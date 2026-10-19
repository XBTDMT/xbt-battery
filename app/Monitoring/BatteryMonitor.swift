import Foundation
import Combine

/// Owns the readers, the event-driven live updates, the slow ~60 s timer, the health LEVEL filter
/// (#HEALTH-STEADY — settle-and-hold, see `HealthLevelFilter`), and the merged published `snapshot`.
/// `@MainActor` `ObservableObject`. (SPEC WI-1.3.)
@MainActor
final class BatteryMonitor: ObservableObject {

    @Published private(set) var snapshot: BatterySnapshot = .empty

    // Held for recomposition (partial data is fine).
    private var latestLive: LiveTelemetry?
    private var latestDiagnostics: DiagnosticsTelemetry?
    private var latestSmoothedAmperage: Int?        // rolling-mean current for the hero Time projection
    private var latestEnergyMode: EnergyMode = .unavailable
    private var healthFilter = HealthLevelFilter()  // #HEALTH-STEADY: settle-and-hold, NOT a rolling mean
    private var ampSmoother = AmperageSmoother()    // rolling mean — correct HERE, see the note on the filter
    /// #POPOVER-TREND: moved here from `BatteryApp.updateStatusButton` so the bolt and the popover read ONE
    /// verdict. Fed on EVERY read (not only on published snapshots, which the A9 dedup thins), timed on
    /// `monotonicNow` (CLOCK_MONOTONIC — keeps counting across sleep, never jumps with the wall clock).
    private var packTrend = PackTrend()
    private var packInflow = PackInflowEstimator()
    /// The last DEFINITE power source the trend was collected on. `.unknown` (a dock / cable negotiation
    /// blip) neither resets nor counts: AC → unknown → AC keeps the climb (red-team 2026-09-14 #8).
    private var trendSource: PowerSource?
    /// #POPOVER-TREND veto inputs, pushed by the app (`setTrendVeto`). A rise is NOT a charge at or above the
    /// charge limit or while the classifier reports the limit hold: arriving at the limit, the last up-step
    /// is still inside the hold, and without this the popover said "Charging" / "+37 W" and dropped
    /// "Holding at N%" for up to two minutes while the glyph already showed the hold mark (red-team #2).
    private var trendLimitPercent: Int?
    private var trendLimitHold = false
    private var isRunning = false
    /// AUDIT B6. Was a bare `energyModeReadInFlight` Bool set at kickoff and cleared only by the
    /// completion — so one wedged `pmset -g` child froze the Energy-Mode read (and with it the glyph's
    /// Low-Power tint) for the life of the process. The gate keeps the L2 pile-up guard and adds the
    /// way back; see `BoundedReadGate`.
    private var energyModeGate = BoundedReadGate()

    // Phase 4 (sec 13.2 / 16.4): per-source Energy Mode read, GATED to when the auto-energy automation
    // is enabled, so there is NO added `pmset -g custom` spawn for users who have not opted in. Kept
    // DISTINCT from the active `-g` LPM-tint read above (NOT unified — the tint path is regression-prone
    // and pinned by tests, sec 16.4). BatteryApp mirrors the runner's `enabled` onto this flag.
    var readPerSourceModes = false {
        didSet {
            guard readPerSourceModes != oldValue else { return }
            if readPerSourceModes {
                refreshPerSourceModes()                                  // populate immediately on opt-in
            } else {
                latestPerSourceMode = .unavailable; recompose()          // opt-out → consumers see .unavailable
            }
        }
    }
    private var latestPerSourceMode: EnergyModeReader.PerSourceEnergyMode = .unavailable
    /// AUDIT B6, sibling of `energyModeGate`: same pile-up guard, same wedged-child reclaim.
    private var perSourceGate = BoundedReadGate()
    private var powerStateObserver: NSObjectProtocol? // #2-glyph: Low Power Mode change → re-read energyMode
    private var responsivenessActivity: NSObjectProtocol?  // App-Nap suppression → prompt plug/unplug
    private let reader: PowerSourceReading
    private let energyModeReader: EnergyModeReading   // seam: pmset in production, a fake in tests

    // 4.D event-driven trigger plumbing (injectable seams).
    private let repeatingScheduler: any RepeatingScheduling
    private let oneShot: any OneShotScheduling
    private let monotonicNow: () -> TimeInterval
    private var lastEventSampleAt: TimeInterval = -.infinity   // leading-edge debounce cooldown
    static let eventDebounce: TimeInterval = 0.5               // coalesce a storm to one sample
    static let postSetKickDelay: TimeInterval = 3              // the second post-Set kick (T+3 s)

    /// 2.E settling re-reads. At the instant of plug-in the hardware has NOT started charging yet
    /// (`NotChargingReason == 0x80` → `.idleInhibit`, or |InstantAmperage| < 350 mA), so the T+0
    /// sample classifies into a state where `MenuBarBatteryIcon.boltOn` vetoes the bolt — and below
    /// 100 % the bolt is the ONLY AC signal, so the glyph stays pixel-identical to on-battery until
    /// something re-reads. Before this, the next chance was the 60 s poll (measured p90 52 s, max
    /// exactly 60 — the poll grid). These are BOUNDED one-shots on the existing `oneShot` seam
    /// (no new repeating timer), scheduled ONLY from a real power-source event.
    static let eventSettleDelays: [TimeInterval] = [2, 5]
    private var settleGeneration = 0   // a newer event supersedes the prior event's pending re-reads

    /// Phase 2 REBUILD (SPEC v4.0 sec 2, single-poller rule): the charge-control pipeline taps
    /// the SAME diagnostics read this loop already performs — no second timer, no second IOKit
    /// read. Fired with the raw props dict on every diagnostics refresh.
    var onDiagnosticsProperties: (([String: Any]) -> Void)?
    /// Fired when the diagnostics read returns nil (sec 6 telemetry-read-failure surface).
    var onDiagnosticsReadFailure: (() -> Void)?

    /// spec 31 §2.2 (G-2, G-4): the MULTI-subscriber tap, beside the single-slot pipeline tap above (owned
    /// by the charge pipeline, inside the support gate, and unchanged). Each subscriber is called
    /// synchronously, in registration order, from `refreshDiagnostics` on EVERY read — `start()`, the poll
    /// tick, the IOPS T+0 sample, the T+2 / T+5 settle re-reads, both post-Set kick samples and
    /// `refreshOnDemand` — with `.read(props)`, and with `.unread` from the failure branch. Same read: no
    /// second timer, no second IOKit call. Append-only; subscribers live as long as the monitor (app-long).
    private var diagnosticsSubscribers: [@MainActor (DiagnosticsRead) -> Void] = []

    func addDiagnosticsSubscriber(_ handler: @escaping @MainActor (DiagnosticsRead) -> Void) {
        diagnosticsSubscribers.append(handler)
    }

    private func notifyDiagnosticsSubscribers(_ read: DiagnosticsRead) {
        for handler in diagnosticsSubscribers { handler(read) }
    }

    /// The shared loop's interval = the max requirement of all consumers: 60 s passive, 10 s
    /// while a confirm window is armed (sec 2 polling cadence). One Timer, re-scheduled.
    private(set) var pollInterval: TimeInterval = 60

    init(reader: PowerSourceReading = LiveBatteryReader(),
         energyModeReader: EnergyModeReading = LiveEnergyModeReader(),
         repeatingScheduler: any RepeatingScheduling = LiveRepeatingScheduler(),
         oneShot: any OneShotScheduling = LiveOneShotScheduler(),
         monotonicNow: @escaping () -> TimeInterval = MonitorTime.monotonicNow) {
        self.reader = reader
        self.energyModeReader = energyModeReader
        self.repeatingScheduler = repeatingScheduler
        self.oneShot = oneShot
        self.monotonicNow = monotonicNow
    }

    /// Idempotent. Immediate refresh + event-driven live source + the single poll timer.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // App-Nap suppression, KEPT — but its original justification is MEASURED FALSE and must not be
        // repeated. That justification said a background LSUIElement app is napped and its run-loop
        // work coalesced. It is not: on macOS 27.0 this process shape (LSUIElement + NSStatusItem +
        // a retained hidden window) never became nap-eligible — `PROC_FLAG_SUPPRESSED` was set in
        // 0 of 260 samples across a 2x2 over process shape and suppression. The null is "there is
        // nothing here to suppress", not "the call does nothing": the POSITIVE CONTROL — the identical
        // `beginActivity` call on a regular app hidden with `NSApp.hide` — does suppress a nap that
        // otherwise starts in ~20 s, and a machine-wide census agreed (of 153 LSUIElement processes the
        // 21 napped were all Brave renderers and PAH_Extension; zero menu-bar agents).
        // So this is cheap INSURANCE, not an active fix. Measured cost is indistinguishable from zero
        // and below the tools' resolution floor (7.61 vs 7.56 CPU-s/hr, 117.58 vs 117.71 mJ — the two
        // metrics disagree on the sign). It stays because ONE trigger could not be tested: display
        // sleep / clamshell, the only plausible remaining path to a nap here — `pmset displaysleepnow`
        // is a WRITE flag and was excluded from the run, and four foreign `caffeinate` assertions were
        // held throughout. Removing the call would take on that untested risk to buy nothing.
        // Numbers and method: knowledge/08-MEASURE-appnap-a8-a7.md.
        // NOT the plug/unplug lag fix — that was traced to the bolt veto (audit sec 2.E / 7.5).
        // Idle SYSTEM sleep is still allowed (this suppresses only App Nap, not sleep).
        responsivenessActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Battery menu-bar: prompt plug/unplug + status updates")

        refreshLive()
        refreshDiagnostics()
        refreshEnergyMode()
        refreshPerSourceModes()   // Phase 4: gated to readPerSourceModes (no-op when the automation is off)

        // 4.D: the IOPS power-source change is an ADDITIONAL trigger into this ONE loop — its
        // callback (debounced) does a FULL sample (live + diagnostics) so the charge-control
        // pipeline reclassifies and the glyph/popover refresh in <1 s instead of on the poll grid.
        reader.startLiveUpdates { [weak self] in
            MainActor.assumeIsolated { self?.handlePowerSourceEvent() }
        }

        // #2-glyph: Low Power Mode toggles post NSProcessInfoPowerStateDidChange (fires on
        // Low <-> not-Low). Re-read Energy Mode the instant it fires so the glyph's yellow tint tracks
        // LPM immediately — not only on popover-open. (Automatic <-> High doesn't change the tint, so a
        // non-fire there is harmless; the poll backstop self-heals any missed notification.)
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEnergyMode() }
        }

        scheduleTimer()
    }

    /// IOPS callback → leading-edge 500 ms debounce: the first event samples immediately; a storm
    /// (flaky cable / dock negotiation) within 500 ms coalesces to that one sample; a genuine
    /// transition >500 ms later samples again (the non-swallow guarantee).
    ///
    /// A13 (MEASURED, `knowledge/11-MEASURE-a5-a9-a13.md` §4). The callback behind this is
    /// `kIOPSTimeRemainingNotificationKey`, and Apple's own header says it fires when percent **or
    /// time remaining** changes. Measured on this machine, on battery: **72.4 fires/hr** (19 in 945 s)
    /// against **zero** plug/unplug transitions in the same window — `kIOPSNotifyPowerSource` fired
    /// 0 times in 945 s. Before this gate every one of those 72.4 fires ran THREE full `eventSample()`s
    /// (T+0 plus the 2.E settle re-reads at T+2 s and T+5 s) for 138.17 ms (sd 33.96, n = 8), i.e.
    /// 9.45 CPU-s/hr = **63.4% of the app's entire CPU**, causally proven (8 of 8 CPU bursts aligned
    /// with 8 notification fires to within 0.03 s on one fitted offset). The settle machinery was
    /// running ~72×/hr for the ~0 events it was built for.
    ///
    /// So the follow-ups are now gated on an ACTUAL power-source transition — `powerSource` before the
    /// T+0 sample vs after it — which is exactly the event 2.E's settle re-reads exist for (see
    /// `scheduleSettleFollowUps`). Worth a measured **−4.99 CPU-s/hr (33% of app CPU)** and ~3,476
    /// fewer `pmset -g custom` spawns/day. It removes NO capability: the T+0 `eventSample()` still runs
    /// on EVERY fire, so the menu-bar percentage and the time-remaining estimate stay exactly as fresh
    /// as before, and a real plug/unplug still gets both settle re-reads.
    ///
    /// What was explicitly REJECTED, so nobody re-proposes it: swapping to `kIOPSNotifyPowerSource`.
    /// It fired 0 times in 945 s; adopting it would leave the menu-bar percentage updating on the 60 s
    /// poll alone. §7.5 of the audit struck that swap on latency grounds and §4.7 strikes it on cost
    /// grounds too. The fix is the multiplier, not the key.
    private func handlePowerSourceEvent() {
        let t = monotonicNow()
        guard t - lastEventSampleAt >= Self.eventDebounce else { return }
        lastEventSampleAt = t
        // Captured BEFORE the sample; `eventSample()`'s `refreshLive()` is what republishes `latestLive`.
        // A failed live read leaves `latestLive` untouched → before == after → no follow-ups, which is
        // right: there is no new hardware state to watch settle.
        let sourceBefore = latestLive?.powerSource
        eventSample()
        if latestLive?.powerSource != sourceBefore { scheduleSettleFollowUps() }
    }

    /// 2.E: after the T+0 `eventSample()`, re-read the settling hardware on bounded one-shots
    /// (T+2 s, T+5 s) — the same pattern `postSetKick` already uses, now also reachable from a real
    /// plug/unplug instead of only from an in-app Set. The follow-ups call `eventSample()` DIRECTLY
    /// and never touch `lastEventSampleAt`, so they cannot starve the debounce: a genuine second
    /// transition >500 ms later still samples on its own leading edge (the non-swallow guarantee).
    /// A newer event bumps the generation, so a storm can never stack more than two live re-reads
    /// (each of which costs one `pmset -g custom` spawn when the auto-energy automation is on).
    ///
    /// A13 refines "a newer event" to "a newer TRANSITION": `handlePowerSourceEvent` now calls this
    /// only when `powerSource` actually moved, so the generation advances per transition rather than
    /// per notification. The bound it exists to enforce is UNCHANGED — at most two live re-reads can
    /// ever be pending, because the only thing that schedules a pair is a transition and each
    /// transition retires the previous pair. The bound is in fact tighter now: a time-remaining fire
    /// arriving 1 s after a real plug-in no longer cancels and re-arms that plug-in's pair, so the
    /// re-reads land at T+2 s / T+5 s from the PLUG, which is the offset 2.E measured them for.
    private func scheduleSettleFollowUps() {
        settleGeneration &+= 1
        let generation = settleGeneration
        for delay in Self.eventSettleDelays {
            oneShot.after(delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, generation == self.settleGeneration else { return }
                    self.eventSample()
                }
            }
        }
    }

    /// A full sample on the existing loop: live + diagnostics (→ charge-control reclassify + glyph).
    private func eventSample() {
        refreshLive()
        refreshDiagnostics()
        refreshPerSourceModes()   // Phase 4: refresh per-source modes on plug/unplug + post-set kicks (gated)
    }

    /// 4.D post-Set double-kick: EXACTLY two early samples — T+0 and T+3 s — so the UI races the
    /// hardware's stop/resume reaction (~10–20 s) instead of the poll grid. Called from ONE site
    /// (AppDelegate, on command completion). Bypasses the IOPS debounce (it is an explicit kick).
    func postSetKick() {
        guard isRunning else { return }
        eventSample()                                                  // T+0
        oneShot.after(Self.postSetKickDelay) { [weak self] in          // T+3 s (one-shot, not a timer)
            MainActor.assumeIsolated { self?.eventSample() }
        }
    }

    /// Swap the shared loop's cadence (10 s armed / 60 s passive). Re-schedules the ONE timer;
    /// a no-op when the interval is unchanged.
    func setPollInterval(_ interval: TimeInterval) {
        guard interval != pollInterval else { return }
        pollInterval = interval
        if isRunning { scheduleTimer() }
    }

    /// The BACKSTOP poll timer (the ONE repeating timer): refreshes BOTH live + diagnostics so
    /// state still updates if the notification source is silent/failed (notifications are
    /// best-effort). Re-scheduled on cadence change; never a second concurrent timer.
    private func scheduleTimer() {
        repeatingScheduler.startRepeating(interval: pollInterval) { [weak self] in
            self?.refreshLive()
            self?.refreshDiagnostics()
            self?.refreshEnergyMode()   // #2-glyph: self-heal the glyph tint if an LPM notification was missed
            self?.refreshPerSourceModes()   // Phase 4: keep the inactive-source mode fresh on the poll cadence (gated)
        }
    }

    /// Idempotent teardown.
    func stop() {
        reader.stopLiveUpdates()
        repeatingScheduler.stopRepeating()
        settleGeneration &+= 1   // 2.E: retire any pending settle re-reads (they also re-check isRunning)
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
        if let responsivenessActivity {
            ProcessInfo.processInfo.endActivity(responsivenessActivity)
            self.responsivenessActivity = nil
        }
        isRunning = false
    }

    /// Popover-open refresh so the surface isn't up-to-60 s stale (SPEC WI-1.5).
    func refreshOnDemand() {
        refreshDiagnostics()
        refreshEnergyMode()
        refreshPerSourceModes()   // Phase 4: popover-open refresh of the per-source modes (gated)
    }

    /// Read Energy Mode off the main thread (on-demand/slow), marshal the result back. Guarded
    /// against pile-up so rapid popover toggling can't stack `pmset` spawns (L2).
    func refreshEnergyMode() {
        guard let token = energyModeGate.begin(now: monotonicNow()) else { return }
        DispatchQueue.global(qos: .utility).async {
            let mode = self.energyModeReader.readEnergyMode()
            Task { @MainActor in
                self.settleEnergyMode(token: token, mode: mode)
            }
        }
    }

    /// AUDIT B6 — the ONE settle path for the active Energy-Mode read. A completion whose read was
    /// already reclaimed as wedged loses the gate and does nothing, so a late arrival can never clobber
    /// the newer read that replaced it.
    private func settleEnergyMode(token: Int, mode: EnergyMode) {
        guard energyModeGate.settle(token) else { return }
        latestEnergyMode = mode
        recompose()
    }

    /// Phase 4 (sec 13.2): read BOTH sources' Energy Modes off the main thread (`pmset -g custom` blocks
    /// on the child), marshal the result back, recompose. GATED to `readPerSourceModes` (the automation
    /// enabled) and guarded against pile-up, exactly like `refreshEnergyMode()`. DISTINCT from the active
    /// `-g` tint read — deliberately NOT unified, to protect the regression-prone tint path (sec 16.4).
    func refreshPerSourceModes() {
        guard readPerSourceModes, let token = perSourceGate.begin(now: monotonicNow()) else { return }
        DispatchQueue.global(qos: .utility).async {
            let modes = EnergyModeReader.readCustom()
            Task { @MainActor in
                self.settlePerSourceModes(token: token, modes: modes)
            }
        }
    }

    /// AUDIT B6 — the ONE settle path for the per-source read (see `settleEnergyMode`).
    private func settlePerSourceModes(token: Int, modes: EnergyModeReader.PerSourceEnergyMode) {
        guard perSourceGate.settle(token) else { return }
        latestPerSourceMode = modes
        recompose()
    }

    /// #POPOVER-TREND: the charge limit (nil = unknown → only 100 % vetoes) and whether the classifier is in
    /// `.limitHold`. Republishes at once when the veto changes the verdict.
    func setTrendVeto(limitPercent: Int?, limitHold: Bool) {
        guard limitPercent != trendLimitPercent || limitHold != trendLimitHold else { return }
        trendLimitPercent = limitPercent
        trendLimitHold = limitHold
        recompose()
    }

    private func refreshLive() {
        guard let desc = reader.readLiveDescription() else { return }
        let live = BatteryTelemetryParser.parseLive(desc)
        // A power-source change forgets the trend: a battery-side fall must not read as "not rising on AC"
        // after a plug-in, and an AC-side rise must not follow the Mac onto battery.
        if live.powerSource != .unknown {
            if live.powerSource != trendSource { packTrend.reset(); packInflow.reset() }
            trendSource = live.powerSource
        }
        latestLive = live
        if let pct = live.chargePercent { packTrend.push(percent: pct, at: monotonicNow()) }
        recompose()
    }

    private func refreshDiagnostics() {
        guard let props = reader.readDiagnosticsProperties() else {
            onDiagnosticsReadFailure?()   // the pipeline degrades honestly instead of freezing
            notifyDiagnosticsSubscribers(.unread)   // spec 31 §3.1: a failed read is reported, never a stale value
            return
        }
        onDiagnosticsProperties?(props)   // charge-control tap (same read, single poller)
        notifyDiagnosticsSubscribers(.read(props))   // spec 31 §2.2: the multi-subscriber tap, same read
        var d = BatteryTelemetryParser.parseDiagnostics(props)
        // #HEALTH-STEADY: health is a LEVEL — hold it steady and STEP it, never smooth it (R-06).
        if let h = d.healthPercent { d.healthPercent = healthFilter.push(h, at: monotonicNow()) }
        if let a = d.amperageMilliamps { latestSmoothedAmperage = ampSmoother.push(a) }
        if let mAh = d.remainingCapacity_mAh { packInflow.push(mAh: mAh, at: monotonicNow()) }
        latestDiagnostics = d
        recompose()
    }

    /// A9 (MEASURED, `knowledge/11-MEASURE-a5-a9-a13.md` §3). The app published `$snapshot`
    /// **20,538×/day** (856/hr) and **~70% of those were byte-identical to the previous one**, because
    /// the gas gauge advances only ~once every 50 s while `recompose()` runs 3–4× per tick and 3× per
    /// event sample. A duplicate publish still cost **10.15–11.49 ms** of app CPU — A2's render-key gate
    /// (`BatteryApp.updateStatusButton`) gates the PAINT, not the PUBLISH: it sits after the prefs read
    /// and three display computations and short-circuits only 1 of the 5 `$snapshot` subscribers.
    ///
    /// WHY THE GATE IS HERE AND NOT A `.removeDuplicates()` ON `$snapshot`. Two `.removeDuplicates()`
    /// already exist in `BatteryApp` (`settingsRouter.$selection`, `pipeline.$telemetryState`) and
    /// neither sits on `$snapshot` — that part of A9's claim is confirmed. But an operator on
    /// `monitor.$snapshot` sits DOWNSTREAM of `@Published`'s `willSet`, so it cannot suppress
    /// `objectWillChange`, and `BatteryPopoverView` holds `@ObservedObject var monitor` on a view tree
    /// that is built at launch and retained forever (A10). §0.5 of the measurement states plainly that
    /// the split of the ~10 ms between the five sinks, their five `RunLoop.main` hops and that SwiftUI
    /// invalidation is UNMEASURED — so a downstream operator would capture an unknown, possibly
    /// minority, fraction of it. Assigning only on a real change elides the whole publish, which is the
    /// thing that was priced. It is also strictly stronger: it dedups all five subscribers at once.
    ///
    /// SAFE because no consumer of this publisher needs liveness rather than value:
    /// - the charge-control classifier is NOT on this publisher at all — `ChargeTelemetryPipeline` is
    ///   fed by `onDiagnosticsProperties` (below, in `refreshDiagnostics`), a direct callback on the
    ///   raw props. A dedup here cannot starve it, delay a reclassification, or move a confirm window.
    /// - `AutoEnergyRunner` keeps its own `thermalStateDidChangeNotification` observer;
    ///   `TopUpController` is merged with `engine.$limit`; `NotificationCoordinator` is merged with
    ///   `pipeline.$telemetryState`. Every non-snapshot trigger survives untouched.
    /// - `HistoryStore.ingest` is the one consumer whose semantics are about liveness (a ≤1/60 s
    ///   heartbeat row, and rows keyed on `state`/`limit`, which are NOT snapshot fields). It is
    ///   DELIBERATELY given `pipeline.$telemetryState` as a second trigger at its call site so its row
    ///   cadence is unchanged by this gate — see the comment there.
    private func recompose() {
        // Evaluated at recompose time, so a rise EXPIRES on the next read (the ≤60 s poll) after its hold
        // passes with no new step — the snapshot then changes and publishes, and nothing claims charging
        // off one old step. Gated on AC (a rise is only a charge while plugged in) and vetoed at the limit.
        let now = monotonicNow()
        let belowLimit = latestLive?.chargePercent.map { $0 < min(trendLimitPercent ?? 100, 100) } ?? false
        let rising = latestLive?.powerSource == .ac && packTrend.verdict(at: now) == .rising
            && belowLimit && !trendLimitHold
        let next = BatterySnapshot(
            chargePercent: latestLive?.chargePercent,
            isCharging: latestLive?.isCharging,
            powerSource: latestLive?.powerSource ?? .unknown,
            minutesToFull: latestLive?.minutesToFull,
            minutesToEmpty: latestLive?.minutesToEmpty,
            healthPercent: latestDiagnostics?.healthPercent,
            cycleCount: latestDiagnostics?.cycleCount,
            temperatureCelsius: latestDiagnostics?.temperatureCelsius,
            voltageVolts: latestDiagnostics?.voltageVolts,
            amperageMilliamps: latestDiagnostics?.amperageMilliamps,
            smoothedAmperageMilliamps: latestSmoothedAmperage,
            fullChargeCapacity_mAh: latestDiagnostics?.fullChargeCapacity_mAh,
            designCapacity_mAh: latestDiagnostics?.designCapacity_mAh,
            energyMode: latestEnergyMode,
            perSourceMode: latestPerSourceMode,
            packRising: rising,
            packInflowMilliamps: rising ? packInflow.milliamps(at: now) : nil)
        guard next != snapshot else { return }   // A9: no publish, no sinks, no SwiftUI invalidation
        snapshot = next
    }
}

/// #HEALTH-STEADY. Battery health is a LEVEL, not a rate: it moves on the order of a percentage point
/// over MONTHS. The raw numerator (`AppleRawMaxCapacity`, decision #13) does not behave like that — on
/// this machine it jitters 5198…5639 mAh (σ ≈ 70 mAh ≈ 1.1 pp of the 6249 mAh design capacity) with the
/// cycle count flat, and that jitter is LOW-FREQUENCY. Measured by replaying 7 days of the owner's own
/// `health.jsonl`: widening a rolling mean from 5 to 121 samples moves σ only 1.07 pp → 0.93 pp, and
/// even a 24-hour rolling median still spans 3.1 pp. That is the whole case against the filter this
/// replaces. A rolling MEAN — and equally a rolling median, at any window — is a SMOOTHER, not a
/// stabiliser: it never settles on a level, it walks. The displayed health walked a 6.5 pp band over
/// 7 days while the battery had not changed, which is a claim the app cannot stand behind.
///
/// So the filter here is settle-and-hold, in two stages:
///   1. `candidate` — the MEDIAN of the last `spikeWindow` raw reads. A median, not a mean, because the
///      raw stream carries genuine single-read outliers (one read of 4958 mAh landed on a day whose
///      median was 5306 — 5.6 pp low) that a mean drags into the output for the whole window.
///   2. `held` — the PUBLISHED value, which does NOT track the candidate. It moves only when the median
///      of the candidates over the last `levelWindow` of monitor uptime has left `held ± deadband`, and
///      it then steps straight onto that level. Between steps the published number is bit-identical.
///
/// `deadband` = 2.0 pp is sized to the gauge's own irreducible wander, not to taste: 72-hour medians of
/// the raw signal still span 2.0 pp over the last 30 days, so the app cannot honestly claim to resolve
/// health finer than that. The bounded consequence, stated plainly: `held` may sit up to `deadband`
/// away from the current level. That IS the resolution being claimed, and it is the price of a number
/// that holds still. Replayed over the owner's 90 days this steps 4 times; over the last 7 days it
/// spans 2.1 pp instead of 6.5 pp, and it composes with `HistoryStore.recordHealth`'s 0.1 pp dedup grid
/// to ~2 recorded rows/day (the daily rollover + cycle-count changes) instead of ~204.
///
/// Health MEANING is unchanged: same source, same units, same decision-#13 provenance. Only the noise
/// treatment changed. Pure + value-typed (time is a parameter, it owns no clock) → unit-testable, and
/// it adds NO timer: it is driven entirely by the diagnostics reads the monitor already performs.
struct HealthLevelFilter {
    /// Median width for outlier rejection. Short on purpose — a wider window buys almost nothing against
    /// low-frequency noise (measured above); the HOLD is what delivers the stability.
    static let spikeWindow = 15
    /// How much monitor uptime the level median covers. 12 h spans a full charge/discharge day, so the
    /// level is not biased by time-of-day gauge behaviour.
    static let levelWindow: TimeInterval = 12 * 3600
    /// The hold engages once the level buffer covers this much time. Before that the published value
    /// tracks the candidate, so a fresh launch shows an honest number at once instead of freezing on
    /// read #1 for hours.
    static let minLevelSpan: TimeInterval = 900
    static let minLevelSamples = 10
    /// Level samples are taken no closer together than this, so the filter's memory is the same 12 h
    /// whether the poll is 60 s passive or 10 s armed, and an event burst of re-reads cannot skew it.
    static let minSampleSpacing: TimeInterval = 30
    /// Percentage points. Below the gauge's own multi-day wander the display limit-cycles (measured on
    /// the owner's last 30 days: a 1.5 pp deadband oscillates 87.1 ↔ 88.7 thirteen times; 2.0 pp steps twice).
    static let deadband = 2.0

    private var recent: [Double] = []
    private var level: [(t: TimeInterval, v: Double)] = []
    private var lastPush: TimeInterval?
    /// The published level. nil until the first sample.
    private(set) var held: Double?

    /// Feed one raw health reading (percent) taken at monotonic time `t`; returns the value to publish.
    mutating func push(_ raw: Double, at t: TimeInterval) -> Double {
        guard raw.isFinite else { return held ?? raw }   // a non-finite read never disturbs the held level

        recent.append(raw)
        if recent.count > Self.spikeWindow { recent.removeFirst(recent.count - Self.spikeWindow) }
        let candidate = Self.median(recent)

        // A clock that went backwards restarts the level buffer rather than leaving it holding entries
        // it could never prune.
        if let last = lastPush, t < last { level.removeAll(); lastPush = nil }
        if lastPush == nil || t - lastPush! >= Self.minSampleSpacing {
            lastPush = t
            level.append((t: t, v: candidate))
            while let first = level.first, t - first.t > Self.levelWindow { level.removeFirst() }
        }

        let mature = level.count >= Self.minLevelSamples
            && t - (level.first?.t ?? t) >= Self.minLevelSpan
        guard let current = held, mature else {
            held = Self.quantize(candidate)          // settle phase: track the candidate
            return held!
        }
        let levelValue = Self.median(level.map(\.v))
        if abs(levelValue - current) > Self.deadband { held = Self.quantize(levelValue) }
        return held!
    }

    /// 0.1 pp — the same grid `HistoryStore.recordHealth` dedups on, so one step here is one recorded row.
    private static func quantize(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return .nan }
        let m = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
