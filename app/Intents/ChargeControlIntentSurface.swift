import Foundation
import os

/// Phase 5 feature #17 Pass 1 (SPEC 02-SPEC-phase-5-app-intents.md sec 2/10/11): the ONE @MainActor seam
/// an App Intent may reach. The AppDelegate constructs the live instance with the live engine and
/// registers it through `AppDependencyManager` once on launch; the intent resolves it via `@Dependency`
/// and calls `setLimit`. The surface exposes ONLY the set entry point, gated on the injected readiness gate, so an
/// intent can never reach unaudited engine state. Routing goes through the live audited engine
/// (`userSetLimit`, source `.appIntent`), inheriting its serialization, read-verify, and setup gating —
/// never a reimplementation and never a raw `shortcuts run`.

/// Shared os_log handle for the App Intents in-process / readiness diagnostics (sec 10 PID gate).
enum IntentLog {
    static let log = Logger(subsystem: "com.example.batteryapp", category: "AppIntents")
}

/// The audited Set entry point, seamed so the surface is testable host-app-free (the production
/// conformer is `ChargeLimitEngine`; tests inject a recording mock).
@MainActor
protocol ChargeLimitSetting {
    func userSetLimit(_ target: Int, source: CommandSource) async -> CommandOutcome
}

extension ChargeLimitEngine: ChargeLimitSetting {}

@MainActor
final class ChargeControlIntentSurface {

    /// The AppDependencyManager key the AppDelegate registers under and the intent resolves with
    /// (sec 10: the explicit-key async @MainActor form, Swift 6 safe). `nonisolated` so the intent's
    /// `@Dependency(key:)` attribute — a nonisolated stored-property context — can read it.
    nonisolated static let dependencyKey = "com.example.batteryapp.intentSurface"

    /// What an intent reports from (spec sec 4 / sec 10): the Set applied (engine confirmed the target),
    /// or an honest non-acting / non-confirming reason.
    enum SetLimitResult: Equatable {
        case applied
        case appliedUnconfirmed // the set went out but the engine could not read-verify it (degraded) — honest soft success
        case notSetUp        // charge control's shortcuts are absent / automation blocked (open Battery to set up)
        case notReady        // readiness did not settle within the bounded timeout (open Battery first)
        case couldNotConfirm // the set ran but the engine could not confirm the target was reached
    }

    private let setter: any ChargeLimitSetting
    private let isSetUp: @MainActor () -> Bool          // SetupFlow.isOperational, read live (already-determined)

    /// The shared app-level readiness latch (sec 11): the app settles it once (first known-limit read done,
    /// or setup-failure path taken) and every intent surface awaits it. Injected, not owned, so Pass 2's Top
    /// Up surface awaits the SAME gate rather than a duplicated latch.
    private let readinessGate: IntentReadinessGate

    init(setter: any ChargeLimitSetting,
         isSetUp: @escaping @MainActor () -> Bool,
         readinessGate: IntentReadinessGate) {
        self.setter = setter
        self.isSetUp = isSetUp
        self.readinessGate = readinessGate
    }

    /// Route a Set through the audited engine entry point (sec 10). Awaits the readiness gate (bounded);
    /// honest + non-acting when not ready or not set up; reports `.applied` ONLY after the engine confirms
    /// the limit reached the target through its existing read-verify path, else `.couldNotConfirm`.
    func setLimit(_ percent: Int) async -> SetLimitResult {
        // Await the shared app-level readiness gate (sec 11). A first trigger after a quit suspends here
        // until the gate settles (first known-limit read done, or the setup-failure path taken); a timeout
        // is the honest could-not-ready, never a silent no-op.
        guard await readinessGate.awaitReady() else { return .notReady }
        // Not-set-up pre-check (sec 4): SetupFlow's ALREADY-DETERMINED operational state — no fresh
        // `shortcuts run`, so the intent never blocks on a stuck invocation.
        guard isSetUp() else { return .notSetUp }
        // Route through the audited engine: inherits serialization (commandInFlight), the read-verify, the
        // source tagging, and the non-blocking confirm window. Any source other than `.user` (this one
        // included) uses only the non-blocking read-verify and the opt-in banner — never a synchronous modal.
        // Audit A2: the verdict is the engine's OWN CommandOutcome, not a re-read of currentLimit(). The
        // old `currentLimit() == percent` value-compare could not tell a read-verified `.applied` from a
        // degraded-assumed `.appliedUnconfirmed` (the engine optimistically sets `limit = .known(target)`
        // in degraded mode, so the compare returned `.applied` for an unverified write — the A2 hole).
        // The read-verify is settled synchronously inside `userSetLimit` (sec 10), so the outcome
        // is final at the call's return — no bounded wait, no extension of the commandInFlight lock.
        switch await setter.userSetLimit(percent, source: .appIntent) {
        case .applied:            return .applied
        case .appliedUnconfirmed: return .appliedUnconfirmed
        case .invalidTarget, .busy, .mismatch, .issueFailed:
            return .couldNotConfirm
        }
    }
}
