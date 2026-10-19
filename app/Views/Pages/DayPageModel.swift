import Foundation

/// #30 stage 3 · the PURE helpers behind `DayPage` (spec §4.3, §5, §14-B7/B11/D14). Host-app-free so the
/// test target compiles it without the view: chart-series shaping (SoC + signed watts downsampled into one
/// point list, the |watts| area normalized onto the 0–100 SoC axis — Swift Charts has one y-scale, §14-B7),
/// the table's cell styling and column strings, the scrubber's tooltip text, and the VoiceOver value of a
/// day row. No I/O, no clock: every function takes the rows, a `now`, and a `Calendar` / `TimeZone`.
enum DayPageModel {
    /// The chart title's trailing caption: "last 24 h" / "last 7 days" / "last 30 days".
    static func rangeTitle(_ r: ChargeRange) -> String {
        switch r { case .h24: "last 24 h"; case .d7: "last 7 days"; case .d30: "last 30 days" }
    }

    /// One plotted point: `soc` drives the line, `watts` (signed, − = discharging) the area, `onAC` the
    /// tooltip's "On power / On battery".
    struct ChartPoint: Equatable, Sendable {
        let date: Date
        let soc: Double
        let watts: Double?
        let onAC: Bool
    }

    /// The area under the chart: |watts| mapped so the range's PEAK draw reaches this many percent of the
    /// SoC axis (the mock's area rides in the bottom ~30 % of the plot; a peak-to-100 mapping would bury the
    /// line under the fill).
    static let wattsAreaCeilingPct: Double = 30

    /// §10: the heatmap's floor alpha in light appearance (a 12 % cell is invisible on white).
    static let heatmapFloorAlpha: Double = 0.15
    static let heatmapFutureAlpha: Double = 0.06

    // MARK: - chart series

    /// The range's raw rows → ≤ `maxPoints` points, averaged in uniform absolute-time buckets (same policy
    /// as `GraphVM.downsample`, extended to carry watts + the bucket's majority `onAC`). Rows without a
    /// SoC are skipped for the line but still contribute watts to their bucket. Sorted by time.
    static func chartPoints(_ raw: [ChargePoint], lo: Int, hi: Int, maxPoints: Int = 200) -> [ChartPoint] {
        let inRange = raw.filter { $0.ts >= lo && $0.ts <= hi && $0.soc != nil }.sorted { $0.ts < $1.ts }
        guard inRange.count > maxPoints else {
            return inRange.map { ChartPoint(date: date($0.ts), soc: Double($0.soc!), watts: $0.watts, onAC: $0.onAC) }
        }
        let span = max(1, hi - lo)
        let bucketW = max(1, span / maxPoints)
        struct Acc { var sumT = 0.0, sumS = 0.0, n = 0, sumW = 0.0, nW = 0, ac = 0 }
        var acc: [Int: Acc] = [:]
        for r in inRange {
            let b = (r.ts - lo) / bucketW
            var a = acc[b] ?? Acc()
            a.sumT += Double(r.ts); a.sumS += Double(r.soc!); a.n += 1
            if let w = r.watts { a.sumW += w; a.nW += 1 }
            if r.onAC { a.ac += 1 }
            acc[b] = a
        }
        return acc.keys.sorted().map { k in
            let a = acc[k]!
            return ChartPoint(date: Date(timeIntervalSince1970: a.sumT / Double(a.n)),
                              soc: a.sumS / Double(a.n),
                              watts: a.nW > 0 ? a.sumW / Double(a.nW) : nil,
                              onAC: a.ac * 2 >= a.n)
        }
    }

    /// The largest |watts| in the series (≥ 1 so the normalization never divides by zero).
    static func peakWatts(_ pts: [ChartPoint]) -> Double {
        max(1, pts.compactMap { $0.watts.map(abs) }.max() ?? 1)
    }

    /// §14-B7: |watts| onto the SoC axis — `peak` maps to `wattsAreaCeilingPct`.
    static func normalizedWatts(_ watts: Double, peak: Double) -> Double {
        guard peak > 0 else { return 0 }
        return min(100, abs(watts) / peak * wattsAreaCeilingPct)
    }

    /// The point nearest a scrubbed instant (the series is sorted; a binary search would be over-engineering
    /// for ≤ 200 points).
    static func nearest(_ pts: [ChartPoint], to d: Date) -> ChartPoint? {
        pts.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
    }

    // MARK: - strings

    private static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    /// A signed watt figure with a true minus sign: "−22.4 W", "+18.0 W".
    static func signedWatts(_ w: Double) -> String {
        let mag = String(format: "%.1f W", abs(w))
        if w < -0.05 { return "−" + mag }
        if w > 0.05 { return "+" + mag }
        return mag
    }

    /// The scrubber tooltip's two lines: "12:58 · 55% · −22.4 W" and "On battery" / "On power".
    static func tooltipLines(_ p: ChartPoint, timeZone tz: TimeZone) -> (top: String, bottom: String) {
        let f = DateFormatter()
        f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        var top = "\(f.string(from: p.date)) · \(Int(p.soc.rounded()))%"
        if let w = p.watts { top += " · \(signedWatts(w))" }
        return (top, p.onAC ? "On power" : "On battery")
    }

    /// The chart's leading x label: "13:00" for 24 h, "2 Sep" for the longer ranges. The trailing one is
    /// always "now".
    static func startLabel(for range: ChargeRange, lo: Date, timeZone tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = range == .h24 ? "HH:mm" : "d MMM"
        return f.string(from: lo)
    }

    /// The range strip's labels ("24 h / 7 d / 30 d" per the mock; `ChargeRange.title` is the old "24H").
    static func stripLabel(_ r: ChargeRange) -> String {
        switch r { case .h24: "24 h"; case .d7: "7 d"; case .d30: "30 d" }
    }

    /// Intervals on the chart's ruler, so every tick is a round unit of time: every 6 h on 24 h, every day on
    /// 7 d, every 5 days on 30 d.
    static func rulerIntervals(_ r: ChargeRange) -> Int {
        switch r { case .h24: 4; case .d7: 7; case .d30: 6 }
    }

    /// The mock's two-letter day labels (Su M Tu W Th F Sa), by `Calendar.weekday` (1 = Sunday).
    static func dayLabel(weekday: Int) -> String {
        let names = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]
        return (1...7).contains(weekday) ? names[weekday - 1] : "?"
    }

    /// "157 / 140" split into the two numbers (the view draws the slash in tertiary). A day known only as
    /// NET (aggregates, §5) shows the signed net in the first slot and "net" in the second.
    static func whColumns(_ row: HistoryMetrics.DayRow) -> (first: String, second: String) {
        if row.whIsNet {
            let net = row.whIn - row.whOut
            return (net < 0 ? "−\(Int((-net).rounded()))" : "\(Int(net.rounded()))", "net")
        }
        return ("\(Int(row.whOut.rounded()))", "\(Int(row.whIn.rounded()))")
    }

    /// "17.4 W", "—" when the day had no awake battery time.
    static func avgWText(_ w: Double?) -> String {
        guard let w else { return "—" }
        return String(format: "%.1f W", w)
    }

    /// "9h" — awake hours on battery, rounded to the hour.
    static func awakeText(seconds: Int) -> String {
        "\(Int((Double(max(0, seconds)) / 3600).rounded()))h"
    }

    // MARK: - heatmap cells

    enum CellStyle: Equatable, Sendable {
        case future            // today's unelapsed hours — 6 % green + outline
        case asleep            // no rows that hour — neutral (`DSColor.holding` at 35 %)
        case power             // on the adapter — accent
        case battery(Double)   // green at socAvg / 100 (floored at `heatmapFloorAlpha`)
    }

    /// A cell is `future` when its hour has not started by `now`; the running hour renders as data.
    static func cellStyle(_ c: HistoryMetrics.HourCell, now: Date) -> CellStyle {
        if c.start >= now { return .future }
        guard c.hasRows else { return .asleep }
        if c.onPower { return .power }
        let a = (c.socAvg ?? 0) / 100
        return .battery(max(heatmapFloorAlpha, min(1, a)))
    }

    // MARK: - accessibility

    /// §10: each day row is ONE element; this is its value string.
    static func rowAXValue(_ row: HistoryMetrics.DayRow) -> String {
        let wh = whColumns(row)
        let energy = row.whIsNet ? "\(wh.first) watt-hours net" : "\(wh.first) watt-hours out, \(wh.second) in"
        var s = "\(energy); average \(avgWText(row.avgW_onBattery)); \(awakeText(seconds: row.awakeOnBattery_s)) awake on battery"
        let onPower = row.cells.filter { $0.hasRows && $0.onPower }.count
        let asleep = row.cells.filter { !$0.hasRows }.count
        s += "; \(onPower) hours on power, \(asleep) hours asleep"
        if row.isPartial { s += "; today, so far" }
        return s
    }

    /// The chart's VoiceOver value: current level, range, and the limit when known.
    static func chartAXValue(_ pts: [ChartPoint], limit: Int?) -> String {
        let socs = pts.map(\.soc)
        guard let now = socs.last, let lo = socs.min(), let hi = socs.max() else { return "No data yet" }
        var v = "Now \(Int(now.rounded())) percent, ranged \(Int(lo.rounded())) to \(Int(hi.rounded())) percent"
        if let limit { v += "; limit \(limit) percent" }
        return v
    }
}
