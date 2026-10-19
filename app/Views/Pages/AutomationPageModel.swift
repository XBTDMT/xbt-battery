import Foundation

/// #30 §4.7 · the Automation page's PURE bits — timeline geometry, row ordering + captions, the header
/// line, the "Limit now" provenance text and the editor's inline rejection copy. Foundation only (no
/// SwiftUI), so it compiles into `BatteryTests` host-app-free and every string the page shows is
/// assertable without a view. `AutomationPage` is the one consumer.
enum AutomationPageModel {

    // MARK: - header

    /// "next 18:00 → 95% · 4 of 4 rules" · "3 of 4 rules" (schedule off / nothing upcoming) · "no rules".
    static func headerLine(next: ChargeRule?, ruleCount: Int) -> String {
        let rules = ruleCount == 0 ? "no rules" : "\(ruleCount) of \(ChargeScheduleConfig.maxRules) rules"
        guard let next else { return rules }
        return "next \(next.timeLabel) → \(next.limit)% · \(rules)"
    }

    // MARK: - timeline (a 5 pt track for the local day; fractions are 0…1 across 00:00…24:00)

    struct Timeline: Equatable {
        /// Blue spans (sleep → wake), as [start, end] fractions. Two pieces when the span crosses midnight.
        var spans: [ClosedRange<Double>] = []
        /// "06:45 wake" above the track; nil when no wake is scheduled.
        var wake: (fraction: Double, label: String)?
        /// "23:30 sleep" below the track; nil when no sleep is scheduled.
        var sleep: (fraction: Double, label: String)?
        /// Green ticks + "07:30 → 100" labels, alternating below/above in rule order.
        var rules: [(fraction: Double, label: String)] = []
        /// The white "now HH:mm" tick.
        var now: (fraction: Double, label: String) = (0, "now 00:00")

        static func == (a: Timeline, b: Timeline) -> Bool {
            a.spans == b.spans && a.wake?.fraction == b.wake?.fraction && a.wake?.label == b.wake?.label
                && a.sleep?.fraction == b.sleep?.fraction && a.sleep?.label == b.sleep?.label
                && a.rules.map(\.fraction) == b.rules.map(\.fraction) && a.rules.map(\.label) == b.rules.map(\.label)
                && a.now.fraction == b.now.fraction && a.now.label == b.now.label
        }
    }

    static func fraction(minuteOfDay: Int) -> Double {
        Double(min(max(minuteOfDay, 0), 24 * 60)) / Double(24 * 60)
    }

    static func hhmm(_ minuteOfDay: Int) -> String {
        let m = min(max(minuteOfDay, 0), 24 * 60 - 1)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// The blue sleep→wake span(s). `sleep` and `wake` are minutes-of-day; either may be absent.
    /// sleep < wake ⇒ one span; sleep ≥ wake ⇒ [0, wake] + [sleep, 24 h]; one side only ⇒ that side's
    /// half (asleep before a wake, asleep after a sleep).
    static func spans(sleep: Int?, wake: Int?) -> [ClosedRange<Double>] {
        switch (sleep, wake) {
        case (nil, nil): return []
        case (nil, let w?): return w > 0 ? [0...fraction(minuteOfDay: w)] : []
        case (let s?, nil): return s < 24 * 60 ? [fraction(minuteOfDay: s)...1] : []
        case (let s?, let w?):
            if s < w { return [fraction(minuteOfDay: s)...fraction(minuteOfDay: w)] }
            var out: [ClosedRange<Double>] = []
            if w > 0 { out.append(0...fraction(minuteOfDay: w)) }
            if s < 24 * 60 { out.append(fraction(minuteOfDay: s)...1) }
            return out
        }
    }

    /// The whole timeline. `sleep`/`wake` are the minutes the page decided to draw (the live read-back
    /// when authored, else the config — the caller's choice, see `sleepWakeMinutes`).
    static func timeline(nowMinute: Int, sleep: Int?, wake: Int?, rules: [ChargeRule]) -> Timeline {
        var t = Timeline()
        t.spans = spans(sleep: sleep, wake: wake)
        if let wake { t.wake = (fraction(minuteOfDay: wake), "\(hhmm(wake)) wake") }
        if let sleep { t.sleep = (fraction(minuteOfDay: sleep), "\(hhmm(sleep)) sleep") }
        t.rules = rules.sorted { $0.minuteOfDay < $1.minuteOfDay }
            .map { (fraction(minuteOfDay: $0.minuteOfDay), "\($0.timeLabel) → \($0.limit)") }
        t.now = (fraction(minuteOfDay: nowMinute), "now \(hhmm(nowMinute))")
        return t
    }

    /// A candidate timeline label at a resolved x (points), on one side of the track. `priority`
    /// labels ("now") always draw and reserve their neighbourhood.
    struct TimelineLabel: Equatable {
        var text: String
        var x: Double
        var above: Bool
        var priority: Bool = false
    }

    /// R15 F5 collision rule: per side, in x order, a label draws only when it is ≥ `minGap` from the
    /// previous DRAWN label on that side and ≥ `minGap` from every priority label on that side; a
    /// priority label always draws. Returns one flag per input, in input order.
    static func drawnLabels(_ labels: [TimelineLabel], minGap: Double = 52) -> [Bool] {
        var out = [Bool](repeating: false, count: labels.count)
        for side in [true, false] {
            let idx = labels.indices.filter { labels[$0].above == side }.sorted { labels[$0].x < labels[$1].x }
            let reserved = idx.filter { labels[$0].priority }.map { labels[$0].x }
            var lastDrawn: Double?
            for i in idx {
                let x = labels[i].x
                if labels[i].priority {
                    out[i] = true; lastDrawn = x; continue
                }
                let clearOfLast = lastDrawn.map { x - $0 >= minGap } ?? true
                let clearOfPriority = reserved.allSatisfy { abs($0 - x) >= minGap }
                if clearOfLast && clearOfPriority { out[i] = true; lastDrawn = x }
            }
        }
        return out
    }

    /// §4.7: the blue span draws from `lastReadback` WHEN AUTHORED (the live pmset schedule matches
    /// our config), else from the config's enabled sides. A foreign or unread schedule never paints
    /// our config as if it were live.
    static func sleepWakeMinutes(config: SleepWakeScheduleConfig,
                                 readback: RepeatingSchedule?) -> (sleep: Int?, wake: Int?) {
        if let readback, !readback.events.isEmpty, SleepWakeReadback.isAuthored(by: config, matching: readback) {
            let sleep = readback.events.first { $0.kind == .sleep }?.minuteOfDay
            let wake = readback.events.first { $0.kind == .wake }?.minuteOfDay
            return (sleep, wake)
        }
        return (config.sleepEnabled ? config.sleepHour * 60 + config.sleepMinute : nil,
                config.wakeEnabled ? config.wakeHour * 60 + config.wakeMinute : nil)
    }

    // MARK: - rules card rows

    enum Row: Equatable, Identifiable {
        case wake(minuteOfDay: Int)
        case limit(ChargeRule)
        case sleep(minuteOfDay: Int)

        var id: String {
            switch self {
            case .wake: "wake"
            case .sleep: "sleep"
            case .limit(let r): r.id.uuidString
            }
        }
        var minuteOfDay: Int {
            switch self {
            case .wake(let m), .sleep(let m): m
            case .limit(let r): r.minuteOfDay
            }
        }
        var time: String {
            switch self {
            case .limit(let r): r.timeLabel
            default: hhmm(minuteOfDay)
            }
        }
        var title: String {
            switch self {
            case .wake: "Wake"
            case .sleep: "Sleep"
            case .limit(let r): "Limit → \(r.limit)%"
            }
        }
    }

    /// Rows sorted by time — wake · limit rules · sleep (the mock's order is purely chronological).
    static func rows(config: SleepWakeScheduleConfig, rules: [ChargeRule]) -> [Row] {
        var out: [Row] = rules.map { .limit($0) }
        if config.wakeEnabled { out.append(.wake(minuteOfDay: config.wakeHour * 60 + config.wakeMinute)) }
        if config.sleepEnabled { out.append(.sleep(minuteOfDay: config.sleepHour * 60 + config.sleepMinute)) }
        return out.sorted { a, b in
            if a.minuteOfDay != b.minuteOfDay { return a.minuteOfDay < b.minuteOfDay }
            return rank(a) < rank(b)
        }
    }
    private static func rank(_ r: Row) -> Int { switch r { case .wake: 0; case .limit: 1; case .sleep: 2 } }

    /// Limit-rule caption (without the chevron): "fired" when its latest occurrence is in the fired-set,
    /// "next" when it is the upcoming trigger, else empty. Fired wins (a rule can be both only across
    /// midnight, and "fired" is the fact about today).
    static func limitCaption(fired: Bool, isNext: Bool) -> String {
        if fired { return "fired" }
        if isNext { return "next" }
        return ""
    }

    /// Weekday-mask caption for the wake/sleep rows: "every day", "Mon–Fri", "weekends", else the
    /// selected day abbreviations ("Mon, Wed, Fri"). Bit 0 = Monday … bit 6 = Sunday.
    static func daysCaption(weekdayMask: Int) -> String {
        switch weekdayMask & 127 {
        case 127: return "every day"
        case 31: return "Mon–Fri"
        case 96: return "weekends"
        case 0: return "no days"
        default:
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            return (0..<7).filter { weekdayMask & (1 << $0) != 0 }.map { names[$0] }.joined(separator: ", ")
        }
    }

    // MARK: - closing card

    /// "80% · by schedule at 22:00" while the last command in THIS session came from the schedule
    /// (§14-C6: `lastCommandSource` is in-memory only), else "80% · set HH:mm" from the persisted custody
    /// stamp, else "80%" (a known limit with no custody), else "—".
    static func limitNowText(limit: Int?, source: CommandSource, operativeTime: String?,
                             custodyAt: Date?, calendar: Calendar = .current) -> String {
        guard let limit else { return "—" }
        if source == .schedule, let operativeTime { return "\(limit)% · by schedule at \(operativeTime)" }
        if let custodyAt {
            let c = calendar.dateComponents([.hour, .minute], from: custodyAt)
            return "\(limit)% · set \(hhmm((c.hour ?? 0) * 60 + (c.minute ?? 0)))"
        }
        return "\(limit)%"
    }

    /// "Auto · Low ≤20% · High plugged" / "Auto · Low ≤20%" / "Off" from the two opt-ins.
    static func energyRuleText(enabled: Bool, highWhenPlugged: Bool) -> String {
        guard enabled else { return "Off" }
        var s = "Auto · Low ≤\(AutoEnergyPolicy.lowEnterSoc)%"
        if highWhenPlugged { s += " · High plugged" }
        return s
    }

    /// The keep-awake presets the closing card offers, in the mock's order: "30 m · 1 h · 2 h · on power".
    static let keepAwakePresets: [(label: String, duration: KeepAwakeController.Duration)] = [
        ("30 m", .timed(1800)), ("1 h", .timed(3600)), ("2 h", .timed(7200)), ("on power", .whileOnAC),
    ]

    // MARK: - "Sleeps after" (spec 31 §2.3, G-1 / T1)

    /// The closing card's "Sleeps after" row: "battery 10 min · power never". Each side is how long the
    /// Mac sits idle on that power profile before it ACTUALLY idle-sleeps —
    /// `SleepTimers.effectiveSystemSleepMinutes`, i.e. max(sleep, displaysleep), "never" when either is 0 —
    /// not the raw `sleep` value, which on this Mac (battery `sleep 1`, `displaysleep 10`) would claim 1 min.
    ///
    /// A side whose system OR display timer is unread is "—": with the display unknown,
    /// `effectiveSystemSleepMinutes` falls back to the raw system value, which is exactly the wrong claim.
    /// Never read (nil) or both sides unread → "—" for the whole row. `help` carries the raw pmset values
    /// for the row's hover and VoiceOver ("battery: system 1 min, display 10 min · power: system never,
    /// display 20 min").
    static func sleepsAfterText(_ settings: SleepTimerSettings?) -> (text: String, help: String) {
        guard let settings else { return ("—", "Sleep timers not read yet") }
        let help = "battery: \(rawTimers(settings.battery)) · power: \(rawTimers(settings.charger))"
        let battery = effectiveSleep(settings.battery)
        let power = effectiveSleep(settings.charger)
        if battery == nil && power == nil { return ("—", help) }
        return ("battery \(battery ?? "—") · power \(power ?? "—")", help)
    }

    /// nil = unread (either timer missing); "never" = the profile never idle-sleeps; else "10 min".
    private static func effectiveSleep(_ t: SleepTimers) -> String? {
        guard t.systemMinutes != nil, t.displayMinutes != nil else { return nil }
        guard let minutes = t.effectiveSystemSleepMinutes else { return "never" }
        return KeepAwakeController.minutesLabel(minutes)
    }

    /// "system 1 min, display 10 min" — pmset's `0` is "never", an unread value "—".
    private static func rawTimers(_ t: SleepTimers) -> String {
        "system \(rawMinutes(t.systemMinutes)), display \(rawMinutes(t.displayMinutes))"
    }

    private static func rawMinutes(_ m: Int?) -> String {
        guard let m else { return "—" }
        return m == 0 ? "never" : KeepAwakeController.minutesLabel(m)
    }

    // MARK: - scroll cue (spec 31 §2.4, Q1)

    /// The page scrolls while an editor is open OR its measured content is taller than the frame. The
    /// 0.5 pt tolerance absorbs layout rounding (the same as `PageGate.clipTolerance`); a 0 height (not yet
    /// measured) never scrolls.
    static func canScroll(isEditing: Bool, contentHeight: CGFloat, viewport: CGFloat) -> Bool {
        isEditing || contentHeight > viewport + 0.5
    }

    /// True while content sits below the visible frame. `contentTop` is the content's minY in the scroll
    /// view's own coordinate space (0 at rest, negative once scrolled down). Drives the bottom fade.
    static func hasContentBelow(contentTop: CGFloat, contentHeight: CGFloat, viewport: CGFloat) -> Bool {
        contentTop + contentHeight > viewport + 0.5
    }

    // MARK: - editor rejections (§4.7: a `false` from addRule/updateRule is shown inline, never a silent no-op)

    /// Why `addRule` / `updateRule` would refuse `rule` against `config`. nil = it would be accepted.
    /// `configUnreadable` (final review F1): the edit normally moves an unreadable saved schedule aside
    /// and proceeds; if it was STILL refused, the reason is that, in plain words — never the generic line.
    static func rejectionMessage(config: ChargeScheduleConfig, rule: ChargeRule, isNew: Bool,
                                 configUnreadable: Bool = false) -> String? {
        if configUnreadable { return "your saved schedule couldn’t be read, so this wasn’t saved" }
        if config.rules.contains(where: { $0.id != rule.id && $0.minuteOfDay == rule.minuteOfDay }) {
            return "that time is taken"
        }
        if isNew, config.rules.count >= ChargeScheduleConfig.maxRules {
            return "four rules is the limit"
        }
        if !rule.isValid { return "that limit isn’t available" }
        return nil
    }

    /// A new rule at the first free common time (ported from Settings): addRule rejects duplicates, so
    /// the draft must not start on a taken minute.
    static func defaultNewRule(config: ChargeScheduleConfig) -> ChargeRule {
        let used = Set(config.rules.map { $0.minuteOfDay })
        for h in [22, 7, 8, 12, 0, 18] where !used.contains(h * 60) {
            return ChargeRule(hour: h, minute: 0, limit: h >= 6 && h < 18 ? 100 : 80)
        }
        for m in stride(from: 0, to: 24 * 60, by: 30) where !used.contains(m) {
            return ChargeRule(hour: m / 60, minute: m % 60, limit: 80)
        }
        return ChargeRule(hour: 23, minute: 0, limit: 80)
    }
}
