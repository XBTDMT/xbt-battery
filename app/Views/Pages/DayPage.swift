import SwiftUI
import Charts

/// #30 stage 3 · the DAY tab (spec §4.3; mock `.page.day`). Header "32% · 38m left" + the 24 h / 7 d / 30 d
/// strip; the Swift Charts plot (SoC line, |watts| area normalized onto the SoC axis — §14-B7, AC spans
/// in the fixed on-power blue, dashed limit rule, drag scrubber); then the per-local-day table with a
/// `Grid`-free row of `RoundedRectangle` heatmap cells (§14-B11) and the Wh out / in · avg W · awake
/// columns. Fills the width the shell gives it (297 pt at the 360 pt popover) and fills exactly
/// `DSMetric.pageHeight` (470), distributing header / chart / table down the frame; never scrolls. R15 parity: the mock has no limit-hold spans and no "limit N"
/// annotation — only the dashed rule — so neither is drawn here.
///
/// Data is computed once per (appearance, range) in `.task(id:)` on the main actor — the store is
/// `@MainActor` and the reads are memoized per file version — and cancels with the page (§8 page lifetime).
struct DayPage: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var engine: ChargeLimitEngine
    let reduceMotion: Bool

    @State private var range: ChargeRange = .h24
    @State private var data = PageData()
    @State private var scrub: Date?
    /// Spec 31 §2.6: the render harness pins the clock; nil in every normal launch.
    @Environment(\.fixtureNow) private var fixtureNow

    /// Everything the page renders, shaped once per range.
    struct PageData: Equatable {
        var points: [DayPageModel.ChartPoint] = []
        var acSpans: [GraphSpan] = []
        var peakW: Double = 1
        // Placeholders until the first `recompute()` — nothing reads them while `points` / `rows` are empty.
        // Constants, so no wall-clock read hides here (spec 31 §2.6).
        var lo = Date.distantPast
        var now = Date.distantPast
        var rows: [HistoryMetrics.DayRow] = []
        var isEmpty: Bool { points.count < 2 }
    }

    private var limitValue: Int? {
        if case .known(let v) = engine.limit { return v } else { return nil }
    }

    var body: some View {
        // Owner ruling 2026-09-09 (evening): the page DISTRIBUTES its three blocks down the 470 pt frame —
        // mock `.pg .page { justify-content: space-between }` — instead of a top-pinned stack with one trailing
        // spacer. The two `Spacer()`s share the leftover height equally; the chart block is elastic
        // (`chartMinHeight…chartMaxHeight`) and, having a higher layout priority than a Spacer, grows first.
        VStack(alignment: .leading, spacing: 0) {
            header
            Color.clear.frame(height: 10)
            blockTitle("Battery level", trailing: DayPageModel.rangeTitle(range))
            chartBlock
            if !data.isEmpty { keyRow(Self.chartKey).padding(.top, Self.keyGap) }
            // Owner 2026-09-11: "there is some neg area" between the chart's key and "Last 7 days" — 10 pt, the
            // same gap that sits above "Battery level"; the chart takes what this frees (up to its 190 pt max).
            Color.clear.frame(height: 10)
            table
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dsPageFrame(.fixed, alignment: .center)
        .task(id: range) { recompute() }
    }

    // MARK: - header

    private var header: some View {
        let s = monitor.snapshot
        let time = HeroStats.timeText(onAC: s.powerSource == .ac, chargePercent: s.chargePercent,
                                      limit: limitValue, amperageMilliamps: s.smoothedAmperageMilliamps,
                                      fullChargeCapacity_mAh: s.fullChargeCapacity_mAh,
                                      minutesToEmpty: s.minutesToEmpty, isCharging: s.isCharging,
                                      packRising: s.packRising, packInflowMilliamps: s.packInflowMilliamps)
        return HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(s.chargePercent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DSSurface.text)
                Text("· \(time)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DSSurface.text2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DSMetric.space2)
            DSStrip(selection: $range, pairs: ChargeRange.allCases.map { ($0, DayPageModel.stripLabel($0)) })
                .frame(width: 130)
                .accessibilityLabel("Range")
        }
        .padding(.top, 2)
        .padding(.bottom, DSMetric.space2)
    }

    // MARK: - chart

    /// The block is elastic — at least 150 pt and up to ~190 when the 470 pt frame has room; the ruler under the
    /// plot keeps its natural height and the plot takes the rest.
    private static let chartMinHeight: CGFloat = 150
    private static let chartMaxHeight: CGFloat = 190

    /// Owner 2026-09-11 (layout round, frame C): each block's colour key sits UNDER the block, 5 pt below it,
    /// instead of beside its title.
    private static let chartKey: [(Color, String)] = [(DSColor.charging, "level"), (DSColor.attention.opacity(0.7), "draw"), (DSColor.onPower.opacity(0.6), "on power")]
    private static let tableKey: [(Color, String)] = [(DSColor.charging, "level by hour"), (DSColor.onPower.opacity(0.6), "on power"), (DSColor.holding.opacity(0.35), "asleep")]
    private static let keyGap: CGFloat = 5

    @ViewBuilder private var chartBlock: some View {
        if data.isEmpty {
            Text(PopoverDetailStrings.historyEmpty(recordingSince: history.recordingSince) {
                $0.formatted(date: .abbreviated, time: .omitted)
            })
            .font(.system(size: 11)).foregroundStyle(DSSurface.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: Self.chartMinHeight, idealHeight: Self.chartMinHeight,
                   maxHeight: Self.chartMaxHeight, alignment: .center)
        } else {
            VStack(spacing: 0) {
                chart
                    .frame(maxHeight: .infinity)
                DSRuler(leading: DayPageModel.startLabel(for: range, lo: data.lo, timeZone: .current),
                        trailing: "now", trailingEmphasis: true,
                        intervals: DayPageModel.rulerIntervals(range))
            }
            .frame(minHeight: Self.chartMinHeight, idealHeight: Self.chartMinHeight, maxHeight: Self.chartMaxHeight)
        }
    }

    private var chart: some View {
        Chart {
            // Spans first so the line and area ride on top (ported from d6HistoryCard).
            ForEach(data.acSpans, id: \.start) { span in
                RectangleMark(xStart: .value("From", span.start), xEnd: .value("To", span.end),
                              yStart: .value("lo", 0), yEnd: .value("hi", 100))
                    .foregroundStyle(DSColor.onPower.opacity(0.14))     // on the adapter (mock rgba(10,132,255,.14))
            }
            // §14-B7: one y-scale — |watts| normalized onto 0…100.
            ForEach(data.points, id: \.date) { p in
                if let w = p.watts {
                    AreaMark(x: .value("Time", p.date),
                             y: .value("Draw", DayPageModel.normalizedWatts(w, peak: data.peakW)),
                             series: .value("Series", "draw"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(DSColor.attention.opacity(0.25))
                }
            }
            ForEach(data.points, id: \.date) { p in
                LineMark(x: .value("Time", p.date), y: .value("Charge", p.soc),
                         series: .value("Series", "soc"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .foregroundStyle(DSColor.charging)
            }
            if let limit = limitValue {
                RuleMark(y: .value("Limit", Double(limit)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(DSSurface.text2.opacity(0.6))
            }
            if let scrub {
                RuleMark(x: .value("Scrub", scrub))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(DSSurface.text2)
            }
        }
        .chartXScale(domain: data.lo...data.now)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(.top, 6).padding(.bottom, 4) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = plotRect(proxy, geo)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    // Owner (Day tab walkthrough): the readout must follow the pointer on HOVER, not only on
                    // click. `onContinuousHover` streams the pointer location; a drag still works.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let x = min(max(loc.x - plot.origin.x, 0), plot.width)
                            if let d: Date = proxy.value(atX: x) { scrub = d }
                        case .ended:
                            scrub = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let x = min(max(v.location.x - plot.origin.x, 0), plot.width)
                                if let d: Date = proxy.value(atX: x) { scrub = d }
                            }
                            .onEnded { _ in scrub = nil }
                    )
                if let scrub, let p = DayPageModel.nearest(data.points, to: scrub),
                   let px = proxy.position(forX: p.date) {
                    tooltip(p)
                        .fixedSize()
                        .offset(x: tooltipX(px + plot.origin.x, width: geo.size.width), y: plot.origin.y + 6)
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: range)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery level, \(DayPageModel.stripLabel(range))")
        .accessibilityValue(DayPageModel.chartAXValue(data.points, limit: limitValue))
    }

    /// The plot rect in the overlay's space. `plotFrame` is macOS 15; on 14 the plot is the whole overlay
    /// because both axes are hidden and the only inset is `chartPlotStyle`'s (a few points of y, no x).
    private func plotRect(_ proxy: ChartProxy, _ geo: GeometryProxy) -> CGRect {
        if #available(macOS 15, *), let anchor = proxy.plotFrame { return geo[anchor] }
        return CGRect(origin: .zero, size: geo.size)
    }

    /// Keep the tooltip inside the plot (and therefore below the range strip, which sits above the chart —
    /// §7 "never overlaps the range strip").
    private func tooltipX(_ px: CGFloat, width: CGFloat) -> CGFloat {
        return min(max(px + 8, 0), max(0, width - Self.tooltipWidth))
    }

    /// Mock: a 96 × 24 dark card (#1c1d21, 1 px white 12 % border, radius 5, 8.5 px text) inside the plot.
    private static let tooltipWidth: CGFloat = 96

    private func tooltip(_ p: DayPageModel.ChartPoint) -> some View {
        let lines = DayPageModel.tooltipLines(p, timeZone: .current)
        return VStack(alignment: .leading, spacing: 1) {
            Text(lines.top).foregroundStyle(Color.white.opacity(0.95))
            Text(lines.bottom).foregroundStyle(Color.white.opacity(0.6))
        }
        .font(.system(size: 8.5).monospacedDigit())
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .frame(width: Self.tooltipWidth, alignment: .leading)
        .allowsHitTesting(false)
    }

    // MARK: - table

    // Mock `.dayrow` grid: 20 | 1fr | 66 | 40 | 26, gap 5.
    private static let colLabel: CGFloat = 20
    private static let colWh: CGFloat = 60
    private static let colAvg: CGFloat = 40
    private static let colAwake: CGFloat = 36
    private static let colGap: CGFloat = 5
    private static let cellHeight: CGFloat = 12      // `.pg .page.day .dayrow .hmr i { height: 12px }`
    private static let rowMargin: CGFloat = 6        // `.pg .page.day .dayrow { margin: 6px 0 }`

    /// The table is one block — title-and-captions line + rows + hour ruler + key — so the frame's leftover
    /// height lands between the major blocks, never inside the table.
    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Self.rowMargin) {
                tableHeader
                // Collapsed CSS margins → `rowMargin` between rows.
                ForEach(data.rows, id: \.date) { row in
                    dayRow(row)
                }
            }
            if !data.rows.isEmpty {
                hourRuler
                keyRow(Self.tableKey).padding(.top, Self.keyGap)
            }
        }
    }

    /// Owner 2026-09-11: a ruler under the heatmap column only, once below the last row — a tick every 6 h,
    /// 0:00 · 12:00 · 24:00 (the column is ~120 pt, too narrow for five labels). On a 23 / 25 h day the ticks
    /// are quarter-widths.
    private var hourRuler: some View {
        HStack(alignment: .top, spacing: Self.colGap) {
            Color.clear.frame(width: Self.colLabel, height: 1)
            DSRuler(leading: "0:00", center: "12:00", trailing: "24:00").frame(maxWidth: .infinity)
            Color.clear.frame(width: Self.colWh + Self.colAvg + Self.colAwake + 2 * Self.colGap, height: 1)
        }
    }

    /// A 12 pt semibold block title and a trailing caption (the range, e.g. "last 24 h").
    private func blockTitle(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DSSurface.text)
            Spacer(minLength: 4)
            Text(trailing).font(.system(size: 10)).foregroundStyle(DSSurface.text3)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    /// A block's colour key, under the block: 8 × 6 pt swatches + 9.5 pt tertiary words.
    private func keyRow(_ legend: [(Color, String)]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).fill(item.0).frame(width: 8, height: 6)
                    Text(item.1).font(.system(size: 9.5)).foregroundStyle(DSSurface.text3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Owner 2026-09-11 (layout round, frame C): the block title and the column captions share ONE line —
    /// "Last 7 days" over the day-label + heatmap columns, each caption over its own column — so no empty band
    /// sits under the title.
    private var tableHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.colGap) {
            Text("Last 7 days").font(.system(size: 12, weight: .semibold)).foregroundStyle(DSSurface.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text("Wh out / in").frame(width: Self.colWh, alignment: .trailing).lineLimit(1)
                Text("avg W").frame(width: Self.colAvg, alignment: .trailing)
                Text("awake").frame(width: Self.colAwake, alignment: .trailing)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(DSSurface.text3)
            .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }

    private func dayRow(_ row: HistoryMetrics.DayRow) -> some View {
        let wh = DayPageModel.whColumns(row)
        let weekday = Calendar.current.component(.weekday, from: row.date)
        let label = DayPageModel.dayLabel(weekday: weekday)
        return HStack(spacing: Self.colGap) {
            Text(label).frame(width: Self.colLabel, alignment: .leading)
            heatRow(row)
            (Text(wh.first) + Text(" / ").foregroundStyle(DSSurface.text3) + Text(wh.second))
                .foregroundStyle(DSSurface.text)
                .frame(width: Self.colWh, alignment: .trailing).lineLimit(1)
            Text(DayPageModel.avgWText(row.avgW_onBattery))
                .frame(width: Self.colAvg, alignment: .trailing).lineLimit(1)
            Text(DayPageModel.awakeText(seconds: row.awakeOnBattery_s))
                .frame(width: Self.colAwake, alignment: .trailing).lineLimit(1)
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(DSSurface.text2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.isPartial ? "Today" : row.date.formatted(date: .abbreviated, time: .omitted))
        .accessibilityValue(DayPageModel.rowAXValue(row))
    }

    /// §14-B11: a row of `RoundedRectangle`s, not a Charts heatmap, so it aligns with the sibling columns.
    /// 23 / 24 / 25 cells as the day has hours (§14-D14).
    private func heatRow(_ row: HistoryMetrics.DayRow) -> some View {
        HStack(spacing: 1.5) {
            ForEach(row.cells, id: \.start) { cell in
                let style = DayPageModel.cellStyle(cell, now: data.now)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(cellColor(style))
                    .overlay {
                        if row.isPartial {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .strokeBorder(DSSurface.text.opacity(0.15), lineWidth: 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.cellHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func cellColor(_ s: DayPageModel.CellStyle) -> Color {
        switch s {
        case .future:         DSColor.charging.opacity(DayPageModel.heatmapFutureAlpha)
        case .asleep:         DSColor.holding.opacity(0.35)
        case .power:          DSColor.onPower.opacity(0.6)       // `.hmr i.ac` rgba(10,132,255,.6)
        case .battery(let a): DSColor.charging.opacity(a)
        }
    }

    // MARK: - data

    private func recompute() {
        let clock = fixtureNow ?? Date()
        let nowTs = Int(clock.timeIntervalSince1970)
        let lo = nowTs - range.seconds
        let raw = history.series(range: lo...nowTs)
        let series = GraphVM.charge(raw, range: range, now: nowTs, tz: .current)
        let points = DayPageModel.chartPoints(raw, lo: lo, hi: nowTs)
        // The table always shows the last 7 local days: raw rows for the whole raw window plus the
        // aggregates so a day that lost its raw file still renders (§5, §14-D3).
        let cal = Calendar.current
        let tableLo = Int((cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: clock)) ?? clock).timeIntervalSince1970)
        let tableRaw = range == .h24 ? history.series(range: tableLo...nowTs) : raw
        let rows = HistoryMetrics.dayRows(raw: tableRaw, agg: history.allAggregates(), now: nowTs, calendar: cal)
        data = PageData(points: points, acSpans: series.acSpans,
                        peakW: DayPageModel.peakWatts(points),
                        lo: Date(timeIntervalSince1970: TimeInterval(lo)),
                        now: Date(timeIntervalSince1970: TimeInterval(nowTs)),
                        rows: rows)
        scrub = nil
    }
}
