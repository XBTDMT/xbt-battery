import Foundation

/// The store reads behind the Now and Health tabs' history figures. They live here, not in the views,
/// because `app/History` compiles into the host-app-free test target: the suite runs each tab's own
/// read against a real `HistoryStore` on disk, so the two tabs' lifetime figures can be held equal.
extension HistoryStore {
    /// Every stored hour EXACTLY ONCE — the rows behind every figure that spans more than the raw
    /// window (Health's §5 figures, Now's "N h at a limit since …"): all aggregates, plus the raw rows
    /// of the hours no aggregate covers, read from the oldest raw day file on disk
    /// (`HistoryMetrics.lifetimeRawFloor`), so a raw day that is not aggregated — not yet, or because its
    /// month could not be — is never missed. A raw day that IS aggregated (its file not yet deleted)
    /// contributes nothing here: its aggregate is the record of it.
    ///
    /// Was: Health read a fixed 7 × 24 h raw window (dropping the un-aggregated hours of the 7- and
    /// 8-day-old days) and Now read raw only from yesterday (dropping days 2–7, which are in no
    /// aggregate yet) — a render showed Now "133 h at a limit" beside Health "At limit 151 h".
    func lifetimeRows(now: Int) -> (raw: [ChargePoint], agg: [String: HourlyAggregate]) {
        let agg = allAggregates()
        let floor = HistoryMetrics.lifetimeRawFloor(
            now: now, oldestRawDay: oldestRawDayStart(),
            rawRetentionDays: Self.rawRetentionDays, horizonDays: Self.maxRawAgeDays)
        return (HistoryMetrics.unaggregated(raw: series(range: floor...now), agg: agg), agg)
    }
}

/// The Now page's two history figures (spec §5): today's account and the lifetime at-limit hours.
@MainActor
enum NowHistoryFigures {
    static func compute(history: HistoryStore, clock: Date, calendar cal: Calendar)
    -> (today: HistoryMetrics.TodayAccount, limitHoldHours: Int) {
        let now = Int(clock.timeIntervalSince1970)
        let dayStart = Int(cal.startOfDay(for: clock).timeIntervalSince1970)
        // The lifetime figure reads the SAME rows as the Health tab's "At limit" — one path, no drift.
        // Its aggregates are reused for today's account (one `allAggregates()` per recompute).
        let lifetime = history.lifetimeRows(now: now)
        // Yesterday's tail is needed for the first session edge's off-context and the strip's first run.
        let raw = history.series(range: (dayStart - 86_400)...now)
        return (HistoryMetrics.todayAccount(raw: raw, agg: lifetime.agg, now: now, calendar: cal),
                HistoryMetrics.limitHoldHours(agg: lifetime.agg, raw: lifetime.raw))
    }
}
