import Foundation
import Shared

/// Sprint 3.7 (sleep/wake) STAGE 2: the app-side schedule MODEL + the PURE read-back parser + the
/// single-owner authored-comparison. No I/O here (the Stage-2b controller supplies pmset spawning +
/// persistence); every function is a pure transform so the parsing and the comparison are exhaustively
/// unit-testable. The helper-side command core (validation + argv) is shared/SleepWakeCommand.swift;
/// this is the display / read-back / owner side only.
///
/// Wall-clock semantics: a time HH:mm means HH:mm wherever the Mac currently is. macOS/pmset own DST
/// (a non-existent spring-forward local time is skipped, a doubled fall-back hour may fire twice); we
/// program the picked wall-clock and DISCLOSE this, we do not correct it.

// MARK: - config model

/// The persisted sleep/wake schedule: an optional sleep time, an optional wake time, and the weekday
/// mask (bit0=Mon..bit6=Sun) shared by both. Mirrors the helper op's input shape (the controller passes
/// these primitives to setRepeatingSleepWake). Neither side enabled => applying is a CANCEL.
struct SleepWakeScheduleConfig: Codable, Equatable {
    var sleepEnabled: Bool = false
    var sleepHour: Int = 23
    var sleepMinute: Int = 0
    var wakeEnabled: Bool = false
    var wakeHour: Int = 7
    var wakeMinute: Int = 0
    var weekdayMask: Int = 31   // Mon-Fri default

    static let empty = SleepWakeScheduleConfig()

    /// Neither side enabled -> applying this is a CANCEL (the helper treats it so).
    var isCancel: Bool { !sleepEnabled && !wakeEnabled }

    /// In-range per the helper's validate() rules (the controller blocks Apply otherwise): any enabled
    /// time in [0,23]:[0,59], the mask in [1,127], and not both-enabled-at-the-same-time.
    var isValid: Bool {
        if isCancel { return true }
        if sleepEnabled, !((0...23).contains(sleepHour) && (0...59).contains(sleepMinute)) { return false }
        if wakeEnabled, !((0...23).contains(wakeHour) && (0...59).contains(wakeMinute)) { return false }
        guard (1...127).contains(weekdayMask) else { return false }
        if sleepEnabled && wakeEnabled && sleepHour == wakeHour && sleepMinute == wakeMinute { return false }
        return true
    }
}

/// Redman sweep item 3 — the schema-tolerant decoder (the SWEEP H2 pattern, `PauseCapture`). Every
/// property has a DEFAULT, but the synthesized `Decodable` still throws on a missing key, so the day one
/// field is added every stored config would read `.unreadable` on upgrade. In an EXTENSION so the
/// memberwise init every call site uses is kept.
///
/// WHAT STAYS REQUIRED: all seven fields — the struct is unchanged since it was
/// born (`ea354ca`) and the synthesized `encode` always wrote every one of them, so no stored config can
/// lack them. EVERY FIELD ADDED LATER must use `decodeIfPresent` with its default. Unknown keys are
/// ignored by `JSONDecoder`. The synthesized `encode(to:)` is kept; the round-trip and frozen-v1 tests in
/// `SleepWakeConfigUnreadableTests` are the tripwires.
extension SleepWakeScheduleConfig {
    enum CodingKeys: String, CodingKey {
        case sleepEnabled, sleepHour, sleepMinute, wakeEnabled, wakeHour, wakeMinute, weekdayMask
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version.
        self.sleepEnabled = try c.decode(Bool.self, forKey: .sleepEnabled)
        self.sleepHour = try c.decode(Int.self, forKey: .sleepHour)
        self.sleepMinute = try c.decode(Int.self, forKey: .sleepMinute)
        self.wakeEnabled = try c.decode(Bool.self, forKey: .wakeEnabled)
        self.wakeHour = try c.decode(Int.self, forKey: .wakeHour)
        self.wakeMinute = try c.decode(Int.self, forKey: .wakeMinute)
        self.weekdayMask = try c.decode(Int.self, forKey: .weekdayMask)
        // TOLERANT — EVERY FIELD ADDED LATER must be decoded with `decodeIfPresent` and a default.
    }
}

// MARK: - read-back model

/// One repeating power event as `pmset -g sched` DISPLAYS it (pmset-normalized: the type may read
/// "wakepoweron" for a wakeorpoweron we set, the days may read "weekdays only" for MTWRF, the time is
/// 12-hour). We keep a best-effort STRUCTURED form (minuteOfDay, mask); an unparseable field is nil so
/// the comparison treats the event as not-ours.
struct RepeatingPowerEvent: Equatable {
    enum Kind: Equatable { case sleep, wake, other(String) }
    let kind: Kind
    let minuteOfDay: Int?
    let weekdayMask: Int?
}

struct RepeatingSchedule: Equatable {
    let events: [RepeatingPowerEvent]
    static let none = RepeatingSchedule(events: [])
}

// MARK: - pure parser + authored comparison

enum SleepWakeReadback {

    /// Parse `pmset -g sched`. Read ONLY the "Repeating power events:" section; a "Scheduled power
    /// events:" header ends it (one-time events are a separate surface we never touch). Each event line
    /// is "<type> at <H:MMAM/PM> <day-spec>"; unrecognized lines are skipped, a recognized line with an
    /// unparseable time/day yields nil in that field.
    static func parse(_ output: String) -> RepeatingSchedule {
        var inRepeating = false
        var events: [RepeatingPowerEvent] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Repeating power events") { inRepeating = true; continue }
            if line.hasPrefix("Scheduled power events") { inRepeating = false; continue }
            guard inRepeating, !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4, parts[1] == "at" else { continue }
            events.append(RepeatingPowerEvent(kind: parseKind(parts[0]),
                                              minuteOfDay: parseTwelveHour(parts[2]),
                                              weekdayMask: parseDaySpec(parts[3])))
        }
        return RepeatingSchedule(events: events)
    }

    /// Only the exact displayed strings this app produces map to a known kind; anything else is .other
    /// (so the comparison treats it as foreign). pmset shows a wakeorpoweron we set as "wakepoweron".
    static func parseKind(_ s: String) -> RepeatingPowerEvent.Kind {
        switch s.lowercased() {
        case "sleep": return .sleep
        case "wakepoweron", "wakeorpoweron": return .wake
        default: return .other(s)
        }
    }

    /// "4:10PM" -> minutes since midnight (970). 12AM -> 0, 12PM -> 12. nil if unparseable.
    static func parseTwelveHour(_ s: String) -> Int? {
        let upper = s.uppercased()
        let isPM = upper.hasSuffix("PM"), isAM = upper.hasSuffix("AM")
        guard isPM || isAM else { return nil }
        let hm = upper.dropLast(2).split(separator: ":")
        guard hm.count == 2, var h = Int(hm[0]), let m = Int(hm[1]),
              (1...12).contains(h), (0...59).contains(m) else { return nil }
        if isPM && h != 12 { h += 12 }
        if isAM && h == 12 { h = 0 }
        return h * 60 + m
    }

    /// A day-spec -> the weekday mask (bit0=Mon..bit6=Sun). Handles pmset's normalized phrases and a raw
    /// MTWRFSU letter string. nil for anything unrecognized (the comparison then treats it as foreign).
    static func parseDaySpec(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "weekdays only": return 0b0011111   // MTWRF = 31
        case "weekends only": return 0b1100000   // SU = 96
        case "every day":     return 0b1111111   // 127
        default: break
        }
        let map: [Character: Int] = ["M":0,"T":1,"W":2,"R":3,"F":4,"S":5,"U":6]
        var mask = 0
        for ch in trimmed.uppercased() {
            guard let bit = map[ch] else { return nil }
            mask |= (1 << bit)
        }
        return mask == 0 ? nil : mask
    }

    /// Did THIS app author the repeating schedule now on the system (should-fix 5, single-owner-with-
    /// confirm)? Coarse + conservative: an empty system is vacuously ours (nothing to clobber); a
    /// non-empty system must match the config's expected events EXACTLY (same count, every field parsed,
    /// every event expected). Any mismatch / unparseable field / extra event -> false, so Apply/Cancel
    /// will CONFIRM before replacing a schedule we cannot positively recognize as our own (the safe bias).
    static func isAuthored(by config: SleepWakeScheduleConfig, matching readback: RepeatingSchedule) -> Bool {
        if readback.events.isEmpty { return true }
        var expected: [RepeatingPowerEvent] = []
        if !config.isCancel {
            if config.sleepEnabled {
                expected.append(RepeatingPowerEvent(kind: .sleep,
                    minuteOfDay: config.sleepHour * 60 + config.sleepMinute, weekdayMask: config.weekdayMask))
            }
            if config.wakeEnabled {
                expected.append(RepeatingPowerEvent(kind: .wake,
                    minuteOfDay: config.wakeHour * 60 + config.wakeMinute, weekdayMask: config.weekdayMask))
            }
        }
        guard readback.events.count == expected.count else { return false }
        var remaining = expected
        for ev in readback.events {
            guard ev.minuteOfDay != nil, ev.weekdayMask != nil,
                  let idx = remaining.firstIndex(of: ev) else { return false }
            remaining.remove(at: idx)
        }
        return remaining.isEmpty
    }

    /// The standing DST disclosure (should-fix 3), shown under the schedule controls in Stage 2b.
    static let dstDisclosure =
        "Times follow your Mac's clock. Around daylight-saving changes, a time that does not exist that day is skipped, and a repeated hour may fire twice."
}

// MARK: - reply-token classification (audit B8)

/// How to read the helper's reply token for a schedule apply / cancel. Pure, so the controller's
/// status mapping is unit-testable without the XPC seam.
enum SleepWakeReply {

    /// Does this `error:*` token mean "THIS call changed nothing" rather than "the operation failed"?
    ///
    /// The helper gates every apply behind a 250 ms cooldown (`beginApplyIfAllowed`) whose clock is
    /// SHARED with `setWakeBehavior`. So a second submission inside that window — a fast double-click,
    /// the confirm path re-issuing, or applying wake behaviour and the schedule back-to-back — is
    /// rejected with `error:cooldown` BEFORE any `pmset` runs. Nothing was attempted and nothing was
    /// changed: the outcome of the call that DID run still stands. Mapping this token to `.failed`
    /// tells the user "Schedule change failed" about a schedule that applied correctly, which is the
    /// exact inversion of the honest-failure contract the reply tokens exist to serve.
    ///
    /// Only the cooldown token qualifies. Every other `error:*` token (`invalid-time`, `invalid-days`,
    /// `sleep-equals-wake`, `set-failed`) is a real failure and must still surface as one.
    static func isNoChangeRejection(_ token: String) -> Bool {
        token == SleepWakeCommand.errCooldown
    }
}
