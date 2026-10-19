import XCTest

/// Sprint 4.I — THE deliverable (sec 4): the end-to-end Get-degraded command cycle. Each component
/// (LimitReader .unknown, the engine's LastSetTracker contingency, BehaviorConfirm's degraded
/// verdicts) was already spec-compliant — but their COMPOSITION was never exercised with no Get at
/// all. This is the integration test that would have caught the SetupFlow gate gap before the 27.0
/// seed surfaced it organically.
@MainActor
final class GetDegradedIntegrationTests: XCTestCase {

    private func chargingSnapshot(soc: Int) -> ChargeTelemetrySnapshot {
        ChargeTelemetrySnapshot(timestamp: 0, socPercent: soc, rawCapacity_mAh: 4000,
                                instantAmperage_mA: 1800, notChargingReason: 0, isChargingFlag: true,
                                externalConnected: true, chargingCurrent_mA: 2500)
    }

    func testFullSetCycleInDegradedModeWithNoGet() async {
        // The Get shortcut is GONE: every reader.read() resolves to .unavailable.
        let mock = MockShortcutRunner([])
        mock.fallback = .init(.missingShortcut)   // any Get (and any unscripted call) → unavailable
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        engine.ingest(chargingSnapshot(soc: 70), state: .charging)   // soc < target → chargingToCap

        // A re-sync with no Get must leave the limit UNKNOWN (first-class), not crash or wedge.
        await engine.sync(.popoverOpen)
        XCTAssertEqual(engine.limit, .unknown, "read-back unavailable → limit-unknown is first-class")
        XCTAssertNotNil(engine.syncProblem)

        // Now the full command cycle: Set 80 with no working Get.
        mock.script([.init(.success(stdout: ""))])   // the Set succeeds; its read-verify Get → fallback
        _ = await engine.userSetLimit(80)

        // 1) The value is adopted via the LastSetTracker contingency (behavioral, in-memory).
        XCTAssertEqual(engine.limit, .known(80), "Set adopted despite no read-back")
        // 2) The degraded caveat is surfaced honestly.
        XCTAssertNotNil(engine.engineNote)
        XCTAssertTrue(engine.engineNote?.lowercased().contains("read-back") ?? false,
                      "degraded caveat present: \(engine.engineNote ?? "nil")")
        // 3) A BEHAVIORAL confirm window is armed (the status the popover renders).
        XCTAssertTrue(engine.confirm.isWindowArmed, "a behavioral confirm window armed")
        XCTAssertNotNil(ChargeStatusStrings.commandLabel(engine.confirm.status),
                        "the popover has a command status to show")
    }

    func testResumeRestoresWithCaveatWhenGetUnavailable() async {
        // Pause/Resume contract (sec 2): pre-Resume Get impossible → restore the capture + caveat.
        let mock = MockShortcutRunner([])
        mock.fallback = .init(.missingShortcut)
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        engine.ingest(chargingSnapshot(soc: 90), state: .charging)
        mock.script([.init(.success(stdout: ""))])   // pause Set succeeds
        _ = await engine.pause()
        XCTAssertTrue(engine.isPaused)
        // resume() reads the pre-Resume Get FIRST (degraded → unavailable), THEN issues the Set.
        mock.script([.init(.missingShortcut),         // pre-Resume Get → .unavailable + caveat
                     .init(.success(stdout: ""))])    // the resume Set succeeds (read-verify → fallback)
        _ = await engine.resume()
        XCTAssertFalse(engine.isPaused, "resume completed in degraded mode")
        XCTAssertNotNil(engine.engineNote, "resume surfaced a degraded/couldn't-verify caveat")
    }
}
