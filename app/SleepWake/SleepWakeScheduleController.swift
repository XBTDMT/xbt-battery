import Foundation
import Combine

// MARK: - read-back reader seam

/// Seam over the `pmset -g sched` read (mirrors EnergyModeReading). Production spawns pmset; tests
/// inject a fake. Returns nil on a read FAILURE (spawn / non-zero exit / decode), distinct from an
/// empty schedule: an empty read means "no repeating events" (isAuthored treats that as vacuously
/// ours), but a read failure must NOT be read as empty, or should-fix 5's confirm would be skipped on
/// a schedule we never saw. So nil means "cannot verify authorship" and the controller requires the confirm.
protocol SleepScheduleReading {
    func readRepeatingSchedule() -> RepeatingSchedule?
}

/// Production reader: spawn `pmset -g sched` (read-only, non-privileged; no helper) and parse via the
/// Stage 2a SleepWakeReadback.parse. The caller runs this off the main thread (the child blocks). nil
/// on a spawn failure, a non-zero exit, or a decode failure.
/// AUDIT B6: bounded + fully drained via `PmsetProbe.run` — the hand-rolled spawn this replaces left
/// `standardError` unread, which is what could wedge the child and latch `readInFlight` forever.
struct LivePmsetScheduleReader: SleepScheduleReading {
    func readRepeatingSchedule() -> RepeatingSchedule? {
        let outcome = PmsetProbe.run(["-g", "sched"])
        guard outcome.succeeded, let output = outcome.stdout else { return nil }
        return SleepWakeReadback.parse(output)
    }
}

// MARK: - the privileged-set seam (mirrors EnergyModeSetter; HelperClient conforms)

/// The one privileged call the controller drives, seamed for tests (the production conformance is
/// HelperClient, which marshals the reply to the main actor). Mirrors EnergyModeSetter.
@MainActor
protocol SleepWakeSetter {
    func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                               wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int,
                               completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void)
}

// MARK: - persistence (UserDefaults — app container, S-N6-clean)

/// AUDIT hand-off H3 — the three states of the STORED config. `.unreadable` is not `.none`.
///
/// `loadConfig()` used to be `(try? decode(...)) ?? .empty`, which made a stored config that will not
/// decode identical to a user who never set a schedule. The `??` is not the tell; the DIRECTION of the
/// resulting claim is. Holding `.empty` (both sides off, `isCancel == true`), the app goes on to assert
/// two things it cannot support: the read-back line calls the live schedule FOREIGN ("This app didn't
/// set this schedule, and its own settings say the feature is off") and offers to remove it, and the
/// destructive confirm repeats that claim. Then the first edit overwrites the undecodable blob with
/// defaults, and the real stored schedule is gone with no cue anywhere.
///
/// Same discipline as `ConfirmReason` below, `RawCorroboration`, and the `temperatureReading` row:
/// "we could not read it" is its own state and is never folded into a verdict.
enum SleepWakeConfigLoad: Equatable {
    /// Nothing has ever been stored — the honest empty. The feature is genuinely off.
    case none
    case config(SleepWakeScheduleConfig)
    /// Something is stored and it would not decode. We know nothing about the user's schedule.
    case unreadable

    /// The config to EDIT from. `.empty` is a fine starting point in all three states; what must not
    /// travel with it is the false confidence that the user chose it.
    var configOrEmpty: SleepWakeScheduleConfig {
        if case .config(let c) = self { return c }
        return .empty
    }

    var isUnreadable: Bool { self == .unreadable }
}

protocol SleepWakeScheduleStoring {
    /// H3: the read that can say "I could not read it". Conformances that predate the split get the
    /// default below, which reports what they have — they have no failure to express.
    func loadConfigDetailed() -> SleepWakeConfigLoad
    func loadConfig() -> SleepWakeScheduleConfig
    func saveConfig(_ c: SleepWakeScheduleConfig)
    /// Redman sweep item 3: MOVE an unreadable stored config aside (never delete it). A no-op when the
    /// stored config is readable or absent.
    func setAsideUnreadableConfig()
}

extension SleepWakeScheduleStoring {
    func loadConfigDetailed() -> SleepWakeConfigLoad { .config(loadConfig()) }
    /// No decode step, so nothing can be unreadable — nothing to set aside.
    func setAsideUnreadableConfig() {}
}

struct UserDefaultsSleepWakeStore: SleepWakeScheduleStoring {
    private static let configKey = "sleepWakeSchedule.config.v1"

    /// Test seam ONLY — a named suite so the real store can be driven over real bytes. `nil` =
    /// `UserDefaults.standard`, the production path.
    private let suiteName: String?
    private var defaults: UserDefaults {
        guard let suiteName, let d = UserDefaults(suiteName: suiteName) else { return .standard }
        return d
    }
    init(suiteName: String? = nil) { self.suiteName = suiteName }

    /// PURE. The decode, split from the `UserDefaults` read so the three-state is testable without
    /// touching the process-wide standard defaults.
    static func decode(_ data: Data?) -> SleepWakeConfigLoad {
        guard let data else { return .none }
        guard let c = try? JSONDecoder().decode(SleepWakeScheduleConfig.self, from: data) else {
            return .unreadable
        }
        return .config(c)
    }

    func loadConfigDetailed() -> SleepWakeConfigLoad {
        // Final review F6: a value of the wrong type is not "nothing stored".
        if defaults.data(forKey: Self.configKey) == nil, defaults.object(forKey: Self.configKey) != nil {
            return .unreadable
        }
        return Self.decode(defaults.data(forKey: Self.configKey))
    }
    func loadConfig() -> SleepWakeScheduleConfig { loadConfigDetailed().configOrEmpty }
    /// Redman sweep item 3 — defence in depth: never replace bytes that are present but will not decode.
    func saveConfig(_ c: SleepWakeScheduleConfig) {
        if loadConfigDetailed().isUnreadable {
            NSLog("battery_app: sleep/wake schedule save REFUSED — the stored config (%@) will not decode "
                  + "and is not overwritten.", Self.configKey)
            return
        }
        if let data = try? JSONEncoder().encode(c) { defaults.set(data, forKey: Self.configKey) }
    }
    /// Copy the unreadable bytes to a dated key, verify the copy, then remove the original.
    func setAsideUnreadableConfig() {
        // F6: moves whatever is stored (bytes, or a value of the wrong type), not only `Data`.
        guard loadConfigDetailed().isUnreadable, let stored = defaults.object(forKey: Self.configKey) else { return }
        let asideKey = "\(Self.configKey).unreadable.\(Int(Date().timeIntervalSince1970))"
        defaults.set(stored, forKey: asideKey)
        guard let kept = defaults.object(forKey: asideKey) as? NSObject, kept.isEqual(stored) else { return }   // never remove what was not kept
        defaults.removeObject(forKey: Self.configKey)
        NSLog("battery_app: unreadable sleep/wake config set aside under %@ (value kept as-is).", asideKey)
    }
}

// MARK: - controller

/// Sprint 3.7 (sleep/wake) STAGE 2b: the app-side controller. A PROGRAM-ONCE controller, NOT a
/// timer-driven runner: we call the privileged op once and pmset owns the recurrence (no pacer, no
/// fire loop). Structurally this is setEnergyMode (a one-shot write) plus EnergyModeReader (an on-open
/// read). @MainActor ObservableObject; the helper reply is marshaled to main (assumeIsolated) and the
/// pmset read runs off-main with a pile-up guard (mirrors BatteryMonitor.refreshEnergyMode).
@MainActor
final class SleepWakeScheduleController: ObservableObject {

    /// The apply readiness decision — a pure function of (config, read-back).
    enum ApplyDecision: Equatable {
        case blocked        // config invalid; the UI prevents reaching apply
        case ready          // safe to apply with no confirm
        case needsConfirm   // a foreign or unverifiable schedule is present (should-fix 5)
    }

    /// AUDIT hand-off 4 — WHY a confirm is being asked for. The safe bias is unchanged and correct:
    /// `pmset repeat cancel` clears the ENTIRE repeating schedule, so confirming when authorship is
    /// unknown is right. What was missing is the reason, and the two reasons are NOT the same fact —
    /// the dialog stated only the first of them, which on a failed read is not a caveat but a claim we
    /// cannot support ("a repeating schedule is set that this app didn't create" — we do not know that
    /// a schedule is set at all). Same three-state discipline as `RawCorroboration` and the
    /// `temperatureReading` row: "we could not read it" is its own state, never folded into a verdict.
    enum ConfirmReason: Equatable {
        /// The read worked and the live schedule is not ours.
        case foreignSchedule
        /// The `pmset -g sched` read did not come back, so nothing is known about the live schedule.
        case scheduleUnreadable
        /// H3. The live schedule WAS read, but this app's own stored config would not decode — so the
        /// authorship comparison has no left-hand side. Calling the schedule "foreign" here would be a
        /// claim about who set it, drawn from a config we could not read.
        case configUnreadable

        /// The sentence shown above the Apply confirm. Says the fact and then the consequence.
        var applyMessage: String {
            switch self {
            case .foreignSchedule:
                return "A repeating schedule is set that this app didn't create. Applying replaces it."
            case .scheduleUnreadable:
                return "The current schedule couldn't be read, so whether one is set — and who set it — "
                     + "is unknown. Applying replaces whatever is there."
            case .configUnreadable:
                return "Battery couldn't read its own saved schedule settings, so it can't tell whether "
                     + "the schedule on this Mac is one it set. Applying replaces it."
            }
        }

        /// The sentence shown above the Turn-off confirm. Same fact, different consequence.
        var cancelMessage: String {
            switch self {
            case .foreignSchedule:
                return "A repeating schedule is set that this app didn't create. Turning it off removes it."
            case .scheduleUnreadable:
                return "The current schedule couldn't be read, so whether one is set — and who set it — "
                     + "is unknown. Turning it off removes whatever is there."
            case .configUnreadable:
                return "Battery couldn't read its own saved schedule settings, so it can't tell whether "
                     + "the schedule on this Mac is one it set. Turning it off removes it."
            }
        }
    }

    /// The outcome of the most recent apply / cancel, for the status line.
    enum ApplyStatus: Equatable {
        case idle, applying, applied
        /// The e498c86 sibling. The helper reported success and NOTHING has confirmed it since.
        /// `.applied` now means "the helper said yes AND a read taken afterwards showed the live
        /// truth"; this case means only the first half. It is not a failure and is not rendered as one.
        case appliedUnverified
        case failed(String)   // a helper error token
        case unreachable
    }

    @Published private(set) var config: SleepWakeScheduleConfig
    /// H3. The stored config would not decode, so `config` below is a DEFAULT, not the user's. Drives
    /// the Automation tab's note and suppresses the foreign-authorship claim (see `confirmReason`).
    @Published private(set) var configUnreadable: Bool
    @Published private(set) var lastReadback: RepeatingSchedule?
    @Published private(set) var lastApplyStatus: ApplyStatus = .idle

    private let setter: any SleepWakeSetter
    private let reader: any SleepScheduleReading
    private let store: any SleepWakeScheduleStoring
    private let monotonicNow: () -> TimeInterval
    /// AUDIT B6. Was a bare `readInFlight` Bool set at kickoff and cleared only by the completion — so
    /// one wedged `pmset` child froze the read-back for the life of the process, and a frozen read-back
    /// is not cosmetic here: `applyDecision`/`cancelNeedsConfirm` treat a nil read-back as
    /// "cannot verify authorship" and force the confirm on every apply and cancel, forever.
    private var readGate = BoundedReadGate()

    /// Audit B8. The status to restore when a reply says THIS call changed nothing (`error:cooldown`).
    /// Captured at every apply/cancel kickoff, alongside setting `.applying`. It can never itself be
    /// `.applying`: the in-flight guard refuses to start a second call while one is outstanding.
    private var statusBeforeApply: ApplyStatus = .idle

    /// The e498c86 sibling — the post-apply verification. The first read TOKEN that can count as
    /// evidence about the apply now awaiting confirmation, or nil when none is.
    ///
    /// A token rather than a bool because the read that confirms must have BEGUN at or after the
    /// apply. `refreshReadback` can be refused by `BoundedReadGate` when a read started BEFORE the
    /// apply is still in flight; that read's answer describes the machine as it was before the write,
    /// so accepting it would be the same lie by another route.
    private var verifyFromToken: Int?
    /// The last token this controller was issued by its own gate. The gate is private and
    /// `refreshReadback` is its only `begin` call site, so the numbering is entirely ours and the NEXT
    /// token is always this + 1 — which is what a REFUSED post-apply read has to arm against.
    private var lastIssuedToken = 0

    /// Audit B8. A privileged apply/cancel is outstanding iff the status is `.applying` — the status is
    /// set to `.applying` only at kickoff and moved off it only by `handleReply`, and HelperClient
    /// guarantees exactly one reply per call (its XPC error handler replies `.unreachable`). This is the
    /// same predicate the wake-behaviour surface disables its Apply button on
    /// (`.disabled(wakeBehavior.lastApplyStatus == .applying)`), held HERE rather than in the view so the
    /// non-button callers (the confirm path, the uninstall bridge) are covered by the same gate.
    var isApplyInFlight: Bool { lastApplyStatus == .applying }

    init(setter: any SleepWakeSetter,
         reader: any SleepScheduleReading = LivePmsetScheduleReader(),
         store: any SleepWakeScheduleStoring = UserDefaultsSleepWakeStore(),
         monotonicNow: @escaping () -> TimeInterval = MonitorTime.monotonicNow) {
        self.setter = setter
        self.reader = reader
        self.store = store
        self.monotonicNow = monotonicNow
        let loaded = store.loadConfigDetailed()
        self.config = loaded.configOrEmpty
        self.configUnreadable = loaded.isUnreadable
    }

    // MARK: edit API (saves the config; does NOT apply — applying is an explicit user action)

    func setSleepEnabled(_ on: Bool) { mutate { $0.sleepEnabled = on } }
    func setSleepTime(hour: Int, minute: Int) { mutate { $0.sleepHour = hour; $0.sleepMinute = minute } }
    func setWakeEnabled(_ on: Bool) { mutate { $0.wakeEnabled = on } }
    func setWakeTime(hour: Int, minute: Int) { mutate { $0.wakeHour = hour; $0.wakeMinute = minute } }
    func setWeekdayMask(_ mask: Int) { mutate { $0.weekdayMask = mask } }

    /// Flip a single weekday bit (bit0=Mon..bit6=Sun) for the day-chip UI. Out-of-range is a no-op.
    func toggleWeekday(bit: Int) {
        guard (0...6).contains(bit) else { return }
        mutate { $0.weekdayMask ^= (1 << bit) }
    }

    private func mutate(_ change: (inout SleepWakeScheduleConfig) -> Void) {
        var c = config
        change(&c)
        config = c
        // Redman sweep item 3: while the stored config is unreadable, an edit changes the fields IN
        // MEMORY (the shipped copy tells the user to "set the times and apply to take it over") but is
        // NOT saved over the blob. Unlike the charge schedule, this config drives nothing on its own —
        // it only matters on an explicit Apply — so editing in memory is safe. The blob is moved aside
        // (kept) and the config saved only when an apply SUCCEEDS (`handleReply`).
        guard !configUnreadable else {
            NSLog("battery_app: sleep/wake edit kept in memory only — the stored config will not decode "
                  + "and is not overwritten until an apply succeeds.")
            return
        }
        store.saveConfig(c)
    }

    // MARK: read-back (off-main pmset read; mirrors BatteryMonitor.refreshEnergyMode)

    /// Read `pmset -g sched` off the main thread and publish the result (nil on a read failure).
    /// Guarded against pile-up so rapid popover toggling can't stack pmset spawns.
    ///
    /// Returns the gate token the read claimed, or nil when the gate REFUSED it (a read is genuinely
    /// in flight). Only `handleReply` uses the return value — every other caller discards it.
    @discardableResult
    func refreshReadback() -> Int? {
        guard let token = readGate.begin(now: monotonicNow()) else { return nil }
        lastIssuedToken = token
        DispatchQueue.global(qos: .utility).async {
            let result = self.reader.readRepeatingSchedule()
            Task { @MainActor in
                self.settleReadback(token: token, result: result)
            }
        }
        return token
    }

    /// AUDIT B6 — the ONE settle path. A completion whose read was already reclaimed as wedged loses
    /// the gate and does nothing: it must not clobber the newer read that replaced it.
    func settleReadback(token: Int, result: RepeatingSchedule?) {
        guard readGate.settle(token) else { return }
        lastReadback = result
        guard let outcome = Self.resolveVerification(settledToken: token,
                                                     verifyFromToken: verifyFromToken,
                                                     readSucceeded: result != nil) else { return }
        lastApplyStatus = outcome.status
        if !outcome.stayArmed { verifyFromToken = nil }
    }

    /// PURE. What a settling read-back does to a pending post-apply verification, or nil when the
    /// settle is not evidence about one — an ordinary on-open read, or a read that BEGAN before the
    /// apply did. Tokens are issued monotonically by this controller's own gate, so "at or after the
    /// apply" is a comparison. Mirrors `WakeBehaviorController.resolveVerification` exactly.
    ///
    /// ⚠️ NO RETRY, and this is a hard constraint with a machine-checked reason. The read behind this
    /// sits inside `BoundedReadGate` (`staleAfterSeconds` = 10) while `PmsetProbe.RetryPolicy
    /// .onceIfCutShort` worst-cases at 17 s — `PmsetProbe.worstCaseSeconds` is pure and a test asserts
    /// that ordering — so a gated caller that retried would reclaim its OWN read mid-retry and spawn a
    /// third child. The recovery is verify-the-effect: say what was actually confirmed, and stay ARMED
    /// so the next read the app was going to take anyway (the Automation tab's on-open refresh) lifts
    /// the caveat for free.
    static func resolveVerification(settledToken: Int,
                                    verifyFromToken: Int?,
                                    readSucceeded: Bool) -> (status: ApplyStatus, stayArmed: Bool)? {
        guard let from = verifyFromToken, settledToken >= from else { return nil }
        return readSucceeded ? (.applied, false) : (.appliedUnverified, true)
    }

    // MARK: decisions (pure, testable)

    /// AUDIT hand-off 4 — THE gate predicate. nil when no confirm is required; otherwise the reason,
    /// so the branch that fires the dialog and the sentence the dialog shows can never disagree.
    /// `applyDecision` and `cancelNeedsConfirm` are now two views of this one fact rather than two
    /// re-derivations of it. A nil read-back is `.scheduleUnreadable` — the safe bias, unchanged.
    func confirmReason(for readback: RepeatingSchedule?) -> ConfirmReason? {
        guard let readback else { return .scheduleUnreadable }
        // Nothing scheduled is nothing to clobber — true whatever our own config says, and the answer
        // `isAuthored` already gives for an empty read-back. Hoisted so the H3 branch below cannot
        // manufacture a confirm where there was none.
        if readback.events.isEmpty { return nil }
        // H3. The authorship comparison needs OUR config as its left-hand side. If that could not be
        // read, the honest answer is that we cannot tell — never "this app didn't create it".
        if configUnreadable { return .configUnreadable }
        return SleepWakeReadback.isAuthored(by: config, matching: readback) ? nil : .foreignSchedule
    }

    /// The apply readiness against a given read-back. .blocked if the config is invalid; .needsConfirm
    /// if the read-back is nil (read failed / not yet read, so we cannot verify — the safe bias) or
    /// foreign; .ready if the current schedule is empty or recognizably ours.
    func applyDecision(for readback: RepeatingSchedule?) -> ApplyDecision {
        guard config.isValid else { return .blocked }
        return confirmReason(for: readback) == nil ? .ready : .needsConfirm
    }

    /// Whether a cancel must confirm first: pmset repeat cancel clears the ENTIRE repeating schedule,
    /// ours or not, so a foreign or unverifiable schedule takes the same gate as apply. Config validity
    /// is irrelevant to a cancel (we are clearing).
    func cancelNeedsConfirm(for readback: RepeatingSchedule?) -> Bool {
        confirmReason(for: readback) != nil
    }

    // MARK: apply / cancel (program-once; pmset owns the recurrence after this)

    /// Apply the current config via the privileged op. If the decision needs a confirm and the caller
    /// has not confirmed, this is a no-op (the view shows the confirm first).
    func apply(confirmed: Bool) {
        guard !isApplyInFlight else { return }   // B8: no second submission while one is outstanding
        if applyDecision(for: lastReadback) == .needsConfirm && !confirmed { return }
        let c = config
        beginApply()
        setter.setRepeatingSleepWake(
            sleepEnabled: c.sleepEnabled, sleepHour: c.sleepHour, sleepMinute: c.sleepMinute,
            wakeEnabled: c.wakeEnabled, wakeHour: c.wakeHour, wakeMinute: c.wakeMinute,
            weekdayMask: c.weekdayMask) { [weak self] result in
            MainActor.assumeIsolated { self?.handleReply(result) }
        }
    }

    /// Turn the schedule off (a cancel). The helper maps an all-disabled config to pmset repeat cancel.
    /// Same authorship gate as apply. We send the all-disabled request and disable the config only on a
    /// success reply (a failed cancel leaves the config matching the still-present schedule, like apply).
    func cancel(confirmed: Bool) {
        guard !isApplyInFlight else { return }   // B8: shares the gate with apply — one privileged op at a time
        if cancelNeedsConfirm(for: lastReadback) && !confirmed { return }
        let c = config
        beginApply()
        setter.setRepeatingSleepWake(
            sleepEnabled: false, sleepHour: c.sleepHour, sleepMinute: c.sleepMinute,
            wakeEnabled: false, wakeHour: c.wakeHour, wakeMinute: c.wakeMinute,
            weekdayMask: c.weekdayMask) { [weak self] result in
            MainActor.assumeIsolated {
                if case .success = result {
                    self?.mutate { $0.sleepEnabled = false; $0.wakeEnabled = false }
                }
                self?.handleReply(result)
            }
        }
    }

    /// Enter the in-flight state, remembering the status to fall back to if the reply turns out to be a
    /// no-change rejection. Both entry points go through this so the two stay in lockstep.
    private func beginApply() {
        statusBeforeApply = lastApplyStatus
        lastApplyStatus = .applying
        verifyFromToken = nil   // a new write supersedes any verification still armed for the last one
    }

    private func handleReply(_ result: Result<String, HelperClientError>) {
        var helperSaidYes = false
        switch result {
        case .success:
            lastApplyStatus = .applied
            helperSaidYes = true
            // H3. The flag means "the app's record of what it set is lost", and an EDIT does not end
            // that — the live schedule is still one it cannot account for, so the foreign-authorship
            // claim must stay suppressed. A successful apply/cancel DOES end it: the app has just
            // written the schedule, so its config describes it again.
            // Redman sweep item 3: that apply is also the user's explicit act of taking the schedule
            // over, so it is the one moment the unreadable stored config may be replaced — and even
            // then its bytes are MOVED aside (kept under a dated key), never written over. The edits
            // made since were held in memory; they are saved now. (On the cancel path `mutate` has
            // already run with the flag up, so the disabled sides are saved here too.)
            if configUnreadable {
                store.setAsideUnreadableConfig()
                // Final review F5: the flag comes from a RE-READ, never an assumption — if the set-aside
                // did not take, the blob is still on the live key, still unreadable, and must not be
                // saved over (the edits stay in memory; the store would refuse anyway).
                configUnreadable = store.loadConfigDetailed().isUnreadable
                if !configUnreadable { store.saveConfig(config) }
                else {
                    NSLog("battery_app: sleep/wake apply succeeded but the unreadable saved config could not "
                          + "be set aside — the applied settings are not saved.")
                }
            }
        case .failure(.unreachable):
            lastApplyStatus = .unreachable
        case .failure(.helperError(let token)) where SleepWakeReply.isNoChangeRejection(token):
            // B8. The helper refused this submission inside its 250 ms apply cooldown — a clock it
            // SHARES with setWakeBehavior — so no `pmset` ran and nothing changed. That is not a
            // failure of the schedule: the call that DID run owns the outcome, so we restore the status
            // as it stood before this one rather than overwriting it with `.failed("error:cooldown")`,
            // which the Settings surface renders as "Schedule change failed" over a schedule that
            // applied. The re-read below still refreshes the live truth either way.
            lastApplyStatus = statusBeforeApply
        case .failure(.helperError(let token)):
            lastApplyStatus = .failed(token)
        }
        let token = refreshReadback()
        guard helperSaidYes else { return }
        // The e498c86 sibling. This read is the ONLY thing that can turn "the helper accepted the
        // call" into "the machine actually reads that way", so arm it as the verification. If the gate
        // REFUSED it, no post-apply read ran at all — `lastReadback` is still describing the machine
        // BEFORE the write — so say so now and arm the NEXT read instead.
        if let token {
            verifyFromToken = token
        } else {
            verifyFromToken = lastIssuedToken + 1
            lastApplyStatus = .appliedUnverified
        }
    }
}
