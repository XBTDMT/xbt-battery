import XCTest
import Shared

// app/App/HelperClient.swift, app/Privileged/EnergyModeController.swift and
// app/Privileged/AutoEnergyMode.swift all compile into THIS host-app-free target → visible without
// import. No NSXPC connection is ever opened here.

/// A `SetWatchdogScheduler` test double: records what the controller armed instead of arming a real
/// timer, so the backstop can be TRIPPED deterministically without burning 25s of wall clock. Shared by
/// this file and `EnergyModeControllerTests`.
@MainActor
final class ManualSetWatchdog {
    private(set) var armed: [(delay: TimeInterval, fire: @MainActor @Sendable () -> Void)] = []

    /// Hand this to `EnergyModeController(setter:setTimeout:scheduleWatchdog:)`.
    var schedule: EnergyModeController.SetWatchdogScheduler {
        { [self] delay, fire in armed.append((delay: delay, fire: fire)) }
    }

    var armedCount: Int { armed.count }
    var lastDelay: TimeInterval? { armed.last?.delay }

    /// Trip the OLDEST pending deadline (FIFO — deadlines expire in the order they were armed).
    func fireFirst() {
        guard !armed.isEmpty else { return XCTFail("no watchdog was armed") }
        armed.removeFirst().fire()
    }

    /// Trip every pending deadline, oldest first.
    func fireAll() {
        let pending = armed
        armed = []
        for entry in pending { entry.fire() }
    }
}

/// An `EnergyModeSetter` that models the B3 defect directly: it takes the call and NEVER replies.
/// (`HelperClient` before this fix had no bound on that; a wedged helper produces neither reply nor
/// error handler.) Completions are held so a LATE reply can be delivered after the deadline, to prove
/// the exactly-once arbitration.
@MainActor
final class NeverReplyingSetter: EnergyModeSetter {
    private(set) var callCount = 0
    private var held: [@Sendable (Result<String, HelperClientError>) -> Void] = []

    func setEnergyMode(mode: Int, source: Int,
                       completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
        callCount += 1
        held.append(completion)
    }

    /// Deliver the oldest held reply — the "late reply" that races the watchdog.
    func deliverOldest(_ result: Result<String, HelperClientError>) {
        guard !held.isEmpty else { return XCTFail("no held reply to deliver") }
        held.removeFirst()(result)
    }

    var heldCount: Int { held.count }
}

/// B3 — no XPC call had a timeout, so any state machine that latched a bit before the call and cleared
/// it only in the completion could be wedged FOREVER by one lost reply. This suite pins the two halves
/// of the fix that can be exercised host-app-free:
///
///  1. `HelperCallGate` — the exactly-once arbitration `HelperClient` puts between the reply, the proxy
///     error handler and the deadline (the client's own call sites are correct by inspection over it;
///     driving them would require a real privileged NSXPC connection).
///  2. `AutoEnergyModeRunner.inFlight` — the automation's own latch, which is cleared only by the
///     controller's completion. It recovers through the controller's backstop, with no change to the
///     runner itself.
///
/// NOTE for a future reader: this does NOT contradict the 2026-06 recon's "no swallowed failure on a
/// real path" dismissal of HelperClient. That finding was about failures being REPORTED honestly when
/// they arrive. This one is about an outcome that never arrives at all.
@MainActor
final class HelperClientWatchdogTests: XCTestCase {

    // MARK: - The exactly-once gate

    func testGate_claimSucceedsExactlyOnce() {
        let gate = HelperCallGate()
        XCTAssertFalse(gate.isSettled)
        XCTAssertTrue(gate.claim(), "the first party to arrive settles the call")
        XCTAssertTrue(gate.isSettled)
        XCTAssertFalse(gate.claim(), "a late reply must NOT re-settle it")
        XCTAssertFalse(gate.claim(), "and neither must anything after that")
    }

    func testGate_onlyOneWinnerUnderConcurrentClaims() {
        // The three parties arrive on three different queues; the gate is the only thing standing
        // between them and a double-invoked completion.
        let gate = HelperCallGate()
        let winners = WinCounter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if gate.claim() { winners.bump() }
        }
        XCTAssertEqual(winners.count, 1, "exactly one of {reply, error, timeout} may settle a call")
    }

    /// Locks the DELIBERATE split between the two bounds (and the reasoning behind it).
    func testWatchdogBounds_samplingIsBoundedAboveTheHelpersOwnCeiling() {
        // The helper's own worst case for one bounded spawn: 30s hard timeout + 2s SIGTERM grace +
        // 2s SIGKILL grace.
        let helperSpawnCeiling = TaskEnergyCommand.spawnTimeoutSeconds + 2 * TaskEnergyCommand.spawnGraceSeconds
        XCTAssertGreaterThan(HelperClient.samplingCallTimeout, helperSpawnCeiling,
                             "powermetrics is ALLOWED to run 30s — the sampling bound must sit above the "
                             + "helper's own, or it would preempt a case the helper already answers honestly")
        XCTAssertLessThan(HelperClient.fastCallTimeout, helperSpawnCeiling,
                          "a pmset write is sub-second; bounding below the ceiling costs nothing because a "
                          + "spawn that really burns 30s replies error:set-failed — the same honest failure")
        XCTAssertLessThan(HelperClient.fastCallTimeout, EnergyModeController.defaultSetTimeout,
                          "the production conformance must always settle before the controller's backstop")
    }

    // MARK: - The automation's inFlight latch recovers (no change to the runner)

    private func makeRunner(setter: AutoEnergyModeSetting,
                            conditions: @escaping @MainActor () -> AutoEnergyConditions) -> AutoEnergyModeRunner {
        let suite = "HelperClientWatchdogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AutoEnergyModeRunner(setter: setter, conditions: conditions,
                                    defaults: defaults, enabledKey: "auto.energy.enabled")
    }

    func testAutoRunner_lostReply_clearsInFlightAndTellsTheTruth() {
        // The defect: `driveIfAllowed` sets inFlight BEFORE the call and clears it only in the
        // completion, so a lost reply stops the automation silently while `autoNote` still reads as if
        // it were working.
        let setter = NeverReplyingSetter()
        let watchdog = ManualSetWatchdog()
        let controller = EnergyModeController(setter: setter, setTimeout: 25,
                                              scheduleWatchdog: watchdog.schedule)
        var soc = 50
        let runner = makeRunner(setter: controller, conditions: {
            AutoEnergyConditions(thermal: .nominal, soc: soc, plugged: false,
                                 highAvailable: false, currentSourceMode: .automatic,
                                 inactiveSourceMode: .automatic)
        })
        runner.enabled = true                       // seeds last[battery] = .automatic, drives nothing
        XCTAssertEqual(setter.callCount, 0)

        soc = 15
        runner.evaluate()                           // edge → drive .low → the helper never replies
        XCTAssertEqual(setter.callCount, 1)
        XCTAssertTrue(controller.isBusy, "the set is in flight")

        // While wedged the automation is stuck: a newer edge cannot drive (single-in-flight).
        runner.evaluate()
        XCTAssertEqual(setter.callCount, 1, "this is the wedge — before the fix it lasted forever")

        watchdog.fireFirst()                        // the deadline expires
        XCTAssertFalse(controller.isBusy, "the backstop frees the controller")
        XCTAssertTrue(runner.autoNote?.localizedCaseInsensitiveContains("helper") ?? false,
                      "and the note stops claiming the automation is working")
        XCTAssertEqual(runner.lastBattery, .automatic, "a timeout NEVER advances the baseline")

        // The automation is live again: the next external evaluation retries.
        runner.evaluate()
        XCTAssertEqual(setter.callCount, 2, "inFlight was cleared — the runner can drive again")
    }

    func testAutoRunner_lateReplyAfterTheDeadlineCannotResurrectTheSet() {
        // A reply that lost the race must not advance the baseline or re-publish a success note after
        // the runner has already been told the attempt failed.
        let setter = NeverReplyingSetter()
        let watchdog = ManualSetWatchdog()
        let controller = EnergyModeController(setter: setter, setTimeout: 25,
                                              scheduleWatchdog: watchdog.schedule)
        var soc = 50
        let runner = makeRunner(setter: controller, conditions: {
            AutoEnergyConditions(thermal: .nominal, soc: soc, plugged: false,
                                 highAvailable: false, currentSourceMode: .automatic,
                                 inactiveSourceMode: .automatic)
        })
        runner.enabled = true
        soc = 15
        runner.evaluate()
        watchdog.fireFirst()
        let noteAfterTimeout = runner.autoNote

        setter.deliverOldest(.success("1"))         // the reply finally arrives — too late
        XCTAssertEqual(runner.autoNote, noteAfterTimeout, "a loser cannot rewrite the outcome")
        XCTAssertEqual(runner.lastBattery, .automatic, "and cannot advance the baseline")
        XCTAssertEqual(controller.lastReadback, "—", "nor publish a read-back for a set we gave up on")
    }
}

/// Thread-safe counter for the concurrent-claim proof.
private final class WinCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
