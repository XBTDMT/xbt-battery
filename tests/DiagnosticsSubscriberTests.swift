import XCTest
import IOKit.ps
// app/Monitoring compiles into BatteryTests → BatteryMonitor / DiagnosticsRead are visible host-app-free.

/// spec 31 §2.2 (G-2, G-4): the monitor's MULTI-subscriber diagnostics tap. Every read the charge
/// pipeline's single-slot tap sees, a subscriber sees — synchronously, on the same read, from all six
/// read paths — and a failed read reaches subscribers as `.unread` (absence is not a fact: before this,
/// a failed read silently kept the last value).
@MainActor
final class DiagnosticsSubscriberTests: XCTestCase {

    private typealias MockRepeating = EventTelemetryTests.MockRepeating
    private typealias MockOneShot = EventTelemetryTests.MockOneShot
    private typealias Clock = EventTelemetryTests.Clock

    /// No `pmset` spawn from `start()` / `refreshOnDemand()` in these tests.
    private final class NoEnergyMode: EnergyModeReading {
        func readEnergyMode() -> EnergyMode { .unavailable }
    }

    /// What subscribers saw, in order: "<tag>read:<UpdateTime>" or "<tag>unread".
    private final class Log { var entries: [String] = [] }

    private func batteryLive() -> [String: Any] {
        [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
         kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
    }
    private func acLive() -> [String: Any] {
        [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
         kIOPSPowerSourceStateKey: kIOPSACPowerValue]
    }

    private func makeMonitor() -> (BatteryMonitor, MockPowerSourceReader, MockRepeating, MockOneShot, Clock) {
        let reader = MockPowerSourceReader(
            live: batteryLive(),
            diagnostics: ["UpdateTime": 1_790_630_342, "AppleRawMaxCapacity": 5400, "DesignCapacity": 6249])
        let repeating = MockRepeating(); let oneShot = MockOneShot(); let clock = Clock()
        let monitor = BatteryMonitor(reader: reader, energyModeReader: NoEnergyMode(),
                                     repeatingScheduler: repeating, oneShot: oneShot,
                                     monotonicNow: { clock.t })
        return (monitor, reader, repeating, oneShot, clock)
    }

    private func subscribe(_ monitor: BatteryMonitor, into log: Log, tag: String = "") {
        monitor.addDiagnosticsSubscriber { read in
            switch read {
            case .read(let props):
                let stamp = (props["UpdateTime"] as? Int).map { String($0) } ?? "-"
                log.entries.append("\(tag)read:\(stamp)")
            case .unread:
                log.entries.append("\(tag)unread")
            }
        }
    }

    func testStartDeliversTheFirstReadSynchronously() {
        let (monitor, _, _, _, _) = makeMonitor()
        let log = Log()
        subscribe(monitor, into: log)
        monitor.start(); defer { monitor.stop() }
        XCTAssertEqual(log.entries, ["read:1790630342"],
                       "start()'s read reaches the subscriber before start() returns — no hop, no await")
    }

    func testEveryReadPathReachesTheSubscriberInLockstepWithThePipelineTap() {
        let (monitor, reader, repeating, oneShot, clock) = makeMonitor()
        let log = Log()
        subscribe(monitor, into: log)
        var pipelineTaps = 0
        monitor.onDiagnosticsProperties = { _ in pipelineTaps += 1 }

        monitor.start(); defer { monitor.stop() }        // path 1: start()
        XCTAssertEqual(log.entries.count, 1)
        repeating.fireTick()                              // path 2: the poll timer
        XCTAssertEqual(log.entries.count, 2)
        clock.t += 10
        reader.liveDescription = acLive()
        reader.fireChange()                               // path 3: IOPS T+0 on a real transition
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(oneShot.count, BatteryMonitor.eventSettleDelays.count)
        oneShot.fireAll()                                 // path 4: settle re-reads T+2 / T+5
        XCTAssertEqual(log.entries.count, 5)
        monitor.postSetKick()                             // path 5a: post-Set kick T+0
        XCTAssertEqual(log.entries.count, 6)
        oneShot.fireAll()                                 // path 5b: post-Set kick T+3
        XCTAssertEqual(log.entries.count, 7)
        monitor.refreshOnDemand()                         // path 6: popover open
        XCTAssertEqual(log.entries.count, 8)

        XCTAssertEqual(pipelineTaps, 8, "the subscriber sees exactly the reads the pipeline tap sees")
        XCTAssertEqual(Set(log.entries), ["read:1790630342"], "…and the same props dict")
    }

    func testAFailedReadDeliversUnreadBesideTheExistingFailureHook() {
        let (monitor, reader, repeating, _, _) = makeMonitor()
        let log = Log()
        subscribe(monitor, into: log)
        var failures = 0
        var pipelineTaps = 0
        monitor.onDiagnosticsReadFailure = { failures += 1 }
        monitor.onDiagnosticsProperties = { _ in pipelineTaps += 1 }
        monitor.start(); defer { monitor.stop() }

        reader.diagnosticsProperties = nil
        repeating.fireTick()
        XCTAssertEqual(log.entries, ["read:1790630342", "unread"])
        XCTAssertEqual(failures, 1, "the pipeline's failure hook still fires, unchanged")
        XCTAssertEqual(pipelineTaps, 1, "…and the pipeline tap is not called for a failed read")

        reader.diagnosticsProperties = ["UpdateTime": 1_790_630_402]
        repeating.fireTick()
        XCTAssertEqual(log.entries.last, "read:1790630402", "a recovered read is delivered as .read again")
    }

    func testSubscribersRunInRegistrationOrderAndTheSingleSlotTapReplacesNeither() {
        let (monitor, _, _, _, _) = makeMonitor()
        let log = Log()
        subscribe(monitor, into: log, tag: "A:")
        var pipelineTaps = 0
        monitor.onDiagnosticsProperties = { _ in pipelineTaps += 1 }   // assigned AFTER A: must not replace it
        subscribe(monitor, into: log, tag: "B:")
        monitor.start(); defer { monitor.stop() }
        XCTAssertEqual(log.entries, ["A:read:1790630342", "B:read:1790630342"])
        XCTAssertEqual(pipelineTaps, 1)
    }
}
