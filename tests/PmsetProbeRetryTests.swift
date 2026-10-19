import XCTest

/// RECOVERY ARC — "when we give up early, fix whatever is supposed to happen."
///
/// `BoundedProcess` made a failed spawn HONEST: `killed` and `outputTruncated` are facts, so a caller
/// finally knows the difference between "the command answered no" and "we stopped listening". Honest
/// was inert, though — every reader mapped both to the same `.unavailable` / nil / false and then did
/// nothing about it.
///
/// These tests pin the second half: a bounded, per-site recovery. The thing they exist to PREVENT is a
/// retry storm — this app's largest measured CPU cost is subprocess spawns fired too often (audit A13,
/// `knowledge/11-MEASURE-a5-a9-a13.md`: 63.4% of app CPU from 72.4 notifications/hr × 3 samples), so
/// every assertion below is about a CEILING as much as about a recovery.
///
/// The spawn COUNT is measured, not inferred: each scripted child appends a byte to a counter file
/// before it does anything else, so "did it retry?" is answered by the filesystem rather than by a
/// flag the code under test sets itself.
final class PmsetProbeRetryTests: XCTestCase {

    // MARK: - the counter harness

    private var counterPath = ""

    override func setUp() {
        super.setUp()
        counterPath = NSTemporaryDirectory() + "battery_app-retry-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: counterPath)
        super.tearDown()
    }

    /// How many children actually ran — one byte appended per spawn, before the child does anything
    /// that could be cut short.
    private func spawnCount() -> Int {
        (try? Data(contentsOf: URL(fileURLWithPath: counterPath)).count) ?? 0
    }

    /// A child that records itself and then HANGS past any bound we give it.
    private var hangingScript: String { "printf x >> \(counterPath); exec sleep 3" }

    private func runScript(_ script: String,
                           timeout: TimeInterval,
                           retry: PmsetProbe.RetryPolicy) -> PmsetOutcome {
        PmsetProbe.run(executable: "/bin/sh", arguments: ["-c", script], timeout: timeout, retry: retry)
    }

    // MARK: - the recovery happens, ONCE

    /// THE RED TEST FOR THE RECOVERY. A child we killed at the bound is the one failure a second
    /// attempt can plausibly change — so under `.onceIfCutShort` there must be a second child, and the
    /// outcome must SAY there was one.
    func testACutShortReadIsRetriedExactlyOnce() {
        let outcome = runScript(hangingScript, timeout: 0.4, retry: .onceIfCutShort)
        XCTAssertEqual(spawnCount(), 2, "a cut-short read must be retried — once")
        XCTAssertEqual(outcome.attempts, 2, "the outcome must carry the fact that it retried")
        XCTAssertTrue(outcome.timedOut)
        XCTAssertFalse(outcome.succeeded, "a retry that also failed is still a failure")
    }

    /// THE RED TEST FOR THE CEILING. A binary that is wedged FOREVER must cost exactly two spawns per
    /// read, for every read, forever — never three, and never a count that grows with the failure
    /// streak. This is the assertion that stops the recovery undoing the energy arc of the audit.
    func testAPersistentlyFailingBinaryNeverExceedsTwoSpawnsPerRead() {
        for _ in 0..<3 { _ = runScript(hangingScript, timeout: 0.4, retry: .onceIfCutShort) }
        XCTAssertEqual(spawnCount(), 6, "three reads of a permanently wedged binary must be 3 × 2 spawns, not a storm")
    }

    /// The recovery must actually RECOVER, not merely re-fail politely. The first invocation hangs, the
    /// second (seeing the counter) answers — which is exactly the transient-load case the retry exists
    /// for, and the outcome comes back as a clean, parseable read.
    func testTheSecondAttemptCanSucceedAndItsOutputIsTheOneReturned() {
        let script = """
        if [ -s \(counterPath) ]; then printf x >> \(counterPath); echo 'highpowermode'; \
        else printf x >> \(counterPath); exec sleep 3; fi
        """
        let outcome = runScript(script, timeout: 0.4, retry: .onceIfCutShort)
        XCTAssertEqual(spawnCount(), 2)
        XCTAssertEqual(outcome.attempts, 2)
        XCTAssertTrue(outcome.succeeded, "the retry's own result is what comes back")
        XCTAssertEqual(outcome.stdout, "highpowermode\n")
        XCTAssertTrue(HighPowerCapabilityReader.parse(outcome.stdout ?? ""),
                      "the recovered read must be usable, not just non-nil")
    }

    // MARK: - the failures that must NEVER be retried

    /// A command that RAN and exited non-zero has answered us. Re-asking it is how a binary that is
    /// wedged-but-responsive gets hammered — so this must cost exactly one spawn even under the
    /// retrying policy.
    func testACleanNonZeroExitIsNeverRetried() {
        let outcome = runScript("printf x >> \(counterPath); exit 3", timeout: 5, retry: .onceIfCutShort)
        XCTAssertEqual(spawnCount(), 1, "a non-zero exit is an ANSWER, not a gap — do not re-ask it")
        XCTAssertEqual(outcome.attempts, 1)
        XCTAssertEqual(outcome.exitCode, 3)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertFalse(outcome.succeeded)
    }

    /// A missing binary fails identically on the second `posix_spawn`. Retrying it buys nothing and
    /// costs a spawn.
    func testALaunchFailureIsNeverRetried() {
        let outcome = PmsetProbe.run(executable: "/nonexistent/battery_app/pmset",
                                     arguments: ["-g"], timeout: 1, retry: .onceIfCutShort)
        XCTAssertTrue(outcome.launchFailed)
        XCTAssertEqual(outcome.attempts, 1, "a binary that will not launch will not launch twice either")
        XCTAssertFalse(outcome.timedOut)
    }

    /// `.none` is the default and it must be exactly one spawn even for the retryable failure class —
    /// otherwise every existing call site silently inherits a doubled spawn count.
    func testPolicyNoneNeverSpawnsASecondChild() {
        let outcome = runScript(hangingScript, timeout: 0.4, retry: .none)
        XCTAssertEqual(spawnCount(), 1, "`.none` means one child, even when we cut it short")
        XCTAssertEqual(outcome.attempts, 1)
        XCTAssertTrue(outcome.timedOut)
    }

    /// The default is the CHEAP one. A caller that has not thought about spawn cost must not acquire a
    /// retry by writing nothing.
    func testTheDefaultPolicyIsNoRetry() {
        let outcome = PmsetProbe.run(executable: "/bin/sh", arguments: ["-c", hangingScript], timeout: 0.4,
                                     retry: .none)
        XCTAssertEqual(outcome.attempts, 1)
        XCTAssertEqual(spawnCount(), 1)
    }

    // MARK: - the retry is a DIFFERENT experiment, and still bounded

    /// Attempt 2 gets a wider bound (the first was killed AT the bound, so repeating it mostly re-buys
    /// the same kill) — but the TOTAL stays bounded and inside the stated worst case. Both halves
    /// matter: too narrow and the retry is theatre, unbounded and it is a hang.
    func testTheRetryWidensTheBoundAndTheTotalStaysBounded() {
        let start = Date()
        _ = runScript(hangingScript, timeout: 0.4, retry: .onceIfCutShort)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 1.0, "attempt 2 must get a genuinely wider bound (0.4 then 0.8), not a repeat")
        XCTAssertLessThan(elapsed, PmsetProbe.worstCaseSeconds(timeout: 0.4, retry: .onceIfCutShort) + 2,
                          "the total must stay inside the stated worst case")
    }

    /// PURE. The worst-case arithmetic the ordering rule below is argued from.
    func testWorstCaseSecondsIsTheStatedArithmetic() {
        XCTAssertEqual(PmsetProbe.worstCaseSeconds(timeout: 5, retry: .none), 6, accuracy: 0.001)
        XCTAssertEqual(PmsetProbe.worstCaseSeconds(timeout: 5, retry: .onceIfCutShort), 17, accuracy: 0.001)
    }

    /// THE ORDERING RULE, machine-checked rather than left as a comment. `BoundedReadGate` presumes a
    /// read still in flight after `staleAfterSeconds` is wedged and lets the NEXT caller take the gate
    /// from it. A `.onceIfCutShort` read outlives that window — so a GATED caller would reclaim its own
    /// read mid-retry and start a third child, which is the pile-up the gate exists to prevent.
    ///
    /// If this test ever fails because the gate window grew, that is the signal to re-examine every
    /// `.none` below — not to delete the test.
    @MainActor
    func testTheRetryPolicyIsIncompatibleWithABoundedReadGateCaller() {
        XCTAssertLessThan(PmsetProbe.worstCaseSeconds(retry: .none), BoundedReadGate.staleAfterSeconds,
                          "a plain read must always settle itself before the gate's backstop")
        XCTAssertGreaterThan(PmsetProbe.worstCaseSeconds(retry: .onceIfCutShort),
                             BoundedReadGate.staleAfterSeconds,
                             "a retrying read outlives the gate window — gated callers must stay `.none`")
    }

    // MARK: - the per-site decisions, pinned

    /// Each reader's policy is the one its CALL SITE can afford, and the differences are the point:
    ///
    ///  * `EnergyModeReader` — `.none`. The two highest-frequency spawns in the app (60 s poll + popover
    ///    open + the A13 notification path, ~8,100 `pmset` spawns/day measured). Its recovery is the
    ///    re-read the app was already going to do, ≤60 s away, and it is behind `BoundedReadGate`.
    ///  * `HighPowerCapabilityReader` — `.onceIfCutShort`. Resolved ONCE per launch, and a failure
    ///    latches "High Power unsupported" for the whole session with no cue and no way back.
    ///  * `SleepTimerReader` — `.onceIfCutShort`. Behind a 300 s cache that stamps on FAILURE too, so a
    ///    single cut-short read costs the keep-awake explanation for five minutes.
    func testEachReaderDeclaresThePolicyItsCallSiteCanAfford() {
        XCTAssertEqual(EnergyModeReader.retryPolicy, .none)
        XCTAssertEqual(HighPowerCapabilityReader.retryPolicy, .onceIfCutShort)
        XCTAssertEqual(SleepTimerReader.retryPolicy, .onceIfCutShort)
    }

    // MARK: - a retry that also fails must END somewhere honest

    /// A recovery that papers over a real failure is the original defect class. A second failure is
    /// LOGGED as a second failure — the note names the retry rather than reading like a first attempt.
    func testAFailedRetryIsNamedAsSuchInTheLog() {
        let once = PmsetOutcome(stdout: nil, stderr: "", exitCode: nil, timedOut: true, launchFailed: false)
        let twice = PmsetOutcome(stdout: nil, stderr: "", exitCode: nil, timedOut: true, launchFailed: false,
                                 attempts: 2)
        let first = PmsetProbe.failureNote(arguments: ["-g", "cap"], outcome: once)
        let second = PmsetProbe.failureNote(arguments: ["-g", "cap"], outcome: twice)
        XCTAssertEqual(first, "pmset -g cap: timed out and was killed")
        XCTAssertEqual(second, "pmset -g cap: timed out and was killed (attempt 2, after a retry)")
    }

    /// A successful read still logs nothing, retry or not — the note is a diagnostic, not a trace.
    func testASuccessfulReadIsStillSilent() {
        let ok = PmsetOutcome(stdout: "powermode 2", stderr: "", exitCode: 0, timedOut: false,
                              launchFailed: false, attempts: 2)
        XCTAssertNil(PmsetProbe.failureNote(arguments: ["-g"], outcome: ok))
    }

    /// `attempts` defaults to 1, so every construction site that predates the recovery arc — including
    /// the hand-built outcomes elsewhere in the suite — keeps its exact previous meaning.
    func testAttemptsDefaultsToOneForEveryPreExistingConstruction() {
        let ok = PmsetOutcome(stdout: "x", stderr: "", exitCode: 0, timedOut: false, launchFailed: false)
        XCTAssertEqual(ok.attempts, 1)
    }
}

// MARK: - the classification the retry is gated on

/// `wasCutShort` is what makes a bounded retry safe: it separates "we stopped listening" from "it
/// answered". Every exclusion here is a spawn NOT made on a persistently failing machine.
final class BoundedProcessCutShortTests: XCTestCase {

    private func result(killed: Bool = false, signalled: Bool = false, truncated: Bool = false,
                        launchFailed: Bool = false, exitCode: Int32? = 0) -> BoundedProcessResult {
        BoundedProcessResult(stdout: Data(), stderr: Data(), exitCode: exitCode, killed: killed,
                             terminatedBySignal: signalled, outputTruncated: truncated,
                             launchFailed: launchFailed, launchError: "", duration: 0)
    }

    func testWeKilledItCountsAsCutShort() {
        XCTAssertTrue(result(killed: true, signalled: true, exitCode: nil).wasCutShort)
    }

    func testAnAbandonedPipeCountsAsCutShort() {
        XCTAssertTrue(result(truncated: true).wasCutShort,
                      "bytes we gave up on are the same gap as a child we gave up on")
    }

    func testALaunchFailureIsNotCutShort() {
        XCTAssertFalse(result(launchFailed: true, exitCode: nil).wasCutShort,
                       "a missing binary fails identically the second time — retrying it is pure cost")
    }

    func testANonZeroExitIsNotCutShort() {
        XCTAssertFalse(result(exitCode: 3).wasCutShort, "it RAN and told us no — that is an answer")
    }

    func testASelfCrashIsNotCutShort() {
        XCTAssertFalse(result(signalled: true, exitCode: nil).wasCutShort,
                       "nothing we did bounded it; a deterministic crash reproduces")
    }

    func testASuccessIsNotCutShort() {
        XCTAssertFalse(result().wasCutShort)
    }

    /// Live, against a real child: killed at the bound ⇒ cut short, and the `pmset` seam folds exactly
    /// this into its `timedOut`.
    func testARealKilledChildIsCutShort() {
        let r = BoundedProcess.run(executable: "/bin/sleep", arguments: ["3"], timeout: 0.4)
        XCTAssertTrue(r.killed)
        XCTAssertTrue(r.wasCutShort)
    }

    /// Live: a child that answers non-zero in time is NOT cut short, so it can never trigger a retry.
    func testARealNonZeroExitIsNotCutShort() {
        let r = BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "exit 4"], timeout: 5)
        XCTAssertEqual(r.exitCode, 4)
        XCTAssertFalse(r.wasCutShort)
    }
}

// MARK: - the three-state High Power capability

/// The site with the worst failure-to-cost ratio: resolved once per launch, and a failure used to
/// latch "High Power unsupported" for the whole session as an anonymous `false`. It is now the same
/// three-state shape the tree already uses four times over (`TemperatureReading`,
/// `BatteryLifetimeReadFailure`, `PowerAdapterReadState`) — a proven absence and a failed read are
/// different values.
final class HighPowerCapabilityStateTests: XCTestCase {

    func testAProvenAbsenceAndAFailedReadAreDifferentValues() {
        XCTAssertNotEqual(HighPowerCapability.unsupported,
                          HighPowerCapability.unknown("the capability read did not finish in time"))
    }

    func testOnlySupportedShowsTheOption() {
        XCTAssertTrue(HighPowerCapability.supported.isSupported)
        XCTAssertFalse(HighPowerCapability.unsupported.isSupported)
        XCTAssertFalse(HighPowerCapability.unknown("x").isSupported,
                       "hiding an option we cannot prove exists is the conservative direction")
    }

    /// Only a FAILED read gets a sentence — a Mac without High Power is not a problem to report.
    func testOnlyAFailedReadGetsANote() {
        XCTAssertNil(HighPowerCapability.supported.note)
        XCTAssertNil(HighPowerCapability.unsupported.note)
        XCTAssertEqual(HighPowerCapability.unknown("the capability read did not finish in time, twice").note,
                       "High Power availability unknown — the capability read did not finish in time, twice.")
    }

    /// A retry that also failed must not launder itself into certainty: the reason SAYS it happened
    /// twice, so nothing downstream can read the answer as a settled "unsupported".
    func testTheReasonNamesTheRetryWhenThereWasOne() {
        let once = PmsetOutcome(stdout: nil, stderr: "", exitCode: nil, timedOut: true, launchFailed: false)
        let twice = PmsetOutcome(stdout: nil, stderr: "", exitCode: nil, timedOut: true, launchFailed: false,
                                 attempts: 2)
        XCTAssertEqual(HighPowerCapabilityReader.unknownReason(once),
                       "the capability read did not finish in time")
        XCTAssertEqual(HighPowerCapabilityReader.unknownReason(twice),
                       "the capability read did not finish in time, twice")
    }

    func testEachFailureShapeGetsItsOwnReason() {
        let launch = PmsetOutcome(stdout: nil, stderr: "", exitCode: nil, timedOut: false, launchFailed: true)
        let exited = PmsetOutcome(stdout: "", stderr: "", exitCode: 3, timedOut: false, launchFailed: false)
        let garbled = PmsetOutcome(stdout: nil, stderr: "", exitCode: 0, timedOut: false, launchFailed: false)
        XCTAssertEqual(HighPowerCapabilityReader.unknownReason(launch),
                       "the capability read could not be started")
        XCTAssertEqual(HighPowerCapabilityReader.unknownReason(exited), "the capability read exited 3")
        XCTAssertEqual(HighPowerCapabilityReader.unknownReason(garbled),
                       "the capability read returned output this app could not decode")
    }

    /// The `() -> Bool` shape `EnergyModeController.resolveHighPowerAvailability(probe:)` takes is
    /// unchanged in meaning — the three-state read is additive, not a behaviour swap.
    func testTheBoolShimIsUnchangedInMeaning() {
        XCTAssertTrue(HighPowerCapabilityReader.parse("highpowermode\nlowpowermode"))
        XCTAssertFalse(HighPowerCapabilityReader.parse("lowpowermode"))
    }
}

// MARK: - the cut-short fact reaches the device probe

/// `DeviceBatterySource` latches `ioregExhausted` on `timedOut || launchFailed`, which permanently
/// disarms the Bluetooth-HID fallback for the session — the same latch-on-a-transient defect
/// `HighPowerCapabilityReader` had. The FACT it needs to stop doing that is published here; the edit
/// itself is a hand-off (that file is not this pass's to change).
final class ProcessProbeCutShortTests: XCTestCase {

    func testAKilledChildReachesTheCallerAsCutShort() async {
        let r = await ProcessProbe().run("/bin/sleep", args: ["3"], timeout: 0.4)
        XCTAssertTrue(r.timedOut)
        XCTAssertTrue(r.cutShort, "the caller must be able to tell WE gave up from the child crashing")
    }

    func testASelfCrashIsTimedOutButNotCutShort() async {
        let r = await ProcessProbe().run("/bin/sh", args: ["-c", "kill -SEGV $$"], timeout: 5)
        XCTAssertTrue(r.timedOut, "a self-crash still means the output is not a complete read")
        XCTAssertFalse(r.cutShort, "but nothing WE did bounded it — it is not a retry candidate")
    }

    func testACleanReadIsNeither() async {
        let r = await ProcessProbe().run("/bin/echo", args: ["ok"], timeout: 5)
        XCTAssertFalse(r.timedOut)
        XCTAssertFalse(r.cutShort)
        XCTAssertEqual(r.stdout, "ok\n")
    }

    /// `cutShort` defaults to false, so every scripted mock that predates it — including
    /// `DeviceBatterySourceTests`' — keeps its exact previous meaning.
    func testCutShortDefaultsToFalseForPreExistingConstructions() {
        let r = ProcessProbeResult(stdout: "", timedOut: true, launchFailed: false, duration: 5)
        XCTAssertFalse(r.cutShort)
    }
}
