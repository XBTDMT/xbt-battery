import XCTest
import IOKit.ps

/// #POPOVER-TREND (2026-09-14). Owner report: "charging but the battery app shows negative draw and time
/// not charging". Measured live that evening on macOS 27.0, on the 100 W adapter: `CurrentCapacity`
/// 62 → 63 %, `RemainingCapacity` 3323 → 3375 mAh in one minute, while `IsCharging = No` and `Amperage`
/// read −619 / −1559 mA. The menu-bar bolt already read the % trend (`PackTrend`); the popover's Time and
/// Draw rows read the stale flag/current and so contradicted the bolt. These tests pin the fix — the trend
/// lives in the monitor, is vetoed at the limit, rides the snapshot, and every "is power going in" surface
/// reads it — and each red-team finding against the first cut (slow climbs, limit arrival, wake / drain /
/// hold alignment, `.unknown` blips, the Energy Pack row, per-step jumps).
@MainActor
final class PackFlowTests: XCTestCase {

    // MARK: - PackTrend hold

    /// Red-team #1: the first cut held from the last LOWER READ, so any climb slower than ~1 %/min dropped to
    /// "not rising" between steps. A step every `interval` s, a 60 s poll offset by 30 s, for an hour.
    private func flatReadsDuringClimb(stepInterval: TimeInterval) -> [TimeInterval] {
        var trend = PackTrend()
        var pct = 50
        var nextStep = stepInterval
        var flats: [TimeInterval] = []
        var t: TimeInterval = 0
        trend.push(percent: pct, at: 0)
        var poll: TimeInterval = 30
        while t < 3600 {
            if nextStep <= poll {                         // IOPS event at the step
                t = nextStep; pct += 1; nextStep += stepInterval
            } else {
                t = poll; poll += 60
            }
            trend.push(percent: pct, at: t)
            if t > stepInterval * 2 + 1, trend.verdict(at: t) != .rising { flats.append(t) }
        }
        return flats
    }

    func testSteadyClimbNeverDropsTheVerdictBetweenSteps() {
        for interval: TimeInterval in [55, 60, 65, 90, 120, 180] {
            XCTAssertEqual(flatReadsDuringClimb(stepInterval: interval), [],
                           "a steady climb of one step every \(Int(interval)) s must read rising at every read")
        }
    }

    func testRiseEndsOneAndAHalfIntervalsAfterTheStepsStop() {
        var t = PackTrend()
        t.push(percent: 70, at: 0); t.push(percent: 71, at: 60); t.push(percent: 72, at: 120)
        XCTAssertEqual(t.verdict(at: 210), .rising)       // 1.5 × 60 s = 90 s hold
        XCTAssertEqual(t.verdict(at: 211), .flat)
    }

    func testADownStepEndsTheRiseImmediately() {
        var t = PackTrend()
        t.push(percent: 70, at: 0); t.push(percent: 71, at: 60)
        t.push(percent: 70, at: 80)
        XCTAssertEqual(t.verdict(at: 81), .falling)
    }

    func testAChangeAcrossALongReadGapIsNotAStep() {
        var t = PackTrend()
        t.push(percent: 70, at: 0); t.push(percent: 71, at: 60)
        t.push(percent: 90, at: 30_000)                    // woke up after a lid-closed charge
        XCTAssertEqual(t.verdict(at: 30_000), .flat)
    }

    // MARK: - PackInflowEstimator

    func testFirstReadIsABaselineAndTwoStepsAreNotARate() {
        var e = PackInflowEstimator()
        e.push(mAh: 3323, at: 30)          // launch mid-step: when this value appeared is unknown
        e.push(mAh: 3375, at: 60)
        e.push(mAh: 3427, at: 120)
        XCTAssertNil(e.milliamps(at: 120), "two steps over one interval is too thin to quote")
    }

    func testThreeAlignedStepsGiveTheMeasuredRate() {
        var e = PackInflowEstimator()
        e.push(mAh: 3323, at: 30)
        e.push(mAh: 3375, at: 60)
        e.push(mAh: 3375, at: 90)          // repeat reads of an unchanged value do not move the step time
        e.push(mAh: 3427, at: 120)
        e.push(mAh: 3479, at: 180)
        XCTAssertEqual(e.milliamps(at: 180), 3120, "52 mAh per 60 s")
    }

    func testFallingCapacityGivesNoInflow() {
        var e = PackInflowEstimator()
        for (i, v) in [3400, 3380, 3360, 3340].enumerated() { e.push(mAh: v, at: TimeInterval(i * 60)) }
        XCTAssertNil(e.milliamps(at: 180))
    }

    /// Red-team #3: the first post-wake value appeared at an unknown time; as an anchor it quoted 18720 mA.
    func testAReadGapMakesTheNextValueABaselineNotAStep() {
        var e = PackInflowEstimator()
        for (i, v) in [3000, 3052, 3104, 3156].enumerated() { e.push(mAh: v, at: TimeInterval(i * 60)) }
        e.push(mAh: 4000, at: 30_000)                      // first read after sleep
        e.push(mAh: 4052, at: 30_010)                      // the real step lands 10 s later
        XCTAssertNil(e.milliamps(at: 30_010))
        e.push(mAh: 4104, at: 30_070)
        e.push(mAh: 4156, at: 30_130)
        XCTAssertEqual(e.milliamps(at: 30_130), 3120)
    }

    /// Red-team #4: draining on AC under load, then the load drops — the slope must not straddle the fall.
    func testAFallEndsTheRunSoTheRiseIsMeasuredOnItsOwn() {
        var e = PackInflowEstimator()
        for (i, v) in [3400, 3350, 3300, 3250, 3302, 3354, 3406].enumerated() {
            e.push(mAh: v, at: TimeInterval(i * 60))
        }
        XCTAssertEqual(e.milliamps(at: 360), 3120)
    }

    /// Red-team #4: held at the limit for minutes, then Top Up — the old step must not dilute the new rate.
    func testALongPauseBetweenStepsRestartsTheRun() {
        var e = PackInflowEstimator()
        e.push(mAh: 3000, at: 0); e.push(mAh: 3052, at: 60); e.push(mAh: 3104, at: 120)
        for t in stride(from: 180, through: 360, by: 60) { e.push(mAh: 3104, at: TimeInterval(t)) }
        e.push(mAh: 3156, at: 420)
        XCTAssertNil(e.milliamps(at: 420))
        e.push(mAh: 3208, at: 480); e.push(mAh: 3260, at: 540)
        XCTAssertEqual(e.milliamps(at: 540), 3120)
    }

    func testAPhysicallyImpossibleRateIsRefused() {
        var e = PackInflowEstimator()
        e.push(mAh: 3000, at: 0)
        e.push(mAh: 3500, at: 10); e.push(mAh: 4000, at: 60); e.push(mAh: 4500, at: 115)
        XCTAssertNil(e.milliamps(at: 115), "~15 A into the pack is an alignment artefact")
    }

    func testARunWithNoRecentStepIsStale() {
        var e = PackInflowEstimator()
        for (i, v) in [3000, 3052, 3104, 3156].enumerated() { e.push(mAh: v, at: TimeInterval(i * 60)) }
        XCTAssertNotNil(e.milliamps(at: 180))
        XCTAssertNil(e.milliamps(at: 180 + PackInflowEstimator.maxStepGap + 1))
    }

    func testResetForgetsTheBaselineToo() {
        var e = PackInflowEstimator()
        for (i, v) in [3000, 3050, 3100, 3150].enumerated() { e.push(mAh: v, at: TimeInterval(i * 60)) }
        e.reset()
        e.push(mAh: 3200, at: 240); e.push(mAh: 3250, at: 300); e.push(mAh: 3300, at: 360)
        XCTAssertNil(e.milliamps(at: 360), "after a reset the first read is a baseline again")
    }

    // MARK: - HeroStats with the trend

    /// The owner's exact popover state before the fix: on AC, smoothed current negative, IsCharging=No.
    func testTimeWithoutTrendStillSaysNotCharging() {
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 62, limit: 90,
                                          amperageMilliamps: -1559, fullChargeCapacity_mAh: 5441,
                                          minutesToEmpty: nil, isCharging: false), "Not charging")
    }

    func testTimeRisingOnACProjectsFromTheInflow() {
        // 62 → 90 % of 5441 mAh = 1523 mAh at 3120 mA ≈ 29 min (the pack really gained ~1 %/min).
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 62, limit: 90,
                                          amperageMilliamps: -1559, fullChargeCapacity_mAh: 5441,
                                          minutesToEmpty: nil, isCharging: false,
                                          packRising: true, packInflowMilliamps: 3120), "29 min to 90%")
    }

    func testTimeRisingWithNoRateYetSaysCharging() {
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 62, limit: 90,
                                          amperageMilliamps: -1559, fullChargeCapacity_mAh: 5441,
                                          minutesToEmpty: nil, isCharging: false,
                                          packRising: true, packInflowMilliamps: nil), "Charging")
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 62, limit: 90,
                                          amperageMilliamps: nil, fullChargeCapacity_mAh: 5441,
                                          minutesToEmpty: nil, isCharging: false,
                                          packRising: true, packInflowMilliamps: nil), "Charging",
                       "a rise beats an unread current")
    }

    /// Red-team #6: the ~1 s "+3.7 A" step frame must not make the row jump off the steady inflow figure.
    func testTimeRisingPrefersTheInflowOverASinglePositiveSample() {
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 62, limit: 90,
                                          amperageMilliamps: 3700, fullChargeCapacity_mAh: 5441,
                                          minutesToEmpty: nil, isCharging: true,
                                          packRising: true, packInflowMilliamps: 3120), "29 min to 90%")
        // No rate yet: the live positive sample projects (1523 mAh at 3700 mA ≈ 25 min).
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 62, limit: 90,
                                          amperageMilliamps: 3700, fullChargeCapacity_mAh: 5441,
                                          minutesToEmpty: nil, isCharging: true,
                                          packRising: true, packInflowMilliamps: nil), "25 min to 90%")
    }

    func testTimeRisingIgnoredOnBattery() {
        XCTAssertEqual(HeroStats.timeText(onAC: false, chargePercent: 50, limit: 80,
                                          amperageMilliamps: nil, fullChargeCapacity_mAh: nil,
                                          minutesToEmpty: 135, isCharging: nil,
                                          packRising: true, packInflowMilliamps: 3000), "2 h 15 m left")
    }

    func testDrawWhileRising() {
        XCTAssertEqual(HeroStats.drawMilliamps(onAC: true, packRising: true,
                                               sampledMilliamps: -1559, packInflowMilliamps: 3120), 3120)
        XCTAssertEqual(HeroStats.drawMilliamps(onAC: true, packRising: true,
                                               sampledMilliamps: 3700, packInflowMilliamps: 3120), 3120,
                       "the steady inflow, not the step frame")
        XCTAssertEqual(HeroStats.drawMilliamps(onAC: true, packRising: true,
                                               sampledMilliamps: 3700, packInflowMilliamps: nil), 3700)
        XCTAssertNil(HeroStats.drawMilliamps(onAC: true, packRising: true,
                                             sampledMilliamps: -1559, packInflowMilliamps: nil),
                     "a rise with no rate is unknown, never the stale negative figure")
        XCTAssertEqual(WattageReadout.compact(voltageVolts: 12.066, amperageMilliamps: 3120), "+37.6 W")
    }

    func testDrawKeepsTheSampleWhenNotRisingOrOnBattery() {
        XCTAssertEqual(HeroStats.drawMilliamps(onAC: true, packRising: false,
                                               sampledMilliamps: -1559, packInflowMilliamps: 3120), -1559,
                       "no rise on AC → the orange-bolt shortfall case; the negative figure is the truth")
        XCTAssertEqual(HeroStats.drawMilliamps(onAC: false, packRising: true,
                                               sampledMilliamps: -1559, packInflowMilliamps: 3120), -1559)
    }

    /// Red-team #5: the Energy page's Pack row read the raw sample and contradicted the Now page.
    func testEnergyPackRowCarriesTheSameFigureAndSaysWhereItCameFrom() {
        let row = EnergyPageModel.packRow(voltageVolts: 12.066, amperageMilliamps: 3120, onBattery: false,
                                          fromChargeTrend: true)
        XCTAssertEqual(row.value, "37.6 W · 12.1 V × 3.12 A")
        XCTAssertEqual(row.faint, "· from % climb")
        XCTAssertNil(EnergyPageModel.packRow(voltageVolts: 12.066, amperageMilliamps: -1559,
                                             onBattery: false).faint)
    }

    func testSnapshotChargingForDisplay() {
        var s = BatterySnapshot(isCharging: false, powerSource: .ac)
        XCTAssertEqual(s.isChargingForDisplay, false)
        s.packRising = true
        XCTAssertEqual(s.isChargingForDisplay, true)
        s.powerSource = .battery
        XCTAssertEqual(s.isChargingForDisplay, false, "a rise is only a charge while plugged in")
    }

    // MARK: - End to end through the real monitor, replaying the 2026-09-14 capture

    private final class Clock { var t: TimeInterval = 10_000 }

    private func live(_ pct: Int, source: String = kIOPSACPowerValue) -> [String: Any] {
        [kIOPSCurrentCapacityKey: pct, kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: source]
    }
    private func diag(_ mAh: Int, amps: Int) -> [String: Any] {
        ["AppleRawCurrentCapacity": mAh, "AppleRawMaxCapacity": 5441, "DesignCapacity": 6249,
         "CycleCount": 530, "Voltage": 12066, "Amperage": amps]
    }

    /// Steps `pct`/`mAh` once per `interval`, with a stale read (same values) half-way between steps.
    private func climb(_ monitor: BatteryMonitor, _ mock: MockPowerSourceReader, _ clock: Clock,
                       from pct: Int, mAh: Int, steps: Int, interval: TimeInterval = 60,
                       check: ((BatterySnapshot) -> Void)? = nil) {
        for i in 1...steps {
            clock.t += interval / 2; mock.fireChange(); check?(monitor.snapshot)
            clock.t += interval / 2
            mock.liveDescription = live(pct + i)
            mock.diagnosticsProperties = diag(mAh + 52 * i, amps: i.isMultiple(of: 2) ? -2048 : -1559)
            mock.fireChange(); check?(monitor.snapshot)
        }
    }

    func testStaleDrainingFramesWhileThePackClimbsReachTheSnapshotAsCharging() {
        let clock = Clock()
        let mock = MockPowerSourceReader(live: live(62), diagnostics: diag(3323, amps: -619))
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }
        monitor.setTrendVeto(limitPercent: 90, limitHold: false)

        XCTAssertFalse(monitor.snapshot.packRising, "no history yet → no claim")
        climb(monitor, mock, clock, from: 62, mAh: 3323, steps: 3)

        let s = monitor.snapshot
        XCTAssertEqual(s.isCharging, false, "the raw OS flag is passed through untouched")
        XCTAssertEqual(s.amperageMilliamps, -1559, "the raw current is passed through untouched")
        XCTAssertTrue(s.packRising)
        XCTAssertEqual(s.packInflowMilliamps, 3120)
        XCTAssertEqual(s.isChargingForDisplay, true)

        let time = HeroStats.timeText(onAC: true, chargePercent: s.chargePercent, limit: 90,
                                      amperageMilliamps: s.smoothedAmperageMilliamps,
                                      fullChargeCapacity_mAh: s.fullChargeCapacity_mAh,
                                      minutesToEmpty: s.minutesToEmpty, isCharging: s.isCharging,
                                      packRising: s.packRising, packInflowMilliamps: s.packInflowMilliamps)
        XCTAssertEqual(time, "26 min to 90%")                    // 25 % of 5441 = 1360 mAh at 3120 mA
        let draw = HeroStats.drawMilliamps(onAC: true, packRising: s.packRising,
                                           sampledMilliamps: s.amperageMilliamps,
                                           packInflowMilliamps: s.packInflowMilliamps)
        XCTAssertEqual(WattageReadout.compact(voltageVolts: s.voltageVolts, amperageMilliamps: draw), "+37.6 W")
    }

    /// Red-team #1 through the real monitor: a 2-minute-per-step climb must read charging at every read.
    func testSlowClimbReadsChargingAtEveryReadThroughTheMonitor() {
        let clock = Clock()
        let mock = MockPowerSourceReader(live: live(40), diagnostics: diag(2000, amps: -800))
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }
        monitor.setTrendVeto(limitPercent: 90, limitHold: false)
        var readsAfterFirstStep = 0, notRising = 0
        climb(monitor, mock, clock, from: 40, mAh: 2000, steps: 20, interval: 120) { s in
            guard s.chargePercent! > 40 else { return }
            readsAfterFirstStep += 1
            if !s.packRising { notRising += 1 }
        }
        XCTAssertGreaterThan(readsAfterFirstStep, 30)
        XCTAssertEqual(notRising, 0)
    }

    /// Red-team #2: arriving AT the limit the last up-step is still inside the hold — the popover must go
    /// straight to "Not charging" / "Holding at N%", as the glyph does, not claim a charge for two minutes.
    func testArrivingAtTheLimitEndsTheRiseAtOnce() {
        let clock = Clock()
        let mock = MockPowerSourceReader(live: live(87), diagnostics: diag(4700, amps: -1000))
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }
        monitor.setTrendVeto(limitPercent: 90, limitHold: false)
        climb(monitor, mock, clock, from: 87, mAh: 4700, steps: 2)
        XCTAssertTrue(monitor.snapshot.packRising, "89 %: still climbing")

        clock.t += 60
        mock.liveDescription = live(90); mock.diagnosticsProperties = diag(4856, amps: -20)
        mock.fireChange()
        let s = monitor.snapshot
        XCTAssertFalse(s.packRising)
        XCTAssertNil(s.packInflowMilliamps)
        XCTAssertEqual(HeroStats.limitText(limit: 90, chargePercent: 90, onAC: true,
                                           isCharging: s.isChargingForDisplay == true, isPaused: false).text,
                       PopoverHeroStrings.holding(90))
    }

    func testTheClassifierLimitHoldVetoesTheRiseAndReleasesIt() {
        let clock = Clock()
        let mock = MockPowerSourceReader(live: live(60), diagnostics: diag(3200, amps: -900))
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }
        monitor.setTrendVeto(limitPercent: 100, limitHold: false)
        climb(monitor, mock, clock, from: 60, mAh: 3200, steps: 2)
        XCTAssertTrue(monitor.snapshot.packRising)
        monitor.setTrendVeto(limitPercent: 100, limitHold: true)
        XCTAssertFalse(monitor.snapshot.packRising, "the veto republishes without waiting for a read")
        monitor.setTrendVeto(limitPercent: 100, limitHold: false)
        XCTAssertTrue(monitor.snapshot.packRising)
    }

    /// The verdict must EXPIRE on its own: when the climb stops the next poll-driven read has to publish
    /// "not rising", or the popover would claim charging forever off one old step.
    func testRiseExpiresOnTheNextReadAfterTheHoldWithNoNewStep() {
        let clock = Clock()
        let mock = MockPowerSourceReader(live: live(70), diagnostics: diag(3800, amps: -1000))
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }
        climb(monitor, mock, clock, from: 70, mAh: 3800, steps: 3)
        XCTAssertTrue(monitor.snapshot.packRising)

        clock.t += 100                                          // 1.5 × 60 s hold has passed, no step
        mock.fireChange()
        XCTAssertFalse(monitor.snapshot.packRising, "a rise past its hold is no longer a charge")
        XCTAssertNil(monitor.snapshot.packInflowMilliamps, "no rate is published without a live rise")
        XCTAssertEqual(monitor.snapshot.isChargingForDisplay, false)
    }

    /// Unplugging must not carry an AC-side rise onto battery, and plugging in must not read a battery-side
    /// history as a trend.
    func testPowerSourceChangeResetsTheTrend() {
        let clock = Clock()
        let mock = MockPowerSourceReader(live: live(62), diagnostics: diag(3323, amps: -619))
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }
        climb(monitor, mock, clock, from: 62, mAh: 3323, steps: 1)
        XCTAssertTrue(monitor.snapshot.packRising)

        clock.t += 5
        mock.liveDescription = live(63, source: kIOPSBatteryPowerValue)
        mock.fireChange()
        XCTAssertFalse(monitor.snapshot.packRising)

        clock.t += 5
        mock.liveDescription = live(63)
        mock.fireChange()
        XCTAssertFalse(monitor.snapshot.packRising, "back on AC: the history before the plug-in is gone")
    }

    /// Red-team #8: a dock / cable negotiation blip reports `.unknown` for one read — that is not a
    /// power-source change and must not wipe a climb.
    func testAnUnknownPowerSourceBlipKeepsTheTrend() {
        let clock = Clock()
        let mock = MockPowerSourceReader(live: live(62), diagnostics: diag(3323, amps: -619))
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }
        climb(monitor, mock, clock, from: 62, mAh: 3323, steps: 1)

        clock.t += 5
        mock.liveDescription = [kIOPSCurrentCapacityKey: 63]         // no power-source state → .unknown
        mock.fireChange()
        XCTAssertFalse(monitor.snapshot.packRising, "not on AC for this read: no claim")

        clock.t += 5
        mock.liveDescription = live(63)
        mock.fireChange()
        XCTAssertTrue(monitor.snapshot.packRising, "the climb survived the blip")
    }
}
