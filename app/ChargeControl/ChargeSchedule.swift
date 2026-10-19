import Foundation

/// Sprint 4.C (#24): the charge-schedule MODEL + PURE trigger math (SPEC `02-SPEC-phase-4c`).
/// No I/O, no clocks of its own, no engine refs — every function is a pure transform over
/// (now, config, fired, currentLimit) so the whole trigger semantics is exhaustively unit-testable.
/// The runner (ScheduleRunner) supplies time/wake/persistence and the engine.
///
/// 4g thermostat-hold: a manual change is NOT a separate suppression. Once a trigger fires, its
/// occurrence is in the fired-set, so a later manual change cannot be re-fired over — it simply
/// HOLDS until the NEXT (different) occurrence fires and reasserts the schedule.
///
/// Wall-clock semantics: a rule at HH:mm means HH:mm wherever the Mac currently is — the caller
/// passes a `Calendar` carrying the live time zone, so DST and time-zone hops are the calendar's
/// job, not ours.

// MARK: - model

/// One daily rule: fire `limit` at `hour:minute` local, every day.
struct ChargeRule: Codable, Equatable, Identifiable {
    var id: UUID
    var hour: Int       // 0…23
    var minute: Int     // 0…59
    var limit: Int      // one of ChargeShortcuts.validLimitValues

    init(id: UUID = UUID(), hour: Int, minute: Int, limit: Int) {
        self.id = id; self.hour = hour; self.minute = minute; self.limit = limit
    }

    /// "HH:mm" for display.
    var timeLabel: String { String(format: "%02d:%02d", hour, minute) }
    /// Minutes-since-midnight — the within-day ordering / duplicate key.
    var minuteOfDay: Int { hour * 60 + minute }

    var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute) &&
            ChargeShortcuts.validLimitValues.contains(limit)
    }
}

/// The persisted schedule: master toggle, up to 4 rules, and whether the starter preset was
/// already offered (offered ONCE).
struct ChargeScheduleConfig: Codable, Equatable {
    var enabled: Bool = false
    var rules: [ChargeRule] = []
    var presetOffered: Bool = false

    static let maxRules = 4

    static let empty = ChargeScheduleConfig()

    /// SPEC sec 1 starter preset.
    static func starterPreset() -> [ChargeRule] {
        [ChargeRule(hour: 22, minute: 0, limit: 80),     // Night hold
         ChargeRule(hour: 7, minute: 30, limit: 100)]    // Morning top-up
    }

    /// Add a rule iff there's room AND no duplicate time (SPEC sec 1: duplicate times rejected).
    /// Returns false (no change) on rejection.
    @discardableResult
    mutating func addRule(_ rule: ChargeRule) -> Bool {
        guard rule.isValid, rules.count < Self.maxRules,
              !rules.contains(where: { $0.minuteOfDay == rule.minuteOfDay }) else { return false }
        rules.append(rule)
        rules.sort { $0.minuteOfDay < $1.minuteOfDay }
        return true
    }

    mutating func removeRule(id: UUID) { rules.removeAll { $0.id == id } }

    /// Edit a rule's time/limit, rejecting a duplicate time against the OTHER rules.
    @discardableResult
    mutating func updateRule(_ updated: ChargeRule) -> Bool {
        guard updated.isValid,
              !rules.contains(where: { $0.id != updated.id && $0.minuteOfDay == updated.minuteOfDay })
        else { return false }
        guard let i = rules.firstIndex(where: { $0.id == updated.id }) else { return false }
        rules[i] = updated
        rules.sort { $0.minuteOfDay < $1.minuteOfDay }
        return true
    }
}

/// Redman sweep item 1 — the schema-tolerant decoders for the persisted schedule (the SWEEP H2
/// pattern, `PauseCapture` in PauseResume.swift). Swift's SYNTHESIZED `Decodable` throws on a missing
/// key even when the property has a default, so the day either type gains one stored property, every
/// config the previous release saved stops decoding — and an unreadable config blocks every edit
/// (`ScheduleRunner.mutate`). A hand-written `init(from:)` in an EXTENSION (which keeps the memberwise
/// inits) forces a future field into this initializer, beside lines that all use `decodeIfPresent`.
///
/// WHAT STAYS REQUIRED: every field that exists today. The file history shows both structs unchanged
/// since they were born in `8daab05` (4.C), and the synthesized `encode` always writes non-optional
/// fields, so every blob any version ever saved carries all of them. A rule missing one is not a lenient
/// rule; it is unreadable, and the whole config with it — PRESERVED by the runner, never silently
/// shortened. Unknown keys are ignored by `JSONDecoder`. The synthesized `encode(to:)` is kept; the
/// round-trip and frozen-v1 tests in `ScheduleConfigUnreadableTests` are the tripwires.
extension ChargeRule {
    enum CodingKeys: String, CodingKey { case id, hour, minute, limit }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version.
        self.id = try c.decode(UUID.self, forKey: .id)
        self.hour = try c.decode(Int.self, forKey: .hour)
        self.minute = try c.decode(Int.self, forKey: .minute)
        self.limit = try c.decode(Int.self, forKey: .limit)
        // TOLERANT — EVERY FIELD ADDED LATER must be decoded with `decodeIfPresent` and a default.
    }
}

extension ChargeScheduleConfig {
    enum CodingKeys: String, CodingKey { case enabled, rules, presetOffered }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version.
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.rules = try c.decode([ChargeRule].self, forKey: .rules)
        self.presetOffered = try c.decode(Bool.self, forKey: .presetOffered)
        // TOLERANT — EVERY FIELD ADDED LATER must be decoded with `decodeIfPresent` and a default.
    }
}

/// Idempotence record: a (rule, occurrence-local-date) pair has fired. The double-fire guard for
/// clock jumps / recomputes (NOT timer discipline — sec 7).
struct FiredOccurrence: Codable, Hashable {
    let ruleID: UUID
    let dayKey: String   // the occurrence's OWN local date, yyyy-MM-dd
}

/// Redman sweep item 2 — the schema-tolerant decoder for one fired record (the SWEEP H2 pattern). Both
/// fields are required (unchanged since `8daab05`, always written). EVERY FIELD ADDED LATER must use
/// `decodeIfPresent`. The SET is decoded element by element (`UserDefaultsScheduleStore`), so one record
/// that fails this initializer costs that record, not the whole set.
extension FiredOccurrence {
    enum CodingKeys: String, CodingKey { case ruleID, dayKey }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version.
        self.ruleID = try c.decode(UUID.self, forKey: .ruleID)
        self.dayKey = try c.decode(String.self, forKey: .dayKey)
        // TOLERANT — EVERY FIELD ADDED LATER must be decoded with `decodeIfPresent` and a default.
    }
}

/// The pure decision.
enum ScheduleAction: Equatable {
    case none
    case fire(rule: ChargeRule, occurrenceDayKey: String)
}

// MARK: - pure trigger math

enum ChargeSchedule {

    /// The most recent occurrence of `rule` at or before `now` (always within 24 h for a daily
    /// rule — yesterday's or today's HH:mm). nil only if the calendar can't resolve it.
    static func mostRecentOccurrence(of rule: ChargeRule, atOrBefore now: Date,
                                     calendar: Calendar) -> Date? {
        let comps = DateComponents(hour: rule.hour, minute: rule.minute, second: 0)
        // Search backward from just-after-now so an exact-now match counts as "at or before".
        return calendar.nextDate(after: now.addingTimeInterval(1), matching: comps,
                                 matchingPolicy: .nextTime, direction: .backward)
    }

    /// The next occurrence strictly after `now`.
    static func nextOccurrence(of rule: ChargeRule, after now: Date, calendar: Calendar) -> Date? {
        let comps = DateComponents(hour: rule.hour, minute: rule.minute, second: 0)
        return calendar.nextDate(after: now, matching: comps,
                                 matchingPolicy: .nextTime, direction: .forward)
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The OPERATIVE occurrence: the single most-recent occurrence across ALL rules (circular daily
    /// cycle, backward ≤24 h, crossing midnight). nil when disabled / no rules / unresolvable. Shared
    /// by nextAction (DRY) and the runner's Resume + divergence query.
    static func operativeOccurrence(now: Date, calendar: Calendar,
                                    config: ChargeScheduleConfig) -> (rule: ChargeRule, date: Date)? {
        guard config.enabled, !config.rules.isEmpty else { return nil }
        var op: (rule: ChargeRule, date: Date)?
        for rule in config.rules {
            guard let occ = mostRecentOccurrence(of: rule, atOrBefore: now, calendar: calendar) else { continue }
            if op == nil || occ > op!.date { op = (rule, occ) }
        }
        return op
    }

    /// THE decision (SPEC sec 2 / 4g sec 2). Fires the operative occurrence iff its value differs and
    /// it is not already fired. Older missed occurrences are SUPERSEDED, never replayed. (4g: the
    /// manual-override skip is gone — a fired occurrence already produces a HOLD via the fired-set, so
    /// a later manual change holds until the NEXT, not-yet-fired occurrence fires and reasserts.)
    static func nextAction(now: Date, calendar: Calendar, config: ChargeScheduleConfig,
                           fired: Set<FiredOccurrence>, currentLimit: Int?) -> ScheduleAction {
        guard let operative = operativeOccurrence(now: now, calendar: calendar, config: config) else { return .none }
        let key = dayKey(for: operative.date, calendar: calendar)
        // already fired this occurrence?
        if fired.contains(FiredOccurrence(ruleID: operative.rule.id, dayKey: key)) { return .none }
        // value already satisfied → nothing to do (and the older intent is superseded).
        if let currentLimit, currentLimit == operative.rule.limit { return .none }
        return .fire(rule: operative.rule, occurrenceDayKey: key)
    }

    /// The NEXT chronological trigger strictly after `now` — backs the "Next:" UI line (the standing
    /// disclosure of the next reassertion). nil if no rules / unresolvable.
    static func nextTrigger(after now: Date, calendar: Calendar,
                            config: ChargeScheduleConfig) -> (rule: ChargeRule, date: Date)? {
        guard !config.rules.isEmpty else { return nil }
        var best: (rule: ChargeRule, date: Date)?
        for rule in config.rules {
            guard let occ = nextOccurrence(of: rule, after: now, calendar: calendar) else { continue }
            if best == nil || occ < best!.date { best = (rule, occ) }
        }
        return best
    }

    /// The "Next: HH:mm → N%" UI line: the next FUTURE trigger (what the user will see happen next).
    static func upcomingLine(now: Date, calendar: Calendar,
                             config: ChargeScheduleConfig) -> (rule: ChargeRule, date: Date)? {
        guard config.enabled else { return nil }
        return nextTrigger(after: now, calendar: calendar, config: config)
    }
}
