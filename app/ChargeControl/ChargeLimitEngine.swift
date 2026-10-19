import Foundation
import Combine

/// sec 6 OS gate: "OS below 26.4 (feature hidden, monitoring-only mode)". ONE check used by
/// BOTH the UI (hide the section) and the wiring (no engine taps, no setup detection, no
/// Shortcuts invocations of any kind) — the gate must not be UI-only.
enum ChargeLimitSupport {
    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0))
    }
}

/// Sprint 4.C: who issued a limit change. The runner/windows treat non-`.user` sources IDENTICALLY
/// to `.user` on the issue path; the tag only (a) drives the UI status prefix and (b) lets the
/// ScheduleRunner distinguish app-initiated Sets from human/external changes (human-primacy skip,
/// keyed on `== .user`).
/// Sprint 4.F: `.topUp` is the Top-Up REVERT leg's source (status prefix "Top Up:"); because the
/// runner's skip condition is exactly `== .user`, a `.topUp` revert sets NO schedule skip.
/// Phase 5 (#17): `.appIntent` is an App Intent / Shortcut / Siri-driven Set. Autonomous at the
/// notification cause, but an EXPLICIT instruction the schedule must not fight, so the runner's
/// human-primacy guard widens to `isExplicitUserOrIntent` (user or intent) — see that helper.
enum CommandSource: Equatable { case user, schedule, topUp, appIntent }

extension CommandSource {
    /// An EXPLICIT "set this now" instruction the schedule must not fight (spec sec 3/8): a direct
    /// user/external change (`.user`) or an App Intent (`.appIntent`). NOT our own autonomous
    /// `.schedule` Set nor the `.topUp` revert leg. Replaces the scattered `== .user` comparisons.
    var isExplicitUserOrIntent: Bool { self == .user || self == .appIntent }

    /// The popover status-line prefix for a source-tagged command status (spec sec 3). Owner-tunable
    /// copy. Pure so the "Shortcut: " rendering is unit-testable (the view is app-only).
    var statusPrefix: String {
        switch self {
        case .schedule:  return "Scheduled: "
        case .topUp:     return "Top Up: "
        case .appIntent: return "Shortcut: "
        case .user:      return ""
        }
    }
}

/// Audit keystone (00-AUDIT-codebase-recon-2026-06.md Part 2 item 1): the verified result of a
/// Set / Pause / Resume. `issueSet` already COMPUTES this distinction inside its read-verify pipeline;
/// the command methods surface it instead of discarding it (callers must stop reconstructing "success"
/// from a re-read of `engine.limit`, which is strictly weaker — and in degraded mode an outright lie).
/// `.issueFailed` reuses the existing `CommandStatus` taxon (the SAME value `issueSet` hands to
/// `confirm.commandFailed`) — NOT a parallel failure vocabulary. (The design-of-record's enum sketch
/// named a `CommandFailure` payload that does not exist in this codebase; `CommandStatus` is the real
/// taxon and is used here — flagged in the hand-back.)
enum CommandOutcome: Equatable, Sendable {
    case applied                      // written AND verified by the post-Set read-back
    case appliedUnconfirmed           // written; read-back unavailable (degraded), "as set", not verified
    case invalidTarget(Int)           // rejected: not a settable step
    case busy                         // rejected: a command was already in flight
    case mismatch(observed: Int)      // Set ran but the verified read-back showed a different value
    case issueFailed(CommandStatus)   // shortcut missing/blocked/nonzero/launch (the status issueSet already raised)
}

extension CommandOutcome {
    /// The Set physically landed (verified OR as-set). The post-Set side effects in `pause`/`resume`
    /// (capture save, `isPaused` flip) are valid iff this is true — it is the exact successor to the
    /// old `guard await issueSet(target) else { return }` Bool.
    var didWrite: Bool { self == .applied || self == .appliedUnconfirmed }
}

/// Sprint 4.I addendum (architect ruling cfcd53c): the LastSetTracker custody — the last value the
/// app itself WROTE, persisted so it survives a relaunch. In degraded mode (no Get read-back) this
/// is what the popover shows as "<v>% · as set" and what Top Up consults on relaunch. NOT an
/// external read — provenance is "our last write; external changes invisible".
struct LastSetCustody: Codable, Equatable { let value: Int; let at: Date }

/// Redman sweep item 6 — the schema-tolerant decoder (the SWEEP H2 pattern, `PauseCapture`). Both
/// fields are required: the struct is unchanged since it was born (`21c2927`) and the synthesized
/// `encode` always wrote both. EVERY FIELD ADDED LATER must use `decodeIfPresent` with a default, or one
/// new field turns every stored custody into "no witness" on upgrade. Unknown keys are ignored.
extension LastSetCustody {
    enum CodingKeys: String, CodingKey { case value, at }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version.
        self.value = try c.decode(Int.self, forKey: .value)
        self.at = try c.decode(Date.self, forKey: .at)
        // TOLERANT — EVERY FIELD ADDED LATER must be decoded with `decodeIfPresent` and a default.
    }
}

/// Redman sweep item 6: how the stored custody READ. `try?` made "never written" and "written but will
/// not decode" the same `nil`, and in degraded mode that `nil` was the ONLY relaunch witness Top Up had.
enum LastSetCustodyLoad: Equatable, Sendable {
    case none
    case custody(LastSetCustody)
    case unreadable

    var custody: LastSetCustody? { if case .custody(let c) = self { return c } else { return nil } }
}

protocol LastSetCustodyStoring: Sendable {
    func load() -> LastSetCustody?
    func save(_ c: LastSetCustody)
    func loadDetailed() -> LastSetCustodyLoad
}

extension LastSetCustodyStoring {
    /// Stores with no decode step cannot be unreadable.
    func loadDetailed() -> LastSetCustodyLoad { load().map { .custody($0) } ?? .none }
}

struct UserDefaultsLastSetCustodyStore: LastSetCustodyStoring {
    private static let key = "chargeLimit.lastSetCustody.v1"

    /// Test seam ONLY — a named suite so the real decoder can be driven over real bytes. `nil` =
    /// `UserDefaults.standard`, the production path.
    private let suiteName: String?
    private var defaults: UserDefaults {
        guard let suiteName, let d = UserDefaults(suiteName: suiteName) else { return .standard }
        return d
    }
    init(suiteName: String? = nil) { self.suiteName = suiteName }

    func loadDetailed() -> LastSetCustodyLoad {
        guard let stored = defaults.object(forKey: Self.key) else { return .none }
        guard let d = stored as? Data, let c = try? JSONDecoder().decode(LastSetCustody.self, from: d) else {
            return .unreadable
        }
        return .custody(c)
    }
    func load() -> LastSetCustody? { loadDetailed().custody }
    /// Overwriting an UNREADABLE custody here is deliberate and is not the defect class: the value
    /// written is a fresh, authoritative record of a Set that just landed (never one derived from the
    /// failed read), and custody only ever describes the LAST write — the unreadable bytes describe an
    /// earlier one that this Set supersedes.
    func save(_ c: LastSetCustody) {
        if let d = try? JSONEncoder().encode(c) { defaults.set(d, forKey: Self.key) }
    }
}

/// WI-N5: the engine coordinator — owns the runner, the LimitReader, and BehaviorConfirm;
/// implements the Set pipeline (read-verify + retry-once), S-N3 external-change absorption,
/// and the sec-5 Pause/Resume orchestration. The UI (WI-N7) talks ONLY to this.
///
/// Serialization (sec 2): the runner serializes invocations; a new user action supersedes the
/// armed confirm window (BehaviorConfirm publishes nothing from it); UI debounce hangs off
/// `commandInFlight`.
@MainActor
final class ChargeLimitEngine: ObservableObject {

    /// B-arc B5 split `.verify` out of `.popoverOpen`. They read identically; the difference is that
    /// `.popoverOpen` is a REFRESH (the surface is about to be shown, and a reopen seconds later learns
    /// nothing new) while `.verify` is a PRECONDITION read a caller is about to act on — Top Up's
    /// pre-revert check and its resume-on-launch check. Only `.popoverOpen` is rate-gated; gating a
    /// `.verify` would let a command proceed against a stale limit, which is the opposite of the point.
    enum SyncTrigger { case popoverOpen, verify, wake, backstop }

    /// The absorbed limit (S-N3: the app NEVER fights an external value — it adopts it).
    @Published private(set) var limit: ChargeLimitValue = .unknown
    @Published private(set) var isPaused = false
    /// Engine-level context line (resume invalidation, degraded caveats). Composes with
    /// BehaviorConfirm's own statusNote in the UI.
    @Published private(set) var engineNote: String?
    /// True while a user command (Set/Pause/Resume) is being executed — disables controls.
    @Published private(set) var commandInFlight = false
    /// S-N4 fail-toward-visibility for the RE-SYNC path: a popover/wake/backstop Get that
    /// fails publishes its problem here (the UI surfaces the matching taxon string) instead
    /// of silently leaving `limit = .unknown`. Cleared by the next successful read.
    @Published private(set) var syncProblem: LimitReadProblem?
    /// sec 5 Pause caveats, surfaced while paused: the sub-80 floor ("may still rise to 80")
    /// or the above-95 bleed. Cleared on Resume / new Set.
    @Published private(set) var pauseCaveat: String?
    /// SWEEP H2: this pause was INFERRED from a capture that would not decode — the app knows charging
    /// is being held but not what it was held from, and Resume will therefore set 100.
    ///
    /// Session-STICKY on purpose, and deliberately NOT a second persisted latch (the review rejected
    /// that): amendment 3 drops the stored blob on the first Resume attempt even when its Set fails, so
    /// after that attempt the store says `.none` and only this flag remembers that the retry must still
    /// disclose. Read by `ScheduleRunner` (its suspend note) and by the popover's charge card (the
    /// standing caveat) — a published state with no screen is what `scripts/ui-orphan-gate.sh` exists
    /// to catch.
    @Published private(set) var pauseRestorePointLost = false
    /// 4.C: the source of the last APPLIED limit change. `.schedule` only right after a
    /// scheduled Set; a user/external change flips it back to `.user`. Drives the UI's
    /// "Scheduled:" prefix and the runner's human-primacy detection.
    @Published private(set) var lastCommandSource: CommandSource = .user
    /// 4.I addendum: the persisted last-set custody (our last write). Drives the degraded "· as set"
    /// value and the Top Up relaunch decision. nil until the first Set on a fresh install.
    @Published private(set) var lastSetCustody: LastSetCustody?

    let confirm: BehaviorConfirm

    /// B1: mirrors `setupFlow.state == .readyDegraded` (the app updates this; the same canonical signal
    /// popover L227 keys on, not a new heuristic). When true, a read-back-unavailable after a successful
    /// Set is the EXPECTED permanent-degraded case, so we show a calm transient "Limit set to N%" instead
    /// of the scary read-back caveat. The "as set"/"holding" provenance tag is the steady-state truth.
    var readBackDegraded = false

    private let runner: any ShortcutRunning
    private let reader: LimitReader
    private let captureStore: any PauseCaptureStoring
    private let custodyStore: any LastSetCustodyStoring
    private let clock: any MonotonicClock

    private var latestSnapshot: ChargeTelemetrySnapshot?
    private var latestState: TelemetryChargeState = .unknown
    private var lastBackstopSyncAt: TimeInterval?
    private var lastPopoverSyncAt: TimeInterval?

    /// S-N3: the periodic backstop re-sync runs AT MOST every 30 min (popover/wake/post-Set
    /// cover the real cases; each re-sync is a Shortcuts invocation — power-politeness).
    static let backstopMinInterval: TimeInterval = 1800

    /// B-arc B5: rapid popover reopens no longer each spawn a `shortcuts run` — at most one popover-open
    /// re-sync per minute. Deliberately the GENEROUS end of the ruled 60–120 s range: S-N3 adoption is
    /// safety-relevant, so the gate exists to kill the open/close/open burst, not to ration the read.
    /// `.wake` and `.backstop` are NOT gated by this (they keep their own cadence), and the post-Set
    /// read-back path doesn't route through `sync` at all.
    static let popoverOpenMinInterval: TimeInterval = 60

    /// Redman sweep item 6: the stored custody is present but would not decode, so `lastSetCustody` is
    /// nil for want of a READABLE witness — not because the app never set a limit. Cleared by the next
    /// successful Set (which writes a fresh custody). NOT `@Published`: no screen yet; NSLog'd.
    private(set) var custodyUnreadable = false

    init(runner: any ShortcutRunning,
         captureStore: any PauseCaptureStoring = UserDefaultsPauseCaptureStore(),
         custodyStore: any LastSetCustodyStoring = UserDefaultsLastSetCustodyStore(),
         clock: any MonotonicClock = LiveMonotonicClock(),
         confirmTunables: BehaviorConfirm.Tunables = .init()) {
        self.runner = runner
        self.reader = LimitReader(runner: runner)
        self.captureStore = captureStore
        self.custodyStore = custodyStore
        self.clock = clock
        self.confirm = BehaviorConfirm(limitReader: reader, tunables: confirmTunables)
        // SWEEP H2 change 1 — the launch read, three-state. `.capture` AND `.corrupt` are paused;
        // only `.none` (nothing stored under the key) keeps the scheduler running.
        //
        // The old `load() != nil` collapsed `.corrupt` into "never paused", which is a VANISHED latch:
        // the pack is physically held at the pause target, the app shows no pause, no caveat and NO
        // RESUME BUTTON, and the scheduler runs on a capped pack. There is no second witness — on a
        // corrupt capture both `limit` and `lastSetCustody` read the PAUSE target, not the pre-pause
        // one. `pause()` is SET-THEN-CAPTURE (`guard outcome.didWrite` precedes `captureStore.save`),
        // so a capture write that went wrong can only have happened after the hold landed: bytes under
        // this key are evidence the pack IS capped.
        //
        // AUTONOMOUS-BEHAVIOUR CHANGE, accepted with its new failure mode named: a leftover or migrated
        // key now suspends the whole schedule until the user presses Resume, and that Resume sets 100
        // though the user never paused. The price of admission is `pauseRestorePointLost` — the state
        // is disclosed on the idle surface, and the 100 is never presented as a restore.
        let pauseLoad = captureStore.loadDetailed()
        self.isPaused = pauseLoad.indicatesPaused
        self.pauseRestorePointLost = pauseLoad.restorePointLost
        if pauseLoad.restorePointLost { self.pauseCaveat = ChargeStatusStrings.pauseRestorePointLostCaveat }
        // 4.I addendum: restore the persisted custody so a degraded relaunch shows "<v>% · as set"
        // immediately instead of knowing nothing (a later verified read overwrites it).
        let custodyLoad = custodyStore.loadDetailed()
        self.lastSetCustody = custodyLoad.custody
        self.custodyUnreadable = (custodyLoad == .unreadable)
        if custodyLoad == .unreadable {
            NSLog("battery_app: the saved last-set custody will not decode — treated as NO witness (not as "
                  + "\"no Set was ever made\"); the next successful Set replaces it.")
        }
        if let c = lastSetCustody { self.limit = .known(c.value) }
        confirm.onAdoptExternalLimit = { [weak self] adopted in
            self?.adoptExternal(adopted)
        }
    }

    // MARK: - telemetry feed (single poll loop, WI-N7)

    func ingest(_ snapshot: ChargeTelemetrySnapshot, state: TelemetryChargeState) {
        latestSnapshot = snapshot
        latestState = state
        confirm.ingest(snapshot, state: state)
    }

    /// The armed cadence driver for the shared poll loop (10 s armed / 60 s passive).
    var wantsFastPolling: Bool { confirm.isWindowArmed }

    // MARK: - user commands

    /// Set the limit to one of the sanctioned values (sec 3). `source` tags who asked — the issue
    /// path is otherwise IDENTICAL for user and schedule (serialization, read-verify, arming).
    func userSetLimit(_ target: Int, source: CommandSource = .user) async -> CommandOutcome {
        guard let step = ChargeLimitStep(target) else { return .invalidTarget(target) }   // C2 smart-constructor gate
        guard !commandInFlight else { return .busy }   // sec 2: a command is already pending
        commandInFlight = true
        defer { commandInFlight = false }
        lastCommandSource = source
        engineNote = nil
        pauseCaveat = nil
        let outcome = await issueSet(step.percent)
        if outcome.didWrite {
            // ISSUE-11 / SF2 latch: an authoritative in-app Set supersedes any prior Pause intent. Once a
            // new ceiling is set, "holding at a captured level, will resume to my real limit" is meaningless,
            // so clear the latch + the capture. Gated on didWrite (the same gate pause()/resume() use), so a
            // failed Set leaves the failure path byte-identical to before. pauseCaveat is already nil'd above
            // and issueSet never sets it (commandInFlight blocks a concurrent pause()), so no redundant clear.
            isPaused = false
            captureStore.clear()
            pauseRestorePointLost = false   // SWEEP H2: the pause it described is superseded
        } else if pauseRestorePointLost {
            // SWEEP H2: the Set did not land, so the inferred pause is STILL in force and still
            // unexplained. `pauseCaveat` was blanked above (unconditional, pre-existing) — put the
            // standing disclosure back rather than letting a failed Set quietly retire it.
            pauseCaveat = ChargeStatusStrings.pauseRestorePointLostCaveat
        }
        return outcome
    }

    /// Pause Charging (sec 5): set min(95, highest step <= SoC); capture the absorbed limit.
    func pause() async -> CommandOutcome {
        guard !commandInFlight else { return .busy }
        commandInFlight = true
        defer { commandInFlight = false }
        lastCommandSource = .user
        engineNote = nil

        let soc = latestSnapshot?.socPercent
        let target = PauseResumePolicy.pauseTarget(socPercent: soc)
        var capturedFrom: Int?
        if case .known(let v) = limit { capturedFrom = v }
        let outcome = await issueSet(target)
        guard outcome.didWrite else { return outcome }
        captureStore.save(PauseCapture(pausedFromLimit: capturedFrom, pauseTarget: target,
                                       capturedAt: Date()))
        isPaused = true
        pauseRestorePointLost = false   // SWEEP H2: this capture IS the restore point
        // sec 5: the honest envelope of the mechanism, surfaced — (a) native floor below 80,
        // (b) bleed-down above 95.
        if let soc, soc < 80 {
            pauseCaveat = ChargeStatusStrings.pauseFloorCaveat
        } else if let soc, soc > 95 {
            pauseCaveat = ChargeStatusStrings.pauseBleedCaveat
        } else if soc == nil { pauseCaveat = "battery level unreadable - paused at the 80% floor" }  // LOW-2 (the one permitted engine line)
        else { pauseCaveat = nil }   // SWEEP H2: no stale caveat (the H2 one included) outlives a fresh pause
        return outcome
    }

    /// Resume Charging (sec 5 + Grok SF2): pre-Resume Get verifies the capture is still the
    /// live value; an external change invalidates it AT THAT MOMENT → restore 100 + note.
    func resume() async -> CommandOutcome {
        guard !commandInFlight else { return .busy }
        commandInFlight = true
        defer { commandInFlight = false }
        lastCommandSource = .user
        engineNote = nil

        // SWEEP H2: three-state, and the "restore point lost" answer is STICKY for the session — not
        // read fresh from the store. Amendment 3 (below) drops the blob on the FIRST Resume attempt even
        // when its Set fails, so a retry would re-read `.none` and set 100 in silence. The one thing
        // this path may never do is that.
        let load = captureStore.loadDetailed()
        let capture = load.capture
        let restorePointLost = load.restorePointLost || pauseRestorePointLost
        var target = 100
        switch (capture, capture?.invalidatedByExternalChange) {
        case (nil, _):
            break                                    // no capture → default 100
        case (let cap?, true):
            _ = cap
            engineNote = "limit was changed outside the app"
        case (let cap?, _):
            switch await reader.read() {
            case .value(let current) where current != cap.pauseTarget:
                engineNote = "limit was changed outside the app"   // invalidated NOW (SF2)
            case .value:
                target = cap.pausedFromLimit ?? 100
            case .unavailable:
                // Get-degraded: restore the capture, say we couldn't verify (sec 5).
                target = cap.pausedFromLimit ?? 100
                engineNote = "couldn't verify external changes"
            }
        }
        // SWEEP H2 change 2. A lost restore point does NOT block Resume — refusing would leave the pack
        // capped with its only exit removed, the same defect shape as the stalled Top Up climb that had
        // no Cancel (`752086e`). But 100 is the UNCAPPED, battery-ageing direction and holding the cap
        // below it is the app's whole purpose, so a 100 taken on no evidence is disclosed as a loss,
        // never presented as a restore. Set before `issueSet` so a read-back caveat composes onto it
        // (`appendNote`), matching the external-change note above.
        if restorePointLost { engineNote = ChargeStatusStrings.resumeRestorePointLostNote }
        let outcome = await issueSet(target)
        guard outcome.didWrite else {
            // SWEEP H2 AMENDMENT 3 — on `.corrupt`, drop the key even when the Set failed partway.
            // Otherwise there is NO EXIT: corrupt → paused → Resume's Set fails → the key survives →
            // the next launch re-arms the same ghost pause, and so does the launch after that.
            // AUTONOMOUS-BEHAVIOUR CHANGE, accepted, new failure mode named: this destroys the last
            // evidence that a pause ever existed — evidence that was already unreadable. `isPaused` is
            // deliberately left TRUE (the pack really may still be held, so this session keeps showing
            // the pause and its Resume), and `pauseRestorePointLost` stays true so the retry still
            // discloses. Scoped to `.corrupt`: a DECODABLE capture whose Set fails keeps its blob —
            // that restore point is still good and the retry needs it.
            if restorePointLost { captureStore.clear() }
            return outcome
        }
        captureStore.clear()
        isPaused = false
        pauseRestorePointLost = false
        pauseCaveat = nil
        return outcome
    }

    // MARK: - S-N3 re-sync triggers (popover open / wake / 30-min backstop)

    func sync(_ trigger: SyncTrigger) async {
        if trigger == .backstop {
            let now = clock.now()
            if let last = lastBackstopSyncAt, now - last < Self.backstopMinInterval { return }
            lastBackstopSyncAt = now
        }
        if trigger == .popoverOpen {
            let now = clock.now()
            if let last = lastPopoverSyncAt, now - last < Self.popoverOpenMinInterval { return }
            lastPopoverSyncAt = now
        }
        switch await reader.read() {
        case .value(let v):
            syncProblem = nil
            adoptExternal(.known(v))
        case .unavailable(let problem):
            // S-N4: fail toward visibility — surface the taxon. 4.I addendum: but when we hold a
            // persisted custody (our last write), KEEP it rather than blanking to .unknown — the
            // popover shows "<v>% · as set" (provenance honest) instead of knowing nothing.
            syncProblem = problem
            if let c = lastSetCustody { limit = .known(c.value) } else { limit = .unknown }
        }
    }

    /// Adopt, never fight (S-N3). An adopted value that contradicts a live pause capture
    /// invalidates it (Resume will restore 100 + note).
    private func adoptExternal(_ value: ChargeLimitValue) {
        // 4.C: a GENUINE external change (value differs from what we hold) is human-primacy
        // relevant — tag it `.user` so the runner sets the one-trigger skip. A same-value
        // re-sync must NOT flip the source (else every backstop poll would skip the schedule).
        if value != limit, case .known = value { lastCommandSource = .user }
        let previous = limit
        limit = value
        guard case .known(let v) = value else { return }
        // Redman sweep item 8: the THREE-state read. The collapsing `load()` made a corrupt capture look
        // like "no pause", so a genuine external change during a pause the engine already treats as in
        // force (SWEEP H2: `.corrupt` ⇒ paused, restore point lost) went undisclosed.
        switch captureStore.loadDetailed() {
        case .capture(var capture):
            if !capture.invalidatedByExternalChange, v != capture.pauseTarget {
                capture.invalidatedByExternalChange = true
                captureStore.save(capture)
                engineNote = "limit was changed outside the app"
            }
        case .corrupt:
            // No pause target to compare against, and NOTHING is written (the unreadable capture is
            // never replaced; Resume already resolves to 100 with the restore-point-lost disclosure).
            // The evidence available is a change from the value the engine HELD — a first reading
            // after an unknown, or a same-value re-sync, is not a change.
            if case .known(let held) = previous, held != v { engineNote = "limit was changed outside the app" }
        case .none:
            break
        }
    }

    // MARK: - the Set pipeline

    /// Run the per-value Set shortcut; classify failures (sec 6); read-verify (mandatory,
    /// sec 2); arm BehaviorConfirm. Returns success.
    ///
    /// S-N4 BUDGET: max ONE automatic retry per user action, SHARED between the two retryable
    /// conditions (a nonzero-exit re-run and a read-back-mismatch re-Set) — the compositions
    /// can never multiply into a retry storm.
    private func issueSet(_ target: Int) async -> CommandOutcome {
        // Captured BEFORE the Set — the arming rules key off the PRE-Set world.
        let preSetNCR = latestSnapshot?.notChargingReason
        let socAtSet = latestSnapshot?.socPercent
        let stateAtSet = latestState
        let now = clock.now()

        confirm.supersede()   // any armed window dies now, publishing nothing

        let first = await runSetShortcut(target, now: now, allowRetry: true)
        guard first.ok else { return .issueFailed(first.status) }
        var retryAvailable = !first.retried   // the single S-N4 retry, if still unspent
        // B1: in permanent-degraded mode a read-back-unavailable is the soft-confirmation case. We emit
        // the calm "Limit set to N%" AFTER commandIssued (which clears any stale note), not here.
        var pendingDegradedConfirm = false
        // Keystone: the post-Set read-verify ACTUALLY confirmed the target (→ .applied) vs the write
        // went out but read-back was unavailable (→ .appliedUnconfirmed). NOT the same as
        // pendingDegradedConfirm (which is only about showing the calm transient in permanent-degraded).
        var readVerified = false

        // Mandatory read-verify (sec 2 "Read-verify rule"); Get-degraded must NOT block.
        switch await reader.read() {
        case .value(let v) where v == target:
            limit = .known(target)
            readVerified = true
        case .value(let v):
            // Mismatch → re-Set ONCE if the budget allows (sec 6), re-verify, then surface.
            guard retryAvailable else {
                adoptExternal(.known(v))
                confirm.commandFailed(.error(.limitMismatchAfterSet), at: now)
                return .mismatch(observed: v)
            }
            retryAvailable = false
            let retry = await runSetShortcut(target, now: now, allowRetry: false)
            guard retry.ok else { return .issueFailed(retry.status) }
            switch await reader.read() {
            case .value(let v2) where v2 == target:
                limit = .known(target)
                readVerified = true
            case .value(let v2):
                adoptExternal(.known(v2))
                confirm.commandFailed(.error(.limitMismatchAfterSet), at: now)
                return .mismatch(observed: v2)
            case .unavailable(let problem):
                limit = .known(target)
                if noteReadBackUnavailable(problem) { pendingDegradedConfirm = true }
            }
        case .unavailable(let problem):
            // LastSetTracker contingency (sec 2): adopt the last-written value. In verified mode this
            // carries the read-back caveat; in permanent-degraded mode it is the soft-confirmation case.
            limit = .known(target)
            if noteReadBackUnavailable(problem) { pendingDegradedConfirm = true }
        }

        // 4.I addendum: persist the custody on every successful Set (our last write), so it survives
        // a relaunch and drives the degraded "· as set" value + the Top Up relaunch decision.
        let custody = LastSetCustody(value: target, at: Date())
        custodyStore.save(custody)
        lastSetCustody = custody
        custodyUnreadable = false   // sweep item 6: a fresh, readable witness supersedes the unreadable one

        confirm.commandIssued(target: target, preSetNCR: preSetNCR, socAtSet: socAtSet,
                              telemetryState: stateAtSet, at: now)
        // B1: degraded-success soft confirmation, AFTER commandIssued cleared any stale note. Calm and
        // transient; the persistent truth is the "as set"/"holding" provenance tag (Batch 2).
        if pendingDegradedConfirm {
            confirm.showTransientConfirmation("Limit set to \(target)%")
        }
        // Keystone: .applied ONLY when the post-Set read-verify CONFIRMED the target; a write whose
        // read-back was unavailable is .appliedUnconfirmed ("as set", not verified) — never .applied.
        return readVerified ? .applied : .appliedUnconfirmed
    }

    /// B1: route a read-back-unavailable after a successful Set. In permanent-degraded mode this is the
    /// EXPECTED soft-confirmation case, so we append NO caveat and return true (the caller emits the calm
    /// "Limit set to N%"). In verified mode a normally-working read failed this once, which is honest
    /// news, so we keep the caveat and return false.
    private func noteReadBackUnavailable(_ problem: LimitReadProblem) -> Bool {
        if readBackDegraded { return true }
        appendReadBackCaveat(problem)
        return false
    }

    /// The Get-degraded caveat — with the sec-6 mandated wording when the cause is a format
    /// change rather than an unavailable Get.
    private func appendReadBackCaveat(_ problem: LimitReadProblem) {
        if problem == .outputUnparseable {
            appendNote(ChargeStatusStrings.errorLabel(.getOutputUnparseable))
        } else {
            appendNote("couldn't verify the change (read-back unavailable)")
        }
    }

    /// Notes compose (a degraded Resume can produce two distinct caveats in one action).
    private func appendNote(_ note: String) {
        engineNote = engineNote.map { "\($0); \(note)" } ?? note
    }

    /// One Set invocation with S-N4 failure routing. Retries (at most one, only when the
    /// shared budget allows) apply ONLY to plain nonzero exits — timeouts/blocks/missing are
    /// never auto-retried (sec 2). Returns whether the retry was consumed.
    private func runSetShortcut(_ target: Int, now: TimeInterval,
                                allowRetry: Bool) async -> (ok: Bool, retried: Bool, status: CommandStatus) {
        let name = ChargeShortcuts.setName(for: target)
        var retried = false
        var outcome = await runner.run(name: name, outputPath: nil)
        if case .failed = outcome, allowRetry {
            retried = true
            outcome = await runner.run(name: name, outputPath: nil)   // the single retry
        }
        // The status is the SAME value handed to confirm.commandFailed — surfaced so issueSet can wrap
        // it in CommandOutcome.issueFailed without re-deriving the taxon (keystone: one failure vocabulary).
        let failure: CommandStatus
        switch outcome {
        case .success:
            return (true, retried, .idle)
        case .missingShortcut:
            failure = .setupRequired
        case .automationBlocked:
            failure = .error(.automationBlocked)
        case .shortcutsBinaryAbsent:
            failure = .error(.shortcutsBinaryAbsent)
        case .failed(let code, _):
            failure = .error(.nonzeroExit(code: code))
        case .launchFailed:
            failure = .error(.launchFailed)
        }
        confirm.commandFailed(failure, at: now)
        return (false, retried, failure)
    }
}
