import Foundation

// Sprint 3.7 (sleep/wake) — the pure command core for the THIRD privileged op (setRepeatingSleepWake,
// a `pmset repeat` write that programs macOS's native recurring power scheduler from explicit user
// config). Range-check + FIXED argv construction live here, fully unit-testable. The Process SPAWN is
// helper-only; the app passes only validated primitives over XPC. Injection is structurally impossible:
// `pmsetArguments` accepts ONLY a `ValidatedSleepWakeRequest` (which ONLY `validate` can mint), and every
// varying token is either a range-checked int rendered fixed-width or a letter from the fixed MTWRFSU
// set. The event types are hard-coded literals ("sleep","wakeorpoweron"); the op can NEVER emit
// shutdown/restart/bare-poweron. The neither-enabled request is a CANCEL.
public enum SleepWakeCommand {

    /// Reuse the one pmset-path source of truth (absolute, never PATH-resolved).
    public static var pmsetPath: String { EnergyModeCommand.pmsetPath }

    // Reply token contract. Success = "ok" (the app then reads `pmset -g sched` for display). The error
    // tokens are what the helper replies on reject/failure (surfaced honestly app-side).
    public static let ok                 = "ok"
    public static let errInvalidTime     = "error:invalid-time"
    public static let errInvalidDays     = "error:invalid-days"
    public static let errSleepEqualsWake = "error:sleep-equals-wake"
    public static let errSetFailed       = "error:set-failed"
    /// A submission within the cooldown of the last apply is REJECTED (a flood can't pile up root pmset
    /// spawns). Applies are deliberate user actions, never rapid — pure upside.
    public static let errCooldown        = "error:cooldown"

    /// Reject a new apply that starts within this of the previous apply's START (serial + cooldown).
    public static let applyCooldownMs = 250

    public static let minHour = 0, maxHour = 23
    public static let minMinute = 0, maxMinute = 59
    public static let minMask = 1, maxMask = 127   // 7-bit weekday field, at least one day set

    /// A request whose times/mask are PROVEN in range (or a CANCEL). The initializer is `fileprivate`,
    /// so the ONLY way to obtain one is `validate(...)` — `pmsetArguments` can never be handed an
    /// out-of-range value (structural injection/abuse defense, mirroring the other ops).
    public struct ValidatedSleepWakeRequest: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case schedule, cancel }
        public let kind: Kind
        public let sleepEnabled: Bool
        public let sleepHour: Int
        public let sleepMinute: Int
        public let wakeEnabled: Bool
        public let wakeHour: Int
        public let wakeMinute: Int
        public let weekdayMask: Int
        fileprivate init(kind: Kind, sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                         wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int) {
            self.kind = kind
            self.sleepEnabled = sleepEnabled; self.sleepHour = sleepHour; self.sleepMinute = sleepMinute
            self.wakeEnabled = wakeEnabled; self.wakeHour = wakeHour; self.wakeMinute = wakeMinute
            self.weekdayMask = weekdayMask
        }
    }

    /// VALIDATE raw primitives. Neither-enabled → a CANCEL (times/mask ignored). Otherwise each ENABLED
    /// side's hour ∈ [0,23] and minute ∈ [0,59], the mask ∈ [1,127], and (both enabled) the sleep time
    /// must differ from the wake time. Returns nil (REJECT) for anything else — BEFORE any argv exists.
    public static func validate(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                                wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int,
                                weekdayMask: Int) -> ValidatedSleepWakeRequest? {
        guard sleepEnabled || wakeEnabled else {
            return ValidatedSleepWakeRequest(kind: .cancel, sleepEnabled: false, sleepHour: 0,
                sleepMinute: 0, wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 0)
        }
        if sleepEnabled {
            guard (minHour...maxHour).contains(sleepHour),
                  (minMinute...maxMinute).contains(sleepMinute) else { return nil }
        }
        if wakeEnabled {
            guard (minHour...maxHour).contains(wakeHour),
                  (minMinute...maxMinute).contains(wakeMinute) else { return nil }
        }
        guard (minMask...maxMask).contains(weekdayMask) else { return nil }
        if sleepEnabled && wakeEnabled && sleepHour == wakeHour && sleepMinute == wakeMinute { return nil }
        return ValidatedSleepWakeRequest(kind: .schedule, sleepEnabled: sleepEnabled,
            sleepHour: sleepHour, sleepMinute: sleepMinute, wakeEnabled: wakeEnabled,
            wakeHour: wakeHour, wakeMinute: wakeMinute, weekdayMask: weekdayMask)
    }

    /// Which validation failure a raw input set represents — for the helper's reject token. Order mirrors
    /// validate(): time bounds first (per enabled side), then mask, then the sleep==wake clash.
    public static func rejectionToken(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                                      wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int,
                                      weekdayMask: Int) -> String {
        if sleepEnabled && (!(minHour...maxHour).contains(sleepHour) || !(minMinute...maxMinute).contains(sleepMinute)) {
            return errInvalidTime
        }
        if wakeEnabled && (!(minHour...maxHour).contains(wakeHour) || !(minMinute...maxMinute).contains(wakeMinute)) {
            return errInvalidTime
        }
        if (sleepEnabled || wakeEnabled) && !(minMask...maxMask).contains(weekdayMask) {
            return errInvalidDays
        }
        if sleepEnabled && wakeEnabled && sleepHour == wakeHour && sleepMinute == wakeMinute {
            return errSleepEqualsWake
        }
        return errInvalidTime
    }

    /// Map a validated weekday mask (bit0=Mon..bit6=Sun) to the pmset day-letter string MTWRFSU (set
    /// bits, in order). Always 1–7 letters from the fixed set (the mask is proven ∈ [1,127]).
    public static func weekdayLetters(_ mask: Int) -> String {
        let letters: [(Int, Character)] = [(0,"M"),(1,"T"),(2,"W"),(3,"R"),(4,"F"),(5,"S"),(6,"U")]
        return String(letters.compactMap { (bit, ch) in (mask & (1 << bit)) != 0 ? ch : nil })
    }

    /// Build the FIXED `pmset repeat` argv from a VALIDATED request. Every element is a literal except
    /// the days string (the fixed MTWRFSU set) and the times (HH:MM:00 from the range-checked ints).
    /// The event-type tokens "sleep"/"wakeorpoweron" are LITERALS; cancel is the three-literal form.
    public static func pmsetArguments(_ request: ValidatedSleepWakeRequest) -> [String] {
        if request.kind == .cancel { return [pmsetPath, "repeat", "cancel"] }
        let days = weekdayLetters(request.weekdayMask)
        func time(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d:00", h, m) }
        var argv = [pmsetPath, "repeat"]
        if request.sleepEnabled { argv += ["sleep", days, time(request.sleepHour, request.sleepMinute)] }
        if request.wakeEnabled  { argv += ["wakeorpoweron", days, time(request.wakeHour, request.wakeMinute)] }
        return argv
    }
}
