import Foundation

/// #30 stage 2 — the PURE metric layer behind the Now / Day / Health / Devices figures (spec §5, the XS
/// rows; red-team rulings §14 D1/D3/D4/D5/D9/D12/D13/D14/D15). No I/O, no clock: every function takes
/// the store's rows (`[ChargePoint]` raw, `[String: HourlyAggregate]` aggregates keyed by UTC hour
/// epoch, `[HealthPoint]`), an injected `now` and a `Calendar` whose `timeZone` defines "local".
///
/// Conventions carried from `HistoryStore`:
/// - `ChargePoint.ts` / aggregate keys are UTC epoch seconds; `watts` is signed, **negative =
///   discharging**.
/// - Rows arrive ≤ 1 / 60 s while awake plus transition rows, so a gap wider than `gapCap_s` (120 s) is
///   sleep: each row is "held" for `min(Δt to the next row, gapCap_s)` and the remainder of the gap is
///   the third, *asleep*, state — never counted as battery or power (§14-D5).
/// - Aggregates exist only for days older than 7 (`HistoryStore.runMaintenance`), so every figure that
///   spans more than the raw window stitches the raw days in via `HistoryStore.hourly()` (§14-D3). The
///   lifetime figures read their rows through ONE path, `HistoryStore.lifetimeRows(now:)`
///   (`HistoryReads.swift`), so the Now and Health tabs cannot disagree about them.
enum HistoryMetrics {
    /// §5: a row-to-row gap wider than this is asleep, not awake.
    static let gapCap_s = 120
    /// §5 "Charge sessions today": AC edges closer than this are one session (§14-D13).
    static let debounce_s = 120

    // MARK: - result types

    enum StripState: Sendable, Equatable { case battery, power, asleep, future }

    struct StripRun: Sendable, Equatable {
        let start: Date
        let end: Date
        let state: StripState
    }

    struct SoCAt: Sendable, Equatable {
        let soc: Int
        let ts: Date
    }

    /// §4.1 "Today strip" + its label row and the "Wh out · Wh in" / "low N % at HH:mm" lines.
    struct TodayAccount: Sendable, Equatable {
        let awakeOnBattery_s: Int
        let awakeOnPower_s: Int
        let whOut: Double
        let whIn: Double
        let lowest: SoCAt?
        let highest: SoCAt?
        let sessions: Int
        let strip: [StripRun]
    }

    /// One heatmap cell of the Day table (§4.3). `hasRows == false` renders hatched = asleep.
    struct HourCell: Sendable, Equatable {
        let start: Date
        let socAvg: Double?
        let onPower: Bool
        let hasRows: Bool
    }

    /// One local-day row of the Day table (§4.3). `whIsNet` is true when the day came from aggregates
    /// (beyond the raw window): then only the SIGNED net is known, and it is split by sign into
    /// `whOut` / `whIn` for rendering — the UI shows it as net (§5).
    struct DayRow: Sendable, Equatable {
        let date: Date              // local midnight
        let cells: [HourCell]       // 23 / 24 / 25 (DST)
        let whOut: Double
        let whIn: Double
        let whIsNet: Bool
        let avgW_onBattery: Double? // whOut ÷ awake hours on battery; nil when no awake battery time
        let awakeOnBattery_s: Int
        let isPartial: Bool
    }

    struct Session: Sendable, Equatable {
        let start: Date
        let end: Date               // last row of the on-AC run (== the last row seen when `ongoing`)
        let ongoing: Bool
    }

    struct LowDays: Sendable, Equatable {
        let count: Int
        let deepest: Int?
        let deepestDate: Date?      // local midnight of the deepest day
        /// Days in the window with at least one SoC reading. 0 = nothing was read, so `count == 0`
        /// is NOT a measured "no low day" (absence is not a fact).
        let daysWithReadings: Int
    }

    struct WeeklyCapacity: Sendable, Equatable {
        let weekStart: Date         // ISO week Monday, local midnight
        let pct: Double
    }

    // MARK: - primitives

    private static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    private static func epoch(_ d: Date) -> Int { Int(d.timeIntervalSince1970.rounded(.down)) }

    /// The pair walk every Δt figure shares: `(row, heldSeconds)` for each row except the last, where
    /// `heldSeconds = min(next.ts − row.ts, gapCap_s)`. The last row is held for nothing (no successor).
    private static func held(_ rows: [ChargePoint], gapCap_s: Int) -> [(row: ChargePoint, dt: Int)] {
        let sorted = rows.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return [] }
        return (0..<(sorted.count - 1)).map { i in
            (sorted[i], max(0, min(sorted[i + 1].ts - sorted[i].ts, gapCap_s)))
        }
    }

    /// §5 "Wh out / Wh in" (inside 7 days): integrate raw rows by Δt with gaps capped at `gapCap_s`,
    /// **split by sign per row** so a mixed charge/discharge hour never nets (§14-D1/D4).
    /// `out` = Σ |watts| · Δt / 3600 over rows with watts < 0; `in` likewise for watts > 0. Rows
    /// without watts contribute nothing.
    static func integrateWh(raw: [ChargePoint], gapCap_s: Int = gapCap_s) -> (out: Double, in: Double) {
        var out = 0.0, inn = 0.0
        for (row, dt) in held(raw, gapCap_s: gapCap_s) {
            guard let w = row.watts, dt > 0 else { continue }
            let wh = w * Double(dt) / 3600
            if wh < 0 { out -= wh } else { inn += wh }
        }
        return (out, inn)
    }

    /// §5 "Awake hours on battery / on power": Σ min(Δt, cap) split by `onAC`. Sleep (the capped
    /// remainder of a wide gap) is neither.
    static func awakeSeconds(raw: [ChargePoint], gapCap_s: Int = gapCap_s) -> (battery: Int, power: Int) {
        var b = 0, p = 0
        for (row, dt) in held(raw, gapCap_s: gapCap_s) { if row.onAC { p += dt } else { b += dt } }
        return (b, p)
    }

    /// `HistoryStore.hourly()`'s formula, field for field. Mirrored here because `HistoryStore` is
    /// `@MainActor` and this layer runs on a background task (§5); `HistoryMetricsTests` pins the two
    /// equal on a fixture hour so they cannot drift silently.
    static func hourly(_ rows: [ChargePoint]) -> HourlyAggregate {
        let socs = rows.compactMap { $0.soc }
        let watts = rows.compactMap { $0.watts }
        let acCount = rows.filter { $0.onAC }.count
        let states = Dictionary(grouping: rows, by: { $0.state }).mapValues { $0.count }
        let dominant = states.max { a, b in a.value < b.value }?.key ?? "unknown"
        return HourlyAggregate(
            socMin: socs.min(), socMax: socs.max(),
            socAvg: socs.isEmpty ? nil : Double(socs.reduce(0, +)) / Double(socs.count),
            wattsAvg: watts.isEmpty ? nil : (watts.reduce(0, +) / Double(watts.count)),
            acFraction: rows.isEmpty ? 0 : Double(acCount) / Double(rows.count),
            dominantState: dominant, count: rows.count)
    }

    /// §5 / §14-D3: the aggregates plus `hourly()` (== `HistoryStore.hourly()`) over the raw rows for
    /// every UTC hour the aggregates lack (aggregates win where both exist). Keys are UTC hour-start epochs.
    static func stitched(agg: [String: HourlyAggregate], raw: [ChargePoint]) -> [Int: HourlyAggregate] {
        var out: [Int: HourlyAggregate] = [:]
        for (k, v) in agg { if let h = Int(k) { out[h] = v } }
        let byHour = Dictionary(grouping: raw, by: { HistoryFormat.utcHourStart($0.ts) })
        for (h, rows) in byHour where out[h] == nil { out[h] = hourly(rows) }
        return out
    }

    /// The raw rows of the UTC hours the aggregates do NOT cover — the raw half of "every stored hour
    /// exactly once" (aggregates win per hour, as in `stitched`). Also drops the hourly points
    /// `HistoryStore.series` synthesizes from aggregates for raw-less days: their hours are aggregate keys.
    static func unaggregated(raw: [ChargePoint], agg: [String: HourlyAggregate]) -> [ChargePoint] {
        let aggregated = Set(agg.keys.compactMap { Int($0) })
        return raw.filter { !aggregated.contains(HistoryFormat.utcHourStart($0.ts)) }
    }

    /// Where a lifetime figure must start reading raw rows so that no raw day on disk is missed: the
    /// earlier of the retention edge and the OLDEST raw day file actually present
    /// (`HistoryStore.oldestRawDayStart`). Taken from the files, not inferred: maintenance can leave raw
    /// days past the retention edge (it runs at launch and then every 24 h of uptime), and a month that
    /// cannot be aggregated keeps its raw days on disk — older than newer, aggregated months. Reading
    /// from the oldest file is safe because `unaggregated` / `stitched` count each hour once whichever
    /// tier holds it. All UTC: the store's day files are UTC.
    ///
    /// `horizonDays` bounds the walk (`series` visits every day in the range): the store passes
    /// `HistoryStore.maxRawAgeDays`, the oldest a KEPT raw day can be, so a stray older file never turns
    /// this into a decades-long read.
    static func lifetimeRawFloor(now: Int, oldestRawDay: Int?, rawRetentionDays: Int, horizonDays: Int) -> Int {
        let today = HistoryFormat.utcDayStart(now)
        let retentionEdge = today - rawRetentionDays * 86_400
        let oldest = oldestRawDay.map(HistoryFormat.utcDayStart) ?? retentionEdge
        return max(min(retentionEdge, oldest), today - horizonDays * 86_400)
    }

    // MARK: - local-day helpers

    private static func dayStart(_ ts: Int, _ cal: Calendar) -> Date { cal.startOfDay(for: date(ts)) }
    private static func nextDay(_ d: Date, _ cal: Calendar) -> Date { cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400) }
    private static func rows(_ raw: [ChargePoint], in range: Range<Int>) -> [ChargePoint] {
        raw.filter { range.contains($0.ts) }.sorted { $0.ts < $1.ts }
    }

    /// Absolute hour starts covering the local day [`day`, next day): 24 normally, 23 on spring-forward,
    /// 25 on fall-back (§14-D14) — one cell per elapsed hour of the day, not per wall-clock label.
    static func hourStarts(ofDay day: Date, calendar cal: Calendar) -> [Date] {
        let end = nextDay(day, cal)
        var out: [Date] = []
        var h = day
        while h < end {
            out.append(h)
            guard let n = cal.date(byAdding: .hour, value: 1, to: h), n > h else { break }
            h = n
        }
        return out
    }

    /// The stitched hours overlapping an absolute hour cell [start, start + 3600). Whole-hour zones hit
    /// exactly one key; half-hour zones get their two overlapping UTC hours count-weighted.
    private static func cellFrom(_ st: [Int: HourlyAggregate], start: Int) -> HourCell {
        let hits = st.filter { $0.key < start + 3600 && $0.key + 3600 > start }.values.filter { $0.count > 0 }
        let n = hits.reduce(0) { $0 + $1.count }
        guard n > 0 else { return HourCell(start: date(start), socAvg: nil, onPower: false, hasRows: false) }
        let socHits = hits.filter { $0.socAvg != nil }
        let socN = socHits.reduce(0) { $0 + $1.count }
        let soc = socN > 0 ? socHits.reduce(0.0) { $0 + $1.socAvg! * Double($1.count) } / Double(socN) : nil
        let ac = hits.reduce(0.0) { $0 + $1.acFraction * Double($1.count) } / Double(n)
        return HourCell(start: date(start), socAvg: soc, onPower: ac >= 0.5, hasRows: true)
    }

    // MARK: - §5 Today

    /// §5 rows "Awake hours today", "Wh out / in (day)", "Lowest / highest today, and the time of the
    /// low" (argmin/argmax over today's raw rows, §14-D12; ties → earliest), "Today timeline strip"
    /// (raw `onAC` runs for the local day with asleep as the third state and `future` after `now`),
    /// "Charge sessions today" (off→on edges debounced ≥ 2 min, counted when the edge is today —
    /// the preceding-off context may lie in an earlier day, so pass all retained raw rows).
    static func todayAccount(raw: [ChargePoint], agg: [String: HourlyAggregate] = [:],
                             now: Int, calendar cal: Calendar,
                             gapCap_s: Int = gapCap_s) -> TodayAccount {
        let d0 = dayStart(now, cal), d1 = nextDay(d0, cal)
        let s0 = epoch(d0), s1 = epoch(d1)
        let today = rows(raw, in: s0..<s1)
        let awake = awakeSeconds(raw: today, gapCap_s: gapCap_s)
        let wh = integrateWh(raw: today, gapCap_s: gapCap_s)
        let withSoc = today.filter { $0.soc != nil }
        let low = withSoc.min { $0.soc! < $1.soc! || ($0.soc! == $1.soc! && $0.ts < $1.ts) }
        let high = withSoc.min { $0.soc! > $1.soc! || ($0.soc! == $1.soc! && $0.ts < $1.ts) }
        let sessions = chargeSessions(raw: raw).filter { (s0..<s1).contains(epoch($0.start)) }.count
        return TodayAccount(
            awakeOnBattery_s: awake.battery, awakeOnPower_s: awake.power,
            whOut: wh.out, whIn: wh.in,
            lowest: low.map { SoCAt(soc: $0.soc!, ts: date($0.ts)) },
            highest: high.map { SoCAt(soc: $0.soc!, ts: date($0.ts)) },
            sessions: sessions,
            strip: strip(today, dayStart: s0, dayEnd: s1, now: now, gapCap_s: gapCap_s))
    }

    /// The timeline strip: [dayStart, first row) asleep; each row held ≤ cap in its `onAC` state, the
    /// gap remainder asleep; after the last row its state holds ≤ cap then asleep until `now`; then
    /// `future` to the end of the day. Adjacent same-state runs merge.
    private static func strip(_ today: [ChargePoint], dayStart: Int, dayEnd: Int, now: Int,
                              gapCap_s: Int) -> [StripRun] {
        var segs: [(Int, Int, StripState)] = []
        func push(_ a: Int, _ b: Int, _ s: StripState) {
            guard b > a else { return }
            if let last = segs.last, last.2 == s, last.1 == a { segs[segs.count - 1].1 = b } else { segs.append((a, b, s)) }
        }
        let nowClamped = min(max(now, dayStart), dayEnd)
        var cursor = dayStart
        for (i, r) in today.enumerated() {
            let next = i + 1 < today.count ? today[i + 1].ts : nowClamped
            push(cursor, r.ts, .asleep)
            let holdEnd = min(next, r.ts + gapCap_s)
            push(r.ts, holdEnd, r.onAC ? .power : .battery)
            push(holdEnd, next, .asleep)
            cursor = next
        }
        push(cursor, nowClamped, .asleep)
        push(nowClamped, dayEnd, .future)
        return segs.map { StripRun(start: date($0.0), end: date($0.1), state: $0.2) }
    }

    // MARK: - §5 Day rows (§4.3 table)

    /// §4.3 / §5: one row per local day, oldest first, today last and `isPartial`. Days with neither raw
    /// rows nor aggregate hours are omitted (§6 "only the days that exist"). Cells come from the
    /// stitched hourly map re-bucketed UTC→local (23/24/25 per DST). Inside the raw window Wh / awake
    /// time are raw-row Δt integrals; a day with no raw rows falls back to aggregates:
    /// `whNet = Σ wattsAvg · min(count,60)/60` (shown as net, §14-D1) and
    /// `awakeOnBattery = Σ (1 − acFraction) · min(count,60)/60 · 3600`.
    static func dayRows(raw: [ChargePoint], agg: [String: HourlyAggregate], now: Int,
                        calendar cal: Calendar, days: Int = 7,
                        gapCap_s: Int = gapCap_s) -> [DayRow] {
        let st = stitched(agg: agg, raw: raw)
        let today = dayStart(now, cal)
        var out: [DayRow] = []
        for back in stride(from: days - 1, through: 0, by: -1) {
            guard let d0 = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let d1 = nextDay(d0, cal)
            let s0 = epoch(d0), s1 = epoch(d1)
            let starts = hourStarts(ofDay: d0, calendar: cal).map(epoch)
            let cells = starts.map { cellFrom(st, start: $0) }
            let dayRaw = rows(raw, in: s0..<s1)
            let hours = st.filter { $0.key >= s0 && $0.key < s1 }.values
            guard !dayRaw.isEmpty || hours.contains(where: { $0.count > 0 }) else { continue }
            let whOut: Double, whIn: Double, isNet: Bool, awakeB: Int
            if !dayRaw.isEmpty {
                let wh = integrateWh(raw: dayRaw, gapCap_s: gapCap_s)
                whOut = wh.out; whIn = wh.in; isNet = false
                awakeB = awakeSeconds(raw: dayRaw, gapCap_s: gapCap_s).battery
            } else {
                let net = hours.reduce(0.0) { $0 + ($1.wattsAvg ?? 0) * Double(min($1.count, 60)) / 60 }
                whOut = max(0, -net); whIn = max(0, net); isNet = true
                awakeB = Int((hours.reduce(0.0) { $0 + (1 - $1.acFraction) * Double(min($1.count, 60)) / 60 } * 3600).rounded())
            }
            out.append(DayRow(date: d0, cells: cells, whOut: whOut, whIn: whIn, whIsNet: isNet,
                              avgW_onBattery: awakeB > 0 ? whOut / (Double(awakeB) / 3600) : nil,
                              awakeOnBattery_s: awakeB, isPartial: s1 > now))
        }
        return out
    }

    /// §5 "Wh out / Wh in (week)": the sum over the day rows.
    static func weekWh(_ rows: [DayRow]) -> (out: Double, in: Double) {
        (rows.reduce(0) { $0 + $1.whOut }, rows.reduce(0) { $0 + $1.whIn })
    }

    // MARK: - §5 Health / limit figures

    /// §5 "At limit (awake hours)": count of stitched hours with `dominantState == "limitHold"`.
    static func limitHoldHours(agg: [String: HourlyAggregate], raw: [ChargePoint]) -> Int {
        stitched(agg: agg, raw: raw).values.filter { $0.dominantState == "limitHold" }.count
    }

    /// §5 "At 100 % on power (awake hours, 14 d)": stitched hours in the last `days` local days (today
    /// included) with `socMin == 100 && acFraction ≥ 0.5`. `socMin`, not `socMax`, so the arriving hour
    /// is excluded; dominant state is NOT consulted (`unknown` is the sitting-full state, §14-D9).
    static func atFullOnPowerHours(agg: [String: HourlyAggregate], raw: [ChargePoint], now: Int,
                                   calendar cal: Calendar, days: Int = 14) -> Int {
        let lo = epoch(cal.date(byAdding: .day, value: -(days - 1), to: dayStart(now, cal)) ?? dayStart(now, cal))
        return stitched(agg: agg, raw: raw)
            .filter { $0.key >= lo && $0.key <= now && $0.value.socMin == 100 && $0.value.acFraction >= 0.5 }
            .count
    }

    /// §5 "Days ≤ 20 %, deepest": per local day `min(socMin)` over the stitched hours of the last `days`
    /// days (today included); count of days ≤ 20 and the deepest one (earliest day on a tie).
    static func lowDays(agg: [String: HourlyAggregate], raw: [ChargePoint], now: Int,
                        calendar cal: Calendar, days: Int = 14, threshold: Int = 20) -> LowDays {
        let st = stitched(agg: agg, raw: raw)
        let today = dayStart(now, cal)
        var count = 0
        var withReadings = 0
        var deepest: (Int, Date)?
        for back in stride(from: days - 1, through: 0, by: -1) {
            guard let d0 = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let s0 = epoch(d0), s1 = epoch(nextDay(d0, cal))
            let mins = st.filter { $0.key >= s0 && $0.key < s1 }.values.compactMap(\.socMin)
            guard let m = mins.min() else { continue }
            withReadings += 1
            guard m <= threshold else { continue }
            count += 1
            if deepest == nil || m < deepest!.0 { deepest = (m, d0) }
        }
        return LowDays(count: count, deepest: deepest?.0, deepestDate: deepest?.1, daysWithReadings: withReadings)
    }

    /// §5 "Last full charge": the later of the last raw row with `soc == 100` and the last aggregate
    /// hour with `socMax == 100`. Neither tier is assumed newer: a raw day kept because its month could
    /// not be aggregated can be older than an aggregated day.
    static func lastFullCharge(raw: [ChargePoint], agg: [String: HourlyAggregate]) -> Date? {
        let rawTs = raw.filter({ $0.soc == 100 }).map(\.ts).max()
        let hour = agg.compactMap { k, v in v.socMax == 100 ? Int(k) : nil }.max()
        return [rawTs, hour].compactMap { $0 }.max().map(date)
    }

    /// §5 "Cycles per week": least-squares slope of `HealthPoint.cycles` over the last 90 days, in
    /// cycles/week. `nil` unless the points span ≥ 14 days (§6). "Per year" is this × 52.
    static func cyclesPerWeek(health: [HealthPoint], now: Int, windowDays: Int = 90,
                              minSpanDays: Int = 14) -> Double? {
        let lo = now - windowDays * 86_400
        let pts = health.filter { $0.ts >= lo && $0.ts <= now && $0.cycles != nil }
            .map { (x: Double($0.ts), y: Double($0.cycles!)) }
        guard pts.count >= 2, let first = pts.map(\.x).min(), let last = pts.map(\.x).max(),
              last - first >= Double(minSpanDays * 86_400) else { return nil }
        let n = Double(pts.count)
        let mx = pts.reduce(0) { $0 + $1.x } / n, my = pts.reduce(0) { $0 + $1.y } / n
        let sxx = pts.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        guard sxx > 0 else { return nil }
        let sxy = pts.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) }
        return sxy / sxx * 604_800
    }

    /// §5 "Weekly median capacity": median of `HealthPoint.maxCap_mAh` per ISO week ÷ the passed-in
    /// design capacity (from the live read, §14-D15), as percent, oldest week first. Weeks with no
    /// reading are simply absent. Empty when `designCapacity_mAh ≤ 0`.
    static func weeklyMedianCapacityPct(health: [HealthPoint], designCapacity_mAh: Int,
                                        calendar cal: Calendar) -> [WeeklyCapacity] {
        guard designCapacity_mAh > 0 else { return [] }
        var iso = Calendar(identifier: .iso8601); iso.timeZone = cal.timeZone
        var byWeek: [Date: [Int]] = [:]
        for p in health {
            guard let cap = p.maxCap_mAh else { continue }
            let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date(p.ts))
            guard let ws = iso.date(from: c) else { continue }
            byWeek[ws, default: []].append(cap)
        }
        return byWeek.keys.sorted().map { ws in
            let v = byWeek[ws]!.sorted()
            let med = v.count % 2 == 1 ? Double(v[v.count / 2]) : Double(v[v.count / 2 - 1] + v[v.count / 2]) / 2
            return WeeklyCapacity(weekStart: ws, pct: med / Double(designCapacity_mAh) * 100)
        }
    }

    // MARK: - §5 Devices / sessions

    /// §5 "Adapter fit" (§14-D2): Wh drained while on power in the last `days` — raw-row Δt integral
    /// (gaps capped) over rows with `onAC && watts < 0`.
    ///
    /// nil = UNKNOWN: the window holds no awake on-power time with a watts reading, so there is nothing
    /// to judge the adapter by. That must never collapse into a measured 0, which the Fit row prints as
    /// "kept up" (absence is not a fact).
    static func drainedOnPowerWh(raw: [ChargePoint], now: Int, days: Int = 7,
                                 gapCap_s: Int = gapCap_s) -> Double? {
        let lo = now - days * 86_400
        let window = raw.filter { $0.ts >= lo && $0.ts <= now }
        var measured_s = 0
        var drained = 0.0
        for h in held(window, gapCap_s: gapCap_s) where h.row.onAC {
            guard let w = h.row.watts, h.dt > 0 else { continue }
            measured_s += h.dt
            if w < 0 { drained -= w * Double(h.dt) / 3600 }
        }
        return measured_s > 0 ? drained : nil
    }

    /// §5 "Charge sessions": runs of `onAC` rows opened by an off→on edge, **debounced** — a run (on or
    /// off) shorter than `debounce_s` that sits between two runs of the other state is a glitch and is
    /// folded into its neighbours (§14-D13: edges 2 s apart occur). A run already on AC at the first
    /// row has no off→on edge and is not a session; the last run, if on AC, is `ongoing`.
    static func chargeSessions(raw: [ChargePoint], debounce_s: Int = debounce_s) -> [Session] {
        let sorted = raw.sorted { $0.ts < $1.ts }
        guard !sorted.isEmpty else { return [] }
        // runs: (firstTs, lastTs, onAC)
        var runs: [(first: Int, last: Int, onAC: Bool)] = []
        for r in sorted {
            if let l = runs.last, l.onAC == r.onAC { runs[runs.count - 1].last = r.ts }
            else { runs.append((r.ts, r.ts, r.onAC)) }
        }
        // Debounce interior runs (duration = next run's first − this run's first). Off-dropouts are
        // folded first, then on-blips, so an on→off→on flap keeps its FIRST edge as the session start.
        for foldState in [false, true] {
            var changed = true
            while changed {
                changed = false
                guard runs.count >= 3 else { break }
                for i in 1..<(runs.count - 1)
                where runs[i].onAC == foldState && runs[i + 1].first - runs[i].first < debounce_s {
                    runs[i - 1].last = runs[i + 1].last
                    runs.removeSubrange(i...(i + 1))
                    changed = true
                    break
                }
            }
        }
        var out: [Session] = []
        for (i, run) in runs.enumerated() where run.onAC && i > 0 {
            out.append(Session(start: date(run.first), end: date(run.last), ongoing: i == runs.count - 1))
        }
        return out
    }
}
