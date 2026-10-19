import XCTest
import Shared
@testable import Battery

/// The in-app helper restart (no sudo). Mechanism proven on-device 2026-09-09: a rebuild replaces the
/// embedded helper file, the running daemon's executable no longer matches (proc_pidpath ENOENT or
/// errSecCSStaticCodeChanged), and the app's audit-token pin refuses it. `SMAppService.unregister()`
/// boots the stale process out and a later `register()` bootstraps the new file — but a `register()` in
/// the same instant is refused ("Job is not allowed to bootstrap") while Background Task Management is
/// still writing the unregister, so the register is retried. These tests lock the decision logic; the
/// live SMAppService adapter is behind the `DaemonService` seam and never runs here.
@MainActor
final class HelperRestartTests: XCTestCase {

    /// A daemon whose registration comes back `.enabled` only on the Nth `register()` after an
    /// `unregister()` — the shape the machine actually showed.
    private final class RecyclingDaemon: DaemonService {
        var statusValue: DaemonServiceStatus
        var enableOnRegisterAttempt: Int
        var registerCalls = 0, unregisterCalls = 0
        var registerError: Error?, unregisterError: Error?
        init(_ s: DaemonServiceStatus, enableOnRegisterAttempt: Int = 1) {
            statusValue = s; self.enableOnRegisterAttempt = enableOnRegisterAttempt
        }
        func register() throws {
            registerCalls += 1
            if let registerError { throw registerError }
            statusValue = registerCalls >= enableOnRegisterAttempt ? .enabled : .notRegistered
        }
        func unregister() throws {
            unregisterCalls += 1
            if let unregisterError { throw unregisterError }
            statusValue = .notRegistered
        }
    }

    private struct StubProbe: HelperDaemonProbing {
        var image: HelperDaemonImage
        func read() -> HelperDaemonImage { image }
    }

    private struct Boom: Error {}

    private let built = Date(timeIntervalSince1970: 1_788_850_699)
    private let older = Date(timeIntervalSince1970: 1_788_467_534)
    private let newer = Date(timeIntervalSince1970: 1_788_900_000)
    private var staleImage: HelperDaemonImage { HelperDaemonImage(daemonStartedAt: older, bundledBuiltAt: built) }
    private var freshImage: HelperDaemonImage { HelperDaemonImage(daemonStartedAt: newer, bundledBuiltAt: built) }

    /// The between-attempt pause is a seam; tests count it instead of sleeping.
    private final class PauseCounter: @unchecked Sendable {
        var seconds: [TimeInterval] = []
        func pause(_ s: TimeInterval) async { seconds.append(s) }
    }

    private func model(_ daemon: RecyclingDaemon, registration: HelperUIState = .enabled,
                       image: HelperDaemonImage, pauses: PauseCounter = PauseCounter()) -> HelperHealthModel {
        HelperHealthModel(service: daemon, launchVerdict: registration, probe: StubProbe(image: image),
                          pause: { await pauses.pause($0) })
    }

    // MARK: the policy — when launch may try on its own

    func testAutoRestartOnlyForAStaleApprovedDaemonNotYetAttempted() {
        XCTAssertTrue(HelperHealthModel.shouldAutoRestart(registration: .enabled, image: staleImage, alreadyAttempted: false))
        XCTAssertFalse(HelperHealthModel.shouldAutoRestart(registration: .enabled, image: freshImage, alreadyAttempted: false),
                       "a current daemon must never be recycled")
        XCTAssertFalse(HelperHealthModel.shouldAutoRestart(registration: .enabled, image: staleImage, alreadyAttempted: true),
                       "bounded to one attempt per launch")
        for reg in [HelperUIState.requiresApproval, .notRegistered, .notFound, .needsManualReset, .signatureMismatch] {
            XCTAssertFalse(HelperHealthModel.shouldAutoRestart(registration: reg, image: staleImage, alreadyAttempted: false),
                           "\(reg) has a different fix; unregistering here would only lose state")
        }
    }

    // MARK: the per-attempt step

    func testRegisterStepReadsTheStatus() {
        XCTAssertEqual(HelperHealthModel.registerStep(status: .enabled, attempt: 3, maxAttempts: 10), .done(.restarted(attempts: 3)))
        XCTAssertEqual(HelperHealthModel.registerStep(status: .requiresApproval, attempt: 1, maxAttempts: 10), .done(.requiresApproval))
        XCTAssertEqual(HelperHealthModel.registerStep(status: .notRegistered, attempt: 1, maxAttempts: 10), .retry)
        XCTAssertEqual(HelperHealthModel.registerStep(status: .notFound, attempt: 9, maxAttempts: 10), .retry)
        if case .done(.failed) = HelperHealthModel.registerStep(status: .notRegistered, attempt: 10, maxAttempts: 10) {} else {
            XCTFail("the last attempt must give up honestly, not loop")
        }
    }

    // MARK: the restart itself

    // The on-device shape: unregister, then the first register() a second later succeeds.
    func testRestartUnregistersThenRegistersAndReportsAttempts() async {
        let daemon = RecyclingDaemon(.enabled, enableOnRegisterAttempt: 1)
        let pauses = PauseCounter()
        let m = model(daemon, image: staleImage, pauses: pauses)
        let outcome = await m.restartDaemon()
        XCTAssertEqual(outcome, .restarted(attempts: 1))
        XCTAssertEqual(daemon.unregisterCalls, 1)
        XCTAssertEqual(daemon.registerCalls, 1)
        XCTAssertEqual(pauses.seconds, [HelperHealthModel.registerRetryInterval], "one pause BEFORE the first register — the same-instant register is the one smd refuses")
        XCTAssertEqual(m.lastRestart, .restarted(attempts: 1))
        XCTAssertEqual(m.registration, .enabled, "refresh() after the restart re-reads the live status")
        XCTAssertFalse(m.restartInProgress)
    }

    // BTM's unregister write lands a few seconds later: early registers come back notRegistered and
    // are retried, one pause apart, until one sticks.
    func testRestartRetriesRegisterUntilTheRegistrationComesBack() async {
        let daemon = RecyclingDaemon(.enabled, enableOnRegisterAttempt: 4)
        let pauses = PauseCounter()
        let m = model(daemon, image: staleImage, pauses: pauses)
        let outcome = await m.restartDaemon()
        XCTAssertEqual(outcome, .restarted(attempts: 4))
        XCTAssertEqual(daemon.registerCalls, 4)
        XCTAssertEqual(pauses.seconds.count, 4)
    }

    func testRestartGivesUpAfterTheBudget() async {
        let daemon = RecyclingDaemon(.enabled, enableOnRegisterAttempt: .max)
        let m = model(daemon, image: staleImage)
        let outcome = await m.restartDaemon()
        XCTAssertEqual(daemon.registerCalls, HelperHealthModel.registerAttempts)
        guard case .failed(let why) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertTrue(why.contains("\(HelperHealthModel.registerAttempts)"), "the failure names how many tries ran: \(why)")
    }

    func testRestartReportsRequiresApprovalWithoutRetrying() async {
        final class Unapproving: DaemonService {
            var statusValue: DaemonServiceStatus = .enabled
            var registerCalls = 0
            func register() throws { registerCalls += 1; statusValue = .requiresApproval }
            func unregister() throws { statusValue = .notRegistered }
        }
        let daemon = Unapproving()
        let m = HelperHealthModel(service: daemon, launchVerdict: .enabled, probe: StubProbe(image: staleImage), pause: { _ in })
        let outcome = await m.restartDaemon()
        XCTAssertEqual(outcome, .requiresApproval)
        XCTAssertEqual(daemon.registerCalls, 1, "an approval prompt is the owner's move; hammering register() would not help")
        XCTAssertEqual(m.registration, .requiresApproval)
    }

    func testUnregisterFailureStopsBeforeAnyRegister() async {
        let daemon = RecyclingDaemon(.enabled)
        daemon.unregisterError = Boom()
        let m = model(daemon, image: staleImage)
        let outcome = await m.restartDaemon()
        guard case .failed(let why) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertTrue(why.hasPrefix("unregister:"))
        XCTAssertEqual(daemon.registerCalls, 0)
    }

    func testAThrowingRegisterIsRetriedNotFatal() async {
        final class ThrowsOnce: DaemonService {
            var statusValue: DaemonServiceStatus = .enabled
            var registerCalls = 0
            func register() throws {
                registerCalls += 1
                if registerCalls == 1 { throw Boom() }
                statusValue = .enabled
            }
            func unregister() throws { statusValue = .notRegistered }
        }
        let daemon = ThrowsOnce()
        let m = HelperHealthModel(service: daemon, launchVerdict: .enabled, probe: StubProbe(image: staleImage), pause: { _ in })
        let outcome = await m.restartDaemon()
        XCTAssertEqual(outcome, .restarted(attempts: 2))
    }

    // MARK: the launch-time attempt — once, and only when stale

    func testAutoRestartRunsOncePerLaunch() async {
        let daemon = RecyclingDaemon(.enabled)
        let m = model(daemon, image: staleImage)
        let first = await m.autoRestartIfStale()
        XCTAssertEqual(first, .restarted(attempts: 1))
        let second = await m.autoRestartIfStale()
        XCTAssertNil(second, "a second launch-time attempt in the same process is a loop, not a fix")
        XCTAssertEqual(daemon.unregisterCalls, 1)
    }

    func testAutoRestartDoesNothingForAFreshDaemon() async {
        let daemon = RecyclingDaemon(.enabled)
        let m = model(daemon, image: freshImage)
        let outcome = await m.autoRestartIfStale()
        XCTAssertNil(outcome)
        XCTAssertEqual(daemon.unregisterCalls, 0, "never unregister a daemon that is not stale")
    }

    func testAutoRestartDoesNothingWhenNotApproved() async {
        let daemon = RecyclingDaemon(.requiresApproval)
        let m = model(daemon, registration: .requiresApproval, image: staleImage)
        let outcome = await m.autoRestartIfStale()
        XCTAssertNil(outcome)
        XCTAssertEqual(daemon.unregisterCalls, 0)
    }

    // MARK: copy — the stale verdicts offer the button; the others do not

    func testOnlyStaleVerdictsOfferTheRestartButton() {
        let all: [HelperHealthVerdict] = [.registrationProblem(.requiresApproval), .unreachableStale, .unreachable,
                                          .stale, .responding, .notYetContacted]
        for v in all {
            let note = HelperHealthCopy.note(for: v, lastReply: nil)
            let expected = (v == .unreachableStale || v == .stale)
            XCTAssertEqual(note.canRestart, expected, "\(v)")
            if expected { XCTAssertNotNil(note.remedy, "the sudo command stays as the manual fallback") }
        }
    }
}
