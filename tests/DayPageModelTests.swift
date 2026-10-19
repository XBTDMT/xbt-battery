import XCTest

/// #30 stage 3: the pure helpers behind the Day page (`DayPageModel`).
final class DayPageModelTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private func cp(_ ts: Int, soc: Int? = 50, w: Double? = -10, ac: Bool = false) -> ChargePoint {
        ChargePoint(ts: ts, soc: soc, watts: w, onAC: ac, state: ac ? "charging" : "discharging", limit: 80)
    }
    private func cell(_ ts: Int, soc: Double? = 50, power: Bool = false, rows: Bool = true) -> HistoryMetrics.HourCell {
        HistoryMetrics.HourCell(start: Date(timeIntervalSince1970: TimeInterval(ts)), socAvg: soc, onPower: power, hasRows: rows)
    }
    private func row(out: Double = 157.4, inn: Double = 140.2, net: Bool = false, avg: Double? = 17.44,
                     awake: Int = 9 * 3600 + 20 * 60, partial: Bool = false,
                     cells: [HistoryMetrics.HourCell] = []) -> HistoryMetrics.DayRow {
        HistoryMetrics.DayRow(date: Date(timeIntervalSince1970: 0), cells: cells, whOut: out, whIn: inn, whIsNet: net,
                              avgW_onBattery: avg, awakeOnBattery_s: awake, isPartial: partial)
    }

    // MARK: chart series

    func testChartPointsPassThroughBelowCapAndSkipNilSoc() {
        let raw = [cp(100, soc: nil), cp(200, soc: 40, w: -5, ac: true), cp(50, soc: 60)]
        let pts = DayPageModel.chartPoints(raw, lo: 0, hi: 300)
        XCTAssertEqual(pts.map(\.soc), [60, 40])
        XCTAssertEqual(pts.last?.watts, -5)
        XCTAssertEqual(pts.last?.onAC, true)
    }

    func testChartPointsDownsampleAveragesBucketsAndMajorityAC() {
        // 400 rows, cap 4 → 4 buckets of 100 rows; watts average inside a bucket.
        let raw = (0..<400).map { i in cp(i, soc: i < 100 ? 100 : 20, w: Double(-(i % 2)), ac: i >= 300) }
        let pts = DayPageModel.chartPoints(raw, lo: 0, hi: 400, maxPoints: 4)
        XCTAssertEqual(pts.count, 4)
        XCTAssertEqual(pts[0].soc, 100)
        XCTAssertEqual(pts[1].soc, 20)
        XCTAssertEqual(pts[0].watts ?? 9, -0.5, accuracy: 1e-9)
        XCTAssertEqual(pts.map(\.onAC), [false, false, false, true])
        XCTAssertEqual(pts.map(\.date), pts.map(\.date).sorted())
    }

    /// Owner 2026-09-11 (layout round, frame C): every tick on the chart's ruler is a round unit of time.
    func testRulerIntervalsTickEverySixHoursDayOrFiveDays() {
        XCTAssertEqual(DayPageModel.rulerIntervals(.h24), 4)    // 24 h / 4 = 6 h
        XCTAssertEqual(DayPageModel.rulerIntervals(.d7), 7)     // 1 day
        XCTAssertEqual(DayPageModel.rulerIntervals(.d30), 6)    // 5 days
        for r in ChargeRange.allCases {
            XCTAssertEqual(r.seconds % DayPageModel.rulerIntervals(r), 0, "\(r) must split into whole seconds")
        }
    }

    func testPeakAndNormalization() {
        let pts = [DayPageModel.ChartPoint(date: Date(), soc: 1, watts: -40, onAC: false),
                   DayPageModel.ChartPoint(date: Date(), soc: 1, watts: 20, onAC: true),
                   DayPageModel.ChartPoint(date: Date(), soc: 1, watts: nil, onAC: false)]
        XCTAssertEqual(DayPageModel.peakWatts(pts), 40)
        XCTAssertEqual(DayPageModel.peakWatts([]), 1)
        XCTAssertEqual(DayPageModel.normalizedWatts(-40, peak: 40), DayPageModel.wattsAreaCeilingPct)
        XCTAssertEqual(DayPageModel.normalizedWatts(20, peak: 40), DayPageModel.wattsAreaCeilingPct / 2)
        XCTAssertEqual(DayPageModel.normalizedWatts(5, peak: 0), 0)
    }

    func testNearest() {
        let pts = [0, 100, 200].map { DayPageModel.ChartPoint(date: Date(timeIntervalSince1970: TimeInterval($0)), soc: Double($0), watts: nil, onAC: false) }
        XCTAssertEqual(DayPageModel.nearest(pts, to: Date(timeIntervalSince1970: 130))?.soc, 100)
        XCTAssertNil(DayPageModel.nearest([], to: Date()))
    }

    // MARK: strings

    func testTooltipLines() {
        let p = DayPageModel.ChartPoint(date: Date(timeIntervalSince1970: 12 * 3600 + 58 * 60), soc: 55.4, watts: -22.44, onAC: false)
        let t = DayPageModel.tooltipLines(p, timeZone: utc)
        XCTAssertEqual(t.top, "12:58 · 55% · −22.4 W")
        XCTAssertEqual(t.bottom, "On battery")
        let q = DayPageModel.ChartPoint(date: p.date, soc: 80, watts: nil, onAC: true)
        XCTAssertEqual(DayPageModel.tooltipLines(q, timeZone: utc).top, "12:58 · 80%")
        XCTAssertEqual(DayPageModel.tooltipLines(q, timeZone: utc).bottom, "On power")
    }

    func testSignedWatts() {
        XCTAssertEqual(DayPageModel.signedWatts(-22.44), "−22.4 W")
        XCTAssertEqual(DayPageModel.signedWatts(18), "+18.0 W")
        XCTAssertEqual(DayPageModel.signedWatts(0), "0.0 W")
    }

    func testStartLabelAndStripLabel() {
        let d = Date(timeIntervalSince1970: 13 * 3600)   // 1970-01-01 13:00 UTC
        XCTAssertEqual(DayPageModel.startLabel(for: .h24, lo: d, timeZone: utc), "13:00")
        XCTAssertEqual(DayPageModel.startLabel(for: .d7, lo: d, timeZone: utc), "1 Jan")
        XCTAssertEqual(ChargeRange.allCases.map(DayPageModel.stripLabel), ["24 h", "7 d", "30 d"])
    }

    func testDayLabels() {
        XCTAssertEqual((1...7).map(DayPageModel.dayLabel), ["Su", "M", "Tu", "W", "Th", "F", "Sa"])
        XCTAssertEqual(DayPageModel.dayLabel(weekday: 0), "?")
    }

    func testColumns() {
        let r = row()
        let wh = DayPageModel.whColumns(r)
        XCTAssertEqual(wh.first, "157"); XCTAssertEqual(wh.second, "140")
        let n = DayPageModel.whColumns(row(out: 52.6, inn: 0, net: true))
        XCTAssertEqual(n.first, "−53"); XCTAssertEqual(n.second, "net")
        XCTAssertEqual(DayPageModel.whColumns(row(out: 0, inn: 30, net: true)).first, "30")
        XCTAssertEqual(DayPageModel.avgWText(17.44), "17.4 W")
        XCTAssertEqual(DayPageModel.avgWText(nil), "—")
        XCTAssertEqual(DayPageModel.awakeText(seconds: 9 * 3600 + 20 * 60), "9h")
        XCTAssertEqual(DayPageModel.awakeText(seconds: 9 * 3600 + 40 * 60), "10h")
        XCTAssertEqual(DayPageModel.awakeText(seconds: 0), "0h")
    }

    // MARK: cells

    func testCellStyle() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(DayPageModel.cellStyle(cell(10_000), now: now), .future)
        XCTAssertEqual(DayPageModel.cellStyle(cell(9_000, rows: false), now: now), .asleep)
        XCTAssertEqual(DayPageModel.cellStyle(cell(9_000, power: true), now: now), .power)
        XCTAssertEqual(DayPageModel.cellStyle(cell(9_000, soc: 72), now: now), .battery(0.72))
        XCTAssertEqual(DayPageModel.cellStyle(cell(9_000, soc: 5), now: now), .battery(DayPageModel.heatmapFloorAlpha))
        XCTAssertEqual(DayPageModel.cellStyle(cell(9_000, soc: nil), now: now), .battery(DayPageModel.heatmapFloorAlpha))
    }

    // MARK: accessibility

    func testRowAXValue() {
        let cells = [cell(0, power: true), cell(3600, rows: false), cell(7200)]
        let v = DayPageModel.rowAXValue(row(partial: true, cells: cells))
        XCTAssertEqual(v, "157 watt-hours out, 140 in; average 17.4 W; 9h awake on battery; 1 hours on power, 1 hours asleep; today, so far")
        XCTAssertTrue(DayPageModel.rowAXValue(row(out: 10, inn: 0, net: true)).hasPrefix("−10 watt-hours net"))
    }

    func testChartAXValue() {
        let pts = [30.0, 80, 55].map { DayPageModel.ChartPoint(date: Date(), soc: $0, watts: nil, onAC: false) }
        XCTAssertEqual(DayPageModel.chartAXValue(pts, limit: 80), "Now 55 percent, ranged 30 to 80 percent; limit 80 percent")
        XCTAssertEqual(DayPageModel.chartAXValue([], limit: nil), "No data yet")
    }
}
