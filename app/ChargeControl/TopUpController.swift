import Foundation
import Combine

/// Sprint 4.F (#8): one-shot Top Up — capture the current limit → Set 100 (user-sourced, so the
/// existing one-trigger schedule skip protects the climb) → watch for full via the display proxy →
/// pre-verified revert to the capture (source `.topUp`, which sets NO schedule skip). Every edge is
/// pre-decided in SPEC sec 1; this file is the state algebra. Revert rides the FULL existing Set
/// path (serialization, read-verify, confirm windows) — no bespoke plumbing.

/// Persisted active state for relaunch resilience (UserDefaults — app container, S-N6-clean).
struct TopUpState: Codable, Equatable {
    let capturedLimit: Int
    let startedAt: Date
}

/// Redman sweep item 5 — the schema-tolerant decoder (the SWEEP H2 pattern, `PauseCapture`). Both
/// fields are required: the struct is unchanged since it was born (`6497d53`) and the synthesized
/// `encode` always wrote both. EVERY FIELD ADDED LATER must use `decodeIfPresent` with a default, or one
/// new field makes every in-flight Top Up unreadable on upgrade. Unknown keys are ignored.
extension TopUpState {
    enum CodingKeys: String, CodingKey { case capturedLimit, startedAt }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version.
        self.capturedLimit = try c.decode(Int.self, forKey: .capturedLimit)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        // TOLERANT — EVERY FIELD ADDED LATER must be decoded with `decodeIfPresent` and a default.
    }
}

/// Redman sweep item 5: how the stored Top Up record READ. `try?` made "no Top Up in progress" and "a
/// Top Up record that will not decode" the same `nil` — and only `topUp()` ever writes this key, so
/// bytes under it are evidence a Top Up was running (the limit was raised to 100).
enum TopUpStateLoad: Equatable, Sendable {
    case none
    case state(TopUpState)
    case unreadable

    var state: TopUpState? { if case .state(let s) = self { return s } else { return nil } }
}

protocol TopUpStoring: Sendable {
    func load() -> TopUpState?
    func save(_ s: TopUpState)
    func clear()
    func loadDetailed() -> TopUpStateLoad
    /// MOVE unreadable stored bytes aside (never delete them). A no-op otherwise.
    func setAsideUnreadable()
}

extension TopUpStoring {
    /// Stores with no decode step cannot be unreadable.
    func loadDetailed() -> TopUpStateLoad { load().map { .state($0) } ?? .none }
    func setAsideUnreadable() {}
}

struct UserDefaultsTopUpStore: TopUpStoring {
    private static let key = "topUp.active.v1"

    /// Test seam ONLY — a named suite. `nil` = `UserDefaults.standard`, the production path.
    private let suiteName: String?
    private var defaults: UserDefaults {
        guard let suiteName, let d = UserDefaults(suiteName: suiteName) else { return .standard }
        return d
    }
    init(suiteName: String? = nil) { self.suiteName = suiteName }

    func loadDetailed() -> TopUpStateLoad {
        guard let stored = defaults.object(forKey: Self.key) else { return .none }
        guard let d = stored as? Data, let s = try? JSONDecoder().decode(TopUpState.self, from: d) else {
            return .unreadable
        }
        return .state(s)
    }
    func load() -> TopUpState? { loadDetailed().state }
    /// Defence in depth: never write over, or clear, a record that is present but will not decode.
    func save(_ s: TopUpState) {
        guard loadDetailed() != .unreadable else {
            NSLog("battery_app: Top Up save REFUSED — the stored record (%@) will not decode.", Self.key)
            return
        }
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: Self.key) }
    }
    func clear() {
        guard loadDetailed() != .unreadable else {
            NSLog("battery_app: Top Up clear REFUSED — the stored record (%@) will not decode and is kept.", Self.key)
            return
        }
        defaults.removeObject(forKey: Self.key)
    }
    func setAsideUnreadable() {
        guard loadDetailed() == .unreadable, let stored = defaults.object(forKey: Self.key) else { return }
        let asideKey = "\(Self.key).unreadable.\(Int(Date().timeIntervalSince1970))"
        defaults.set(stored, forKey: asideKey)
        guard defaults.object(forKey: asideKey) != nil else { return }   // never remove what was not kept
        defaults.removeObject(forKey: Self.key)
        NSLog("battery_app: unreadable Top Up record set aside under %@.", asideKey)
    }
}

@MainActor
final class TopUpController: ObservableObject {
    /// .starting = the initial Set 100 is in flight (watcher inert); .climbing = watching for full /
    /// unplug / external change; .reverting = the pre-verified restore is in flight.
    enum Phase: Equatable { case idle, starting, climbing, reverting }

    /// The flow truth the watcher reads — SoC + on-AC (the display proxy: full = SoC ≥ 100 on AC).
    struct Reading { let soc: Int?; let onAC: Bool }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var note: String?
    @Published private(set) var capturedLimit: Int?
    @Published private(set) var soc: Int?            // for the "Topping up — 87% → 100" row

    private let engine: ChargeLimitEngine
    private let reading: () -> Reading
    private let store: any TopUpStoring
    private let now: () -> Date

    /// A forgotten Top Up older than 12 h must not pin 100 forever (sec 1).
    static let ttl: TimeInterval = 12 * 3600
    private var startedAt: Date?

    /// Final review F3: the unreadable-record note clears itself on the next successful USER Set (the
    /// user has now set a limit, which is what the note asks for). Armed only while that note is posted.
    private var unreadableNoteClearer: AnyCancellable?
    private var postedUnreadableNote: String?

    /// Redman sweep item 5: the stored Top Up record would not decode at launch. A Top Up WAS running
    /// (only `topUp()` writes the key) but what it captured is gone. The relaunch sets the bytes aside
    /// (F3), so this records what THIS launch found; a new Top Up clears it. NOT `@Published`: the
    /// disclosure rides the existing `note`; NSLog'd.
    private(set) var recordUnreadable = false

    /// The disclosure when an interrupted Top Up's record will not decode and the limit reads 100 (or
    /// cannot be read). Plain words; no autonomous Set is made, because nothing remembers the old limit.
    private static func unreadableRecordNote(limitKnownAt100: Bool) -> String {
        limitKnownAt100
            ? "A Top Up was interrupted and Battery couldn't read your limit from before it. Your limit is still 100% — set your usual limit again."
            : "A Top Up was interrupted and Battery couldn't read your limit from before it. Your limit may still be 100% — check it and set your usual limit again."
    }

    init(engine: ChargeLimitEngine,
         reading: @escaping () -> Reading,
         store: any TopUpStoring = UserDefaultsTopUpStore(),
         now: @escaping () -> Date = { Date() }) {
        self.engine = engine
        self.reading = reading
        self.store = store
        self.now = now
    }

    /// In-progress for the UI (the active pill replaces the Top Up button).
    var isInProgress: Bool { phase != .idle }

    /// Whether the UI should offer Cancel. Only while `.climbing` — `cancel()` no-ops in every other
    /// phase, and offering it during the in-flight Set of `.starting` / `.reverting` would promise an
    /// interruption we deliberately don't perform.
    ///
    /// This exists because the climb has NO guaranteed self-exit. `evaluate()` ends a climb on unplug, a
    /// limit change, SoC ≥ 100, or the 12 h TTL — and on macOS 27 a battery can sit on AC at a stale
    /// sub-limit hold (NotChargingReason 0x01000000) that IGNORES the raise to 100, so SoC never moves and
    /// none of the first three can ever fire. Owner hit exactly that: 80% on AC, limit 100, spinner pinned
    /// for the full TTL. Cancel is the escape hatch that makes any such stall recoverable.
    var canCancel: Bool { phase == .climbing }

    // MARK: - start (the button tap = user intent)

    /// What the START attempt resulted in, for the App Intent surface to report. The climb to 100 then
    /// revert runs over minutes via the snapshot loop, so an intent reports the START, not completion.
    enum StartOutcome: Equatable { case started, alreadyInProgress, refusedPaused, notReady, couldNotStart }

    @discardableResult
    func topUp() async -> StartOutcome {
        guard phase == .idle else { return .alreadyInProgress }
        guard !engine.isPaused else { note = "Resume charging first"; return .refusedPaused }   // contradictory intents refused
        guard case .known(let captured) = engine.limit else {
            note = "Top Up needs a known limit — open and let it read first"
            return .notReady
        }
        // Redman sweep item 5: a new Top Up is the one moment an unreadable old record may be replaced —
        // and even then its bytes are MOVED aside (kept under a dated key), never written over.
        if recordUnreadable || store.loadDetailed() == .unreadable {
            store.setAsideUnreadable()
            // Final review F7: re-read. If the old record is STILL unreadable the new one cannot be
            // written (the store refuses), and persist-before-Set is the invariant that lets a relaunch
            // revert a climb — so do not raise the limit at all. Abort, and say so.
            guard store.loadDetailed() != .unreadable else {
                NSLog("battery_app: Top Up refused — the previous Top Up record will not decode and could not "
                      + "be set aside, so a new one cannot be saved; the limit was not raised.")
                note = "Top Up couldn't start — its saved state couldn't be replaced."
                return .couldNotStart
            }
            recordUnreadable = false
        }
        phase = .starting
        note = nil
        capturedLimit = captured
        startedAt = now()
        soc = reading().soc
        store.save(TopUpState(capturedLimit: captured, startedAt: startedAt!))   // persist BEFORE the Set

        // The tap IS user intent → source `.user`, so the one-trigger schedule skip engages and
        // protects the climb from a mid-climb scheduled trigger (the asymmetry is the design).
        // Audit A1: gate on the keystone CommandOutcome, not a re-read of engine.limit. didWrite is true
        // on .applied OR .appliedUnconfirmed (a degraded write still climbs — the climb itself is the
        // behavioral confirmation); a real failure aborts honestly instead of inferring from a stale
        // value-compare that wrongly proceeds when the limit was ALREADY 100 and the Set failed.
        let outcome = await engine.userSetLimit(100)
        guard outcome.didWrite else {
            finish(note: "Top Up couldn't start")   // the Set didn't take → abort, nothing to climb
            return .couldNotStart
        }
        phase = .climbing
        return .started
    }

    // MARK: - the watcher (driven by the app on every snapshot / limit change while active)

    func evaluate() async {
        guard phase == .climbing else { return }

        // TTL: a forgotten Top Up cancels WITH a restore-attempt (pre-verified revert).
        if let s = startedAt, now().timeIntervalSince(s) > Self.ttl {
            await revert(reason: "Top Up timed out — restoring your limit.")
            return
        }
        let r = reading()
        soc = r.soc

        // Unplug mid-climb → cancel + immediate restore (never leave 100 dangling).
        if !r.onAC {
            await revert(reason: "Top Up ended — unplugged. Limit restored.")
            return
        }
        // Manual/external limit change mid-climb → cancel, NO restore (their value is the new intent).
        if engine.limit != .known(100) {
            finish(note: "Top Up ended — the limit was changed.")
            return
        }
        // Full (display proxy: SoC ≥ 100 on AC) → revert.
        if (r.soc ?? 0) >= 100 {
            await revert(reason: nil)
        }
    }

    // MARK: - cancel button (intent custody still ours → the full revert path incl. pre-verification)

    func cancel() async {
        guard phase == .climbing else { return }
        await revert(reason: "Top Up cancelled. Limit restored.")
    }

    // MARK: - relaunch resilience

    func resumeOnLaunch() async {
        let saved: TopUpState
        switch store.loadDetailed() {
        case .none:
            return
        case .state(let s):
            saved = s
        case .unreadable:
            // Redman sweep item 5. Not "no Top Up": the record exists, so the limit was raised to 100,
            // and what it captured is gone. There is NO other witness of the pre-Top-Up limit (the
            // custody is the climb's own 100; the pause capture is unrelated), so ANY autonomous restore
            // would be a guess written to the hardware — the SWEEP H2 precedent (`restorePointLost`)
            // chose "proceed and warn, never guess" for exactly this shape. So: read the limit, make NO
            // Set, keep the record, and say it on the Top Up note when the pack is (or may be) at 100.
            // The 12 h TTL cannot apply — `startedAt` is in the unreadable bytes.
            recordUnreadable = true
            await engine.sync(.verify)   // B5: a precondition read — never rate-gated
            let current = engine.limit.knownValue ?? engine.lastSetCustody?.value
            NSLog("battery_app: the saved Top Up record will not decode — a Top Up was interrupted; limit "
                  + "now reads %@. No restore attempted (the previous limit is unknown); record set aside.",
                  current.map { "\($0)%" } ?? "unknown")
            if current == nil || current == 100 {
                postUnreadableRecordNote(Self.unreadableRecordNote(limitKnownAt100: current == 100))
            }
            // Final review F3: the record has nothing left to do — a KNOWN limit other than 100 means the
            // climb is over; otherwise the one thing it could still do (prompt the user) has just been
            // done. So it is moved aside (KEPT, byte-identical, dated key — never cleared) and the next
            // launch finds no record: the note is shown ONCE per unreadable record, not at every launch
            // for a user who keeps 100%.
            store.setAsideUnreadable()
            return
        }
        capturedLimit = saved.capturedLimit
        startedAt = saved.startedAt
        soc = reading().soc
        phase = .climbing

        // TTL on launch → cancel-with-restore-attempt.
        if now().timeIntervalSince(saved.startedAt) > Self.ttl {
            await revert(reason: "Top Up timed out — restoring your limit.")
            return
        }
        // 4.I addendum: consult the limit where we consulted the Get. Verified mode → engine.limit
        // reflects the read. Degraded mode → the Get can't verify, so fall back to the persisted
        // LastSetTracker custody (our last write). custody == 100 → the climb is intact, resume;
        // else cancel per the existing rule.
        await engine.sync(.verify)   // B5: a precondition read — never rate-gated
        // Redman sweep item 6: NO witness is not evidence of a change. With the Get unavailable and no
        // readable custody (never written, or written but unreadable — `engine.custodyUnreadable`),
        // nothing says whether the climb is intact. The old `current != 100` read that `nil` as "the
        // limit was changed": it deleted a VALID Top Up record and attempted no restore, leaving the
        // pack at 100 under a note blaming the user. The safe answer is the pre-verified RESTORE to the
        // captured limit — the user's own value; staying at 100 is the battery-ageing direction this app
        // exists to prevent, and `revert` already re-reads first and refuses to restore over a read
        // that shows a real change.
        //
        // KNOWN EXPOSURE (final review F4), stated so it is not mistaken for a guarantee: `revert`'s
        // re-read can only refuse over a change it can SEE. In degraded mode (no Get) with an unreadable
        // custody it sees nothing, so if the user changed the limit OUTSIDE the app while it was not
        // running (System Settings, another tool), this restore writes the captured limit over that
        // change. It is the same exposure the 12 h TTL path already carries — `revert` from the TTL
        // branch above takes the identical `.unknown → proceed` route — and it is accepted for the same
        // reason: with no witness either way, the user's own pre-Top-Up limit is the safer write than
        // leaving 100. Verified mode (a working Get) and a readable custody both close it.
        guard let current = engine.limit.knownValue ?? engine.lastSetCustody?.value else {
            NSLog("battery_app: Top Up relaunch — no readable limit and no readable custody%@; restoring the "
                  + "captured limit rather than abandoning the record.",
                  engine.custodyUnreadable ? " (the saved custody will not decode)" : "")
            await revert(reason: "Top Up couldn't be confirmed after relaunch — restoring your limit.")
            return
        }
        if current != 100 {
            finish(note: "Top Up ended — the limit was changed.")
        }
        // else: stay .climbing; evaluate() resumes on the next tick.
    }

    // MARK: - revert (pre-verified — the pre-Resume pattern)

    private func revert(reason: String?) async {
        guard phase == .climbing else { return }
        phase = .reverting
        let captured = capturedLimit

        // Pre-revert verification: Get the current limit. 4.I addendum: a degraded Get now KEEPS the
        // persisted custody (engine.limit stays .known) rather than blanking. The staleness switch below
        // is unchanged. Audit A1: the verified-vs-unconfirmed caveat is no longer inferred from this
        // pre-revert read — it now comes from the RESTORE Set's own CommandOutcome (.applied vs
        // .appliedUnconfirmed), which is strictly more accurate (it reflects whether the restore itself
        // was read-verified, not whether the pre-revert read was).
        await engine.sync(.verify)   // B5: the pre-revert precondition read — never rate-gated
        switch engine.limit {
        case .known(100):
            break                                      // intact (verified read OR custody == 100)
        case .known:
            // A different value — an OBSERVED external change (verified) or a divergent custody →
            // the climb is stale → CANCEL, no restore.
            finish(note: "Top Up ended — the limit was changed.")
            return
        case .unknown:
            break                                      // No custody (degraded, fresh) — proceed on
                                                       // behavioral custody; the restore outcome carries the caveat.
        }
        if let captured {
            // source `.topUp` → sets NO schedule skip (runner keys on `== .user`) + "Top Up:" prefix.
            let outcome = await engine.userSetLimit(captured, source: .topUp)
            let base = reason ?? "Top Up: limit restored to \(captured)%"
            switch outcome {
            case .applied:
                finish(note: base)                     // read-verified restore
            case .appliedUnconfirmed:
                finish(note: base + " — read-back unavailable, confirmed by behavior")
            case .issueFailed, .mismatch, .invalidTarget, .busy:
                // A1: the restore did NOT go through — never claim it was restored.
                finish(note: "Top Up: couldn't set your limit back to \(captured)% — set it manually.")
            }
        } else {
            finish(note: reason)
        }
    }

    /// F3: post the unreadable-record note and arm its one-shot clear on the next successful user Set.
    private func postUnreadableRecordNote(_ text: String) {
        note = text
        postedUnreadableNote = text
        unreadableNoteClearer = engine.$lastSetCustody
            .dropFirst()
            .sink { [weak self] custody in
                MainActor.assumeIsolated {
                    // A custody write IS a Set that landed; only a USER-sourced one answers the note.
                    guard let self, custody != nil, self.engine.lastCommandSource == .user else { return }
                    if self.note == self.postedUnreadableNote { self.note = nil }
                    self.postedUnreadableNote = nil
                    self.unreadableNoteClearer = nil
                }
            }
    }

    private func finish(note: String?) {
        phase = .idle
        capturedLimit = nil
        startedAt = nil
        store.clear()
        self.note = note
    }
}
