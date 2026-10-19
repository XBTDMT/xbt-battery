import SwiftUI
import Charts

/// #30 §4.5 Health (H1), built to the mockup's `.page.health` (no ScrollView). The page fills the width
/// the rail shell gives it (360 − inset − rail − hairline − gap → 297 pt) inside the fixed
/// `DSMetric.pageHeight` (470) frame. Owner re-ruling 2026-09-09: the mock is
/// `.pg .page{display:flex;flex-direction:column;justify-content:space-between;gap:10px}` — the four
/// blocks (header, dial + grid, lifetime card, chart) are DISTRIBUTED down the frame by flexible
/// `Spacer(minLength: 10)`s sharing the leftover height, never a top-pinned stack.
///
/// Header "Health" + condition chip (green "Normal" ONLY when `BatteryLifetime.condition == "Normal"`,
/// i.e. `PermanentFailureStatus` resolved to 0 — never fabricated; "Unknown" neutral; anything else
/// attention). Left: the half dial (health fraction) over "87%" and "5,435 / 6,249 mAh". Right: two
/// columns of six use figures (`.hg .rowsm`: 11.5 pt, 4 × 14 gaps, 6 pt cell padding ≈ 26 pt rows). Then
/// five lifetime rows (`.page.health .rowsm` 12 pt, 6 pt padding → 27 pt rows), then the weekly-median
/// capacity chart (~90 pt block) with the faint 0 · 50 · 100 axis (R7). Y is % of the LIVE
/// `designCapacity_mAh` (§14-D15).
///
/// While the history store needs attention (a month or raw day that will not read, an aggregate that could
/// not be written) a one-line note sits under the figures — spec 30 §16 row "32 · Health · history note".
///
/// Data honesty (§6): when the lifetime read failed (`lastFailure`) or has not happened, every cell on
/// the page prints "—" and the chart draws its axis with no line — never a 0. The history figures are
/// computed ONCE per appearance in a `.task` on the main actor (the store is `@MainActor`) into `@State`,
/// never per render.
struct HealthPage: View {
    @ObservedObject var batteryLifetime: BatteryLifetimeSource
    @ObservedObject var history: HistoryStore
    @ObservedObject var engine: ChargeLimitEngine

    /// The §5 XS figures, computed off the store's rows. nil until the task has run.
    struct Figures: Equatable {
        let cyclesPerWeek: Double?
        let limitHoldHours: Int
        let atFullHours: Int
        let lowDays: HistoryMetrics.LowDays
        let lastFullCharge: Date?
        let weeks: [HistoryMetrics.WeeklyCapacity]
        let now: Date
    }
    @State private var figures: Figures?
    /// Spec 31 §2.6: the render harness pins the clock; nil in every normal launch.
    @Environment(\.fixtureNow) private var fixtureNow

    private static let lowDaysWindow = 14
    private let calendar = Calendar.current
    private let dash = HealthPageModel.dash

    // Mockup geometry (`.dial.sm`, `.hg`, `.rowsm`, `.axis`).
    private static let dialColumnWidth: CGFloat = 92
    private static let dialSize: CGFloat = 84          // `.dial.sm` 84 × 44
    private static let dialRing: CGFloat = 12          // ring thickness (mask 30/31 px on 84 → ~12)
    private static let figureFont: CGFloat = 11.5
    private static let figureCellPad: CGFloat = 6      // `.hg .rowsm{padding:6px 0}` → ~26 pt rows at 11.5 pt
    private static let figureMinGap: CGFloat = DSMetric.space1   // label ↔ figure never touch (see `figureCell`)
    private static let lifetimeFont: CGFloat = 12
    private static let lifetimeRowPad: CGFloat = 6     // `.page.health .rowsm{padding:6px 0}` → 27 pt rows
    private static let noteFont: CGFloat = 10.5        // the history note (spec 30 §16 row 32, render P3)
    private static let noteGap: CGFloat = 8            // figures → note
    private static let chartPlotHeight: CGFloat = 78   // + 10 pt caption + 2 spacing ≈ 90 block
    private static let blockGap: CGFloat = 10          // `.pg .page{gap:10px}` — the spacers' floor
    private static let axisLabelWidth: CGFloat = 18    // the mock's `x="18"` plot origin

    var body: some View {
        let lt = batteryLifetime.lifetime
        VStack(alignment: .leading, spacing: 0) {
            DSPageHeader(title: "Health") { conditionChip(lt?.condition ?? "Unknown", known: lt != nil) }

            Spacer()

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: DSMetric.space3) {
                    dialColumn(lt)
                    figureGrid(lt)
                }
                historyNote
            }

            Spacer()

            lifetimeCard(lt)

            Spacer()

            capacityChart(designCapacity: lt?.designCapacity_mAh)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPageFrame(.fixed, alignment: .top)   // the frame is the budget: never exceed 297 × 470
        .task(id: lt?.designCapacity_mAh) {
            // On-demand, read-only IORegistry read (the popover's own refresh normally precedes this;
            // harmless when it already ran). Never a timer.
            if batteryLifetime.lifetime == nil, batteryLifetime.lastFailure == nil { batteryLifetime.refresh() }
            // The history note's read-side state, re-checked from disk on appearance (reads only, memoised)
            // so a repaired file stops being named without waiting for the daily maintenance run.
            history.refreshUnreadableHistory()
            loadFigures(designCapacity: batteryLifetime.lifetime?.designCapacity_mAh)
        }
    }

    // MARK: - header chip

    /// `.chip` 11 pt, 2 × 8 padding, capsule. `.chip.g` = healthy .18 background under a pale green text
    /// (the mock's #7fe39a ≈ healthy mixed ~0.4 toward white); "Unknown" neutral; anything else attention.
    private func conditionChip(_ condition: String, known: Bool) -> some View {
        let tone = known ? HeroStats.healthTone(condition) : .neutral
        let background: Color = switch tone {
        case .healthy:   DSColor.healthy.opacity(0.18)
        case .neutral:   DSSurface.text2.opacity(0.18)
        case .attention: DSColor.attention.opacity(0.18)
        }
        let text: Color = switch tone {
        case .healthy:   Self.paleHealthy
        case .neutral:   DSSurface.text2
        case .attention: DSColor.attention
        }
        return Text(known ? condition : "Unknown")
            .font(.system(size: 11))
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(background, in: Capsule())
            .accessibilityLabel("Battery condition \(known ? condition : "Unknown")")
    }

    /// `DSColor.healthy` blended 40 % toward white — `Color.mix` is macOS 15+, so blend the NSColor.
    private static let paleHealthy = Color(nsColor: NSColor.systemGreen.blended(withFraction: 0.4, of: .white) ?? .systemGreen)

    // MARK: - half dial + capacity

    private func dialColumn(_ lt: BatteryLifetime?) -> some View {
        let fraction = HealthPageModel.healthFraction(raw_mAh: lt?.rawMaxCapacity_mAh, design_mAh: lt?.designCapacity_mAh)
        let pct = lt?.maxCapacityPercent
        return VStack(spacing: 0) {
            halfDial(fraction: fraction)
            VStack(spacing: 0) {
                Text(pct.map { "\($0)%" } ?? dash)
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DSSurface.text)
                Text(HealthPageModel.capacityText(raw_mAh: lt?.rawMaxCapacity_mAh, design_mAh: lt?.designCapacity_mAh) ?? dash)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(DSSurface.text2)
                    .lineLimit(1)
            }
            .padding(.top, -20)   // mock: margin-top:-20px — the numeral sits in the dial's mouth
        }
        .frame(width: Self.dialColumnWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pct.map { "Health \($0) percent" } ?? "Health unavailable")
    }

    /// 84 × 44 half ring: a 12 pt stroke on a 72 pt circle (outer edge 84, inner 60), the top half
    /// showing. Track = separator; fill = green for `fraction`.
    private func halfDial(fraction: Double?) -> some View {
        ZStack {
            Circle().trim(from: 0.5, to: 1)
                .stroke(DSSurface.line, style: StrokeStyle(lineWidth: Self.dialRing, lineCap: .butt))
            if let f = fraction {
                Circle().trim(from: 0.5, to: 0.5 + f / 2)
                    .stroke(DSColor.healthy, style: StrokeStyle(lineWidth: Self.dialRing, lineCap: .butt))
            }
        }
        .padding(Self.dialRing / 2)
        .frame(width: Self.dialSize, height: Self.dialSize)
        .frame(width: Self.dialSize, height: Self.dialSize / 2 + 2, alignment: .top)
        .clipped()
        .accessibilityHidden(true)
    }

    // MARK: - six use figures, two columns

    private struct Cell: Identifiable {
        let id: Int
        let label: String
        let value: String
        var tint: Color? = nil
        /// What VoiceOver reads for `value` when the printed form does not speak well ("12/14").
        var spoken: String? = nil
    }

    private func cells(_ lt: BatteryLifetime?) -> [Cell] {
        let f = figures
        let known = lt != nil
        func v(_ s: String?) -> String { known ? (s ?? dash) : dash }
        let lowCount = f?.lowDays.count ?? 0
        return [
            Cell(id: 0, label: "Cycles",   value: v(lt.map { "\($0.cycleCount)" })),
            Cell(id: 1, label: "Per week", value: v(HealthPageModel.perWeekText(f?.cyclesPerWeek))),
            Cell(id: 2, label: "At limit", value: v(f.map { HealthPageModel.hoursText($0.limitHoldHours) })),
            Cell(id: 3, label: "At 100%",  value: v(f.map { HealthPageModel.hoursText($0.atFullHours) }),
                 tint: (known && (f?.atFullHours ?? 0) > 0) ? DSColor.lowPower : nil),
            Cell(id: 4, label: "Low days", value: v(f.flatMap { HealthPageModel.lowDaysText($0.lowDays) }),
                 tint: (known && lowCount > 0) ? DSColor.critical : nil,
                 spoken: known ? f.flatMap { HealthPageModel.lowDaysSpoken($0.lowDays) } : nil),
            Cell(id: 5, label: "Deepest",  value: v(f.flatMap { HealthPageModel.deepestText($0.lowDays) })),
        ]
    }

    /// `.hg`: two EQUAL columns (`1fr 1fr`, `gap:4px 14px`) — two `maxWidth: .infinity` VStacks in an HStack,
    /// not a `Grid` (which sizes columns by content and starves the narrower one at 297 pt). The mock's
    /// hairline between stacked rows is kept: `.rowsm+.rowsm` = every cell but the first.
    private func figureGrid(_ lt: BatteryLifetime?) -> some View {
        let items = cells(lt)
        return HStack(alignment: .top, spacing: 14) {
            ForEach(0..<2, id: \.self) { col in
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { row in
                        figureCell(items[row * 2 + col], hairline: row > 0 || col > 0)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func figureCell(_ c: Cell, hairline: Bool) -> some View {
        // 297 pt page → ~90 pt columns. The FIGURE keeps its full width (layoutPriority + fixedSize); the label
        // may shrink a little (never truncate) so the row can never push the page past the frame. The gap
        // never collapses: `figureMinGap` (4 pt) is reserved first and the label takes what remains.
        // Low days reads N/M (spec 30 §16 row 32), widest "12/14" (32.6 pt at 11.5, monospaced digits):
        // "Low days" (50.5 pt) + 4 + 32.6 = 87.1 pt ≤ 90, so the label renders at full size. (As "12 of 14",
        // 46.7 pt, it needed 101.2 pt and shrank to ~0.77.) The shrink stays as the guard, not the plan.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(c.label).font(.system(size: Self.figureFont)).foregroundStyle(DSSurface.text2)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: Self.figureMinGap)
            Text(c.value).font(.system(size: Self.figureFont).monospacedDigit())
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(c.tint ?? DSSurface.text)
                .layoutPriority(1)
        }
        .padding(.vertical, Self.figureCellPad)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if hairline { Rectangle().fill(DSSurface.line).frame(height: 0.5) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.label) \(c.spoken ?? c.value)")
    }

    // MARK: - history note (spec 30 §16 "32 · Health · history note")

    /// One faint line under the figures while the history store needs attention — the figures above it
    /// are the ones a broken history file affects. The store's level signals come from its last
    /// maintenance run, so the note shows only while the state holds; the copy (and which cause wins when
    /// several hold) is `HealthPageModel.historyNoteText`. Wraps rather than truncates: a two-month note
    /// is longer than the page is wide.
    @ViewBuilder private var historyNote: some View {
        if let note = HealthPageModel.historyNoteText(for: history, now: fixtureNow ?? Date(), calendar: calendar) {
            Text(note)
                .font(.system(size: Self.noteFont))
                .foregroundStyle(DSSurface.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Self.noteGap)
        }
    }

    // MARK: - lifetime rows

    private func lifetimeCard(_ lt: BatteryLifetime?) -> some View {
        let f = figures
        let known = lt != nil
        func v(_ s: String?) -> String { known ? (s ?? dash) : dash }
        let rows: [(String, String)] = [
            ("Projected this year", v(HealthPageModel.projectedText(f?.cyclesPerWeek))),
            ("Last full charge", v(f.flatMap { HealthPageModel.lastFullChargeText($0.lastFullCharge, now: $0.now, calendar: calendar) })),
            ("Lifetime temperature", v(HealthPageModel.temperatureText(minC: lt?.lifetimeMinTempC, maxC: lt?.lifetimeMaxTempC,
                                                                       avgDeciC: lt?.lifetimeAvgTempDeciC))),
            ("Peak current", v(HealthPageModel.peakCurrentText(charge_mA: lt?.lifetimeMaxChargeCurrent_mA,
                                                               discharge_mA: lt?.lifetimeMaxDischargeCurrent_mA))),
            ("Pack voltage", v(HealthPageModel.packVoltageText(min_mV: lt?.lifetimeMinPackVoltage_mV,
                                                               max_mV: lt?.lifetimeMaxPackVoltage_mV))),
        ]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                lifetimeRow(key: row.0, value: row.1)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(DSSurface.line).frame(height: 0.5) }
                    }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background(DSSurface.card, in: RoundedRectangle(cornerRadius: DSMetric.radiusGroup + 2, style: .continuous))
    }

    /// `.rowsm` at the Health override: 12 pt, `padding:4px 0` (23 pt rows) — DSKV pads 3, so inline here.
    private func lifetimeRow(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: Self.lifetimeFont)).foregroundStyle(DSSurface.text2).lineLimit(1)
            Spacer(minLength: DSMetric.space2)
            Text(value).font(.system(size: Self.lifetimeFont).monospacedDigit()).foregroundStyle(DSSurface.text)
                .lineLimit(1)
        }
        .padding(.vertical, Self.lifetimeRowPad)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key) \(value)")
    }

    // MARK: - weekly-median capacity chart (R7 faint axis)

    /// The mock's 72 px SVG: three grid lines at `rgba(235,235,245,.10)`, 7.5–8 px labels at the left,
    /// the caption inset to the plot's `x="18"` origin.
    private func capacityChart(designCapacity: Int?) -> some View {
        let weeks = designCapacity == nil ? [] : (figures?.weeks ?? [])
        return VStack(alignment: .leading, spacing: 2) {
            Chart(weeks, id: \.weekStart) { w in
                LineMark(x: .value("Week", w.weekStart), y: .value("Capacity", w.pct))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .foregroundStyle(DSColor.healthy)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(DSSurface.text.opacity(0.10))
                    AxisValueLabel(anchor: .trailing) {
                        if let v = value.as(Int.self) {
                            Text("\(v)").font(.system(size: 8).monospacedDigit()).foregroundStyle(DSSurface.text3)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(maxWidth: .infinity)
            .frame(height: Self.chartPlotHeight)
            Text(HealthPageModel.chartCaption(weeks: weeks, calendar: calendar))
                .font(.system(size: 8)).foregroundStyle(DSSurface.text3)
                .lineLimit(1)
                .padding(.leading, Self.axisLabelWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HealthPageModel.chartSummary(weeks: weeks))
    }

    // MARK: - figures

    /// One pass over the store: every stored hour once (`lifetimeRows` — all aggregates + the raw rows of
    /// the hours they do not cover) + the health series → the §5 rows.
    private func loadFigures(designCapacity: Int?) {
        let nowDate = fixtureNow ?? Date()
        let now = Int(nowDate.timeIntervalSince1970)
        let (raw, agg) = history.lifetimeRows(now: now)   // app/History/HistoryReads.swift — shared with Now
        let health = history.healthSeries()
        figures = Figures(
            cyclesPerWeek: HistoryMetrics.cyclesPerWeek(health: health, now: now),
            limitHoldHours: HistoryMetrics.limitHoldHours(agg: agg, raw: raw),
            atFullHours: HistoryMetrics.atFullOnPowerHours(agg: agg, raw: raw, now: now, calendar: calendar,
                                                          days: Self.lowDaysWindow),
            lowDays: HistoryMetrics.lowDays(agg: agg, raw: raw, now: now, calendar: calendar, days: Self.lowDaysWindow),
            lastFullCharge: HistoryMetrics.lastFullCharge(raw: raw, agg: agg),
            weeks: designCapacity.map {
                HistoryMetrics.weeklyMedianCapacityPct(health: health, designCapacity_mAh: $0, calendar: calendar)
            } ?? [],
            now: nowDate)
    }
}
