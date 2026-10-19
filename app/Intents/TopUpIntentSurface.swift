import Foundation

/// Phase 5 feature #17 Pass 2: the ONE @MainActor seam a Top Up App Intent may reach, mirroring
/// ChargeControlIntentSurface. The AppDelegate constructs the live instance with the live TopUpController
/// and registers it through `AppDependencyManager` once on launch; the intent resolves it via `@Dependency`
/// and calls `requestTopUp`. The surface exposes ONLY that one entry point, gated on the SAME injected
/// readiness gate the charge surface awaits (Step A), so an intent can never reach an unaudited controller.
/// Routing goes through the live audited TopUpController (`topUp`), reporting the START outcome only (the
/// climb to 100 then revert runs over minutes via the app's snapshot loop, not synchronously here).

/// The audited start action, seamed so the surface is testable without a real controller (the production
/// conformer is `TopUpController`; tests inject a recording mock), mirroring `ChargeLimitSetting`.
@MainActor
protocol TopUpStarting: AnyObject {
    func topUp() async -> TopUpController.StartOutcome
}

extension TopUpController: TopUpStarting {}

@MainActor
final class TopUpIntentSurface {

    /// The AppDependencyManager key the AppDelegate registers under and the intent resolves with (sec 10),
    /// mirroring ChargeControlIntentSurface.dependencyKey. `nonisolated` so the intent's `@Dependency(key:)`
    /// nonisolated stored-property context can read it.
    nonisolated static let dependencyKey = "com.example.batteryapp.topUpIntentSurface"

    /// What a Top Up intent reports from: the start happened, or an honest non-acting reason. Completion is
    /// NOT reported here; the climb to full then revert runs over minutes via the app's snapshot loop.
    enum TopUpIntentResult: Equatable {
        case started            // the one-shot top up started (climbing to 100, reverts when full)
        case alreadyInProgress  // a top up is already running
        case pausedFirst        // charging is paused, resume before topping up
        case notReady           // readiness did not settle, or the limit is still unknown after it settled
        case couldNotStart      // the start Set did not take (abort, nothing to climb)
        case notSetUp           // charge control's shortcuts are absent or automation blocked
    }

    private let readinessGate: IntentReadinessGate
    private let topUp: any TopUpStarting
    private let isSetUp: @MainActor () -> Bool          // SetupFlow.isOperational, read live (already-determined)

    /// #29 D-5: fired when a Top Up INTENT actually STARTS (no UI present), so the AppDelegate shows the
    /// "Topping up to 100%" HUD. Additive + intent-only — a menu / popover Top Up bypasses this surface, so
    /// it never triggers the HUD (D10: never for direct in-app actions). nil in tests / when no HUD is wired.
    var onStarted: (@MainActor () -> Void)?

    init(readinessGate: IntentReadinessGate,
         topUp: any TopUpStarting,
         isSetUp: @escaping @MainActor () -> Bool) {
        self.readinessGate = readinessGate
        self.topUp = topUp
        self.isSetUp = isSetUp
    }

    /// Start a one-shot top up through the audited controller (sec 10), in the same order as the charge
    /// surface: await the shared readiness gate first (bounded, honest could-not-ready, never a silent
    /// no-op), then the already-determined setup state, then route. Reports the START outcome only.
    func requestTopUp() async -> TopUpIntentResult {
        guard await readinessGate.awaitReady() else { return .notReady }   // bounded; never a silent no-op
        guard isSetUp() else { return .notSetUp }                          // already-determined state, no fresh shortcuts run
        switch await topUp.topUp() {
        case .started:           onStarted?(); return .started
        case .alreadyInProgress: return .alreadyInProgress
        case .refusedPaused:     return .pausedFirst
        case .notReady:          return .notReady   // limit still unknown even after the gate settled (fresh install)
        case .couldNotStart:     return .couldNotStart
        }
    }
}
