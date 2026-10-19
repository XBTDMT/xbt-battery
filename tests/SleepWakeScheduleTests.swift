import XCTest

/// Sprint 3.7 (sleep/wake) STAGE 2: the PURE app-side read-back parser + the single-owner authored-
/// comparison + the config validity rule. Host-app-free (mirrors ChargeScheduleTests): the app-side
/// source compiles INTO the test target, so these reference the types directly (no app-module import).
final class SleepWakeScheduleTests: XCTestCase {

    // MARK: - parse: the "Repeating power events:" section only

    func testParse_liveProbeFixture_oneWakeEvent() {
        // The on-device probe: a wakeorpoweron reads back NORMALIZED as "wakepoweron", MTWRF as "weekdays only".
        let s = SleepWakeReadback.parse("Repeating power events:\n  wakepoweron at 4:10PM weekdays only")
        XCTAssertEqual(s.events.count, 1)
        XCTAssertEqual(s.events.first, RepeatingPowerEvent(kind: .wake, minuteOfDay: 970, weekdayMask: 31))
    }

    func testParse_bothForm_sleepThenWake() {
        let out = """
        Repeating power events:
          sleep at 11:30PM weekdays only
          wakepoweron at 7:00AM weekdays only
        """
        XCTAssertEqual(SleepWakeReadback.parse(out).events, [
            RepeatingPowerEvent(kind: .sleep, minuteOfDay: 23 * 60 + 30, weekdayMask: 31),
            RepeatingPowerEvent(kind: .wake,  minuteOfDay: 7 * 60,       weekdayMask: 31),
        ])
    }

    func testParse_noRepeatingEvents_isNone() {
        XCTAssertEqual(SleepWakeReadback.parse(""), .none)
        XCTAssertEqual(SleepWakeReadback.parse("Repeating power events:"), .none, "header only → no events")
    }

    func testParse_ignoresScheduledOneTimeSection() {
        let out = """
        Repeating power events:
          sleep at 11:30PM weekdays only
        Scheduled power events:
          wake at 7/1/2026 9:00AM
        """
        let s = SleepWakeReadback.parse(out)
        XCTAssertEqual(s.events.count, 1, "the one-time Scheduled section ends the Repeating section and is not parsed")
        XCTAssertEqual(s.events.first?.kind, .sleep)
    }

    // MARK: - parseTwelveHour

    func testParseTwelveHour() {
        XCTAssertEqual(SleepWakeReadback.parseTwelveHour("12:00AM"), 0,   "midnight")
        XCTAssertEqual(SleepWakeReadback.parseTwelveHour("12:30PM"), 750, "noon + 30")
        XCTAssertEqual(SleepWakeReadback.parseTwelveHour("4:10PM"),  970)
        XCTAssertEqual(SleepWakeReadback.parseTwelveHour("7:00AM"),  420)
        XCTAssertNil(SleepWakeReadback.parseTwelveHour("nonsense"))
    }

    // MARK: - parseDaySpec

    func testParseDaySpec() {
        XCTAssertEqual(SleepWakeReadback.parseDaySpec("weekdays only"), 31)
        XCTAssertEqual(SleepWakeReadback.parseDaySpec("weekends only"), 96)
        XCTAssertEqual(SleepWakeReadback.parseDaySpec("every day"),     127)
        XCTAssertEqual(SleepWakeReadback.parseDaySpec("MWF"),           21)
        XCTAssertEqual(SleepWakeReadback.parseDaySpec("MTWRFSU"),       127)
        XCTAssertNil(SleepWakeReadback.parseDaySpec("XYZ"), "an unrecognized letter → nil")
    }

    // MARK: - isAuthored: the conservative single-owner comparison

    func testIsAuthored() {
        let live = SleepWakeReadback.parse("Repeating power events:\n  wakepoweron at 4:10PM weekdays only")

        // foreign: the live (not-ours) event vs the empty config → NOT ours (must confirm before clobber)
        XCTAssertFalse(SleepWakeReadback.isAuthored(by: .empty, matching: live))

        // ours: a wake-only config at 16:10 mask 31 exactly matches the read-back → recognized as ours
        var mine = SleepWakeScheduleConfig.empty
        mine.wakeEnabled = true; mine.wakeHour = 16; mine.wakeMinute = 10; mine.weekdayMask = 31
        XCTAssertTrue(SleepWakeReadback.isAuthored(by: mine, matching: live))

        // an EMPTY system → vacuously ours (nothing to clobber), for any config
        XCTAssertTrue(SleepWakeReadback.isAuthored(by: mine, matching: .none))
        XCTAssertTrue(SleepWakeReadback.isAuthored(by: .empty, matching: .none))

        // a both-config vs its EXACT matching read-back → ours
        var both = SleepWakeScheduleConfig.empty
        both.sleepEnabled = true; both.sleepHour = 23; both.sleepMinute = 30
        both.wakeEnabled = true;  both.wakeHour = 7;   both.wakeMinute = 0; both.weekdayMask = 31
        let bothRead = SleepWakeReadback.parse("""
        Repeating power events:
          sleep at 11:30PM weekdays only
          wakepoweron at 7:00AM weekdays only
        """)
        XCTAssertTrue(SleepWakeReadback.isAuthored(by: both, matching: bothRead))

        // an EXTRA third event the config didn't author → NOT ours
        let extra = SleepWakeReadback.parse("""
        Repeating power events:
          sleep at 11:30PM weekdays only
          wakepoweron at 7:00AM weekdays only
          wakepoweron at 9:00AM weekends only
        """)
        XCTAssertFalse(SleepWakeReadback.isAuthored(by: both, matching: extra))

        // an UNPARSEABLE day-spec field → NOT ours (we cannot positively recognize it)
        let badDay = SleepWakeReadback.parse("Repeating power events:\n  wakepoweron at 4:10PM someday")
        XCTAssertFalse(SleepWakeReadback.isAuthored(by: mine, matching: badDay))
    }

    // MARK: - isAuthored regression: duplicate-collapse must not false-positive

    func testIsAuthored_duplicateCollapse_isForeign() {
        // A foreign system of TWO identical sleep events vs a sleep+wake config: counts match
        // (2 == 2) and each foreign sleep is a member of the expected set, but the expected WAKE
        // is never present. The old membership test returned true here (silent-clobber); the
        // consuming multiset match must return false.
        var both = SleepWakeScheduleConfig.empty
        both.sleepEnabled = true; both.sleepHour = 23; both.sleepMinute = 30
        both.wakeEnabled = true;  both.wakeHour = 7;   both.wakeMinute = 0; both.weekdayMask = 31
        let twoSleeps = SleepWakeReadback.parse("""
        Repeating power events:
          sleep at 11:30PM weekdays only
          sleep at 11:30PM weekdays only
        """)
        XCTAssertEqual(twoSleeps.events.count, 2, "two sleep lines parse to two events")
        XCTAssertFalse(SleepWakeReadback.isAuthored(by: both, matching: twoSleeps),
                       "a two-sleep system is NOT our sleep+wake schedule (must confirm before clobber)")
    }

    // MARK: - SleepWakeScheduleConfig.isValid

    func testConfigIsValid() {
        var c = SleepWakeScheduleConfig.empty
        c.sleepEnabled = true; c.sleepHour = 23; c.sleepMinute = 0
        c.wakeEnabled = true;  c.wakeHour = 7;   c.wakeMinute = 0; c.weekdayMask = 31
        XCTAssertTrue(c.isValid)

        var badHour = c; badHour.sleepHour = 24
        XCTAssertFalse(badHour.isValid, "hour 24 is out of [0,23]")
        var badMask = c; badMask.weekdayMask = 0
        XCTAssertFalse(badMask.isValid, "mask 0 (no day) is out of [1,127]")
        var sameTime = c
        sameTime.sleepHour = 7; sameTime.sleepMinute = 0; sameTime.wakeHour = 7; sameTime.wakeMinute = 0
        XCTAssertFalse(sameTime.isValid, "both enabled at the identical time")
        XCTAssertTrue(SleepWakeScheduleConfig.empty.isValid, "cancel (neither enabled) is valid")
    }
}
