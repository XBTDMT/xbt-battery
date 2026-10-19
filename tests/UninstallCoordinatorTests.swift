import XCTest

/// 5.5 Cut 2 — the ordered uninstall teardown. These are ORDERING proofs: the three restores
/// (limit → energy → schedule) MUST all succeed, in order, BEFORE anything is unregistered; any
/// failure in steps 1–3 aborts the remainder with nothing torn down; steps 4–6 are best-effort
/// teardown that record per-step status but never abort. Mock seams record a single global call
/// order so "ran / did-not-run / in-what-order" is directly assertable.
@MainActor
final class UninstallCoordinatorTests: XCTestCase {

    // MARK: shared ordered call log (only ever touched on the main actor during a run)

    final class OrderLog {
        private(set) var calls: [String] = []
        func record(_ s: String) { calls.append(s) }
    }

    // MARK: the four new seams (all @MainActor — they wrap @MainActor engines)

    final class MockSeams: LimitRestoring, EnergyRestoring, ScheduleClearing, AppResidueRemoving {
        let log: OrderLog
        var limitOutcomes: [CommandOutcome]   // popped per restoreFullLimit call (default → .applied)
        var energyOK: Bool
        var scheduleOK: Bool
        init(log: OrderLog, limitOutcomes: [CommandOutcome] = [.applied],
             energyOK: Bool = true, scheduleOK: Bool = true) {
            self.log = log; self.limitOutcomes = limitOutcomes
            self.energyOK = energyOK; self.scheduleOK = scheduleOK
        }
        func restoreFullLimit() async -> CommandOutcome {
            log.record("limit")
            return limitOutcomes.isEmpty ? .applied : limitOutcomes.removeFirst()
        }
        func waitUntilIdle() async { log.record("waitIdle") }
        func restoreAutomatic() async -> Bool { log.record("energy"); return energyOK }
        func clearRepeatingSchedule() async -> Bool { log.record("schedule"); return scheduleOK }
        func removeAppResidue() { log.record("residue") }
    }

    // MARK: the two reused existing seams (nonisolated protocols → plain mocks)

    final class MockDaemon: DaemonService {
        let log: OrderLog; let label: String; var error: Error?
        var statusValue: DaemonServiceStatus = .enabled
        init(log: OrderLog, label: String, error: Error? = nil) {
            self.log = log; self.label = label; self.error = error
        }
        func register() throws {}
        func unregister() throws { log.record(label); if let error { throw error } }
    }

    final class MockLogin: LoginItemServicing {
        let log: OrderLog; var status: LoginStatus; var error: Error?
        init(log: OrderLog, status: LoginStatus = .notRegistered, error: Error? = nil) {
            self.log = log; self.status = status; self.error = error
        }
        func register() throws {}
        func unregister() throws { log.record("login"); if let error { throw error }; status = .notRegistered }
    }

    // MARK: factory

    private func makeCoordinator(
        limitOutcomes: [CommandOutcome] = [.applied],
        energyOK: Bool = true,
        scheduleOK: Bool = true,
        primaryDaemonError: Error? = nil,
        legacyDaemonError: Error? = nil,
        loginError: Error? = nil
    ) -> (UninstallCoordinator, OrderLog) {
        let log = OrderLog()
        let seams = MockSeams(log: log, limitOutcomes: limitOutcomes, energyOK: energyOK, scheduleOK: scheduleOK)
        let coord = UninstallCoordinator(
            limit: seams, energy: seams, schedule: seams,
            primaryDaemon: MockDaemon(log: log, label: "daemon.primary", error: primaryDaemonError),
            legacyDaemon: MockDaemon(log: log, label: "daemon.legacy", error: legacyDaemonError),
            loginItem: MockLogin(log: log, error: loginError),
            residue: seams)
        return (coord, log)
    }

    private func err(_ msg: String) -> Error {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    // MARK: t1 — happy path runs all six steps strictly in order

    func testHappyPathRunsAllStepsInOrder() async {
        let (coord, log) = makeCoordinator()
        await coord.run()
        XCTAssertEqual(log.calls,
                       ["limit", "energy", "schedule", "daemon.primary", "daemon.legacy", "login", "residue"])
        XCTAssertEqual(coord.steps.map(\.status), Array(repeating: .done, count: 6))
        XCTAssertEqual(coord.terminal, .completed)
    }

    // MARK: t2 — a limit-restore failure runs NOTHING after step 1

    func testLimitFailureAbortsBeforeAnyOtherStep() async {
        let (coord, log) = makeCoordinator(limitOutcomes: [.issueFailed(.error(.launchFailed))])
        await coord.run()
        XCTAssertEqual(log.calls, ["limit"], "no energy/schedule/unregister call may follow a failed restore")
        if case .failed(let reason) = coord.steps[0].status {
            XCTAssertFalse(reason.isEmpty, "the failed step carries a user-facing reason")
        } else { XCTFail("step 1 must be failed") }
        XCTAssertEqual(coord.steps[1...].map(\.status), Array(repeating: .pending, count: 5))
        if case .aborted(let step, _) = coord.terminal { XCTAssertEqual(step, 1) } else { XCTFail("must abort at step 1") }
    }

    // MARK: t2b — a mismatch (Set ran, read-back differs) also aborts

    func testLimitMismatchAborts() async {
        let (coord, log) = makeCoordinator(limitOutcomes: [.mismatch(observed: 80)])
        await coord.run()
        XCTAssertEqual(log.calls, ["limit"])
        if case .aborted(let step, _) = coord.terminal { XCTAssertEqual(step, 1) } else { XCTFail() }
    }

    // MARK: t3 — an energy-restore failure runs no schedule/unregister

    func testEnergyFailureAbortsBeforeScheduleAndUnregister() async {
        let (coord, log) = makeCoordinator(energyOK: false)
        await coord.run()
        XCTAssertEqual(log.calls, ["limit", "energy"])
        XCTAssertEqual(coord.steps[0].status, .done)
        if case .failed = coord.steps[1].status {} else { XCTFail("step 2 must be failed") }
        XCTAssertEqual(coord.steps[2...].map(\.status), Array(repeating: .pending, count: 4))
        if case .aborted(let step, _) = coord.terminal { XCTAssertEqual(step, 2) } else { XCTFail() }
    }

    // MARK: t4 — a schedule-clear failure runs no unregister

    func testScheduleFailureAbortsBeforeUnregister() async {
        let (coord, log) = makeCoordinator(scheduleOK: false)
        await coord.run()
        XCTAssertEqual(log.calls, ["limit", "energy", "schedule"])
        XCTAssertEqual(coord.steps[0].status, .done)
        XCTAssertEqual(coord.steps[1].status, .done)
        if case .failed = coord.steps[2].status {} else { XCTFail("step 3 must be failed") }
        XCTAssertEqual(coord.steps[3...].map(\.status), Array(repeating: .pending, count: 3))
        if case .aborted(let step, _) = coord.terminal { XCTAssertEqual(step, 3) } else { XCTFail() }
    }

    // MARK: t5 — .busy triggers exactly ONE retry, then proceeds

    func testBusyRetriesExactlyOnceThenProceeds() async {
        let (coord, log) = makeCoordinator(limitOutcomes: [.busy, .applied])
        await coord.run()
        XCTAssertEqual(log.calls,
                       ["limit", "waitIdle", "limit", "energy", "schedule",
                        "daemon.primary", "daemon.legacy", "login", "residue"],
                       "one wait + one retry, then the full teardown")
        XCTAssertEqual(coord.steps[0].status, .done)
        XCTAssertEqual(coord.terminal, .completed)
    }

    // MARK: t5b — .busy that stays failing on the retry aborts (proves the retry is bounded to one)

    func testBusyRetryStillFailingAbortsWithoutSecondRetry() async {
        let (coord, log) = makeCoordinator(limitOutcomes: [.busy, .busy])
        await coord.run()
        XCTAssertEqual(log.calls, ["limit", "waitIdle", "limit"], "exactly one retry — never a second")
        if case .aborted(let step, _) = coord.terminal { XCTAssertEqual(step, 1) } else { XCTFail() }
    }

    // MARK: t6 — a legacy-plist unregister error is swallowed; teardown continues

    func testLegacyDaemonUnregisterErrorIsSwallowed() async {
        let (coord, log) = makeCoordinator(legacyDaemonError: err("legacy gone"))
        await coord.run()
        XCTAssertEqual(log.calls,
                       ["limit", "energy", "schedule", "daemon.primary", "daemon.legacy", "login", "residue"],
                       "the legacy error must not stop login/residue")
        XCTAssertEqual(coord.steps[3].status, .done, "step 4 succeeds on the primary; the legacy error is best-effort")
        XCTAssertEqual(coord.terminal, .completed)
    }

    // MARK: t6b — a PRIMARY daemon failure records .failed but does NOT abort steps 5–6

    func testPrimaryDaemonFailureContinuesTeardown() async {
        let (coord, log) = makeCoordinator(primaryDaemonError: err("smappservice denied"))
        await coord.run()
        XCTAssertEqual(log.calls,
                       ["limit", "energy", "schedule", "daemon.primary", "daemon.legacy", "login", "residue"])
        if case .failed = coord.steps[3].status {} else { XCTFail("step 4 must record the primary failure") }
        XCTAssertEqual(coord.steps[4].status, .done, "login still unregisters")
        XCTAssertEqual(coord.steps[5].status, .done, "residue still removed")
        XCTAssertEqual(coord.terminal, .completed, "teardown steps 4–6 never abort")
    }

    // MARK: t6c — a login-item error records .failed but does NOT abort residue

    func testLoginUnregisterErrorContinuesToResidue() async {
        let (coord, log) = makeCoordinator(loginError: err("login denied"))
        await coord.run()
        XCTAssertEqual(log.calls,
                       ["limit", "energy", "schedule", "daemon.primary", "daemon.legacy", "login", "residue"])
        if case .failed = coord.steps[4].status {} else { XCTFail("step 5 records the login failure") }
        XCTAssertEqual(coord.steps[5].status, .done, "residue still removed after a login-unregister failure")
        XCTAssertEqual(coord.terminal, .completed)
    }

    // MARK: t7 — the terminal state reflects the per-step statuses (happy + aborted vectors)

    func testTerminalStateReflectsPerStepStatuses() async {
        let (happy, _) = makeCoordinator()
        await happy.run()
        XCTAssertEqual(happy.steps.count, 6)
        XCTAssertEqual(happy.steps.map(\.status), Array(repeating: .done, count: 6))
        XCTAssertEqual(happy.terminal, .completed)

        let (aborted, _) = makeCoordinator(scheduleOK: false)
        await aborted.run()
        XCTAssertEqual(aborted.steps[0].status, .done)
        XCTAssertEqual(aborted.steps[1].status, .done)
        if case .failed = aborted.steps[2].status {} else { XCTFail() }
        XCTAssertEqual(aborted.steps[3...].map(\.status), Array(repeating: .pending, count: 3))
    }

    // MARK: t8 — run() is idempotent; a second call after completion does nothing

    func testRunIsIdempotentAfterCompletion() async {
        let (coord, log) = makeCoordinator()
        await coord.run()
        let firstCalls = log.calls
        await coord.run()
        XCTAssertEqual(log.calls, firstCalls, "a second run() after completion must be a no-op")
        XCTAssertEqual(coord.terminal, .completed)
    }

    // MARK: t8b — run() after an ABORT is also a no-op (retry needs a fresh instance)

    func testRunAfterAbortIsNoOp() async {
        let (coord, log) = makeCoordinator(scheduleOK: false)   // aborts at step 3
        await coord.run()
        let afterAbort = log.calls
        if case .aborted = coord.terminal {} else { XCTFail("must be aborted at step 3") }
        await coord.run()
        XCTAssertEqual(log.calls, afterAbort, "a re-run after abort is a no-op — a retry needs a fresh coordinator")
    }

    // MARK: t9 — a DEGRADED (as-set, read-back unavailable) restore is still success → teardown proceeds

    func testDegradedAppliedUnconfirmedRestoreProceeds() async {
        // RISK-1 / the success family: `.appliedUnconfirmed` means the Set physically landed but the
        // read-back was unavailable (degraded). didWrite is true, so the limit IS restored and the
        // teardown MUST proceed — never abort a degraded-but-written restore.
        let (coord, log) = makeCoordinator(limitOutcomes: [.appliedUnconfirmed])
        await coord.run()
        XCTAssertEqual(log.calls,
                       ["limit", "energy", "schedule", "daemon.primary", "daemon.legacy", "login", "residue"])
        XCTAssertEqual(coord.steps[0].status, .done)
        XCTAssertEqual(coord.terminal, .completed)
    }

    // MARK: t10 — the manual-residue checklist copy for the pmset-repeat item is pinned
    //
    // Audit 2026-09 §2.H rank 1: `pmset repeat` is the ONE lever the app writes that has no System
    // Settings surface, so on a drag-to-Trash removal it is both harmful and invisible. The completed
    // panel discloses it as item 1. These assertions exist so the disclosure cannot be silently
    // watered down or the recovery command mistyped — the command has to be exactly runnable.

    func testRepeatingScheduleResidueDisclosureIsPinned() {
        XCTAssertEqual(UninstallCoordinator.repeatingScheduleInspectCommand, "pmset -g sched")
        XCTAssertEqual(UninstallCoordinator.repeatingScheduleRecoveryCommand, "sudo pmset repeat cancel")

        let notice = UninstallCoordinator.repeatingScheduleResidueNotice
        XCTAssertTrue(notice.contains(UninstallCoordinator.repeatingScheduleInspectCommand),
                      "the notice must name the ONLY way to see a repeating schedule")
        XCTAssertTrue(notice.contains("no System Settings page"),
                      "the whole reason this item leads the checklist is that it is invisible in Settings")
        XCTAssertFalse(UninstallCoordinator.repeatingScheduleRecoveryCommand.contains("\u{2019}"),
                       "no curly quotes in a command the user copy-pastes into a shell")
        XCTAssertFalse(notice.isEmpty)
    }

    // MARK: t11 — the step-4 failure copy must not claim that removing the app undoes settings
    //
    // The old wording ("Removing the app still stops it") was true of the daemon PROCESS and false of
    // everything the app had written; a future reader could build on the wrong premise.

    func testDaemonUnregisterFailureCopyDoesNotClaimSettingsAreUndone() async {
        let (coord, _) = makeCoordinator(primaryDaemonError: err("boom"))
        await coord.run()
        guard case .failed(let reason) = coord.steps[3].status else {
            return XCTFail("step 4 must record the primary-unregister failure")
        }
        XCTAssertTrue(reason.contains("doesn’t undo settings"),
                      "the copy must say removal stops the helper but does not undo settings")
        XCTAssertFalse(reason.contains("still stops it"),
                       "the retired wording implied removal was sufficient — it is not")
        XCTAssertEqual(coord.terminal, .completed, "a step-4 failure still never aborts the teardown")
    }
}
