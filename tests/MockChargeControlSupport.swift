import Foundation

/// Scripted ShortcutRunning for reader/engine tests: outcomes consumed FIFO; a `.success`
/// scripted with `fileContent` writes it to the invocation's `-o` path (the Get channel).
final class MockShortcutRunner: ShortcutRunning, @unchecked Sendable {

    struct Scripted {
        var outcome: ShortcutRunOutcome
        var fileContent: String?
        init(_ outcome: ShortcutRunOutcome, file: String? = nil) {
            self.outcome = outcome
            fileContent = file
        }
    }

    private let lock = NSLock()
    private var queue: [Scripted]
    private(set) var invocations: [(name: String, outputPath: String?)] = []
    /// Returned when the queue is empty (keeps unrelated calls from failing tests).
    var fallback = Scripted(.success(stdout: ""))

    init(_ queue: [Scripted] = []) { self.queue = queue }

    func script(_ more: [Scripted]) {
        lock.lock(); queue.append(contentsOf: more); lock.unlock()
    }

    /// Sync helper: NSLock's lock()/unlock() are unavailable in async contexts (Swift 6).
    private func record(_ name: String, _ outputPath: String?) -> Scripted {
        lock.lock(); defer { lock.unlock() }
        invocations.append((name, outputPath))
        return queue.isEmpty ? fallback : queue.removeFirst()
    }

    func run(name: String, outputPath: String?) async -> ShortcutRunOutcome {
        let s = record(name, outputPath)
        if let path = outputPath, let content = s.fileContent {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return s.outcome
    }

    func list() async -> ShortcutRunOutcome {
        record("<list>", nil).outcome
    }

    var invocationNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return invocations.map(\.name)
    }
}

/// In-memory capture store.
///
/// SWEEP H2: it models all THREE load states, not two. `corrupt: true` seeds "bytes are stored under
/// the key but will not decode" — the state the real `UserDefaultsPauseCaptureStore` reaches through a
/// failed `JSONDecoder`, and the one the engine's launch read and Resume disclosure turn on. Without
/// it this double inherits the protocol default (`load()`-shaped, `.corrupt` unreachable) and no engine
/// test could state the case at all.
final class MockPauseCaptureStore: PauseCaptureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var capture: PauseCapture?
    private var corrupt: Bool
    /// Every `clear()` this store has seen — amendment 3 asserts the key is dropped even on a path
    /// that returns early, where "the blob is gone" and "it was never written" would otherwise look alike.
    private(set) var clearCount = 0
    init(_ initial: PauseCapture? = nil, corrupt: Bool = false) {
        capture = initial
        self.corrupt = corrupt
    }
    func load() -> PauseCapture? { loadDetailed().capture }
    func loadDetailed() -> PauseCaptureLoad {
        lock.lock(); defer { lock.unlock() }
        if corrupt { return .corrupt }
        if let capture { return .capture(capture) }
        return .none
    }
    func save(_ c: PauseCapture) { lock.lock(); capture = c; corrupt = false; lock.unlock() }
    func clear() { lock.lock(); capture = nil; corrupt = false; clearCount += 1; lock.unlock() }
}

/// Settable monotonic clock.
final class MockClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ t: TimeInterval = 0) { self.t = t }
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return t }
        set { lock.lock(); t = newValue; lock.unlock() }
    }
}

struct MockMonotonicClock: MonotonicClock {
    let box: MockClockBox
    func now() -> TimeInterval { box.now }
}

/// 4.I addendum: in-memory last-set custody store (shared across engine instances to simulate a
/// relaunch — seed it, then build a new engine with the SAME store).
final class MockLastSetCustodyStore: LastSetCustodyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var c: LastSetCustody?
    init(_ c: LastSetCustody? = nil) { self.c = c }
    func load() -> LastSetCustody? { lock.lock(); defer { lock.unlock() }; return c }
    func save(_ x: LastSetCustody) { lock.lock(); c = x; lock.unlock() }
}
