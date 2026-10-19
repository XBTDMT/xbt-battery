import XCTest
import Shared

/// Sprint 3.7 (sleep/wake) — the THIRD privileged op's command core. Security-critical: validate
/// rejects out-of-range BEFORE construction, and `pmsetArguments` accepts ONLY a `validate`-minted
/// request, so an out-of-range value is structurally unable to reach the argv. Same validate-before-
/// construct pattern as setEnergyMode / collectTaskEnergy. Host-app-free (the pure core, no spawn).
final class SleepWakeCommandTests: XCTestCase {

    // MARK: validate — accept / cancel / reject

    func testValidate_acceptsBothEnabledDifferentTimes() throws {
        let r = try XCTUnwrap(SleepWakeCommand.validate(
            sleepEnabled: true, sleepHour: 23, sleepMinute: 30,
            wakeEnabled: true, wakeHour: 7, wakeMinute: 0, weekdayMask: 31))
        XCTAssertEqual(r.kind, .schedule)
        XCTAssertEqual(r.sleepEnabled, true);  XCTAssertEqual(r.sleepHour, 23); XCTAssertEqual(r.sleepMinute, 30)
        XCTAssertEqual(r.wakeEnabled, true);   XCTAssertEqual(r.wakeHour, 7);   XCTAssertEqual(r.wakeMinute, 0)
        XCTAssertEqual(r.weekdayMask, 31)
    }

    func testValidate_neitherEnabledIsCancel() throws {
        let r = try XCTUnwrap(SleepWakeCommand.validate(
            sleepEnabled: false, sleepHour: 0, sleepMinute: 0,
            wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 0))
        XCTAssertEqual(r.kind, .cancel, "neither enabled → CANCEL (times/mask ignored)")
    }

    func testValidate_rejectsOutOfRange() {
        // bad sleep hour
        XCTAssertNil(SleepWakeCommand.validate(sleepEnabled: true, sleepHour: 24, sleepMinute: 0,
                     wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 31))
        // bad sleep minute
        XCTAssertNil(SleepWakeCommand.validate(sleepEnabled: true, sleepHour: 1, sleepMinute: 60,
                     wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 31))
        // bad wake hour (negative)
        XCTAssertNil(SleepWakeCommand.validate(sleepEnabled: false, sleepHour: 0, sleepMinute: 0,
                     wakeEnabled: true, wakeHour: -1, wakeMinute: 0, weekdayMask: 31))
        // mask 0 (no day) while enabled
        XCTAssertNil(SleepWakeCommand.validate(sleepEnabled: true, sleepHour: 1, sleepMinute: 0,
                     wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 0))
        // mask 128 (bit 7 set) while enabled
        XCTAssertNil(SleepWakeCommand.validate(sleepEnabled: true, sleepHour: 1, sleepMinute: 0,
                     wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 128))
    }

    func testValidate_rejectsSleepEqualsWake() {
        XCTAssertNil(SleepWakeCommand.validate(sleepEnabled: true, sleepHour: 7, sleepMinute: 0,
                     wakeEnabled: true, wakeHour: 7, wakeMinute: 0, weekdayMask: 31),
                     "both enabled at the identical time is a self-contradictory schedule → reject")
    }

    // MARK: rejectionToken — which bound a raw set violates

    func testRejectionToken_mapsEachFailure() {
        XCTAssertEqual(SleepWakeCommand.rejectionToken(sleepEnabled: true, sleepHour: 99, sleepMinute: 0,
                       wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 31),
                       SleepWakeCommand.errInvalidTime, "bad hour → invalid-time")
        XCTAssertEqual(SleepWakeCommand.rejectionToken(sleepEnabled: true, sleepHour: 1, sleepMinute: 0,
                       wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 0),
                       SleepWakeCommand.errInvalidDays, "mask 0 → invalid-days")
        XCTAssertEqual(SleepWakeCommand.rejectionToken(sleepEnabled: true, sleepHour: 7, sleepMinute: 0,
                       wakeEnabled: true, wakeHour: 7, wakeMinute: 0, weekdayMask: 31),
                       SleepWakeCommand.errSleepEqualsWake, "identical times → sleep-equals-wake")
    }

    // MARK: weekdayLetters — bit0=Mon..bit6=Sun → MTWRFSU

    func testWeekdayLetters_mapsBitsToLetters() {
        XCTAssertEqual(SleepWakeCommand.weekdayLetters(31), "MTWRF", "bits 0-4 → Mon-Fri")
        XCTAssertEqual(SleepWakeCommand.weekdayLetters(127), "MTWRFSU", "all 7 days")
        XCTAssertEqual(SleepWakeCommand.weekdayLetters(64), "U", "bit 6 → Sunday")
        XCTAssertEqual(SleepWakeCommand.weekdayLetters(65), "MU", "bit 0 + bit 6 → Mon + Sun")
        XCTAssertEqual(SleepWakeCommand.weekdayLetters(1), "M", "bit 0 → Monday")
    }

    // MARK: pmsetArguments — the FIXED argv, built ONLY from a validate()-minted request

    /// Headline structural guarantee: `pmsetArguments` is reachable ONLY through a `validate()`-minted
    /// `ValidatedSleepWakeRequest`. The `fileprivate` init makes an out-of-range request UNCONSTRUCTABLE
    /// at compile time (no test can hand `pmsetArguments` an unchecked value), so injection/abuse is
    /// structurally closed — this asserts the four argv forms over validated requests only.
    func testPmsetArguments_fourFixedFormsFromValidatedRequestsOnly() throws {
        let pmset = EnergyModeCommand.pmsetPath

        // cancel (neither enabled)
        let cancel = try XCTUnwrap(SleepWakeCommand.validate(sleepEnabled: false, sleepHour: 0, sleepMinute: 0,
                                   wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 0))
        XCTAssertEqual(SleepWakeCommand.pmsetArguments(cancel), [pmset, "repeat", "cancel"])

        // sleep only (mask 31 → MTWRF, 23:30)
        let sleepOnly = try XCTUnwrap(SleepWakeCommand.validate(sleepEnabled: true, sleepHour: 23, sleepMinute: 30,
                                      wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 31))
        XCTAssertEqual(SleepWakeCommand.pmsetArguments(sleepOnly),
                       [pmset, "repeat", "sleep", "MTWRF", "23:30:00"])

        // wake only (mask 127 → MTWRFSU, 07:00)
        let wakeOnly = try XCTUnwrap(SleepWakeCommand.validate(sleepEnabled: false, sleepHour: 0, sleepMinute: 0,
                                     wakeEnabled: true, wakeHour: 7, wakeMinute: 0, weekdayMask: 127))
        XCTAssertEqual(SleepWakeCommand.pmsetArguments(wakeOnly),
                       [pmset, "repeat", "wakeorpoweron", "MTWRFSU", "07:00:00"])

        // both (sleep then wake, same days)
        let both = try XCTUnwrap(SleepWakeCommand.validate(sleepEnabled: true, sleepHour: 23, sleepMinute: 30,
                                 wakeEnabled: true, wakeHour: 7, wakeMinute: 0, weekdayMask: 31))
        XCTAssertEqual(SleepWakeCommand.pmsetArguments(both),
                       [pmset, "repeat", "sleep", "MTWRF", "23:30:00", "wakeorpoweron", "MTWRF", "07:00:00"])
    }

    func testPmsetArguments_absolutePathFirst_noShell() throws {
        let both = try XCTUnwrap(SleepWakeCommand.validate(sleepEnabled: true, sleepHour: 1, sleepMinute: 5,
                                 wakeEnabled: true, wakeHour: 6, wakeMinute: 15, weekdayMask: 65))
        let argv = SleepWakeCommand.pmsetArguments(both)
        XCTAssertEqual(argv.first, EnergyModeCommand.pmsetPath, "argv[0] is the absolute pmset path")
        XCTAssertFalse(argv.contains("/bin/sh"))
        XCTAssertTrue(argv.contains("sleep") && argv.contains("wakeorpoweron"),
                      "only the hard-coded event types — never shutdown/restart/poweron")
        // 01:05 and 06:15 are zero-padded fixed-width; mask 65 → MU
        XCTAssertTrue(argv.contains("01:05:00") && argv.contains("06:15:00") && argv.contains("MU"))
    }
}
