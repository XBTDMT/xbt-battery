import XCTest

/// Sprint 4.C + 4g: the PURE trigger math — catch-up matrices (incl. the midnight-crossing case),
/// supersession, per-local-day idempotence under clock jumps, DST forward/back, timezone change,
/// the operative occurrence, the 4g deadline-raise-fires-despite-manual-lower (no skip), value-match,
/// duplicate-time rejection. (Pause suspension is a runner concern — see ScheduleRunnerTests.)
final class ChargeScheduleTests: XCTestCase {

    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }
    private func date(_ c: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: 0))!
    }
    private func config(_ rules: [ChargeRule], enabled: Bool = true) -> ChargeScheduleConfig {
        ChargeScheduleConfig(enabled: enabled, rules: rules, presetOffered: false)
    }

    private let A = ChargeRule(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!, hour: 22, minute: 0, limit: 80)
    private let B = ChargeRule(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!, hour: 7, minute: 30, limit: 100)

    // MARK: - catch-up matrices

    func testMidnightCrossing_launchAt0030FiresYesterdays2200() {
        let c = cal("America/Chicago")
        let now = date(c, 2026, 6, 10, 0, 30)
        let action = ChargeSchedule.nextAction(now: now, calendar: c, config: config([A, B]),
                                               fired: [], currentLimit: 100)
        guard case .fire(let rule, let key) = action else { return XCTFail("expected fire, got \(action)") }
        XCTAssertEqual(rule.limit, 80, "yesterday's 22:00→80 is the operative intent at 00:30")
        XCTAssertEqual(key, "2026-06-09", "idempotence key = the occurrence's OWN local date")
    }

    func testMultiMissedSupersession_wake0900FiresOnlyMorningRule() {
        let c = cal("America/Chicago")
        let now = date(c, 2026, 6, 10, 9, 0)   // slept through 22:00 and 07:30
        let action = ChargeSchedule.nextAction(now: now, calendar: c, config: config([A, B]),
                                               fired: [], currentLimit: 80)
        guard case .fire(let rule, let key) = action else { return XCTFail("expected fire") }
        XCTAssertEqual(rule.limit, 100, "only the latest occurrence (today 07:30) fires; 22:00 superseded")
        XCTAssertEqual(key, "2026-06-10")
    }

    func testAsleepAt2200Wake0200Fires80() {
        let c = cal("America/Chicago")
        let now = date(c, 2026, 6, 10, 2, 0)
        let action = ChargeSchedule.nextAction(now: now, calendar: c, config: config([A]),
                                               fired: [], currentLimit: 100)
        guard case .fire(let rule, let key) = action else { return XCTFail("expected fire") }
        XCTAssertEqual(rule.limit, 80)
        XCTAssertEqual(key, "2026-06-09")
    }

    func testValueAlreadySatisfied_none() {
        let c = cal("America/Chicago")
        let now = date(c, 2026, 6, 10, 23, 0)
        // operative = today 22:00→80; limit already 80 → nothing to do.
        let action = ChargeSchedule.nextAction(now: now, calendar: c, config: config([A]),
                                               fired: [], currentLimit: 80)
        XCTAssertEqual(action, .none)
    }

    func testDisabledSchedule_none() {
        let c = cal("America/Chicago")
        let now = date(c, 2026, 6, 10, 23, 0)
        let action = ChargeSchedule.nextAction(now: now, calendar: c, config: config([A], enabled: false),
                                               fired: [], currentLimit: 100)
        XCTAssertEqual(action, .none)
    }

    // MARK: - idempotence (the double-fire guard)

    func testIdempotencePerLocalDayUnderClockJumps() {
        let c = cal("America/Chicago")
        let now = date(c, 2026, 6, 10, 22, 0)
        let fired: Set<FiredOccurrence> = [FiredOccurrence(ruleID: A.id, dayKey: "2026-06-10")]
        // Already fired today → none, even as the clock jumps around within the day.
        for minute in [0, 1, 5, 30, 59] {
            let jumped = date(c, 2026, 6, 10, 22, minute)
            XCTAssertEqual(ChargeSchedule.nextAction(now: jumped, calendar: c, config: config([A]),
                                                     fired: fired, currentLimit: 100),
                           .none, "minute \(minute)")
        }
        _ = now
        // A NEW local day's occurrence is NOT covered by yesterday's fired key.
        let tomorrow = date(c, 2026, 6, 11, 22, 30)
        guard case .fire(_, let key) = ChargeSchedule.nextAction(now: tomorrow, calendar: c, config: config([A]),
                                                                 fired: fired, currentLimit: 100)
        else { return XCTFail("a new day must be eligible") }
        XCTAssertEqual(key, "2026-06-11")
    }

    // MARK: - DST

    func testDSTSpringForwardDay_eveningRuleUnaffected() {
        // 2026-03-08: clocks jump 02:00→03:00 in US. A 22:00 rule is far from the gap.
        let c = cal("America/New_York")
        let now = date(c, 2026, 3, 8, 23, 0)
        guard case .fire(let rule, let key) = ChargeSchedule.nextAction(now: now, calendar: c, config: config([A]),
                                                                        fired: [], currentLimit: 100)
        else { return XCTFail("expected fire") }
        XCTAssertEqual(rule.limit, 80)
        XCTAssertEqual(key, "2026-03-08")
    }

    func testDSTFallBack_repeatedHourFiresOnce() {
        // 2026-11-01: clocks fall 02:00→01:00 — 01:30 occurs TWICE. Same local day → one fire,
        // and once fired the second 01:30 must not re-fire (idempotence by local day).
        let c = cal("America/New_York")
        let r = ChargeRule(id: A.id, hour: 1, minute: 30, limit: 80)
        let now = date(c, 2026, 11, 1, 3, 0)
        guard case .fire(_, let key) = ChargeSchedule.nextAction(now: now, calendar: c, config: config([r]),
                                                                 fired: [], currentLimit: 100)
        else { return XCTFail("expected fire") }
        XCTAssertEqual(key, "2026-11-01")
        // mark fired → the repeated hour does not produce a second fire.
        let fired: Set<FiredOccurrence> = [FiredOccurrence(ruleID: r.id, dayKey: key)]
        XCTAssertEqual(ChargeSchedule.nextAction(now: now, calendar: c, config: config([r]),
                                                 fired: fired, currentLimit: 100), .none)
    }

    // MARK: - timezone change mid-day

    func testTimeZoneRespectedPerCalendar() {
        // Same absolute instant; the operative occurrence is computed in WHICHEVER tz the calendar
        // carries (wall-clock semantics). Documented behavior — a westward hop can move the
        // operative occurrence to the prior local day (FLAGGED in the hand-back).
        let east = cal("America/New_York")
        let instant = date(east, 2026, 6, 10, 23, 0)            // 23:00 EDT
        let pacific = cal("America/Los_Angeles")                // same instant = 20:00 PDT
        guard case .fire(_, let keyE) = ChargeSchedule.nextAction(now: instant, calendar: east, config: config([A]),
                                                                  fired: [], currentLimit: 100),
              case .fire(_, let keyP) = ChargeSchedule.nextAction(now: instant, calendar: pacific, config: config([A]),
                                                                  fired: [], currentLimit: 100)
        else { return XCTFail("expected fires") }
        XCTAssertEqual(keyE, "2026-06-10", "in EDT, today's 22:00 already passed")
        XCTAssertEqual(keyP, "2026-06-09", "in PDT it's 20:00 — today's 22:00 hasn't happened; yesterday's is operative")
    }

    // MARK: - 4g thermostat-hold: no skip; the deadline-raise always fires; operative occurrence

    func testDeadlineRaiseFiresDespiteManualLower() {
        // The trip case at the pure-math layer: with no skip, a manual lower never suppresses the
        // raise. rules [22:00→80, 07:30→100]; at 07:35 with currentLimit 80 (a manual lower overnight)
        // and fired empty, the 07:30→100 occurrence fires for today.
        let c = cal("America/Chicago")
        let now = date(c, 2026, 6, 11, 7, 35)
        guard case .fire(let rule, let key) = ChargeSchedule.nextAction(now: now, calendar: c,
                                                                        config: config([A, B]),
                                                                        fired: [], currentLimit: 80)
        else { return XCTFail("the 07:30→100 raise must fire (no skip to suppress it)") }
        XCTAssertEqual(rule.limit, 100)
        XCTAssertEqual(key, "2026-06-11")
    }

    func testOperativeOccurrence() {
        // Guards the helper the Resume affordance + divergence query use.
        let c = cal("America/Chicago")
        XCTAssertEqual(ChargeSchedule.operativeOccurrence(now: date(c, 2026, 6, 10, 23, 0), calendar: c,
                                                          config: config([A, B]))?.rule.id, A.id,
                       "at 23:00 the operative is today's 22:00→80")
        XCTAssertEqual(ChargeSchedule.operativeOccurrence(now: date(c, 2026, 6, 10, 8, 0), calendar: c,
                                                          config: config([A, B]))?.rule.id, B.id,
                       "at 08:00 the operative is today's 07:30→100")
        XCTAssertNil(ChargeSchedule.operativeOccurrence(now: date(c, 2026, 6, 10, 12, 0), calendar: c,
                                                        config: config([A], enabled: false)),
                     "disabled → no operative occurrence")
    }

    // MARK: - nextTrigger / upcoming line

    func testNextTriggerPicksEarliestFuture() {
        let c = cal("America/Chicago")
        let now = date(c, 2026, 6, 10, 12, 0)   // next is today 22:00, then tomorrow 07:30
        let next = ChargeSchedule.nextTrigger(after: now, calendar: c, config: config([A, B]))
        XCTAssertEqual(next?.rule.id, A.id)
        XCTAssertEqual(ChargeSchedule.dayKey(for: next!.date, calendar: c), "2026-06-10")
    }

    // MARK: - model validation

    func testDuplicateTimeRejectedOnAddAndUpdate() {
        var cfg = ChargeScheduleConfig()
        XCTAssertTrue(cfg.addRule(ChargeRule(hour: 22, minute: 0, limit: 80)))
        XCTAssertFalse(cfg.addRule(ChargeRule(hour: 22, minute: 0, limit: 100)), "duplicate time rejected")
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertTrue(cfg.addRule(ChargeRule(hour: 7, minute: 30, limit: 100)))
        // editing the 07:30 rule onto 22:00 collides with the other rule → rejected.
        var seven = cfg.rules.first { $0.hour == 7 }!
        seven.hour = 22; seven.minute = 0
        XCTAssertFalse(cfg.updateRule(seven))
    }

    func testMaxFourRules() {
        var cfg = ChargeScheduleConfig()
        for m in 0..<6 { _ = cfg.addRule(ChargeRule(hour: 0, minute: m, limit: 80)) }
        XCTAssertEqual(cfg.rules.count, ChargeScheduleConfig.maxRules)
    }

    func testInvalidRuleRejected() {
        var cfg = ChargeScheduleConfig()
        XCTAssertFalse(cfg.addRule(ChargeRule(hour: 25, minute: 0, limit: 80)))
        XCTAssertFalse(cfg.addRule(ChargeRule(hour: 22, minute: 0, limit: 83)), "83 not a sanctioned limit")
    }

    func testStarterPreset() {
        let p = ChargeScheduleConfig.starterPreset()
        XCTAssertEqual(p.map { [$0.hour, $0.minute, $0.limit] }, [[22, 0, 80], [7, 30, 100]])
    }
}
