import XCTest

/// WI-N7: status-string tables (the normative wording), OBCAdvisor persistence, the pipeline
/// (props → history → classification → engine), and the single-poller cadence.
@MainActor
final class ChargeWiringTests: XCTestCase {

    // MARK: - status strings (sec 5 labels / sec 6 taxon strings)

    func testTelemetryLabelsNameTheTaxonomy() {
        XCTAssertEqual(ChargeStatusStrings.telemetryLabel(.limitHold, limit: .known(80)),
                       "Holding at limit (80%)")
        XCTAssertEqual(ChargeStatusStrings.telemetryLabel(.charging, limit: .unknown), "Charging")
        XCTAssertEqual(ChargeStatusStrings.telemetryLabel(.idleInhibit, limit: .unknown),
                       "Not charging — system idle")
        XCTAssertEqual(ChargeStatusStrings.telemetryLabel(.ambiguousHold, limit: .known(80)),
                       "Charging managed by macOS (check Optimized Battery Charging)")
        XCTAssertEqual(ChargeStatusStrings.telemetryLabel(.discharging, limit: .unknown),
                       "Discharging")
    }

    func testAutomationBlockedStringNamesBothHypothesesAndBothRoutes() {
        // Grok B3 (normative): ONE taxon, ONE string, BOTH hypotheses + BOTH recovery routes.
        let s = ChargeStatusStrings.errorLabel(.automationBlocked)
        XCTAssertTrue(s.contains("permission prompt may be waiting"), "hypothesis 1: waiting prompt")
        XCTAssertTrue(s.contains("silently denied"), "hypothesis 2: silent TCC block")
        XCTAssertTrue(s.contains("Approve the prompt"), "recovery route 1")
        XCTAssertTrue(s.contains("Privacy & Security → Automation"), "recovery route 2")
    }

    func testGetParseFailureStringBlamesFormatNotUser() {
        // sec 6: "Apple may have changed the action's output format", not a generic error.
        XCTAssertTrue(ChargeStatusStrings.errorLabel(.getOutputUnparseable)
            .contains("Apple may have changed the action's output format"))
    }

    func testEveryCommandStatusHasAStringExceptIdle() {
        XCTAssertNil(ChargeStatusStrings.commandLabel(.idle))
        let statuses: [CommandStatus] = [
            .confirming, .confirmedStop, .confirmedResume, .limitSetChargingToCap,
            .requestedNoPromise, .confirmInconclusive(.systemInhibit),
            .confirmInconclusive(.noCleanHoldObserved), .confirmFailed, .setupRequired,
            .error(.automationBlocked), .error(.shortcutsBinaryAbsent),
            .error(.nonzeroExit(code: 1)), .error(.launchFailed),
            .error(.getOutputUnparseable), .error(.limitMismatchAfterSet),
            .error(.telemetryReadFailure),
        ]
        for status in statuses {
            let label = ChargeStatusStrings.commandLabel(status)
            XCTAssertNotNil(label, "no user string for \(status)")
            XCTAssertFalse(label!.isEmpty, "empty user string for \(status)")
        }
    }

    func testB2HoldingTagReadsFromVerifiedLimitHold() {
        // limit/soc supplied but inert here — socPercent nil means the override branch never trips,
        // so this test isolates the verified-hold provenance exactly as before.
        func tag(_ s: TelemetryChargeState, _ paused: Bool) -> String {
            ChargeStatusStrings.limitProvenanceTag(telemetryState: s, isPaused: paused,
                                                   limit: .known(80), socPercent: nil)
        }
        // "· holding" ONLY on a verified .limitHold and not paused (matches the #26 glyph hold mark).
        XCTAssertEqual(tag(.limitHold, false), "· holding")
        XCTAssertEqual(tag(.limitHold, true),  "· as set", "paused: the stop is the user's, not the limit's")
        // Every other classified state stays "· as set" — including the ambiguous hold (no false claim).
        for s: TelemetryChargeState in [.ambiguousHold, .charging, .discharging, .idleInhibit, .unknown] {
            XCTAssertEqual(tag(s, false), "· as set", "\(s) is not a verified hold")
        }
    }

    // MARK: - 3.7 override-aware tag (native "Charge to 100% Now" charges PAST the set limit)

    func testTagShowsOverrideWhenChargingPastTheSetLimit() {
        // Live-validated signature (handoff): SoC 81, set limit 80, charging → the cap is not being
        // enforced right now (under enforcement charging stops at the limit and flips to a hold).
        // `.charging` while the SoC is strictly past our own set limit, limit < 100.
        let tag = ChargeStatusStrings.limitProvenanceTag(
            telemetryState: .charging, isPaused: false, limit: .known(80), socPercent: 81)
        XCTAssertEqual(tag, "· Overridden Externally")
    }

    func testOverrideBoundaryGuardDoesNotFlashAtTheLimit() {
        // The brief NORMAL top-off: the SoC just reaches the limit and is about to flip to a hold.
        // soc == v (not strictly past) must NOT trip the override text — that is the boundary guard.
        XCTAssertEqual(ChargeStatusStrings.limitProvenanceTag(
            telemetryState: .charging, isPaused: false, limit: .known(80), socPercent: 80),
            "· as set", "at-limit top-off (soc == limit) is not an override")
        // Charging up toward the limit (normal climb) is also just "· as set".
        XCTAssertEqual(ChargeStatusStrings.limitProvenanceTag(
            telemetryState: .charging, isPaused: false, limit: .known(80), socPercent: 60),
            "· as set", "charging toward the limit is not an override")
    }

    func testOverrideRequiresKnownLimitBelow100UnpausedAndKnownSoC() {
        // v == 100: no cap to exceed → never an override (even at soc 100).
        XCTAssertEqual(ChargeStatusStrings.limitProvenanceTag(
            telemetryState: .charging, isPaused: false, limit: .known(100), socPercent: 100),
            "· as set", "a 100% limit cannot be overridden")
        // Unknown limit: can't judge an override (no value to compare against).
        XCTAssertEqual(ChargeStatusStrings.limitProvenanceTag(
            telemetryState: .charging, isPaused: false, limit: .unknown, socPercent: 90),
            "· as set", "no known limit → no override claim")
        // nil SoC: can't judge.
        XCTAssertEqual(ChargeStatusStrings.limitProvenanceTag(
            telemetryState: .charging, isPaused: false, limit: .known(80), socPercent: nil),
            "· as set", "no SoC → no override claim")
        // Paused (a pause stop is the user's, not a native override) → never the override text.
        XCTAssertEqual(ChargeStatusStrings.limitProvenanceTag(
            telemetryState: .charging, isPaused: true, limit: .known(80), socPercent: 90),
            "· as set", "paused → no override")
    }

    func testVerifiedHoldWinsOverOverrideInputs() {
        // The override branch is keyed to `.charging`; a verified `.limitHold` (even with soc past the
        // limit) is still "· holding" — the verified hold is the truth, not a charge-proximity guess.
        XCTAssertEqual(ChargeStatusStrings.limitProvenanceTag(
            telemetryState: .limitHold, isPaused: false, limit: .known(80), socPercent: 90),
            "· holding")
    }

    func testB1SoftFailureWordingForTransientSetFailures() {
        // B1: the genuinely TRANSIENT Set failures read soft + actionable.
        XCTAssertEqual(ChargeStatusStrings.commandLabel(.error(.nonzeroExit(code: 1))),
                       "Couldn't set the limit. Try again.")
        XCTAssertEqual(ChargeStatusStrings.commandLabel(.error(.launchFailed)),
                       "Couldn't set the limit. Try again.")
        // The actionable / structural taxons KEEP their guidance (not replaced by the generic):
        XCTAssertEqual(ChargeStatusStrings.commandLabel(.setupRequired),
                       "Setup required — create the Battery Limit shortcuts.")
        XCTAssertTrue(ChargeStatusStrings.commandLabel(.error(.automationBlocked))!.contains("Automation"),
                      "automationBlocked keeps its permission-route guidance")
    }

    func testLOW1FullyChargedComposition() {
        // DISPLAY-LAYER rule: .unknown + onAC + (FullyCharged OR SoC>=99) → "Fully charged".
        func label(_ s: TelemetryChargeState, soc: Int?, full: Bool, ac: Bool) -> String {
            ChargeStatusStrings.composedTelemetryLabel(s, limit: .known(80),
                                                       socPercent: soc, fullyCharged: full, onAC: ac)
        }
        // Triggers
        XCTAssertEqual(label(.unknown, soc: 100, full: false, ac: true), "Fully charged")
        XCTAssertEqual(label(.unknown, soc: 99, full: false, ac: true), "Fully charged")
        XCTAssertEqual(label(.unknown, soc: 50, full: true, ac: true), "Fully charged")  // FullyCharged disjunct
        // Non-triggers
        XCTAssertEqual(label(.unknown, soc: 98, full: false, ac: true), "—", "below 99 and not full")
        XCTAssertEqual(label(.unknown, soc: 100, full: false, ac: false), "—", "must be on AC")
        XCTAssertEqual(label(.unknown, soc: nil, full: false, ac: true), "—", "unknown SoC, not full")
        // Other states are never overridden by the composition.
        XCTAssertEqual(label(.charging, soc: 100, full: true, ac: true), "Charging")
        XCTAssertEqual(label(.limitHold, soc: 100, full: true, ac: true), "Holding at limit (80%)")
        XCTAssertEqual(label(.discharging, soc: 99, full: false, ac: true), "Discharging")
    }

    func testPauseCaveatStringsStateTheHonestEnvelope() {
        // sec 5: (a) the sub-80 floor, (b) the above-95 bleed — surfaced, in plain words.
        XCTAssertTrue(ChargeStatusStrings.pauseFloorCaveat.contains("80%"))
        XCTAssertTrue(ChargeStatusStrings.pauseFloorCaveat.contains("rise"))
        XCTAssertTrue(ChargeStatusStrings.pauseBleedCaveat.contains("95%"))
        XCTAssertTrue(ChargeStatusStrings.pauseBleedCaveat.contains("discharge"))
    }

    func testLimitReadProblemLabelsRouteTheTaxonomy() {
        // The re-sync failure surface: blocked reads carry the full dual-hypothesis string;
        // unparseable reads carry the mandated format-change string (now reachable, #33).
        XCTAssertEqual(ChargeStatusStrings.limitReadProblemLabel(.automationBlocked),
                       ChargeStatusStrings.errorLabel(.automationBlocked))
        XCTAssertEqual(ChargeStatusStrings.limitReadProblemLabel(.outputUnparseable),
                       ChargeStatusStrings.errorLabel(.getOutputUnparseable))
        XCTAssertTrue(ChargeStatusStrings.limitReadProblemLabel(.missingShortcut)
            .contains("Battery Limit Get"))
        XCTAssertFalse(ChargeStatusStrings.limitReadProblemLabel(.runnerFailure).isEmpty)
    }

    func testRunnerTimeoutConstantsPinnedToSpec() {
        XCTAssertEqual(ShortcutsRunner.invocationTimeout, 15, "spec: 15 s hard timeout")
        XCTAssertEqual(ShortcutsRunner.sigkillGrace, 2, "spec: SIGTERM, 2 s grace, SIGKILL")
        XCTAssertEqual(OBCAdvisor.persistence, 180, "spec: ambiguous hold >= 3 min")
    }

    func testSystemInhibitStringDeclaresNoFault() {
        // sec 2: "the limit mechanism is not at fault and no failure is declared."
        let s = ChargeStatusStrings.commandLabel(.confirmInconclusive(.systemInhibit))!
        XCTAssertTrue(s.contains("not at fault"))
    }

    // MARK: - OBCAdvisor (sec 2: guidance after >=3 min of ambiguous hold)

    func testAdvisorGuidesAfterThreeMinutesOfAmbiguousHold() {
        let advisor = OBCAdvisor()
        advisor.observe(state: .ambiguousHold, at: 0)
        XCTAssertNil(advisor.guidance, "not yet — persistence required")
        advisor.observe(state: .ambiguousHold, at: 100)
        XCTAssertNil(advisor.guidance)
        advisor.observe(state: .ambiguousHold, at: 180)
        XCTAssertEqual(advisor.guidance, OBCAdvisor.guidanceText)
    }

    func testAdvisorResetsWhenStateLeavesAmbiguous() {
        let advisor = OBCAdvisor()
        advisor.observe(state: .ambiguousHold, at: 0)
        advisor.observe(state: .charging, at: 100)        // flicker out…
        advisor.observe(state: .ambiguousHold, at: 110)   // …and back: clock restarts
        advisor.observe(state: .ambiguousHold, at: 250)   // 140 s since re-entry: not enough
        XCTAssertNil(advisor.guidance)
        advisor.observe(state: .ambiguousHold, at: 290)   // 180 s since re-entry
        XCTAssertNotNil(advisor.guidance)
        advisor.observe(state: .limitHold, at: 300)       // clean hold clears the guidance
        XCTAssertNil(advisor.guidance)
    }

    func testAdvisorDeepLinkIsTheVerifiedBatteryPane() {
        XCTAssertEqual(OBCAdvisor.batterySettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.Battery-Settings.extension")
    }

    // MARK: - pipeline (props → snapshot → classify-with-LIVE-limit → engine)

    func testPipelineClassifiesAndFeedsEngine() async {
        let runner = MockShortcutRunner([
            .init(.success(stdout: "")),                 // Set 100
            .init(.success(stdout: ""), file: "100"),    // read-verify
        ])
        let box = MockClockBox(0)
        let engine = ChargeLimitEngine(runner: runner, captureStore: MockPauseCaptureStore(),
                                       clock: MockMonotonicClock(box: box))
        let pipeline = ChargeTelemetryPipeline(engine: engine, advisor: OBCAdvisor(),
                                               clock: MockMonotonicClock(box: box))

        // A limit-hold registry row arrives through the pipeline (NCR nested in ChargerData).
        var holdDict = ChargeFixtures.registryChargingDict()
        holdDict["InstantAmperage"] = 0
        holdDict["IsCharging"] = false
        holdDict["ChargerData"] = ["NotChargingReason": 0x0100_0000, "ChargingCurrent": 0]
        pipeline.ingestDiagnostics(holdDict)
        XCTAssertEqual(pipeline.telemetryState, .limitHold)

        // The engine demonstrably received that snapshot: a raise now arms the RESUME window
        // (which requires the pre-Set NCR hold to have been ingested).
        _ = await engine.userSetLimit(100)
        XCTAssertEqual(engine.confirm.status, .confirming)
    }

    func testPipelineTrimsHistory() {
        let runner = MockShortcutRunner()
        let box = MockClockBox(0)
        let engine = ChargeLimitEngine(runner: runner, captureStore: MockPauseCaptureStore(),
                                       clock: MockMonotonicClock(box: box))
        let pipeline = ChargeTelemetryPipeline(engine: engine, advisor: OBCAdvisor(),
                                               clock: MockMonotonicClock(box: box))
        for i in 0..<100 {
            box.now = TimeInterval(i * 10)
            pipeline.ingestDiagnostics(ChargeFixtures.registryChargingDict())
        }
        XCTAssertEqual(pipeline.history.count, 64, "history must trim, not grow unbounded")
    }

    // MARK: - single-poller cadence (sec 2)

    func testMonitorCadenceSwitchesWithoutSecondTimer() {
        let monitor = BatteryMonitor(reader: MockPowerSourceReader())
        XCTAssertEqual(monitor.pollInterval, 60, "passive default")
        monitor.setPollInterval(10)
        XCTAssertEqual(monitor.pollInterval, 10, "armed cadence")
        monitor.setPollInterval(10)   // no-op path
        XCTAssertEqual(monitor.pollInterval, 10)
        monitor.setPollInterval(60)
        XCTAssertEqual(monitor.pollInterval, 60)
    }

    func testMonitorDiagnosticsTapFiresWithRawProps() {
        let reader = MockPowerSourceReader()
        reader.diagnosticsProperties = ChargeFixtures.registryIdleInhibitDict()
        let monitor = BatteryMonitor(reader: reader)
        var tapped: [String: Any]?
        monitor.onDiagnosticsProperties = { tapped = $0 }
        monitor.refreshOnDemand()                        // drives refreshDiagnostics
        XCTAssertNotNil(tapped, "the charge-control tap must ride the existing read")
        XCTAssertEqual(tapped?["CurrentCapacity"] as? Int, 74)
    }

    func testMonitorReadFailureFiresFailureHookAndPipelineDegradesHonestly() {
        // sec 6 telemetry-read-failure (#31): a nil IOKit read must not freeze the last state.
        let reader = MockPowerSourceReader()
        reader.diagnosticsProperties = ChargeFixtures.registryChargingDict()
        let monitor = BatteryMonitor(reader: reader)
        let box = MockClockBox(0)
        let engine = ChargeLimitEngine(runner: MockShortcutRunner(),
                                       captureStore: MockPauseCaptureStore(),
                                       clock: MockMonotonicClock(box: box))
        let pipeline = ChargeTelemetryPipeline(engine: engine, advisor: OBCAdvisor(),
                                               clock: MockMonotonicClock(box: box))
        monitor.onDiagnosticsProperties = { pipeline.ingestDiagnostics($0) }
        monitor.onDiagnosticsReadFailure = { pipeline.noteDiagnosticsReadFailure() }

        monitor.refreshOnDemand()
        XCTAssertEqual(pipeline.telemetryState, .charging)
        XCTAssertFalse(pipeline.telemetryReadFailed)

        reader.diagnosticsProperties = nil               // the read starts failing
        monitor.refreshOnDemand()
        XCTAssertTrue(pipeline.telemetryReadFailed)
        XCTAssertEqual(pipeline.telemetryState, .unknown, "no frozen stale state on display")

        reader.diagnosticsProperties = ChargeFixtures.registryChargingDict()
        monitor.refreshOnDemand()                        // recovery clears the flag
        XCTAssertFalse(pipeline.telemetryReadFailed)
        XCTAssertEqual(pipeline.telemetryState, .charging)
    }
}
