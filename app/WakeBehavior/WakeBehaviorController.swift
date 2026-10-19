import Foundation
import Combine
import Shared

// MARK: - read-back reader seam

/// Read-back seam: supplies the current per-source wake-behavior State, or nil if unreadable.
/// Production spawns `pmset -g custom`; tests inject a fake. Mirrors SleepScheduleReading.
protocol WakeBehaviorReading: Sendable {
    func readCurrent() -> WakeBehaviorReadback.State?
}

/// Production reader: `pmset -g custom` (read-only, non-privileged; no helper) parsed via the
/// Stage 2a WakeBehaviorReadback.parse. The caller runs this off the main thread (the child blocks).
/// nil on a spawn failure, a timeout, a non-zero exit, or a decode failure. Mirrors
/// LivePmsetScheduleReader exactly; only the arguments and the parser differ.
///
/// AUDIT B6: bounded + fully drained via `PmsetProbe.run` — the hand-rolled spawn this replaces left
/// `standardError` unread, which is what could wedge the child and latch `readInFlight` forever.
struct LivePmsetCustomReader: WakeBehaviorReading {
    func readCurrent() -> WakeBehaviorReadback.State? {
        let outcome = PmsetProbe.run(["-g", "custom"])
        guard outcome.succeeded, let output = outcome.stdout else { return nil }
        return WakeBehaviorReadback.parse(output)
    }
}

// MARK: - the privileged-set seam (mirrors SleepWakeSetter; HelperClient conforms)

/// The one privileged call the controller drives, seamed for tests (the production conformance is
/// HelperClient, which marshals the reply to the main actor). `@MainActor` + the `@Sendable`
/// completion mirror SleepWakeSetter exactly.
@MainActor
protocol WakeBehaviorSetter {
    func setWakeBehavior(powerNapBattery: Bool,
                         powerNapAC: Bool,
                         wakeOnNetworkBattery: Bool,
                         wakeOnNetworkAC: Bool,
                         completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void)
}

// MARK: - controller

/// Sprint 3.7 (power-nap / wake-for-network) STAGE 2b-i: the app-side controller. SIMPLER than the
/// sleep/wake sibling — no Apply confirm, no ApplyDecision, no persistence/store: the four values are
/// plain booleans (no foreign-authorship question), and the live `pmset -g custom` state is the single
/// source of truth (re-read after every apply). @MainActor ObservableObject; the helper reply is
/// marshaled to main (assumeIsolated) and the pmset read runs off-main with a pile-up guard (mirrors
/// SleepWakeScheduleController.refreshReadback).
@MainActor
final class WakeBehaviorController: ObservableObject {

    /// The outcome of the most recent apply, for the status line.
    enum ApplyStatus: Equatable {
        case idle
        case applying
        case applied
        /// AUDIT hand-off 3. The helper reported success and NOTHING has confirmed it since. Split out
        /// of `.applied` because the two were rendering identically — which is this project's most
        /// repeated defect, and the third one found in this shape today (`8c2cbe4`'s missing witness
        /// that counted as an agreeing one; `f69f1d1`'s silent spawn failure). `.applied` now means
        /// "the helper said yes AND a read taken afterwards showed the live truth"; this case means
        /// only the first half. It is not a failure and is not rendered as one.
        case appliedUnverified
        case failed(String)   // a helper error token
        case unreachable
    }

    // Placeholders matching Apple's live defaults; the first refreshReadback() snaps them to truth.
    @Published var powerNap: WakeBehaviorReadback.Scope = .always
    @Published var wakeOnNetwork: WakeBehaviorReadback.Scope = .onPowerAdapter
    @Published private(set) var lastReadback: WakeBehaviorReadback.State?
    @Published private(set) var lastApplyStatus: ApplyStatus = .idle

    private let setter: any WakeBehaviorSetter
    private let reader: any WakeBehaviorReading
    private let monotonicNow: () -> TimeInterval
    /// AUDIT B6. Was a bare `readInFlight` Bool set at kickoff and cleared only by the completion — so
    /// one wedged `pmset` child froze the read-back for the life of the process. The gate keeps the
    /// pile-up guard and adds the way back (see `BoundedReadGate`).
    private var readGate = BoundedReadGate()

    /// AUDIT hand-off 3 — the post-apply verification. The first read TOKEN that can count as evidence
    /// about the apply now awaiting confirmation, or nil when none is. Armed on a helper success and
    /// cleared only by a read that actually returned live state.
    ///
    /// A token rather than a bool because the read that confirms must have BEGUN at or after the apply.
    /// `refreshReadback` can be refused by `BoundedReadGate` when a read started BEFORE the apply is
    /// still in flight; that read's answer describes the machine as it was before the write, so
    /// accepting it would be the same lie by another route.
    private var verifyFromToken: Int?
    /// The last token this controller was issued by its own gate. The gate is private and
    /// `refreshReadback` is its only `begin` call site, so the numbering is entirely ours and the NEXT
    /// token is always this + 1 — which is what a refused post-apply read has to arm against.
    private var lastIssuedToken = 0

    // Monotonic edit generation. Each user-driven picker change bumps it; a read or an apply captures the
    // value at kickoff and, on return, syncs the pickers to live truth ONLY if the generation is unchanged
    // (no edit landed since kickoff). Replaces a cleared-at-read-start boolean whose correctness relied on
    // the off-main read happening to yield the main actor between the clear and the return — one refactor
    // from silently reverting to always-adopt. A captured-generation compare is order-independent AND lets
    // the post-apply re-read preserve an edit made DURING the apply (which the cleared boolean forgot).
    private(set) var editGeneration = 0

    init(setter: any WakeBehaviorSetter,
         reader: any WakeBehaviorReading = LivePmsetCustomReader(),
         monotonicNow: @escaping () -> TimeInterval = MonitorTime.monotonicNow) {
        self.setter = setter
        self.reader = reader
        self.monotonicNow = monotonicNow
    }

    /// The four booleans implied by the current two scope selections, in protocol order.
    func currentBools() -> (powerNapBattery: Bool, powerNapAC: Bool,
                            wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool) {
        let pn = WakeBehaviorReadback.bools(for: powerNap)
        let wn = WakeBehaviorReadback.bools(for: wakeOnNetwork)
        return (pn.battery, pn.ac, wn.battery, wn.ac)
    }

    /// User-driven picker changes route here (the SwiftUI bindings call these), distinct from adopt's
    /// programmatic sync. Marking the edit lets a read returning mid-edit avoid reverting the picker.
    func setPowerNap(_ scope: WakeBehaviorReadback.Scope) {
        powerNap = scope
        editGeneration &+= 1          // &+ : monotonic, wrap-safe (a wrap is astronomically unreachable)
    }
    func setWakeOnNetwork(_ scope: WakeBehaviorReadback.Scope) {
        wakeOnNetwork = scope
        editGeneration &+= 1
    }

    /// Set lastReadback and, when the read succeeded, snap each picker to the scope matching the live
    /// per-source truth. A nil read leaves the pickers untouched (we do not guess).
    func adopt(_ state: WakeBehaviorReadback.State?) {
        lastReadback = state
        guard let s = state else { return }
        powerNap = WakeBehaviorReadback.scope(battery: s.powerNapBattery, ac: s.powerNapAC)
        wakeOnNetwork = WakeBehaviorReadback.scope(battery: s.wakeOnNetworkBattery, ac: s.wakeOnNetworkAC)
    }

    /// Decide what a completed read/apply does, given the edit generation captured at its kickoff: if the
    /// user has edited since (the live generation advanced), refresh only the read-back line and keep the
    /// in-progress picker edit; otherwise it is safe to sync the pickers to the live truth. Split out so
    /// the decision is unit-testable without the async wrappers.
    func applyReadResult(_ state: WakeBehaviorReadback.State?, readGeneration: Int) {
        if editGeneration != readGeneration {
            lastReadback = state          // an edit landed since kickoff — keep the picker, refresh the line
        } else {
            adopt(state)
        }
    }

    /// Read `pmset -g custom` off the main thread and sync the result on main (nil on a read failure).
    /// Guarded against pile-up. `sinceGeneration`: when non-nil, the returning read syncs the pickers only
    /// if no edit landed since THAT generation — used by the post-apply re-read, which must honor an edit
    /// made while the apply was in flight (else it reverts it). When nil (the plain on-open read), capture
    /// the current generation at kickoff. Mirrors SleepWakeScheduleController.refreshReadback's idiom.
    ///
    /// Returns the gate token the read claimed, or nil when the gate refused it (a read is genuinely
    /// in flight). Only `handleReply` uses the return value — every other caller discards it.
    @discardableResult
    func refreshReadback(sinceGeneration: Int? = nil) -> Int? {
        guard let token = readGate.begin(now: monotonicNow()) else { return nil }
        lastIssuedToken = token
        let gen = sinceGeneration ?? editGeneration     // capture at kickoff; never reset
        let reader = self.reader                         // capture the (Sendable) read seam on the main actor for the off-main read
        DispatchQueue.global(qos: .utility).async {
            let state = reader.readCurrent()
            Task { @MainActor in
                self.settleReadback(token: token, state: state, readGeneration: gen)
            }
        }
        return token
    }

    /// AUDIT B6 — the ONE settle path. A completion whose read was already reclaimed as wedged loses
    /// the gate and does nothing: it must not clobber the newer read that replaced it.
    func settleReadback(token: Int, state: WakeBehaviorReadback.State?, readGeneration: Int) {
        guard readGate.settle(token) else { return }
        applyReadResult(state, readGeneration: readGeneration)
        guard let outcome = Self.resolveVerification(settledToken: token,
                                                     verifyFromToken: verifyFromToken,
                                                     readSucceeded: state != nil) else { return }
        lastApplyStatus = outcome.status
        if !outcome.stayArmed { verifyFromToken = nil }
    }

    /// PURE. What a settling read-back does to a pending post-apply verification, or nil when the
    /// settle is not evidence about one — an ordinary on-open read, or a read that BEGAN before the
    /// apply did. Tokens are issued monotonically by this controller's own gate, so "at or after the
    /// apply" is a comparison.
    ///
    /// ⚠️ NO RETRY, and this is a hard constraint with a machine-checked reason. The read behind this
    /// sits inside `BoundedReadGate` (`staleAfterSeconds` = 10) while `PmsetProbe.RetryPolicy
    /// .onceIfCutShort` worst-cases at 17 s — `PmsetProbe.worstCaseSeconds` is pure and a test asserts
    /// that ordering — so a gated caller that retried would reclaim its OWN read mid-retry and spawn a
    /// third child, which is exactly the pile-up the gate exists to prevent. The recovery here is
    /// verify-the-effect: say what was actually confirmed, and stay ARMED so the next read the app was
    /// going to take anyway (the Automation tab's own on-open refresh) lifts the caveat for free.
    static func resolveVerification(settledToken: Int,
                                    verifyFromToken: Int?,
                                    readSucceeded: Bool) -> (status: ApplyStatus, stayArmed: Bool)? {
        guard let from = verifyFromToken, settledToken >= from else { return nil }
        return readSucceeded ? (.applied, false) : (.appliedUnverified, true)
    }

    /// Apply the current selections through the helper, then re-read to show the live truth. Mirrors
    /// SleepWakeScheduleController.apply()/handleReply for the closure annotations and error coverage.
    func apply() {
        lastApplyStatus = .applying
        verifyFromToken = nil           // a new write supersedes any verification still armed for the last one
        let gen = editGeneration        // capture alongside the bools we commit; the post-apply re-read
        let b = currentBools()          // compares against THIS, so an edit during the apply is not reverted
        setter.setWakeBehavior(powerNapBattery: b.powerNapBattery,
                               powerNapAC: b.powerNapAC,
                               wakeOnNetworkBattery: b.wakeOnNetworkBattery,
                               wakeOnNetworkAC: b.wakeOnNetworkAC) { [weak self] result in
            MainActor.assumeIsolated { self?.handleReply(result, appliedGeneration: gen) }
        }
    }

    private func handleReply(_ result: Result<String, HelperClientError>, appliedGeneration: Int) {
        var helperSaidYes = false
        switch result {
        case .success:
            lastApplyStatus = .applied
            helperSaidYes = true
        case .failure(.unreachable):
            lastApplyStatus = .unreachable
        case .failure(.helperError(let token)):
            // AUDIT B8, the other direction: the helper's 250 ms apply cooldown is shared across
            // setWakeBehavior AND setRepeatingSleepWake, so applying the two back-to-back rejects the
            // second with `error:cooldown`. That means "this call made no change" — NOT that the
            // operation failed — and reporting it as a failure tells the user a successful apply
            // broke. Leave the prior status alone; the read-back below is the source of truth.
            if token == SleepWakeCommand.errCooldown {
                if lastApplyStatus == .applying { lastApplyStatus = .idle }
            } else {
                lastApplyStatus = .failed(token)
            }
        }
        let token = refreshReadback(sinceGeneration: appliedGeneration)   // honor an edit made during the apply
        guard helperSaidYes else { return }
        // AUDIT hand-off 3. This read is the ONLY thing that can turn "the helper accepted the call"
        // into "the machine actually reads that way", so arm it as the verification. If the gate
        // refused it, no post-apply read ran at all — `lastReadback` is still describing the machine
        // BEFORE the write — so say so now and arm the NEXT read instead.
        if let token {
            verifyFromToken = token
        } else {
            verifyFromToken = lastIssuedToken + 1
            lastApplyStatus = .appliedUnverified
        }
    }
}
