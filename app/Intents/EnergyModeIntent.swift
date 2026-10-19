import AppIntents
import Foundation
import Shared   // EnergyModeValue — the lockstep source of truth for the AppEnum raw values

/// Phase 5 feature #17 Pass 2 (Energy Mode): the sanctioned energy-mode values as an AppEnum, so an
/// out-of-set value cannot be chosen in Shortcuts/Siri (spec §3). Kept in LOCKSTEP with the shared
/// `EnergyModeValue` (a test asserts the raw values match — the single source of truth).
///
/// HONESTY EDGE (spec §3): a static AppEnum cannot hide High Power the way the picker's `availableModes`
/// does, so on hardware that lacks High Power a `.high` set MUST surface the failure path (`.rejected`),
/// never a silent no-op. The surface maps the helper's rejection token to `.rejected`; the perform reports it.
enum EnergyModeOption: Int, AppEnum, CaseIterable {
    case automatic = 0
    case low = 1
    case high = 2

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Energy Mode" }

    static var caseDisplayRepresentations: [EnergyModeOption: DisplayRepresentation] {
        [.automatic: "Automatic", .low: "Low Power", .high: "High Power"]
    }

    /// A plain-String label for the spoken/written dialog (the `caseDisplayRepresentations` above are
    /// `DisplayRepresentation`s for the picker; this is the same wording for dialog interpolation).
    var displayLabel: String {
        switch self {
        case .automatic: return "Automatic"
        case .low:       return "Low Power"
        case .high:      return "High Power"
        }
    }
}

/// Set Energy Mode (spec §3): routes to `EnergyModeController.setMode` through the live @MainActor surface,
/// writing the ACTIVE per-source scope. Mirrors SetChargeLimitIntent's invocation model (sec 10): it
/// conforms to `ForegroundContinuableIntent` and NEVER calls `continueInForeground`, which pins `perform`
/// to the app's own resident process (so the live controller is reachable in-process) WITHOUT foregrounding
/// the menu-bar accessory (no Dock icon, no focus steal, no popover). The live surface is resolved via
/// `@Dependency` (AppDependencyManager, registered at launch). Unlike Top Up there is NO readiness gate and
/// NO setup gate: Energy Mode's only precondition is helper reachability, surfaced honestly as the
/// `.helperUnreachable` arm.
///
/// `@available(macOSApplicationExtension, unavailable)`: `ForegroundContinuableIntent` is itself unavailable
/// in app-extension contexts, so the conformer must match.
/// Honest, localized failures for the Energy-Mode intent (Shape B, locked from the Phase-0 probe). `perform`
/// THROWS these so the system surfaces the message AND marks the action FAILED (honest action status, which a
/// success-result-carrying-a-failure-dialog would not). `CustomLocalizedStringResourceConvertible` is the
/// surfacing protocol — verified on-device (Phase-0 obs-2) to surface the exact message on Spotlight and the
/// Shortcuts app. Copy is owner-tunable, honest, and non-blaming.
enum EnergyModeIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case helperUnreachable
    case busy
    case rejected(String)   // the requested mode label, e.g. "High Power"
    case invalidRequest

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .helperUnreachable:
            return "Energy helper unavailable — approve it in System Settings → Login Items & Extensions, then try again."
        case .busy:
            return "Another energy-mode change is in progress. Try again in a moment."
        case .rejected(let label):
            return "This Mac couldn't switch to \(label)."
        case .invalidRequest:
            return "That request wasn't valid."
        }
    }
}

// FCI RETAINED deliberately (#17 §7, owner decision c): `ForegroundContinuableIntent` (introduced macOS 13.3)
// is the ONLY in-process mechanism at this app's macOS 14.0 deployment floor (below 26.4 the app runs
// monitoring-only; charge control is hidden). `supportedModes` / `.foreground(.dynamic)` require macOS 26.0,
// so the FCI→supportedModes migration is DEFERRED until the floor is raised to 26.0 — the deprecation warning
// here is cosmetic, non-breaking, and intentional (tracked item).
@available(macOSApplicationExtension, unavailable)
struct EnergyModeIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource { "Set Energy Mode" }
    static var description: IntentDescription {
        IntentDescription("Set the Mac's Energy Mode (Automatic, Low Power, or High Power) for the power source in use. Routes through the app so the change is verified and surfaced.")
    }

    @Parameter(title: "Energy Mode") var mode: EnergyModeOption

    /// The live audited surface, resolved in-process via AppDependencyManager (sec 10), mirroring the other
    /// two intents. The framework awaits the registered async @MainActor dependency before `perform`, so this
    /// is populated by the time `perform` runs in the app's own process.
    @Dependency(key: EnergyModeIntentSurface.dependencyKey) var surface: EnergyModeIntentSurface

    // FINAL perform shape — SHAPE B, locked from the Phase-0 probe (2026-06-26).
    //   SUCCESS → `.result()`: silent and flash-free. Obs-3 showed plain `.result()` presents NO window on
    //     Spotlight, the Shortcuts app, or Siri; whereas an empty `.result(dialog:"")` flashed a blank window
    //     in the Shortcuts app (obs-1). The honest resulting value is surfaced in-app — the menu-bar glyph
    //     re-reads via EnergyModeController.onSetSucceeded — so silent success is not a "did it work?" no-op.
    //   FAILURE → THROW a localized error. Obs-2: a thrown CustomLocalizedStringResourceConvertible surfaced
    //     our exact message on Spotlight AND the Shortcuts app, in-process, and a throw marks the action
    //     FAILED (honest action status). HARD INVARIANT held: every failure arm yields real feedback.
    //   VOICE/Siri is a §6-gated follow-on: Siri did not invoke the parameterless probe at all, so its
    //     throw-vs-spoken-dialog behavior is unverified. Pure throw is the verified-safe shape; an
    //     isVoiceOnly spoken path (without regressing visual success) is a separate increment if §6 proves
    //     it both needed and achievable.
    @MainActor
    func perform() async throws -> some IntentResult {
        // sec 10 on-device gate: log the PID so the owner can confirm same-process (in-process) execution.
        IntentLog.log.debug("EnergyModeIntent.perform pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")

        switch await surface.setMode(mode.rawValue) {
        case .applied:
            return .result()   // silent success; the glyph re-reads via onSetSucceeded — no dialog, no flash
        case .helperUnreachable:
            throw EnergyModeIntentError.helperUnreachable
        case .busy:
            throw EnergyModeIntentError.busy
        case .rejected:
            throw EnergyModeIntentError.rejected(mode.displayLabel)
        case .invalidRequest:
            throw EnergyModeIntentError.invalidRequest
        }
    }
}
