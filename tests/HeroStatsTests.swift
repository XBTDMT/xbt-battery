import XCTest
@testable import Battery

/// #29 hero v2: the pure stat strings (Time formatter + adaptive Time + Limit branch), host-app-free.
final class HeroStatsTests: XCTestCase {

    // MARK: - hm(_:) formatter — drops a zero component

    func testHmHoursAndMinutes() {
        XCTAssertEqual(HeroStats.hm(135), "2 h 15 m")
        XCTAssertEqual(HeroStats.hm(90), "1 h 30 m")
    }
    func testHmMinutesOnly() { XCTAssertEqual(HeroStats.hm(45), "45 min") }
    func testHmHoursOnly()   { XCTAssertEqual(HeroStats.hm(120), "2 h") }
    func testHmZero()        { XCTAssertEqual(HeroStats.hm(0), "0 min") }
    func testHmClampsNegative() { XCTAssertEqual(HeroStats.hm(-30), "0 min") }

    // MARK: - adaptive Time row (projected to the limit / to empty — computed from current + capacity)

    // Charging: time to the LIMIT (or "to full" at 100), computed from smoothed current + capacity.

    func testTimeChargingReadsTimeToLimit() {
        // 23% → 80% limit at 5401 mA into a 5280 mAh pack ≈ 33 min.
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 23, limit: 80,
                                          amperageMilliamps: 5401, fullChargeCapacity_mAh: 5280,
                                          minutesToEmpty: nil), "33 min to 80%")
    }
    func testTimeChargingToFullWhenLimitIs100() {
        // 50% → 100% at 5000 mA into a 6000 mAh pack = 36 min, worded "to full".
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 50, limit: 100,
                                          amperageMilliamps: 5000, fullChargeCapacity_mAh: 6000,
                                          minutesToEmpty: nil), "36 min to full")
    }
    func testTimeChargingToFullWhenLimitUnknown() {
        // no limit set → target is 100 → "to full".
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 40, limit: nil,
                                          amperageMilliamps: 6000, fullChargeCapacity_mAh: 6000,
                                          minutesToEmpty: nil), "36 min to full")
    }
    func testTimeChargingWithoutCapacityFallsBackToCharging() {
        // charging but no capacity to estimate from → the state word, not a bogus time.
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 23, limit: 80,
                                          amperageMilliamps: 5000, fullChargeCapacity_mAh: nil,
                                          minutesToEmpty: nil), "Charging")
    }
    func testTimeHeldAtLimitReadsNotCharging() {
        // on the adapter, no inflow (held at the limit) → "Not charging" (unchanged behavior).
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 80, limit: 80,
                                          amperageMilliamps: -20, fullChargeCapacity_mAh: 5280,
                                          minutesToEmpty: nil), "Not charging")
    }
    func testTimeIdleInhibitBelowLimitReadsNotCharging() {
        // on AC, below the limit but drawing no current (transient idle-inhibit) → "Not charging".
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 65, limit: 80,
                                          amperageMilliamps: 0, fullChargeCapacity_mAh: 5280,
                                          minutesToEmpty: nil), "Not charging")
    }

    // Discharging: time until empty — prefer the OS estimate, else compute from charge + draw.

    func testTimeDischargingPrefersOSEstimate() {
        XCTAssertEqual(HeroStats.timeText(onAC: false, chargePercent: 60, limit: 80,
                                          amperageMilliamps: -1732, fullChargeCapacity_mAh: 5280,
                                          minutesToEmpty: 135), "2 h 15 m left")
    }
    func testTimeDischargingComputesWhenOSEstimateAbsent() {
        // OS "still calculating" (nil) → compute: 50% of 6000 mAh at 3000 mA = 60 min.
        XCTAssertEqual(HeroStats.timeText(onAC: false, chargePercent: 50, limit: 80,
                                          amperageMilliamps: -3000, fullChargeCapacity_mAh: 6000,
                                          minutesToEmpty: nil), "1 h left")
    }
    func testTimeOnBatteryNoSignalReadsNotPluggedIn() {
        // on battery, no OS estimate and no capacity/draw to compute from → honest fallback.
        XCTAssertEqual(HeroStats.timeText(onAC: false, chargePercent: nil, limit: 80,
                                          amperageMilliamps: 0, fullChargeCapacity_mAh: nil,
                                          minutesToEmpty: nil), "Not plugged in")
    }

    // MARK: - projection math (pure)

    func testMinutesToChargeToLimit() {
        // (80−23)/100 × 5280 = 3009.6 mAh; / 5401 mA × 60 ≈ 33 min.
        XCTAssertEqual(HeroStats.minutesToCharge(from: 23, to: 80, fcc: 5280, milliamps: 5401), 33)
    }
    func testMinutesToChargeNilWhenAlreadyAtTarget() {
        XCTAssertNil(HeroStats.minutesToCharge(from: 80, to: 80, fcc: 5280, milliamps: 5401))
    }
    func testMinutesToChargeNilWithoutCurrentOrCapacity() {
        XCTAssertNil(HeroStats.minutesToCharge(from: 23, to: 80, fcc: nil, milliamps: 5401))
        XCTAssertNil(HeroStats.minutesToCharge(from: 23, to: 80, fcc: 5280, milliamps: 0))
    }
    func testMinutesToDrainToEmpty() {
        // 50% of 6000 mAh = 3000 mAh; / 3000 mA × 60 = 60 min.
        XCTAssertEqual(HeroStats.minutesToDrain(percent: 50, fcc: 6000, milliamps: -3000), 60)
    }
    func testMinutesToDrainNilWhenNotDischarging() {
        // non-negative current is not a discharge.
        XCTAssertNil(HeroStats.minutesToDrain(percent: 50, fcc: 6000, milliamps: 3000))
    }

    // MARK: - AmperageSmoother (rolling mean; resets on a charge↔discharge flip)

    func testSmootherReturnsFirstSampleVerbatim() {
        var s = AmperageSmoother()
        XCTAssertEqual(s.push(5000), 5000)
    }
    func testSmootherRollingMeanSameSign() {
        var s = AmperageSmoother()
        _ = s.push(4000)
        XCTAssertEqual(s.push(6000), 5000)   // mean(4000, 6000)
    }
    func testSmootherCapsWindow() {
        var s = AmperageSmoother(window: 3)
        _ = s.push(3000); _ = s.push(3000); _ = s.push(3000)
        XCTAssertEqual(s.push(9000), 5000)   // mean of the last three: (3000, 3000, 9000)
    }
    func testSmootherResetsOnSignFlip() {
        var s = AmperageSmoother()
        _ = s.push(5000)                     // charging
        XCTAssertEqual(s.push(-3000), -3000) // flip to discharge → window cleared, no averaging across the flip
    }
    /// #POPOVER-TREND live capture 2026-09-14: arriving at the limit the current goes to exactly 0 mA; averaged
    /// in, the mean stepped 2450 → 1956 → 1468 … and the Time row said "Charging" while held.
    func testSmootherResetsIntoAndOutOfAnExactZero() {
        var s = AmperageSmoother()
        for _ in 0..<5 { _ = s.push(2450) }
        XCTAssertEqual(s.push(0), 0, "the hold starts a fresh window")
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 90, limit: 90,
                                          amperageMilliamps: 0, fullChargeCapacity_mAh: 5435,
                                          minutesToEmpty: nil, isCharging: false), "Not charging")
        XCTAssertEqual(s.push(2400), 2400, "charging resumes: no dilution by the zeros")
    }

    // MARK: - Limit branch (Holding gated on the actual at-limit condition)

    func testLimitHoldingAtLimitOnAC() {
        let r = HeroStats.limitText(limit: 80, chargePercent: 80, onAC: true, isCharging: false, isPaused: false)
        XCTAssertEqual(r.text, "Holding at 80%")
        XCTAssertTrue(r.holding)
    }
    func testLimitHoldingAboveLimitOnAC() {
        let r = HeroStats.limitText(limit: 80, chargePercent: 85, onAC: true, isCharging: false, isPaused: false)
        XCTAssertEqual(r.text, "Holding at 80%")
        XCTAssertTrue(r.holding)
    }
    func testLimitBelowLimitNotChargingReadsPlain() {
        // on AC, not charging, but BELOW the limit (transient idle-inhibit) → NOT "Holding".
        let r = HeroStats.limitText(limit: 80, chargePercent: 65, onAC: true, isCharging: false, isPaused: false)
        XCTAssertEqual(r.text, "80%")
        XCTAssertFalse(r.holding)
    }
    func testLimitUnknownChargingBelowLimitReadsPlain() {
        // isCharging == nil coerces to false at the caller; below the limit it must still read plain.
        let r = HeroStats.limitText(limit: 80, chargePercent: 65, onAC: true, isCharging: false, isPaused: false)
        XCTAssertEqual(r.text, "80%")
        XCTAssertFalse(r.holding)
    }
    func testLimitPausedIsLevelIndependent() {
        // paused wins regardless of level (even below the limit) and is never green.
        let r = HeroStats.limitText(limit: 80, chargePercent: 60, onAC: true, isCharging: false, isPaused: true)
        XCTAssertEqual(r.text, "Paused at 80%")
        XCTAssertFalse(r.holding)
    }
    func testLimitPlainOnBattery() {
        let r = HeroStats.limitText(limit: 80, chargePercent: 80, onAC: false, isCharging: false, isPaused: false)
        XCTAssertEqual(r.text, "80%")
        XCTAssertFalse(r.holding)
    }
    func testLimitPlainWhileChargingOnAC() {
        let r = HeroStats.limitText(limit: 80, chargePercent: 70, onAC: true, isCharging: true, isPaused: false)
        XCTAssertEqual(r.text, "80%")
        XCTAssertFalse(r.holding)
    }
    func testLimitNilRendersEmDash() {
        let r = HeroStats.limitText(limit: nil, chargePercent: 80, onAC: true, isCharging: false, isPaused: false)
        XCTAssertEqual(r.text, "—")
        XCTAssertFalse(r.holding)
    }

    // MARK: - #29 C1 re-home: the degraded provenance tag on the Limit row

    /// In VERIFIED mode the figure IS a read, so no custody suffix may appear — a "· as set" there
    /// would be a lie of emphasis.
    func testLimitRow_verifiedModeCarriesNoTag() {
        let r = HeroStats.limitRowText(limit: 80, chargePercent: 70, onAC: true, isCharging: true,
                                       isPaused: false, readBackDegraded: false, telemetryState: .charging)
        XCTAssertEqual(r.text, "80%")
    }

    /// Degraded + not holding → "· as set": the number is the value we last WROTE, never one we read.
    func testLimitRow_degradedTagsAsSet() {
        let r = HeroStats.limitRowText(limit: 80, chargePercent: 70, onAC: true, isCharging: true,
                                       isPaused: false, readBackDegraded: true, telemetryState: .charging)
        XCTAssertEqual(r.text, "80% · as set")
    }

    /// The one that matters most: the native "Charge to 100% Now" suspended the cap and the pack is
    /// charging PAST the limit the row is showing.
    func testLimitRow_degradedSurfacesAnExternalOverride() {
        let r = HeroStats.limitRowText(limit: 80, chargePercent: 81, onAC: true, isCharging: true,
                                       isPaused: false, readBackDegraded: true, telemetryState: .charging)
        XCTAssertEqual(r.text, "80% · Overridden Externally")
    }

    /// "Holding at 80% · holding" is the same fact twice in a 320-pt row — the suffix is dropped.
    func testLimitRow_doesNotSayHoldingTwice() {
        let r = HeroStats.limitRowText(limit: 80, chargePercent: 80, onAC: true, isCharging: false,
                                       isPaused: false, readBackDegraded: true, telemetryState: .limitHold)
        XCTAssertEqual(r.text, "Holding at 80%")
        XCTAssertTrue(r.holding)
    }

    /// …but a hold the telemetry has NOT classified still gets the custody tag: the row's own
    /// "Holding at N%" is a charge-proximity inference, and the tag is the verified truth.
    func testLimitRow_unclassifiedHoldStillGetsTheTag() {
        let r = HeroStats.limitRowText(limit: 80, chargePercent: 80, onAC: true, isCharging: false,
                                       isPaused: false, readBackDegraded: true, telemetryState: .ambiguousHold)
        XCTAssertEqual(r.text, "Holding at 80% · as set")
    }

    /// A pause is the user's own stop, so the tag function excludes it — the row keeps saying "Paused".
    func testLimitRow_pausedKeepsTheAsSetCustody() {
        let r = HeroStats.limitRowText(limit: 80, chargePercent: 90, onAC: true, isCharging: false,
                                       isPaused: true, readBackDegraded: true, telemetryState: .limitHold)
        XCTAssertEqual(r.text, "Paused at 80% · as set")
    }

    func testLimitRow_nilLimitNeverGetsATag() {
        let r = HeroStats.limitRowText(limit: nil, chargePercent: 80, onAC: true, isCharging: false,
                                       isPaused: false, readBackDegraded: true, telemetryState: .limitHold)
        XCTAssertEqual(r.text, "—")
    }

    // MARK: - #29 C1: battery-condition tone (macOS 27 made "Unknown" a legitimate reading)

    func testHealthTone_normalIsHealthy() {
        XCTAssertEqual(HeroStats.healthTone("Normal"), .healthy)
    }

    /// macOS 27 removed `PermanentFailureStatus` outright. An unreadable key is an ABSENCE, not a
    /// warning — painting it the same orange as a failing pack is a false alarm on every M4 Mac.
    func testHealthTone_unknownIsNeutralNotAWarning() {
        XCTAssertEqual(HeroStats.healthTone("Unknown"), .neutral)
    }

    func testHealthTone_aConditionWeReadAndThatIsBadGetsAttention() {
        XCTAssertEqual(HeroStats.healthTone("Service recommended"), .attention)
    }

    /// The tone map is driven by `BatteryLifetime.condition`, so it must agree with what that produces.
    func testHealthTone_agreesWithTheModelsOwnConditionStrings() {
        XCTAssertEqual(HeroStats.healthTone(lifetimeFixture(pfs: 0).condition), .healthy)
        XCTAssertEqual(HeroStats.healthTone(lifetimeFixture(pfs: nil).condition), .neutral)
        XCTAssertEqual(HeroStats.healthTone(lifetimeFixture(pfs: 1).condition), .attention)
    }

    private func lifetimeFixture(pfs: Int?) -> BatteryLifetime {
        BatteryLifetime(cycleCount: 12, designCapacity_mAh: 6250, nominalCapacity_mAh: 5500,
                        rawMaxCapacity_mAh: 5381, permanentFailureStatus: pfs,
                        lifetimeMinTempC: nil, lifetimeMaxTempC: nil, lifetimeAvgTempDeciC: nil,
                        dailyMinSoc: nil, dailyMaxSoc: nil,
                        lifetimeMinPackVoltage_mV: nil, lifetimeMaxPackVoltage_mV: nil,
                        lifetimeMaxChargeCurrent_mA: nil, lifetimeMaxDischargeCurrent_mA: nil)
    }

    // MARK: - SWEEP §2.G · an UNREAD current is not "Not charging" (12-SWEEP-silent-absence.md, hit 3)

    /// RED-first, the collapse itself. `timeText` opened with `let amp = amperageMilliamps ?? 0`, so a
    /// nil current on AC took the `amp > 0` branch as FALSE and the row asserted "Not charging" — a
    /// positive claim manufactured out of no reading. The two facts below produced the SAME string.
    func testTimeText_unreadCurrentOnACIsNotAFindingOfNotCharging() {
        // A real, read 0 mA on the adapter: the pack genuinely is not taking charge. This may say so.
        let measured = HeroStats.timeText(onAC: true, chargePercent: 80, limit: 80,
                                          amperageMilliamps: 0, fullChargeCapacity_mAh: 6000,
                                          minutesToEmpty: nil, isCharging: false)
        XCTAssertEqual(measured, "Not charging")

        // The current was never read AND the OS flag says it IS charging. The old shape printed
        // "Not charging" here — the exact opposite of the truth, from an absence.
        let unread = HeroStats.timeText(onAC: true, chargePercent: 80, limit: 100,
                                        amperageMilliamps: nil, fullChargeCapacity_mAh: 6000,
                                        minutesToEmpty: nil, isCharging: true)
        XCTAssertEqual(unread, "Charging")
        XCTAssertNotEqual(unread, measured, "absence and a measured zero must not be the same sentence")
    }

    /// With the current unread, the OS's own `isCharging` flag is the second witness — the same move
    /// `temperatureReading` makes with cycleCount and `RawCorroboration` makes with the coulomb counter.
    func testTimeText_fallsBackToTheIsChargingWitnessWhenTheCurrentIsUnread() {
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 50, limit: 80,
                                          amperageMilliamps: nil, fullChargeCapacity_mAh: nil,
                                          minutesToEmpty: nil, isCharging: true), "Charging")
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 50, limit: 80,
                                          amperageMilliamps: nil, fullChargeCapacity_mAh: nil,
                                          minutesToEmpty: nil, isCharging: false), "Not charging")
    }

    /// Neither witness read: say so. "Unknown" is the word `BatteryLifetime.condition` already uses for
    /// a key we could not read — never a fabricated state word, and never the forbidden bare em-dash.
    func testTimeText_bothWitnessesUnreadSaysUnknown() {
        let t = HeroStats.timeText(onAC: true, chargePercent: nil, limit: nil,
                                   amperageMilliamps: nil, fullChargeCapacity_mAh: nil,
                                   minutesToEmpty: nil, isCharging: nil)
        XCTAssertEqual(t, "Unknown")
        XCTAssertNotEqual(t, "Not charging", "no reading is not a finding")
        XCTAssertNotEqual(t, "—", "the row still never renders a bare em-dash")
    }

    /// The measured paths are untouched: a real positive current still projects, and the on-battery half
    /// still restates the fact we DID read (`onAC == false`).
    func testTimeText_measuredPathsAreUnchangedByTheThreeStateSplit() {
        XCTAssertEqual(HeroStats.timeText(onAC: true, chargePercent: 50, limit: 100,
                                          amperageMilliamps: 3000, fullChargeCapacity_mAh: 6000,
                                          minutesToEmpty: nil, isCharging: true), "1 h to full")
        XCTAssertEqual(HeroStats.timeText(onAC: false, chargePercent: 50, limit: 80,
                                          amperageMilliamps: nil, fullChargeCapacity_mAh: 6000,
                                          minutesToEmpty: nil, isCharging: nil), "Not plugged in")
        XCTAssertEqual(HeroStats.timeText(onAC: false, chargePercent: 50, limit: 80,
                                          amperageMilliamps: nil, fullChargeCapacity_mAh: nil,
                                          minutesToEmpty: 135, isCharging: nil), "2 h 15 m left")
    }

    // MARK: - D1 B (§16 "32 · Now · day's low", ruled 2026-10-18): the day's low is red only at ≤ 20 %

    func testDayLowAt41IsSecondary() { XCTAssertEqual(HeroStats.dayLowTone(soc: 41), .secondary) }
    func testDayLowAt20IsCritical()  { XCTAssertEqual(HeroStats.dayLowTone(soc: 20), .critical) }
    func testDayLowAt21IsSecondary() { XCTAssertEqual(HeroStats.dayLowTone(soc: 21), .secondary) }
    func testDayLowAt0IsCritical()   { XCTAssertEqual(HeroStats.dayLowTone(soc: 0), .critical) }
    /// An unread low makes no tint claim (absence is not a fact): no tone, so the view draws no low at all.
    func testDayLowUnreadMakesNoTintClaim() { XCTAssertNil(HeroStats.dayLowTone(soc: nil)) }

    /// The day's low and the menu-bar glyph share ONE threshold: at the edge both agree (glyph off the charger).
    func testDayLowSharesTheGlyphRedThreshold() {
        XCTAssertEqual(BatteryRedRule.threshold, 20)
        for soc in [BatteryRedRule.threshold, BatteryRedRule.threshold + 1] {
            let glyphRed = MenuBarBatteryIcon.render(soc: soc, isChargingDisplay: false, holdMark: false,
                                                     fullyCharged: false, onAC: false, lowPower: false,
                                                     keepAwake: false).colorMode == .redAlert
            XCTAssertEqual(HeroStats.dayLowTone(soc: soc) == .critical, glyphRed, "soc \(soc)")
        }
    }
}
