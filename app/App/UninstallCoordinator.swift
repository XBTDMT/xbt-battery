import Foundation

// 5.5 Cut 2 — the ordered uninstall teardown (app-side only). The privileged helper is SMC-DEAD /
// Process-only, so "clean uninstall" is: RESTORE the three things the app can change from their
// as-shipped defaults (the charge limit, the Energy Mode, the sleep/wake schedule) BEFORE
// dismantling anything, then unregister the daemon + login item and drop the app's own residue.
// The order is a safety invariant: never tear down around an unrestored limit (RISK-1), and the two
// helper-driven restores (energy, schedule) need the daemon ALIVE, so they MUST precede any
// unregister. Any failure in the three restores ABORTS the remainder — the app stays fully installed
// and says why. The teardown steps (4–6) are best-effort: each records its own status but never aborts
// the ones after it (by the time they run the machine is already in a safe, restored state).
//
// SCOPE, stated honestly: every guarantee above holds ONLY on the Settings → Uninstall path. Drag the
// app to the Trash (or `rm -rf build/`, which is how the live bundle disappears on the dev machine)
// and nothing in this file runs — and it can never run later, because the daemon's BundleProgram
// points at a binary INSIDE the app bundle (`launchctl print` shows the job as submitted by smd with a
// bundle-relative program; there is no /Library/LaunchDaemons plist), so a deleted bundle leaves an
// unlaunchable job. Restore logic can therefore never live in the helper "for later" — it has no
// later. What survives that path is documented in the completed panel's manual-residue checklist and
// in RELEASING.md §9.
//
// This file is host-app-free (pure logic + seam protocols; no SwiftUI, no engine imports) so it
// compiles into the test target. The LIVE seam conformances (which drive the real @MainActor engines)
// and the SwiftUI surface live in the app-only wiring (BatteryApp.swift).

// MARK: - seams (the three restores + the app-residue removal)
//
// @MainActor because each wraps a @MainActor engine (ChargeLimitEngine / EnergyModeController /
// SleepWakeScheduleController). The daemon + login-item unregisters reuse the EXISTING nonisolated
// seams DaemonService and LoginItemServicing (the coordinator calls their synchronous throwing
// unregister() directly, matching the spec's "DaemonService (exists) / login item (exists)").

/// Restore the charge limit to 100% via ChargeLimitEngine.userSetLimit(100, source: .user). `.user`
/// custody is deliberate — it satisfies `isExplicitUserOrIntent`, so the scheduler will not fight the
/// restore. `waitUntilIdle` backs the one `.busy` retry (wait for `commandInFlight` to clear).
@MainActor protocol LimitRestoring: AnyObject {
    func restoreFullLimit() async -> CommandOutcome
    func waitUntilIdle() async
}

/// Restore Energy Mode to Automatic (on all power sources) via EnergyModeController.setMode. Returns
/// true iff the helper confirmed the set. Requires the daemon alive → runs before any unregister.
@MainActor protocol EnergyRestoring: AnyObject {
    func restoreAutomatic() async -> Bool
}

/// Clear the repeating sleep/wake schedule (all-disabled → `pmset repeat cancel`, verified against the
/// helper's fixed argv builder). Idempotent when no schedule exists. Returns true iff it succeeded.
@MainActor protocol ScheduleClearing: AnyObject {
    func clearRepeatingSchedule() async -> Bool
}

/// Remove the app's OWN residue: its UserDefaults domain and the user-Library Application Support dir
/// it created. NOT the root-owned /Library state dir (that is the residue script's job — it needs sudo).
@MainActor protocol AppResidueRemoving: AnyObject {
    func removeAppResidue()
}

// MARK: - coordinator

@MainActor
final class UninstallCoordinator: ObservableObject {

    enum StepStatus: Equatable { case pending, running, done, failed(String) }

    struct Step: Identifiable, Equatable {
        let id: Int            // 1-based step number
        let title: String
        var status: StepStatus
    }

    enum Terminal: Equatable {
        case notStarted
        case running
        case aborted(step: Int, reason: String)   // a failure in one of the three restores (steps 1–3)
        case completed                            // reached the terminal panel (steps 4–6 may carry per-step failures)
    }

    /// The six runnable steps, in strict order. (Step 7 in the spec — the terminal panel — is the
    /// `.completed` state's UI, not a runnable step.)
    static let stepTitles = [
        "Restore charge limit to 100%",
        "Restore Energy Mode to Automatic",
        "Clear the sleep/wake schedule",
        "Unregister the energy helper",
        "Remove the login item",
        "Remove app preferences & data",
    ]

    // MARK: - manual-residue checklist copy (rendered by the completed panel)
    //
    // The panel's item 1. It lives HERE rather than inline in the view because it is uninstall-domain
    // knowledge, not view styling: `pmset repeat` is a SINGLE machine-wide slot with no System Settings
    // page anywhere, so unlike the charge limit / Energy Mode / Power Nap it cannot be discovered or
    // undone by a user poking around Settings — the only way to see it is `pmset -g sched`. Step 3
    // clears it on THIS path; the checklist exists for readers who will next drag the app to the Trash
    // (or `rm -rf build/`), where nothing in this file ever runs. Pinned by a test so the copy and the
    // command cannot drift apart.

    /// The `pmset` incantation that reveals a repeating schedule (there is no GUI for it).
    static let repeatingScheduleInspectCommand = "pmset -g sched"

    /// The recovery command that clears it. Root-only, and it clears the ENTIRE repeating slot.
    static let repeatingScheduleRecoveryCommand = "sudo pmset repeat cancel"

    /// Item 1 of the completed panel's manual-residue checklist.
    static let repeatingScheduleResidueNotice =
        "Check for a repeating sleep/wake schedule. Battery's schedule is programmed into pmset, which has one machine-wide slot and no System Settings page — if Battery is removed without this uninstall running, the schedule keeps waking or sleeping your Mac and nothing will show it to you. Run \(repeatingScheduleInspectCommand); if a repeating event is listed and you don't want it, clear it with:"

    @Published private(set) var steps: [Step]
    @Published private(set) var terminal: Terminal = .notStarted

    private let limit: any LimitRestoring
    private let energy: any EnergyRestoring
    private let schedule: any ScheduleClearing
    private let primaryDaemon: any DaemonService
    private let legacyDaemon: any DaemonService
    private let loginItem: any LoginItemServicing
    private let residue: any AppResidueRemoving

    init(limit: any LimitRestoring,
         energy: any EnergyRestoring,
         schedule: any ScheduleClearing,
         primaryDaemon: any DaemonService,
         legacyDaemon: any DaemonService,
         loginItem: any LoginItemServicing,
         residue: any AppResidueRemoving) {
        self.limit = limit
        self.energy = energy
        self.schedule = schedule
        self.primaryDaemon = primaryDaemon
        self.legacyDaemon = legacyDaemon
        self.loginItem = loginItem
        self.residue = residue
        self.steps = Self.stepTitles.enumerated().map {
            Step(id: $0.offset + 1, title: $0.element, status: .pending)
        }
    }

    private func set(_ step: Int, _ status: StepStatus) { steps[step - 1].status = status }

    /// Execute the strict-order teardown. Idempotent: a second call after it has started/finished is a
    /// no-op (we never re-run a teardown).
    func run() async {
        guard terminal == .notStarted else { return }
        terminal = .running

        // 1. RESTORE CHARGE LIMIT → 100% as .user. Success family = didWrite (verified OR as-set);
        //    .busy → wait for the in-flight command to clear, retry ONCE; anything else → ABORT (RISK-1:
        //    never tear down around an unrestored limit).
        set(1, .running)
        var outcome = await limit.restoreFullLimit()
        if outcome == .busy {
            await limit.waitUntilIdle()
            outcome = await limit.restoreFullLimit()
        }
        guard outcome.didWrite else {
            let reason = "Couldn’t restore the charge limit to 100%. Repair the “Battery Limit 100” shortcut (or set 100% manually in Shortcuts), then try again."
            set(1, .failed(reason))
            terminal = .aborted(step: 1, reason: reason)
            return
        }
        set(1, .done)

        // 2. RESTORE ENERGY MODE → Automatic. Needs the daemon ALIVE, so it precedes any unregister.
        set(2, .running)
        guard await energy.restoreAutomatic() else {
            let reason = "Couldn’t restore Energy Mode to Automatic. The energy helper must be running — keep the app installed and try again."
            set(2, .failed(reason))
            terminal = .aborted(step: 2, reason: reason)
            return
        }
        set(2, .done)

        // 3. CLEAR SLEEP/WAKE SCHEDULE → all-disabled = pmset repeat cancel. Also helper-driven → alive.
        set(3, .running)
        guard await schedule.clearRepeatingSchedule() else {
            let reason = "Couldn’t clear the sleep/wake schedule. The energy helper must be running — keep the app installed and try again."
            set(3, .failed(reason))
            terminal = .aborted(step: 3, reason: reason)
            return
        }
        set(3, .done)

        // 4. DAEMON UNREGISTER — primary, then a BEST-EFFORT legacy unregister whose errors are ignored
        //    (a stale/absent legacy registration is expected). A primary failure is recorded but does
        //    NOT abort: the restores in steps 1–3 already succeeded, so the machine is in a restored
        //    state, and removing the app stops the daemon PROCESS (its BundleProgram points inside the
        //    bundle, so a deleted bundle is an unlaunchable job). What deleting the app does NOT do is
        //    undo settings — that is exactly why steps 1–3 run first and why the completion checklist
        //    exists.
        set(4, .running)
        var primaryError: Error?
        do { try primaryDaemon.unregister() } catch { primaryError = error }
        try? legacyDaemon.unregister()
        if let primaryError {
            set(4, .failed("The energy helper couldn’t be unregistered automatically (\(primaryError.localizedDescription)). Removing the app stops the helper from running, but it doesn’t undo settings — finish the notes below."))
        } else {
            set(4, .done)
        }

        // 5. LOGIN-ITEM UNREGISTER. A not-registered state is not an error (the seam models it as a
        //    status, never a throw). A genuine failure is recorded but does NOT abort.
        set(5, .running)
        do {
            try loginItem.unregister()
            set(5, .done)
        } catch {
            set(5, .failed("The login item couldn’t be removed automatically (\(error.localizedDescription))."))
        }

        // 6. APP-DOMAIN RESIDUE — prefs + the app's own user-Library dir (never the root state dir).
        set(6, .running)
        residue.removeAppResidue()
        set(6, .done)

        // 7. TERMINAL PANEL — reached whenever the three restores succeeded (steps 4–6 may still carry
        //    a per-step failure, surfaced in the panel).
        terminal = .completed
    }
}
