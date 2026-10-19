import XCTest

/// #30 stage 2: the pure `HistoryMetrics` layer (spec §5 XS rows, §14 red-team rulings). Fixtures are
/// built in code in America/Los_Angeles around the 2026-11-01 fall-back day (25 local hours); no files.
final class HistoryMetricsTests: XCTestCase {

    private let la: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// Local midnight of a date (epoch seconds).
    private func midnight(_ y: Int, _ m: Int, _ d: Int) -> Int {
        Int(la.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970)
    }
    private func cp(_ ts: Int, soc: Int? = 50, w: Double? = -10, ac: Bool = false, state: String = "discharging") -> ChargePoint {
        ChargePoint(ts: ts, soc: soc, watts: w, onAC: ac, state: state, limit: 80)
    }
    private func agg(socMin: Int? = 50, socMax: Int? = 60, socAvg: Double? = 55, w: Double? = -10,
                     ac: Double = 0, state: String = "discharging", count: Int = 60) -> HourlyAggregate {
        HourlyAggregate(socMin: socMin, socMax: socMax, socAvg: socAvg, wattsAvg: w, acFraction: ac,
                        dominantState: state, count: count)
    }
    /// Rows every `step` s over [from, to), constant fields.
    private func run(_ from: Int, _ to: Int, step: Int = 60, soc: Int? = 50, w: Double? = -10, ac: Bool = false,
                     state: String = "discharging") -> [ChargePoint] {
        stride(from: from, to: to, by: step).map { cp($0, soc: soc, w: w, ac: ac, state: state) }
    }

    // The fixture week: 2026-10-26 (Mon) … 2026-11-01 (Sun, DST fall-back). `now` = Nov 1 15:00 PST.
    private var nov1: Int { midnight(2026, 11, 1) }
    private var now: Int { nov1 + 16 * 3600 }   // 25-hour day: 16 h after midnight is 15:00 PST

    // MARK: - integrateWh (§5, §14-D1/D4)

    func testIntegrateSplitsBySignAndDoesNotNet() {
        // 30 min at -20 W then 30 min at +20 W: out 10 Wh, in 10 Wh — NOT net 0.
        let a = run(0, 1800, w: -20) + run(1800, 3600, w: 20) + [cp(3600, w: 20)]
        let wh = HistoryMetrics.integrateWh(raw: a)
        XCTAssertEqual(wh.out, 10, accuracy: 1e-9)
        XCTAssertEqual(wh.in, 10, accuracy: 1e-9)
    }

    func testIntegrateCapsGapAt120s() {
        // one row, then a 2728 s gap: held for 120 s only. -30 W × 120 s = 1 Wh.
        let wh = HistoryMetrics.integrateWh(raw: [cp(0, w: -30), cp(2728, w: -30)])
        XCTAssertEqual(wh.out, 1.0, accuracy: 1e-9)
        XCTAssertEqual(wh.in, 0)
    }

    func testIntegrateIgnoresNilWattsAndSingleRow() {
        XCTAssertEqual(HistoryMetrics.integrateWh(raw: [cp(0, w: -30)]).out, 0)
        let wh = HistoryMetrics.integrateWh(raw: [cp(0, w: nil), cp(60, w: -30), cp(120, w: -30)])
        XCTAssertEqual(wh.out, 0.5, accuracy: 1e-9, "only the second row is held for 60 s")
    }

    func testAwakeSecondsTreatSleepAsThirdState() {
        // 10 min on battery, a 3 h gap (asleep), 10 min on power.
        let t0 = nov1
        let rows = run(t0, t0 + 600) + run(t0 + 600 + 3 * 3600, t0 + 600 + 3 * 3600 + 660, ac: true)
        let a = HistoryMetrics.awakeSeconds(raw: rows)
        XCTAssertEqual(a.battery, 540 + 120, "9 held minutes + the 120 s cap of the gap row")
        XCTAssertEqual(a.power, 600, "10 rows, the last one held for nothing")
    }

    // MARK: - stitched (§14-D3)

    func testStitchedAddsRawHoursAndKeepsAggregates() {
        let h0 = HistoryFormat.utcHourStart(nov1)
        let aggs = [String(h0): agg(socMin: 99, count: 5)]
        let rows = run(h0, h0 + 600, soc: 10) + run(h0 + 3600, h0 + 3600 + 600, soc: 20)
        let st = HistoryMetrics.stitched(agg: aggs, raw: rows)
        XCTAssertEqual(st[h0]?.socMin, 99, "aggregate wins for an hour it has")
        XCTAssertEqual(st[h0 + 3600], HistoryMetrics.hourly(Array(rows[10...])), "raw hour added via hourly()")
        XCTAssertEqual(st.count, 2)
    }

    @MainActor
    func testHourlyMirrorsHistoryStoreHourly() {
        // A dominant-state tie is resolved by dictionary order in both; avoid ties in the fixture.
        let h0 = HistoryFormat.utcHourStart(nov1)
        let rows = run(h0, h0 + 1800, soc: 40, w: -12, state: "discharging")
            + run(h0 + 1800, h0 + 2400, soc: 45, w: 30, ac: true, state: "charging")
            + [cp(h0 + 3000, soc: nil, w: nil, ac: true, state: "charging")]
        XCTAssertEqual(HistoryMetrics.hourly(rows), HistoryStore.hourly(rows))
        XCTAssertEqual(HistoryMetrics.hourly([]), HistoryStore.hourly([]))
    }

    // MARK: - hour cells / DST (§14-D14)

    func testHourStartsAre25OnFallBack23OnSpringForward24Otherwise() {
        XCTAssertEqual(HistoryMetrics.hourStarts(ofDay: la.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(nov1))), calendar: la).count, 25)
        let mar8 = la.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        XCTAssertEqual(HistoryMetrics.hourStarts(ofDay: mar8, calendar: la).count, 23)
        let oct30 = la.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        XCTAssertEqual(HistoryMetrics.hourStarts(ofDay: oct30, calendar: la).count, 24)
    }

    // MARK: - dayRows (§4.3, §5)

    func testDayRowsTodayHas25CellsAndIsPartial() {
        let rows = run(nov1 + 9 * 3600, nov1 + 10 * 3600)
        let d = HistoryMetrics.dayRows(raw: rows, agg: [:], now: now, calendar: la)
        XCTAssertEqual(d.count, 1, "only days that exist are rows (§6)")
        XCTAssertEqual(d[0].cells.count, 25)
        XCTAssertTrue(d[0].isPartial)
        XCTAssertEqual(d[0].date.timeIntervalSince1970, TimeInterval(nov1))
    }

    func testDayRowsAsleepNightHasNoRows() {
        // Awake 09:00–11:00 on Oct 30 only; the night cells have no rows = asleep (hatched).
        let oct30 = midnight(2026, 10, 30)
        let rows = run(oct30 + 9 * 3600, oct30 + 11 * 3600, soc: 40)
        let d = HistoryMetrics.dayRows(raw: rows, agg: [:], now: now, calendar: la)
        XCTAssertEqual(d.count, 1)
        let r = d[0]
        XCTAssertFalse(r.isPartial)
        XCTAssertEqual(r.cells.count, 24)
        XCTAssertFalse(r.cells[2].hasRows)
        XCTAssertTrue(r.cells[9].hasRows && r.cells[10].hasRows)
        XCTAssertEqual(r.cells[9].socAvg, 40)
        XCTAssertEqual(r.cells.filter(\.hasRows).count, 2)
    }

    func testDayRowsOneRowHourCountsAsAwakeCellButNoWh() {
        let oct29 = midnight(2026, 10, 29)
        let d = HistoryMetrics.dayRows(raw: [cp(oct29 + 5 * 3600 + 30, soc: 77, w: -50)], agg: [:], now: now, calendar: la)
        XCTAssertEqual(d.count, 1)
        XCTAssertTrue(d[0].cells[5].hasRows)
        XCTAssertEqual(d[0].cells[5].socAvg, 77)
        XCTAssertEqual(d[0].whOut, 0, "a single row is held for nothing")
        XCTAssertNil(d[0].avgW_onBattery)
    }

    func testDayRowsMixedHourDoesNotNetAndAvgWIsWhOverAwakeHours() {
        let oct28 = midnight(2026, 10, 28)
        // 1 h at -20 W on battery, then 1 h at +30 W on AC (charging), then a closing row.
        let rows = run(oct28 + 8 * 3600, oct28 + 9 * 3600, w: -20)
            + run(oct28 + 9 * 3600, oct28 + 10 * 3600, w: 30, ac: true, state: "charging")
            + [cp(oct28 + 10 * 3600, w: 30, ac: true, state: "charging")]
        let r = HistoryMetrics.dayRows(raw: rows, agg: [:], now: now, calendar: la)[0]
        XCTAssertEqual(r.whOut, 20, accuracy: 1e-9)
        XCTAssertEqual(r.whIn, 30, accuracy: 1e-9)
        XCTAssertFalse(r.whIsNet)
        XCTAssertEqual(r.awakeOnBattery_s, 3600)
        XCTAssertEqual(r.avgW_onBattery!, 20, accuracy: 1e-9)
        XCTAssertFalse(r.cells[8].onPower)
        XCTAssertTrue(r.cells[9].onPower)
    }

    func testDayRowsBeyondRawWindowUseAggregatesWeightedAndNet() {
        // A day 20 days back, aggregates only: two hours, 60 rows at -10 W (battery) and 30 rows at +40 W (AC).
        let d0 = midnight(2026, 10, 12)
        let h1 = HistoryFormat.utcHourStart(d0 + 9 * 3600), h2 = h1 + 3600
        let aggs = [String(h1): agg(w: -10, ac: 0, count: 60), String(h2): agg(w: 40, ac: 1, count: 30)]
        let d = HistoryMetrics.dayRows(raw: [], agg: aggs, now: now, calendar: la, days: 30)
        XCTAssertEqual(d.count, 1)
        let r = d[0]
        XCTAssertTrue(r.whIsNet)
        // net = -10·1 + 40·0.5 = +10 → shown as 10 Wh in, 0 out
        XCTAssertEqual(r.whIn, 10, accuracy: 1e-9)
        XCTAssertEqual(r.whOut, 0, accuracy: 1e-9)
        XCTAssertEqual(r.awakeOnBattery_s, 3600, "(1−0)·60/60 h + (1−1)·… = 1 h")
        XCTAssertEqual(r.cells.count, 24)
        XCTAssertTrue(r.cells[9].hasRows)
    }

    func testDayRowsOrderOldestFirstAndWeekWhSums() {
        let a = run(midnight(2026, 10, 27) + 3600, midnight(2026, 10, 27) + 2 * 3600, w: -36)   // 36 Wh out (59 min held)
        let b = run(midnight(2026, 10, 30) + 3600, midnight(2026, 10, 30) + 2 * 3600, w: 36, ac: true)
        let d = HistoryMetrics.dayRows(raw: a + b, agg: [:], now: now, calendar: la)
        XCTAssertEqual(d.map { la.component(.day, from: $0.date) }, [27, 30])
        let w = HistoryMetrics.weekWh(d)
        XCTAssertEqual(w.out, 36 * 59.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(w.in, 36 * 59.0 / 60, accuracy: 1e-9)
    }

    // MARK: - todayAccount (§4.1, §5)

    private var todayRows: [ChargePoint] {
        // 07:00–09:00 on battery (asleep before), 09:00–12:00 on power, then awake on battery until now-ish.
        // Times are absolute offsets from local midnight (the day has 25 hours; "09:00 PST" = +10 h).
        run(nov1 + 8 * 3600, nov1 + 10 * 3600, soc: 30, w: -15)
            + run(nov1 + 10 * 3600, nov1 + 13 * 3600, soc: 80, w: 20, ac: true, state: "charging")
            + run(nov1 + 13 * 3600, now, soc: 90, w: -10)
    }

    func testTodayAwakeSplitAndWh() {
        let t = HistoryMetrics.todayAccount(raw: todayRows, now: now, calendar: la)
        XCTAssertEqual(t.awakeOnBattery_s, 2 * 3600 + 3 * 3600 - 60, "5 h minus the unheld last row")
        XCTAssertEqual(t.awakeOnPower_s, 3 * 3600)
        XCTAssertEqual(t.whOut, 15 * 2 + 10 * (3 - 1.0 / 60), accuracy: 1e-9)
        XCTAssertEqual(t.whIn, 60, accuracy: 1e-9)
    }

    func testTodayStripHasAsleepThenBatteryPowerBatteryFuture() {
        let t = HistoryMetrics.todayAccount(raw: todayRows, now: now, calendar: la)
        XCTAssertEqual(t.strip.map(\.state), [.asleep, .battery, .power, .battery, .future])
        XCTAssertEqual(t.strip.first!.start.timeIntervalSince1970, TimeInterval(nov1))
        XCTAssertEqual(t.strip.last!.end.timeIntervalSince1970, TimeInterval(nov1 + 25 * 3600), "the fall-back day ends 25 h after midnight")
        XCTAssertEqual(t.strip.last!.start.timeIntervalSince1970, TimeInterval(now))
        XCTAssertEqual(t.strip[1].start.timeIntervalSince1970, TimeInterval(nov1 + 8 * 3600))
        XCTAssertEqual(t.strip[2].start.timeIntervalSince1970, TimeInterval(nov1 + 10 * 3600))
    }

    func testTodayStripMarksAWideGapAsleepAfterTheCap() {
        let rows = [cp(nov1 + 3600, ac: false), cp(nov1 + 3 * 3600, ac: false), cp(nov1 + 3 * 3600 + 60, ac: false)]
        let t = HistoryMetrics.todayAccount(raw: rows, now: nov1 + 3 * 3600 + 120, calendar: la)
        XCTAssertEqual(t.strip.map(\.state), [.asleep, .battery, .asleep, .battery, .future])
        XCTAssertEqual(t.strip[1].end.timeIntervalSince1970, TimeInterval(nov1 + 3600 + 120))
    }

    func testTodayLowestHighestArgminWithTimestampsTiesEarliest() {
        let rows = [cp(nov1 + 3600, soc: 40), cp(nov1 + 7200, soc: 5), cp(nov1 + 7260, soc: 5), cp(nov1 + 9000, soc: 95), cp(nov1 + 9060, soc: nil)]
        let t = HistoryMetrics.todayAccount(raw: rows, now: now, calendar: la)
        XCTAssertEqual(t.lowest, HistoryMetrics.SoCAt(soc: 5, ts: Date(timeIntervalSince1970: TimeInterval(nov1 + 7200))))
        XCTAssertEqual(t.highest?.soc, 95)
        XCTAssertNil(HistoryMetrics.todayAccount(raw: [], now: now, calendar: la).lowest)
    }

    func testTodayOnlyCountsRowsOfTheLocalDay() {
        let yesterday = run(nov1 - 3600, nov1, soc: 1, w: -100)   // Oct 31 23:00–24:00
        let t = HistoryMetrics.todayAccount(raw: yesterday + todayRows, now: now, calendar: la)
        XCTAssertEqual(t.lowest?.soc, 30)
        XCTAssertEqual(t.whOut, 15 * 2 + 10 * (3 - 1.0 / 60), accuracy: 1e-9)
    }

    // MARK: - chargeSessions (§14-D13)

    func testFlappingEdges2sApartDebounceToOneSession() {
        let t0 = nov1 + 8 * 3600
        let rows = run(t0, t0 + 600)                                    // off 10 min
            + [cp(t0 + 600, ac: true), cp(t0 + 602, ac: false), cp(t0 + 604, ac: true)]   // flap
            + run(t0 + 660, t0 + 1800, ac: true)                        // on
            + run(t0 + 1800, t0 + 2400)                                 // off
        let s = HistoryMetrics.chargeSessions(raw: rows)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].start.timeIntervalSince1970, TimeInterval(t0 + 600))
        XCTAssertEqual(s[0].end.timeIntervalSince1970, TimeInterval(t0 + 1740))
        XCTAssertFalse(s[0].ongoing)
    }

    func testSeparateSessionsAndOngoingAndNoEdgeAtStart() {
        let t0 = nov1 + 8 * 3600
        let rows = run(t0, t0 + 600, ac: true)          // already on: no edge, no session
            + run(t0 + 600, t0 + 1200)                  // off
            + run(t0 + 1200, t0 + 1800, ac: true)       // session 1
            + run(t0 + 1800, t0 + 2400)                 // off
            + run(t0 + 2400, t0 + 3000, ac: true)       // session 2, ongoing
        let s = HistoryMetrics.chargeSessions(raw: rows)
        XCTAssertEqual(s.count, 2)
        XCTAssertFalse(s[0].ongoing)
        XCTAssertTrue(s[1].ongoing)
        XCTAssertEqual(HistoryMetrics.chargeSessions(raw: []).count, 0)
    }

    func testTodaySessionsCountOnlyEdgesFallingToday() {
        // Edge yesterday 23:50 (session continues into today) + one edge today.
        let rows = run(nov1 - 1200, nov1 - 600) + run(nov1 - 600, nov1 + 600, ac: true)
            + run(nov1 + 600, nov1 + 1200) + run(nov1 + 1200, nov1 + 1800, ac: true)
        XCTAssertEqual(HistoryMetrics.todayAccount(raw: rows, now: now, calendar: la).sessions, 1)
    }

    // MARK: - limit hold / at full / low days (§14-D3, D9)

    func testLimitHoldHoursStitchesRawIntoAggregates() {
        let h0 = HistoryFormat.utcHourStart(midnight(2026, 10, 1))
        let aggs = [String(h0): agg(state: "limitHold"), String(h0 + 3600): agg(state: "charging")]
        let raw = run(nov1 + 3600, nov1 + 7200, state: "limitHold") + run(nov1 + 7200, nov1 + 7200 + 600, state: "limitHold")
        XCTAssertEqual(HistoryMetrics.limitHoldHours(agg: aggs, raw: raw), 3)
    }

    func testLifetimeRawFloorIsTheOldestRawFileBoundedByTheHorizon() {
        let today = HistoryFormat.utcDayStart(now)
        let edge = today - 7 * 86_400
        func floor(_ oldest: Int?) -> Int {
            HistoryMetrics.lifetimeRawFloor(now: now, oldestRawDay: oldest, rawRetentionDays: 7, horizonDays: 372)
        }
        XCTAssertEqual(floor(today - 40 * 86_400 + 99), today - 40 * 86_400, "back to the oldest raw day's UTC start")
        XCTAssertEqual(floor(today - 3 * 86_400), edge, "never later than the retention edge")
        XCTAssertEqual(floor(nil), edge, "no raw file: the retention edge")
        XCTAssertEqual(floor(today - 5_000 * 86_400), today - 372 * 86_400, "a stray ancient file cannot widen the walk")
    }

    func testUnaggregatedDropsOnlyTheRawRowsOfAggregatedHours() {
        let h = HistoryFormat.utcHourStart(nov1)
        let rows = [cp(h + 10), cp(h + 3600 + 10), cp(h + 7200 + 10)]
        let kept = HistoryMetrics.unaggregated(raw: rows, agg: [String(h + 3600): agg()])
        XCTAssertEqual(kept.map(\.ts), [h + 10, h + 7200 + 10])
    }

    func testAtFullOnPowerUsesSocMinIncludesUnknownAndWindows14Days() {
        let h = { (d: Int, hour: Int) in String(HistoryFormat.utcHourStart(self.midnight(2026, 10, d) + hour * 3600)) }
        let aggs: [String: HourlyAggregate] = [
            h(25, 10): agg(socMin: 100, socMax: 100, ac: 1, state: "unknown"),     // counts (unknown IS sitting full)
            h(25, 11): agg(socMin: 98, socMax: 100, ac: 1, state: "charging"),     // arriving hour: excluded
            h(25, 12): agg(socMin: 100, socMax: 100, ac: 0.4, state: "unknown"),   // mostly off AC: excluded
            h(10, 10): agg(socMin: 100, socMax: 100, ac: 1, state: "unknown"),     // 22 days back: outside 14 d
        ]
        let raw = run(nov1 + 3600, nov1 + 7200, soc: 100, w: 0, ac: true, state: "unknown")   // today, raw → stitched
        XCTAssertEqual(HistoryMetrics.atFullOnPowerHours(agg: aggs, raw: raw, now: now, calendar: la), 2)
    }

    func testLowDaysCountsAndDeepestWithDate() {
        let h = { (d: Int, hour: Int) in String(HistoryFormat.utcHourStart(self.midnight(2026, 10, d) + hour * 3600)) }
        let aggs: [String: HourlyAggregate] = [
            h(20, 9): agg(socMin: 18), h(20, 10): agg(socMin: 60),
            h(22, 9): agg(socMin: 7),
            h(24, 9): agg(socMin: 21),           // not ≤ 20
            h(5, 9): agg(socMin: 1),             // outside 14 d
        ]
        let raw = run(nov1 + 3600, nov1 + 3660, soc: 12)   // today, raw
        let l = HistoryMetrics.lowDays(agg: aggs, raw: raw, now: now, calendar: la)
        XCTAssertEqual(l.count, 3)
        XCTAssertEqual(l.deepest, 7)
        XCTAssertEqual(l.deepestDate, Date(timeIntervalSince1970: TimeInterval(midnight(2026, 10, 22))))
        XCTAssertEqual(l.daysWithReadings, 4, "Oct 20, 22, 24 and today carry a SoC; Oct 5 is outside the 14 days")
    }

    func testLowDaysWithNoReadingsInTheWindowSaysSo() {
        let l = HistoryMetrics.lowDays(agg: [:], raw: [], now: now, calendar: la)
        XCTAssertEqual(l.count, 0)
        XCTAssertNil(l.deepest)
        XCTAssertEqual(l.daysWithReadings, 0, "nothing read — the caller must not print a 0")
        let socless = HistoryMetrics.lowDays(agg: [:], raw: run(nov1 + 3600, nov1 + 3720, soc: nil), now: now, calendar: la)
        XCTAssertEqual(socless.daysWithReadings, 0, "rows without a SoC are not a reading of it")
    }

    func testLastFullChargeRawThenAggregateThenNil() {
        let h0 = HistoryFormat.utcHourStart(midnight(2026, 10, 1))
        let aggs = [String(h0): agg(socMin: 90, socMax: 100), String(h0 + 3600): agg(socMin: 90, socMax: 99)]
        let raw = [cp(nov1 + 100, soc: 100), cp(nov1 + 200, soc: 100), cp(nov1 + 300, soc: 99)]
        XCTAssertEqual(HistoryMetrics.lastFullCharge(raw: raw, agg: aggs), Date(timeIntervalSince1970: TimeInterval(nov1 + 200)))
        XCTAssertEqual(HistoryMetrics.lastFullCharge(raw: [cp(nov1, soc: 50)], agg: aggs), Date(timeIntervalSince1970: TimeInterval(h0)))
        XCTAssertNil(HistoryMetrics.lastFullCharge(raw: [], agg: [:]))
    }

    /// Raw is not always the newer tier (a raw day kept because its month could not be aggregated can be
    /// older than an aggregated day): the later of the two candidates wins.
    func testLastFullChargeTakesTheLaterOfRawAndAggregate() {
        let older = midnight(2026, 10, 3) + 3600
        let newerHour = HistoryFormat.utcHourStart(midnight(2026, 10, 20) + 9 * 3600)
        let aggs = [String(newerHour): agg(socMin: 90, socMax: 100)]
        XCTAssertEqual(HistoryMetrics.lastFullCharge(raw: [cp(older, soc: 100)], agg: aggs),
                       Date(timeIntervalSince1970: TimeInterval(newerHour)), "the newer aggregate hour wins")
        XCTAssertEqual(HistoryMetrics.lastFullCharge(raw: [cp(nov1 + 50, soc: 100)], agg: aggs),
                       Date(timeIntervalSince1970: TimeInterval(nov1 + 50)), "the newer raw row wins")
    }

    // MARK: - health (§5)

    private func hp(_ ts: Int, cycles: Int?, cap: Int? = 5000) -> HealthPoint {
        HealthPoint(ts: ts, healthPct: 88, cycles: cycles, maxCap_mAh: cap)
    }

    func testCyclesPerWeekNeeds14DaySpan() {
        let pts = (0..<10).map { hp(now - $0 * 86_400, cycles: 500 - $0) }
        XCTAssertNil(HistoryMetrics.cyclesPerWeek(health: pts, now: now), "10 days of span → —")
        XCTAssertNil(HistoryMetrics.cyclesPerWeek(health: [], now: now))
    }

    func testCyclesPerWeekSlopeOverLast90DaysOnly() {
        // 1 cycle/day for 28 days → 7/week. An ancient point with a wild value must be ignored.
        let pts = (0..<29).map { hp(now - $0 * 86_400, cycles: 500 - $0) } + [hp(now - 200 * 86_400, cycles: 0)]
        XCTAssertEqual(HistoryMetrics.cyclesPerWeek(health: pts, now: now)!, 7, accuracy: 1e-9)
    }

    func testWeeklyMedianCapacityPerISOWeekDividedByDesign() {
        // ISO week of Mon 2026-10-26; three readings (median 5100) + one in the next week (Mon Nov 2).
        let mon = midnight(2026, 10, 26)
        let pts = [hp(mon + 3600, cycles: 1, cap: 5000), hp(mon + 86_400, cycles: 1, cap: 5300), hp(mon + 3 * 86_400, cycles: 1, cap: 5100),
                   hp(midnight(2026, 11, 2) + 3600, cycles: 1, cap: 4000), hp(mon + 7200, cycles: 1, cap: nil)]
        let w = HistoryMetrics.weeklyMedianCapacityPct(health: pts, designCapacity_mAh: 6000, calendar: la)
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w[0].weekStart, Date(timeIntervalSince1970: TimeInterval(mon)))
        XCTAssertEqual(w[0].pct, 85, accuracy: 1e-9)
        XCTAssertEqual(w[1].weekStart, Date(timeIntervalSince1970: TimeInterval(midnight(2026, 11, 2))))
        XCTAssertEqual(w[1].pct, 4000.0 / 6000 * 100, accuracy: 1e-9)
        XCTAssertTrue(HistoryMetrics.weeklyMedianCapacityPct(health: pts, designCapacity_mAh: 0, calendar: la).isEmpty)
    }

    // MARK: - drained on power (§14-D2)

    func testDrainedOnPowerWhCountsOnlyNegativeWattsOnACInWindow() {
        let rows = run(now - 3600, now - 1800, w: -12, ac: true)        // 30 min drain on AC → 6 Wh (every row held 60 s)
            + run(now - 1800, now, w: 20, ac: true)                     // charging on AC: no
            + run(now - 8 * 86_400, now - 8 * 86_400 + 600, w: -50, ac: true)   // outside 7 d
            + [cp(now - 7200, w: -50, ac: false)]                       // battery: no
        XCTAssertEqual(try XCTUnwrap(HistoryMetrics.drainedOnPowerWh(raw: rows, now: now)), 6, accuracy: 1e-9)
    }

    /// On power and measured, nothing drained: a real 0 (the Fit row's "kept up").
    func testDrainedOnPowerIsZeroWhenOnPowerAndNeverDraining() throws {
        let rows = run(now - 3600, now, w: 20, ac: true)
        XCTAssertEqual(try XCTUnwrap(HistoryMetrics.drainedOnPowerWh(raw: rows, now: now)), 0)
    }

    /// Absence is not a fact: with no awake on-power time carrying a watts reading in the window there
    /// is nothing to judge the adapter by, so the figure is unknown (nil), never a measured 0.
    func testDrainedOnPowerIsUnknownWithoutAnOnPowerMeasurement() {
        XCTAssertNil(HistoryMetrics.drainedOnPowerWh(raw: [], now: now), "no rows at all")
        XCTAssertNil(HistoryMetrics.drainedOnPowerWh(raw: run(now - 3600, now, w: -12, ac: false), now: now),
                     "on battery the whole week")
        XCTAssertNil(HistoryMetrics.drainedOnPowerWh(raw: run(now - 3600, now, w: nil, ac: true), now: now),
                     "on power but no watts reading")
        XCTAssertNil(HistoryMetrics.drainedOnPowerWh(raw: run(now - 8 * 86_400, now - 8 * 86_400 + 600, w: 20, ac: true),
                                                     now: now), "on-power rows only outside the 7 days")
        XCTAssertNil(HistoryMetrics.drainedOnPowerWh(raw: [cp(now - 60, w: 20, ac: true)], now: now),
                     "a single row is held for nothing")
    }
}
