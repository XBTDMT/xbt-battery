import XCTest

/// WI-N5: the engine coordinator — the Set pipeline (read-verify + retry-once), S-N4 failure
/// routing, S-N3 absorption (sync triggers, backstop gating, capture invalidation), and the
/// sec-5 Pause/Resume orchestration incl. the pre-Resume Get (Grok SF2).
@MainActor
final class ChargeLimitEngineTests: XCTestCase {

    private func makeEngine(_ scripted: [MockShortcutRunner.Scripted] = [],
                            capture: PauseCapture? = nil,
                            corruptCapture: Bool = false,
                            clockStart: TimeInterval = 0,
                            custody: MockLastSetCustodyStore = MockLastSetCustodyStore())
    -> (ChargeLimitEngine, MockShortcutRunner, MockPauseCaptureStore, MockClockBox) {
        let runner = MockShortcutRunner(scripted)
        let store = MockPauseCaptureStore(capture, corrupt: corruptCapture)
        let box = MockClockBox(clockStart)
        let engine = ChargeLimitEngine(runner: runner, captureStore: store, custodyStore: custody,
                                       clock: MockMonotonicClock(box: box))
        return (engine, runner, store, box)
    }

    // MARK: - the Set pipeline

    func testSetSuccessReadVerifiesAndAdoptsTarget() async {
        let (engine, runner, _, _) = makeEngine([
            .init(.success(stdout: "")),                 // Set 80
            .init(.success(stdout: ""), file: "80"),     // read-verify → match
        ])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(runner.invocationNames, ["Battery Limit 80", "Battery Limit Get"])
        XCTAssertEqual(engine.limit, .known(80))
        // No telemetry has been ingested, so `socAtSet` is nil. Since the nil-SoC ruling (review
        // BLOCKING 4) an unreadable SoC no longer arms `.chargingToCap` — it would pin the
        // stagnation TTL off and leave the 2-h ceiling as the only exit, resolving a telemetry
        // glitch as a charge-management warning. Report, don't promise, and arm nothing.
        XCTAssertEqual(engine.confirm.status, .requestedNoPromise)
        XCTAssertFalse(engine.confirm.isWindowArmed)
        XCTAssertNil(engine.engineNote)
    }

    func testSetFromGenuineHoldArmsResumeConfirm() async {
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),
            .init(.success(stdout: ""), file: "100"),
        ])
        engine.ingest(ChargeFixtures.limitHold80(t: 0), state: .limitHold)   // pre-Set NCR hold
        _ = await engine.userSetLimit(100)
        XCTAssertEqual(engine.confirm.status, .confirming)
        XCTAssertTrue(engine.wantsFastPolling)
    }

    func testReadVerifyMismatchRetriesOnceThenSucceeds() async {
        let (engine, runner, _, _) = makeEngine([
            .init(.success(stdout: "")),                 // Set 80
            .init(.success(stdout: ""), file: "90"),     // verify → MISMATCH
            .init(.success(stdout: "")),                 // retry Set 80
            .init(.success(stdout: ""), file: "80"),     // verify → match
        ])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(runner.invocationNames,
                       ["Battery Limit 80", "Battery Limit Get", "Battery Limit 80", "Battery Limit Get"])
        XCTAssertEqual(engine.limit, .known(80))
    }

    func testReadVerifyMismatchTwiceSurfacesErrorAndAdoptsExternal() async {
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),
            .init(.success(stdout: ""), file: "90"),
            .init(.success(stdout: "")),
            .init(.success(stdout: ""), file: "90"),     // mismatch again → surface (S-N4)
        ])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.confirm.status, .error(.limitMismatchAfterSet))
        XCTAssertEqual(engine.limit, .known(90), "the external value is adopted, never fought (S-N3)")
    }

    func testGetDegradedSetProceedsAdoptsLastWrittenWithCaveat() async {
        // A missing/broken Get must NOT block Set (sec 2) — LastSetTracker contingency.
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),                 // Set 80 works
            .init(.missingShortcut),                     // Get is broken
        ])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.limit, .known(80))
        // Nil SoC (no telemetry ingested) → no window, per the nil-SoC ruling; the Set itself and
        // its caveat are what this test is about and both are unchanged.
        XCTAssertEqual(engine.confirm.status, .requestedNoPromise)
        // State 3 (verified mode, readBackDegraded defaults false): a normally-working read failed this
        // once → keep the honest caveat, and NO positive soft confirmation.
        XCTAssertEqual(engine.engineNote, "couldn't verify the change (read-back unavailable)")
        XCTAssertNil(engine.confirm.transientConfirmation)
    }

    // MARK: - B1 soft confirmation routing (ISSUE-1)

    func testDegradedSet_softConfirmation_noScaryCaveat() async {
        // State 1: permanent-degraded mode + a successful Set whose read-back is unavailable → NO orange
        // caveat; instead a calm transient "Limit set to N%".
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),     // Set 80 works
            .init(.missingShortcut),         // read-back unavailable
        ])
        engine.readBackDegraded = true       // mirrors setupFlow.state == .readyDegraded
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.limit, .known(80))
        XCTAssertNil(engine.engineNote, "degraded success appends NO scary read-back caveat")
        XCTAssertEqual(engine.confirm.transientConfirmation, "Limit set to 80%")
    }

    func testRealSetFailure_routesToCommandFailed_noConfirmation_evenWhenDegraded() async {
        // State 2: a genuine Set failure must NOT be hidden by the degraded suppression — it goes through
        // commandFailed (here .setupRequired), never the read-back path, with no positive confirmation.
        let (engine, _, _, _) = makeEngine([.init(.missingShortcut)])   // the Set itself fails
        engine.readBackDegraded = true
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.confirm.status, .setupRequired)
        XCTAssertNil(engine.engineNote)
        XCTAssertNil(engine.confirm.transientConfirmation, "a real failure shows no positive confirmation")
    }

    // MARK: - S-N4 failure routing

    func testMissingSetShortcutSurfacesSetupRequiredNoRetry() async {
        let (engine, runner, _, _) = makeEngine([.init(.missingShortcut)])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.confirm.status, .setupRequired)
        XCTAssertEqual(runner.invocationNames, ["Battery Limit 80"], "missing is never auto-retried")
    }

    func testAutomationBlockedSurfacesCollapsedTaxonNoRetry() async {
        let (engine, runner, _, _) = makeEngine([.init(.automationBlocked(stderrTail: ""))])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.confirm.status, .error(.automationBlocked))
        XCTAssertEqual(runner.invocationNames.count, 1, "timeouts are never auto-retried (sec 2)")
    }

    func testNonzeroExitRetriedExactlyOnceThenSurfaces() async {
        let (engine, runner, _, _) = makeEngine([
            .init(.failed(exitCode: 3, stderrTail: "boom")),
            .init(.failed(exitCode: 3, stderrTail: "boom")),
        ])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.confirm.status, .error(.nonzeroExit(code: 3)))
        XCTAssertEqual(runner.invocationNames, ["Battery Limit 80", "Battery Limit 80"])
    }

    func testNonzeroExitRetrySucceeds() async {
        let (engine, _, _, _) = makeEngine([
            .init(.failed(exitCode: 3, stderrTail: "")),
            .init(.success(stdout: "")),
            .init(.success(stdout: ""), file: "80"),
        ])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.limit, .known(80))
    }

    func testInvalidTargetValueIsRejectedWithoutSpawning() async {
        let (engine, runner, _, _) = makeEngine()
        _ = await engine.userSetLimit(83)                // not a sanctioned step (sec 3)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: - CommandOutcome (audit keystone, item 1): the engine surfaces the verified result so
    // callers stop reconstructing success from a re-read of engine.limit. Each arm pinned.

    func testUserSetLimitReturnsAppliedOnVerifiedSet() async {
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),                 // Set 80
            .init(.success(stdout: ""), file: "80"),     // read-verify → confirms 80
        ])
        let outcome = await engine.userSetLimit(80)
        XCTAssertEqual(outcome, .applied, "a Set the post-read-verify CONFIRMED is .applied")
    }

    func testUserSetLimitReturnsAppliedUnconfirmedWhenReadBackUnavailable() async {
        // The Set went out but the Get read-back could not confirm the target → .appliedUnconfirmed,
        // NEVER .applied (the verified-vs-assumed split is the core of the fix). Degraded mode here.
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),                 // Set 80 works
            .init(.missingShortcut),                     // read-back unavailable
        ])
        engine.readBackDegraded = true                   // mirrors setupFlow.state == .readyDegraded
        let outcome = await engine.userSetLimit(80)
        XCTAssertEqual(outcome, .appliedUnconfirmed, "written but not read-verified → .appliedUnconfirmed")
        XCTAssertEqual(engine.limit, .known(80), "the as-set value is still adopted")
    }

    func testUserSetLimitReturnsInvalidTargetForNonStep() async {
        let (engine, runner, _, _) = makeEngine()
        let outcome = await engine.userSetLimit(83)      // not a sanctioned step
        XCTAssertEqual(outcome, .invalidTarget(83))
        XCTAssertTrue(runner.invocations.isEmpty, "an invalid target is rejected before any spawn")
    }

    func testUserSetLimitReturnsBusyWhenACommandIsInFlight() async {
        let runner = GatingShortcutRunner()              // holds the FIRST Set suspended until released
        let engine = ChargeLimitEngine(runner: runner)
        let first = Task { await engine.userSetLimit(80) }
        while !engine.commandInFlight { await Task.yield() }
        let second = await engine.userSetLimit(85)       // collides with the in-flight first
        XCTAssertEqual(second, .busy, "a Set while a command is in flight is rejected as .busy")
        runner.release()
        _ = await first.value
    }

    func testUserSetLimitReturnsMismatchWhenReadBackDisagrees() async {
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),                 // Set 80
            .init(.success(stdout: ""), file: "90"),     // verify → 90 (mismatch)
            .init(.success(stdout: "")),                 // retry Set 80
            .init(.success(stdout: ""), file: "90"),     // verify → 90 again → surface
        ])
        let outcome = await engine.userSetLimit(80)
        XCTAssertEqual(outcome, .mismatch(observed: 90), "the read-back disagreed → .mismatch(observed:)")
    }

    func testUserSetLimitReturnsIssueFailedWhenShortcutFails() async {
        let (engine, _, _, _) = makeEngine([.init(.missingShortcut)])   // the Set itself fails
        let outcome = await engine.userSetLimit(80)
        XCTAssertEqual(outcome, .issueFailed(.setupRequired),
                       "a shortcut/launch failure carries the existing CommandStatus taxon")
    }

    // MARK: - Pause (sec 5)

    private func snapshotWithSoC(_ soc: Int, t: TimeInterval = 0) -> ChargeTelemetrySnapshot {
        ChargeTelemetrySnapshot(timestamp: t, socPercent: soc, rawCapacity_mAh: 4000,
                                instantAmperage_mA: 2000, notChargingReason: 0,
                                isChargingFlag: true, externalConnected: true,
                                chargingCurrent_mA: 3000)
    }

    func testPauseAt87Sets85AndCapturesAbsorbedLimit() async {
        let (engine, runner, store, _) = makeEngine([
            .init(.success(stdout: ""), file: "100"),    // popover sync absorbs the user's 100
            .init(.success(stdout: "")),                 // Set 85 (pause target for SoC 87)
            .init(.success(stdout: ""), file: "85"),     // read-verify
        ])
        await engine.sync(.popoverOpen)
        XCTAssertEqual(engine.limit, .known(100))
        engine.ingest(snapshotWithSoC(87), state: .charging)
        _ = await engine.pause()
        XCTAssertEqual(runner.invocationNames.last, "Battery Limit Get")
        XCTAssertTrue(runner.invocationNames.contains("Battery Limit 85"))
        XCTAssertTrue(engine.isPaused)
        let capture = store.load()
        XCTAssertEqual(capture?.pausedFromLimit, 100, "Resume must restore the USER's value (S-N3)")
        XCTAssertEqual(capture?.pauseTarget, 85)
    }

    func testPauseBelow80UsesFloor() async {
        let (engine, runner, _, _) = makeEngine([
            .init(.success(stdout: "")),
            .init(.success(stdout: ""), file: "80"),
        ])
        engine.ingest(snapshotWithSoC(50), state: .discharging)
        _ = await engine.pause()
        XCTAssertTrue(runner.invocationNames.contains("Battery Limit 80"))
    }

    // MARK: - Resume (sec 5 + Grok SF2 pre-Resume Get)

    func testResumeVerifiesCaptureThenRestoresPausedFromValue() async {
        let capture = PauseCapture(pausedFromLimit: 85, pauseTarget: 80, capturedAt: Date())
        let (engine, runner, store, _) = makeEngine([
            .init(.success(stdout: ""), file: "80"),     // pre-Resume Get: still our pause value
            .init(.success(stdout: "")),                 // Set 85 (the captured user value)
            .init(.success(stdout: ""), file: "85"),     // read-verify
        ], capture: capture)
        XCTAssertTrue(engine.isPaused)
        _ = await engine.resume()
        XCTAssertEqual(runner.invocationNames,
                       ["Battery Limit Get", "Battery Limit 85", "Battery Limit Get"])
        XCTAssertFalse(engine.isPaused)
        XCTAssertNil(store.load(), "capture cleared on resume")
    }

    func testResumeDetectsExternalChangeAtThatMomentRestores100() async {
        let capture = PauseCapture(pausedFromLimit: 85, pauseTarget: 80, capturedAt: Date())
        let (engine, runner, _, _) = makeEngine([
            .init(.success(stdout: ""), file: "90"),     // pre-Resume Get: someone moved it
            .init(.success(stdout: "")),                 // Set 100 (capture invalidated NOW)
            .init(.success(stdout: ""), file: "100"),
        ], capture: capture)
        _ = await engine.resume()
        XCTAssertTrue(runner.invocationNames.contains("Battery Limit 100"))
        XCTAssertFalse(runner.invocationNames.contains("Battery Limit 85"))
        XCTAssertEqual(engine.engineNote, "limit was changed outside the app")
    }

    func testResumeGetDegradedRestoresCaptureWithCaveat() async {
        let capture = PauseCapture(pausedFromLimit: 85, pauseTarget: 80, capturedAt: Date())
        let (engine, runner, _, _) = makeEngine([
            .init(.automationBlocked(stderrTail: "")),   // pre-Resume Get impossible
            .init(.success(stdout: "")),                 // Set 85 anyway (sec 5 degraded mode)
            .init(.automationBlocked(stderrTail: "")),   // read-verify also impossible
        ], capture: capture)
        _ = await engine.resume()
        XCTAssertTrue(runner.invocationNames.contains("Battery Limit 85"))
        XCTAssertEqual(engine.engineNote,
                       "couldn't verify external changes; couldn't verify the change (read-back unavailable)")
        XCTAssertFalse(engine.isPaused)
    }

    func testResumeWithoutCaptureDefaults100NoPreGet() async {
        let (engine, runner, _, _) = makeEngine([
            .init(.success(stdout: "")),                 // straight to Set 100
            .init(.success(stdout: ""), file: "100"),
        ])
        _ = await engine.resume()
        XCTAssertEqual(runner.invocationNames, ["Battery Limit 100", "Battery Limit Get"])
    }

    func testResumeWithInvalidatedCaptureRestores100() async {
        var capture = PauseCapture(pausedFromLimit: 85, pauseTarget: 80, capturedAt: Date())
        capture.invalidatedByExternalChange = true
        let (engine, runner, _, _) = makeEngine([
            .init(.success(stdout: "")),                 // Set 100 — no pre-Get needed
            .init(.success(stdout: ""), file: "100"),
        ], capture: capture)
        _ = await engine.resume()
        XCTAssertEqual(runner.invocationNames, ["Battery Limit 100", "Battery Limit Get"])
        XCTAssertEqual(engine.engineNote, "limit was changed outside the app")
    }

    // MARK: - S-N4 retry budget shared across compositions (review finding #15)

    func testExitRetryExhaustsTheBudgetForMismatchReSet() async {
        // One automatic retry PER USER ACTION: a nonzero-exit retry consumes it, so a later
        // read-back mismatch in the SAME action surfaces immediately — no third Set.
        let (engine, runner, _, _) = makeEngine([
            .init(.failed(exitCode: 3, stderrTail: "")),  // Set fails…
            .init(.success(stdout: "")),                  // …the single retry lands
            .init(.success(stdout: ""), file: "90"),      // read-verify MISMATCH
        ])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.confirm.status, .error(.limitMismatchAfterSet))
        XCTAssertEqual(runner.invocationNames,
                       ["Battery Limit 80", "Battery Limit 80", "Battery Limit Get"],
                       "budget spent on the exit retry — no mismatch re-Set may follow")
        XCTAssertEqual(engine.limit, .known(90), "external value adopted (S-N3)")
    }

    // MARK: - sync failures surface (review findings #16/#28)

    func testSyncFailureSurfacesProblemAndSuccessClearsIt() async {
        let (engine, _, _, box) = makeEngine([
            .init(.automationBlocked(stderrTail: "")),
            .init(.success(stdout: ""), file: "80"),
        ])
        await engine.sync(.popoverOpen)
        XCTAssertEqual(engine.syncProblem, .automationBlocked)
        XCTAssertEqual(engine.limit, .unknown)
        box.now += ChargeLimitEngine.popoverOpenMinInterval   // B5: past the popover-open gate
        await engine.sync(.popoverOpen)
        XCTAssertNil(engine.syncProblem, "a successful read clears the surfaced problem")
        XCTAssertEqual(engine.limit, .known(80))
    }

    // MARK: - parse-failure string reachable (review findings #17/#33)

    func testUnparseableReadBackSurfacesTheFormatString() async {
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),                  // Set ok
            .init(.success(stdout: ""), file: "garbage"), // Get returns no in-range integer
        ])
        _ = await engine.userSetLimit(80)
        XCTAssertEqual(engine.limit, .known(80), "unparseable Get must not block the Set")
        XCTAssertEqual(engine.engineNote, ChargeStatusStrings.errorLabel(.getOutputUnparseable))
    }

    // MARK: - sec 5 Pause caveats (review findings #30/#41)

    func testPauseBelowFloorSurfacesFloorCaveat() async {
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),
            .init(.success(stdout: ""), file: "80"),
        ])
        engine.ingest(snapshotWithSoC(50), state: .discharging)
        _ = await engine.pause()
        XCTAssertEqual(engine.pauseCaveat, ChargeStatusStrings.pauseFloorCaveat)
    }

    func testPauseWithUnreadableSocSetsFloorNote_LOW2() async {
        // No telemetry ingested → SoC nil → PauseResumePolicy returns 80; the note explains why.
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),                  // Set 80 (the floor)
            .init(.success(stdout: ""), file: "80"),
        ])
        _ = await engine.pause()
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.pauseCaveat, "battery level unreadable - paused at the 80% floor")
    }

    func testPauseAbove95SurfacesBleedCaveatAndResumeClearsIt() async {
        let (engine, _, _, _) = makeEngine([
            .init(.success(stdout: "")),                  // Set 95 (pause target for SoC 97)
            .init(.success(stdout: ""), file: "95"),
            .init(.success(stdout: ""), file: "95"),      // pre-Resume Get (matches capture)
            .init(.success(stdout: "")),                  // restore Set
            .init(.success(stdout: ""), file: "100"),
        ])
        engine.ingest(snapshotWithSoC(97), state: .unknown)
        _ = await engine.pause()
        XCTAssertEqual(engine.pauseCaveat, ChargeStatusStrings.pauseBleedCaveat)
        _ = await engine.resume()
        XCTAssertNil(engine.pauseCaveat, "Resume clears the pause caveat")
    }

    func testBackstopIntervalPinnedToSpec() {
        XCTAssertEqual(ChargeLimitEngine.backstopMinInterval, 1800, "S-N3: at most every 30 min")
    }

    // MARK: - S-N3 sync triggers + absorption

    /// B-arc B5: the popover-open sync reads and adopts, but no longer on EVERY open — a reopen inside
    /// the gate reuses the value already held rather than spawning another `shortcuts run`.
    func testPopoverSyncReadsAndAdoptsThenRateLimitsTo60s() async {
        let (engine, runner, _, box) = makeEngine([
            .init(.success(stdout: ""), file: "90"),
            .init(.success(stdout: ""), file: "95"),
        ], clockStart: 1000)
        await engine.sync(.popoverOpen)
        XCTAssertEqual(engine.limit, .known(90), "the first open reads and adopts")
        await engine.sync(.popoverOpen)                  // immediate reopen → gated
        XCTAssertEqual(runner.invocations.count, 1, "a reopen inside the gate spawns no second Shortcuts run")
        XCTAssertEqual(engine.limit, .known(90), "and the adopted value is unchanged")
        box.now = 1000 + ChargeLimitEngine.popoverOpenMinInterval + 1
        await engine.sync(.popoverOpen)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(engine.limit, .known(95), "past the gate the open re-reads and adopts the new value")
    }

    /// The gate is popover-only: the safety-relevant triggers keep their own cadence. A wake landing
    /// immediately after a popover open must still read (S-N3 adoption is what makes the app honest).
    func testPopoverGateDoesNotSuppressWakeOrBackstop() async {
        let (engine, runner, _, _) = makeEngine([
            .init(.success(stdout: ""), file: "90"),
            .init(.success(stdout: ""), file: "95"),
            .init(.success(stdout: ""), file: "85"),
        ], clockStart: 1000)
        await engine.sync(.popoverOpen)
        await engine.sync(.wake)                         // same instant, different trigger → NOT gated
        XCTAssertEqual(engine.limit, .known(95))
        await engine.sync(.backstop)                     // first backstop of this engine → NOT gated
        XCTAssertEqual(engine.limit, .known(85))
        XCTAssertEqual(runner.invocations.count, 3, "only .popoverOpen consults the popover gate")
    }

    /// B5's sharpest edge: `.verify` is the PRECONDITION read a caller is about to act on (Top Up's
    /// pre-revert check). It must read every single time even back-to-back inside the popover window —
    /// a gated verify would let the revert Set proceed against a limit the user has since changed.
    func testVerifySyncIsNeverRateGated() async {
        let (engine, runner, _, _) = makeEngine([
            .init(.success(stdout: ""), file: "90"),
            .init(.success(stdout: ""), file: "95"),
            .init(.success(stdout: ""), file: "85"),
        ], clockStart: 1000)
        await engine.sync(.popoverOpen)                  // spends the popover budget
        await engine.sync(.verify)
        XCTAssertEqual(engine.limit, .known(95), "the verify read landed despite the fresh popover sync")
        await engine.sync(.verify)                       // and again, immediately
        XCTAssertEqual(engine.limit, .known(85))
        XCTAssertEqual(runner.invocations.count, 3, "every verify spends a real read — that is the point")
    }

    func testBackstopSyncIsRateLimitedTo30Min() async {
        let (engine, runner, _, box) = makeEngine([
            .init(.success(stdout: ""), file: "90"),
            .init(.success(stdout: ""), file: "95"),
        ], clockStart: 1000)
        await engine.sync(.backstop)
        await engine.sync(.backstop)                     // immediately again → must be skipped
        XCTAssertEqual(runner.invocations.count, 1, "backstop runs at most every 30 min (S-N3)")
        box.now = 1000 + 1801
        await engine.sync(.backstop)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(engine.limit, .known(95))
    }

    func testSyncUnavailableMakesLimitFirstClassUnknown() async {
        let (engine, _, _, _) = makeEngine([.init(.missingShortcut)])
        await engine.sync(.wake)
        XCTAssertEqual(engine.limit, .unknown)
    }

    // MARK: - 4.I addendum: persisted LastSetTracker custody

    func testCustodyPersistsAndSurvivesRelaunchInDegradedMode() async {
        let custody = MockLastSetCustodyStore()   // shared across the two "sessions"
        // Session 1: Set 80 with a degraded Get (no read-back) → adopt via LastSetTracker + persist.
        let (e1, _, _, _) = makeEngine([.init(.success(stdout: "")), .init(.missingShortcut)], custody: custody)
        _ = await e1.userSetLimit(80)
        XCTAssertEqual(e1.limit, .known(80))
        XCTAssertEqual(custody.load()?.value, 80, "custody is persisted on the Set")

        // Session 2 (relaunch): a NEW engine over the SAME store, Get still unavailable.
        let m2 = MockShortcutRunner([]); m2.fallback = .init(.missingShortcut)
        let e2 = ChargeLimitEngine(runner: m2, captureStore: MockPauseCaptureStore(),
                                   custodyStore: custody, clock: MockMonotonicClock(box: MockClockBox(0)))
        XCTAssertEqual(e2.limit, .known(80), "custody restored on launch → '· as set' value, not unknown")
        await e2.sync(.popoverOpen)
        XCTAssertEqual(e2.limit, .known(80), "a degraded sync KEEPS the custody, never blanks to unknown")
        XCTAssertEqual(e2.lastSetCustody?.value, 80)
    }

    func testNoCustodyStillFirstClassUnknownOnDegradedSync() async {
        // The first-class-unknown guarantee is intact when there is NO custody (fresh install).
        let (engine, _, _, _) = makeEngine([.init(.missingShortcut)])   // empty custody store
        await engine.sync(.popoverOpen)
        XCTAssertEqual(engine.limit, .unknown)
    }

    func testSyncDetectingExternalChangeInvalidatesPauseCapture() async {
        let capture = PauseCapture(pausedFromLimit: 100, pauseTarget: 85, capturedAt: Date())
        let (engine, _, store, _) = makeEngine([
            .init(.success(stdout: ""), file: "90"),     // != the pause target 85 → external
        ], capture: capture)
        await engine.sync(.wake)
        XCTAssertEqual(store.load()?.invalidatedByExternalChange, true)
        XCTAssertTrue(engine.isPaused, "still paused — only the capture is invalidated")
        XCTAssertEqual(engine.engineNote, "limit was changed outside the app")
    }

    // MARK: - ISSUE-11: an authoritative in-app Set supersedes a prior Pause (clears the stale latch)

    /// Repro→fixed: Pause, then an in-app Set lands → the battery resumes charging, so the latch +
    /// capture must clear (today they stranded, and Top Up then refused with "resume charging first").
    func testInAppSetWhilePausedClearsStaleLatch_ISSUE11() async {
        let (engine, _, store, _) = makeEngine([
            .init(.success(stdout: "")),                 // pause Set 85 (SoC 87)
            .init(.success(stdout: ""), file: "85"),     // pause read-verify
            .init(.success(stdout: "")),                 // userSetLimit(100) Set
            .init(.success(stdout: ""), file: "100"),    // read-verify
        ])
        engine.ingest(snapshotWithSoC(87), state: .charging)
        _ = await engine.pause()
        XCTAssertTrue(engine.isPaused, "precondition: paused")
        XCTAssertNotNil(store.load(), "precondition: capture saved")
        _ = await engine.userSetLimit(100)
        XCTAssertFalse(engine.isPaused, "an authoritative in-app Set supersedes the pause latch")
        XCTAssertNil(store.load(), "the pause capture is cleared on the superseding Set")
    }

    /// The .appIntent Set path (the "Set Charge Limit" App Shortcut) supersedes the pause too.
    func testInAppSetViaAppIntentWhilePausedClearsLatch_ISSUE11() async {
        let (engine, _, store, _) = makeEngine([
            .init(.success(stdout: "")),                 // pause Set 85
            .init(.success(stdout: ""), file: "85"),
            .init(.success(stdout: "")),                 // appIntent Set 90
            .init(.success(stdout: ""), file: "90"),
        ])
        engine.ingest(snapshotWithSoC(87), state: .charging)
        _ = await engine.pause()
        XCTAssertTrue(engine.isPaused)
        _ = await engine.userSetLimit(90, source: .appIntent)
        XCTAssertFalse(engine.isPaused, "the .appIntent Set path also supersedes the pause latch")
        XCTAssertNil(store.load())
    }

    /// The clear is UNCONDITIONAL on a didWrite Set — not gated on "raising". Guards a future
    /// "only clear if target > pauseTarget" regression: here the Set (80) is BELOW the pause target (85).
    func testInAppSetWhilePausedClearsRegardlessOfTargetValue_ISSUE11() async {
        let (engine, _, store, _) = makeEngine([
            .init(.success(stdout: "")),                 // pause Set 85 (SoC 87)
            .init(.success(stdout: ""), file: "85"),
            .init(.success(stdout: "")),                 // userSetLimit(80) — BELOW the 85 pause target
            .init(.success(stdout: ""), file: "80"),
        ])
        engine.ingest(snapshotWithSoC(87), state: .charging)
        _ = await engine.pause()
        XCTAssertTrue(engine.isPaused)
        _ = await engine.userSetLimit(80)
        XCTAssertFalse(engine.isPaused, "unconditional on didWrite — not gated on raising")
        XCTAssertNil(store.load())
    }

    /// didWrite NEGATIVE gate: a userSetLimit whose Set FAILS (non-didWrite) must NOT clear the latch
    /// or the capture (else the opposite strand — a failed Set silently un-pausing).
    func testInAppSetThatFailsLeavesLatchAndCaptureIntact_didWriteGate_ISSUE11() async {
        let (engine, _, store, _) = makeEngine([
            .init(.success(stdout: "")),                 // pause Set 85
            .init(.success(stdout: ""), file: "85"),     // pause read-verify
            .init(.missingShortcut),                     // userSetLimit Set FAILS → .issueFailed (didWrite == false)
        ])
        engine.ingest(snapshotWithSoC(87), state: .charging)
        _ = await engine.pause()
        XCTAssertTrue(engine.isPaused); XCTAssertNotNil(store.load())
        let outcome = await engine.userSetLimit(90)
        XCTAssertFalse(outcome.didWrite, "precondition: the Set did not land")
        XCTAssertTrue(engine.isPaused, "a failed Set must NOT clear the pause latch")
        XCTAssertNotNil(store.load(), "the capture stays intact on a failed Set")
    }

    // MARK: - launch reconcile seam (the behavior the verified-mode launch read relies on)
    // The launch wiring (BatteryApp.applicationDidFinishLaunching) is app-only; these cover the
    // engine seam it calls — sync(.wake) adopting a live read even when custody is already held.

    /// With custody held (so engine.limit starts at the persisted value), a sync(.wake) that reads a
    /// DIFFERING live value adopts the live value (reflecting a change made outside the app while off)
    /// and tags it human-primacy `.user` so a conflicting schedule rule defers to it for one trigger.
    func testWakeSyncWithCustodyAdoptsDifferingLiveValueAsUser() async {
        let custody = MockLastSetCustodyStore(LastSetCustody(value: 80, at: Date()))
        let (engine, _, _, _) = makeEngine(custody: custody)
        XCTAssertEqual(engine.limit, .known(80), "custody seeds the launch-time limit")
        // The live world says 95 — a change made while the app was off.
        let runner = MockShortcutRunner(); runner.fallback = .init(.success(stdout: ""), file: "95")
        let live = ChargeLimitEngine(runner: runner, captureStore: MockPauseCaptureStore(),
                                     custodyStore: custody, clock: MockMonotonicClock(box: MockClockBox(0)))
        XCTAssertEqual(live.limit, .known(80), "still custody before the read")
        await live.sync(.wake)
        XCTAssertEqual(live.limit, .known(95), "verified-mode reconcile adopts the live value over custody")
        XCTAssertEqual(live.lastCommandSource, .user, "a genuine external change is human-primacy (.user)")
    }

    /// A same-value sync must NOT flip lastCommandSource — else every wake/backstop re-sync would
    /// masquerade as a manual override and make the schedule skip its own just-applied rule.
    func testWakeSyncSameValueDoesNotFlipCommandSource() async {
        let runner = MockShortcutRunner(); runner.fallback = .init(.success(stdout: ""), file: "90")
        let engine = ChargeLimitEngine(runner: runner, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        _ = await engine.userSetLimit(90, source: .schedule)        // our own scheduled set lands at 90
        XCTAssertEqual(engine.limit, .known(90))
        XCTAssertEqual(engine.lastCommandSource, .schedule)
        await engine.sync(.wake)                                // wake re-reads the SAME value
        XCTAssertEqual(engine.limit, .known(90))
        XCTAssertEqual(engine.lastCommandSource, .schedule,
                       "a same-value re-sync is not a manual override — source stays .schedule")
    }
}

// MARK: - SWEEP H2 — an unreadable pause capture (the engine wiring)

/// The three-state load landed inert in `a7916df`'s sibling pass; this is the wiring that makes it
/// mean something, as the adversarial review amended it (SHIP AMENDED).
///
/// **RED-FIRST RECORD.** Every test in this class was written before the wiring and failed against the
/// pre-fix engine: `isPaused` came from `captureStore.load() != nil`, which is `nil` for `.corrupt`, so
/// a corrupt capture launched NOT paused (assertion failures on `isPaused`); `pauseRestorePointLost`
/// did not exist (compile failure — the strongest RED there is); and `resume()` cleared the key only
/// behind `guard outcome.didWrite`, so the failed-Set tests saw the blob survive.
///
/// **The autonomous-behaviour change, and its named new failure mode.** A garbage key now suspends the
/// whole schedule until the user presses Resume, and Resume then sets 100 though the user never paused.
/// That is accepted: the counterfactual is worse (`.corrupt ⇒ not paused` runs the scheduler while the
/// pack is *physically* capped, with no Resume affordance and no second witness — `engine.limit` and
/// `lastSetCustody` both read the PAUSE target). The write order proves the pack is capped: `pause()`
/// is SET-THEN-CAPTURE (`guard outcome.didWrite` precedes `captureStore.save`), so a capture write that
/// went wrong can only have happened AFTER the hold was applied. The obligation the trade buys is
/// DISCLOSURE — never present the 100 as a restore.
@MainActor
final class PauseCaptureCorruptWiringTests: XCTestCase {

    private func makeEngine(_ scripted: [MockShortcutRunner.Scripted] = [],
                            capture: PauseCapture? = nil,
                            corrupt: Bool = false)
    -> (ChargeLimitEngine, MockShortcutRunner, MockPauseCaptureStore) {
        let runner = MockShortcutRunner(scripted)
        let store = MockPauseCaptureStore(capture, corrupt: corrupt)
        let engine = ChargeLimitEngine(runner: runner, captureStore: store,
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        return (engine, runner, store)
    }

    // MARK: change 1 — the launch read

    func testACorruptCaptureLaunchesPaused() {
        let (engine, _, _) = makeEngine(corrupt: true)
        XCTAssertTrue(engine.isPaused,
                      "undecodable bytes under a key only pause() ever writes are evidence of a pause")
    }

    func testACorruptCaptureLaunchDisclosesTheLostRestorePoint() {
        let (engine, _, _) = makeEngine(corrupt: true)
        XCTAssertTrue(engine.pauseRestorePointLost)
        XCTAssertEqual(engine.pauseCaveat, ChargeStatusStrings.pauseRestorePointLostCaveat,
                       "the honesty goes on the IDLE surface, not only after the Resume click")
    }

    func testTheLegitimateEmptyStillLaunchesUnpausedAndSilent() {
        let (engine, _, _) = makeEngine()
        XCTAssertFalse(engine.isPaused, "`.none` must keep the scheduler running — this is the common case")
        XCTAssertFalse(engine.pauseRestorePointLost)
        XCTAssertNil(engine.pauseCaveat, "no pause means no restore point to warn about")
    }

    func testADecodableCaptureLaunchesPausedWithItsRestorePointIntact() {
        let (engine, _, _) = makeEngine(capture: PauseCapture(pausedFromLimit: 90, pauseTarget: 85,
                                                              capturedAt: Date()))
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(engine.pauseRestorePointLost, "a capture that decoded lost nothing")
        XCTAssertNil(engine.pauseCaveat)
    }

    // MARK: change 2 — Resume from corrupt goes to 100, and SAYS so

    func testResumeFromCorruptSetsOneHundredAndDisclosesIt() async {
        let (engine, runner, store) = makeEngine([
            .init(.success(stdout: "")),                  // Set 100
            .init(.success(stdout: ""), file: "100"),     // read-verify
        ], corrupt: true)
        let outcome = await engine.resume()
        XCTAssertTrue(outcome.didWrite)
        XCTAssertEqual(engine.limit, .known(100))
        XCTAssertEqual(engine.engineNote, ChargeStatusStrings.resumeRestorePointLostNote,
                       "100 is the uncapped, battery-ageing direction — it is disclosed, never a restore")
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(store.loadDetailed(), .none)
        XCTAssertFalse(engine.pauseRestorePointLost, "a completed Resume ends the disclosure")
        XCTAssertNil(engine.pauseCaveat)
        XCTAssertTrue(runner.invocationNames.contains { $0.contains("Set") || $0.contains("set") }
                      || !runner.invocationNames.isEmpty)
    }

    /// The contrast case: an ordinary resume must NOT wear the lost-restore-point sentence.
    func testResumeFromADecodableCaptureIsSilentAboutRestorePoints() async {
        let (engine, _, _) = makeEngine([
            .init(.success(stdout: ""), file: "85"),      // pre-Resume Get (SF2) — matches the pause target
            .init(.success(stdout: "")),                  // Set 90
            .init(.success(stdout: ""), file: "90"),      // read-verify
        ], capture: PauseCapture(pausedFromLimit: 90, pauseTarget: 85, capturedAt: Date()))
        _ = await engine.resume()
        XCTAssertEqual(engine.limit, .known(90), "the captured restore point is honoured")
        XCTAssertNil(engine.engineNote)
    }

    // MARK: amendment 3 — Resume on `.corrupt` ALWAYS drops the key

    /// Without this there is NO EXIT: corrupt → paused → Resume's Set fails → the key survives → the
    /// next launch re-arms the same ghost pause, forever. The named cost is accepted: the last evidence
    /// a pause existed is destroyed — evidence that was already unreadable.
    func testResumeFromCorruptDropsTheKeyEvenWhenTheSetFails() async {
        let (engine, _, store) = makeEngine([.init(.missingShortcut)], corrupt: true)
        let outcome = await engine.resume()
        XCTAssertFalse(outcome.didWrite, "precondition: the Set did not land")
        XCTAssertEqual(store.loadDetailed(), .none,
                       "the ghost-pause blob is dropped anyway — otherwise the next launch re-arms it")
        XCTAssertEqual(store.clearCount, 1)
        XCTAssertTrue(engine.isPaused,
                      "the pack really may still be held, so this session keeps showing the pause and its Resume")
    }

    /// A relaunch after that failed Resume: the key is gone, so no ghost pause is re-armed.
    func testTheNextLaunchAfterAFailedCorruptResumeIsNotPaused() async {
        let store = MockPauseCaptureStore(nil, corrupt: true)
        let first = ChargeLimitEngine(runner: MockShortcutRunner([.init(.missingShortcut)]),
                                      captureStore: store, custodyStore: MockLastSetCustodyStore(),
                                      clock: MockMonotonicClock(box: MockClockBox(0)))
        XCTAssertTrue(first.isPaused)
        _ = await first.resume()
        let relaunched = ChargeLimitEngine(runner: MockShortcutRunner(), captureStore: store,
                                           custodyStore: MockLastSetCustodyStore(),
                                           clock: MockMonotonicClock(box: MockClockBox(0)))
        XCTAssertFalse(relaunched.isPaused, "no exit-less ghost pause survives the restart")
        XCTAssertFalse(relaunched.pauseRestorePointLost)
    }

    /// The disclosure must survive the retry. After the failed Resume the blob is gone, so a naive
    /// re-read would say `.none` and set 100 SILENTLY — the exact thing the amendment forbids.
    func testRetryingAFailedCorruptResumeStillDiscloses() async {
        let (engine, _, _) = makeEngine([
            .init(.missingShortcut),                      // first Resume: Set fails
            .init(.success(stdout: "")),                  // retry: Set 100
            .init(.success(stdout: ""), file: "100"),     // read-verify
        ], corrupt: true)
        _ = await engine.resume()
        XCTAssertTrue(engine.pauseRestorePointLost, "the disclosure is sticky for the session, not the blob")
        let retry = await engine.resume()
        XCTAssertTrue(retry.didWrite)
        XCTAssertEqual(engine.engineNote, ChargeStatusStrings.resumeRestorePointLostNote,
                       "a retry that lands must not set 100 in silence")
    }

    /// THE BOUNDARY. Amendment 3 is scoped to `.corrupt`. A DECODABLE capture whose Resume Set fails
    /// keeps its blob — that restore point is still good and must survive for the retry.
    func testResumeFromADecodableCaptureWhoseSetFailsKeepsTheBlob() async {
        let cap = PauseCapture(pausedFromLimit: 90, pauseTarget: 85, capturedAt: Date())
        let (engine, _, store) = makeEngine([
            .init(.success(stdout: ""), file: "85"),      // pre-Resume Get
            .init(.missingShortcut),                      // Set FAILS
        ], capture: cap)
        let outcome = await engine.resume()
        XCTAssertFalse(outcome.didWrite)
        XCTAssertEqual(store.loadDetailed(), .capture(cap), "a good restore point is never destroyed")
        XCTAssertEqual(store.clearCount, 0)
        XCTAssertTrue(engine.isPaused)
    }

    // MARK: the disclosure's other exits

    func testAnAuthoritativeInAppSetEndsTheCorruptDisclosure() async {
        let (engine, _, store) = makeEngine([
            .init(.success(stdout: "")),
            .init(.success(stdout: ""), file: "80"),
        ], corrupt: true)
        XCTAssertTrue(engine.pauseRestorePointLost)
        _ = await engine.userSetLimit(80)
        XCTAssertFalse(engine.isPaused, "ISSUE-11: an in-app Set supersedes any prior pause intent")
        XCTAssertFalse(engine.pauseRestorePointLost, "…and the caveat that described it")
        XCTAssertEqual(store.loadDetailed(), .none)
    }

    func testAFreshPauseReplacesTheCorruptDisclosureWithARealCapture() async {
        let (engine, _, store) = makeEngine([
            .init(.success(stdout: "")),
            .init(.success(stdout: ""), file: "85"),
        ], corrupt: true)
        engine.ingest(ChargeTelemetrySnapshot(timestamp: 0, socPercent: 88, rawCapacity_mAh: 4000,
            instantAmperage_mA: 2000, notChargingReason: 0, isChargingFlag: true,
            externalConnected: true, chargingCurrent_mA: 3000), state: .charging)
        _ = await engine.pause()
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(engine.pauseRestorePointLost, "the new capture IS the restore point")
        XCTAssertNotEqual(engine.pauseCaveat, ChargeStatusStrings.pauseRestorePointLostCaveat)
        XCTAssertEqual(store.loadDetailed().capture?.pauseTarget, 85)
    }

    // MARK: the copy itself (amendment 2 — these sentences ARE the amendment, not polish)

    func testTheCorruptSentencesNeverClaimTheUserPausedAndNeverClaimARestore() {
        let card = ChargeStatusStrings.pauseRestorePointLostCaveat
        let note = ChargeStatusStrings.schedulePausedRestorePointLostNote
        let resume = ChargeStatusStrings.resumeRestorePointLostNote
        for s in [card, note] {
            XCTAssertFalse(s.contains("charging is paused"),
                           "the shared string was the defect: it reads as if the user pressed Pause")
            XCTAssertTrue(s.lowercased().contains("unreadable"), "name the actual condition")
            XCTAssertTrue(s.lowercased().contains("held") || s.lowercased().contains("hold"),
                          "say the pack may still be held — that is the part the user cannot see")
        }
        XCTAssertTrue(card.contains("100%"), "say where Resume will land, before it is pressed")
        XCTAssertFalse(resume.lowercased().contains("restored"),
                       "100 is the uncapped direction — never present it as a restore")
        XCTAssertTrue(resume.lowercased().contains("set it again"))
    }
}
