import Foundation

/// #30 §4.5 Health (H1): the pure strings behind `HealthPage`. Every formatter here returns `nil` (the
/// view prints "—") rather than a fabricated figure when a source is missing — §6 "a failed read never
/// becomes a figure". Host-app-free so `HealthPageModelTests` can pin the wording against the mockup
/// ("5,435 / 6,249 mAh", "9 → 46 °C · avg 26", "6.8 A in · 9.0 A out", "9.0 → 13.2 V", "12/14").
enum HealthPageModel {

    static let dash = "—"

    /// The mockup grid's `--f`: raw ÷ design, clamped to 0…1. nil unless both resolved (never 0 for a
    /// missing read — that would draw an empty dial as if the pack were dead).
    static func healthFraction(raw_mAh: Int?, design_mAh: Int?) -> Double? {
        guard let raw = raw_mAh, let design = design_mAh, design > 0 else { return nil }
        return min(1, max(0, Double(raw) / Double(design)))
    }

    /// "5,435 / 6,249 mAh" — grouped thousands, both figures required (same guard as `maxCapacityPercent`).
    static func capacityText(raw_mAh: Int?, design_mAh: Int?) -> String? {
        guard let raw = raw_mAh, let design = design_mAh, design > 0 else { return nil }
        return "\(grouped(raw)) / \(grouped(design)) mAh"
    }

    /// "8.6" — one decimal; nil (→ "—") when `HistoryMetrics.cyclesPerWeek` had < 14 days (§6).
    static func perWeekText(_ cyclesPerWeek: Double?) -> String? {
        cyclesPerWeek.map { String(format: "%.1f", $0) }
    }

    /// "≈ 450 cycles" — per-week × 52, rounded to whole cycles.
    static func projectedText(_ cyclesPerWeek: Double?) -> String? {
        cyclesPerWeek.map { "≈ \(grouped(Int(($0 * 52).rounded()))) cycles" }
    }

    /// "151 h" (awake hours, R14).
    static func hoursText(_ hours: Int) -> String { "\(grouped(hours)) h" }

    /// "12/14" — low days OF THE DAYS THAT HAVE READINGS (owner-decided: an unread day must not
    /// silently count as "not low"), so one read day reads "0/1". nil (→ "—") when nothing was read.
    /// N/M, not "N of M": spec 30 §16 row "32 · Health · Low days" (the owner, 2026-10-16, option B) — the
    /// shorter figure lets the label "Low days" keep its full size in its ~90 pt column.
    static func lowDaysText(_ l: HistoryMetrics.LowDays) -> String? {
        l.daysWithReadings > 0 ? "\(l.count)/\(l.daysWithReadings)" : nil
    }

    /// The same figure for VoiceOver: "12 of 14" (a slash is read aloud as "slash").
    static func lowDaysSpoken(_ l: HistoryMetrics.LowDays) -> String? {
        l.daysWithReadings > 0 ? "\(l.count) of \(l.daysWithReadings)" : nil
    }

    /// Spec 30 §16 "32 · Health · history note" (the owner, 2026-10-16, P3): the one-line note under the
    /// figures while the history store needs attention, or nil (no note). Fed by `HistoryStore`'s level
    /// signals from its last maintenance run, so it shows only while the state holds. Each sentence is
    /// said only of the cause it is true of:
    ///
    /// - `writeFailed` (`aggregateWriteFailed`: a month aggregate could not be WRITTEN, or
    ///   `rawWriteFailed`: a raw row could not be APPENDED and lives only in RAM — capped, lost on quit):
    ///   "History couldn't be saved — new readings may be lost until it can." (owner decision, review of
    ///   7c286c2: "readings are kept" was false on a full disk).
    /// - an unreadable month file (`unreadableAggregateMonths`) or raw day file (`unreadableRawDays`,
    ///   named by its month): a READ problem, kept as is, so "couldn't be read", never "couldn't be
    ///   saved": "History for September couldn't be read — it's kept as is." A month outside the LOCAL
    ///   calendar year of `now` carries its year ("September 2025"); a current-year month stays bare
    ///   (owner decision, review of 7c286c2). Two months are both named, oldest first, each as it needs
    ///   ("September and October", "December 2025 and January"); three or more are counted
    ///   ("History for 3 months …").
    ///
    /// - `folderUnreadable` (`historyFolderUnreadable`: the folder could not be LISTED, so no month is
    ///   known): "History couldn't be read — it's kept as is." It outranks named months (whatever was
    ///   named before may be stale).
    ///
    /// Precedence, when both hold: the failed write. It is the problem still growing (each day it lasts
    /// another raw day is kept uncompacted, and new history is at risk), where an unreadable file is a
    /// fixed condition; the note is one line, and the read note returns once the write recovers.
    static func historyNoteText(unreadableMonths: Set<String>, unreadableRawDays: Set<String>,
                                writeFailed: Bool, folderUnreadable: Bool = false,
                                now: Date, calendar: Calendar) -> String? {
        if writeFailed { return "History couldn\u{2019}t be saved \u{2014} new readings may be lost until it can." }
        if folderUnreadable { return "History couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is." }
        // A raw day "2026-09-03" belongs to month "2026-09"; a month named twice is one month.
        let months = (unreadableMonths.union(unreadableRawDays.map { String($0.prefix(7)) })).sorted()
        guard !months.isEmpty else { return nil }
        let year = calendar.component(.year, from: now)
        let names = months.map { monthName($0, currentYear: year) }
        let subject: String
        if names.count == 1, let only = names[0] {
            subject = only
        } else if names.count == 2, let a = names[0], let b = names[1] {
            subject = "\(a) and \(b)"
        } else {
            subject = "\(months.count) month\(months.count == 1 ? "" : "s")"
        }
        return "History for \(subject) couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is."
    }

    /// The note for the store's current signals — what the Health page shows. Both write failures drive
    /// the one "couldn't be saved" sentence, with the same precedence.
    @MainActor
    static func historyNoteText(for history: HistoryStore, now: Date, calendar: Calendar) -> String? {
        historyNoteText(unreadableMonths: history.unreadableAggregateMonths,
                        unreadableRawDays: history.unreadableRawDays,
                        writeFailed: history.aggregateWriteFailed || history.rawWriteFailed,
                        folderUnreadable: history.historyFolderUnreadable,
                        now: now, calendar: calendar)
    }

    /// "2026-09" → "September" in 2026, "September 2026" in any other year. nil for a key that is not a
    /// year-month.
    private static func monthName(_ key: String, currentYear: Int) -> String? {
        let p = key.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return nil }
        return y == currentYear ? monthNames[m - 1] : "\(monthNames[m - 1]) \(y)"
    }
    /// The page's copy is English (like every string here), so the month names are too — fixed, not
    /// the user's locale.
    private static let monthNames: [String] = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.standaloneMonthSymbols
    }()

    /// "1%" — the deepest day's minimum SoC. "none" when the window has readings and no day dipped to
    /// the threshold: that is a measured fact, so it must not wear the page's "—", which means "not
    /// read" in every other cell. nil (→ "—") only when nothing was read.
    static func deepestText(_ l: HistoryMetrics.LowDays) -> String? {
        guard l.daysWithReadings > 0 else { return nil }
        return l.deepest.map { "\($0)%" } ?? "none"
    }

    /// "today 23:10" / "yesterday 23:10" / "Sep 3" (older than yesterday, no time). nil when no full
    /// charge is on record.
    static func lastFullChargeText(_ date: Date?, now: Date, calendar cal: Calendar) -> String? {
        guard let date else { return nil }
        let time = DateFormatter()
        time.calendar = cal; time.timeZone = cal.timeZone; time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        if cal.isDate(date, inSameDayAs: now) { return "today \(time.string(from: date))" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) {
            return "yesterday \(time.string(from: date))"
        }
        let day = DateFormatter()
        day.calendar = cal; day.timeZone = cal.timeZone; day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "MMM d"
        return day.string(from: date)
    }

    /// "9 → 46 °C · avg 26" — §14-U6: avg = deci-°C ÷ 10, 0 dp. The range needs BOTH min and max (nil →
    /// "—", never a one-sided range); the average is optional (R15): "9 → 46 °C" when it is absent.
    static func temperatureText(minC: Int?, maxC: Int?, avgDeciC: Int?) -> String? {
        guard let mn = minC, let mx = maxC else { return nil }
        let range = "\(mn) → \(mx) °C"
        guard let avg = avgDeciC else { return range }
        return "\(range) · avg \(Int((Double(avg) / 10).rounded()))"
    }

    /// "6.8 A in · 9.0 A out" — discharge is reported negative by the gauge; shown as its magnitude.
    static func peakCurrentText(charge_mA: Int?, discharge_mA: Int?) -> String? {
        guard let c = charge_mA, let d = discharge_mA else { return nil }
        return "\(amps(abs(c))) A in · \(amps(abs(d))) A out"
    }

    /// "9.0 → 13.2 V".
    static func packVoltageText(min_mV: Int?, max_mV: Int?) -> String? {
        guard let mn = min_mV, let mx = max_mV else { return nil }
        return "\(amps(mn)) → \(amps(mx)) V"
    }

    /// "capacity % · weekly median · Jun → Sep" — first and last ISO-week months of the series; a
    /// single-month series reads "Sep"; an empty series reads "—".
    static func chartCaption(weeks: [HistoryMetrics.WeeklyCapacity], calendar cal: Calendar) -> String {
        let prefix = "capacity % · weekly median · "
        guard let first = weeks.first, let last = weeks.last else { return prefix + dash }
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        let a = f.string(from: first.weekStart), b = f.string(from: last.weekStart)
        return prefix + (a == b ? a : "\(a) → \(b)")
    }

    /// The chart's accessibility summary: "12 weeks, 87 to 88 percent" / "no capacity history".
    static func chartSummary(weeks: [HistoryMetrics.WeeklyCapacity]) -> String {
        guard let lo = weeks.map(\.pct).min(), let hi = weeks.map(\.pct).max() else {
            return "Capacity chart: no capacity history"
        }
        let l = Int(lo.rounded()), h = Int(hi.rounded())
        let range = l == h ? "\(l) percent" : "\(l) to \(h) percent"
        return "Capacity chart: \(weeks.count) week\(weeks.count == 1 ? "" : "s"), \(range)"
    }

    // MARK: - helpers

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// milli → one-decimal unit ("6800" → "6.8").
    private static func amps(_ milli: Int) -> String { String(format: "%.1f", Double(milli) / 1000) }
}
