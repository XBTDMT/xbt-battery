import Foundation
import Combine

/// Seam over the WI-N5 LimitReader for the mid-window / at-resolution external-change checks
/// (Grok B1, normative). Returns `.unknown` in Get-degraded mode — checks impossible, verdicts
/// then carry the standing degraded caveat.
protocol LimitReading: Sendable {
    func readLimit() async -> ChargeLimitValue
}

/// WI-N4: BehaviorConfirm — judges a Set's real-world effect ONLY by InstantAmperage sign +
/// RAW trend over a window (SPEC v4.0 sec 2). Event-driven: windows advance on SAMPLE ARRIVAL
/// (the armed 10 s cadence feeds it); no internal timers, fully deterministic under test.
///
/// Normative behaviors implemented here:
/// - BOTH arming rules: resume-confirm arms ONLY off a pre-Set NCR=0x01000000; stop-confirm
///   arms ONLY when SoC >= the new limit (below it → `.limitSetChargingToCap`).
/// - …but NEVER a `.chargingToCap` window at `target == 100`: with no cap there is no cap-hold
///   reason for macOS to publish, so that window's only clean exit (E1, `state == .limitHold`) is
///   unreachable and it could only decay. `.requestedNoCapToHold` instead — its OWN case, because
///   `.requestedNoPromise`'s string warns about OBC, which is a false alarm here and would fire on
///   every Top Up (`TopUpController` sets 100 every time). The other two windows are
///   unaffected at that target — they judge by amperage + RAW trend and never consult the hold bit.
/// - `.limitSetChargingToCap` lifecycle: RESOLVES to `.confirmedStop` on an observed limit-hold;
///   CLEARS to `.idle` on unplug / external change / supersede; 15-min TTL DECAYS to
///   `.confirmInconclusive(noCleanHoldObserved)` when the cap is reached with no flow and no
///   0x01000000 — it never persists stale. That TTL is CONDITIONAL on being at/past the target,
///   so it is backed by an UNCONDITIONAL 2-h wall-clock ceiling on the window (audit B1): a pack
///   parked BELOW the target (OBC holding at 80 against a target of 100) otherwise had no exit
///   at all, pinning the scheduler and the 10 s poll cadence forever.
/// - Wake-aware (S-N5): a >30 s monotonic gap between samples INVALIDATES AND RESTARTS the
///   window; no verdict derives from stale pre-sleep samples.
/// - Mid-window 0x80 while AWAKE → `.confirmInconclusive(systemInhibit)` (a 0x80 arriving on
///   the first sample after a wake gap restarts the window instead — the nap caused it).
/// - External-change abort (Grok B1): LimitReader at window HALF-TIME and AT RESOLUTION; a
///   confirmed verdict publishes only if the read-back still equals the armed target. Mismatch →
///   cancel (no verdict), adopt the external value (S-N3), `.idle` + note.
/// - ONE armed window; supersede cancels with NO verdict; a GENERATION COUNTER discards late
///   async results from dead windows (the WI-N4 race test).
/// - The ceiling counts SAMPLED time, not calendar time: each wake-gap's duration is banked in
///   `unsampledGapTotal` and subtracted, because 7200 s was justified as a charge-physics bound
///   ("longer than any 0→100 climb") while `CLOCK_MONOTONIC` runs through sleep. Without the
///   rebase a Set at 18:00 followed by a closed lid resolves on the 04:00 wake as an OBC warning
///   after a perfectly successful overnight charge.
/// - The time-based ceiling is ALSO reachable without a sample (`noteTimeElapsedWithoutSample`):
///   a chronic diagnostics read failure must not make a window immortal, because the ceiling that
///   bounds it cannot depend on the very telemetry that failed.
/// - The truth pair is THREE-STATE, never two. The RAW-capacity half can corroborate, contradict,
///   or be UNAVAILABLE, and "unavailable" is not "corroborates": a missing coulomb-counter reading
///   is banked on the window and disclosed on publish, so a confirmation that ran on the amperage
///   term alone says so instead of claiming the full two-signal verdict. (It was silently the
///   latter for the whole macOS 27.0 era — the key had moved to the pack child and the parser was
///   still reading the top level.)
/// - A PUBLISHED verdict is not permanent: an unplug retires an inconclusive one (the in-window
///   rule carried past resolution), and any verdict self-clears at `verdictMaxAge_s`. `ingest`
///   returns once the window is nil, so nothing else could ever clear it and the last verdict
///   would render until the next Set. Both clears are MODEL-side; the view never age-gates.
@MainActor
final class BehaviorConfirm: ObservableObject {

    struct Tunables: Sendable {
        var stopWindow_s: TimeInterval = 60        // measured stop ~10–20 s → ~3× margin
        var resumeWindow_s: TimeInterval = 120     // measured resume 30–51 s → ~3× margin
        var capDecayTTL_s: TimeInterval = 900      // 15 min (Grok B2) — STAGNATION clock, conditional
        /// UNCONDITIONAL ceiling on a `.chargingToCap` window (audit B1). 2 h: longer than any
        /// plausible 0→100 climb on the stock adapter, so it never pre-empts a real one, and 8×
        /// `capDecayTTL_s` so the stagnation clock always wins wherever it applies. It is measured
        /// in SAMPLED time (`unsampledGapTotal` is subtracted) precisely because that justification
        /// is about charge physics, and the clock would otherwise be counting sleep.
        var capMaxWindow_s: TimeInterval = 7200    // 2 h of sampled time (audit B1)
        /// How close to the target counts as "at the limit" when naming the decay taxon. 3 points:
        /// wide enough that a pack finishing at 97 against a target of 100 reads as a completed
        /// charge, narrow enough that the flagship case (OBC parked at 80 against 100) can never be
        /// described as having stopped near the limit.
        var capNearTargetSlack_pct = 3
        /// How long a PUBLISHED verdict may stand before it self-clears to `.idle`. A verdict is
        /// news about the Set that just resolved; `ingest` cannot retire it (it returns as soon as
        /// the window is nil), so without this the last verdict — including the OBC guidance —
        /// renders on the charge card until the user issues ANOTHER Set. 900 s = `capDecayTTL_s`:
        /// the longest this class is willing to sit on an unresolved observation, so a verdict
        /// outliving it is describing something the app itself no longer treats as current. The
        /// steady-state truth (the "holding" / "as set" provenance tag) is unaffected.
        var verdictMaxAge_s: TimeInterval = 900    // 15 min — a verdict is news, not a standing line
        var wakeGap_s: TimeInterval = 30           // S-N5 invalidation threshold
        var confirmSamples = 2                     // consecutive evidence samples per verdict
        var stopFlowMax_mA = 50                    // "stopped" = InstAmp at/below this
        var resumeFlowMin_mA = 350                 // "flowing" = InstAmp at/above this
        var rawStopJitter_mAh = 100                // idle RAW wobbles ±90 (run-02 13:12 rows)
        init() {}
    }

    // MARK: - published surface (composed by the UI with the telemetry state)

    @Published private(set) var status: CommandStatus = .idle
    /// Standing Get-degraded caveat rider: true when a verdict was published without the
    /// external-change checks (LimitReader unavailable) — "couldn't verify external changes."
    @Published private(set) var verdictWasDegraded = false
    /// One-line context for status ("limit was changed outside the app").
    @Published private(set) var statusNote: String?
    /// B1: a transient, CALM positive confirmation ("Limit set to N%") shown after a permanent-degraded
    /// Set whose read-back is unavailable. Auto-clears after a few seconds; never a standing line. Kept
    /// separate from statusNote (which the UI renders orange); the UI renders this one secondary.
    @Published private(set) var transientConfirmation: String?

    /// B1: how long the soft confirmation stays before it auto-clears.
    static let transientConfirmationDuration: TimeInterval = 4
    /// Guards the auto-clear: a new command, supersede, failure, or another confirmation bumps this so a
    /// pending clear from an earlier confirmation cannot wipe a newer one.
    private var confirmationToken = 0

    /// Guards the verdict age-cap auto-clear, exactly as `confirmationToken` guards the transient
    /// confirmation: a newer verdict (or a retirement) bumps it so an older verdict's pending
    /// expiry cannot wipe a newer one.
    private var verdictToken = 0

    /// S-N3 adoption hook: fired when an external limit change is detected mid-window; the
    /// coordinator updates its published limit to the adopted value.
    var onAdoptExternalLimit: ((ChargeLimitValue) -> Void)?

    /// Drives the poll cadence (sec 2): 10 s while armed, lazy 60 s otherwise.
    var isWindowArmed: Bool { window != nil }

    private let limitReader: LimitReading?
    private let tunables: Tunables
    private var generation = 0

    // MARK: - the armed window

    private enum Kind: Equatable {
        case stopConfirm
        case resumeConfirm
        case chargingToCap
    }

    private struct Window {
        let kind: Kind
        let target: Int
        var generation: Int                // re-stamped on wake-gap restart (new incarnation)
        /// ABSOLUTE arming instant. Unlike `start` this is NEVER re-anchored — not by a wake-gap
        /// restart — because the `.chargingToCap` ceiling (audit B1) bounds how long ONE Set may
        /// hold the app in fast-poll / scheduler-deferring mode, and a nap does not reset that
        /// cost. The clock counts through sleep (`LiveMonotonicClock`, CLOCK_MONOTONIC).
        let armedAt: TimeInterval
        /// Total time the window was NOT being sampled, banked one gap at a time on the wake-gap
        /// path. Subtracted from the ceiling's elapsed term so the ceiling measures the quantity
        /// its 2-hour justification is about (charging progress) rather than calendar time: the
        /// window is only "spending" the app's fast-poll/scheduler-deferral budget while samples
        /// are actually arriving, and a sleeping Mac is not slowly failing to charge.
        ///
        /// DESIGN NOTE — THE WAKE-GAP ASYMMETRY IS THE DESIGN. DO NOT "FIX" IT.
        /// The three exits treat a nap differently, and that is deliberate:
        ///   * E1 (`state == .limitHold` → `.confirmedStop`) LOSES NOTHING. It is a level check on
        ///     a single sample, so it fires on the FIRST post-wake sample that is evaluated at all
        ///     — a napping machine parked at a real cap confirms immediately if the hold bit is up.
        ///   * E4 (the `capDecayTTL_s` stagnation clock) loses the gap: `capStagnantSince` is
        ///     cleared by the wake-gap restart, so stagnation must be re-observed while awake.
        ///   * E5 (this ceiling) loses the gap too: the gap is banked here and subtracted.
        /// So a napping machine parked BELOW the target still owes two hours of SAMPLED time
        /// before the app may call its Set inconclusive, while the same machine at a real cap is
        /// confirmed on one sample. The confirmation is cheap and the accusation is expensive, so
        /// only the accusation pays for the sleep. Evaluating E5 (or E4) on the wake-gap sample
        /// would turn a closed lid into an OBC warning after a charge that in fact succeeded —
        /// precisely the defect the banking exists to close.
        var unsampledGapTotal: TimeInterval = 0
        var start: TimeInterval            // restarts on wake-gap invalidation
        var lastSampleAt: TimeInterval
        var baselineRAW: Int?
        var evidenceStreak = 0
        var halfTimeChecked = false
        /// True while an at-resolution read-back is in flight — further samples are held off
        /// so one window resolves once and the ≤2-Get bound per window holds.
        var resolutionInFlight = false
        /// chargingToCap TTL anchor: first moment SoC>=target with no flow and no hold bit.
        var capStagnantSince: TimeInterval?
        /// The HIGHEST SoC this window has seen: seeded from `socAtSet` (so never nil for a
        /// `.chargingToCap` window), raised by every sample and never lowered — including across a
        /// wake-gap restart, because the restart discards stale EVIDENCE and the window's identity
        /// (like `armedAt`) survives it. Decides ONLY which decay taxon is honest at resolution —
        /// "stopped at the limit" vs "never reached the limit". It is never evidence.
        ///
        /// A MAX, not the last reading, because the question the taxon asks is whether the pack
        /// ever APPROACHED the target. Gauge sag after a real cap (95 → 85 as the pack relaxes, or
        /// a recalibration step) ends below the slack band, so reading where the window ENDED hung
        /// the OBC / stale-hold sentence on a charge that got there.
        var maxSoc: Int?
        /// STICKY: at least one evidence sample in this window had no readable RAW capacity, so the
        /// verdict rests on the amperage half of the truth pair alone. Recorded, not swallowed —
        /// see `RawCorroboration`.
        var rawEvidenceMissing = false
    }

    /// The RAW-trend half of the validated truth pair is THREE-STATE, and conflating the third
    /// state with the first is precisely the defect this exists to prevent. The guards used to read
    /// `zip(raw, baseline).map { … } ?? true`, so a RAW reading that could not be obtained AT ALL
    /// became a guard that PASSED — and on macOS 27.0 that was every sample, because
    /// `AppleRawCurrentCapacity` had been relocated to the pack child and the parser was still
    /// reading the top level. Stop/resume confirmation silently degraded to amperage-only for the
    /// whole 27.0 era with nothing reporting a failure (the Health/FCC break, again).
    private enum RawCorroboration {
        /// A reading and a baseline both exist and the trend agrees with the verdict.
        case corroborates
        /// Both exist and the trend CONTRADICTS it — vetoes the evidence, as it always did.
        case contradicts
        /// No reading at one or both ends: the coulomb counter resolved at no known registry
        /// layout. NOT corroboration. The verdict may still publish off the amperage term (a hard
        /// failure would be a lie in the other direction, and a machine that never publishes the
        /// key must still get confirmations) — but it publishes WITH the caveat.
        case unavailable
    }

    private var window: Window?

    init(limitReader: LimitReading?, tunables: Tunables = Tunables()) {
        self.limitReader = limitReader
        self.tunables = tunables
    }

    // MARK: - command lifecycle (called by the coordinator)

    /// A Set was successfully issued. Decide what (if anything) to arm — BOTH arming rules live
    /// here. `at` is the current monotonic time (the latest snapshot's clock).
    func commandIssued(target: Int,
                       preSetNCR: UInt32?,
                       socAtSet: Int?,
                       telemetryState: TelemetryChargeState,
                       at now: TimeInterval) {
        cancelWindow()                       // supersede: the old window publishes NO verdict
        statusNote = nil
        verdictWasDegraded = false
        clearTransientConfirmation()         // a new Set clears any stale soft confirmation

        let raising = socAtSet.map { target > $0 } ?? true

        // From the ambiguous hold, a raise is REPORTED, never promised (S-N2): no window.
        if telemetryState == .ambiguousHold && raising {
            status = .requestedNoPromise
            return
        }

        // Resume-confirm arms ONLY off a genuine pre-Set limit-hold (run-03: resumes 30–51 s).
        if raising, ChargeNCR.isLimitHold(preSetNCR) {
            arm(.resumeConfirm, target: target, at: now)
            return
        }

        // Stop-confirm arms ONLY when SoC is at/above the new limit…
        if let soc = socAtSet, soc >= target {
            arm(.stopConfirm, target: target, at: now)
            return
        }

        // …below it, charging toward the cap is legitimate — pending status, full lifecycle.
        //
        // EXCEPT at `target == 100`, where there IS no cap and so no window worth arming. E1 — the
        // only CLEAN exit from a `.chargingToCap` window — is `state == .limitHold`, and
        // `ChargeStateMachine.classify` publishes that state solely off the NCR limit bit
        // (`isLimitHoldNCR`: 0x01000000 or the 0x01002080 stop transient). A cap-hold reason has no
        // referent when nothing is being held back, so the bit never appears: in the app's own
        // history every non-flowing sample at SoC 100 / on AC / limit 100 classifies
        // `.ambiguousHold` (33 rows), and that classification requires `notChargingReason == 0`
        // EXACTLY. The window could therefore only ever end on the stagnation TTL, the 2-h ceiling,
        // an unplug or a supersede — so EVERY completed charge to 100 resolved as an inconclusive
        // verdict, having first pinned the 10 s poll cadence (`wantsFastPolling` IS
        // `isWindowArmed`) and deferred the scheduler for up to two hours to get there.
        //
        // Report, don't promise — the same honest outcome, and the same shape, as the nil-SoC guard
        // immediately below: no evidence was ever obtainable, so arming a window to fail is worse
        // than declining to judge.
        //
        // NARROW BY CONSTRUCTION, and it must stay narrow. This is NOT the withdrawn claim that
        // `.limitHold` is dead on macOS 27 (§7.8) — the aggregates record 151 `.limitHold` hours
        // across 29 days at a target of 80, none of them capping above 95. The bit is alive
        // wherever there is a cap; it is only `target == 100` that has none. Do not generalise it.
        guard target < 100 else {
            status = .requestedNoCapToHold
            return
        }

        // This is also the branch an UNREADABLE SoC falls into: `raising` defaults to true
        // above and the stop-confirm arm needs a non-nil SoC. A nil SoC then PINS the stagnation
        // TTL off forever (`socPercent ?? Int.min` can never reach the target), so the window's
        // only exit is the 2-h ceiling and an unreadable pack resolves as a charge-management
        // warning. Report, don't promise (the S-N2 shape): with no SoC there was never any evidence
        // to confirm against, so losing confirm coverage for this Set costs nothing real.
        guard let soc = socAtSet else {
            status = .requestedNoPromise
            return
        }
        arm(.chargingToCap, target: target, at: now, seedSoc: soc)
        status = .limitSetChargingToCap
    }

    /// A new user action supersedes any armed window — it must publish nothing, ever.
    func supersede() {
        cancelWindow()
        status = .idle
        statusNote = nil
        clearTransientConfirmation()
    }

    /// Runner-failure surface (S-N4): the coordinator routes taxons here.
    func commandFailed(_ status: CommandStatus, at now: TimeInterval) {
        cancelWindow()
        clearTransientConfirmation()
        self.status = status
    }

    /// B1: show a calm positive confirmation that auto-clears after `seconds`. A new command, supersede,
    /// failure, or another confirmation cancels the pending clear via the token guard. This is a normal
    /// main-actor Task (not an NSXPC closure); it touches UI state only on the main actor.
    func showTransientConfirmation(_ text: String,
                                   clearAfter seconds: TimeInterval = BehaviorConfirm.transientConfirmationDuration) {
        confirmationToken += 1
        let token = confirmationToken
        transientConfirmation = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.confirmationToken == token else { return }
            self.transientConfirmation = nil
        }
    }

    /// Clear the soft confirmation and cancel any pending auto-clear (a new action took over).
    private func clearTransientConfirmation() {
        confirmationToken += 1
        transientConfirmation = nil
    }

    // MARK: - telemetry ingestion (every poll while armed; cheap no-op otherwise)

    func ingest(_ snapshot: ChargeTelemetrySnapshot, state: TelemetryChargeState) {
        guard var w = window else {
            // NO window: a resolved verdict is all that can still be standing, and an UNPLUG ends
            // its story — the same rule the in-window check below applies ("an unplug is a user
            // act, not a mechanism verdict"), carried past resolution. Without this nothing
            // telemetry ever does clears a verdict, so a user could unplug, walk away, and hours
            // later still be reading "Stopped near the limit". This rides the EXISTING
            // power-source distribution — BatteryMonitor's 2.E power-source event does a full
            // sample (live + diagnostics) → pipeline → engine → here, within ~1 s of the unplug —
            // so it needs no observer and no timer of its own.
            if snapshot.externalConnected == false { clearInconclusiveVerdictOnUnplug() }
            return
        }
        guard w.generation == generation else { return }
        let now = snapshot.timestamp

        // S-N5: a monotonic gap (nap) invalidates and RESTARTS the window — stale pre-sleep
        // evidence is discarded wholesale, and this sample only re-baselines. The restart is a
        // NEW window incarnation: the generation is re-stamped so any in-flight read launched
        // from pre-sleep evidence is dead on arrival (no verdict from stale samples).
        if now - w.lastSampleAt > tunables.wakeGap_s {
            generation += 1
            w.generation = generation
            // BANK THE GAP. `armedAt` is still deliberately NOT re-anchored — evidence restarts,
            // the window's identity does not (audit B1) — but the ceiling must not charge the
            // window for time nobody was sampling. `CLOCK_MONOTONIC` runs through system sleep, so
            // without this a Set at 18:00 with the lid then closed until 04:00 blows the 2-h
            // ceiling on the second post-wake sample and reports an OBC warning for a charge that
            // in fact succeeded. The 7200 s number is a claim about charging duration; this makes
            // the clock measure that quantity.
            w.unsampledGapTotal += now - w.lastSampleAt
            w.start = now
            w.lastSampleAt = now
            w.baselineRAW = snapshot.rawCapacity_mAh
            w.maxSoc = raisedMax(w.maxSoc, snapshot.socPercent)   // identity survives the nap
            w.evidenceStreak = 0
            w.halfTimeChecked = false
            w.resolutionInFlight = false
            w.capStagnantSince = nil
            window = w
            return
        }
        w.lastSampleAt = now
        w.maxSoc = raisedMax(w.maxSoc, snapshot.socPercent)
        if w.baselineRAW == nil { w.baselineRAW = snapshot.rawCapacity_mAh }   // first-sample anchor

        // Unplugged: `.limitSetChargingToCap` CLEARS to `.idle` (spec lifecycle); armed confirm
        // windows follow the same rule — an unplug is a user act, not a mechanism verdict
        // (flagged interpretation, see hand-back). Checked BEFORE the in-flight guard: the
        // cancel bumps the generation, so a parked read-back dies with the window.
        if snapshot.externalConnected == false {
            cancelWindow()
            status = .idle
            return
        }

        // One resolution per window: while the at-resolution read-back is in flight, later
        // samples only keep the liveness bookkeeping above (no duplicate resolves/Gets).
        if w.resolutionInFlight {
            window = w
            return
        }

        switch w.kind {
        case .stopConfirm, .resumeConfirm:
            ingestForConfirm(&w, snapshot: snapshot, now: now)
        case .chargingToCap:
            ingestForCap(&w, snapshot: snapshot, state: state, now: now)
        }
    }

    /// TIME-ONLY evaluation for a poll tick that produced NO telemetry sample — the diagnostics
    /// read failed (sec 6 telemetry-read-failure). Every other transition in this class is
    /// evaluated inside `ingest`, i.e. on sample ARRIVAL, so a chronic `AppleSmartBattery` read
    /// failure left a window armed FOREVER with the 2-h ceiling present and unable to fire: 10 s
    /// polling pinned and the scheduler deferring — the exact audit-B1 symptom the ceiling exists
    /// to close, reached through a door the ceiling cannot see. An unconditional wall-clock bound
    /// must not depend on the telemetry that may itself be what failed.
    ///
    /// It stamps the clock and applies E5 — the `.chargingToCap` ceiling — AND ONLY E5, through
    /// the same `resolve()` gate and the same generation guards `ingest` uses. It invents no SoC,
    /// no NCR and no flow, and a single failed read can never cancel a window: only the full
    /// ceiling resolves one, so an IOKit blip cannot abort a real climb.
    ///
    /// Deliberately NOT evaluated here: the `capDecayTTL_s` stagnation clock (gated on
    /// `atOrPastTarget && noFlow && !isLimitHoldNCR` — unknown without a sample, and advancing a
    /// stagnation clock on unknown evidence would be inventing evidence), the half-time external
    /// check, the `.stopConfirm` / `.resumeConfirm` windows (out of scope this pass), and every
    /// evidence/wake-gap bookkeeping field. `lastSampleAt` is left untouched in particular, so the
    /// first REAL sample after an outage is still correctly seen as a gap: it restarts the evidence
    /// and banks its own duration (S-N5).
    func noteTimeElapsedWithoutSample(at now: TimeInterval) {
        guard var w = window else { return }
        guard w.generation == generation else { return }
        guard w.kind == .chargingToCap else { return }
        // One resolution per window: a read-back is already deciding this window's fate.
        guard !w.resolutionInFlight else { return }
        guard sampledElapsed(w, now: now) >= tunables.capMaxWindow_s else { return }

        w.resolutionInFlight = true
        window = w
        resolve(with: .confirmInconclusive(capDecayReason(w)),
                generation: w.generation, target: w.target)
    }

    // MARK: - stop/resume windows

    private func ingestForConfirm(_ w: inout Window, snapshot: ChargeTelemetrySnapshot,
                                  now: TimeInterval) {
        // Mid-window system inhibit while awake: not the mechanism's fault — inconclusive.
        // Routed through resolve() like every other resolution (Grok B1: the at-resolution
        // read-back runs on EVERY resolution path; mismatch → no verdict, adopt, .idle).
        if snapshot.notChargingReason == ChargeNCR.idleInhibit {
            w.resolutionInFlight = true
            window = w
            resolve(with: .confirmInconclusive(.systemInhibit), generation: w.generation,
                    target: w.target)
            return
        }

        let duration = w.kind == .stopConfirm ? tunables.stopWindow_s : tunables.resumeWindow_s

        // Evidence: InstAmp sign + RAW trend ONLY (the validated truth pair).
        let flowEvidence: Bool
        let raw: RawCorroboration
        if w.kind == .stopConfirm {
            flowEvidence = (snapshot.instantAmperage_mA ?? Int.max) <= tunables.stopFlowMax_mA
            raw = corroboration(snapshot.rawCapacity_mAh, w.baselineRAW) {
                $0 <= $1 + tunables.rawStopJitter_mAh
            }
        } else {
            flowEvidence = (snapshot.instantAmperage_mA ?? Int.min) >= tunables.resumeFlowMin_mA
            raw = corroboration(snapshot.rawCapacity_mAh, w.baselineRAW) { $0 >= $1 }
        }
        // `.unavailable` is BANKED, not silently accepted: it does not veto the sample (that would
        // turn every confirmation on a gauge-less machine into a false `.confirmFailed`), but the
        // window remembers that this verdict is standing on half its evidence and says so on
        // publish. Only `.contradicts` vetoes — exactly as before.
        if raw == .unavailable { w.rawEvidenceMissing = true }
        let evidence = flowEvidence && raw != .contradicts
        w.evidenceStreak = evidence ? w.evidenceStreak + 1 : 0

        if w.evidenceStreak >= tunables.confirmSamples {
            w.resolutionInFlight = true
            window = w
            let verdict: CommandStatus = w.kind == .stopConfirm ? .confirmedStop : .confirmedResume
            resolve(with: verdict, generation: w.generation, target: w.target,
                    rawEvidenceMissing: w.rawEvidenceMissing)
            return
        }

        // Window expiry without evidence → at-resolution check, then an honest failure.
        if now - w.start >= duration {
            w.resolutionInFlight = true
            window = w
            resolve(with: .confirmFailed, generation: w.generation, target: w.target)
            return
        }

        // Half-time external-change check (Grok B1).
        if !w.halfTimeChecked && now - w.start >= duration / 2 {
            w.halfTimeChecked = true
            runExternalCheck(generation: w.generation, target: w.target)
        }
        window = w
    }

    /// Classify the RAW half of the truth pair into its THREE states. `trendHolds` is given the
    /// (current, baseline) pair and answers whether the trend supports the verdict under test.
    private func corroboration(_ current: Int?, _ baseline: Int?,
                               trendHolds: (Int, Int) -> Bool) -> RawCorroboration {
        guard let pair = zip(current, baseline) else { return .unavailable }
        return trendHolds(pair.0, pair.1) ? .corroborates : .contradicts
    }

    // MARK: - chargingToCap lifecycle

    /// Time this window has been under observation: elapsed since arming MINUS every banked
    /// unsampled gap. The ceiling is expressed in this quantity, never in raw calendar time.
    private func sampledElapsed(_ w: Window, now: TimeInterval) -> TimeInterval {
        now - w.armedAt - w.unsampledGapTotal
    }

    /// Which decay taxon is honest for this window. If the pack ever GOT at/near the target it did
    /// finish its climb and merely never produced the hold flag; if it never got there, charging
    /// never approached the limit and something else is managing it.
    ///
    /// The input is the window's MAX SoC, never its last: the question is whether the pack ever
    /// approached the target, and a real cap followed by gauge sag ends below it. `capNearTargetSlack_pct`
    /// stays at 3 precisely because the input is a max — a 3-point band is generous enough for a
    /// pack that finishes at 97 against a target of 100 and far too narrow for one parked at 80.
    ///
    /// SCOPE, since the `target == 100` arming gate: every window that reaches this function has a
    /// REAL cap (`target < 100`), where the hold bit is alive — the app's own hourly aggregates
    /// record 151 `.limitHold` hours across 29 days at a target of 80, and not one of those hours
    /// caps above 95. So a missing flag here is no longer the expected shape of a charge to 100
    /// (that case never arms a window at all now): it is a genuine "the app could not verify it",
    /// which is exactly what the `.noCleanHoldObserved` string says. Do NOT re-read this as evidence
    /// the bit is gone — that claim was withdrawn (§7.8) and its 7-day window was entirely at
    /// limit == 100.
    private func capDecayReason(_ w: Window) -> InconclusiveReason {
        guard let soc = w.maxSoc else { return .noCleanHoldObserved }
        return soc >= w.target - tunables.capNearTargetSlack_pct ? .noCleanHoldObserved
                                                                : .neverReachedLimit
    }

    /// Raise a running max by a possibly-unreadable sample: an unreadable SoC leaves the max where
    /// it was (it is not evidence that the pack fell back), and the first readable one seeds it.
    private func raisedMax(_ current: Int?, _ sample: Int?) -> Int? {
        guard let sample else { return current }
        guard let current else { return sample }
        return Swift.max(current, sample)
    }

    private func ingestForCap(_ w: inout Window, snapshot: ChargeTelemetrySnapshot,
                              state: TelemetryChargeState, now: TimeInterval) {
        // RESOLUTION: the clean hold appeared at/after the cap → this Set is confirmed-stopped.
        if state == .limitHold {
            w.resolutionInFlight = true
            window = w
            resolve(with: .confirmedStop, generation: w.generation, target: w.target)
            return
        }

        // TTL decay clock: runs while the pack sits at/past the target with no flow and NO
        // hold NCR (the NCR=0/OBC hold at the cap — run-02's invisible morning blocker).
        let atOrPastTarget = (snapshot.socPercent ?? Int.min) >= w.target
        let noFlow = abs(snapshot.instantAmperage_mA ?? 0) < tunables.resumeFlowMin_mA
        if atOrPastTarget && noFlow && !snapshot.isLimitHoldNCR {
            if w.capStagnantSince == nil { w.capStagnantSince = now }
            if let since = w.capStagnantSince, now - since >= tunables.capDecayTTL_s {
                w.resolutionInFlight = true
                window = w
                resolve(with: .confirmInconclusive(.noCleanHoldObserved),
                        generation: w.generation, target: w.target)
                return
            }
        } else {
            w.capStagnantSince = nil       // flow resumed / fell below target: not stagnant
        }

        // UNCONDITIONAL ceiling (audit B1). The stagnation clock above is CONDITIONAL on
        // `atOrPastTarget`, so when SoC parks BELOW the target — Apple's OBC holding the pack at
        // 80 while our target is 100 — it never starts and the window had NO reachable exit: the
        // scheduler defers forever ("the app was busy") and polling pins at 10 s. This clock runs
        // regardless of SoC, flow or NCR (the stagnation TTL only ACCELERATES the same outcome
        // where the pack is demonstrably parked at the cap), but it counts SAMPLED time only —
        // see `sampledElapsed`. It goes through `resolve()`, so the at-resolution external-change
        // read-back still gates it; the taxon is chosen by how far the pack actually got.
        if sampledElapsed(w, now: now) >= tunables.capMaxWindow_s {
            w.resolutionInFlight = true
            window = w
            resolve(with: .confirmInconclusive(capDecayReason(w)),
                    generation: w.generation, target: w.target)
            return
        }

        // Half-time external-change check, anchored to the TTL horizon.
        if !w.halfTimeChecked && now - w.start >= tunables.capDecayTTL_s / 2 {
            w.halfTimeChecked = true
            runExternalCheck(generation: w.generation, target: w.target)
        }
        window = w
    }

    // MARK: - resolution + external checks (generation-guarded async)

    private func arm(_ kind: Kind, target: Int, at now: TimeInterval, seedSoc: Int? = nil) {
        generation += 1
        window = Window(kind: kind, target: target, generation: generation,
                        armedAt: now, start: now, lastSampleAt: now, maxSoc: seedSoc)
        if kind != .chargingToCap { status = .confirming }
    }

    private func cancelWindow() {
        generation += 1        // any in-flight async result is now from a DEAD window
        window = nil
    }

    /// AT-RESOLUTION check: a verdict may only publish if the read-back limit still equals the
    /// armed target (Grok B1). The generation captured here is compared on completion — a poll
    /// racing a cancel/supersede must never publish from a dead window (the WI-N4 race).
    /// `rawEvidenceMissing` rides the whole async chain as a VALUE rather than as instance state:
    /// a window can resolve while another is being armed, and a stored flag would leak across the
    /// generation boundary the rest of this class is careful about. Only the positive-confirmation
    /// call site ever passes true.
    private func resolve(with verdict: CommandStatus, generation gen: Int, target: Int,
                         rawEvidenceMissing: Bool = false) {
        guard let reader = limitReader else {
            publishIfLive(verdict, generation: gen, degraded: true,
                          rawEvidenceMissing: rawEvidenceMissing)
            return
        }
        Task { [weak self] in
            let readBack = await reader.readLimit()
            self?.completeResolution(verdict: verdict, readBack: readBack,
                                     generation: gen, target: target,
                                     rawEvidenceMissing: rawEvidenceMissing)
        }
    }

    private func completeResolution(verdict: CommandStatus, readBack: ChargeLimitValue,
                                    generation gen: Int, target: Int,
                                    rawEvidenceMissing: Bool) {
        guard gen == generation else { return }            // dead window — discard, no publish
        switch readBack {
        case .unknown:
            publishIfLive(verdict, generation: gen, degraded: true,
                          rawEvidenceMissing: rawEvidenceMissing)
        case .known(let value) where value == target:
            publishIfLive(verdict, generation: gen, degraded: false,
                          rawEvidenceMissing: rawEvidenceMissing)
        case .known(let value):
            abortForExternalChange(adopting: value)
        }
    }

    private func runExternalCheck(generation gen: Int, target: Int) {
        guard let reader = limitReader else { return }     // degraded: check impossible
        Task { [weak self] in
            let readBack = await reader.readLimit()
            guard let self, gen == self.generation else { return }   // dead window — discard
            if case .known(let value) = readBack, value != target {
                self.abortForExternalChange(adopting: value)
            }
        }
    }

    private func publishIfLive(_ verdict: CommandStatus, generation gen: Int, degraded: Bool,
                               rawEvidenceMissing: Bool = false) {
        guard gen == generation else { return }
        // Publishing TERMINATES the window: bump the generation so any still-in-flight read
        // (e.g. an unanswered half-time check) is dead — it must never mutate state after
        // the verdict (the other half of the WI-N4 race discipline).
        generation += 1
        window = nil
        verdictWasDegraded = degraded
        // A positive confirmation that ran on HALF the truth pair must not read as the whole one.
        // Carried on `statusNote` (the existing standing-context surface, same idiom and same
        // lifecycle as "limit was changed outside the app": cleared by the next command, by the
        // unplug retirement, and by the verdict age cap) rather than on a new published flag, so
        // it renders through the honesty layer that already exists. Deliberately NOT folded into
        // `verdictWasDegraded`: that flag means one specific thing — the external-change read-back
        // was unavailable — and overloading it would make its own string a lie.
        if rawEvidenceMissing {
            statusNote = "Confirmed from charge flow only — the battery's raw capacity reading was unavailable."
        }
        status = verdict
        scheduleVerdictExpiry(verdict)
    }

    // MARK: - verdict retirement (a verdict is news, not a standing line)

    /// Retire whatever a resolved window left standing. The caveat and the note belong to that same
    /// resolved episode, so they go with it.
    private func clearVerdict() {
        verdictToken += 1            // any pending age-cap expiry for this verdict is now spent
        verdictWasDegraded = false
        statusNote = nil
        status = .idle
    }

    /// The UNPLUG rule, deliberately NARROW (review ruling): only an INCONCLUSIVE verdict is
    /// retired by an unplug. That is the one that describes an episode the disconnect just ended
    /// and the one whose guidance ("something else may be managing charging") is actively
    /// misleading once there is no charger. A `.confirmedStop` / `.confirmedResume` /
    /// `.confirmFailed` is a fact about a Set the user made and stands until the age cap.
    private func clearInconclusiveVerdictOnUnplug() {
        guard case .confirmInconclusive = status else { return }
        clearVerdict()
    }

    /// Absolute age cap on a published verdict — MODEL-side, never a view heuristic. Same idiom as
    /// `showTransientConfirmation` (a token-guarded main-actor `Task`, no timer state), because the
    /// clear CANNOT be sample-driven: `ingest` returns as soon as the window is nil, and a machine
    /// whose telemetry has stopped is exactly the machine that most needs this to fire. It composes
    /// with the unplug clear rather than duplicating it: the unplug rule is a narrow power-state
    /// rule that fires immediately for one taxon, this is the relevance bound on every verdict, and
    /// whichever runs first spends the token so the other is inert. Two guards make a late expiry
    /// harmless: the token, and the captured verdict value (any later state — a new command, a
    /// failure, `.idle` — is left alone).
    private func scheduleVerdictExpiry(_ verdict: CommandStatus) {
        verdictToken += 1
        let token = verdictToken
        let seconds = tunables.verdictMaxAge_s
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.verdictToken == token, self.status == verdict else { return }
            self.clearVerdict()
        }
    }

    /// Mismatch → cancel the window (NO verdict), adopt the external value (S-N3), say so.
    private func abortForExternalChange(adopting value: Int) {
        cancelWindow()
        status = .idle
        statusNote = "limit was changed outside the app"
        onAdoptExternalLimit?(.known(value))
    }
}

/// Local two-optional zip (Swift's zip is sequence-only).
private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
