import XCTest

/// WI-N2: the charge-control parser against ioreg-shaped fixtures built from REAL captured rows
/// (provenance in ChargeTelemetryFixtures / validation/phase2/raw/).
final class ChargeTelemetryParsingTests: XCTestCase {

    func testParsesIdleInhibitRowWithFoldedNegativeAmperage() {
        let snap = ChargeTelemetryParser.parse(ChargeFixtures.registryIdleInhibitDict(), timestamp: 42)
        XCTAssertEqual(snap.timestamp, 42)
        XCTAssertEqual(snap.socPercent, 74)
        XCTAssertEqual(snap.rawCapacity_mAh, 3788)
        // The REAL observed 64-bit registry value 18446744073709546403 must fold to −5213 mA.
        XCTAssertEqual(snap.instantAmperage_mA, -5213)
        XCTAssertEqual(snap.notChargingReason, 0x80)
        XCTAssertEqual(snap.isChargingFlag, false)
        XCTAssertEqual(snap.externalConnected, true)
        XCTAssertEqual(snap.chargingCurrent_mA, 0)
    }

    func testParsesChargingRow() {
        let snap = ChargeTelemetryParser.parse(ChargeFixtures.registryChargingDict(), timestamp: 0)
        XCTAssertEqual(snap.socPercent, 80)
        XCTAssertEqual(snap.rawCapacity_mAh, 4223)
        XCTAssertEqual(snap.instantAmperage_mA, 2496)
        XCTAssertEqual(snap.notChargingReason, 0)
        XCTAssertEqual(snap.isChargingFlag, true)
        XCTAssertEqual(snap.chargingCurrent_mA, 3496)
    }

    func testMissingKeysParseToNilNotGarbage() {
        let snap = ChargeTelemetryParser.parse([:], timestamp: 1)
        XCTAssertNil(snap.socPercent)
        XCTAssertNil(snap.rawCapacity_mAh)
        XCTAssertNil(snap.instantAmperage_mA)
        XCTAssertNil(snap.notChargingReason)
        XCTAssertNil(snap.isChargingFlag)
        XCTAssertNil(snap.externalConnected)
        XCTAssertNil(snap.chargingCurrent_mA)
    }

    func testMissingChargerDataSubdictParsesToNilNCR() {
        let snap = ChargeTelemetryParser.parse(["CurrentCapacity": 50], timestamp: 1)
        XCTAssertEqual(snap.socPercent, 50)
        XCTAssertNil(snap.notChargingReason)
        XCTAssertNil(snap.chargingCurrent_mA)
    }

    func testLimitHoldNCRExactMatchCoversPureAndTransient() {
        // 0x01000000 (pure hold) and 0x01002080 (stop transient) BOTH carry the limit bit;
        // 0x80 and 0 do not (run-03 state decoder).
        XCTAssertTrue(ChargeFixtures.limitHold80(t: 0).isLimitHoldNCR)
        XCTAssertTrue(ChargeFixtures.stopTransient84(t: 0).isLimitHoldNCR)
        XCTAssertFalse(ChargeFixtures.idleInhibitQuiet(t: 0).isLimitHoldNCR)
        XCTAssertFalse(ChargeFixtures.charging80(t: 0).isLimitHoldNCR)
        XCTAssertFalse(ChargeTelemetrySnapshot(timestamp: 0).isLimitHoldNCR)   // nil NCR
    }

    // MARK: - macOS 27 relocation ladder (03-REF-applesmartbattery-layout.md)

    /// THE REGRESSION THIS PASS EXISTS FOR. On macOS 27.0 `AppleRawCurrentCapacity` is published at
    /// NEITHER the `AppleSmartBattery` top level NOR the node's own `BatteryData` — only in the
    /// CHILD `AppleSmartBatteryPack` node's `BatteryData`. The parser read the top level only, so
    /// `rawCapacity_mAh` was structurally nil on every sample and `BehaviorConfirm`'s RAW-trend half
    /// of the validated truth pair had nothing to work with. Same defect class as the Health/FCC
    /// break. Verified live on this machine 2026-09-08: pack value 1431.
    func testParsesMacOS27RawCapacityFromThePackChild() {
        let snap = ChargeTelemetryParser.parse(ChargeFixtures.registryMacOS27NestedDict(), timestamp: 7)
        XCTAssertEqual(snap.rawCapacity_mAh, 1431, "the pack child's BatteryData is rung 3")
        XCTAssertEqual(snap.socPercent, 27)
        XCTAssertEqual(snap.instantAmperage_mA, -2683)
        XCTAssertEqual(snap.notChargingReason, 0x80)
        XCTAssertEqual(snap.externalConnected, false)
        // Documented, not fixed here: `ChargingCurrent` lives in the SIBLING `AppleChargerData`
        // node, which the reader does not walk. It is read by nothing (`grep chargingCurrent_mA
        // app/` = the struct field and this parser only), so it stays honestly nil.
        XCTAssertNil(snap.chargingCurrent_mA)
    }

    /// Pre-27 machines must be unaffected: the top-level key still OUTRANKS every nested rung.
    func testTopLevelRawCapacityStillOutranksTheNestedRungs() {
        var props = ChargeFixtures.registryMacOS27NestedDict()
        props["AppleRawCurrentCapacity"] = 4223
        XCTAssertEqual(ChargeTelemetryParser.parse(props, timestamp: 0).rawCapacity_mAh, 4223)
    }

    /// Substitute rung: a machine with the node's `BatteryData` and no pack child still reads the
    /// figure, from `RemainingCapacity` (measured EQUAL to `AppleRawCurrentCapacity` — both 1431).
    func testRawCapacityFallsBackToNodeRemainingCapacity() {
        let snap = ChargeTelemetryParser.parse(ChargeFixtures.registryNodeBatteryDataOnlyDict(), timestamp: 0)
        XCTAssertEqual(snap.rawCapacity_mAh, 1431)
    }

    /// A saturated gauge placeholder is "not published at this rung", never a reading (03-REF #4).
    func testSaturatedPlaceholderIsSkippedSoTheLadderMovesOn() {
        let snap = ChargeTelemetryParser.parse(ChargeFixtures.registrySaturatedTopRungDict(), timestamp: 0)
        XCTAssertEqual(snap.rawCapacity_mAh, 1431, "65535 must never render as a 65 Ah reading")
    }

    /// Resolving at NO rung yields nil — the honest third state. It must not be papered over with a
    /// substitute figure of a different quantity (`AppleRawMaxCapacity` is the FULL capacity).
    func testRawCapacityUnresolvableAtEveryRungIsNil() {
        let snap = ChargeTelemetryParser.parse(ChargeFixtures.registryRawCapacityUnresolvableDict(), timestamp: 0)
        XCTAssertNil(snap.rawCapacity_mAh)
    }

    func testLiveMonotonicClockAdvances() {
        let clock = LiveMonotonicClock()
        let a = clock.now()
        let b = clock.now()
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertGreaterThan(a, 0)
    }
}
