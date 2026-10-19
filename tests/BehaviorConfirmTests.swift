import XCTest
import Combine

/// WI-N4: BOTH arming rules, the full verdict matrix, wake-gap invalidation, the
/// `.limitSetChargingToCap` lifecycle (resolve/clear/TTL-decay), mid-window + at-resolution
/// external-change aborts, generation-counter discard — and the explicit RACE test (a poll
/// racing a cancel must not publish from a dead window).
@MainActor
final class BehaviorConfirmTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Bounded deterministic drain: yields until `condition` (the async resolution chains are
    /// mock-driven — they settle within a handful of hops or not at all).
    private func drain(until condition: @autoclosure () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition never became true within the drain bound", file: file, line: line)
    }

    /// Stopped-flow sample (post-stop): −1051 mA tail, NCR already decayed handled elsewhere —
    /// NCR kept 0 here so the window logic (not the state machine) is what's under test.
    private func stoppedSample(t: TimeInterval, soc: Int = 84, raw: Int = 4425) -> ChargeTelemetrySnapshot {
        ChargeTelemetrySnapshot(timestamp: t, socPercent: soc, rawCapacity_mAh: raw,
                                instantAmperage_mA: -200, notChargingReason: 0,
                                isChargingFlag: false, externalConnected: true,
                                chargingCurrent_mA: 0)
    }

    private func chargingSample(t: TimeInterval, soc: Int = 80, raw: Int = 4223) -> ChargeTelemetrySnapshot {
        ChargeTelemetrySnapshot(timestamp: t, socPercent: soc, rawCapacity_mAh: raw,
                                instantAmperage_mA: 2496, notChargingReason: 0,
                                isChargingFlag: true, externalConnected: true,
                                chargingCurrent_mA: 3496)
    }

    /// Armed-not-flowing at the cap (the NCR=0 hold) — TTL-decay fodder.
    private func stagnantAtCap(t: TimeInterval, soc: Int = 80) -> ChargeTelemetrySnapshot {
        ChargeTelemetrySnapshot(timestamp: t, socPercent: soc, rawCapacity_mAh: 4200,
                                instantAmperage_mA: 31, notChargingReason: 0,
                                isChargingFlag: true, externalConnected: true,
                                chargingCurrent_mA: 3692)
    }

    // MARK: - arming rules (sec 2, BOTH directions)

    // MARK: - B1 transient soft confirmation

    func testTransientConfirmation_setsThenAutoClears() async {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.showTransientConfirmation("Limit set to 80%", clearAfter: 0.05)
        XCTAssertEqual(confirm.transientConfirmation, "Limit set to 80%", "renders immediately")
        try? await Task.sleep(nanoseconds: 250_000_000)   // 0.25s, well past the 0.05s clear window (no flake)
        XCTAssertNil(confirm.transientConfirmation, "auto-clears, never a standing line")
    }

    func testTransientConfirmation_clearedByNewCommand() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.showTransientConfirmation("Limit set to 80%", clearAfter: 60)   // long window: only a new action clears it
        XCTAssertEqual(confirm.transientConfirmation, "Limit set to 80%")
        confirm.commandIssued(target: 90, preSetNCR: nil, socAtSet: 50, telemetryState: .unknown, at: 0)
        XCTAssertNil(confirm.transientConfirmation, "a new command supersedes a stale confirmation")
    }

    func testTransientConfirmation_clearedByFailure() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.showTransientConfirmation("Limit set to 80%", clearAfter: 60)
        confirm.commandFailed(.setupRequired, at: 0)
        XCTAssertNil(confirm.transientConfirmation, "a failure clears the positive confirmation")
    }

    func testResumeConfirmArmsOnlyOffPreSetLimitHoldNCR() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        XCTAssertEqual(confirm.status, .confirming)
        XCTAssertTrue(confirm.isWindowArmed)
    }

    func testStopTransientNCRAlsoArmsResume() {
        // 0x01002080 carries the limit bit — a raise issued mid-decay still arms.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.stopTransient, socAtSet: 84,
                              telemetryState: .limitHold, at: 0)
        XCTAssertEqual(confirm.status, .confirming)
    }

    func testRaiseWithoutHoldNCRDoesNotArmResume() {
        // Raising from NCR=0 (not ambiguous-classified): no resume window — SoC below the new
        // limit routes to .limitSetChargingToCap instead. Target 90, not 100: a target of 100 arms
        // nothing at all now (no cap → no reachable clean exit), which would mask what this asserts.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 90, preSetNCR: 0, socAtSet: 80,
                              telemetryState: .unknown, at: 0)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
    }

    func testAmbiguousHoldRaisePublishesRequestedNoPromiseAndArmsNothing() {
        // S-N2: report, never promise — and no window that is expected to fail.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 100, preSetNCR: 0, socAtSet: 79,
                              telemetryState: .ambiguousHold, at: 0)
        XCTAssertEqual(confirm.status, .requestedNoPromise)
        XCTAssertFalse(confirm.isWindowArmed)
    }

    func testStopConfirmArmsOnlyWhenSocAtOrAboveNewLimit() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .confirming)
        XCTAssertTrue(confirm.isWindowArmed)
    }

    func testBelowLimitSetPublishesChargingToCapNotStopExpectation() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
    }

    // MARK: - verdicts

    func testConfirmedStopAfterTwoEvidenceSamples() async {
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        XCTAssertEqual(confirm.status, .confirming)   // one sample is not evidence enough
        confirm.ingest(stoppedSample(t: 20), state: .unknown)
        await drain(until: confirm.status == .confirmedStop)
        XCTAssertFalse(confirm.verdictWasDegraded)
        XCTAssertFalse(confirm.isWindowArmed)
    }

    func testConfirmedResumeAfterTwoFlowingSamples() async {
        let reader = MockLimitReader([.known(100)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        confirm.ingest(chargingSample(t: 10, raw: 4223), state: .charging)
        confirm.ingest(chargingSample(t: 20, raw: 4261), state: .charging)
        await drain(until: confirm.status == .confirmedResume)
    }

    // MARK: - the validated truth pair: the RAW half must never SILENTLY pass

    /// `stoppedSample` with the coulomb counter unreadable. This was the real shape of EVERY sample
    /// on macOS 27.0 before the parser's relocation ladder was restored (`AppleRawCurrentCapacity`
    /// moved to the pack child), and it stays the shape on any machine that publishes the key at no
    /// known rung.
    private func stoppedSampleNoRaw(t: TimeInterval, soc: Int = 84) -> ChargeTelemetrySnapshot {
        ChargeTelemetrySnapshot(timestamp: t, socPercent: soc, rawCapacity_mAh: nil,
                                instantAmperage_mA: -200, notChargingReason: 0,
                                isChargingFlag: false, externalConnected: true,
                                chargingCurrent_mA: nil)
    }

    private func chargingSampleNoRaw(t: TimeInterval, soc: Int = 80) -> ChargeTelemetrySnapshot {
        ChargeTelemetrySnapshot(timestamp: t, socPercent: soc, rawCapacity_mAh: nil,
                                instantAmperage_mA: 2496, notChargingReason: 0,
                                isChargingFlag: true, externalConnected: true,
                                chargingCurrent_mA: nil)
    }

    /// THE DEFECT. With the RAW half unreadable both evidence guards used to fall through to
    /// `?? true`, so a stop confirmation published on amperage ALONE while claiming the full
    /// two-signal verdict. The verdict may still stand (amperage is the dominant term and hard
    /// failure would be a lie in the other direction) — but it must SAY it had less evidence.
    func testStopConfirmWithoutRawEvidenceSaysItHadLessEvidence() async {
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSampleNoRaw(t: 10), state: .unknown)
        confirm.ingest(stoppedSampleNoRaw(t: 20), state: .unknown)
        await drain(until: confirm.status == .confirmedStop)
        XCTAssertNotNil(confirm.statusNote,
                        "a truth pair missing half its evidence must not publish silently")
    }

    func testResumeConfirmWithoutRawEvidenceSaysItHadLessEvidence() async {
        let reader = MockLimitReader([.known(100)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        confirm.ingest(chargingSampleNoRaw(t: 10), state: .charging)
        confirm.ingest(chargingSampleNoRaw(t: 20), state: .charging)
        await drain(until: confirm.status == .confirmedResume)
        XCTAssertNotNil(confirm.statusNote)
    }

    /// The other side of the same coin: with BOTH halves present the verdict is whole and must
    /// carry NO caveat — otherwise the honest note becomes noise everyone learns to ignore.
    func testConfirmWithRawEvidencePresentCarriesNoReducedEvidenceNote() async {
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)
        await drain(until: confirm.status == .confirmedStop)
        XCTAssertNil(confirm.statusNote)
        XCTAssertFalse(confirm.verdictWasDegraded)
    }

    /// Regression guard on the OTHER two states: a RAW trend that CONTRADICTS the flow reading must
    /// still veto the evidence (a pack whose coulomb counter is climbing has not stopped charging,
    /// whatever the instantaneous amperage says). The window then expires honestly.
    func testRisingRawStillVetoesStopEvidence() async {
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        // Flow reads "stopped" throughout; RAW climbs 600 mAh per sample, far past the ±100 jitter.
        var raw = 4425
        for t in stride(from: 10.0, through: 60, by: 10) {
            confirm.ingest(stoppedSample(t: t, raw: raw), state: .unknown)
            raw += 600
        }
        await drain(until: confirm.status == .confirmFailed)
        XCTAssertNotEqual(confirm.status, .confirmedStop)
    }

    func testResumeWindowExpiryPublishesConfirmFailed() async {
        // From a GENUINE hold (NCR=0x01000000), non-resume within the window IS a failure.
        let reader = MockLimitReader([.known(100)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        for t in stride(from: 10.0, through: 120, by: 10) {
            confirm.ingest(stagnantAtCap(t: t), state: .unknown)
            await Task.yield()   // let the half-time check (matching value) settle mid-loop
        }
        await drain(until: confirm.status == .confirmFailed)
    }

    func testMidWindowIdleInhibitPublishesInconclusiveSystemInhibit() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        confirm.ingest(ChargeFixtures.idleInhibitQuiet(t: 10), state: .idleInhibit)
        XCTAssertEqual(confirm.status, .confirmInconclusive(.systemInhibit))
        XCTAssertFalse(confirm.isWindowArmed)
    }

    func testUnplugDuringConfirmWindowClearsToIdle() {
        // Flagged interpretation: an unplug is a user act, not a mechanism verdict.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        confirm.ingest(ChargeFixtures.dischargingOnBattery(t: 10), state: .discharging)
        XCTAssertEqual(confirm.status, .idle)
        XCTAssertFalse(confirm.isWindowArmed)
    }

    // MARK: - wake-gap invalidation (S-N5)

    func testWakeGapInvalidatesAndRestartsWindowNoStaleVerdict() async {
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)     // streak 1 (pre-sleep)
        // Nap: next sample 90 s later (>30 s gap). The pre-sleep streak must NOT combine with
        // post-sleep samples into a verdict; the window restarts at t=100.
        confirm.ingest(stoppedSample(t: 100), state: .unknown)    // restart + re-baseline only
        XCTAssertEqual(confirm.status, .confirming)               // alive, not expired, no verdict
        confirm.ingest(stoppedSample(t: 110), state: .unknown)    // fresh streak 1
        XCTAssertEqual(confirm.status, .confirming)
        confirm.ingest(stoppedSample(t: 120), state: .unknown)    // fresh streak 2 → verdict
        await drain(until: confirm.status == .confirmedStop)
    }

    func testWindowExpiryMeasuresFromRestartNotOriginalArming() {
        // At t=100 the original 60 s stop window would be long expired — but the t=100 sample
        // RESTARTED it, so no .confirmFailed may fire before t=160.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stagnantAtCap(t: 10, soc: 84), state: .unknown)
        confirm.ingest(stagnantAtCap(t: 100, soc: 84), state: .unknown)   // gap → restart
        XCTAssertEqual(confirm.status, .confirming)
        confirm.ingest(stagnantAtCap(t: 130, soc: 84), state: .unknown)   // 30 s into restarted window
        XCTAssertEqual(confirm.status, .confirming)                        // still alive
    }

    func testIdleInhibitOnFirstSampleAfterGapRestartsInsteadOfInconclusive() {
        // "while awake": a 0x80 arriving WITH the wake gap is the nap's signature — restart,
        // don't blame the mechanism.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        confirm.ingest(chargingSample(t: 10), state: .charging)
        confirm.ingest(ChargeFixtures.idleInhibitQuiet(t: 200), state: .idleInhibit)  // gap first
        XCTAssertEqual(confirm.status, .confirming)   // restarted, NOT .confirmInconclusive
        XCTAssertTrue(confirm.isWindowArmed)
    }

    // MARK: - .limitSetChargingToCap lifecycle

    func testCapResolvesToConfirmedStopOnObservedLimitHold() async {
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        confirm.ingest(chargingSample(t: 10, soc: 76), state: .charging)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)   // still climbing
        confirm.ingest(ChargeFixtures.limitHold80(t: 20), state: .limitHold)
        await drain(until: confirm.status == .confirmedStop)
    }

    func testCapClearsToIdleOnUnplug() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        confirm.ingest(ChargeFixtures.dischargingOnBattery(t: 10), state: .discharging)
        XCTAssertEqual(confirm.status, .idle)
    }

    func testCapClearsOnSupersede() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        confirm.supersede()
        XCTAssertEqual(confirm.status, .idle)
        XCTAssertFalse(confirm.isWindowArmed)
    }

    func testCapTTLDecaysToNoCleanHoldObserved() {
        // The NCR=0/OBC hold at the cap: SoC at target, no flow, NO 0x01000000 — for 15 min.
        // (run-02's invisible morning blocker, now with an honest name.)
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 900, by: 10) {
            confirm.ingest(stagnantAtCap(t: t), state: .ambiguousHold)
        }
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)    // 890 s stagnant: not yet
        confirm.ingest(stagnantAtCap(t: 910), state: .ambiguousHold)
        XCTAssertEqual(confirm.status, .confirmInconclusive(.noCleanHoldObserved))
        XCTAssertFalse(confirm.isWindowArmed)
    }

    func testCapTTLResetsWhenFlowResumes() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 400, by: 10) {
            confirm.ingest(stagnantAtCap(t: t), state: .ambiguousHold)
        }
        confirm.ingest(chargingSample(t: 410, soc: 80, raw: 4250), state: .charging)  // flow → reset
        for t in stride(from: 420.0, through: 1300, by: 10) {
            confirm.ingest(stagnantAtCap(t: t), state: .ambiguousHold)
        }
        // Stagnant only since t=420 → 880 s: the TTL must NOT have fired yet.
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        confirm.ingest(stagnantAtCap(t: 1320), state: .ambiguousHold)   // 900 s since reset
        XCTAssertEqual(confirm.status, .confirmInconclusive(.noCleanHoldObserved))
    }

    // MARK: - audit B1: the UNCONDITIONAL ceiling (SoC parked BELOW the target)

    func testCapCeilingResolvesWhenSocParksBelowTarget() {
        // THE DEFECT. Apple's OBC holds the pack at 80 while our target is higher. `atOrPastTarget`
        // is false on every sample, so the 15-min stagnation TTL never starts — before the
        // ceiling this window had NO reachable exit: the scheduler deferred forever ("the app
        // was busy") and polling pinned at 10 s indefinitely.
        // The flagship illustration used to be a target of 100; that target no longer arms a window
        // at all, so the case is now carried at a REAL cap of 95 — just as reachable (OBC parks at
        // 80 whatever our cap is) and the ceiling is still the only exit.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        for t in stride(from: 10.0, through: 7190, by: 10) {
            confirm.ingest(stagnantAtCap(t: t, soc: 80), state: .ambiguousHold)   // 80 < target 95
        }
        // Far past the 900 s stagnation TTL and still armed — proof the stagnation clock is not
        // what resolves this window, and that nothing else exits it either.
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        XCTAssertTrue(confirm.isWindowArmed)

        confirm.ingest(stagnantAtCap(t: 7200, soc: 80), state: .ambiguousHold)   // ceiling
        XCTAssertEqual(confirm.status, .confirmInconclusive(.neverReachedLimit),
                       "80 against a target of 95 never got near the limit — the honest taxon")
        XCTAssertFalse(confirm.isWindowArmed, "the ceiling must actually disarm — that is the point")
    }

    func testCapCeilingIsAnchoredToArmingAndSurvivesWakeGapRestart() {
        // S-N5 restarts EVIDENCE on a nap; it must not restart the window's absolute lifetime,
        // or a machine that naps periodically would defeat the ceiling the same way.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 3600, by: 10) {
            confirm.ingest(stagnantAtCap(t: t, soc: 80), state: .ambiguousHold)
        }
        confirm.ingest(stagnantAtCap(t: 3700, soc: 80), state: .ambiguousHold)   // 100 s gap → restart
        XCTAssertTrue(confirm.isWindowArmed, "the nap restarts the window, it does not resolve it")
        for t in stride(from: 3710.0, through: 7290, by: 10) {
            confirm.ingest(stagnantAtCap(t: t, soc: 80), state: .ambiguousHold)
        }
        // t=7290 is 7190 s of SAMPLED time (7290 elapsed less the 100 s banked gap) — not yet.
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        confirm.ingest(stagnantAtCap(t: 7300, soc: 80), state: .ambiguousHold)
        XCTAssertEqual(confirm.status, .confirmInconclusive(.neverReachedLimit),
                       "ceiling anchored to ARMING (t=0) less banked gaps, NOT to the post-nap restart "
                     + "— a restart-anchored clock would not expire until t=10900")
    }

    func testStagnationTTLStillAcceleratesFarAheadOfTheCeiling() {
        // The Grok-mandated 15-min TTL is untouched: at/past the target it must still resolve at
        // 900 s — one eighth of the ceiling. The ceiling is a backstop, never the normal exit.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 900, by: 10) {
            confirm.ingest(stagnantAtCap(t: t, soc: 80), state: .ambiguousHold)   // 80 >= target 80
        }
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        confirm.ingest(stagnantAtCap(t: 910, soc: 80), state: .ambiguousHold)
        XCTAssertEqual(confirm.status, .confirmInconclusive(.noCleanHoldObserved))
        XCTAssertLessThan(910, BehaviorConfirm.Tunables().capMaxWindow_s,
                          "the stagnation clock must ACCELERATE the decay, never trail the ceiling")
    }

    func testGenuineLimitHoldShortCircuitsEvenLateInACeilingBoundWindow() async {
        // The ceiling must not steal the good outcome: a clean hold arriving deep into a long
        // below-target climb still publishes `.confirmedStop`, not the inconclusive taxon.
        let reader = MockLimitReader([.known(95)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 7000, by: 10) {     // 200 s short of the ceiling
            confirm.ingest(chargingSample(t: t, soc: 90), state: .charging)
        }
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        confirm.ingest(ChargeFixtures.limitHold80(t: 7010), state: .limitHold)
        await drain(until: confirm.status == .confirmedStop)
        XCTAssertFalse(confirm.isWindowArmed)
    }

    // MARK: - external-change aborts (Grok B1)

    func testHalfTimeExternalChangeAbortsWindowAdoptsValueNoVerdict() async {
        let reader = MockLimitReader([.known(85)])    // someone moved the slider mid-window
        let confirm = BehaviorConfirm(limitReader: reader)
        var adopted: ChargeLimitValue?
        confirm.onAdoptExternalLimit = { adopted = $0 }
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        // Real armed cadence: 10 s samples (a single t=60 sample would read as a NAP and
        // restart the window — the wake-gap rule, separately tested). t=60 crosses 120/2.
        for t in stride(from: 10.0, through: 60, by: 10) {
            confirm.ingest(stagnantAtCap(t: t), state: .unknown)
        }
        await drain(until: confirm.status == .idle)
        XCTAssertEqual(adopted, .known(85))
        XCTAssertEqual(confirm.statusNote, "limit was changed outside the app")
        XCTAssertFalse(confirm.isWindowArmed)
        // Late evidence from the dead window publishes nothing.
        confirm.ingest(chargingSample(t: 70), state: .charging)
        confirm.ingest(chargingSample(t: 80), state: .charging)
        await Task.yield()
        XCTAssertEqual(confirm.status, .idle)
    }

    func testAtResolutionMismatchSuppressesVerdictAndAdopts() async {
        let reader = MockLimitReader([.known(100)])   // mismatch discovered AT resolution
        let confirm = BehaviorConfirm(limitReader: reader)
        var adopted: ChargeLimitValue?
        confirm.onAdoptExternalLimit = { adopted = $0 }
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)   // evidence complete → check
        await drain(until: confirm.status == .idle)
        XCTAssertEqual(adopted, .known(100))
        XCTAssertNotEqual(confirm.status, .confirmedStop)
    }

    func testGetDegradedVerdictCarriesCaveat() async {
        // No LimitReader (Get-degraded): the verdict still publishes, with the standing caveat.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)
        await drain(until: confirm.status == .confirmedStop)
        XCTAssertTrue(confirm.verdictWasDegraded)
    }

    // MARK: - THE RACE (WI-N4 explicit requirement)

    func testPollRacingSupersedeNeverPublishesFromDeadWindow() async {
        // Choreography: evidence completes → at-resolution read-back PARKS → a new user command
        // supersedes (same monotonic instant — the edge case) → the parked read-back returns
        // MATCHING. The dead window's verdict must be discarded by the generation counter.
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)

        var published: [CommandStatus] = []
        confirm.$status.sink { published.append($0) }.store(in: &cancellables)

        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        await reader.parkNext()
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)   // verdict ready → check parks
        await reader.waitUntilParked()

        // Supersede at the SAME monotonic timestamp as the last sample (t=20).
        confirm.commandIssued(target: 90, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .unknown, at: 20)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)  // the new command's status

        await reader.release()                                   // dead window's read-back lands
        for _ in 0..<100 { await Task.yield() }                  // give a wrong publish every chance

        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        XCTAssertFalse(published.contains(.confirmedStop),
                       "a verdict from a superseded window must NEVER publish")
    }

    // MARK: - generation discipline on EVERY termination (review finding #6, BLOCKING)

    func testPublishedVerdictKillsLateHalfTimeRead() async {
        // A half-time read parks; the window then resolves and PUBLISHES; the parked read
        // finally returns a MISMATCH. Publishing must have bumped the generation — the late
        // read must neither adopt nor overwrite the verdict.
        let reader = MockLimitReader([.known(100), .known(85)])
        let confirm = BehaviorConfirm(limitReader: reader)
        var adopted: ChargeLimitValue?
        confirm.onAdoptExternalLimit = { adopted = $0 }
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        await reader.parkNext()
        for t in stride(from: 10.0, through: 60, by: 10) {       // crosses 120/2 → parks
            confirm.ingest(stagnantAtCap(t: t), state: .unknown)
        }
        await reader.waitUntilParked()
        confirm.ingest(chargingSample(t: 70), state: .charging)   // evidence…
        confirm.ingest(chargingSample(t: 80), state: .charging)   // …complete → resolution read
        await drain(until: confirm.status == .confirmedResume)    // (resolution got .known(100))
        await reader.release()                                    // late half-time read: .known(85)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(confirm.status, .confirmedResume, "late read must not overwrite the verdict")
        XCTAssertNil(adopted, "late read must not adopt")
        XCTAssertNil(confirm.statusNote)
    }

    func testWakeGapRestartKillsInFlightResolutionRead() async {
        // Evidence resolves and the read-back parks; the machine then NAPS; the post-wake
        // sample restarts the window (new incarnation). The parked pre-sleep read returning a
        // MATCH must not publish — no verdict from stale pre-sleep samples (S-N5).
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        await reader.parkNext()
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)     // resolution read parks
        await reader.waitUntilParked()
        confirm.ingest(stoppedSample(t: 120), state: .unknown)    // 100 s gap → restart
        await reader.release()                                    // stale read returns MATCH
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(confirm.status, .confirming, "stale resolution must not publish")
        XCTAssertTrue(confirm.isWindowArmed, "the restarted window stays armed")
    }

    // MARK: - at-resolution check on INCONCLUSIVE resolutions (review finding #7, MAJOR)

    func testSystemInhibitResolutionAbortsOnExternalMismatch() async {
        // Grok B1 runs at EVERY resolution: if the read-back at a systemInhibit resolution
        // shows an external change, the window cancels (no verdict), adopts, says so.
        let reader = MockLimitReader([.known(85)])
        let confirm = BehaviorConfirm(limitReader: reader)
        var adopted: ChargeLimitValue?
        confirm.onAdoptExternalLimit = { adopted = $0 }
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        confirm.ingest(ChargeFixtures.idleInhibitQuiet(t: 10), state: .idleInhibit)
        await drain(until: confirm.status == .idle)
        XCTAssertEqual(adopted, .known(85))
        XCTAssertEqual(confirm.statusNote, "limit was changed outside the app")
    }

    func testSystemInhibitResolutionPublishesWhenReadBackMatches() async {
        let reader = MockLimitReader([.known(100)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                              telemetryState: .limitHold, at: 0)
        confirm.ingest(ChargeFixtures.idleInhibitQuiet(t: 10), state: .idleInhibit)
        await drain(until: confirm.status == .confirmInconclusive(.systemInhibit))
        XCTAssertFalse(confirm.verdictWasDegraded)
    }

    // MARK: - verdict-matrix holes (review findings #35, #36)

    func testStopWindowExpiryPublishesConfirmFailed() async {
        // Stop-direction expiry: charging persists past the 60 s stop window → honest failure.
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 60, by: 10) {
            confirm.ingest(chargingSample(t: t, soc: 84, raw: 4400 + Int(t)), state: .charging)
            await Task.yield()
        }
        await drain(until: confirm.status == .confirmFailed)
    }

    func testStopWindowSystemInhibitIsInconclusiveToo() async {
        // Stop-direction mid-window 0x80: same no-fault rule as the resume direction.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(ChargeFixtures.idleInhibitQuiet(t: 10), state: .idleInhibit)
        await drain(until: confirm.status == .confirmInconclusive(.systemInhibit))
    }

    func testCapClearsOnExternalLimitChange() async {
        // The third spec-enumerated clear trigger: an external change detected at the cap
        // half-time check clears .limitSetChargingToCap (no verdict), adopts, notes.
        let reader = MockLimitReader([.known(90)])
        let confirm = BehaviorConfirm(limitReader: reader)
        var adopted: ChargeLimitValue?
        confirm.onAdoptExternalLimit = { adopted = $0 }
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        for t in stride(from: 10.0, through: 450, by: 10) {       // crosses the 900/2 half-time
            confirm.ingest(chargingSample(t: t, soc: 76), state: .charging)
        }
        await drain(until: confirm.status == .idle)
        XCTAssertEqual(adopted, .known(90))
        XCTAssertEqual(confirm.statusNote, "limit was changed outside the app")
    }

    // MARK: - the ceiling must count SAMPLED time, not calendar time (review BLOCKING 1)

    func testOvernightSleepDoesNotResolveASuccessfulChargeAsAWarning() async {
        // THE DEFECT. `CLOCK_MONOTONIC` runs through system sleep, so a Set at 18:00 with SoC 73,
        // lid closed, waking at 04:00 arrives with ~36 ks on the clock: sample 1 takes the wake-gap
        // early return and evaluates nothing, sample 2 blows the 2-h ceiling instantly and reports
        // "Optimized Battery Charging or a stale hold is likely managing charging" after a charge
        // that in fact succeeded. The 7200 s constant is a claim about CHARGING DURATION; the clock
        // was measuring calendar time.
        // (An earlier version of this comment added "on this machine `.limitHold` has NEVER been
        // observed (0 of 6,312 recorded samples)". That claim is WITHDRAWN — §7.8: the sample
        // window was entirely at limit == 100. The defect this test pins never depended on it.)
        let confirm = BehaviorConfirm(limitReader: nil)
        var published: [CommandStatus] = []
        confirm.$status.sink { published.append($0) }.store(in: &cancellables)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 300, by: 10) {          // a few minutes awake, climbing
            confirm.ingest(chargingSample(t: t, soc: 75), state: .charging)
        }
        // Lid closed at ~00:05, machine wakes 10 h later.
        let wake = 300.0 + 36_000
        confirm.ingest(chargingSample(t: wake, soc: 100), state: .charging)          // wake-gap sample
        XCTAssertTrue(confirm.isWindowArmed, "the wake sample restarts the window, it does not resolve it")
        confirm.ingest(chargingSample(t: wake + 10, soc: 100), state: .charging)     // the killer sample
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(confirm.status, .limitSetChargingToCap,
                       "10 h of SLEEP is not 10 h of charging: the ceiling must not have fired")
        XCTAssertTrue(confirm.isWindowArmed)
        XCTAssertFalse(published.contains(.confirmInconclusive(.neverReachedLimit)))
        XCTAssertFalse(published.contains(.confirmInconclusive(.noCleanHoldObserved)))
    }

    func testBankedGapsAccumulateAcrossSeveralNaps() async {
        // Every gap is banked, not just the first — otherwise a machine that naps repeatedly still
        // drifts into the ceiling on calendar time.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        var t = 0.0
        for _ in 0..<7 {                                   // 7 × (600 s awake + 600 s napping)
            for _ in 0..<60 { t += 10; confirm.ingest(chargingSample(t: t, soc: 80), state: .charging) }
            t += 600                                       // nap: banked, not charged to the ceiling
            confirm.ingest(chargingSample(t: t, soc: 80), state: .charging)
        }
        // 8.4 ks of calendar time, 4.2 ks of it asleep → 4.2 ks sampled.
        XCTAssertGreaterThan(t, 7200, "calendar time is past the ceiling…")
        XCTAssertEqual(confirm.status, .limitSetChargingToCap, "…but sampled time is not")
        XCTAssertTrue(confirm.isWindowArmed)
    }

    // MARK: - a nil SoC must not arm .chargingToCap (review BLOCKING 4)

    func testUnreadableSocArmsNoCapWindow() {
        // `raising` defaults to true on a nil SoC and the stop-confirm arm needs a non-nil SoC, so
        // an unreadable pack used to FALL INTO `.chargingToCap` — where `socPercent ?? Int.min`
        // then pins `atOrPastTarget` false forever, killing the 900 s TTL and leaving the 2-h
        // ceiling as the only exit. A telemetry glitch resolved as a charge-management warning.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: nil,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .requestedNoPromise,
                       "report, don't promise: there was no evidence to confirm against")
        XCTAssertFalse(confirm.isWindowArmed, "and above all: no 2-h window, so no OBC warning later")
    }

    func testUnreadableSocStillArmsResumeConfirmOffAHoldNCR() {
        // Scope guard: resume-confirm judges by InstantAmperage + RAW trend, which need no SoC, so
        // the nil-SoC rule must not take that window away too.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: nil,
                              telemetryState: .limitHold, at: 0)
        XCTAssertEqual(confirm.status, .confirming)
        XCTAssertTrue(confirm.isWindowArmed)
    }

    // MARK: - a target of 100 must not arm .chargingToCap (review ruling, two rounds)
    //
    // E1 — the ONLY clean exit from a `.chargingToCap` window — is `state == .limitHold`, and
    // `ChargeStateMachine.classify` publishes that state ONLY on the NCR limit bit (0x01000000 /
    // 0x01002080). At `target == 100` there is no cap, so macOS has no cap-hold reason to publish
    // and the bit never appears: in the app's own history every sample at SoC 100 / on AC /
    // limit 100 that is not flowing classifies `.ambiguousHold` (33 rows), which by construction
    // requires `notChargingReason == 0` EXACTLY. So the window could only ever end on the
    // stagnation TTL, the 2-h ceiling, an unplug or a supersede — every completed charge to 100
    // resolving as an inconclusive verdict, after two hours of pinned 10 s polling and scheduler
    // deferral. Report, don't promise, and arm nothing.
    //
    // NARROW BY CONSTRUCTION: this says nothing about sub-100 targets. `.limitHold` is alive there
    // — 151 `.limitHold` hours across 29 days in the app's aggregates at a target of 80, none of
    // them capping above 95 — so those windows keep their clean exit and keep arming.

    func testTargetOfOneHundredArmsNoCapWindow() {
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 100, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .requestedNoCapToHold,
                       "no cap means no cap-hold to observe: report, don't promise")
        XCTAssertFalse(confirm.isWindowArmed,
                       "a window whose only clean exit cannot occur must never arm")
    }

    func testSubHundredTargetStillArmsTheCapWindow() {
        // The scope guard. The ruling is about the ABSENCE OF A CAP, not about the hold signal:
        // at a real cap the hold bit is published and E1 is reachable, so the window still arms.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        XCTAssertTrue(confirm.isWindowArmed)
    }

    func testTargetOfOneHundredDoesNotPinTheFastPollCadence() {
        // The cost being avoided, measured at its real consumer: `wantsFastPolling` IS
        // `confirm.isWindowArmed`, and `BatteryApp` switches the monitor to 10 s off it. A target
        // of 100 must leave the loop lazy; a sub-100 target must still pin it.
        let engine = ChargeLimitEngine(runner: MockShortcutRunner(),
                                       captureStore: MockPauseCaptureStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        engine.confirm.commandIssued(target: 100, preSetNCR: 0, socAtSet: 73,
                                     telemetryState: .charging, at: 0)
        XCTAssertFalse(engine.wantsFastPolling,
                       "no window at a target of 100 → no 10 s cadence, for up to 2 h")

        engine.confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                                     telemetryState: .charging, at: 0)
        XCTAssertTrue(engine.wantsFastPolling, "a real cap still pins the loop at 10 s")
    }

    func testTargetOfOneHundredStillArmsTheOtherTwoWindows() {
        // Scope guard, the same shape the nil-SoC ruling needed: `.stopConfirm` and
        // `.resumeConfirm` judge by InstantAmperage + RAW trend and never consult the hold bit,
        // so a target of 100 must keep BOTH of them. Only `.chargingToCap` depends on E1.
        let resume = BehaviorConfirm(limitReader: nil)
        resume.commandIssued(target: 100, preSetNCR: ChargeNCR.limitHoldPure, socAtSet: 80,
                             telemetryState: .limitHold, at: 0)
        XCTAssertEqual(resume.status, .confirming)
        XCTAssertTrue(resume.isWindowArmed)

        let stop = BehaviorConfirm(limitReader: nil)
        stop.commandIssued(target: 100, preSetNCR: 0, socAtSet: 100,
                           telemetryState: .charging, at: 0)
        XCTAssertEqual(stop.status, .confirming)
        XCTAssertTrue(stop.isWindowArmed)
    }

    // MARK: - the decay copy split (review BLOCKING 2)

    func testDecayTaxonSplitsOnHowFarThePackActuallyGot() async {
        // At/near the target the climb COMPLETED and macOS merely never published the hold flag —
        // the normal outcome on this hardware. Well below it, charging never approached the limit.
        // Same exit (the ceiling), different distance from the target.
        let nearTarget = BehaviorConfirm(limitReader: nil)
        nearTarget.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                                 telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 7200, by: 10) {
            nearTarget.ingest(stagnantAtCap(t: t, soc: 93), state: .ambiguousHold)   // 93 vs 95
        }
        await drain(until: nearTarget.status == .confirmInconclusive(.noCleanHoldObserved))

        let farBelow = BehaviorConfirm(limitReader: nil)
        farBelow.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                               telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 7200, by: 10) {
            farBelow.ingest(stagnantAtCap(t: t, soc: 80), state: .ambiguousHold)     // 80 vs 95
        }
        await drain(until: farBelow.status == .confirmInconclusive(.neverReachedLimit))
    }

    func testDecayTaxonAsksTheMaxSocInTheWindowNotWhereItEnded() async {
        // AMENDMENT 1 (round 2). The taxon asks whether the pack ever APPROACHED the target;
        // `lastSoc` answered where it ENDED. Gauge sag after a REAL cap — the pack tops out at 95,
        // the cap engages, and the reading relaxes back to 85 over the following hour — therefore
        // turned `.noCleanHoldObserved` into `.neverReachedLimit` and hung the OBC / stale-hold
        // sentence on a charge that in fact got there. The window keeps a running MAX instead,
        // seeded from the SoC at Set and never lowered.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 300, by: 10) {          // the climb REACHES the cap
            confirm.ingest(chargingSample(t: t, soc: 95), state: .charging)
        }
        // Then the gauge sags below the slack band and stays there. Below the target the stagnation
        // TTL cannot start (`atOrPastTarget` is false), so this window runs to the unconditional
        // ceiling — the path on which the taxon is chosen.
        for t in stride(from: 310.0, through: 7200, by: 10) {
            confirm.ingest(stagnantAtCap(t: t, soc: 85), state: .ambiguousHold)
        }
        await drain(until: confirm.status == .confirmInconclusive(.noCleanHoldObserved))
    }

    func testTheMaxSocSurvivesAWakeGapRestart() async {
        // A wake gap restarts the EVIDENCE, not the window's identity (`armedAt` is never
        // re-anchored), so what the window learned about how far the pack got must survive it too.
        // A machine that reached 95, slept, and woke with the gauge reading 80 has still been to
        // the cap — and the pre-amendment code overwrote that fact on the wake sample.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 300, by: 10) {
            confirm.ingest(chargingSample(t: t, soc: 95), state: .charging)
        }
        confirm.ingest(stagnantAtCap(t: 900, soc: 80), state: .ambiguousHold)   // 600 s nap, banked
        for t in stride(from: 910.0, through: 7900, by: 10) {                   // ceiling at 7800
            confirm.ingest(stagnantAtCap(t: t, soc: 80), state: .ambiguousHold)
        }
        await drain(until: confirm.status == .confirmInconclusive(.noCleanHoldObserved))
    }

    func testDecayStringsAreHonestForBothCases() {
        // AMENDMENT 2 (round 2). This string was calmed to a plain completion on the rationale that
        // `.noCleanHoldObserved` was the only terminal state a charge to a target of 100 could
        // reach. That rationale DIED: no `.chargingToCap` window arms at 100 any more, so this
        // taxon now fires ONLY at `target < 100` — which is exactly where this machine DOES publish
        // the hold bit (150 of the 151 recorded `.limitHold` hours are at sub-100 caps). A missing
        // flag at a cap the hardware can signal is a genuine failed verify with a live cause, so
        // the string keeps its calm observation-first register AND names the hypothesis.
        let atLimit = ChargeStatusStrings.commandLabel(.confirmInconclusive(.noCleanHoldObserved))!
        XCTAssertTrue(atLimit.contains("stopped at the limit"))
        XCTAssertTrue(atLimit.contains("couldn't verify"),
                      "observation first, then the honest limit of the evidence")
        XCTAssertTrue(atLimit.contains("Optimized Battery Charging"),
                      "a failed verify at a REAL cap must name the live hypothesis, not shrug")
        XCTAssertFalse(atLimit.hasPrefix("Stopped near the limit"),
                       "…but the old scare stays deleted (explicit review ruling)")
        XCTAssertNotEqual(atLimit,
                          ChargeStatusStrings.commandLabel(.confirmInconclusive(.neverReachedLimit)),
                          "the two taxa still describe different observations")
        // The below-target string must not claim the pack stopped near a limit it never reached.
        let below = ChargeStatusStrings.commandLabel(.confirmInconclusive(.neverReachedLimit))!
        XCTAssertTrue(below.contains("never reached the limit"))
        XCTAssertTrue(below.contains("Optimized Battery Charging"),
                      "this IS the something-else-is-managing-charging case")
    }

    // MARK: - DEFECT A: a time-based bound must not depend on the telemetry that failed

    func testChronicDiagnosticsReadFailureStillBoundsTheCapWindow() async {
        // THE DEFECT, driven through the PRODUCTION path. Every window transition in
        // `BehaviorConfirm` is evaluated inside `ingest`, and `ingest` runs only when a telemetry
        // sample arrives. `ChargeTelemetryPipeline.noteDiagnosticsReadFailure` never reaches it, so a
        // chronic AppleSmartBattery read failure left the window armed FOREVER with the 2-h ceiling
        // present and unable to fire: 10 s polling pinned and the scheduler deferring — the exact
        // audit-B1 symptom the ceiling was added to close, reached through a door it cannot see.
        let box = MockClockBox(0)
        let engine = ChargeLimitEngine(runner: MockShortcutRunner(),
                                       captureStore: MockPauseCaptureStore(),
                                       clock: MockMonotonicClock(box: box))
        let pipeline = ChargeTelemetryPipeline(engine: engine, advisor: OBCAdvisor(),
                                               clock: MockMonotonicClock(box: box))
        engine.confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                                     telemetryState: .charging, at: 0)
        XCTAssertEqual(engine.confirm.status, .limitSetChargingToCap)
        XCTAssertTrue(engine.wantsFastPolling, "an armed window pins the poll loop at 10 s")

        // Telemetry goes dark: for two hours the ONLY thing the app is told is that the read failed.
        // The failure signal is LEVEL-triggered, not edge-triggered — `BatteryMonitor.refreshDiagnostics`
        // fires `onDiagnosticsReadFailure` on EVERY nil read, from the poll timer and from the
        // power-source event — so the stamps below are what the production path actually delivers.
        var stamps = 0
        var largestStep = 0.0
        var previous = 0.0
        for t in stride(from: 10.0, through: 7190, by: 10) {
            largestStep = max(largestStep, t - previous)
            previous = t
            box.now = t
            pipeline.noteDiagnosticsReadFailure()
            stamps += 1
        }
        XCTAssertTrue(engine.confirm.isWindowArmed,
                      "the bound is the CEILING, not merely elapsed time — it must not fire early")
        XCTAssertGreaterThan(stamps, 700, "an outage is hundreds of ordinary ticks, not one jump")
        XCTAssertLessThanOrEqual(largestStep, BehaviorConfirm.Tunables().wakeGap_s,
                                 "no single advance here is even long enough to be a wake gap")

        box.now = 7200
        pipeline.noteDiagnosticsReadFailure()
        await drain(until: engine.confirm.isWindowArmed == false)
        XCTAssertEqual(engine.confirm.status, .confirmInconclusive(.neverReachedLimit))
        XCTAssertFalse(engine.wantsFastPolling,
                       "fast polling must stop — the 10 s cadence is the cost being bounded")
    }

    func testALongOutageDisarmsFromAccumulatedStampsNotOneBigJump() async {
        // AMENDMENT 3 (round 2). A single `noteTimeElapsedWithoutSample(at: 7200)` proves only the
        // arithmetic of one subtraction. The claim actually being made is about a REAL outage:
        // hundreds of ordinary 10 s poll ticks, not one of them individually longer than
        // `wakeGap_s`, which together must still reach the ceiling and disarm the window.
        //
        // This is also the assertion that catches the plausible wrong fix. The dark path
        // deliberately banks NOTHING into `unsampledGapTotal` and deliberately leaves
        // `lastSampleAt` alone; make it bank its own interval "for symmetry with the wake gap" and
        // every dark tick refunds itself, `sampledElapsed` sits at ~0 for ever and this window
        // never disarms — while a lone call at t = 7200 would still pass, unchanged.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)

        var stamps = 0
        var largestStep = 0.0
        var previous = 0.0
        for t in stride(from: 10.0, through: 7190, by: 10) {
            largestStep = max(largestStep, t - previous)
            previous = t
            confirm.noteTimeElapsedWithoutSample(at: t)
            stamps += 1
            XCTAssertTrue(confirm.isWindowArmed,
                          "every tick short of the ceiling must leave the window armed (t = \(t))")
        }
        XCTAssertGreaterThan(stamps, 700, "this is an accumulation, not a jump")
        XCTAssertLessThanOrEqual(largestStep, BehaviorConfirm.Tunables().wakeGap_s,
                                 "no single advance may stand in for the whole outage")

        confirm.noteTimeElapsedWithoutSample(at: 7200)          // the tick that crosses it
        await drain(until: confirm.isWindowArmed == false)
        XCTAssertEqual(confirm.status, .confirmInconclusive(.neverReachedLimit),
                       "the pack never got near 95 and the dark path invents no SoC of its own")
    }

    func testTheFirstRealSampleAfterAnOutageBanksTheDarkTimeItSurvived() async {
        // The other half of the same mechanism, pinned because round 1 never called it. The dark
        // path and the wake-gap path account for the SAME missing time in OPPOSITE directions, on
        // purpose. While telemetry is dark, `noteTimeElapsedWithoutSample` SPENDS the ceiling —
        // nothing else can bound the window, and an unconditional bound must not depend on the
        // telemetry that failed. The instant a real sample arrives, `ingest` sees the whole outage
        // as one S-N5 gap and BANKS it, because from that sample on there is evidence again and the
        // 7200 s constant is a claim about charging duration, not about how long IOKit was
        // unreadable. A blip — even a two-hour one — must not abort a climb that is still running.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 7190, by: 10) {
            confirm.noteTimeElapsedWithoutSample(at: t)          // 10 s short of the ceiling
        }
        XCTAssertTrue(confirm.isWindowArmed)

        confirm.ingest(chargingSample(t: 7200, soc: 90), state: .charging)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(confirm.isWindowArmed,
                      "telemetry returned: the outage is banked as a gap, not charged to the ceiling")
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
    }

    func testTimeOnlyEvaluationNeverAdvancesTheStagnationTTL() {
        // HARD CONSTRAINT. `capDecayTTL_s` is CONDITIONAL on telemetry (`atOrPastTarget && noFlow
        // && !isLimitHoldNCR`). With no sample those conditions are UNKNOWN, so advancing the
        // stagnation clock on the time-only path would be inventing evidence — the window must
        // survive dark time far past 900 s and end only on the unconditional ceiling.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stagnantAtCap(t: 10, soc: 80), state: .ambiguousHold)   // TTL clock starts
        for t in stride(from: 20.0, through: 3600, by: 10) {
            confirm.noteTimeElapsedWithoutSample(at: t)                        // telemetry is dark
        }
        XCTAssertEqual(confirm.status, .limitSetChargingToCap,
                       "4× the 900 s TTL of DARK time must not decay a telemetry-gated clock")
        XCTAssertTrue(confirm.isWindowArmed)
    }

    func testTimeOnlyEvaluationLeavesConfirmWindowsAlone() async {
        // E5 AND ONLY E5 (review ruling). An absolute bound for `.stopConfirm`/`.resumeConfirm` is
        // a separate change; the failure path must not quietly acquire one, and above all it must
        // not publish `.confirmFailed` — that is a claim about the hardware, and there is no sample.
        let confirm = BehaviorConfirm(limitReader: nil)
        var published: [CommandStatus] = []
        confirm.$status.sink { published.append($0) }.store(in: &cancellables)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        XCTAssertEqual(confirm.status, .confirming)
        for t in stride(from: 10.0, through: 7200, by: 10) {
            confirm.noteTimeElapsedWithoutSample(at: t)
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(confirm.status, .confirming)
        XCTAssertFalse(published.contains(.confirmFailed),
                       "no sample = no evidence: this path may not assert the change failed")
    }

    func testSingleFailedReadNeverCancelsARealClimb() async {
        // A blip is not a verdict: one (or many) failed diagnostics reads short of the ceiling must
        // leave the window armed so a genuine climb is still confirmable when telemetry returns.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        confirm.noteTimeElapsedWithoutSample(at: 10)
        confirm.noteTimeElapsedWithoutSample(at: 20)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        XCTAssertTrue(confirm.isWindowArmed)
        confirm.ingest(chargingSample(t: 25, soc: 78), state: .charging)   // telemetry returns
        XCTAssertTrue(confirm.isWindowArmed)
        confirm.ingest(ChargeFixtures.limitHold80(t: 35), state: .limitHold)
        await drain(until: confirm.status == .confirmedStop)
    }

    func testTimeOnlyEvaluationCannotResolveASupersededWindow() async {
        // Generation discipline, exactly as `ingest` applies it: a late time-only tick from a dead
        // window must publish nothing.
        let confirm = BehaviorConfirm(limitReader: nil)
        var published: [CommandStatus] = []
        confirm.$status.sink { published.append($0) }.store(in: &cancellables)
        confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        confirm.supersede()
        confirm.noteTimeElapsedWithoutSample(at: 7200)   // far past the ceiling
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(confirm.status, .idle)
        XCTAssertFalse(published.contains(.confirmInconclusive(.neverReachedLimit)),
                       "a superseded window must never publish, on any path")
    }

    // MARK: - DEFECT B: a published verdict is not permanent

    func testUnplugClearsAPublishedVerdict() async {
        // THE DEFECT. `ingest` opens `guard var w = window else { return }`, so once a verdict has
        // published (window == nil) NO telemetry event can clear it — including an unplug. The user
        // could unplug, walk away, and hours later still be reading the OBC guidance, dismissible
        // only by issuing another Set. The in-window rule ("an unplug is a user act, not a mechanism
        // verdict") applies after resolution too: once power is gone, that window's story is over.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 73,
                              telemetryState: .charging, at: 0)
        for t in stride(from: 10.0, through: 910, by: 10) {
            confirm.ingest(stagnantAtCap(t: t, soc: 80), state: .ambiguousHold)   // TTL decay
        }
        await drain(until: confirm.status == .confirmInconclusive(.noCleanHoldObserved))
        XCTAssertFalse(confirm.isWindowArmed)
        XCTAssertTrue(confirm.verdictWasDegraded, "no reader → the verdict carries the caveat")

        confirm.ingest(ChargeFixtures.dischargingOnBattery(t: 920), state: .discharging)
        XCTAssertEqual(confirm.status, .idle, "power is gone — the verdict goes with it")
        XCTAssertFalse(confirm.verdictWasDegraded, "the caveat rides the verdict; it clears with it")
    }

    func testStillPluggedSamplesDoNotClearAPublishedVerdict() async {
        // The unplug rule is exactly that — an UNPLUG rule. Ordinary on-AC telemetry must leave a
        // verdict standing (the user has to be able to read it).
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)
        await drain(until: confirm.status == .confirmedStop)
        confirm.ingest(stoppedSample(t: 30), state: .unknown)
        XCTAssertEqual(confirm.status, .confirmedStop, "still on AC: the verdict stands")
    }

    func testUnplugDoesNotClearAConfirmedVerdict() {
        // The unplug rule is deliberately NARROW (review ruling): only the INCONCLUSIVE verdict —
        // the one whose guidance is misleading with no charger attached — is retired. "Hold
        // confirmed" is a fact about the Set the user made; it stands until the age cap.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)
        XCTAssertEqual(confirm.status, .confirmedStop)
        confirm.ingest(ChargeFixtures.dischargingOnBattery(t: 30), state: .discharging)
        XCTAssertEqual(confirm.status, .confirmedStop)
    }

    func testUnplugDoesNotClearACommandFailure() {
        // Scope guard: only a resolved WINDOW verdict is the unplug rule's business. A setup problem
        // the user still has to act on is not a window verdict and must survive an unplug.
        let confirm = BehaviorConfirm(limitReader: nil)
        confirm.commandFailed(.setupRequired, at: 0)
        confirm.ingest(ChargeFixtures.dischargingOnBattery(t: 10), state: .discharging)
        XCTAssertEqual(confirm.status, .setupRequired)
    }

    func testPublishedVerdictSelfClearsAtTheAgeCap() async {
        // The second half of DEFECT B: even with no unplug, a verdict must not outlive its
        // relevance. `ingest` returns as soon as the window is nil, so the clear cannot be
        // sample-driven — it reuses the file's transient-status idiom (a token-guarded Task).
        var tunables = BehaviorConfirm.Tunables()
        tunables.verdictMaxAge_s = 0.05
        let confirm = BehaviorConfirm(limitReader: nil, tunables: tunables)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)
        await drain(until: confirm.status == .confirmedStop)
        try? await Task.sleep(nanoseconds: 300_000_000)   // well past 0.05 s (no flake)
        XCTAssertEqual(confirm.status, .idle, "a verdict is news, not a standing line")
        XCTAssertFalse(confirm.verdictWasDegraded)
    }

    func testPendingVerdictExpiryCannotWipeANewerStatus() async {
        // The token guard, same discipline as the transient confirmation: an older verdict's
        // pending expiry must not wipe the state a newer command installed.
        var tunables = BehaviorConfirm.Tunables()
        tunables.verdictMaxAge_s = 0.05
        let confirm = BehaviorConfirm(limitReader: nil, tunables: tunables)
        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)
        await drain(until: confirm.status == .confirmedStop)

        confirm.commandIssued(target: 90, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .unknown, at: 20)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(confirm.status, .limitSetChargingToCap,
                       "the older verdict's expiry must be inert against a newer state")
        XCTAssertTrue(confirm.isWindowArmed, "and it must not disarm the new window")
    }

    // MARK: - normative timing constants pinned (review finding #38)

    func testTunableDefaultsPinTheSpecNumbers() {
        let t = BehaviorConfirm.Tunables()
        XCTAssertEqual(t.stopWindow_s, 60, "spec: stop-confirm window 60 s")
        XCTAssertEqual(t.resumeWindow_s, 120, "spec: resume-confirm window 120 s")
        XCTAssertEqual(t.capDecayTTL_s, 900, "spec: 15-min TTL decay")
        XCTAssertEqual(t.capMaxWindow_s, 7200, "audit B1: 2-h unconditional ceiling on chargingToCap")
        XCTAssertEqual(t.verdictMaxAge_s, 900, "a published verdict self-clears after 15 min")
        XCTAssertEqual(t.capNearTargetSlack_pct, 3, "how close to the target still reads as \"at the limit\"")
        XCTAssertEqual(t.wakeGap_s, 30, "spec: monotonic gaps > 30 s invalidate")
    }

    func testExplicitSupersedeDiscardsParkedVerdictToo() async {
        let reader = MockLimitReader([.known(80)])
        let confirm = BehaviorConfirm(limitReader: reader)
        var published: [CommandStatus] = []
        confirm.$status.sink { published.append($0) }.store(in: &cancellables)

        confirm.commandIssued(target: 80, preSetNCR: 0, socAtSet: 84,
                              telemetryState: .charging, at: 0)
        await reader.parkNext()
        confirm.ingest(stoppedSample(t: 10), state: .unknown)
        confirm.ingest(stoppedSample(t: 20), state: .unknown)
        await reader.waitUntilParked()

        confirm.supersede()                                      // user cancelled
        await reader.release()
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(confirm.status, .idle)
        XCTAssertFalse(published.contains(.confirmedStop))
    }
}
