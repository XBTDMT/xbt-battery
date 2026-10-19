import XCTest

/// spec 31 §2.1 (G-6): the on-power bands with 92 % / 85 % hysteresis and the ±0.5 W dead band, the port
/// 0.5 W / 0.3 W hysteresis, the SystemPowerIn-0-on-AC unread rule, and the on-battery cost line.
final class PortPowerMathTests: XCTestCase {

    private let iPhoneWatts = 14.054

    private func band(_ s: inout OnPowerBandState, _ systemIn: Int?, ceiling: Int? = 65_000,
                      p: Double?, watts: Double = 14.054) -> OnPowerBand {
        s.update(systemPowerIn_mW: systemIn, ceiling_mW: ceiling, packPower_mW: p, portWatts: watts)
    }

    // MARK: bands

    func testSaturatedAndGainingIsSlower() {
        var s = OnPowerBandState()
        let b = band(&s, 61_000, p: 5_600)              // 93.8 % of 65 W
        XCTAssertEqual(b, .slower(watts: 14))
        XCTAssertTrue(s.saturated)
    }

    func testHysteresisHoldsBetween85And92() {
        var s = OnPowerBandState()
        _ = band(&s, 61_000, p: 5_600)                  // enter at 93.8 %
        let held = band(&s, 57_000, p: 5_600)           // 87.7 %: inside the hold
        let left = band(&s, 55_000, p: 5_600)           // 84.6 % ≤ 85 %: leave
        let notYet = band(&s, 59_000, p: 5_600)         // 90.8 % < 92 %: stay out
        let back = band(&s, 60_000, p: 5_600)           // 92.3 % ≥ 92 %: enter
        XCTAssertEqual(held, .slower(watts: 14))
        XCTAssertEqual(left, .headroom)
        XCTAssertEqual(notYet, .headroom)
        XCTAssertEqual(back, .slower(watts: 14))
    }

    func testSaturatedAndLosingIsFromBatteryCappedByDraw() {
        var s = OnPowerBandState()
        _ = band(&s, 61_000, p: 5_600)
        let capped = band(&s, 61_000, p: -9_000)        // only 9 W is actually leaving the pack
        let full = band(&s, 61_000, p: -52_000)         // the live −52 W frame: the port's own 14 W
        XCTAssertEqual(capped, .fromBattery(watts: 9))
        XCTAssertEqual(full, .fromBattery(watts: 14))
    }

    func testDeadBandAtALimitHoldIsNoLine() {
        var s = OnPowerBandState()
        _ = band(&s, 61_000, p: 5_600)
        let up = band(&s, 61_000, p: 400)
        let down = band(&s, 61_000, p: -400)
        let edge = band(&s, 61_000, p: 500)
        let over = band(&s, 61_000, p: 501)
        XCTAssertEqual(up, .none)
        XCTAssertEqual(down, .none)
        XCTAssertEqual(edge, .none, "headroom / slower need P > +0.5 W")
        XCTAssertEqual(over, .slower(watts: 14))

        var idle = OnPowerBandState()
        let unsaturatedHold = band(&idle, 40_000, p: 200)
        XCTAssertEqual(unsaturatedHold, .none, "an unsaturated limit hold never says \"doesn't slow\"")
    }

    func testUnsaturatedAndLosingIsNoLine() {
        var s = OnPowerBandState()
        let b = band(&s, 50_000, p: -9_000)
        XCTAssertEqual(b, .none)
    }

    func testUnreadSystemPowerLeavesStateUntouched() {
        var s = OnPowerBandState()
        _ = band(&s, 61_000, p: 5_600)
        let missing = band(&s, nil, p: 5_600)
        let zero = band(&s, 0, p: 5_600)
        XCTAssertEqual(missing, .none)
        XCTAssertEqual(zero, .none)
        XCTAssertTrue(s.saturated, "an unread frame carries no information about saturation")
        let next = band(&s, 57_000, p: 5_600)
        XCTAssertEqual(next, .slower(watts: 14), "the hold survives the unread frames")
    }

    func testCeilingChangeReEvaluatesFresh() {
        var s = OnPowerBandState()
        _ = band(&s, 61_000, ceiling: 65_000, p: 5_600)
        XCTAssertTrue(s.saturated)
        let swapped = band(&s, 60_000, ceiling: 68_000, p: 5_600)   // 88.2 % of the new ceiling
        XCTAssertEqual(swapped, .headroom, "a new charger is judged fresh, not through the old hold")
        XCTAssertFalse(s.saturated)
        XCTAssertEqual(s.lastCeiling_mW, 68_000)
    }

    func testNoPortsDrawingMakesNoClaimButStillTracksSaturation() {
        var s = OnPowerBandState()
        let b = band(&s, 61_000, p: 5_600, watts: 0)
        XCTAssertEqual(b, .none)
        XCTAssertTrue(s.saturated)
    }

    func testUnreadCeilingOrPackPowerIsNoLine() {
        var s = OnPowerBandState()
        let noCeiling = band(&s, 61_000, ceiling: nil, p: 5_600)
        let noPack = band(&s, 61_000, p: nil)
        let nanPack = band(&s, 61_000, p: .nan)
        XCTAssertEqual(noCeiling, .none)
        XCTAssertEqual(noPack, .none)
        XCTAssertEqual(nanPack, .none)
    }

    func testGarbageWattsNeverTrap() {
        var s = OnPowerBandState()
        let infinite = band(&s, 61_000, p: 5_600, watts: .infinity)
        let huge = band(&s, 61_000, p: 5_600, watts: 1e15)
        let drain = band(&s, 61_000, p: -.infinity)
        XCTAssertEqual(infinite, .none)
        XCTAssertEqual(huge, .none)
        XCTAssertEqual(drain, .none)
    }

    // MARK: port hysteresis

    func testPortHysteresisOnAt500OffBelow300() {
        var h = PortPowerHysteresis()
        let a = h.isDrawing(portIndex: 2, filteredPower_mW: 499)
        let b = h.isDrawing(portIndex: 2, filteredPower_mW: 500)
        let c = h.isDrawing(portIndex: 2, filteredPower_mW: 300)
        let d = h.isDrawing(portIndex: 2, filteredPower_mW: 299)
        let e = h.isDrawing(portIndex: 2, filteredPower_mW: 450)
        XCTAssertEqual([a, b, c, d, e], [false, true, true, false, false])
    }

    func testRetainForgetsAbsentPorts() {
        var h = PortPowerHysteresis()
        _ = h.isDrawing(portIndex: 2, filteredPower_mW: 14_054)
        h.retain(only: [])
        let back = h.isDrawing(portIndex: 2, filteredPower_mW: 400)
        XCTAssertFalse(back, "a port that went absent re-enters below 0.5 W as not drawing")
    }

    // MARK: SystemPowerIn 0 on AC

    func testSystemPowerInZeroOnACIsUnread() {
        let zero = PowerTelemetry(systemPowerIn_mW: 0, systemLoad_mW: 52_000, batteryPower_mW: -52_000,
                                  accBatteryPower: nil, cntBatteryPower: nil,
                                  accBatteryDischarge: nil, cntBatteryDischarge: nil)
        XCTAssertNil(PortPowerMath.systemPowerIn(zero, externalConnected: true), "0 on AC is a transient → unread")
        XCTAssertEqual(PortPowerMath.systemPowerIn(zero, externalConnected: false), 0, "0 on battery is simply true")
        XCTAssertEqual(PortPowerMath.systemPowerIn(PortPowerFixtures.telemetry(PortPowerFixtures.base), externalConnected: true), 62_706)
        XCTAssertNil(PortPowerMath.systemPowerIn(nil, externalConnected: true))
    }

    // MARK: battery cost

    func testCostLineFromTheCellCountAndAveragedDraw() {
        // 3 banks × 3.86 V = 11.58 V; pack 5 400 mAh = 62.532 Wh; remaining 2 538 mAh = 29.390 Wh; draw 25 W.
        let line = BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: -25_000,
                                    remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3)
        XCTAssertEqual(line, BatteryCostLine(percentPerHour: 22,          // 14.054 / 62.532 = 22.47 %
                                             timeLeft: 4_260,             // 29.390 / 25 h = 70.5 → 71 min
                                             timeLeftWithout: 9_660))     // 29.390 / 10.946 h = 161.1 → 161 min
    }

    func testWithoutTimeHiddenBelowTheQuarterGuard() {
        // draw 16 W, port 14.054 W → the rest is 1.946 W < 25 % of 16 W.
        let line = BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: -16_000,
                                    remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3)
        XCTAssertEqual(line, BatteryCostLine(percentPerHour: 22, timeLeft: 6_600, timeLeftWithout: nil))
    }

    func testNoCostLineWhenThePackIsNotLosing() {
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: 0,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3))
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: 3_000,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3))
    }

    func testNoCostLineWhenAnyInputIsUnread() {
        let p = -25_000.0
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: nil, remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3))
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: p, remaining_mAh: nil, fullCharge_mAh: 5_400, bankCount: 3))
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: p, remaining_mAh: 2_538, fullCharge_mAh: nil, bankCount: 3))
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: p, remaining_mAh: 2_538, fullCharge_mAh: 0, bankCount: 3))
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: p, remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: nil))
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: p, remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 0))
        XCTAssertNil(BatteryCost.line(portWatts: 0, packPower_mW: p, remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3))
    }

    func testPortWattsSumsInDoubleWithoutOverflow() {
        let huge = PortPower(portIndex: 5, filteredPower_mW: .max, watts_mW: nil, contract_mW: nil,
                             current_mA: nil, voltage_mV: nil, accumulatedPower: nil, accumulatorCount: nil)
        let hugeTwin = PortPower(portIndex: 6, filteredPower_mW: .max, watts_mW: nil, contract_mW: nil,
                                 current_mA: nil, voltage_mV: nil, accumulatedPower: nil, accumulatorCount: nil)
        let watts = PortPowerMath.portWatts([huge, hugeTwin])            // would trap as an Int sum
        XCTAssertGreaterThan(watts, PortPowerMath.maxPlausibleWatts)
        XCTAssertNil(BatteryCost.line(portWatts: watts, packPower_mW: -25_000,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3))
        XCTAssertEqual(PortPowerMath.portWatts([PortPowerFixtures.capturedIPhonePort]), 14.054, accuracy: 0.000_1)
    }

    // MARK: exact boundaries (both sides)

    func testExactly92PercentEntersAndJustBelowDoesNot() {
        var below = OnPowerBandState()
        XCTAssertEqual(band(&below, 59_799, p: 5_600), .headroom)      // 91.998 %
        XCTAssertFalse(below.saturated)
        var exact = OnPowerBandState()
        XCTAssertEqual(band(&exact, 59_800, p: 5_600), .slower(watts: 14))   // exactly 92 %
        XCTAssertTrue(exact.saturated)
    }

    func testExactly85PercentLeavesAndJustAboveHolds() {
        var hold = OnPowerBandState()
        _ = band(&hold, 61_000, p: 5_600)
        XCTAssertEqual(band(&hold, 55_251, p: 5_600), .slower(watts: 14))    // 85.0015 %: still held
        XCTAssertTrue(hold.saturated)
        var leave = OnPowerBandState()
        _ = band(&leave, 61_000, p: 5_600)
        XCTAssertEqual(band(&leave, 55_250, p: 5_600), .headroom)            // exactly 85 %: leaves
        XCTAssertFalse(leave.saturated)
    }

    func testLosingDeadBandEdgeBothSides() {
        var s = OnPowerBandState()
        _ = band(&s, 61_000, p: 5_600)
        XCTAssertEqual(band(&s, 61_000, p: -500), .none, "fromBattery needs P < -0.5 W")
        XCTAssertEqual(band(&s, 61_000, p: -501), .fromBattery(watts: 1))
    }

    func testFromBatteryWattsRoundHalfAwayAndZeroIsNoLine() {
        var s = OnPowerBandState()
        _ = band(&s, 61_000, p: 5_600)
        XCTAssertEqual(band(&s, 61_000, p: -1_500), .fromBattery(watts: 2))
        XCTAssertEqual(band(&s, 61_000, p: -9_000, watts: 0.4), .none, "a port under 0.5 W rounds to 0 W: no claim")
    }

    func testSameCeilingKeepsHoldWhileNewCeilingReEnters() {
        var s = OnPowerBandState()
        _ = band(&s, 61_000, ceiling: 65_000, p: 5_600)
        // A different ceiling at a level that is >= 92 % of it enters fresh.
        XCTAssertEqual(band(&s, 62_600, ceiling: 68_000, p: 5_600), .slower(watts: 14))
        XCTAssertTrue(s.saturated)
    }

    func testRetainKeepsPresentPortsHeld() {
        var h = PortPowerHysteresis()
        _ = h.isDrawing(portIndex: 2, filteredPower_mW: 14_054)
        _ = h.isDrawing(portIndex: 3, filteredPower_mW: 14_054)
        h.retain(only: [2])
        XCTAssertTrue(h.isDrawing(portIndex: 2, filteredPower_mW: 400), "port 2 stayed held above 0.3 W")
        XCTAssertFalse(h.isDrawing(portIndex: 3, filteredPower_mW: 400), "port 3 was forgotten")
    }

    func testPortsAreHeldIndependently() {
        var h = PortPowerHysteresis()
        _ = h.isDrawing(portIndex: 1, filteredPower_mW: 600)
        XCTAssertFalse(h.isDrawing(portIndex: 2, filteredPower_mW: 400), "port 2 has its own 0.5 W entry")
        XCTAssertTrue(h.isDrawing(portIndex: 1, filteredPower_mW: 400))
    }

    func testWithoutGuardExactlyAtAQuarterShowsAndJustUnderHides() {
        // draw 16 W. Port 12 W leaves exactly 4 W = 25 % of the draw.
        let at = BatteryCost.line(portWatts: 12, packPower_mW: -16_000,
                                  remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3)
        XCTAssertNotNil(at?.timeLeftWithout, "the rest is exactly 25 % of the draw: shown")
        let under = BatteryCost.line(portWatts: 12.001, packPower_mW: -16_000,
                                     remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3)
        XCTAssertNotNil(under)
        XCTAssertNil(under?.timeLeftWithout, "the rest is just under 25 %: hidden")
    }

    // FIX 2: on battery the port's power comes out of the pack, so a pack loss below the port's draw is an
    // inconsistent frame (mismatched sample windows) -> no line. (Replaces testNoWithoutTimeWhenThePortsExceedTheDraw,
    // which asserted a line for 30 W of ports on a 25 W draw.)
    func testNoLineWhenThePortsExceedThePackDraw() {
        XCTAssertNil(BatteryCost.line(portWatts: 30, packPower_mW: -25_000,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3))
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: -300,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3),
                     "14 W of ports against a 0.3 W pack loss is not a real frame")
    }

    func testDrawExactlyEqualToPortWattsGivesALineWithoutTPrime() {
        let equal = BatteryCost.line(portWatts: 14, packPower_mW: -14_000,
                                     remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3)
        XCTAssertNotNil(equal, "draw == port W is allowed")
        XCTAssertNil(equal?.timeLeftWithout, "nothing is left after the ports: the 25 % guard hides T'")
        XCTAssertNil(BatteryCost.line(portWatts: 14, packPower_mW: -13_999.9,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3),
                     "draw just below the port W is inconsistent")
    }

    // FIX 3: the seconds products can overflow to infinity after the hours check.
    func testOverflowingSecondsAreNotALine() {
        // drawW = portWatts = 1e-306 W: hoursLeft = 2.9e307 is finite, hoursLeft * 3600 is not.
        XCTAssertNil(BatteryCost.line(portWatts: 1e-306, packPower_mW: -1e-303,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3),
                     "T not finite -> no line")
        // drawW = 7e-304 W, port = a quarter of it: T ~ 1.5e308 s is finite, T' ~ 2.0e308 s is not.
        let line = BatteryCost.line(portWatts: 1.75e-304, packPower_mW: -7e-301,
                                    remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3)
        XCTAssertNotNil(line, "T finite -> the line stands")
        XCTAssertNotNil(line.map { $0.timeLeft.isFinite ? 1 : nil }, "T is finite")
        XCTAssertNil(line?.timeLeftWithout, "T' not finite -> T' is nil")
    }

    func testCostLineAtTheSmallestLossAndZeroRemaining() {
        XCTAssertNotNil(BatteryCost.line(portWatts: 1e-6, packPower_mW: -0.001,
                                         remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3),
                        "any P < 0 is losing")
        let empty = BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: -25_000,
                                     remaining_mAh: 0, fullCharge_mAh: 5_400, bankCount: 3)
        XCTAssertEqual(empty?.timeLeft, 0)
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: -25_000,
                                      remaining_mAh: -1, fullCharge_mAh: 5_400, bankCount: 3))
        XCTAssertNil(BatteryCost.line(portWatts: .nan, packPower_mW: -25_000,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3))
        XCTAssertNil(BatteryCost.line(portWatts: iPhoneWatts, packPower_mW: -.infinity,
                                      remaining_mAh: 2_538, fullCharge_mAh: 5_400, bankCount: 3))
    }

    func testSystemPowerInIsUnreadWhenTheACFlagIsUnknown() {
        let t = PortPowerFixtures.telemetry(PortPowerFixtures.base)
        XCTAssertNil(PortPowerMath.systemPowerIn(t, externalConnected: nil),
                     "spec 5.5: ExternalConnected unread -> no on-power line, whatever the value")
        XCTAssertEqual(PortPowerMath.systemPowerIn(t, externalConnected: false), 62_706)
        XCTAssertEqual(PortPowerMath.systemPowerIn(t, externalConnected: true), 62_706)
        let zero = PowerTelemetry(systemPowerIn_mW: 0, systemLoad_mW: nil, batteryPower_mW: nil,
                                  accBatteryPower: nil, cntBatteryPower: nil,
                                  accBatteryDischarge: nil, cntBatteryDischarge: nil)
        XCTAssertNil(PortPowerMath.systemPowerIn(zero, externalConnected: nil))
        XCTAssertNil(PortPowerMath.systemPowerIn(zero, externalConnected: true))
        XCTAssertEqual(PortPowerMath.systemPowerIn(zero, externalConnected: false), 0)
        let unread = PowerTelemetry(systemPowerIn_mW: nil, systemLoad_mW: 1, batteryPower_mW: nil,
                                    accBatteryPower: nil, cntBatteryPower: nil,
                                    accBatteryDischarge: nil, cntBatteryDischarge: nil)
        XCTAssertNil(PortPowerMath.systemPowerIn(unread, externalConnected: false))
    }

    /// S5.3 fix: the notice (`PortPowerDisplayModel.percentPerHour`) and the page's cost line (`BatteryCost.line`)
    /// once multiplied the pack's Wh in a different order and split an exact .5 tie by 1 %.
    func testNoticeRateAndCostLineRateAgreeAtAnExactTie() throws {
        for (fcc, watts) in [(5_920, 42.846), (6_320, 45.741)] {
            let line = try XCTUnwrap(BatteryCost.line(portWatts: watts, packPower_mW: -(watts * 1_000 + 20_000),
                                                      remaining_mAh: 3_000, fullCharge_mAh: fcc, bankCount: 3))
            XCTAssertEqual(PortPowerDisplayModel.percentPerHour(portWatts: watts, fullCharge_mAh: fcc, bankCount: 3),
                           line.percentPerHour, "FCC \(fcc) at \(watts) W")
        }
    }
}
