import AppIntents
import Foundation

/// Honest, localized failures for Top Up (#17 §7 Shape B, mirroring EnergyModeIntentError's pattern).
/// `perform` THROWS these so the system surfaces the message AND marks the action FAILED (honest action
/// status). `CustomLocalizedStringResourceConvertible` is the surfacing protocol; the wording is preserved
/// verbatim from the prior dialog copy.
enum TopUpIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case alreadyInProgress
    case pausedFirst
    case notReady
    case couldNotStart
    case notSetUp

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .alreadyInProgress:
            return "A top up is already running."
        case .pausedFirst:
            return "Charging is paused. Resume charging, then top up."
        case .notReady:
            return "I couldn't read your current limit yet. Open the app once so it can read, then try again."
        case .couldNotStart:
            return "I couldn't start the top up. Open the app and check it's set up."
        case .notSetUp:
            return "Battery's charge control isn't set up yet. Open Battery to finish setup."
        }
    }
}

/// Top Up (spec sec 1, Pass 2): starts a one-shot top up through the live @MainActor surface, routing to
/// `TopUpController.topUp`. Invocation model (sec 10): the intent conforms to `ForegroundContinuableIntent`
/// and NEVER calls `continueInForeground`, which pins `perform` to the app's own resident process (so the
/// live audited controller is reachable in-process) WITHOUT foregrounding the menu-bar accessory (no Dock
/// icon, no focus steal, no popover). The live surface is resolved via `@Dependency` (AppDependencyManager,
/// registered at launch). Parameterless (no AppEnum, unlike Set Charge Limit). Reports the START outcome
/// only: the climb to 100 then revert runs over minutes via the app's snapshot loop. Shape B (#17 §7): the
/// start is a silent `.result()` — the "limit restored" reassurance is delivered at completion by the
/// existing topUpComplete notification (gated on reachedFull, names the restored limit) and the climb shows
/// in the popover, matching the app's own Top-Up-button feedback model; every failure throws a localized
/// `TopUpIntentError`.
///
/// FCI RETAINED deliberately (#17 §7, owner decision c): `ForegroundContinuableIntent` (introduced macOS 13.3)
/// is the ONLY in-process mechanism at this app's macOS 14.0 deployment floor (below 26.4 the app runs
/// monitoring-only; charge control is hidden). `supportedModes` / `.foreground(.dynamic)` require macOS 26.0,
/// so the FCI→supportedModes migration is DEFERRED until the floor is raised to 26.0 — the deprecation warning
/// here is cosmetic, non-breaking, and intentional (tracked item).
///
/// `@available(macOSApplicationExtension, unavailable)`: `ForegroundContinuableIntent` is itself
/// unavailable in app-extension contexts, so the conformer must match.
@available(macOSApplicationExtension, unavailable)
struct TopUpIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource { "Top Up Battery" }
    static var description: IntentDescription {
        IntentDescription("Charge to full once, then restore your charge limit. Routes through the app so the change is verified and surfaced.")
    }

    /// The live audited surface, resolved in-process via AppDependencyManager (sec 10), mirroring
    /// SetChargeLimitIntent. The framework awaits the registered async @MainActor dependency before
    /// `perform`, so this is populated by the time `perform` runs in the app's own process.
    @Dependency(key: TopUpIntentSurface.dependencyKey) var surface: TopUpIntentSurface

    @MainActor
    func perform() async throws -> some IntentResult {
        // sec 10 on-device gate: log the PID so the owner can confirm same-process (in-process) execution.
        IntentLog.log.debug("TopUpIntent.perform pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")

        switch await surface.requestTopUp() {
        case .started:
            return .result()   // Shape B: silent start; completion surfaces via the topUpComplete notification
        case .alreadyInProgress:
            throw TopUpIntentError.alreadyInProgress
        case .pausedFirst:
            throw TopUpIntentError.pausedFirst
        case .notReady:
            throw TopUpIntentError.notReady
        case .couldNotStart:
            throw TopUpIntentError.couldNotStart
        case .notSetUp:
            throw TopUpIntentError.notSetUp
        }
    }
}
