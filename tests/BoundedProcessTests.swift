import XCTest

/// AUDIT B6 CONVERGENCE — the app had THREE subprocess-spawn implementations of differing safety.
/// `PmsetProbe` was hardened by B6; these tests hold the OTHER two to the same contract and pin the
/// shared `BoundedProcess` primitive they now converge on.
///
/// The B6 mechanism, restated because it is the whole reason this file exists: a pipe holds ~64 KB.
/// A child that writes past that BLOCKS on the write, so it never exits and never closes stdout —
/// and the parent's `readDataToEndOfFile()` on stdout then blocks FOREVER. Any spawn that assigns a
/// `Pipe()` to `standardError` and never reads it has that wedge latent.

// MARK: - the shared primitive

final class BoundedProcessTests: XCTestCase {

    /// THE RED TEST FOR B6 HALF ONE, at the primitive. The child writes 200 KB to stderr — far past a
    /// pipe's ~64 KB buffer — and only then writes stdout. With an assigned-but-unread stderr pipe the
    /// child blocks on its stderr write, never closes stdout, and this call never returns. Draining
    /// both pipes concurrently is what makes it return at all.
    func testAFloodOnStderrDoesNotWedgeTheChild() {
        let r = BoundedProcess.run(executable: "/bin/sh",
                                   arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' 'x' >&2; echo done"],
                                   timeout: 10)
        XCTAssertTrue(r.succeeded, "the child must not deadlock against an undrained stderr pipe")
        XCTAssertFalse(r.killed, "it must finish on its own, not be killed by the watchdog")
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "done\n")
        XCTAssertEqual(r.stderr.count, 200_000, "stderr must be drained in full, not truncated")
    }

    /// `.discard` is the OTHER safe answer — /dev/null is an fd that cannot fill. What must never
    /// exist is a third case that assigns a pipe and does not read it.
    func testAFloodOnStderrDoesNotWedgeTheChildUnderDiscard() {
        let r = BoundedProcess.run(executable: "/bin/sh",
                                   arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' 'x' >&2; echo done"],
                                   timeout: 10, stderr: .discard)
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "done\n")
        XCTAssertTrue(r.stderr.isEmpty, "discarded stderr is not captured")
    }

    /// A flood on BOTH pipes at once — the case a single-pipe drain still deadlocks on.
    func testAFloodOnBothPipesDoesNotWedgeTheChild() {
        let r = BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' 'e' >&2; head -c 200000 /dev/zero | tr '\\0' 'o'"],
            timeout: 10)
        XCTAssertTrue(r.succeeded, "neither pipe may wedge the other")
        XCTAssertEqual(r.stdout.count, 200_000)
        XCTAssertEqual(r.stderr.count, 200_000)
    }

    /// THE RED TEST FOR B6 HALF TWO. A child that never exits is killed at the bound instead of
    /// parking a global-queue thread — and the caller can TELL it was killed.
    func testAWedgedChildIsBoundedAndKilled() {
        let start = Date()
        let r = BoundedProcess.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.4)
        XCTAssertTrue(r.killed)
        XCTAssertFalse(r.succeeded, "a killed child's partial output must never count as a complete read")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "the run must be bounded, not open-ended")
    }

    /// `killed` is a FACT — "the watchdog claimed the verdict" — not an inference from
    /// `terminationReason`. This child HANDLES SIGTERM and exits ZERO, so every signal-based proxy
    /// reports a clean exit; only the gate knows we killed it.
    func testAChildThatHandlesSIGTERMAndExitsZeroIsStillReportedKilled() {
        let start = Date()
        let r = BoundedProcess.run(executable: "/bin/sh",
                                   arguments: ["-c", "trap 'echo partial; exit 0' TERM; sleep 30 & wait"],
                                   timeout: 0.4)
        XCTAssertTrue(r.killed, "we signalled this child — a clean exit code does not undo that")
        XCTAssertFalse(r.succeeded, "so its partial stdout must not be accepted as a complete read")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "and the whole call must stay bounded")
    }

    /// THE THIRD WEDGE, found by the test above. EOF on stdout is NOT a bound: this child exits
    /// immediately, but the grandchild it backgrounds inherited a copy of the stdout pipe's WRITE
    /// end, so the pipe stays open for the grandchild's whole life. A `readDataToEndOfFile()` on the
    /// calling thread therefore blocks for 30 s against a 0.4 s bound — measured at 30.07 s before
    /// this fix, on a "bounded" primitive. Waiting on the CHILD's exit (not EOF) and giving the
    /// drains their own deadline is what actually bounds it.
    func testAGrandchildHoldingTheStdoutPipeCannotOutlastTheBound() {
        let start = Date()
        let r = BoundedProcess.run(executable: "/bin/sh",
                                   arguments: ["-c", "echo early; sleep 30 &"],
                                   timeout: 5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5,
                          "a backgrounded grandchild holding the write end must not extend the read")
        XCTAssertTrue(r.outputTruncated, "we gave up on the pipe — say so rather than implying EOF")
        XCTAssertFalse(r.succeeded, "a read we abandoned is not a complete read")
        XCTAssertEqual(r.exitCode, 0, "the child itself exited cleanly — that is a separate fact")
        // Chunked draining means the bytes that DID arrive are still recoverable.
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "early\n")
    }

    /// THE RECYCLED-PID INVARIANT. A child that finishes well inside the bound must be reported
    /// clean even though the watchdog still fires afterwards: the normal path claims the one-shot
    /// gate first, so the late watchdog signals NOTHING. An unconditional `DispatchWorkItem.cancel()`
    /// cannot promise this — `cancel()` is a no-op once the item has begun executing, and by then
    /// `waitUntilExit()` has already let Foundation reap the pid.
    func testAChildThatFinishesInTimeIsNeverSignalledByTheLateWatchdog() {
        let r = BoundedProcess.run(executable: "/bin/echo", arguments: ["hi"], timeout: 0.3)
        XCTAssertFalse(r.killed, "the normal path owns the verdict; the watchdog arrives to a settled gate")
        XCTAssertFalse(r.terminatedBySignal)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "hi\n")
        XCTAssertTrue(r.succeeded)
        // The watchdog is still pending here. Give it its deadline; nothing may change, and nothing
        // may crash — the pid it holds has already been reaped.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(r.succeeded)
    }

    func testALaunchFailureIsReportedNotCrashed() {
        let r = BoundedProcess.run(executable: "/nonexistent/binary/xyz", arguments: [], timeout: 1)
        XCTAssertTrue(r.launchFailed)
        XCTAssertFalse(r.succeeded)
        XCTAssertNil(r.exitCode)
        XCTAssertFalse(r.launchError.isEmpty, "the thrown error is the only artifact — keep it")
    }

    func testStderrAndExitCodeAreCarriedBackOnAFailedRun() {
        let r = BoundedProcess.run(executable: "/bin/sh",
                                   arguments: ["-c", "echo 'boom' >&2; exit 3"], timeout: 5)
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertFalse(r.succeeded)
        XCTAssertTrue(String(decoding: r.stderr, as: UTF8.self).contains("boom"))
        XCTAssertEqual(BoundedProcess.failureNote(command: "sh -c", result: r), "sh -c: exited 3 — boom")
    }

    /// A child that dies on its OWN signal is a failed run even though nobody killed it.
    func testAChildThatCrashesOnItsOwnSignalIsNotASuccess() {
        let r = BoundedProcess.run(executable: "/bin/sh",
                                   arguments: ["-c", "printf partial; kill -SEGV $$"], timeout: 5)
        XCTAssertFalse(r.killed, "we did not signal it")
        XCTAssertTrue(r.terminatedBySignal)
        XCTAssertFalse(r.succeeded, "its stdout is partial by definition")
    }

    // MARK: pure diagnostics

    func testFailureNoteIsNilOnSuccess() {
        let ok = BoundedProcessResult(stdout: Data(), stderr: Data(), exitCode: 0, killed: false,
                                      terminatedBySignal: false, outputTruncated: false,
                                      launchFailed: false, launchError: "", duration: 0.01)
        XCTAssertNil(BoundedProcess.failureNote(command: "x", result: ok))
    }

    func testFailureNoteNamesEachFailureShape() {
        func note(exitCode: Int32?, killed: Bool = false, signalled: Bool = false,
                  truncated: Bool = false, launchFailed: Bool = false,
                  launchError: String = "") -> String? {
            BoundedProcess.failureNote(command: "ioreg -l", result: BoundedProcessResult(
                stdout: Data(), stderr: Data(), exitCode: exitCode, killed: killed,
                terminatedBySignal: signalled, outputTruncated: truncated,
                launchFailed: launchFailed, launchError: launchError, duration: 0))
        }
        XCTAssertEqual(note(exitCode: nil, launchFailed: true, launchError: "no such file"),
                       "ioreg -l: could not launch — no such file")
        XCTAssertEqual(note(exitCode: 15, killed: true, signalled: true),
                       "ioreg -l: timed out and was killed")
        XCTAssertEqual(note(exitCode: 11, signalled: true), "ioreg -l: was terminated by a signal")
        XCTAssertEqual(note(exitCode: 0, truncated: true),
                       "ioreg -l: left its output pipe open past the drain grace (a backgrounded grandchild?)")
        XCTAssertEqual(note(exitCode: 3), "ioreg -l: exited 3")
    }

    func testFirstLineIsTheFirstNonBlankLineCapped() {
        XCTAssertEqual(BoundedProcess.firstLine("\n\n  boom  \nsecond\n"), "boom")
        XCTAssertEqual(BoundedProcess.firstLine(""), "")
        XCTAssertEqual(BoundedProcess.firstLine(String(repeating: "x", count: 500)).count, 200)
    }
}

// MARK: - path 2: ProcessProbe (app/Devices)

final class BoundedProcessProcessProbeTests: XCTestCase {

    /// The wedge, through the real seam. This path always routed stderr to `FileHandle.nullDevice`
    /// rather than to an unread `Pipe()`, so it was never wedgeable — but it now CAPTURES stderr, and
    /// this proves the capture is drained rather than merely assigned.
    func testAFloodOnStderrDoesNotWedgeTheProbe() async {
        let r = await ProcessProbe().run(
            "/bin/sh",
            args: ["-c", "head -c 200000 /dev/zero | tr '\\0' 'x' >&2; echo done"],
            timeout: 10)
        XCTAssertFalse(r.timedOut, "200 KB on stderr must not wedge the child against the parent")
        XCTAssertFalse(r.launchFailed)
        XCTAssertEqual(r.stdout, "done\n")
        XCTAssertEqual(r.stderr.count, 200_000, "stderr is captured AND drained, not assigned and dropped")
    }

    /// THE DEFECT THIS CUT FIXES. `timedOut` used to read `terminationReason == .uncaughtSignal` — a
    /// PROXY for the fact, not the fact. A child that installs a SIGTERM handler and exits 0 reports
    /// `.exit`, so the watchdog kill was invisible: `timedOut` came back FALSE and the partial stdout
    /// the child managed to flush was handed to `DeviceParsers.parseIoreg` as a complete read.
    ///
    /// RED before the fix (`timedOut == false`). GREEN after: the verdict is owned by whichever of
    /// {the normal path, the watchdog} claims the gate FIRST, so a killed child is reported killed
    /// regardless of how it chose to die.
    func testAKilledChildsPartialStdoutIsNotAcceptedAsACompleteRead() async {
        // Prints, then parks. On SIGTERM it runs its trap and exits ZERO — a clean exit code on a
        // child we killed. (`sleep` backgrounded + `wait` so the shell can service the signal.)
        let r = await ProcessProbe().run(
            "/bin/sh", args: ["-c", "trap 'echo partial; exit 0' TERM; sleep 30 & wait"], timeout: 0.4)
        XCTAssertTrue(r.timedOut,
                      "a child we SIGTERMed is killed even when it exits 0 — its stdout is partial")
        XCTAssertLessThan(r.duration, 5, "and the read must still be bounded")
    }

    /// The grandchild-on-the-pipe wedge, through the real seam. `DeviceBatterySource` reads exactly
    /// one bit — `timedOut` — to decide whether the ioreg tree is complete enough to parse, so a
    /// read we ABANDONED must set it, not merely be short.
    func testAGrandchildHoldingTheStdoutPipeCannotOutlastTheBound() async {
        let r = await ProcessProbe().run("/bin/sh", args: ["-c", "echo early; sleep 30 &"], timeout: 5)
        XCTAssertLessThan(r.duration, 5, "the probe must not wait out a grandchild's lifetime")
        XCTAssertTrue(r.timedOut, "an abandoned read must not be merged as a complete device list")
        XCTAssertEqual(r.stdout, "early\n", "what did arrive is still recoverable")
    }

    /// The old inference caught a self-crashing child, so the new value must too — it is a strict
    /// SUPERSET, never a narrowing (`DeviceBatterySource` gates its ioreg fallback on this exact bit).
    func testASelfCrashingChildIsStillReportedAsNotComplete() async {
        let r = await ProcessProbe().run("/bin/sh", args: ["-c", "printf partial; kill -SEGV $$"], timeout: 5)
        XCTAssertTrue(r.timedOut, "a signal-terminated child must stay a failed probe")
    }

    /// The bound survives the convergence, and `duration` — which the adaptive `system_profiler`
    /// demotion guard reads — is still populated.
    func testAWedgedChildIsStillBoundedAndKilled() async {
        let r = await ProcessProbe().run("/bin/sleep", args: ["30"], timeout: 0.3)
        XCTAssertTrue(r.timedOut)
        XCTAssertGreaterThan(r.duration, 0.2, "duration must still measure the real wall time")
        XCTAssertLessThan(r.duration, 5, "the read must be bounded, not open-ended")
    }

    /// B6: a failed probe is no longer anonymous.
    func testExitCodeAndStderrReachTheCaller() async {
        let r = await ProcessProbe().run("/bin/sh", args: ["-c", "echo nope >&2; exit 4"], timeout: 5)
        XCTAssertEqual(r.exitCode, 4)
        XCTAssertTrue(r.stderr.contains("nope"))
        XCTAssertFalse(r.timedOut, "a non-zero exit is not a timeout")
    }
}

// MARK: - path 3: LiveShortcutProcess (app/ChargeControl)

/// The charge-control command path. A wedge here does not merely freeze a display — it STRANDS a
/// limit change. This seam does NOT adopt `BoundedProcess` (it needs a live stderr stream so a
/// missing shortcut, which prints its error and then hangs forever, can be classified WHILE the
/// process runs), so its immunity to the B6 wedge has to be proven on its own terms.
final class BoundedProcessShortcutSeamTests: XCTestCase {

    /// 200 KB on stderr and 200 KB on stdout, at once. Both pipes are drained by their own
    /// readability handlers, so neither can fill and deadlock the child. If either drain were ever
    /// swapped for an assigned-but-unread pipe, `awaitExit()` here would never return.
    func testAFloodOnBothPipesDoesNotWedgeTheShortcutSeam() async {
        let script = "head -c 200000 /dev/zero | tr '\\0' 'e' >&2; head -c 200000 /dev/zero | tr '\\0' 'o'"
        let handle = LiveShortcutProcess(arguments: ["-c", script], executable: "/bin/sh")

        // Consume the live line stream exactly as ShortcutsRunner does — concurrently with the exit
        // wait, never after it.
        async let drained: Int = {
            var bytes = 0
            for await line in handle.stderrLines { bytes += line.utf8.count }
            return bytes
        }()

        XCTAssertNoThrow(try handle.launch())
        let code = await handle.awaitExit()
        let stderrBytes = await drained

        XCTAssertEqual(code, 0, "the child must exit on its own, not wedge against an undrained pipe")
        XCTAssertGreaterThanOrEqual(stderrBytes, 200_000 - 1, "stderr must be drained in full")
        XCTAssertEqual(handle.collectedStdout().count, 200_000, "stdout must be drained in full")
        XCTAssertTrue(handle.hasExited)
    }

    /// The seam's own kill discipline still works, and `hasExited` — which `ShortcutsRunner` uses to
    /// skip the SIGKILL when SIGTERM landed — reports honestly.
    func testTerminateAndForceKillStillEndAHangingChild() async {
        let handle = LiveShortcutProcess(arguments: ["-c", "sleep 30"], executable: "/bin/sh")
        XCTAssertNoThrow(try handle.launch())
        XCTAssertFalse(handle.hasExited)
        handle.terminate()
        _ = await handle.awaitExit()
        XCTAssertTrue(handle.hasExited)
        handle.forceKill()   // must be a safe no-op once the child is gone (no recycled-pid signal)
    }

    /// B6 contract item the seam DOES adopt: stdin is /dev/null, so a child that reads it gets EOF
    /// instead of parking on an inherited descriptor for the runner's whole 15 s bound.
    func testStdinIsDevNullSoAReadingChildGetsEOFRatherThanHanging() async {
        let handle = LiveShortcutProcess(arguments: ["-c", "cat; echo eof"], executable: "/bin/sh")
        XCTAssertNoThrow(try handle.launch())
        let code = await handle.awaitExit()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(handle.collectedStdout(), "eof\n")
    }

    /// The production factory still targets the real binary — the executable parameter is a TEST
    /// affordance and must never leak into the production path.
    func testTheProductionFactoryStillTargetsTheRealShortcutsBinary() {
        XCTAssertEqual(LiveShortcutProcess.executablePath, "/usr/bin/shortcuts")
        XCTAssertEqual(LiveShortcutProcessFactory().shortcutsBinaryExists(),
                       FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts"))
    }
}
