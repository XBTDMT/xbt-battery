import AppIntents
import Foundation

/// Phase 5 feature #17 Pass 1: the sanctioned charge-limit values as an AppEnum, so an out-of-range
/// value cannot be chosen in Shortcuts/Siri (spec sec 1). Kept in lockstep with
/// `ChargeShortcuts.validLimitValues` (a test asserts the raw values match — the single source of truth).
enum ChargeLimitOption: Int, AppEnum, CaseIterable {
    case eighty = 80
    case eightyFive = 85
    case ninety = 90
    case ninetyFive = 95
    case hundred = 100

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Charge Limit" }

    static var caseDisplayRepresentations: [ChargeLimitOption: DisplayRepresentation] {
        [.eighty: "80%", .eightyFive: "85%", .ninety: "90%", .ninetyFive: "95%", .hundred: "100%"]
    }
}

/// Honest, localized failures for Set Charge Limit (#17 §7 Shape B, mirroring EnergyModeIntentError's
/// pattern). `perform` THROWS these so the system surfaces the message AND marks the action FAILED (honest
/// action status, which a success-result-carrying-a-failure-dialog would not). `CustomLocalizedStringResource-
/// Convertible` is the surfacing protocol; the wording is preserved verbatim from the prior dialog copy.
/// `couldNotConfirm` carries the target percent for interpolation.
enum SetChargeLimitIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notSetUp
    case notReady
    case couldNotConfirm(Int)   // the target percent

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSetUp:
            return "Battery's charge control isn't set up yet. Open Battery to finish setup."
        case .notReady:
            return "Battery isn't ready yet. Open Battery, then run this again."
        case .couldNotConfirm(let pct):
            return "Couldn't confirm the charge limit changed to \(pct)%. Open Battery to check."
        }
    }
}

/// Set Charge Limit (spec sec 1 / sec 10/11): routes to `engine.userSetLimit(target, source: .appIntent)`
/// through the live @MainActor surface. Invocation model (sec 10): the intent conforms to
/// `ForegroundContinuableIntent` and NEVER calls `continueInForeground` — this pins `perform` to the app's
/// own resident process (so the live audited engine is reachable in-process), WITHOUT foregrounding the
/// menu-bar accessory (no Dock icon, no focus steal, no popover). The live surface is resolved via
/// `@Dependency` (AppDependencyManager, registered at launch). The surface's readiness gate makes a
/// cold-launch trigger either act on a known limit or fail honestly — never a silent no-op. Shape B (#17 §7):
/// success is silent (`.result()`); every failure throws a localized `SetChargeLimitIntentError`.
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
struct SetChargeLimitIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource { "Set Charge Limit" }
    static var description: IntentDescription {
        IntentDescription("Set Battery's charge limit. Routes through the app so the change is verified, tagged, and surfaced.")
    }

    @Parameter(title: "Charge Limit") var limit: ChargeLimitOption

    /// The live audited surface, resolved in-process via AppDependencyManager (sec 10). The framework
    /// awaits the registered async @MainActor dependency before `perform`, so this is populated by the
    /// time `perform` runs in the app's own process.
    @Dependency(key: ChargeControlIntentSurface.dependencyKey) var surface: ChargeControlIntentSurface

    @MainActor
    func perform() async throws -> some IntentResult {
        // sec 10 on-device gate: log the PID so the owner can confirm same-process (in-process) execution
        // and that no second instance was launched. Pairs with the applicationDidFinishLaunching PID log.
        IntentLog.log.debug("SetChargeLimitIntent.perform pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")

        switch await surface.setLimit(limit.rawValue) {
        case .applied:
            return .result()   // Shape B: silent success
        case .appliedUnconfirmed:
            // Honest SOFT success (audit A2 / degraded mode): the limit WAS set — the normal case on a Mac
            // without read-back. Shape B treats it as a (silent) success; the degraded state surfaces in-app,
            // not in the intent. (Owner-veto point still open: could split to a distinct surfaced outcome.)
            return .result()
        case .notSetUp:
            throw SetChargeLimitIntentError.notSetUp
        case .notReady:
            throw SetChargeLimitIntentError.notReady
        case .couldNotConfirm:
            throw SetChargeLimitIntentError.couldNotConfirm(limit.rawValue)
        }
    }
}
