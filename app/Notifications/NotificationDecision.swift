import Foundation

/// Sprint 4.4 (SPEC `02-SPEC-phase-44-notifications.md` sec 3): the PURE NOTIFY decision layer.
///
/// Everything that decides WHETHER to interrupt the user lives here as a total, side-effect-free
/// function. `NotificationManager` is the thin UNUserNotificationCenter glue; the coordinator is the
/// read-only observer that feeds this function. Keeping the logic pure is what makes the spine
/// (never-notify-for-your-own-action) and the cooldowns testable host-app-free (SPEC sec 6).

/// WHAT happened, abstracted from HOW it was observed. The associated values carry the numbers the
/// message needs (the limit being held, the value restored, the low-battery percentage).
enum NotificationKind: Equatable {
    case fullyCharged                  // on AC, at/near 100
    case limitReached(Int)             // holding at N%
    case topUpComplete(restored: Int)  // topped up to 100; limit restored to N%
    case scheduledApplied(Int)         // a schedule set the limit to N%
    case lowBattery(Int)               // on battery, low at N%
    case setupProblem                  // charge control needs attention
    /// #EI-4 / C4: the battery PACK crossed into `BatteryThermalState.hot` (42 °C). The Int is the
    /// reading, rounded for display. Edge-only — `BatteryHeatAlert` owns the latch + hysteresis, so
    /// this kind is constructed at most once per heat EPISODE, not once per hot sample.
    case hotBattery(Int)               // pack running hot at N °C
}

/// The PROXIMATE cause of the event — the spine of the whole feature (SPEC sec 3/6):
/// a purely user-initiated in-app action NEVER notifies; autonomous causes (a schedule firing, a
/// top-up revert completing, the hardware reaching full) DO. The coordinator derives this from the
/// existing `ChargeLimitEngine.lastCommandSource` (`.user` → `.userAction`; `.schedule`/`.topUp` →
/// `.autonomous`) and from telemetry-only outcomes (which are always autonomous).
enum NotificationCause: Equatable {
    case userAction
    case autonomous
}

/// One thing that happened, with its cause.
struct NotificationEvent: Equatable {
    let kind: NotificationKind
    let cause: NotificationCause
}

/// The toggleable event CATEGORIES, with no payload — the unit of the Settings toggles and the
/// persistence keys. `NotificationKind` carries the per-occurrence numbers (the limit, the SoC); the
/// type is what the user enables/disables. (Raw values double as the cooldown-ledger keys.)
enum NotificationEventType: String, CaseIterable, Equatable {
    case fullyCharged, limitReached, topUpComplete, scheduledApplied, lowBattery, setupProblem
    case hotBattery
}

extension NotificationKind {
    var type: NotificationEventType {
        switch self {
        case .fullyCharged:     return .fullyCharged
        case .limitReached:     return .limitReached
        case .topUpComplete:    return .topUpComplete
        case .scheduledApplied: return .scheduledApplied
        case .lowBattery:       return .lowBattery
        case .setupProblem:     return .setupProblem
        case .hotBattery:       return .hotBattery
        }
    }
}

extension NotificationPrefs {
    /// The per-event toggle for a category — the one place that maps a type to its stored bool.
    func isEnabled(_ type: NotificationEventType) -> Bool {
        switch type {
        case .fullyCharged:     return fullyCharged
        case .limitReached:     return limitReached
        case .topUpComplete:    return topUpComplete
        case .scheduledApplied: return scheduledApplied
        case .lowBattery:       return lowBattery
        case .setupProblem:     return setupProblem
        case .hotBattery:       return hotBattery
        }
    }
}

/// The master switch + per-event toggles. Defaults encode the SPEC sec 1/2 choices exactly.
struct NotificationPrefs: Equatable {
    var masterEnabled: Bool
    var fullyCharged: Bool
    var limitReached: Bool
    var topUpComplete: Bool
    var scheduledApplied: Bool
    var lowBattery: Bool
    var setupProblem: Bool
    /// #EI-4 / C4: the hot-pack alert. Default OFF (see `defaults`).
    var hotBattery: Bool
    /// The SoC (percent) at or below which the low-battery warning fires while discharging. Configurable
    /// preset (10/15/20/25/30); the increment default is 20 (warn earlier than the OS's own ~10% nag).
    var lowBatteryThreshold: Int

    /// SPEC defaults: master OFF (sec 1 — the app is useful silent; notifications are opt-in polish).
    /// Once the master is enabled the per-event defaults apply: fully-charged / top-up-complete /
    /// scheduled-applied / setup-problem ON; charge-limit-reached and low-battery OFF (sec 2).
    /// #EI-4 / C4 hot-battery is OFF for the same reason low-battery is: it is an occasional
    /// informational fact about the hardware, not a problem the user must be pulled away to fix, and
    /// the EI-4 spec's own posture is "calm awareness, never crying wolf". It is opt-in, and the
    /// popover Temperature row remains the always-available, non-interrupting surface.
    static let defaults = NotificationPrefs(
        masterEnabled: false,
        fullyCharged: true,
        limitReached: false,
        topUpComplete: true,
        scheduledApplied: true,
        lowBattery: false,
        setupProblem: true,
        hotBattery: false,
        lowBatteryThreshold: 20)
}

/// A pure description of a notification to post. Named `NotificationPlan` (not `Notification`) to
/// avoid colliding with `Foundation.Notification`. The stable `identifier` per kind lets the OS
/// replace a prior banner of the same kind rather than stacking duplicates.
struct NotificationPlan: Equatable {
    let identifier: String
    let title: String
    let body: String
    let threadIdentifier: String
}

enum NotificationDecision {

    /// Per-event-type cooldown (SPEC sec 3 "per-event-type cooldowns"). De-dupes a storm of identical
    /// samples (the 4.D debounce already tames the raw stream; this is the second guard). Fully-charged
    /// is additionally session-latched by the coordinator (the ledger entry is cleared when telemetry
    /// leaves the full episode), so within a charge session it fires exactly once regardless of cooldown.
    static func cooldown(for kind: NotificationKind) -> TimeInterval {
        switch kind {
        case .fullyCharged:     return 3600   // session-latched; this is only a within-episode backstop
        case .limitReached:     return 1800
        case .topUpComplete:    return 300
        case .scheduledApplied: return 300
        case .lowBattery:       return 1800
        case .setupProblem:     return 1800
        // Backstop only — `BatteryHeatAlert`'s latch already limits this to one ping per episode, and
        // the coordinator clears this ledger entry when the pack returns to normal. This bound exists
        // so that even a pathological read pattern cannot ping more than hourly.
        case .hotBattery:       return 3600
        }
    }

    /// Whether this event's per-event toggle is on.
    static func isEnabled(_ kind: NotificationKind, in prefs: NotificationPrefs) -> Bool {
        prefs.isEnabled(kind.type)
    }

    /// A coarse identity per kind for the cooldown ledger — every instance of a kind shares one key,
    /// so a kind notifies at most once per cooldown window.
    static func cooldownKey(for kind: NotificationKind) -> String {
        kind.type.rawValue
    }

    /// The user-facing copy (SPEC sec 2 wording).
    static func plan(for kind: NotificationKind) -> NotificationPlan {
        switch kind {
        case .fullyCharged:
            return NotificationPlan(identifier: cooldownKey(for: kind),
                title: "Fully charged",
                body: "Unplug to preserve battery health.",
                threadIdentifier: "charge")
        case .limitReached(let n):
            return NotificationPlan(identifier: cooldownKey(for: kind),
                title: "Charge limit reached",
                body: "Holding at \(n)% to protect your battery.",
                threadIdentifier: "charge")
        case .topUpComplete(let n):
            return NotificationPlan(identifier: cooldownKey(for: kind),
                title: "Top Up complete",
                body: "Topped up to 100% — limit restored to \(n)%.",
                threadIdentifier: "charge")
        case .scheduledApplied(let n):
            return NotificationPlan(identifier: cooldownKey(for: kind),
                title: "Scheduled limit applied",
                body: "Scheduled: limit set to \(n)%.",
                threadIdentifier: "schedule")
        case .lowBattery(let n):
            return NotificationPlan(identifier: cooldownKey(for: kind),
                title: "Battery low",
                body: "Battery low (\(n)%).",
                threadIdentifier: "battery")
        case .setupProblem:
            return NotificationPlan(identifier: cooldownKey(for: kind),
                title: "Charge control",
                body: "Charge control needs attention.",
                threadIdentifier: "setup")
        case .hotBattery(let c):
            // Honest and actionable: it names the reading, names the two ordinary causes, and names
            // the one thing the user can actually do. It does NOT ask for an action the app cannot
            // take on their behalf, and it does not imply damage (EI-4 sec 3's calm posture).
            return NotificationPlan(identifier: cooldownKey(for: kind),
                title: "Battery running hot",
                body: "Battery is at \(c) °C. Heavy load or a warm spot — easing off or moving to a "
                    + "cooler surface will help it come down.",
                threadIdentifier: "battery")
        }
    }

    /// THE decision (SPEC sec 3). Returns the plan to post, or nil to stay silent. Pure: the caller
    /// owns `lastNotified` (records `now` under `cooldownKey` after a non-nil result) and the OS owns
    /// DND/Focus — we never reimplement it.
    static func shouldNotify(event: NotificationEvent,
                             prefs: NotificationPrefs,
                             lastNotified: [String: Date],
                             now: Date) -> NotificationPlan? {
        guard prefs.masterEnabled else { return nil }            // master gate (sec 1)
        guard event.cause == .autonomous else { return nil }     // SPINE: never for a user action (sec 3)
        guard isEnabled(event.kind, in: prefs) else { return nil } // per-event toggle (sec 2)
        let key = cooldownKey(for: event.kind)
        if let last = lastNotified[key], now.timeIntervalSince(last) < cooldown(for: event.kind) {
            return nil                                           // de-dupe / cooldown (sec 3)
        }
        return plan(for: event.kind)
    }
}
