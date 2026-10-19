import XCTest
@testable import Battery

/// #30 §4.7 / §10 `AutomationEditorTests` slice: the Automation page's pure bits — timeline geometry,
/// row ordering + captions, the header line, "Limit now" provenance and the editor's rejection copy.
final class AutomationPageModelTests: XCTestCase {

    private let r0730 = ChargeRule(hour: 7, minute: 30, limit: 100)
    private let r2200 = ChargeRule(hour: 22, minute: 0, limit: 80)

    // MARK: - header

    func testHeaderLineWithNext() {
        XCTAssertEqual(AutomationPageModel.headerLine(next: ChargeRule(hour: 18, minute: 0, limit: 95), ruleCount: 4),
                       "next 18:00 → 95% · 4 of 4 rules")
    }
    func testHeaderLineWithoutNext() {
        XCTAssertEqual(AutomationPageModel.headerLine(next: nil, ruleCount: 2), "2 of 4 rules")
        XCTAssertEqual(AutomationPageModel.headerLine(next: nil, ruleCount: 0), "no rules")
    }

    // MARK: - timeline geometry

    func testFractionAndClamp() {
        XCTAssertEqual(AutomationPageModel.fraction(minuteOfDay: 0), 0)
        XCTAssertEqual(AutomationPageModel.fraction(minuteOfDay: 12 * 60), 0.5)
        XCTAssertEqual(AutomationPageModel.fraction(minuteOfDay: 24 * 60 + 5), 1)
        XCTAssertEqual(AutomationPageModel.fraction(minuteOfDay: -3), 0)
    }

    func testSpanCrossingMidnightIsTwoPieces() {
        // sleep 23:30 → wake 06:45: [0, 06:45] + [23:30, 24:00]
        let s = AutomationPageModel.spans(sleep: 23 * 60 + 30, wake: 6 * 60 + 45)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].lowerBound, 0)
        XCTAssertEqual(s[0].upperBound, Double(6 * 60 + 45) / 1440, accuracy: 1e-9)
        XCTAssertEqual(s[1].lowerBound, Double(23 * 60 + 30) / 1440, accuracy: 1e-9)
        XCTAssertEqual(s[1].upperBound, 1)
    }

    func testSpanWithinTheDayIsOnePiece() {
        let s = AutomationPageModel.spans(sleep: 13 * 60, wake: 14 * 60)
        XCTAssertEqual(s, [Double(13 * 60) / 1440...Double(14 * 60) / 1440])
    }

    func testOneSidedSpans() {
        XCTAssertEqual(AutomationPageModel.spans(sleep: nil, wake: 6 * 60), [0...0.25])
        XCTAssertEqual(AutomationPageModel.spans(sleep: 18 * 60, wake: nil), [0.75...1])
        XCTAssertEqual(AutomationPageModel.spans(sleep: nil, wake: nil), [])
        XCTAssertEqual(AutomationPageModel.spans(sleep: nil, wake: 0), [], "a wake at 00:00 draws nothing")
    }

    func testTimelineLabelsAndTicks() {
        let t = AutomationPageModel.timeline(nowMinute: 13 * 60 + 21, sleep: 23 * 60 + 30, wake: 6 * 60 + 45,
                                             rules: [r2200, r0730])
        XCTAssertEqual(t.now.label, "now 13:21")
        XCTAssertEqual(t.now.fraction, Double(13 * 60 + 21) / 1440, accuracy: 1e-9)
        XCTAssertEqual(t.wake?.label, "06:45 wake")
        XCTAssertEqual(t.sleep?.label, "23:30 sleep")
        XCTAssertEqual(t.rules.map(\.label), ["07:30 → 100", "22:00 → 80"], "rule ticks are sorted by time")
        XCTAssertEqual(t.spans.count, 2)
    }

    // MARK: - label collision rule (R15 F5: ≥ 52 pt from the previous drawn label on the same side)

    private func label(_ x: Double, above: Bool, priority: Bool = false) -> AutomationPageModel.TimelineLabel {
        .init(text: "\(x)", x: x, above: above, priority: priority)
    }

    func testLabelsCloserThan52OnTheSameSideAreSkipped() {
        // above: 30, 70 (40 apart → skip), 130 (60 from the drawn 30 → draw). below: 72 (own side → draw).
        let drawn = AutomationPageModel.drawnLabels([label(30, above: true), label(70, above: true),
                                                     label(130, above: true), label(72, above: false)])
        XCTAssertEqual(drawn, [true, false, true, true])
    }

    func testLabelCullingIsByXOrderNotInputOrder() {
        let drawn = AutomationPageModel.drawnLabels([label(100, above: true), label(26, above: true), label(78, above: true)])
        // x order: 26 draws, 78 is 52 from 26 → draws, 100 is 22 from 78 → skipped (flags in input order).
        XCTAssertEqual(drawn, [false, true, true])
    }

    func testNowAlwaysDrawsAndReservesItsNeighbourhood() {
        // A rule label 40 pt before "now" would collide with it, so the rule label yields even though
        // it comes first in x order; a label 52+ away still draws.
        let drawn = AutomationPageModel.drawnLabels([label(145, above: true), label(185, above: true, priority: true),
                                                     label(93, above: true)])
        XCTAssertEqual(drawn, [false, true, true])
    }

    func testExactly52IsEnough() {
        XCTAssertEqual(AutomationPageModel.drawnLabels([label(26, above: false), label(78, above: false)]), [true, true])
        XCTAssertEqual(AutomationPageModel.drawnLabels([label(26, above: false), label(77.9, above: false)]), [true, false])
    }

    // MARK: - blue span source: read-back when authored, else config

    private func config(sleep: (Int, Int)?, wake: (Int, Int)?, mask: Int = 31) -> SleepWakeScheduleConfig {
        var c = SleepWakeScheduleConfig()
        if let sleep { c.sleepEnabled = true; c.sleepHour = sleep.0; c.sleepMinute = sleep.1 }
        if let wake { c.wakeEnabled = true; c.wakeHour = wake.0; c.wakeMinute = wake.1 }
        c.weekdayMask = mask
        return c
    }

    func testSleepWakeMinutesFromAuthoredReadback() {
        let cfg = config(sleep: (23, 30), wake: (6, 45))
        let rb = RepeatingSchedule(events: [
            RepeatingPowerEvent(kind: .sleep, minuteOfDay: 23 * 60 + 30, weekdayMask: 31),
            RepeatingPowerEvent(kind: .wake, minuteOfDay: 6 * 60 + 45, weekdayMask: 31)])
        let m = AutomationPageModel.sleepWakeMinutes(config: cfg, readback: rb)
        XCTAssertEqual(m.sleep, 23 * 60 + 30); XCTAssertEqual(m.wake, 6 * 60 + 45)
    }

    func testSleepWakeMinutesFallsBackToConfigWhenReadbackIsForeignOrAbsent() {
        let cfg = config(sleep: (23, 30), wake: nil)
        let foreign = RepeatingSchedule(events: [RepeatingPowerEvent(kind: .sleep, minuteOfDay: 60, weekdayMask: 127)])
        let m1 = AutomationPageModel.sleepWakeMinutes(config: cfg, readback: foreign)
        XCTAssertEqual(m1.sleep, 23 * 60 + 30, "a foreign schedule is never painted as ours")
        XCTAssertNil(m1.wake)
        let m2 = AutomationPageModel.sleepWakeMinutes(config: cfg, readback: nil)
        XCTAssertEqual(m2.sleep, 23 * 60 + 30); XCTAssertNil(m2.wake)
        let off = AutomationPageModel.sleepWakeMinutes(config: config(sleep: nil, wake: nil), readback: .none)
        XCTAssertNil(off.sleep); XCTAssertNil(off.wake)
    }

    // MARK: - rows

    func testRowsAreChronologicalWakeLimitSleep() {
        let rows = AutomationPageModel.rows(config: config(sleep: (23, 30), wake: (6, 45)), rules: [r2200, r0730])
        XCTAssertEqual(rows.map(\.time), ["06:45", "07:30", "22:00", "23:30"])
        XCTAssertEqual(rows.map(\.title), ["Wake", "Limit → 100%", "Limit → 80%", "Sleep"])
        XCTAssertEqual(rows.first?.id, "wake"); XCTAssertEqual(rows.last?.id, "sleep")
    }

    func testRowsOmitDisabledSides() {
        let rows = AutomationPageModel.rows(config: config(sleep: nil, wake: nil), rules: [r0730])
        XCTAssertEqual(rows.map(\.title), ["Limit → 100%"])
    }

    func testRowTieBreakWakeBeforeLimitBeforeSleep() {
        let same = ChargeRule(hour: 7, minute: 0, limit: 90)
        let rows = AutomationPageModel.rows(config: config(sleep: (7, 0), wake: (7, 0)), rules: [same])
        XCTAssertEqual(rows.map(\.title), ["Wake", "Limit → 90%", "Sleep"])
    }

    // MARK: - captions

    func testLimitCaptions() {
        XCTAssertEqual(AutomationPageModel.limitCaption(fired: true, isNext: false), "fired")
        XCTAssertEqual(AutomationPageModel.limitCaption(fired: false, isNext: true), "next")
        XCTAssertEqual(AutomationPageModel.limitCaption(fired: false, isNext: false), "")
        XCTAssertEqual(AutomationPageModel.limitCaption(fired: true, isNext: true), "fired", "fired wins")
    }

    func testDaysCaption() {
        XCTAssertEqual(AutomationPageModel.daysCaption(weekdayMask: 127), "every day")
        XCTAssertEqual(AutomationPageModel.daysCaption(weekdayMask: 31), "Mon–Fri")
        XCTAssertEqual(AutomationPageModel.daysCaption(weekdayMask: 96), "weekends")
        XCTAssertEqual(AutomationPageModel.daysCaption(weekdayMask: 0b0010101), "Mon, Wed, Fri")
        XCTAssertEqual(AutomationPageModel.daysCaption(weekdayMask: 0), "no days")
    }

    // MARK: - closing card

    func testLimitNowBySchedule() {
        XCTAssertEqual(AutomationPageModel.limitNowText(limit: 80, source: .schedule, operativeTime: "22:00",
                                                        custodyAt: Date()),
                       "80% · by schedule at 22:00")
    }

    func testLimitNowFromCustodyAfterRelaunch() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let at = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 9, minute: 5))!
        XCTAssertEqual(AutomationPageModel.limitNowText(limit: 90, source: .user, operativeTime: "22:00",
                                                        custodyAt: at, calendar: cal),
                       "90% · set 09:05")
        // A .schedule source without an operative rule (schedule since disabled) falls back to custody.
        XCTAssertEqual(AutomationPageModel.limitNowText(limit: 90, source: .schedule, operativeTime: nil,
                                                        custodyAt: at, calendar: cal),
                       "90% · set 09:05")
    }

    func testLimitNowDegenerateCases() {
        XCTAssertEqual(AutomationPageModel.limitNowText(limit: nil, source: .user, operativeTime: nil, custodyAt: nil), "—")
        XCTAssertEqual(AutomationPageModel.limitNowText(limit: 85, source: .user, operativeTime: nil, custodyAt: nil), "85%")
    }

    func testEnergyRuleText() {
        XCTAssertEqual(AutomationPageModel.energyRuleText(enabled: true, highWhenPlugged: true), "Auto · Low ≤20% · High plugged")
        XCTAssertEqual(AutomationPageModel.energyRuleText(enabled: true, highWhenPlugged: false), "Auto · Low ≤20%")
        XCTAssertEqual(AutomationPageModel.energyRuleText(enabled: false, highWhenPlugged: true), "Off")
    }

    func testKeepAwakePresetsMatchTheMock() {
        XCTAssertEqual(AutomationPageModel.keepAwakePresets.map(\.label), ["30 m", "1 h", "2 h", "on power"])
        XCTAssertEqual(AutomationPageModel.keepAwakePresets.map(\.duration),
                       [.timed(1800), .timed(3600), .timed(7200), .whileOnAC])
    }

    // MARK: - editor rejections mirror the config API

    func testRejectionMessagesMatchAddRuleAndUpdateRule() {
        var cfg = ChargeScheduleConfig(enabled: true, rules: [r0730, r2200], presetOffered: true)
        // duplicate time (new)
        let dup = ChargeRule(hour: 22, minute: 0, limit: 90)
        XCTAssertEqual(AutomationPageModel.rejectionMessage(config: cfg, rule: dup, isNew: true), "that time is taken")
        XCTAssertFalse(cfg.addRule(dup))
        // duplicate time (edit moved onto another rule)
        var moved = r0730; moved.hour = 22; moved.minute = 0
        XCTAssertEqual(AutomationPageModel.rejectionMessage(config: cfg, rule: moved, isNew: false), "that time is taken")
        XCTAssertFalse(cfg.updateRule(moved))
        // editing a rule onto its OWN time is fine
        var same = r0730; same.limit = 90
        XCTAssertNil(AutomationPageModel.rejectionMessage(config: cfg, rule: same, isNew: false))
        XCTAssertTrue(cfg.updateRule(same))
        // fifth rule
        XCTAssertTrue(cfg.addRule(ChargeRule(hour: 12, minute: 0, limit: 90)))
        XCTAssertTrue(cfg.addRule(ChargeRule(hour: 18, minute: 0, limit: 95)))
        let fifth = ChargeRule(hour: 1, minute: 0, limit: 80)
        XCTAssertEqual(AutomationPageModel.rejectionMessage(config: cfg, rule: fifth, isNew: true), "four rules is the limit")
        XCTAssertFalse(cfg.addRule(fifth))
        XCTAssertNil(AutomationPageModel.rejectionMessage(config: cfg, rule: fifth, isNew: false),
                     "the cap applies to adds, not edits")
    }

    func testDefaultNewRuleAvoidsTakenTimes() {
        let cfg = ChargeScheduleConfig(enabled: true, rules: [r2200, r0730], presetOffered: true)
        let d = AutomationPageModel.defaultNewRule(config: cfg)
        XCTAssertFalse(cfg.rules.contains { $0.minuteOfDay == d.minuteOfDay })
        XCTAssertEqual(d.timeLabel, "07:00", "22:00 is taken; 07:00 is the next preferred slot (07:30 is a different minute)")
        var full = cfg
        XCTAssertNil(AutomationPageModel.rejectionMessage(config: full, rule: d, isNew: true))
        XCTAssertTrue(full.addRule(d))
    }

    // MARK: - "Sleeps after" (spec 31 §2.3, G-1 / T1)

    private func timers(battery: (Int?, Int?), power: (Int?, Int?)) -> SleepTimerSettings {
        SleepTimerSettings(battery: SleepTimers(systemMinutes: battery.0, displayMinutes: battery.1),
                           charger: SleepTimers(systemMinutes: power.0, displayMinutes: power.1))
    }

    func testSleepsAfterUsesTheEffectiveMinutesNotTheRawSleepValue() {
        // This Mac, `pmset -g custom` 2026-09-28: battery sleep 1 / displaysleep 10; AC sleep 0 / displaysleep 20.
        // powerd holds the system awake while the display is on, so battery idle-sleeps at 10, not 1.
        let s = AutomationPageModel.sleepsAfterText(timers(battery: (1, 10), power: (0, 20)))
        XCTAssertEqual(s.text, "battery 10 min · power never")
        XCTAssertEqual(s.help, "battery: system 1 min, display 10 min · power: system never, display 20 min")
    }

    func testSleepsAfterSystemLongerThanDisplayAndHours() {
        // The render harness fixture (battery 10/5, AC 0/20) and an hours value.
        XCTAssertEqual(AutomationPageModel.sleepsAfterText(timers(battery: (10, 5), power: (0, 20))).text,
                       "battery 10 min · power never")
        XCTAssertEqual(AutomationPageModel.sleepsAfterText(timers(battery: (10, 5), power: (90, 20))).text,
                       "battery 10 min · power 1 hr 30 min")
    }

    func testSleepsAfterDisplayNeverMeansTheMacNeverIdleSleeps() {
        // displaysleep 0 keeps powerd's display-on assertion up for good, so the system never idle-sleeps.
        XCTAssertEqual(AutomationPageModel.sleepsAfterText(timers(battery: (5, 0), power: (0, 0))).text,
                       "battery never · power never")
    }

    func testSleepsAfterUnreadDisplayIsDashNotTheRawSystemValue() {
        // effectiveSystemSleepMinutes returns the raw `1` when the display is unknown — the false claim
        // this row exists to avoid.
        let s = AutomationPageModel.sleepsAfterText(timers(battery: (1, nil), power: (0, 20)))
        XCTAssertEqual(s.text, "battery — · power never")
        XCTAssertEqual(s.help, "battery: system 1 min, display — · power: system never, display 20 min")
    }

    func testSleepsAfterUnreadSystemIsDash() {
        XCTAssertEqual(AutomationPageModel.sleepsAfterText(timers(battery: (1, 10), power: (nil, 20))).text,
                       "battery 10 min · power —")
    }

    func testSleepsAfterNeverReadOrAllUnreadIsOneDash() {
        let never = AutomationPageModel.sleepsAfterText(nil)
        XCTAssertEqual(never.text, "—")
        XCTAssertEqual(never.help, "Sleep timers not read yet")
        let failed = AutomationPageModel.sleepsAfterText(.unknown)
        XCTAssertEqual(failed.text, "—")
        XCTAssertEqual(failed.help, "battery: system —, display — · power: system —, display —")
    }

    // MARK: - scroll cue (spec 31 §2.4, Q1)

    func testCanScrollWhenEditingOrTallerThanTheFrame() {
        XCTAssertTrue(AutomationPageModel.canScroll(isEditing: true, contentHeight: 300, viewport: 470))
        XCTAssertTrue(AutomationPageModel.canScroll(isEditing: false, contentHeight: 471, viewport: 470))
        XCTAssertFalse(AutomationPageModel.canScroll(isEditing: false, contentHeight: 470.5, viewport: 470),
                       "half a point of layout rounding is not a scroll")
        XCTAssertFalse(AutomationPageModel.canScroll(isEditing: false, contentHeight: 0, viewport: 470),
                       "the zero initial height before the first measurement is not scrollable")
    }

    func testContentBelowDrivesTheBottomFade() {
        // at rest, 30 pt below the frame → fade on
        XCTAssertTrue(AutomationPageModel.hasContentBelow(contentTop: 0, contentHeight: 500, viewport: 470))
        // half-way down → still on
        XCTAssertTrue(AutomationPageModel.hasContentBelow(contentTop: -15, contentHeight: 500, viewport: 470))
        // scrolled to the bottom → off
        XCTAssertFalse(AutomationPageModel.hasContentBelow(contentTop: -30, contentHeight: 500, viewport: 470))
        // rubber-banded past the bottom → off
        XCTAssertFalse(AutomationPageModel.hasContentBelow(contentTop: -40, contentHeight: 500, viewport: 470))
        // content fits → off
        XCTAssertFalse(AutomationPageModel.hasContentBelow(contentTop: 0, contentHeight: 470, viewport: 470))
    }
}
