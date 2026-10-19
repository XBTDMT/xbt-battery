import XCTest

/// WI-N1: the runner's classification, eager-fingerprint kill, timeout SIGTERM/SIGKILL path, and
/// FIFO serialization — all against the scripted mock process layer. Deterministic: no real
/// sleeps; the MockSleeper only "elapses" when a test fires it.
final class ShortcutsRunnerTests: XCTestCase {

    private func makeRunner(_ processes: [MockShortcutProcess])
    -> (ShortcutsRunner, MockShortcutProcessFactory, MockSleeper) {
        let factory = MockShortcutProcessFactory(processes)
        let sleeper = MockSleeper()
        return (ShortcutsRunner(factory: factory, sleeper: sleeper), factory, sleeper)
    }

    // MARK: - plain classifications

    func testExitZeroClassifiesSuccessWithStdout() async {
        let p = MockShortcutProcess()
        p.stdoutText = "ok"
        let (runner, _, _) = makeRunner([p])
        let task = Task { await runner.run(name: "Battery Limit 80") }
        p.exit(code: 0)
        let outcome = await task.value
        XCTAssertEqual(outcome, .success(stdout: "ok"))
    }

    func testNonzeroExitClassifiesFailedWithStderrTail() async {
        let p = MockShortcutProcess()
        let (runner, _, _) = makeRunner([p])
        let task = Task { await runner.run(name: "Battery Limit 80") }
        p.emitStderr("some unexpected error")
        p.exit(code: 4)
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed(exitCode: 4, stderrTail: "some unexpected error"))
    }

    func testBinaryAbsentClassifiedWithoutSpawning() async {
        let (runner, factory, _) = makeRunner([])
        factory.binaryExists = false
        let outcome = await runner.run(name: "Battery Limit 80")
        XCTAssertEqual(outcome, .shortcutsBinaryAbsent)
        XCTAssertTrue(factory.made.isEmpty, "no process may be created when the binary is absent")
    }

    func testLaunchThrowClassifiesLaunchFailed() async {
        let p = MockShortcutProcess()
        p.launchError = NSError(domain: NSPOSIXErrorDomain, code: 13)
        let (runner, _, _) = makeRunner([p])
        let outcome = await runner.run(name: "Battery Limit 80")
        guard case .launchFailed = outcome else {
            return XCTFail("expected .launchFailed, got \(outcome)")
        }
    }

    // MARK: - eager fingerprint classification (sec 2, VERIFIED hang behavior)

    func testMissingShortcutClassifiedEagerlyFromLivePipeAndKilled() async {
        // The verified on-device behavior: the error line appears, then the process HANGS.
        // The runner must classify-and-kill immediately — NOT wait out the 15 s timeout.
        let p = MockShortcutProcess()
        let (runner, _, sleeper) = makeRunner([p])
        let task = Task { await runner.run(name: "Battery Limit 80") }
        p.emitStderr("Error: Couldn't find shortcut named Battery Limit 80")
        // Note: p.exit() is never scripted — the process hangs until killed.
        let outcome = await task.value
        XCTAssertEqual(outcome, .missingShortcut)
        XCTAssertTrue(p.forceKilled, "the hanging process must be killed at classification time")
        // The 15 s timeout was requested by the racer but never fired by this test — proving
        // classification did not depend on the timeout elapsing.
        let req = await sleeper.nextRequest()
        XCTAssertEqual(req.seconds, ShortcutsRunner.invocationTimeout)
    }

    func testMissingShortcutFingerprintOnRealExitStillClassifies() async {
        // Defensive: if a future OS makes the missing-shortcut error EXIT instead of hang,
        // the same fingerprint must still win over .failed.
        let p = MockShortcutProcess()
        let (runner, _, _) = makeRunner([p])
        let task = Task { await runner.run(name: "Battery Limit 80") }
        p.emitStderr("Error: Couldn't find shortcut named X")
        p.exit(code: 1)
        let outcome = await task.value
        XCTAssertEqual(outcome, .missingShortcut)
    }

    // MARK: - timeout path (sec 2: SIGTERM → 2 s grace → SIGKILL → .automationBlocked)

    func testSilentBlockTimesOutTermResistantGetsSigkillAndAutomationBlocked() async {
        // VERIFIED silent-TCC observable: indefinite hang, EMPTY stderr, no prompt.
        let p = MockShortcutProcess()
        p.exitsOnTerminate = false   // TERM-resistant hang — must escalate to SIGKILL
        let (runner, _, sleeper) = makeRunner([p])
        let task = Task { await runner.run(name: "Battery Limit 80") }

        let timeout = await sleeper.nextRequest()
        XCTAssertEqual(timeout.seconds, ShortcutsRunner.invocationTimeout)
        await sleeper.fire(timeout)                       // 15 s elapse

        let grace = await sleeper.nextRequest()
        XCTAssertEqual(grace.seconds, ShortcutsRunner.sigkillGrace)
        await sleeper.fire(grace)                         // 2 s grace elapses

        let outcome = await task.value
        XCTAssertTrue(p.terminated, "SIGTERM must be attempted first")
        XCTAssertTrue(p.forceKilled, "TERM-resistant process must get SIGKILL after the grace")
        XCTAssertEqual(outcome, .automationBlocked(stderrTail: ""))
    }

    func testTimeoutWhereSigtermLandsSkipsSigkill() async {
        let p = MockShortcutProcess()
        p.exitsOnTerminate = true    // SIGTERM works
        let (runner, _, sleeper) = makeRunner([p])
        let task = Task { await runner.run(name: "Battery Limit 80") }

        let timeout = await sleeper.nextRequest()
        await sleeper.fire(timeout)
        let grace = await sleeper.nextRequest()
        await sleeper.fire(grace)

        let outcome = await task.value
        XCTAssertTrue(p.terminated)
        XCTAssertFalse(p.forceKilled, "no SIGKILL when SIGTERM already landed")
        XCTAssertEqual(outcome, .automationBlocked(stderrTail: ""))
    }

    func testFingerprintClassifierMatchesWithinJoinedTail() {
        // The timeout/exit paths classify over the JOINED stderr tail — the fingerprint must
        // match embedded in surrounding lines, and unknown text must classify as nil.
        XCTAssertEqual(ShortcutStderrFingerprint.classify(line: "x\nError: Couldn't find shortcut\ny"),
                       .missingShortcut)
        XCTAssertNil(ShortcutStderrFingerprint.classify(line: "some other failure"))
        XCTAssertNil(ShortcutStderrFingerprint.classify(line: ""))
    }

    // MARK: - serialization (sec 2: ONE invocation at a time, FIFO, busy flag)

    func testSecondRunWaitsUntilFirstFinishes() async {
        let p1 = MockShortcutProcess()
        let p2 = MockShortcutProcess()
        let (runner, factory, _) = makeRunner([p1, p2])

        let first = Task { await runner.run(name: "Battery Limit 100") }
        // Ensure the first invocation actually occupies the slot before queueing the second.
        while factory.made.isEmpty { await Task.yield() }

        let second = Task { await runner.run(name: "Battery Limit 80") }
        // Give the second run every chance to (incorrectly) spawn while the first is in flight.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(factory.made.count, 1, "second process must not spawn while first is in flight")

        let busy = await runner.isBusy
        XCTAssertTrue(busy, "runner must report busy while an invocation is in flight")

        p1.exit(code: 0)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .success(stdout: ""))

        // Now the queued second run may spawn and complete.
        while factory.made.count < 2 { await Task.yield() }
        p2.exit(code: 0)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .success(stdout: ""))

        let stillBusy = await runner.isBusy
        XCTAssertFalse(stillBusy, "busy must clear once the queue drains")
    }

    func testListUsesSameSerializedPath() async {
        let p = MockShortcutProcess()
        p.stdoutText = "Battery Limit 80\nBattery Limit Get\n"
        let (runner, _, _) = makeRunner([p])
        let task = Task { await runner.list() }
        p.exit(code: 0)
        let outcome = await task.value
        XCTAssertEqual(outcome, .success(stdout: "Battery Limit 80\nBattery Limit Get\n"))
    }
}
