import Foundation
import CoreGraphics

/// #30 §4.4 · the Energy page's pure presentation logic (host-app-free, unit-tested). The view in
/// `EnergyPage.swift` renders what this returns and adds nothing of its own beyond layout — every
/// figure, share, caption and cue is decided here so it can be asserted without a host app.
enum EnergyPageModel {

    // MARK: - ranked rows

    /// One ranked "who spent it" row. `share` is the row's honest share of the SAMPLE's total (§14-D7:
    /// never relative to the top entry), in 0…1. `pid` is present for the 0.5 s snapshot (the live
    /// process); Sustained rows carry no pid (§14-B12) and resolve their icon by `bundleID`.
    struct RankedRow: Equatable, Identifiable {
        let id: String
        let name: String
        let pid: Int?
        let bundleID: String?
        let share: Double
    }

    /// How many ranked rows the card shows (the mock draws five).
    static let rowCap = 5

    /// Snapshot rows: share = `energyMillijoules / totalMillijoules` over every readable process in the
    /// sample. A zero / non-finite total makes every share 0 (never a divide-by-zero, never > 1).
    static func snapshotRows(_ apps: [EnergyImpactRow], totalMillijoules: Double) -> [RankedRow] {
        apps.prefix(rowCap).map { row in
            RankedRow(id: "pid:\(row.pid)", name: row.name, pid: row.pid, bundleID: nil,
                      share: share(row.energyMillijoules, of: totalMillijoules))
        }
    }

    /// Sustained rows: share = entry ÷ the helper's `all_tasks` total when it delivered one, else ÷ the
    /// sum of the entries we have (the honest denominator that is available).
    static func sustainedRows(_ apps: [SustainedEnergyEntry], total: Double?) -> [RankedRow] {
        let denominator: Double = {
            if let total, total.isFinite, total > 0 { return total }
            return apps.reduce(0) { $0 + $1.energyImpact }
        }()
        return apps.prefix(rowCap).map { e in
            RankedRow(id: "bundle:\(e.id)", name: e.name, pid: nil, bundleID: e.id,
                      share: share(e.energyImpact, of: denominator))
        }
    }

    static func share(_ value: Double, of total: Double) -> Double {
        guard total.isFinite, total > 0, value.isFinite, value > 0 else { return 0 }
        return min(1, value / total)
    }

    /// "38%" — whole percent, rounded. A share that rounds to 0 while being positive reads "<1%" so a
    /// listed row never claims to have spent nothing.
    static func percentText(_ share: Double) -> String {
        let pct = Int((share * 100).rounded())
        if pct == 0 && share > 0 { return "<1%" }
        return "\(pct)%"
    }

    // MARK: - header caption

    static let sampleCaption = "right now · your apps"
    static let sustainedCaption = "right now · everything"

    /// The caption under the header: the sample description plus the coverage note when the snapshot
    /// could not read every process (audit A4 — the note MUST render whenever it is non-nil).
    static func caption(sustainedSelected: Bool, coverageNote: String?) -> String {
        if sustainedSelected { return sustainedCaption }
        guard let coverageNote else { return sampleCaption }
        return sampleCaption + " · " + coverageNote
    }

    // MARK: - Power now

    /// A `key · value · faint` row for the "Power now" and "Keeping the Mac awake" lists.
    struct KVRow: Equatable {
        let key: String
        let value: String
        /// The faint tail, e.g. "· ≈ system" — nil when nothing is appended.
        let faint: String?
        /// True when the whole value is faint (the mock's "not connected · last …").
        var valueIsFaint = false
    }

    /// Pack: "27.8 W · 12.1 V × 2.30 A". Magnitude only (the pack row is a power figure, not a flow
    /// direction — the Now tab owns direction). "· ≈ system" appended ONLY on battery (§14-D6: on AC
    /// the pack figure is charge power, not the system's draw). nil inputs → "—".
    /// `fromChargeTrend` (#POPOVER-TREND): the current is the pack's measured inflow from the % climb, not a
    /// sample — say so, because the amps are derived. Pass the Draw row's figure (`HeroStats.drawMilliamps`)
    /// so this row never contradicts the Now page.
    static func packRow(voltageVolts: Double?, amperageMilliamps: Int?, onBattery: Bool,
                        fromChargeTrend: Bool = false) -> KVRow {
        guard let v = voltageVolts, v.isFinite, let mA = amperageMilliamps else {
            return KVRow(key: "Pack", value: "—", faint: nil)
        }
        let amps = Double(mA) / 1000
        let watts = abs(v * amps)
        let value = String(format: "%.1f W · %.1f V × %.2f A", watts, v, abs(amps))
        return KVRow(key: "Pack", value: value,
                     faint: onBattery ? "· ≈ system" : (fromChargeTrend ? "· from % climb" : nil))
    }

    /// B2: tidy a raw IOReport channel name for display ("GPU Energy" → "GPU"); unknown rails as-is.
    private static func railLabel(_ raw: String) -> String {
        switch raw {
        case "GPU Energy", "GPU": return "GPU"
        case "CPU Energy":        return "CPU"
        case "ANE":               return "ANE"
        case "DRAM":              return "DRAM"
        default:                  return raw
        }
    }

    /// The component-rail rows. Exactly ONE live rail → that rail with "· modeled · only live rail"
    /// (the mock's GPU line). Several → one row per rail, each "· modeled". None → a "GPU" row that
    /// says which empty it is: "measuring…" before the first sample pair, "no live rail" after.
    static func railRows(_ rails: [PowerRailReading], hasProbed: Bool) -> [KVRow] {
        if rails.isEmpty {
            return [KVRow(key: "GPU", value: "—", faint: hasProbed ? "· no live rail" : "· measuring…")]
        }
        if rails.count == 1, let r = rails.first {
            return [KVRow(key: railLabel(r.name), value: String(format: "%.1f W", r.watts),
                          faint: "· modeled · only live rail")]
        }
        return rails.map { KVRow(key: railLabel($0.name), value: String(format: "%.1f W", $0.watts), faint: "· modeled") }
    }

    /// Adapter: the live spec while connected; "not connected · last 94 W, 20 V rung" from the persisted
    /// record otherwise (or just "not connected" with no record); a failed read shows "—" + its reason.
    static func adapterRow(state: PowerAdapterReadState, last: LastAdapterRecord?) -> KVRow {
        switch state {
        case .connected(let a):
            return KVRow(key: "Adapter", value: a.specText, faint: nil)
        case .noAdapter:
            var text = "not connected"
            if let last {
                text += " · last \(last.watts) W"
                if let rung = last.rungVoltageText { text += ", \(rung)" }
            }
            return KVRow(key: "Adapter", value: text, faint: nil, valueIsFaint: true)
        case .unavailable(let why):
            return KVRow(key: "Adapter", value: "—", faint: "· \(why)")
        }
    }

    // MARK: - Keeping the Mac awake

    /// R15: the page fits the 361 pt frame at ZERO slack with the mock's content (five apps · Pack / GPU
    /// / Adapter · two holders), so holders are capped at 2 and the rest fold into "+N more"; a third
    /// holder is allowed only while there is a single component rail (the mock's GPU-only case).
    /// Flat cap of 2 (+N more): on device the single-rail 3-holder case overran the 361 pt frame (2026-09-09).
    static func holderCap(railCount: Int) -> Int { 2 }

    /// The holders shown (≤ `holderCap(railCount:)`) and how many are folded into "+N more".
    static func visibleHolders(_ holders: [KeepAwakeHolder], railCount: Int = 1) -> (shown: [KeepAwakeHolder], more: Int) {
        let cap = holderCap(railCount: railCount)
        return (Array(holders.prefix(cap)), max(0, holders.count - cap))
    }

    /// "pid 843 · 5 d 22 h" — the pid and the dwell since the oldest kept assertion; just "pid 843" when
    /// the record carried no `AssertStartWhen`.
    static func holderDetail(_ holder: KeepAwakeHolder, now: Date) -> String {
        guard let since = holder.heldSince else { return "pid \(holder.pid)" }
        return "pid \(holder.pid) · \(WhatsKeepingAwake.dwellText(since: since, now: now))"
    }

    /// The thin row under the holders (variant B): "+3 more system holders · none from your apps", or
    /// "+3 more · 1 from your apps" when some of the folded holders are GUI apps we could quit.
    static func moreText(_ more: Int, fromApps: Int = 0) -> String? {
        guard more > 0 else { return nil }
        return fromApps == 0 ? "+\(more) more system holders · none from your apps" : "+\(more) more · \(fromApps) from your apps"
    }

    /// Whether the 0.5 s snapshot must be (re)sampled when the page appears: nothing cached, or the
    /// cache is stale by the source's own rule (`stalenessNote` non-nil ⇒ ≥ 10 s old).
    static func snapshotNeedsFetch(isEmpty: Bool, stalenessNote: String?) -> Bool {
        isEmpty || stalenessNote != nil
    }

    // MARK: - height budget (R15 audit finding 1)

    /// The page's FIXED vertical budget, mirroring the view's constants and the mock's rhythm, so the fit
    /// against `DSMetric.pageHeight` can be asserted without a host app (the test target is logic-only).
    /// The view distributes its four blocks with three flexible spacers (owner ruling 2026-09-09 evening),
    /// each at least `minSpacer`; `estimatedHeight` includes those minimums, and anything under
    /// `frameHeight` is the slack the spacers share.
    /// Line heights are the SwiftUI system-font values at the sizes the view uses (14 → 17, 12.5 → 15,
    /// 12 → 14, 10 → 12). The view's `.clipped()` is the backstop for anything this misses.
    enum Layout {
        /// == `DSMetric.pageHeight` (the logic-only test target does not compile DSMetric; the view asserts
        /// the two agree in debug builds).
        static let frameHeight: CGFloat = 470
        static let header: CGFloat = 2 + 22 + 8          // DSPageHeader: 2 top · 22 pt strip · 8 bottom
        static let caption: CGFloat = 12 - 6 + 4          // 10 pt line, pulled up 6, 4 below
        static let rankedCardPadding: CGFloat = 2 + 2     // .card.list padding 2px 10px
        static let rankedRow: CGFloat = 22 + 2 * 8        // 22 pt icon · 8 pt padding (.pg .row padding 8px 0)
        static let rankedSeparator: CGFloat = 1
        static let emptyRanked: CGFloat = 14 + 2 * 6      // the "Sampling…" / no-apps line
        static let sectionLabelBlock: CGFloat = 14 + 3    // .sech.t margin 0 0 3 (the 8 above is a spacer's minimum)
        static let kvLine: CGFloat = 15                   // 12.5 pt
        static let kvRowGap: CGFloat = 7                  // .kv gap 7px 12px
        static let minSpacer: CGFloat = 10                // .pg .page gap 10px — three flexible spacers
        static let spacerCount = 3
        static let moreLine: CGFloat = 2 + 12             // "+N more", 10 pt, 2 pt above
    }

    /// Estimated page height for the given row counts (`holderRows` includes the empty-state line).
    static func estimatedHeight(rankedRows: Int, powerRows: Int, holderRows: Int, hasMore: Bool) -> CGFloat {
        var h = Layout.header + Layout.caption
        h += CGFloat(Layout.spacerCount) * Layout.minSpacer
        h += Layout.rankedCardPadding
        h += rankedRows == 0 ? Layout.emptyRanked
                             : CGFloat(rankedRows) * Layout.rankedRow + CGFloat(max(0, rankedRows - 1)) * Layout.rankedSeparator
        h += Layout.sectionLabelBlock + kvBlock(powerRows)
        h += Layout.sectionLabelBlock + kvBlock(holderRows)
        if hasMore { h += Layout.moreLine }
        return h
    }

    private static func kvBlock(_ rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * Layout.kvLine + CGFloat(rows - 1) * Layout.kvRowGap
    }
}
