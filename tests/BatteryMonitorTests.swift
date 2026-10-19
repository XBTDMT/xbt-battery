import XCTest
import IOKit.ps
import Combine
// app/Monitoring compiled into this target → BatteryMonitor visible host-app-free.

/// Mock-driven model tests (no host app). (SPEC WI-1.7.)
@MainActor
final class BatteryMonitorTests: XCTestCase {

    func testSnapshotReflectsFixtures() {
        let mock = MockPowerSourceReader(
            live: [
                kIOPSCurrentCapacityKey: 55,
                kIOPSIsChargingKey: false,
                kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            ],
            diagnostics: [
                "AppleRawMaxCapacity": 5400, "DesignCapacity": 6249,
                "CycleCount": 411, "Temperature": 3017, "Voltage": 11327,
            ])
        let monitor = BatteryMonitor(reader: mock)
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(monitor.snapshot.chargePercent, 55)
        XCTAssertEqual(monitor.snapshot.isCharging, false)
        XCTAssertEqual(monitor.snapshot.powerSource, .battery)
        XCTAssertEqual(monitor.snapshot.cycleCount, 411)
        XCTAssertEqual(monitor.snapshot.temperatureCelsius!, 30.17, accuracy: 0.01)
        XCTAssertNotNil(monitor.snapshot.healthPercent)
        XCTAssertEqual(monitor.snapshot.healthPercent!, 5400.0 / 6249.0 * 100.0, accuracy: 0.5)
    }

    func testFireChangeUpdatesSnapshot() {
        let mock = MockPowerSourceReader(live: [kIOPSCurrentCapacityKey: 50])
        let monitor = BatteryMonitor(reader: mock)
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(monitor.snapshot.chargePercent, 50)

        mock.liveDescription = [kIOPSCurrentCapacityKey: 73]
        mock.fireChange()
        XCTAssertEqual(monitor.snapshot.chargePercent, 73)
    }

    func testStopHaltsUpdates() {
        let mock = MockPowerSourceReader(live: [kIOPSCurrentCapacityKey: 50])
        let monitor = BatteryMonitor(reader: mock)
        monitor.start()
        monitor.stop()   // clears the mock's onChange

        mock.liveDescription = [kIOPSCurrentCapacityKey: 99]
        mock.fireChange()   // no stored callback → no update
        XCTAssertEqual(monitor.snapshot.chargePercent, 50)
    }

    func testDoubleStartIsNoOp() {
        let mock = MockPowerSourceReader(live: [kIOPSCurrentCapacityKey: 40])
        let monitor = BatteryMonitor(reader: mock)
        monitor.start()
        monitor.start()   // idempotent — no second source/timer
        defer { monitor.stop() }

        mock.liveDescription = [kIOPSCurrentCapacityKey: 41]
        mock.fireChange()
        XCTAssertEqual(monitor.snapshot.chargePercent, 41)
    }

    // MARK: - #2-glyph: Energy Mode seam + the LPM-tint trigger (deterministic, no pmset)

    /// Test double for the injected `EnergyModeReading` seam — returns a settable mode, no pmset.
    private final class FakeEnergyModeReader: EnergyModeReading {
        var mode: EnergyMode
        init(_ m: EnergyMode) { mode = m }
        func readEnergyMode() -> EnergyMode { mode }
    }

    /// energyMode is read off-thread + marshaled back, so wait for the published value (the sink fires
    /// with the current value on subscribe, so this returns immediately if already there).
    private func waitForEnergyMode(_ monitor: BatteryMonitor, _ expected: EnergyMode, _ msg: String) {
        let exp = expectation(description: msg)
        exp.assertForOverFulfill = false
        let c = monitor.$snapshot.sink { if $0.energyMode == expected { exp.fulfill() } }
        wait(for: [exp], timeout: 3)
        c.cancel()
    }

    func testEnergyModeSeam_threadsReaderValueIntoSnapshot() {
        let fake = FakeEnergyModeReader(.low)
        let monitor = BatteryMonitor(reader: MockPowerSourceReader(live: [kIOPSCurrentCapacityKey: 50]),
                                     energyModeReader: fake)
        monitor.start(); defer { monitor.stop() }
        waitForEnergyMode(monitor, .low, "the seam threads the reader's .low into snapshot.energyMode")
    }

    func testLPMNotification_reReadsAndFlipsBothDirections() {
        let fake = FakeEnergyModeReader(.automatic)
        let monitor = BatteryMonitor(reader: MockPowerSourceReader(live: [kIOPSCurrentCapacityKey: 50]),
                                     energyModeReader: fake)
        monitor.start(); defer { monitor.stop() }
        waitForEnergyMode(monitor, .automatic, "initial read")

        // ENTER Low Power Mode: the reader now returns .low; the LPM notification fires.
        fake.mode = .low
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        waitForEnergyMode(monitor, .low, "LPM on → energyMode flips to .low (glyph yellows)")

        // LEAVE Low Power Mode: reader returns .high; notification fires again.
        fake.mode = .high
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        waitForEnergyMode(monitor, .high, "LPM off → energyMode flips to .high, NOT stuck .low (regression guard)")
    }

    // MARK: - 2.E settling re-reads after a power-source event
    //
    // Owner-reported lag: at the instant of plug-in the hardware has not started charging, so the
    // T+0 sample lands in `.idleInhibit` (or |amperage| < 350 mA) and `MenuBarBatteryIcon.boltOn`
    // vetoes the bolt — below 100 % the glyph is then pixel-identical to on-battery. The correction
    // used to arrive on the 60 s poll grid. These tests pin the bounded one-shot re-reads that
    // bridge that gap. Seam doubles are reused from EventTelemetryTests (same target).

    private typealias MockRepeating = EventTelemetryTests.MockRepeating
    private typealias MockOneShot = EventTelemetryTests.MockOneShot
    private typealias Clock = EventTelemetryTests.Clock

    /// A monitor on the injectable seams, counting diagnostics reads as the "re-sample" proxy.
    private func makeSettleMonitor()
    -> (BatteryMonitor, MockPowerSourceReader, MockRepeating, MockOneShot, Clock, () -> Int) {
        let reader = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
                   kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue],
            diagnostics: ["AppleRawMaxCapacity": 5400, "DesignCapacity": 6249])
        let repeating = MockRepeating(); let oneShot = MockOneShot(); let clock = Clock()
        let monitor = BatteryMonitor(reader: reader, repeatingScheduler: repeating, oneShot: oneShot,
                                     monotonicNow: { clock.t })
        var diagReads = 0
        monitor.onDiagnosticsProperties = { _ in diagReads += 1 }
        return (monitor, reader, repeating, oneShot, clock, { diagReads })
    }

    /// A13. The monitor starts on battery; this is the plug-in the 2.E follow-ups exist for.
    private func plugIn(_ reader: MockPowerSourceReader) {
        reader.liveDescription = [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
                                  kIOPSPowerSourceStateKey: kIOPSACPowerValue]
    }
    private func unplug(_ reader: MockPowerSourceReader) {
        reader.liveDescription = [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
                                  kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
    }

    func testPowerSourceEventSchedulesTheBoundedSettleFollowUps() {
        let (monitor, reader, _, oneShot, clock, _) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }
        XCTAssertEqual(oneShot.count, 0, "start() alone schedules no settle re-reads")

        clock.t += 10
        plugIn(reader)
        reader.fireChange()
        XCTAssertEqual(oneShot.count, BatteryMonitor.eventSettleDelays.count,
                       "a power-source event schedules one bounded one-shot per settle delay")
        XCTAssertEqual(oneShot.scheduled.map(\.0), BatteryMonitor.eventSettleDelays,
                       "…at T+2 s and T+5 s")
    }

    // MARK: - A13: the settle gate (knowledge/11-MEASURE-a5-a9-a13.md §4)
    //
    // The IOPS callback is kIOPSTimeRemainingNotificationKey, MEASURED at 72.4 fires/hr on battery
    // against ZERO plug/unplug transitions in the same 945 s window. Before the gate every one of those
    // fires ran three full eventSample()s (138.17 ms, sd 33.96, n = 8) = 63.4% of the app's CPU. These
    // tests pin both halves of the gate: the T+0 sample still runs on EVERY fire (no capability lost),
    // and only a genuine powerSource transition arms the T+2 s / T+5 s re-reads.

    func testTimeRemainingFireWithNoSourceChangeSchedulesNoSettleFollowUps() {
        let (monitor, reader, _, oneShot, clock, diagReads) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }
        let baseline = diagReads()

        // A time-remaining-only fire: still on battery, the estimate (and here the SoC) moved.
        clock.t += 10
        reader.liveDescription = [kIOPSCurrentCapacityKey: 49, kIOPSIsChargingKey: false,
                                  kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
                                  kIOPSTimeToEmptyKey: 231]
        reader.fireChange()

        XCTAssertEqual(diagReads(), baseline + 1,
                       "the T+0 sample MUST still run on every fire — that is what keeps the menu-bar "
                       + "percentage and the time estimate fresh")
        XCTAssertEqual(monitor.snapshot.chargePercent, 49, "…and it reaches the snapshot")
        XCTAssertEqual(oneShot.count, 0,
                       "but a same-source notification must arm NO settle re-reads (A13)")
    }

    func testRepeatedSameSourceFiresNeverArmSettleReReads() {
        let (monitor, reader, _, oneShot, clock, diagReads) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }
        let baseline = diagReads()

        // 19 fires is what was MEASURED in 945 s on battery, with zero transitions.
        for i in 0..<19 {
            clock.t += 13
            reader.liveDescription = [kIOPSCurrentCapacityKey: 50 - i, kIOPSIsChargingKey: false,
                                      kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
            reader.fireChange()
        }
        XCTAssertEqual(diagReads(), baseline + 19, "every fire still takes its T+0 sample")
        XCTAssertEqual(oneShot.count, 0, "…and none of them arms a settle re-read")
    }

    func testUnplugTransitionAlsoArmsTheSettleFollowUps() {
        let (monitor, reader, _, oneShot, clock, _) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }

        clock.t += 10; plugIn(reader); reader.fireChange()
        XCTAssertEqual(oneShot.count, BatteryMonitor.eventSettleDelays.count, "plug in arms them")
        oneShot.fireAll()

        clock.t += 10; unplug(reader); reader.fireChange()
        XCTAssertEqual(oneShot.count, BatteryMonitor.eventSettleDelays.count,
                       "unplug is a transition too — it must arm them as well")
    }

    /// The gate keys on `powerSource`, so a same-source fire in which the settling hardware finally
    /// reports `isCharging` must NOT re-arm: that IS the state the already-pending re-reads exist to see.
    func testAFireDuringSettlingDoesNotReArmTheFollowUps() {
        let (monitor, reader, _, oneShot, clock, _) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }

        clock.t += 10; plugIn(reader); reader.fireChange()
        XCTAssertEqual(oneShot.count, 2)

        clock.t += 1                        // 1 s into the settle, a time-remaining fire arrives
        reader.liveDescription = [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: true,
                                  kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        reader.fireChange()
        XCTAssertEqual(oneShot.count, 2,
                       "still exactly the plug-in's pair — the bound is at most two live re-reads")
    }

    func testSettleFollowUpsReSampleTheSettlingHardware() {
        let (monitor, reader, _, oneShot, clock, diagReads) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }
        let baseline = diagReads()

        // T+0: plugged in, but the hardware has not started charging yet (the vetoed sample).
        clock.t += 10
        reader.liveDescription = [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
                                  kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        reader.fireChange()
        XCTAssertEqual(diagReads(), baseline + 1, "T+0 samples immediately")
        XCTAssertEqual(monitor.snapshot.isCharging, false, "…and sees the not-yet-charging hardware")

        // The hardware settles; the bounded re-reads pick it up without waiting for the 60 s poll.
        reader.liveDescription = [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: true,
                                  kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        oneShot.fireAll()
        XCTAssertEqual(diagReads(), baseline + 3, "both settle re-reads sample — exactly two")
        XCTAssertEqual(monitor.snapshot.isCharging, true, "the settled charge state reaches the glyph")
        XCTAssertEqual(oneShot.count, 0, "bounded: the re-reads schedule nothing further")
    }

    func testSettleFollowUpsDoNotSwallowAGenuineSecondTransition() {
        let (monitor, reader, _, oneShot, clock, diagReads) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }
        let baseline = diagReads()

        clock.t += 10
        plugIn(reader)
        reader.fireChange()                   // transition 1 → T+0 sample
        oneShot.fireAll()                     // its settle re-reads land (they must not touch the debounce)
        XCTAssertEqual(diagReads(), baseline + 3)

        clock.t += 0.6                        // > 500 ms later — a genuine second transition
        unplug(reader)
        reader.fireChange()
        XCTAssertEqual(diagReads(), baseline + 4, "the second transition must still sample on its leading edge")
        XCTAssertEqual(oneShot.count, BatteryMonitor.eventSettleDelays.count,
                       "…and arms its own settle re-reads")
    }

    func testStormCoalescesAndANewerEventSupersedesPendingSettleReads() {
        let (monitor, reader, _, oneShot, clock, diagReads) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }
        let baseline = diagReads()

        clock.t += 10
        plugIn(reader)
        reader.fireChange()                   // leading edge
        clock.t += 0.1; reader.fireChange()   // storm, inside the 500 ms window
        clock.t += 0.2; reader.fireChange()
        XCTAssertEqual(diagReads(), baseline + 1, "the debounce still coalesces a storm to one sample")
        XCTAssertEqual(oneShot.count, BatteryMonitor.eventSettleDelays.count,
                       "…and to one set of settle re-reads")

        clock.t += 0.6                        // a genuine second transition supersedes the first's re-reads
        unplug(reader)
        reader.fireChange()
        XCTAssertEqual(oneShot.count, 2 * BatteryMonitor.eventSettleDelays.count, "both sets are queued…")
        oneShot.fireAll()
        XCTAssertEqual(diagReads(), baseline + 4,
                       "…but only the newest event's two re-reads run (2 samples + 2 events), never four")
    }

    func testNonEventRefreshesScheduleNoSettleFollowUps() {
        let (monitor, _, repeating, oneShot, _, _) = makeSettleMonitor()
        monitor.start(); defer { monitor.stop() }

        repeating.fireTick()                  // the 60 s backstop poll
        monitor.refreshOnDemand()             // popover open
        monitor.refreshEnergyMode()
        monitor.setPollInterval(10)           // cadence change
        XCTAssertEqual(oneShot.count, 0, "only a real power-source event arms the settle re-reads")
    }

    func testSettleFollowUpsNeitherCreateATimerNorFireAfterStop() {
        let (monitor, reader, repeating, oneShot, clock, diagReads) = makeSettleMonitor()
        monitor.start()
        XCTAssertEqual(repeating.startCount, 1)

        clock.t += 10
        plugIn(reader)
        reader.fireChange()
        XCTAssertEqual(oneShot.count, BatteryMonitor.eventSettleDelays.count, "the transition armed them")
        XCTAssertEqual(repeating.startCount, 1, "settle re-reads use the one-shot seam, never a new timer")
        XCTAssertTrue(repeating.active, "the poll timer is unaffected")
        XCTAssertEqual(repeating.lastInterval, 60)

        monitor.stop()
        let afterStop = diagReads()
        oneShot.fireAll()                     // pending re-reads land after teardown
        XCTAssertEqual(diagReads(), afterStop, "a pending settle re-read is inert once stopped")
    }

    // MARK: - #HEALTH-STEADY: the health LEVEL reaches the snapshot held, not smoothed

    private final class TestClock { var t: TimeInterval = 1000 }

    /// End-to-end through the real monitor: a week of the owner's real `AppleRawMaxCapacity` jitter with
    /// a FLAT cycle count must reach `snapshot.healthPercent` as one steady number. Before the fix this
    /// published a 5-sample rolling mean that walked several points across the same input.
    func testJitteringCapacityPublishesASteadyHealthPercent() {
        // A slice of the owner's real readings (see HealthLevelFilterTests.ownerFCC for the full week).
        let fcc = [5378, 5459, 5440, 5436, 5439, 5471, 5539, 5507, 5454, 5418, 5485, 5472,
                   5493, 5479, 5540, 5456, 5485, 5430, 5477, 5499, 5456, 5501, 5511, 5501,
                   5460, 5508, 5462, 5469, 5604, 5400, 5549, 5577, 5587, 5576, 5586, 5463,
                   5462, 5388, 5352, 5270, 5316, 5322, 5398, 5367, 5412, 5408, 5426, 5453]
        let clock = TestClock()
        let mock = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: 60, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue],
            diagnostics: ["AppleRawMaxCapacity": fcc[0], "DesignCapacity": 6249, "CycleCount": 523])
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start()
        defer { monitor.stop() }

        var published: [Double] = []
        for v in fcc {
            clock.t += 60                              // the passive poll cadence
            mock.diagnosticsProperties = ["AppleRawMaxCapacity": v, "DesignCapacity": 6249,
                                          "CycleCount": 523]
            mock.fireChange()                          // → eventSample() → refreshDiagnostics()
            published.append(monitor.snapshot.healthPercent!)
        }

        let rawBand = (Double(fcc.max()!) - Double(fcc.min()!)) / 6249 * 100
        XCTAssertGreaterThan(rawBand, 5.0, "fixture sanity: the raw readings really do span >5 pp")
        XCTAssertEqual(Set(published.dropFirst(20)).count, 1,
                       "health must reach the snapshot HELD, not walking with the gauge: \(Set(published.dropFirst(20)).sorted())")
    }

    /// The filter must not change what the other diagnostics fields MEAN: raw capacity and cycle count
    /// still pass through untouched (decision #13 provenance intact — only the health noise is filtered).
    func testRawCapacityAndCyclesArePassedThroughUnfiltered() {
        let clock = TestClock()
        let mock = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: 60],
            diagnostics: ["AppleRawMaxCapacity": 5450, "DesignCapacity": 6249, "CycleCount": 523])
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }

        clock.t += 60
        mock.diagnosticsProperties = ["AppleRawMaxCapacity": 5198, "DesignCapacity": 6249,
                                      "CycleCount": 524]
        mock.fireChange()
        XCTAssertEqual(monitor.snapshot.fullChargeCapacity_mAh, 5198, "raw FCC is reported raw")
        XCTAssertEqual(monitor.snapshot.designCapacity_mAh, 6249)
        XCTAssertEqual(monitor.snapshot.cycleCount, 524, "cycle count is reported raw")
    }

    // MARK: - A9: `$snapshot` publishes only on a real change (knowledge/11-MEASURE-a5-a9-a13.md §3)
    //
    // MEASURED: 20,538 publishes/day, ~70% byte-identical to the previous one, each duplicate still
    // costing 10.15–11.49 ms because A2's render-key gate gates the PAINT, not the PUBLISH. The gate
    // is in `recompose()` rather than as a `.removeDuplicates()` on `$snapshot`, because an operator
    // downstream of `@Published` cannot suppress `objectWillChange` to the retained popover tree.

    /// A counting subscriber on the real publisher — this is the thing the five app sinks and the
    /// SwiftUI `@ObservedObject` invalidation all hang off.
    private func countingSink(_ monitor: BatteryMonitor) -> (() -> Int, AnyCancellable) {
        var n = 0
        let c = monitor.$snapshot.sink { _ in n += 1 }
        return ({ n }, c)
    }

    func testIdenticalHardwareReadPublishesNoSnapshot() {
        let live: [String: Any] = [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
                                   kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        let diag: [String: Any] = ["AppleRawMaxCapacity": 5400, "DesignCapacity": 6249,
                                   "CycleCount": 411, "Voltage": 11327]
        let clock = TestClock()
        let mock = MockPowerSourceReader(live: live, diagnostics: diag)
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }

        let (publishes, c) = countingSink(monitor)
        defer { c.cancel() }
        XCTAssertEqual(publishes(), 1, "@Published seeds the subscriber with the current value")

        // The gas gauge has not moved (measured: it advances ~once every 50 s, while the app
        // recomposes 3–4× per tick and 3× per event sample).
        clock.t += 20; mock.fireChange()
        clock.t += 20; mock.fireChange()
        clock.t += 20; mock.fireChange()
        XCTAssertEqual(publishes(), 1, "a duplicate snapshot must reach NO subscriber")
    }

    func testAChangedReadStillPublishesToEverySubscriber() {
        let clock = TestClock()
        let mock = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
                   kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue],
            diagnostics: ["AppleRawMaxCapacity": 5400, "DesignCapacity": 6249])
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }

        let (publishes, c) = countingSink(monitor)
        defer { c.cancel() }
        let seeded = publishes()

        clock.t += 20
        mock.liveDescription = [kIOPSCurrentCapacityKey: 49, kIOPSIsChargingKey: false,
                                kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        mock.fireChange()
        XCTAssertEqual(publishes(), seeded + 1, "a real change must publish exactly once")
        XCTAssertEqual(monitor.snapshot.chargePercent, 49, "…carrying the new value")

        clock.t += 20
        mock.liveDescription = [kIOPSCurrentCapacityKey: 49, kIOPSIsChargingKey: false,
                                kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        mock.fireChange()
        XCTAssertEqual(publishes(), seeded + 2, "a power-source change is a change")
        XCTAssertEqual(monitor.snapshot.powerSource, .ac)
    }

    /// `eventSample()` is three `recompose()` calls and the poll tick is four. Unchanged hardware
    /// must collapse all of them, not merely the repeats within one of them.
    func testUnchangedPollTickAndEventSampleCollapseToZeroPublishes() {
        let clock = TestClock()
        let mock = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: 77, kIOPSIsChargingKey: true,
                   kIOPSPowerSourceStateKey: kIOPSACPowerValue],
            diagnostics: ["AppleRawMaxCapacity": 5400, "DesignCapacity": 6249, "Voltage": 12100])
        let repeating = EventTelemetryTests.MockRepeating()
        let monitor = BatteryMonitor(reader: mock, repeatingScheduler: repeating,
                                     monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }

        let (publishes, c) = countingSink(monitor)
        defer { c.cancel() }
        let seeded = publishes()

        clock.t += 60; repeating.fireTick()      // the 60 s backstop poll: 4 recompose() calls
        clock.t += 60; repeating.fireTick()
        clock.t += 1;  mock.fireChange()         // an event sample: 3 more
        monitor.refreshOnDemand()                // popover open
        XCTAssertEqual(publishes(), seeded, "unchanged hardware must produce no publish at all")
    }

    /// The safety property the measurement leans on (§3.6): the charge-control classifier does NOT ride
    /// `$snapshot` — it rides `onDiagnosticsProperties`, a direct callback inside `refreshDiagnostics`.
    /// The dedup must therefore be invisible to it, or a confirm window could be starved.
    func testSnapshotDedupDoesNotStarveTheChargeControlTap() {
        let clock = TestClock()
        let mock = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: 50, kIOPSIsChargingKey: false,
                   kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue],
            diagnostics: ["AppleRawMaxCapacity": 5400, "DesignCapacity": 6249])
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        var tapCalls = 0
        monitor.onDiagnosticsProperties = { _ in tapCalls += 1 }
        monitor.start(); defer { monitor.stop() }

        let (publishes, c) = countingSink(monitor)
        defer { c.cancel() }
        let seededPublishes = publishes()
        let afterStart = tapCalls

        for _ in 0..<5 { clock.t += 20; mock.fireChange() }
        XCTAssertEqual(publishes(), seededPublishes, "no publish — the snapshot never moved")
        XCTAssertEqual(tapCalls, afterStart + 5,
                       "…but the classifier tap fires on EVERY diagnostics read, deduped or not")
    }


    /// A9 — the ONE deliberate decision the dedup forces (measurement §3.6). `HistoryStore` is the only
    /// `$snapshot` consumer whose semantics are liveness, not value: it lands a periodic row every 60 s
    /// even when nothing moved, and its rows carry `state` and `limit`, NEITHER of which is a
    /// `BatterySnapshot` field. So `BatteryApp` gives that sink `pipeline.$telemetryState` as a second
    /// trigger. This pins the property that decision rests on — the pipeline republishes its state on
    /// EVERY diagnostics ingest, unchanged value included — so that adding a `guard state != telemetryState`
    /// to the pipeline later cannot silently starve history's heartbeat. (The sink itself lives in the
    /// AppDelegate composition root and has no host app; this reproduces its publisher shape.)
    func testHistorySinkKeepsItsCadenceWhileTheSnapshotIsDeduped() {
        let reader = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: 74, kIOPSIsChargingKey: true,
                   kIOPSPowerSourceStateKey: kIOPSACPowerValue],
            diagnostics: ChargeFixtures.registryIdleInhibitDict())
        let clock = TestClock()
        let monitor = BatteryMonitor(reader: reader, monotonicNow: { clock.t })
        let box = MockClockBox(0)
        let engine = ChargeLimitEngine(runner: MockShortcutRunner(),
                                       captureStore: MockPauseCaptureStore(),
                                       clock: MockMonotonicClock(box: box))
        let pipeline = ChargeTelemetryPipeline(engine: engine, advisor: OBCAdvisor(),
                                               clock: MockMonotonicClock(box: box))
        monitor.onDiagnosticsProperties = { pipeline.ingestDiagnostics($0) }
        monitor.start(); defer { monitor.stop() }

        var snapshotOnlyOffers = 0
        var historyOffers = 0
        let cSnap = monitor.$snapshot.sink { _ in snapshotOnlyOffers += 1 }
        let cHist = monitor.$snapshot.map { _ in () }
            .merge(with: pipeline.$telemetryState.map { _ in () })
            .sink { historyOffers += 1 }
        defer { cSnap.cancel(); cHist.cancel() }
        let seedSnap = snapshotOnlyOffers, seedHist = historyOffers

        // Three diagnostics reads of byte-identical hardware — a flat stretch.
        for _ in 0..<3 { clock.t += 60; monitor.refreshOnDemand() }

        XCTAssertEqual(snapshotOnlyOffers, seedSnap,
                       "the snapshot is deduped: a flat stretch publishes nothing")
        XCTAssertEqual(historyOffers, seedHist + 3,
                       "…but history is still offered one sample per diagnostics read, so its own "
                       + "≤1/60 s rate bound and its state/limit transition rows are unaffected")
    }

    // MARK: - A9 / review item N6 — the near-miss this whole review turned on

    /// Two registry dicts that differ in ONE field the `BatterySnapshot` does not carry:
    /// `ChargerData.NotChargingReason`. Everything `BatteryTelemetryParser.parseDiagnostics` reads
    /// (cycles, voltage, amperage, capacities, temperature) is byte-identical between them, so the
    /// published snapshot cannot move — while `ChargeStateMachine` reclassifies from `.ambiguousHold`
    /// to `.limitHold`. Current is near zero on BOTH sides, which is the point: this is not a flow
    /// change dressed up as a flag change.
    private static func ncrFlipDict(notChargingReason: Int) -> [String: Any] { [
        "CurrentCapacity": 80,                 // ChargeTelemetryParser's SoC; NOT a BatterySnapshot field
        "AppleRawCurrentCapacity": 4075,       //   "        "        "  raw mAh; NOT a snapshot field
        "InstantAmperage": 31,                 // |31| < the 350 mA flow threshold on BOTH sides
        "IsCharging": true,                    // the "armed" half of the ambiguous fingerprint
        "ExternalConnected": true,
        "CycleCount": 411,                     // ↓ the four keys the SNAPSHOT reads — identical both ways
        "Voltage": 12100,
        "ChargerData": [
            "NotChargingReason": notChargingReason,
            "ChargingCurrent": 3692,
        ] as [String: Any],
    ] }

    /// **A9's near-miss, pinned.** The dedup elides the `$snapshot` publish when nothing in the
    /// snapshot moved. `HistoryStore`'s rows carry `state` and `limit`, and NEITHER is a
    /// `BatterySnapshot` field — `.ambiguousHold` and `.limitHold` differ only by
    /// `NotChargingReason`, with the current near zero on both sides. So a genuine classifier
    /// transition CAN occur across a byte-identical snapshot, and if history rode `$snapshot` alone
    /// that row would be dropped and `agg-*.json`'s `.limitHold` hours (audit §7.8, load-bearing)
    /// would be mis-attributed.
    ///
    /// `BatteryApp` therefore gives that ONE sink `pipeline.$telemetryState` as a second trigger.
    /// `testHistorySinkKeepsItsCadenceWhileTheSnapshotIsDeduped` (above) pins that the sink is still
    /// OFFERED a sample; this pins the thing that actually matters — that the offer becomes a ROW.
    /// The flip is placed 5 s after the previous row, WELL inside the store's 60 s rate bound, so the
    /// row can only have been earned by the state transition and never by the periodic heartbeat.
    func testClassifierTransitionAcrossAByteIdenticalSnapshotStillWritesAHistoryRow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("a9-ncr-flip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = TestClock()                 // the monitor's monotonic clock
        let box = MockClockBox(0)               // the pipeline's monotonic clock (stamps the samples)
        final class Wall { var t: Int; init(_ t: Int) { self.t = t } }
        let wall = Wall(1_749_600_000 + 100)    // the history store's UTC wall clock, in seconds

        let reader = MockPowerSourceReader(
            live: [kIOPSCurrentCapacityKey: 80, kIOPSIsChargingKey: true,
                   kIOPSPowerSourceStateKey: kIOPSACPowerValue],
            diagnostics: Self.ncrFlipDict(notChargingReason: 0))       // NCR 0 → the ambiguous fingerprint
        let monitor = BatteryMonitor(reader: reader, monotonicNow: { clock.t })
        let engine = ChargeLimitEngine(runner: MockShortcutRunner(),
                                       captureStore: MockPauseCaptureStore(),
                                       clock: MockMonotonicClock(box: box))
        let pipeline = ChargeTelemetryPipeline(engine: engine, advisor: OBCAdvisor(),
                                               clock: MockMonotonicClock(box: box))
        monitor.onDiagnosticsProperties = { pipeline.ingestDiagnostics($0) }
        let store = HistoryStore(root: dir, now: { wall.t })

        monitor.start(); defer { monitor.stop() }

        // The composition root's ONE history call site, reproduced
        // (`BatteryApp.applicationDidFinishLaunching`, the `historyRecordCancellable` sink).
        // ONE deviation, and only for determinism: production interposes `.receive(on: RunLoop.main)`
        // and then re-READS `pipeline.telemetryState`, which is correct there because the hop lands
        // after `@Published`'s `willSet` has committed the new value. A synchronous test has no hop, so
        // re-reading inside the sink would see the OLD state; the classifier trigger therefore carries
        // its emitted value (which IS the new one — `willSet` publishes `newValue`) and the snapshot
        // trigger, being a separate event, re-reads the already-settled state. Same rows, no run loop.
        let cHist = Publishers.Merge(
            monitor.$snapshot.map { _ -> TelemetryChargeState? in nil },
            pipeline.$telemetryState.map { Optional($0) })
            .sink { [weak monitor] published in
                MainActor.assumeIsolated {
                    guard let snap = monitor?.snapshot else { return }
                    let state = published ?? pipeline.telemetryState
                    store.ingest(HistorySample(
                        soc: snap.chargePercent,
                        watts: HistoryFormat.watts(voltageVolts: snap.voltageVolts,
                                                   amperageMilliamps: snap.amperageMilliamps),
                        onAC: snap.powerSource == .ac,
                        state: HistoryFormat.stateString(state),
                        limit: engine.limit.knownValue,
                        healthPct: snap.healthPercent,
                        cycles: snap.cycleCount,
                        maxCap_mAh: snap.fullChargeCapacity_mAh))
                }
            }
        defer { cHist.cancel() }

        // Build the SUSTAINED ambiguous fingerprint (30 s span, ≤90 s between samples).
        for _ in 0..<4 {
            clock.t += 30; box.now += 30; wall.t += 30
            reader.fireChange()
        }
        XCTAssertEqual(pipeline.telemetryState, .ambiguousHold,
                       "precondition: NCR 0 + armed + not flowing, sustained → the ambiguous hold")

        store.flush()
        let day = 1_749_600_000
        let before = store.series(range: day...(day + 86_400))
        let lastRow = try XCTUnwrap(before.last)
        XCTAssertEqual(lastRow.state, "ambiguousHold", "precondition: the ambiguous hold is on record")

        // ---- the flip: ONLY NotChargingReason moves ----
        let snapshotBefore = monitor.snapshot
        var publishesAcrossTheFlip = 0
        let cSnap = monitor.$snapshot.dropFirst().sink { _ in publishesAcrossTheFlip += 1 }
        defer { cSnap.cancel() }

        wall.t = lastRow.ts + 5          // 5 s — the 60 s rate bound CANNOT have produced the next row
        clock.t += 5; box.now += 5
        reader.diagnosticsProperties = Self.ncrFlipDict(notChargingReason: 0x0100_0000)
        reader.fireChange()

        XCTAssertEqual(monitor.snapshot, snapshotBefore,
                       "the flip moved NO BatterySnapshot field — this is the byte-identical case")
        XCTAssertEqual(publishesAcrossTheFlip, 0,
                       "…so A9 elides the publish entirely: `$snapshot` alone would starve history here")
        XCTAssertEqual(pipeline.telemetryState, .limitHold,
                       "…while the classifier genuinely transitioned on the NCR limit bit")

        store.flush()
        let after = store.series(range: day...(day + 86_400))
        XCTAssertEqual(after.count, before.count + 1,
                       "the classifier transition must still earn exactly one history row")
        XCTAssertEqual(after.last?.state, "limitHold",
                       "…and that row must carry the NEW state, or agg-*.json mis-attributes the hours")
        XCTAssertEqual(after.last?.ts, lastRow.ts + 5,
                       "…written on the transition, not deferred to the next 60 s heartbeat")
    }

}
