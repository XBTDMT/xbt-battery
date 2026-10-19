import Foundation

/// Sprint 4.2: the PURE view-model behind the history charts (SPEC sec 4) — host-app-free so it
/// unit-tests like the glyph/wattage layers. Transforms #28's stored series into plot-ready data:
/// range filter → downsample-for-pixels (cap ~200 pts, average within uniform time buckets so a
/// dense 30-day range neither lags nor lies) → on-AC/hold spans (REUSING each row's stored
/// `onAC`/`state` — never recompute classification). Dates are ABSOLUTE instants; the chart renders
/// them in TimeZone.current. Output is sorted by time → monotonic even across a DST/tz boundary.

enum ChargeRange: CaseIterable, Hashable {
    case h24, d7, d30
    var seconds: Int { switch self { case .h24: 86_400; case .d7: 604_800; case .d30: 2_592_000 } }
    var title: String { switch self { case .h24: "24H"; case .d7: "7D"; case .d30: "30D" } }
}

struct SoCPoint: Equatable { let date: Date; let soc: Double }
struct GraphSpan: Equatable { let start: Date; let end: Date }

struct ChargeSeries: Equatable {
    let points: [SoCPoint]
    let acSpans: [GraphSpan]       // on-AC intervals (from stored onAC) — the D6 chart's AC tint
    let holdSpans: [GraphSpan]     // state == "limitHold" — the D6 chart's limit-hold tint
    // #29 C1: `chargeSpans` (state == "charging") was DELETED, not re-homed. Its only consumer was the
    // excised pre-#29 HistoryGraphs chart, and a charging run is already the rising edge of the line —
    // a third background tint says nothing the plot does not. It was being computed on every Details
    // render and thrown away, which is the exact waste this pass exists to stop.
    let isEmpty: Bool              // < 2 points → "Not enough history yet"
}

enum GraphVM {
    private static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    static func charge(_ raw: [ChargePoint], range: ChargeRange, now: Int,
                       tz: TimeZone, maxPoints: Int = 200) -> ChargeSeries {
        let lo = now - range.seconds
        let inRange = raw.filter { $0.ts >= lo && $0.ts <= now }.sorted { $0.ts < $1.ts }
        let withSoC = inRange.filter { $0.soc != nil }
        guard withSoC.count >= 2 else {
            return ChargeSeries(points: [], acSpans: [], holdSpans: [], isEmpty: true)
        }
        return ChargeSeries(
            points: downsampleSoC(withSoC, lo: lo, hi: now, maxPoints: maxPoints),
            acSpans: spans(inRange) { $0.onAC },
            holdSpans: spans(inRange) { $0.state == "limitHold" },
            isEmpty: false)
    }

    // #30 stage 10: `health(_:range:now:tz:)` / `healthDomain` / `HealthRange` / `HealthSeries` were the
    // pre-#30 Details health-trend chart. The Health page plots the weekly-median capacity straight from
    // `HistoryStore.healthSeries()` through `HealthPageModel` (spec §4.5), so that cluster is deleted.

    // MARK: - downsample (uniform absolute-time buckets, averaged)

    private static func downsampleSoC(_ pts: [ChargePoint], lo: Int, hi: Int, maxPoints: Int) -> [SoCPoint] {
        let socPts = pts.compactMap { p in p.soc.map { (date(p.ts), Double($0)) } }
        guard socPts.count > maxPoints else { return socPts.map { SoCPoint(date: $0.0, soc: $0.1) } }
        return downsample(socPts, lo: lo, hi: hi, maxPoints: maxPoints) { $0.0 } value: { $0.1 }
            .map { SoCPoint(date: $0.0, soc: $0.1) }
    }

    /// Average value + timestamp within each of ≤maxPoints uniform buckets; returns sorted (date, avg).
    private static func downsample<T>(_ items: [T], lo: Int, hi: Int, maxPoints: Int,
                                      date: (T) -> Date, value: (T) -> Double) -> [(Date, Double)] {
        let span = max(1, hi - lo)
        let bucketW = max(1, span / maxPoints)
        var acc: [Int: (sumV: Double, sumT: Double, n: Int)] = [:]
        for item in items {
            let ts = Int(date(item).timeIntervalSince1970)
            let b = (ts - lo) / bucketW
            var a = acc[b] ?? (0, 0, 0)
            a.sumV += value(item); a.sumT += Double(ts); a.n += 1
            acc[b] = a
        }
        return acc.keys.sorted().map { k in
            let a = acc[k]!
            return (Date(timeIntervalSince1970: a.sumT / Double(a.n)), a.sumV / Double(a.n))
        }
    }

    // MARK: - spans (consecutive runs matching a predicate; from stored fields)

    private static func spans(_ pts: [ChargePoint], where pred: (ChargePoint) -> Bool) -> [GraphSpan] {
        var out: [GraphSpan] = []
        var startTs: Int?
        var lastTs = 0
        for p in pts {
            if pred(p) {
                if startTs == nil { startTs = p.ts }
                lastTs = p.ts
            } else if let s = startTs {
                out.append(GraphSpan(start: date(s), end: date(lastTs)))
                startTs = nil
            }
        }
        if let s = startTs { out.append(GraphSpan(start: date(s), end: date(lastTs))) }
        return out
    }
}
