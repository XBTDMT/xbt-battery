import XCTest
import IOKit.ps

/// Sprint 4.D (#25): the IOPS callback → debounced full sample → reclassify chain, debounce
/// coalescing (+ the >500 ms-apart non-swallow), the post-Set double-kick (exactly twice), the
/// backstop still firing when notifications are silent, and the no-second-timer wiring proof.
@MainActor
final class EventTelemetryTests: XCTestCase {

    // MARK: - seam mocks

    /// Counts active/started repeating timers (proves no SECOND poll timer appears).
    final class MockRepeating: RepeatingScheduling {
        private(set) var startCount = 0
        private(set) var active = false
        var lastInterval: TimeInterval = 0
        private var tick: (() -> Void)?
        func startRepeating(interval: TimeInterval, _ tick: @escaping () -> Void) {
            startCount += 1; active = true; lastInterval = interval; self.tick = tick
        }
        func stopRepeating() { active = false; tick = nil }
        func fireTick() { tick?() }      // the backstop poll
    }

    final class MockOneShot: OneShotScheduling {
        private(set) var scheduled: [(TimeInterval, () -> Void)] = []
        func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) { scheduled.append((seconds, work)) }
        func fireAll() { let s = scheduled; scheduled = []; s.forEach { $0.1() } }
        var count: Int { scheduled.count }
    }

    final class Clock { var t: TimeInterval = 1000 }

    /// A reader that counts diagnostics reads (the "reclassify" proxy) and lets the test fire the
    /// IOPS callback.
    private func makeMonitor(charge: Int = 50)
    -> (BatteryMonitor, MockPowerSourceReader, MockRepeating, MockOneShot, Clock, () -> Int) {
        let reader = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: charge],
            diagnostics: ["AppleRawMaxCapacity": 5400, "DesignCapacity": 6249])
        let repeating = MockRepeating(); let oneShot = MockOneShot(); let clock = Clock()
        let monitor = BatteryMonitor(reader: reader, repeatingScheduler: repeating, oneShot: oneShot,
                                     monotonicNow: { clock.t })
        var diagReads = 0
        monitor.onDiagnosticsProperties = { _ in diagReads += 1 }
        return (monitor, reader, repeating, oneShot, clock, { diagReads })
    }

    // MARK: - callback → sample → reclassify chain

    func testIOPSCallbackTriggersDiagnosticsSampleAndReclassify() {
        let (monitor, reader, _, _, clock, diagReads) = makeMonitor(charge: 50)
        monitor.start()
        let baseline = diagReads()            // start() did one immediate diagnostics read
        clock.t += 10                         // well past the debounce window
        reader.liveDescription = [kIOPSCurrentCapacityKey: 73]
        reader.fireChange()                   // IOPS callback
        XCTAssertEqual(diagReads(), baseline + 1, "the callback must trigger a diagnostics reclassify")
        XCTAssertEqual(monitor.snapshot.chargePercent, 73, "and refresh the snapshot/glyph")
    }

    // MARK: - debounce

    func testDebounceCoalescesAStorm() {
        let (monitor, reader, _, _, clock, diagReads) = makeMonitor()
        monitor.start()
        let baseline = diagReads()
        clock.t += 10
        reader.fireChange()                   // samples (leading edge)
        let afterFirst = diagReads()
        XCTAssertEqual(afterFirst, baseline + 1)
        // A storm within 500 ms → all coalesced to the first.
        clock.t += 0.1; reader.fireChange()
        clock.t += 0.2; reader.fireChange()
        clock.t += 0.1; reader.fireChange()
        XCTAssertEqual(diagReads(), afterFirst, "callbacks within 500 ms coalesce to one sample")
    }

    func testDebounceDoesNotSwallowSecondTransitionOver500msApart() {
        let (monitor, reader, _, _, clock, diagReads) = makeMonitor()
        monitor.start()
        let baseline = diagReads()
        clock.t += 10
        reader.fireChange()                   // sample 1
        clock.t += 0.6                        // > 500 ms later — a genuine second transition
        reader.fireChange()                   // sample 2 (must NOT be swallowed)
        XCTAssertEqual(diagReads(), baseline + 2, "a transition >500 ms apart must sample again")
    }

    // MARK: - post-Set double-kick

    func testPostSetKickFiresExactlyTwiceAtT0AndT3() {
        let (monitor, _, _, oneShot, _, diagReads) = makeMonitor()
        monitor.start()
        let baseline = diagReads()
        monitor.postSetKick()
        XCTAssertEqual(diagReads(), baseline + 1, "T+0 kick samples immediately")
        XCTAssertEqual(oneShot.count, 1, "exactly one delayed kick scheduled")
        XCTAssertEqual(oneShot.scheduled.first?.0, BatteryMonitor.postSetKickDelay, "…at T+3 s")
        oneShot.fireAll()                     // T+3 s arrives
        XCTAssertEqual(diagReads(), baseline + 2, "T+3 s kick samples once more — exactly two total")
        XCTAssertEqual(oneShot.count, 0, "no further kicks scheduled")
    }

    func testPostSetKickNoOpWhenStopped() {
        let (monitor, _, _, oneShot, _, diagReads) = makeMonitor()
        monitor.start(); monitor.stop()
        let baseline = diagReads()
        monitor.postSetKick()
        XCTAssertEqual(diagReads(), baseline)
        XCTAssertEqual(oneShot.count, 0)
    }

    // MARK: - backstop

    func testBackstopTimerStillSamplesWhenNotificationsSilent() {
        let (monitor, reader, repeating, _, _, diagReads) = makeMonitor()
        monitor.start()
        let baseline = diagReads()
        reader.liveDescription = [kIOPSCurrentCapacityKey: 88]
        repeating.fireTick()                  // the backstop poll, no IOPS event
        XCTAssertEqual(diagReads(), baseline + 1, "the 60 s backstop still samples")
        XCTAssertEqual(monitor.snapshot.chargePercent, 88)
    }

    // MARK: - no second timer (the wiring proof)

    func testNoSecondRepeatingTimerFromEventsOrKicks() {
        let (monitor, reader, repeating, oneShot, clock, _) = makeMonitor()
        monitor.start()
        XCTAssertEqual(repeating.startCount, 1, "exactly one repeating timer at start")
        XCTAssertTrue(repeating.active)

        // Many events + a kick must NOT spin up another repeating timer.
        for _ in 0..<5 { clock.t += 1; reader.fireChange() }
        monitor.postSetKick()           // the kick uses the ONE-SHOT seam, not a repeating timer
        oneShot.fireAll()
        XCTAssertEqual(repeating.startCount, 1, "events/kicks never create a second repeating timer")

        // A cadence change re-schedules the SAME single timer (still one active).
        monitor.setPollInterval(10)
        XCTAssertEqual(repeating.startCount, 2, "cadence change re-schedules…")
        XCTAssertEqual(repeating.lastInterval, 10)
        XCTAssertTrue(repeating.active, "…but there is still exactly one active repeating timer")
    }

    func testCadenceChangeStillSingleTimer() {
        let (monitor, _, repeating, _, _, _) = makeMonitor()
        monitor.start()
        monitor.setPollInterval(10)
        monitor.setPollInterval(60)
        // Each change stops the prior then starts one — never two concurrently active.
        XCTAssertTrue(repeating.active)
        XCTAssertEqual(repeating.lastInterval, 60)
    }
}
