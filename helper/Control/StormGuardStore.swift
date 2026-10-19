import Foundation

/// A per-connection identity (the XPC layer maps each accepted `NSXPCConnection` to one).
/// KEPT from the Phase-2 scaffolding (formerly in `EngineSeams`) — generic, SMC-free. Used by the
/// energy helper's listener delegate to correlate per-connection log lines (peer lifecycle).
public typealias ConnID = Int

/// The persisted state the crash-loop **storm guard** needs: `crashCount` (the accumulating half) plus
/// `backoffLevel` (Cut 2: the probationary re-vend cooldown level, independent of crashCount).
///
/// Sprint 3.7 decoupling: the Phase-2 `HelperStateStore` also carried a charge-specific `restoreFailed`
/// field; that is GONE with the SMC capability. The storm guard itself is KEPT — it protects ANY root
/// daemon under launchd `KeepAlive` from a rapid respawn storm, charge or not.
public protocol StormGuardStore: AnyObject, Sendable {
    var crashCount: Int { get set }
    var backoffLevel: Int { get set }     // Cut 2: probation cooldown level, independent of crashCount
    func increment()
    func incrementBackoff()
    func reset()
}

public extension StormGuardStore {
    /// In-memory defaults (e.g. test mocks): the production `FileStormGuardStore` overrides all three
    /// with single locked atomic read-modify-writes of the whole {crashCount, backoffLevel} object.
    func increment() { crashCount += 1 }
    func incrementBackoff() { backoffLevel += 1 }
    func reset() { crashCount = 0; backoffLevel = 0 }
}

/// Production `StormGuardStore`: persists the full {crashCount, backoffLevel} state with an **atomic**
/// write (`Data.write(.atomic)` writes an auxiliary file then renames — the temp+rename discipline
/// carried over from the Phase-2 `FileStateStore`). A corrupt/unreadable/missing file defaults to
/// (0, 0) — fail toward "not tripped": a root daemon that cannot read its counter should run, not wedge.
public final class FileStormGuardStore: StormGuardStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let log: (String) -> Void

    public init(url: URL, log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.url = url
        self.log = log
    }

    public var crashCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return readUnlocked().crash }
        set { lock.lock(); defer { lock.unlock() }
              let s = readUnlocked(); writeUnlocked(crash: newValue, backoff: s.backoff) }   // preserve backoffLevel
    }
    public var backoffLevel: Int {
        get { lock.lock(); defer { lock.unlock() }; return readUnlocked().backoff }
        set { lock.lock(); defer { lock.unlock() }
              let s = readUnlocked(); writeUnlocked(crash: s.crash, backoff: newValue) }      // preserve crash
    }

    /// Single-critical-section read-modify-write (mirrors the Phase-2 `FileStateStore.mutate`): the whole
    /// mutation happens under ONE lock, so a future off-thread caller can't lose an update through a
    /// get-then-set TOCTOU window.
    public func increment() {
        lock.lock(); defer { lock.unlock() }
        let s = readUnlocked(); writeUnlocked(crash: s.crash + 1, backoff: s.backoff)
    }
    public func incrementBackoff() {
        lock.lock(); defer { lock.unlock() }
        let s = readUnlocked(); writeUnlocked(crash: s.crash, backoff: s.backoff + 1)
    }
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        writeUnlocked(crash: 0, backoff: 0)
    }

    // Lock-free internals (NSLock is non-recursive — callers above hold the lock). The full persisted
    // state is read/written as one atomic unit; missing/corrupt → (0, 0): fail toward run.
    private func readUnlocked() -> (crash: Int, backoff: Int) {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (0, 0) }
        return (obj["crashCount"] as? Int ?? 0, obj["backoffLevel"] as? Int ?? 0)
    }
    @discardableResult
    private func writeUnlocked(crash: Int, backoff: Int) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["crashCount": crash, "backoffLevel": backoff]) else {
            log("[StormGuard] state encode FAILED — counter not persisted")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log("[StormGuard] state PERSIST failed (\(url.lastPathComponent)): \(error.localizedDescription)")
            return false
        }
    }
}
