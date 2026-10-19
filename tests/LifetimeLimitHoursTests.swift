import XCTest

/// The Now tab's "N h at a limit since …" and the Health tab's "At limit N h" are the SAME lifetime
/// figure (§5 "At limit (awake hours)"), so on one store they must agree, and each stored hour must
/// count exactly once: aggregates for the hours maintenance has rolled up, raw rows for the rest.
///
/// The defect this pins: Now read raw rows only from the start of yesterday. Raw days 2–7 are not
/// aggregated until they are older than 7 days (`HistoryStore.runMaintenance`), so they sat in neither
/// source Now read, and a render showed "133 h at a limit" beside Health's "At limit 151 h".
///
/// Each test writes real store files (raw `charge-<day>.jsonl`, `agg-<month>.json`) and runs each
/// tab's own read: `NowHistoryFigures.compute` (Now) and `lifetimeRows` → `limitHoldHours` (Health,
/// exactly as `HealthPage.loadFigures` does).
@MainActor
final class LifetimeLimitHoursTests: XCTestCase {

    private var dir: URL!
    private let day0 = 1_749_600_000                  // a UTC midnight (2025-06-11)
    private var now: Int { day0 + 12 * 3600 }          // 12:00 UTC
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lifetime-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    // MARK: - fixture helpers

    /// UTC midnight `age` days before `day0`.
    private func day(_ age: Int) -> Int { day0 - age * 86_400 }

    /// limitHold rows every 60 s over [from, to).
    private func hold(_ from: Int, _ to: Int) -> [ChargePoint] {
        stride(from: from, to: to, by: 60).map {
            ChargePoint(ts: $0, soc: 80, watts: 0.3, onAC: true, state: "limitHold", limit: 80)
        }
    }

    private var raw: [String: [ChargePoint]] = [:]
    private var agg: [String: [String: HourlyAggregate]] = [:]

    /// A raw day file's rows (grouped by UTC day like the store).
    private func addRaw(_ rows: [ChargePoint]) {
        for r in rows { raw[HistoryFormat.dayKey(r.ts), default: []].append(r) }
    }
    /// Aggregate hours built from `rows` with the store's own formula, as maintenance would.
    private func addAgg(from rows: [ChargePoint]) {
        for (hour, hr) in Dictionary(grouping: rows, by: { HistoryFormat.utcHourStart($0.ts) }) {
            agg[HistoryFormat.monthKey(hour), default: [:]][String(hour)] = HistoryStore.hourly(hr)
        }
    }

    private func makeStore(recordingSince: Int? = nil) throws -> HistoryStore {
        let enc = JSONEncoder()
        for (dayKey, rows) in raw {
            let text = try rows.sorted { $0.ts < $1.ts }
                .map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try text.write(to: dir.appendingPathComponent("charge-\(dayKey).jsonl"), atomically: true, encoding: .utf8)
        }
        for (month, hours) in agg {
            try enc.encode(hours).write(to: dir.appendingPathComponent("agg-\(month).json"), options: .atomic)
        }
        if let since = recordingSince {
            try String(since).write(to: dir.appendingPathComponent(".started"), atomically: true, encoding: .utf8)
        }
        let t = now
        return HistoryStore(root: dir, now: { t })
    }

    private func nowTabHours(_ s: HistoryStore) -> Int {
        NowHistoryFigures.compute(history: s, clock: Date(timeIntervalSince1970: TimeInterval(now)), calendar: utc)
            .limitHoldHours
    }
    private func healthTabHours(_ s: HistoryStore) -> Int {
        let rows = s.lifetimeRows(now: now)
        return HistoryMetrics.limitHoldHours(agg: rows.agg, raw: rows.raw)
    }

    // MARK: - the reported defect

    /// Aggregated days (ages 9–12) + raw-only days in the 2–7-day range + today: Now must count the raw
    /// days it used to skip, and agree with Health.
    func testNowAndHealthAgreeWithRawOnlyDaysInTheTwoToSevenDayRange() throws {
        for age in 9...12 { addAgg(from: hold(day(age) + 10 * 3600, day(age) + 15 * 3600)) }   // 4 × 5 h = 20
        for age in 1...6 { addRaw(hold(day(age) + 10 * 3600, day(age) + 13 * 3600)) }        // 6 × 3 h = 18
        addRaw(hold(day0 + 8 * 3600, day0 + 11 * 3600))                                         // today 3 h
        let s = try makeStore()
        XCTAssertEqual(healthTabHours(s), 41)
        XCTAssertEqual(nowTabHours(s), 41, "Now counts the raw-only days 2–7 too")
        XCTAssertEqual(nowTabHours(s), healthTabHours(s), "a lifetime total is one figure on both tabs")
    }

    // MARK: - the boundary

    /// A day whose raw file is still on disk AND whose hours are aggregated (maintenance rolled it up
    /// but the raw delete has not happened, or the raw window reaches it): its hours count ONCE.
    func testBoundaryDayWithRawAndAggregateIsNotDoubleCounted() throws {
        for age in [3, 8] {
            let rows = hold(day(age) + 10 * 3600, day(age) + 13 * 3600)                         // 3 h each
            addRaw(rows)
            addAgg(from: rows)
        }
        addAgg(from: hold(day(9) + 10 * 3600, day(9) + 12 * 3600))                              // 2 h
        let s = try makeStore()
        XCTAssertEqual(healthTabHours(s), 8, "3 + 3 + 2 — the raw+aggregated days are not counted twice")
        XCTAssertEqual(nowTabHours(s), 8)
    }

    /// Raw days at the retention edge that maintenance has not rolled up yet: the age-7 day's hours
    /// from before `now − 7 d`, and an age-8 day (maintenance runs at launch and then every 24 h of
    /// uptime, so a day can sit past 7 days, un-aggregated, until the next run). Neither is in any
    /// aggregate, so the raw rows are the only record of them; a fixed 7 × 24 h window dropped them.
    func testUnaggregatedRawAtTheRetentionEdgeIsCounted() throws {
        addRaw(hold(day(7) + 2 * 3600, day(7) + 5 * 3600))      // 3 h, all before now − 7 d (day(7) + 12 h)
        addRaw(hold(day(8) + 10 * 3600, day(8) + 12 * 3600))    // 2 h, maintenance pending
        addAgg(from: hold(day(10) + 10 * 3600, day(10) + 14 * 3600))   // 4 h
        let s = try makeStore()
        XCTAssertEqual(healthTabHours(s), 9)
        XCTAssertEqual(nowTabHours(s), 9)
    }

    /// A raw day OLDER than the newest aggregate, with no aggregate of its own — what an unreadable month
    /// leaves on disk while a newer month folds (the data-loss guard keeps that raw for up to 12 months).
    /// It is the only record of those hours, so both tabs count it; inferring the floor from the newest
    /// aggregate dropped it the night the newer month folded.
    func testRawDayOlderThanTheNewestAggregateIsCountedOnBothTabs() throws {
        addRaw(hold(day(40) + 10 * 3600, day(40) + 13 * 3600))   // 3 h, raw only, no aggregate of its own
        addAgg(from: hold(day(10) + 10 * 3600, day(10) + 12 * 3600))   // 2 h, a NEWER aggregated day
        addRaw(hold(day(1) + 10 * 3600, day(1) + 11 * 3600))     // 1 h
        let s = try makeStore()
        XCTAssertEqual(healthTabHours(s), 6)
        XCTAssertEqual(nowTabHours(s), 6)
    }

    func testOldestRawDayStartReadsTheFilesAndSkipsMalformedNames() throws {
        let empty = try makeStore()
        XCTAssertNil(empty.oldestRawDayStart(), "no raw file → nil")
        addRaw(hold(day(12) + 3600, day(12) + 7200))
        addRaw(hold(day(2) + 3600, day(2) + 7200))
        try "x\n".write(to: dir.appendingPathComponent("charge-garbage.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try makeStore().oldestRawDayStart(), day(12))
    }

    /// No aggregates and the recording-start marker unreadable (no `.started`): the raw files on disk are
    /// still the record — an unread marker must not become a 7-day floor.
    func testNoAggregatesAndRecordingStartUnreadStillCountsEveryRawDay() throws {
        addRaw(hold(day(9) + 10 * 3600, day(9) + 12 * 3600))    // 2 h
        addRaw(hold(day(2) + 10 * 3600, day(2) + 11 * 3600))    // 1 h
        let s = try makeStore(recordingSince: nil)
        XCTAssertNil(s.recordingSince, "fixture: the marker is unread")
        XCTAssertEqual(healthTabHours(s), 3)
        XCTAssertEqual(nowTabHours(s), 3)
    }

    // MARK: - the walk's horizon: as old as a KEPT raw day can be

    /// The horizon the lifetime read walks back to is one named bound, derived from the two retention
    /// rules it must cover: a raw day kept for bytes it could not fold is released past
    /// `keptRawHorizonDays`, but a raw day kept because its MONTH is unreadable is held while that month's
    /// file exists — and a month is pruned only once its LAST day is older than `aggRetentionMonths × 31`
    /// days, so its first day can be up to a further 31 days older.
    func testMaxRawAgeDaysIsTheKeptHorizonPlusOneMonth() {
        XCTAssertEqual(HistoryStore.maxRawAgeDays, HistoryStore.keptRawHorizonDays + 31)
        XCTAssertGreaterThanOrEqual(HistoryStore.maxRawAgeDays, HistoryStore.keptRawHorizonDays)
        // The derivation, checked against the calendar: for every "today" across two years, the oldest
        // first-of-month whose month is still inside the aggregate horizon is within the bound.
        for back in 0..<730 {
            let today = day0 - back * 86_400
            let cutoff = today - HistoryStore.aggRetentionMonths * 31 * 86_400   // `pruneAggregates`
            var c = DateComponents()
            let comps = utc.dateComponents([.year, .month], from: Date(timeIntervalSince1970: TimeInterval(cutoff)))
            c.year = comps.year; c.month = comps.month; c.day = 1
            // The month holding the cutoff day is the oldest one not yet pruned (its last day ≥ cutoff).
            let firstDay = Int(utc.date(from: c)!.timeIntervalSince1970)
            XCTAssertLessThanOrEqual((today - firstDay) / 86_400, HistoryStore.maxRawAgeDays,
                                     "today − \(back) d: a kept day of the oldest unpruned month is past the bound")
        }
    }

    /// A raw day ~390 days old — past `keptRawHorizonDays` (372) — kept because its month will not read,
    /// and that month is not yet pruned (its last day is inside the horizon). It is the only record of
    /// those hours, so the lifetime figure counts it on both tabs.
    func testAKeptRawDayAbout390DaysOldWhoseMonthIsUnreadableIsCounted() throws {
        let today = day0 + 45 * 86_400                   // 2025-07-26 00:00 UTC
        let t = today + 12 * 3600
        let kept = today - 390 * 86_400                  // 2024-07-01: month 2024-07 ends inside the horizon
        XCTAssertEqual(HistoryFormat.dayKey(kept), "2024-07-01")
        addRaw(hold(kept + 10 * 3600, kept + 13 * 3600))                       // 3 h, raw only
        addAgg(from: hold(today - 20 * 86_400 + 10 * 3600, today - 20 * 86_400 + 12 * 3600))   // 2 h, aggregated
        let enc = JSONEncoder()
        for (dayKey, rows) in raw {
            let text = try rows.map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try text.write(to: dir.appendingPathComponent("charge-\(dayKey).jsonl"), atomically: true, encoding: .utf8)
        }
        for (month, hours) in agg {
            try enc.encode(hours).write(to: dir.appendingPathComponent("agg-\(month).json"), options: .atomic)
        }
        try Data("{".utf8).write(to: dir.appendingPathComponent("agg-2024-07.json"))   // the unreadable month
        let s = HistoryStore(root: dir, now: { t })
        s.runMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("charge-2024-07-01.jsonl").path),
                      "fixture: the day is kept — its month will not read")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agg-2024-07.json").path),
                      "fixture: the month is not yet pruned")
        let rows = s.lifetimeRows(now: t)
        XCTAssertEqual(HistoryMetrics.limitHoldHours(agg: rows.agg, raw: rows.raw), 5, "Health counts the kept day")
        let nowTab = NowHistoryFigures.compute(history: s, clock: Date(timeIntervalSince1970: TimeInterval(t)), calendar: utc)
        XCTAssertEqual(nowTab.limitHoldHours, 5, "Now counts it too")
    }

    // MARK: - the memo holds a kept month's worth of raw days

    /// ~40 raw day files on disk (a month kept for an unreadable aggregate + the recent days): the
    /// lifetime read is re-run on every Now/Health recompute, so the memo must hold them all — each file
    /// is decoded once, and a second read decodes nothing. A 16-entry memo cleared itself mid-walk and
    /// re-decoded every file on every call (reported ~340 ms per recompute).
    func testFortyKeptRawDaysAreEachDecodedOnceAcrossTwoLifetimeReads() throws {
        for age in 0..<40 { addRaw(hold(day(age) + 2 * 3600, day(age) + 2 * 3600 + 120)) }
        let s = try makeStore()
        XCTAssertGreaterThanOrEqual(HistoryStore.memoCap, 31 + 9, "a kept month (31 days) + the recent days")
        let before = s.fileDecodes
        _ = s.lifetimeRows(now: now)
        XCTAssertEqual(s.fileDecodes - before, 40, "the first read decodes each raw file once")
        _ = s.lifetimeRows(now: now)
        XCTAssertEqual(s.fileDecodes - before, 40, "the second read decodes nothing — every file is memoised")
    }

    /// No aggregate yet at all (a young store, or maintenance has never landed one): every raw day since
    /// recording began is unaggregated and counts.
    func testWithNoAggregatesEveryRawDaySinceRecordingCounts() throws {
        addRaw(hold(day(9) + 10 * 3600, day(9) + 12 * 3600))    // 2 h
        addRaw(hold(day(2) + 10 * 3600, day(2) + 11 * 3600))    // 1 h
        let s = try makeStore(recordingSince: day(9) + 10 * 3600)
        XCTAssertEqual(healthTabHours(s), 3)
        XCTAssertEqual(nowTabHours(s), 3)
    }
}
