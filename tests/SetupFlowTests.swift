import XCTest

/// WI-N6: detection over `shortcuts list`, degraded states, and the walkthrough content
/// (exact names; the 8h trust boundary stated).
/// A12: a Sendable call counter for the `@Sendable` preflight probe closure.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@MainActor
final class SetupFlowTests: XCTestCase {

    private let allInstalled = """
        Battery Limit 80
        Battery Limit 85
        Battery Limit 90
        Battery Limit 95
        Battery Limit 100
        Battery Limit Get
        Some Unrelated Shortcut
        """

    func testAllPresentIsReady() async {
        let runner = MockShortcutRunner([.init(.success(stdout: allInstalled))])
        let flow = SetupFlow(runner: runner)
        await flow.checkNow()
        XCTAssertEqual(flow.state, .ready)
        XCTAssertEqual(runner.invocationNames, ["<list>"])
    }

    func testPreflightVerdictRecordedAsAdvisoryOnly() async {
        // 8i: the probe's verdict is PUBLISHED for diagnostics but must not change detection —
        // even a hard .denied leaves the setup state driven purely by `shortcuts list`.
        let runner = MockShortcutRunner([.init(.success(stdout: allInstalled))])
        let flow = SetupFlow(runner: runner, preflightProbe: { .denied })
        await flow.checkNow()
        XCTAssertEqual(flow.automationPreflight, .denied)
        XCTAssertEqual(flow.state, .ready, "advisory verdicts must not gate setup state")
    }

    func testMissingShortcutsListedExactly() async {
        let partial = "Battery Limit 80\nBattery Limit Get\nOther Thing"
        let runner = MockShortcutRunner([.init(.success(stdout: partial))])
        let flow = SetupFlow(runner: runner)
        await flow.checkNow()
        XCTAssertEqual(flow.state, .missing(["Battery Limit 85", "Battery Limit 90",
                                             "Battery Limit 95", "Battery Limit 100"]))
    }

    func testEmptyListMissesTheFiveSets() async {
        // 4.I: only the five SET shortcuts are required — empty list → those five missing (not Get).
        let runner = MockShortcutRunner([.init(.success(stdout: ""))])
        let flow = SetupFlow(runner: runner)
        await flow.checkNow()
        XCTAssertEqual(flow.state, .missing(ChargeShortcuts.validLimitValues.map(ChargeShortcuts.setName(for:))))
    }

    // MARK: - 4.I Get-optional gate

    func testFiveSetsNoGetIsReadyDegraded() async {
        // The owner's 27.0 situation: all five Sets, no Get → READY (degraded), never "setup required".
        let noGet = "Battery Limit 80\nBattery Limit 85\nBattery Limit 90\nBattery Limit 95\nBattery Limit 100"
        let runner = MockShortcutRunner([.init(.success(stdout: noGet))])
        let flow = SetupFlow(runner: runner)
        await flow.checkNow()
        XCTAssertEqual(flow.state, .readyDegraded)
    }

    func testIsOperationalIsTrueForReadyAndDegradedOnly() async {
        // "The limit can be SET" — true for verified AND degraded; false for any not-set-up state.
        let noGet = "Battery Limit 80\nBattery Limit 85\nBattery Limit 90\nBattery Limit 95\nBattery Limit 100"
        let degraded = SetupFlow(runner: MockShortcutRunner([.init(.success(stdout: noGet))]))
        await degraded.checkNow()
        XCTAssertEqual(degraded.state, .readyDegraded)
        XCTAssertTrue(degraded.isOperational, "degraded sets fine → operational")

        let ready = SetupFlow(runner: MockShortcutRunner([.init(.success(stdout: allInstalled))]))
        await ready.checkNow()
        XCTAssertTrue(ready.isOperational, "verified → operational")

        let missing = SetupFlow(runner: MockShortcutRunner([.init(.success(stdout: ""))]))
        await missing.checkNow()
        XCTAssertFalse(missing.isOperational, "missing the SET shortcuts → not operational")

        let listFailed = SetupFlow(runner: MockShortcutRunner([.init(.shortcutsBinaryAbsent)]))
        await listFailed.checkNow()
        XCTAssertFalse(listFailed.isOperational, "list unavailable → not operational")

        XCTAssertFalse(SetupFlow(runner: MockShortcutRunner([])).isOperational, ".unknown (pre-check) → not operational")
    }

    func testGetPresentIsVerifiedReady() async {
        let runner = MockShortcutRunner([.init(.success(stdout: allInstalled))])
        let flow = SetupFlow(runner: runner)
        await flow.checkNow()
        XCTAssertEqual(flow.state, .ready, "five Sets + Get → verified mode")
    }

    func testSelfHealDegradedUpgradesToVerifiedWhenGetReturns() async {
        let noGet = "Battery Limit 80\nBattery Limit 85\nBattery Limit 90\nBattery Limit 95\nBattery Limit 100"
        let runner = MockShortcutRunner([
            .init(.success(stdout: noGet)),       // degraded
            .init(.success(stdout: allInstalled)) // a future seed restores the action + the shortcut
        ])
        let box = MockClockBox(1000)
        let flow = SetupFlow(runner: runner, clock: MockMonotonicClock(box: box))
        await flow.checkNow(); XCTAssertEqual(flow.state, .readyDegraded)
        box.now += SetupFlow.checkMinInterval          // A12: a re-check must clear the rate gate
        await flow.checkNow(); XCTAssertEqual(flow.state, .ready, "silently upgrades to verified")
    }

    func testWhitespaceAndUnrelatedLinesTolerated() async {
        let messy = "  Battery Limit 80  \n\n Battery Limit 85\nBattery Limit 90\n" +
                    "Battery Limit 95\nBattery Limit 100\n  Battery Limit Get \n\n"
        let runner = MockShortcutRunner([.init(.success(stdout: messy))])
        let flow = SetupFlow(runner: runner)
        await flow.checkNow()
        XCTAssertEqual(flow.state, .ready)
    }

    func testListFailuresDegradeToListUnavailable() async {
        let cases: [(ShortcutRunOutcome, SetupFlow.ListProblem)] = [
            (.shortcutsBinaryAbsent, .binaryAbsent),
            (.automationBlocked(stderrTail: ""), .automationBlocked),
            (.failed(exitCode: 2, stderrTail: ""), .failure),
            (.launchFailed(message: "m"), .failure),
        ]
        for (outcome, problem) in cases {
            let runner = MockShortcutRunner([.init(outcome)])
            let flow = SetupFlow(runner: runner)
            await flow.checkNow()
            XCTAssertEqual(flow.state, .listUnavailable(problem), "for \(outcome)")
        }
    }

    func testSelfHealRecheckDetectsVanishedShortcuts() async {
        // "Re-check on every launch; degrade … if shortcuts vanish" — ready must not stick.
        let runner = MockShortcutRunner([
            .init(.success(stdout: allInstalled)),
            .init(.success(stdout: "Battery Limit 80")),   // the rest vanished
        ])
        let box = MockClockBox(1000)
        let flow = SetupFlow(runner: runner, clock: MockMonotonicClock(box: box))
        await flow.checkNow()
        XCTAssertEqual(flow.state, .ready)
        box.now += SetupFlow.checkMinInterval          // A12: a re-check must clear the rate gate
        await flow.checkNow()
        guard case .missing(let names) = flow.state else { return XCTFail("expected .missing") }
        XCTAssertEqual(names.count, 4, "the four vanished SET shortcuts (Get is not required)")
    }

    // MARK: - 4.I degraded transition notice (one-time, only on verified → degraded)

    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "setup.tests.\(UUID().uuidString)")! }
    private let noGet = "Battery Limit 80\nBattery Limit 85\nBattery Limit 90\nBattery Limit 95\nBattery Limit 100"

    func testTransitionVerifiedToDegradedFiresOneTimeNotice() async {
        let runner = MockShortcutRunner([
            .init(.success(stdout: allInstalled)),  // verified first (records it)
            .init(.success(stdout: noGet)),         // Get pulled → degraded
        ])
        let box = MockClockBox(1000)
        let flow = SetupFlow(runner: runner, defaults: freshDefaults(), clock: MockMonotonicClock(box: box))
        await flow.checkNow(); XCTAssertFalse(flow.degradedNoticePending)
        box.now += SetupFlow.checkMinInterval          // A12: a re-check must clear the rate gate
        await flow.checkNow()
        XCTAssertEqual(flow.state, .readyDegraded)
        XCTAssertTrue(flow.degradedNoticePending, "the transition into degraded fires the one-time notice")
        flow.dismissDegradedNotice()
        XCTAssertFalse(flow.degradedNoticePending, "dismiss clears it")
    }

    func testFreshDegradedDoesNotNag() async {
        // First-ever check is degraded (no prior verified record) → tag only, NO notice.
        let runner = MockShortcutRunner([.init(.success(stdout: noGet))])
        let flow = SetupFlow(runner: runner, defaults: freshDefaults())
        await flow.checkNow()
        XCTAssertEqual(flow.state, .readyDegraded)
        XCTAssertFalse(flow.degradedNoticePending, "a steady degraded state gets the tag, not a banner")
    }

    func testUpgradeToVerifiedNeedsNoNotice() async {
        let runner = MockShortcutRunner([
            .init(.success(stdout: noGet)),         // degraded
            .init(.success(stdout: allInstalled)),  // Get returns → verified
        ])
        let box = MockClockBox(1000)
        let flow = SetupFlow(runner: runner, defaults: freshDefaults(), clock: MockMonotonicClock(box: box))
        await flow.checkNow()
        box.now += SetupFlow.checkMinInterval          // A12: a re-check must clear the rate gate
        await flow.checkNow()
        XCTAssertEqual(flow.state, .ready)
        XCTAssertFalse(flow.degradedNoticePending, "upgrading to verified needs nothing — the tag just disappears")
    }

    // MARK: - A12 · the popover-open rate gate (the sibling idiom, ChargeLimitEngine.popoverOpenMinInterval)

    /// The defect, stated as a test: on macOS 27 the app's steady state is `.readyDegraded`, so the call
    /// site's `state != .ready` guard passes on EVERY popover open and every open used to spawn a
    /// `shortcuts list` into the runner's serialised FIFO (plus an AppleEvent preflight probe).
    func testRepeatCheckInsideTheWindowSpawnsNoSecondList() async {
        let runner = MockShortcutRunner([.init(.success(stdout: noGet)), .init(.success(stdout: noGet))])
        let probes = ProbeCounter()
        let box = MockClockBox(1000)
        let flow = SetupFlow(runner: runner,
                             preflightProbe: { probes.bump(); return .granted },
                             defaults: freshDefaults(),
                             clock: MockMonotonicClock(box: box))
        await flow.checkNow()
        XCTAssertEqual(runner.invocationNames, ["<list>"], "the first check of a session always runs")
        XCTAssertEqual(flow.state, .readyDegraded)

        box.now += SetupFlow.checkMinInterval - 1        // still inside the window
        await flow.checkNow()
        XCTAssertEqual(runner.invocations.count, 1, "a reopen inside the gate spawns no second `shortcuts list`")
        XCTAssertEqual(probes.count, 1, "and no second AppleEvent preflight probe")
        XCTAssertEqual(flow.state, .readyDegraded, "the already-determined state is unchanged")
    }

    /// The gate must not RATION the check — past the window the self-heal still works (this is what
    /// makes a 60 s gate safe rather than a new "stuck in setup" bug).
    func testCheckPastTheWindowRunsAgainAndSelfHeals() async {
        let runner = MockShortcutRunner([.init(.success(stdout: noGet)), .init(.success(stdout: allInstalled))])
        let box = MockClockBox(1000)
        let flow = SetupFlow(runner: runner, defaults: freshDefaults(),
                             clock: MockMonotonicClock(box: box))
        await flow.checkNow()
        XCTAssertEqual(flow.state, .readyDegraded)
        box.now += SetupFlow.checkMinInterval            // exactly at the boundary → NOT gated
        await flow.checkNow()
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(flow.state, .ready, "past the gate the re-check adopts the restored Get shortcut")
    }

    /// `lastCheckAt == nil` is never gated, whatever the clock reads — the LAUNCH pass must always run
    /// or the app would sit in `.unknown` for want of a rate gate.
    func testFirstCheckOfASessionIsNeverGated() async {
        let runner = MockShortcutRunner([.init(.success(stdout: allInstalled))])
        let flow = SetupFlow(runner: runner, defaults: freshDefaults(),
                             clock: MockMonotonicClock(box: MockClockBox(0)))
        await flow.checkNow()
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(flow.state, .ready)
    }

    // MARK: - walkthrough content

    func testWalkthroughCoversTheFiveSetNames() {
        // 4.I: the required walkthrough steps are the five Sets only (Get moved to a recommendation).
        XCTAssertEqual(SetupWalkthrough.steps.map(\.shortcutName),
                       ChargeShortcuts.validLimitValues.map(ChargeShortcuts.setName(for:)))
        for step in SetupWalkthrough.steps {
            XCTAssertTrue(step.instruction.contains("“\(step.shortcutName)”"),
                          "instruction must quote the exact name: \(step.shortcutName)")
            XCTAssertTrue(step.instruction.contains("“Set Battery Charge Limit”"),
                          "must name Apple's built-in action by its current label")
            XCTAssertTrue(step.instruction.contains("not this app’s “Set Charge Limit”"),
                          "must steer the user OFF this app's own intent title")
            XCTAssertTrue(step.instruction.contains("No input, no other actions"),
                          "keeps the single-action / no-input constraint")
        }
    }

    func testGetRecommendationLeadsWithValueAndDegradedNoteNamesFix() {
        // Get is no longer a required step; the guidance now LEADS with its value (recommended +
        // live read-back) while keeping the OS-lacks-action escape, and the degraded note names the
        // actionable fix (create the Get shortcut) rather than asserting read-back is impossible.
        XCTAssertFalse(SetupWalkthrough.steps.contains { $0.shortcutName == ChargeShortcuts.get },
                       "Get must NOT be a required step")
        XCTAssertTrue(SetupWalkthrough.getRecommendation.contains(ChargeShortcuts.get),
                      "the Get name stays single-sourced")
        XCTAssertTrue(SetupWalkthrough.getRecommendation.contains("“Get Battery Charge Limit”"),
                      "names Apple's built-in Get action by its current label, not the bare Get Charge Limit")
        XCTAssertTrue(SetupWalkthrough.getRecommendation.lowercased().contains("recommended"),
                      "the guidance leads with the recommendation, not 'optional'")
        XCTAssertTrue(SetupWalkthrough.getRecommendation.lowercased().contains("live"),
                      "it states the value: reading the live limit")
        XCTAssertTrue(SetupWalkthrough.getRecommendation.lowercased().contains("skip"),
                      "the OS-lacks-the-action escape is preserved")
        // The honest degraded line — never a wall, and now ACTIONABLE (names the fix).
        XCTAssertTrue(SetupWalkthrough.degradedNote.contains("read-back"))
        XCTAssertTrue(SetupWalkthrough.degradedNote.lowercased().contains("behavior"))
        XCTAssertTrue(SetupWalkthrough.degradedNote.contains(ChargeShortcuts.get),
                      "the degraded note names the actionable fix (create the Get shortcut)")
        XCTAssertTrue(SetupWalkthrough.degradedNote.contains("“Get Battery Charge Limit”"),
                      "names the built-in Get action by its current label")
    }

    func testGrantExplanationNamesBothRecoveryRoutes() {
        // The collapsed-taxon honesty (Grok B3) starts here: prompt approval AND the
        // Settings path are both named.
        XCTAssertTrue(SetupWalkthrough.grantExplanation.contains("one-time permission"))
        XCTAssertTrue(SetupWalkthrough.grantExplanation.contains("Privacy & Security → Automation"))
    }

    func testTrustBoundaryNoticeStatesTheBoundary() {
        // 8h: documented, deliberately not code-mitigated.
        XCTAssertTrue(SetupWalkthrough.trustBoundaryNotice.contains("single-action"))
        XCTAssertTrue(SetupWalkthrough.trustBoundaryNotice
            .contains("verifies the resulting limit value"))
    }
}
