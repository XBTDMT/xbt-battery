import Foundation
import Combine

/// WI-N7 glue: raw `AppleSmartBattery` props (from the Phase-1 monitor's SINGLE poll loop) →
/// timestamped snapshot → history → classification (against the engine's LIVE limit) →
/// engine + advisor. No timers of its own (the single-poller rule, sec 2).
@MainActor
final class ChargeTelemetryPipeline: ObservableObject {

    @Published private(set) var telemetryState: TelemetryChargeState = .unknown
    /// sec 6 "telemetry read failure": set when the IOKit read fails so the UI says so instead
    /// of freezing the last state on display; cleared by the next successful read.
    @Published private(set) var telemetryReadFailed = false

    private(set) var history: [ChargeTelemetrySnapshot] = []
    private let maxHistory = 64   // ≥10 min at the armed 10 s cadence; sustain checks need 30 s

    private let engine: ChargeLimitEngine
    private let advisor: OBCAdvisor
    private let clock: any MonotonicClock

    init(engine: ChargeLimitEngine, advisor: OBCAdvisor,
         clock: any MonotonicClock = LiveMonotonicClock()) {
        self.engine = engine
        self.advisor = advisor
        self.clock = clock
    }

    func ingestDiagnostics(_ props: [String: Any]) {
        telemetryReadFailed = false
        let snapshot = ChargeTelemetryParser.parse(props, timestamp: clock.now())
        history.append(snapshot)
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        let state = ChargeStateMachine.classify(history: history, limit: engine.limit)
        telemetryState = state
        engine.ingest(snapshot, state: state)
        advisor.observe(state: state, at: snapshot.timestamp)
    }

    /// The monitor's diagnostics read failed: the display must degrade to `.unknown` honestly,
    /// not freeze the last classified state (sec 6 telemetry-read-failure taxon).
    func noteDiagnosticsReadFailure() {
        telemetryReadFailed = true
        telemetryState = .unknown
        // Every window transition in BehaviorConfirm is evaluated on SAMPLE ARRIVAL, and this path
        // produces no sample — so a chronic read failure used to leave a confirm window armed
        // forever, with the 2-h ceiling present and unable to fire (10 s polling pinned, the
        // scheduler deferring). A wall-clock bound must not depend on the telemetry that failed, so
        // the tick is forwarded as TIME ONLY: it applies only the time-based bounds and publishes no
        // evidence-bearing verdict. Same clock the successful path stamps its snapshots with — one
        // clock, not two.
        engine.confirm.noteTimeElapsedWithoutSample(at: clock.now())
    }
}
