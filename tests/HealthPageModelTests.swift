import XCTest

/// #30 §4.5: the Health page's pure strings, pinned to the mockup's wording (§14-D16 pack values).
final class HealthPageModelTests: XCTestCase {

    private let la: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        la.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testCapacityAndFraction() {
        XCTAssertEqual(HealthPageModel.capacityText(raw_mAh: 5435, design_mAh: 6249), "5,435 / 6,249 mAh")
        XCTAssertNil(HealthPageModel.capacityText(raw_mAh: nil, design_mAh: 6249))
        XCTAssertNil(HealthPageModel.capacityText(raw_mAh: 5435, design_mAh: 0))
        XCTAssertEqual(HealthPageModel.healthFraction(raw_mAh: 5435, design_mAh: 6249)!, 0.8697, accuracy: 0.001)
        XCTAssertNil(HealthPageModel.healthFraction(raw_mAh: nil, design_mAh: nil))   // never a 0 dial
        XCTAssertEqual(HealthPageModel.healthFraction(raw_mAh: 7000, design_mAh: 6249), 1)
    }

    func testCyclesPerWeekAndProjection() {
        XCTAssertEqual(HealthPageModel.perWeekText(8.64), "8.6")
        XCTAssertNil(HealthPageModel.perWeekText(nil))
        XCTAssertEqual(HealthPageModel.projectedText(8.65), "≈ 450 cycles")
        XCTAssertEqual(HealthPageModel.projectedText(25), "≈ 1,300 cycles")
        XCTAssertNil(HealthPageModel.projectedText(nil))
    }

    func testUseFigures() {
        XCTAssertEqual(HealthPageModel.hoursText(151), "151 h")
        let twelve = HistoryMetrics.LowDays(count: 12, deepest: 1, deepestDate: nil, daysWithReadings: 14)
        XCTAssertEqual(HealthPageModel.lowDaysText(twelve), "12/14", "spec 30 §16 row 32 · Low days: N/M")
        XCTAssertEqual(HealthPageModel.lowDaysSpoken(twelve), "12 of 14", "VoiceOver reads words, not a slash")
        XCTAssertEqual(HealthPageModel.deepestText(twelve), "1%")
    }

    /// No day dipped to 20 % although the fortnight HAS readings: the count is a real 0 and "Deepest"
    /// is a real "none" — not the page's "—", which means "not read" everywhere else on it.
    func testZeroLowDaysWithReadingsIsZeroAndNone() {
        let zero = HistoryMetrics.LowDays(count: 0, deepest: nil, deepestDate: nil, daysWithReadings: 14)
        XCTAssertEqual(HealthPageModel.lowDaysText(zero), "0/14")
        XCTAssertEqual(HealthPageModel.deepestText(zero), "none")
    }

    /// Absence is not a fact (owner-decided): the denominator is the days that HAVE readings, so an
    /// unread day is never silently counted as "not low". One day read → "/1".
    func testLowDaysDenominatorIsTheDaysWithReadings() {
        let oneDay = HistoryMetrics.LowDays(count: 0, deepest: nil, deepestDate: nil, daysWithReadings: 1)
        XCTAssertEqual(HealthPageModel.lowDaysText(oneDay), "0/1")
        let oneLow = HistoryMetrics.LowDays(count: 1, deepest: 9, deepestDate: nil, daysWithReadings: 1)
        XCTAssertEqual(HealthPageModel.lowDaysText(oneLow), "1/1")
        let nine = HistoryMetrics.LowDays(count: 3, deepest: 9, deepestDate: nil, daysWithReadings: 9)
        XCTAssertEqual(HealthPageModel.lowDaysText(nine), "3/9")
    }

    /// Absence is not a fact: a fortnight with no charge readings at all knows nothing about low days,
    /// so both cells are nil (the view's "—"), never "0/14" / "none".
    func testLowDaysWithoutReadingsAreUnknown() {
        let unread = HistoryMetrics.LowDays(count: 0, deepest: nil, deepestDate: nil, daysWithReadings: 0)
        XCTAssertNil(HealthPageModel.lowDaysText(unread))
        XCTAssertNil(HealthPageModel.lowDaysSpoken(unread))
        XCTAssertNil(HealthPageModel.deepestText(unread))
    }

    // MARK: - the history note (spec 30 §16 "32 · Health · history note")

    /// The render fixture's clock: 2026-09-09 13:21 local.
    private var fixtureClock: Date { at(2026, 9, 9, 13, 21) }
    private func note(months: Set<String> = [], rawDays: Set<String> = [], writeFailed: Bool = false,
                      folderUnreadable: Bool = false, now: Date? = nil) -> String? {
        HealthPageModel.historyNoteText(unreadableMonths: months, unreadableRawDays: rawDays, writeFailed: writeFailed,
                                        folderUnreadable: folderUnreadable, now: now ?? fixtureClock, calendar: la)
    }
    /// Owner decision (review of 7c286c2): "readings are kept" was false on a full disk — unsaved raw rows
    /// live only in RAM (capped at 10,000, lost on quit).
    private let saved = "History couldn\u{2019}t be saved \u{2014} new readings may be lost until it can."

    func testNoHistoryNoteWhileNothingNeedsAttention() {
        XCTAssertNil(note())
    }

    func testAnUnreadableMonthIsNamedByItsFullMonthName() {
        XCTAssertEqual(note(months: ["2026-09"]),
                       "History for September couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
    }

    /// Two months: both named, oldest first, whatever order the set gives.
    func testTwoUnreadableMonthsAreBothNamedOldestFirst() {
        XCTAssertEqual(note(months: ["2026-10", "2026-09"]),
                       "History for September and October couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
    }

    /// Owner decision (review of 7c286c2): a month outside the current year carries its year; a
    /// current-year month stays bare. The render fixture's case: clock 2026-09-09, file 2025-09.
    func testAMonthOutsideTheCurrentYearCarriesItsYear() {
        XCTAssertEqual(note(months: ["2025-09"]),
                       "History for September 2025 couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
        XCTAssertEqual(note(months: ["2025-09", "2025-12"]),
                       "History for September 2025 and December 2025 couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
        XCTAssertEqual(note(rawDays: ["2025-11-30"]),
                       "History for November 2025 couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
    }

    /// A pair across the year boundary: each month as it needs.
    func testAYearBoundaryPairNamesEachMonthAsItNeeds() {
        XCTAssertEqual(note(months: ["2026-01", "2025-12"]),
                       "History for December 2025 and January couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
    }

    /// "Current year" is the LOCAL calendar year of `now`: at 20:00 on Dec 31 in Los Angeles it is
    /// already Jan 1 in UTC, but the year is still 2025 here.
    func testTheCurrentYearIsTheLocalCalendarYear() {
        XCTAssertEqual(note(months: ["2025-12", "2026-01"], now: at(2025, 12, 31, 20, 0)),
                       "History for December and January 2026 couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
    }

    func testThreeOrMoreUnreadableMonthsAreCounted() {
        XCTAssertEqual(note(months: ["2026-07", "2026-08", "2026-09"]),
                       "History for 3 months couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
    }

    /// The same month name in two years is told apart by the year, so both are named.
    func testTwoMonthsWithTheSameNameAreToldApartByTheYear() {
        XCTAssertEqual(note(months: ["2025-09", "2026-09"]),
                       "History for September 2025 and September couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
    }

    /// An unreadable RAW day is a read problem too: "couldn't be read", named by the day's month — never
    /// "couldn't be saved" (nothing failed to write). A raw day and an aggregate of the same month are
    /// one month.
    func testAnUnreadableRawDayReadsAsItsMonthCouldNotBeRead() {
        XCTAssertEqual(note(rawDays: ["2026-09-03"]),
                       "History for September couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
        XCTAssertEqual(note(months: ["2026-09"], rawDays: ["2026-09-03", "2026-09-04"]),
                       "History for September couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
        XCTAssertEqual(note(months: ["2026-08"], rawDays: ["2026-09-03"]),
                       "History for August and September couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is.")
    }

    /// Review fix 6: a folder that cannot be listed — no month is known, so none is named.
    func testAnUnlistableFolderSaysHistoryCouldNotBeRead() {
        let folder = "History couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is."
        XCTAssertEqual(note(folderUnreadable: true), folder)
        XCTAssertEqual(note(months: ["2026-09"], folderUnreadable: true), folder, "it outranks a named month")
        XCTAssertEqual(note(writeFailed: true, folderUnreadable: true), saved, "a failed write outranks it")
    }

    func testAFailedWriteSaysCouldNotBeSaved() {
        XCTAssertEqual(note(writeFailed: true), saved)
    }

    /// Precedence: a failed write outranks an unreadable file — it is the problem still growing (each day
    /// it lasts, another raw day is kept uncompacted), while an unreadable file is a fixed condition.
    func testAFailedWriteTakesPrecedenceOverAnUnreadableFile() {
        XCTAssertEqual(note(months: ["2026-09"], rawDays: ["2026-08-30"], writeFailed: true), saved)
    }

    func testLastFullCharge() {
        let now = at(2026, 9, 9, 10, 0)
        XCTAssertEqual(HealthPageModel.lastFullChargeText(at(2026, 9, 9, 7, 5), now: now, calendar: la), "today 07:05")
        XCTAssertEqual(HealthPageModel.lastFullChargeText(at(2026, 9, 8, 23, 10), now: now, calendar: la), "yesterday 23:10")
        XCTAssertEqual(HealthPageModel.lastFullChargeText(at(2026, 9, 3, 12, 0), now: now, calendar: la), "Sep 3")
        XCTAssertNil(HealthPageModel.lastFullChargeText(nil, now: now, calendar: la))
    }

    func testLifetimeRows() {
        XCTAssertEqual(HealthPageModel.temperatureText(minC: 9, maxC: 46, avgDeciC: 257), "9 → 46 °C · avg 26")
        XCTAssertEqual(HealthPageModel.temperatureText(minC: 9, maxC: 46, avgDeciC: 244), "9 → 46 °C · avg 24")
        XCTAssertEqual(HealthPageModel.temperatureText(minC: 9, maxC: 46, avgDeciC: nil), "9 → 46 °C")   // R15: avg optional
        XCTAssertNil(HealthPageModel.temperatureText(minC: nil, maxC: 46, avgDeciC: 257))                  // never a one-sided range
        XCTAssertNil(HealthPageModel.temperatureText(minC: 9, maxC: nil, avgDeciC: 257))
        XCTAssertEqual(HealthPageModel.peakCurrentText(charge_mA: 6800, discharge_mA: -9000), "6.8 A in · 9.0 A out")
        XCTAssertEqual(HealthPageModel.peakCurrentText(charge_mA: 6800, discharge_mA: 9000), "6.8 A in · 9.0 A out")
        XCTAssertNil(HealthPageModel.peakCurrentText(charge_mA: 6800, discharge_mA: nil))
        XCTAssertEqual(HealthPageModel.packVoltageText(min_mV: 9000, max_mV: 13200), "9.0 → 13.2 V")
        XCTAssertNil(HealthPageModel.packVoltageText(min_mV: nil, max_mV: 13200))
    }

    func testChartCaptionAndSummary() {
        let jun = HistoryMetrics.WeeklyCapacity(weekStart: at(2026, 6, 1), pct: 87.2)
        let sep = HistoryMetrics.WeeklyCapacity(weekStart: at(2026, 9, 7), pct: 86.9)
        XCTAssertEqual(HealthPageModel.chartCaption(weeks: [jun, sep], calendar: la), "capacity % · weekly median · Jun → Sep")
        XCTAssertEqual(HealthPageModel.chartCaption(weeks: [sep], calendar: la), "capacity % · weekly median · Sep")
        XCTAssertEqual(HealthPageModel.chartCaption(weeks: [], calendar: la), "capacity % · weekly median · —")
        XCTAssertEqual(HealthPageModel.chartSummary(weeks: [jun, sep]), "Capacity chart: 2 weeks, 87 percent")
        XCTAssertEqual(HealthPageModel.chartSummary(weeks: [jun, HistoryMetrics.WeeklyCapacity(weekStart: at(2026, 7, 6), pct: 90)]),
                       "Capacity chart: 2 weeks, 87 to 90 percent")
        XCTAssertEqual(HealthPageModel.chartSummary(weeks: []), "Capacity chart: no capacity history")
    }
}
