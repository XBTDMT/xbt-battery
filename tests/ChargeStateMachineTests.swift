import XCTest

/// WI-N3: the FULL taxonomy matrix over the real fixture vectors — precedence order, transient
/// decay, ambiguous-fingerprint thresholds/sustain, the on-AC gate, and the no-holes guarantee.
final class ChargeStateMachineTests: XCTestCase {

    private func classify(_ history: [ChargeTelemetrySnapshot],
                          limit: ChargeLimitValue = .known(80)) -> TelemetryChargeState {
        ChargeStateMachine.classify(history: history, limit: limit)
    }

    // MARK: - precedence rule (1): the limit bit

    func testPureLimitHoldClassifies() {
        XCTAssertEqual(classify([ChargeFixtures.limitHold80(t: 0)]), .limitHold)
    }

    func testLimitBitBeatsNegativeFlow_staleDipRow() {
        // run-03 16:02:50: pure hold with a stale −1534 mA disengage dip. Precedence (1) must
        // beat (3) — this row displayed as "discharging" would violate S-N1 honesty.
        XCTAssertEqual(classify([ChargeFixtures.limitHold84StaleDip(t: 0)]), .limitHold)
    }

    func testStopTransientMapsToLimitHold() {
        // 0x01002080 (the instant-of-stop composite) IS the limit hold (sec 2: maps here
        // after decay logic) — both the fresh transient and the decaying sample.
        XCTAssertEqual(classify([ChargeFixtures.stopTransient84(t: 0)]), .limitHold)
        XCTAssertEqual(classify([ChargeFixtures.stopDecaying84(t: 0)]), .limitHold)
    }

    // MARK: - precedence rule (2): idle inhibit

    func testIdleInhibitClassifiesWhilePlugged() {
        XCTAssertEqual(classify([ChargeFixtures.idleInhibitPostLoad(t: 0)]), .idleInhibit)
        XCTAssertEqual(classify([ChargeFixtures.idleInhibitQuiet(t: 0)]), .idleInhibit)
    }

    func testIdleInhibitBeatsPositiveFlow_precedenceOrder() {
        // Synthetic precedence probe: NCR=0x80 with +2496 mA flowing. The spec's order is
        // explicit — (2) outranks (3). (A stale NCR during a resume transient reads as
        // inhibit for one sample rather than flapping the display.)
        var s = ChargeFixtures.charging80(t: 0)
        s.notChargingReason = ChargeNCR.idleInhibit
        XCTAssertEqual(classify([s]), .idleInhibit)
    }

    // MARK: - precedence rule (3): flow

    func testRealChargingFlowClassifies() {
        XCTAssertEqual(classify([ChargeFixtures.charging80(t: 0)]), .charging)
        XCTAssertEqual(classify([ChargeFixtures.charging82(t: 0)]), .charging)
    }

    func testOnACDischargeUnderLoadClassifiesDischarging() {
        // run-02 12:51:49: plugged, IsCharging lying true, −3790 mA (load > adapter).
        XCTAssertEqual(classify([ChargeFixtures.dischargingOnACUnderLoad(t: 0)]), .discharging)
    }

    func testOnBatteryDischargeClassifiesDischarging_extGateBeatsNCR() {
        // Live probe 20:04:25: UNPLUGGED with NCR=0x80. Without the on-AC gate this would
        // read .idleInhibit — nonsense on battery. The gate routes it to flow → .discharging.
        XCTAssertEqual(classify([ChargeFixtures.dischargingOnBattery(t: 0)]), .discharging)
    }

    func testOnBatteryNearIdleStillDischarging() {
        // On battery with |flow| under the threshold: a battery machine is discharging by
        // definition — never .unknown, never a hold taxon.
        var s = ChargeFixtures.dischargingOnBattery(t: 0)
        s.instantAmperage_mA = -86   // run-02 13:11:20-style near-idle drain
        XCTAssertEqual(classify([s]), .discharging)
    }

    // MARK: - precedence rule (4): the ambiguous fingerprint, LAST + sustained

    /// Builds a sustained armed-not-flowing history: the run-02 lying-flags row repeated at
    /// 10 s cadence across the given span.
    private func ambiguousHistory(span: TimeInterval, step: TimeInterval = 10,
                                  soc: Int = 79) -> [ChargeTelemetrySnapshot] {
        stride(from: 0, through: span, by: step).map { t in
            var s = ChargeFixtures.ambiguousHold79(t: t)
            s.socPercent = soc
            return s
        }
    }

    func testSustainedLyingArmedFlagsClassifyAmbiguousHold() {
        XCTAssertEqual(classify(ambiguousHistory(span: 30)), .ambiguousHold)
    }

    func testSingleLyingSampleIsNotYetAmbiguous() {
        // Pre-sustained reads .unknown — a transient must never certify a hold.
        XCTAssertEqual(classify([ChargeFixtures.ambiguousHold79(t: 0)]), .unknown)
        XCTAssertEqual(classify(ambiguousHistory(span: 20)), .unknown)
    }

    func testSleepGapInsideWindowBreaksSustained() {
        // Two fingerprint samples 120 s apart (> maxSampleGap 90): the nap de-sustains the
        // window — stale pre-sleep samples must not certify a hold (S-N5 spirit).
        let history = [ChargeFixtures.ambiguousHold79(t: 0),
                       ChargeFixtures.ambiguousHold79(t: 120)]
        XCTAssertEqual(classify(history), .unknown)
    }

    func testAmbiguousAtTheCapClassifies_atOrBelowWidening() {
        // Grok B2: an NCR=0 hold AT the cap (SoC == limit) previously had no home — at-or-below
        // must include it.
        XCTAssertEqual(classify(ambiguousHistory(span: 30, soc: 80), limit: .known(80)),
                       .ambiguousHold)
    }

    func testAboveLimitArmedNotFlowingIsUnknownNotAmbiguous() {
        XCTAssertEqual(classify(ambiguousHistory(span: 30, soc: 85), limit: .known(80)), .unknown)
    }

    func testLimitUnknownUsesLiveSocCeiling() {
        // Get-degraded mode: comparison satisfied iff LIVE SoC < 95 (sec 2) — 79 qualifies,
        // 96 must not (conservative: cannot misfire at the cap).
        XCTAssertEqual(classify(ambiguousHistory(span: 30, soc: 79), limit: .unknown),
                       .ambiguousHold)
        XCTAssertEqual(classify(ambiguousHistory(span: 30, soc: 96), limit: .unknown), .unknown)
    }

    func testArmedFlagFalseBlocksAmbiguous() {
        // IsCharging=false + no flow + NCR=0 (e.g. resting full at limit 100) → .unknown,
        // never .ambiguousHold — the fingerprint REQUIRES the armed flag.
        var s = ChargeFixtures.ambiguousHold79(t: 0)
        s.isChargingFlag = false
        let history = stride(from: 0.0, through: 40, by: 10).map { t -> ChargeTelemetrySnapshot in
            var c = s; c.timestamp = t; return c
        }
        XCTAssertEqual(classify(history), .unknown)
    }

    // MARK: - holes

    func testEmptyHistoryIsUnknown() {
        XCTAssertEqual(classify([]), .unknown)
    }

    func testNilExternalConnectedNeverClassifiesHoldTaxons() {
        // ext unreadable: hold taxons are gated off; low flow → .unknown (never a false hold).
        var s = ChargeFixtures.limitHold80(t: 0)
        s.externalConnected = nil
        XCTAssertEqual(classify([s]), .unknown)
    }

    func testEveryFixtureMapsToItsExpectedState() {
        // No-holes sweep WITH teeth: every real captured vector asserts its exact taxon
        // (single-sample classification — the lying-flags row reads .unknown pre-sustain).
        let expectations: [(ChargeTelemetrySnapshot, TelemetryChargeState, String)] = [
            (ChargeFixtures.limitHold80(t: 0), .limitHold, "limitHold80"),
            (ChargeFixtures.limitHold84StaleDip(t: 0), .limitHold, "limitHold84StaleDip"),
            (ChargeFixtures.charging80(t: 0), .charging, "charging80"),
            (ChargeFixtures.charging82(t: 0), .charging, "charging82"),
            (ChargeFixtures.stopTransient84(t: 0), .limitHold, "stopTransient84"),
            (ChargeFixtures.stopDecaying84(t: 0), .limitHold, "stopDecaying84"),
            (ChargeFixtures.ambiguousHold79(t: 0), .unknown, "ambiguousHold79 (pre-sustain)"),
            (ChargeFixtures.dischargingOnACUnderLoad(t: 0), .discharging, "dischargingOnACUnderLoad"),
            (ChargeFixtures.idleInhibitPostLoad(t: 0), .idleInhibit, "idleInhibitPostLoad"),
            (ChargeFixtures.idleInhibitQuiet(t: 0), .idleInhibit, "idleInhibitQuiet"),
            (ChargeFixtures.dischargingOnBattery(t: 0), .discharging, "dischargingOnBattery"),
        ]
        for (fixture, expected, name) in expectations {
            XCTAssertEqual(classify([fixture]), expected, name)
        }
    }

    func testAmbiguousFlowThresholdBoundary() {
        // The 350 mA fingerprint boundary (sec 8d tunable): 349 sustains as ambiguous;
        // 350 is REAL flow and classifies by sign instead.
        func history(ia: Int) -> [ChargeTelemetrySnapshot] {
            stride(from: 0.0, through: 30, by: 10).map { t in
                var s = ChargeFixtures.ambiguousHold79(t: t)
                s.instantAmperage_mA = ia
                return s
            }
        }
        XCTAssertEqual(classify(history(ia: 349)), .ambiguousHold)
        XCTAssertEqual(classify(history(ia: 350)), .charging)
        XCTAssertEqual(classify(history(ia: -350)), .discharging)
    }
}
