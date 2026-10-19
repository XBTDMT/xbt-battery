import Foundation

/// Sprint 4.4: PURE derivation of `NotificationEvent`s from the app's existing, already-published
/// truth — telemetry classification (`TelemetryChargeState`), the engine's `lastCommandSource`,
/// the top-up phase, and the command status. Notifications OBSERVE these outcomes read-only; nothing
/// here drives or gates the engine (SPEC sec 0). Each function is total and host-app-free so the
/// spine (cause assignment) is fully tested without a running app.
///
/// Degraded mode (SPEC sec 4): these inputs ARE the same behavioral truth the UI rides — a scheduled
/// apply still fires (we issued it), a limit-hold rides the classifier's hold detection, fully-charged
/// rides the display proxy. No event asserts a fact the app cannot stand behind.
enum NotificationEvents {

    /// Fully charged: mirrors `ChargeStatusStrings.composedTelemetryLabel`'s proxy — on AC, the
    /// classifier idle (`.unknown`, i.e. not actively charging/holding), and SoC ≥ 99. The frozen
    /// `ChargeStateMachine` is untouched; this reuses its published `.unknown` exactly as the glyph/
    /// popover do. Always autonomous (the hardware reached full; the user didn't "do" it).
    static func fullyCharged(onAC: Bool, soc: Int?, state: TelemetryChargeState) -> NotificationEvent? {
        guard onAC, state == .unknown, let soc, soc >= 99 else { return nil }
        return NotificationEvent(kind: .fullyCharged, cause: .autonomous)
    }

    /// Limit reached: telemetry entered `.limitHold` at a known limit. Cause follows WHO set that
    /// limit — `.user` → a user action (no ping, per the spine); `.schedule`/`.topUp` → autonomous.
    static func limitReached(entered state: TelemetryChargeState, limit: Int?,
                             source: CommandSource) -> NotificationEvent? {
        guard state == .limitHold, let limit else { return nil }
        return NotificationEvent(kind: .limitReached(limit), cause: cause(of: source))
    }

    /// Top-up complete: ONLY a `.topUp` revert that actually REACHED 100%. The act of tapping Top Up
    /// is user-initiated, but its autonomous full-completion revert is what's worth surfacing.
    /// `reachedFull` is required because the SAME `.topUp` revert leg also runs on unplug-abort,
    /// TTL-timeout, and user-cancel (TopUpController.revert is the single restore path for all four) —
    /// firing "Topped up to 100%" on those would assert a fact the app cannot stand behind (SPEC
    /// sec 4 honesty). `source == .topUp` is necessary but NOT sufficient; the climb must have hit
    /// full. `restoredLimit` is the limit now back in force.
    static func topUpComplete(source: CommandSource, restoredLimit: Int?,
                              reachedFull: Bool) -> NotificationEvent? {
        guard source == .topUp, reachedFull, let restoredLimit else { return nil }
        return NotificationEvent(kind: .topUpComplete(restored: restoredLimit), cause: .autonomous)
    }

    /// Scheduled applied: a limit change whose source is `.schedule` — a schedule firing is autonomous
    /// and the user should know it happened (SPEC sec 2, default ON). A user/top-up change is NOT this.
    static func scheduledApplied(source: CommandSource, limit: Int?) -> NotificationEvent? {
        guard source == .schedule, let limit else { return nil }
        return NotificationEvent(kind: .scheduledApplied(limit), cause: .autonomous)
    }

    /// Low battery: on battery (`.discharging`) at or below a configurable `threshold` percent (SPEC
    /// sec 2 increment, default 20; the per-event toggle stays default OFF). Always autonomous.
    static func lowBattery(state: TelemetryChargeState, soc: Int?, threshold: Int) -> NotificationEvent? {
        guard state == .discharging, let soc, soc <= threshold else { return nil }
        return NotificationEvent(kind: .lowBattery(soc), cause: .autonomous)
    }

    /// Setup / automation problem (SPEC sec 2): a charge control that is broken or unconfigured — the
    /// one error-class notification. Fires for `.setupRequired` and the broken-control error causes
    /// (automation blocked, Shortcuts binary absent, launch failed). It does NOT fire for transient,
    /// command-specific outcomes (a single mismatch, a one-off telemetry read failure) — those are not
    /// "the control is broken", and surfacing them would be the chatty over-notification the SPEC avoids.
    static func setupProblem(status: CommandStatus) -> NotificationEvent? {
        switch status {
        case .setupRequired:
            return NotificationEvent(kind: .setupProblem, cause: .autonomous)
        case .error(let cause):
            switch cause {
            case .automationBlocked, .shortcutsBinaryAbsent, .launchFailed:
                return NotificationEvent(kind: .setupProblem, cause: .autonomous)
            case .nonzeroExit, .getOutputUnparseable, .limitMismatchAfterSet, .telemetryReadFailure:
                return nil
            }
        default:
            return nil
        }
    }

    /// #EI-4 / C4 hot pack. Deliberately thin: ALL of the judgement — the three-state handling, the
    /// 42/37 hysteresis band, the once-per-episode latch — lives in the pure `BatteryHeatAlert`, so
    /// this function only translates its RISING edge into an event. `.rearm` and `.silent` produce
    /// nothing: a pack cooling down is not worth an interruption, and "we could not read the
    /// temperature" is never an event in either direction. Always autonomous (the hardware got hot;
    /// the user did not do it).
    static func hotBattery(outcome: BatteryHeatAlert.Outcome) -> NotificationEvent? {
        guard case .fire(let celsius) = outcome else { return nil }
        return NotificationEvent(kind: .hotBattery(Int(celsius.rounded())), cause: .autonomous)
    }

    private static func cause(of source: CommandSource) -> NotificationCause {
        source == .user ? .userAction : .autonomous
    }
}
