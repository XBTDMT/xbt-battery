import Foundation
import Shared   // EnergyModeCommand.validate, EnergySource (the validated {0,1,2} set values + per-source target)

/// Phase 5 feature #17 Pass 2 (Energy Mode): the ONE @MainActor seam an Energy-Mode App Intent may reach,
/// mirroring ChargeControlIntentSurface / TopUpIntentSurface. The AppDelegate constructs the live instance
/// with the live EnergyModeController and an active-source resolver, and registers it through
/// AppDependencyManager once on launch; the intent resolves it via `@Dependency` and calls `setMode`.
///
/// Two ways this surface differs from the charge / Top Up surfaces, both decided in the spec (§2):
///   • READINESS GATE — DECOUPLED. It does NOT await the shared IntentReadinessGate. That gate settles on
///     a charge-limit fact; Energy Mode's only precondition is helper reachability, already surfaced
///     honestly as `.helperUnreachable` on a cold-launch set. Awaiting it would block on an unrelated read
///     and manufacture a `.notReady` that does not reflect the real dependency.
///   • SCOPE — it writes the ACTIVE per-source scope only, resolved LIVE at perform time (the picker's
///     `(powerSource == .ac) ? .charger : .battery`). No source parameter is exposed: a battery/charger
///     choice could select the INACTIVE profile, which is invisible to the auto-energy runner's BRANCH A/B
///     manual-change detection and would land on the wrong profile (the HARD SAFETY constraint).

/// The privileged set seam, signature-identical to the automation's `AutoEnergyModeSetting` but owned
/// per-surface like `ChargeLimitSetting` / `TopUpStarting` (so the intent surface keeps its own injected
/// mock in tests). `EnergyModeController` conforms via the empty extension below; tests inject a recording
/// mock. It is the controller's ADDITIVE Int + optional-completion overload — the completion is non-nil here
/// (the picker passes none and drops silently; the intent must LEARN of a serialization drop to report busy).
@MainActor
protocol EnergyModeSetting: AnyObject {
    func setMode(_ mode: Int, source: Int,
                 completion: (@MainActor (Result<String, HelperClientError>) -> Void)?)
}

extension EnergyModeController: EnergyModeSetting {}

@MainActor
final class EnergyModeIntentSurface {

    /// The AppDependencyManager key the AppDelegate registers under and the intent resolves with (sec 10),
    /// mirroring ChargeControlIntentSurface.dependencyKey / TopUpIntentSurface.dependencyKey. `nonisolated`
    /// so the intent's `@Dependency(key:)` nonisolated stored-property context can read it.
    nonisolated static let dependencyKey = "com.example.batteryapp.energyModeIntentSurface"

    /// What an Energy-Mode intent reports from (spec §2). NOT Top-Up's arms: there is no readiness latch and
    /// no charging-pause, so no `.notReady` / `.pausedFirst`. There is NO silent no-op — every arm is honest.
    enum SetModeResult: Equatable {
        case applied(String)     // .success(token): the helper read-back (the honest resulting value)
        case helperUnreachable   // .failure(.unreachable): approve the helper in System Settings
        case busy                // .failure(.helperError(serializedDropToken)): a set is already in flight
        case rejected            // .failure(.helperError(otherToken)): the helper rejected the set
        case invalidRequest      // EnergyModeCommand.validate(mode:source:) == nil — defense-in-depth + hang guard
    }

    private let setter: any EnergyModeSetting
    /// Resolve the ACTIVE source LIVE at perform time (spec §2 SCOPE): the picker's
    /// `(powerSource == .ac) ? .charger : .battery`. The intent writes THIS single per-source scope.
    private let activeSource: @MainActor () -> EnergySource

    /// #29 D-5: fired on a successful intent set with the friendly applied-mode name, so the AppDelegate
    /// can show the HUD ("Energy mode set to X"). nil in tests / when no HUD is wired (an additive hook —
    /// the set path is unchanged).
    var onApplied: (@MainActor (String) -> Void)?

    init(setter: any EnergyModeSetting, activeSource: @escaping @MainActor () -> EnergySource) {
        self.setter = setter
        self.activeSource = activeSource
    }

    /// Set the Energy Mode for the source in use, through the live audited controller (spec §2). Resolves
    /// the active per-source scope live, then bridges the controller's additive Int + completion overload
    /// into an async result.
    func setMode(_ mode: Int) async -> SetModeResult {
        // Resolve the active per-source scope LIVE, once, so validate + the set agree on the scope.
        let source = activeSource()
        // HANG FIX (spec §2): EnergyModeController.setMode fires its completion on EVERY path EXCEPT the
        // validate guard (mode/source out of {0,1,2}), which sets lastError and returns WITHOUT firing — a
        // naïve withCheckedContinuation over that path would hang forever. So validate HERE first and return
        // .invalidRequest WITHOUT bridging. The §3 AppEnum constrains mode, so this never fires in practice;
        // it is defense-in-depth, and the hang-fix test pins it.
        guard EnergyModeCommand.validate(mode: mode, source: source.rawValue) != nil else {
            return .invalidRequest
        }
        // Bridge the additive completion (spec §2 BRIDGE): first arg unlabeled, PASS A NON-NIL completion so
        // the intent learns of a serialization drop. The controller fires the completion exactly once on the
        // valid path, so the continuation resumes exactly once.
        return await withCheckedContinuation { (cont: CheckedContinuation<SetModeResult, Never>) in
            setter.setMode(mode, source: source.rawValue) { result in
                switch result {
                case .success(let token):
                    let name = EnergyModeValue(rawValue: mode).map(EnergyModePresentation.label) ?? "the selected mode"
                    self.onApplied?(name)
                    cont.resume(returning: .applied(token))
                case .failure(.unreachable):
                    cont.resume(returning: .helperUnreachable)
                case .failure(.helperError(let token)):
                    // Reused-case distinction (spec §2): STRING-MATCH the serialization drop token to
                    // separate a drop (busy) from a real helper rejection (rejected).
                    cont.resume(returning: token == EnergyModeController.serializedDropToken ? .busy : .rejected)
                }
            }
        }
    }
}
