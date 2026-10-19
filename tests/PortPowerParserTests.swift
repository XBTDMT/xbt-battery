import XCTest
// app/Devices + app/Monitoring compile into BatteryTests → the parser is visible host-app-free.

/// spec 31 §1.1 / §1.2 / §5: the pure parsers over one `AppleSmartBattery` read.
final class PortPowerParserTests: XCTestCase {

    // MARK: PowerOutDetails

    func testCapturedIPhoneElementParsesVerbatim() {
        let ports = PortPowerParser.ports([PortPowerParser.portsKey: [PortPowerFixtures.capturedIPhoneElement()]])
        XCTAssertEqual(ports, [PortPowerFixtures.capturedIPhonePort])
    }

    func testAbsentKeyIsNoPortSourcing() {
        XCTAssertEqual(PortPowerParser.ports(["UpdateTime": 1]), [], "absent key on a good read = no port sourcing")
        XCTAssertFalse(PortPowerParser.portsKeyIsMalformed(["UpdateTime": 1]))
    }

    func testTwoPortsAreSortedByIndex() {
        let props: [String: Any] = [PortPowerParser.portsKey: [
            PortPowerFixtures.element(portIndex: 3, filteredPower: 4_500),
            PortPowerFixtures.element(portIndex: 1, filteredPower: 9_000),
        ]]
        XCTAssertEqual(PortPowerParser.ports(props).map(\.portIndex), [1, 3])
    }

    func testGarbageElementsAreDroppedAndADuplicateIndexKeepsTheFirst() {
        let raw: [Any] = [
            "junk", 42,
            ["PortIndex": 1] as [String: Any],                                 // no FilteredPower
            ["PortIndex": 3, "FilteredPower": -5] as [String: Any],            // negative mW → dropped
            ["PortIndex": "two", "FilteredPower": 900] as [String: Any],       // non-numeric index
            ["PortIndex": 4, "FilteredPower": 700, "Watts": -1, "PDPowermW": "15 W"] as [String: Any],
            PortPowerFixtures.capturedIPhoneElement(),
            ["PortIndex": 2, "FilteredPower": 1] as [String: Any],             // duplicate index 2
        ]
        let ports = PortPowerParser.ports([PortPowerParser.portsKey: raw])
        XCTAssertEqual(ports.map(\.portIndex), [2, 4])
        XCTAssertEqual(ports.first, PortPowerFixtures.capturedIPhonePort, "the first element for index 2 wins")
        XCTAssertNil(ports.last?.watts_mW, "a negative optional field is nil, the element is kept")
        XCTAssertNil(ports.last?.contract_mW, "a non-numeric optional field is nil")
    }

    func testMalformedKeyIsFlaggedNotReadAsEmpty() {
        XCTAssertTrue(PortPowerParser.portsKeyIsMalformed([PortPowerParser.portsKey: "not an array"]))
        XCTAssertTrue(PortPowerParser.portsKeyIsMalformed([PortPowerParser.portsKey: ["PortIndex": 2] as [String: Any]]))
        XCTAssertFalse(PortPowerParser.portsKeyIsMalformed([PortPowerParser.portsKey: [PortPowerFixtures.capturedIPhoneElement()]]))
    }

    func testAllBadNonEmptyArrayIsMalformedNotNoPorts() {
        let allBad: [Any] = [["PortIndex": 2, "Watts": 14_097] as [String: Any], "junk"]   // FilteredPower missing
        let props: [String: Any] = [PortPowerParser.portsKey: allBad]
        XCTAssertEqual(PortPowerParser.ports(props), [])
        XCTAssertTrue(PortPowerParser.portsKeyIsMalformed(props), "a list none of whose elements parse is unreadable, not empty")
    }

    func testEmptyArrayIsARealNoPortsSourcing() {
        let props: [String: Any] = [PortPowerParser.portsKey: [Any]()]
        XCTAssertEqual(PortPowerParser.ports(props), [])
        XCTAssertFalse(PortPowerParser.portsKeyIsMalformed(props))
    }

    func testMixOfGoodAndBadElementsKeepsTheGoodAndIsNotMalformed() {
        let raw: [Any] = ["junk", PortPowerFixtures.capturedIPhoneElement()]
        let props: [String: Any] = [PortPowerParser.portsKey: raw]
        XCTAssertEqual(PortPowerParser.ports(props), [PortPowerFixtures.capturedIPhonePort])
        XCTAssertFalse(PortPowerParser.portsKeyIsMalformed(props))
    }

    // MARK: PowerTelemetryData

    func testLiveTelemetryFrameParses() throws {
        let t = try XCTUnwrap(PortPowerParser.telemetry([PortPowerParser.telemetryKey: PortPowerFixtures.liveTelemetryDict()]))
        XCTAssertEqual(t, PowerTelemetry(systemPowerIn_mW: 62_706, systemLoad_mW: 58_028, batteryPower_mW: 4_678,
                                         accBatteryPower: 1_229_859_229, cntBatteryPower: 45_395,
                                         accBatteryDischarge: -1_202_170_610, cntBatteryDischarge: 52_621))
    }

    func testDischargeAccumulatorStaysSignedSixtyFourBit() throws {
        var f = PortPowerFixtures.base
        f.accDis = -5_000_000_000                      // outside Int32 — must not be folded
        let t = try XCTUnwrap(PortPowerParser.telemetry([PortPowerParser.telemetryKey: PortPowerFixtures.telemetryDict(f)]))
        XCTAssertEqual(t.accBatteryDischarge, -5_000_000_000)
    }

    func testAWrappedUnsignedDischargeAccumulatorIsNeverReadAsAPositiveCharge() throws {
        var d = PortPowerFixtures.telemetryDict(PortPowerFixtures.base)
        d["AccumulatedBatteryDischarge"] = NSNumber(value: UInt64(18_446_744_072_507_381_006))
        let t = try XCTUnwrap(PortPowerParser.telemetry([PortPowerParser.telemetryKey: d]))
        XCTAssertTrue(t.accBatteryDischarge == nil || t.accBatteryDischarge == -1_202_170_610,
                      "either the true signed value or unread — never a positive discharge; got \(String(describing: t.accBatteryDischarge))")
    }

    func testAPositiveDischargeAccumulatorIsGarbage() throws {
        var f = PortPowerFixtures.base
        f.accDis = 1_000
        let t = try XCTUnwrap(PortPowerParser.telemetry([PortPowerParser.telemetryKey: PortPowerFixtures.telemetryDict(f)]))
        XCTAssertNil(t.accBatteryDischarge)
    }

    func testBatteryDataBatteryPowerIsNeverAFallback() {
        let props: [String: Any] = ["BatteryData": ["BatteryPower": -12_000, "RemainingCapacity": 2_538] as [String: Any]]
        XCTAssertNil(PortPowerParser.telemetry(props), "PowerTelemetryData absent → unread, never BatteryData.BatteryPower")
    }

    func testNonDictTelemetryIsUnread() {
        XCTAssertNil(PortPowerParser.telemetry([PortPowerParser.telemetryKey: [1, 2, 3]]))
    }

    func testNegativeSystemPowerIsDroppedButBatteryPowerStaysSigned() throws {
        var d = PortPowerFixtures.telemetryDict(PortPowerFixtures.base, systemPowerIn: 0, batteryPower: -52_000)
        d["SystemPowerIn"] = -5
        let t = try XCTUnwrap(PortPowerParser.telemetry([PortPowerParser.telemetryKey: d]))
        XCTAssertNil(t.systemPowerIn_mW, "negative mW is garbage")
        XCTAssertEqual(t.batteryPower_mW, -52_000, "BatteryPower is signed (− = pack losing)")
    }

    func testSystemPowerInZeroParsesRaw() throws {
        let d = PortPowerFixtures.telemetryDict(PortPowerFixtures.base, systemPowerIn: 0)
        let t = try XCTUnwrap(PortPowerParser.telemetry([PortPowerParser.telemetryKey: d]))
        XCTAssertEqual(t.systemPowerIn_mW, 0, "the parser stays raw; the 0-on-AC unread rule is PortPowerMath.systemPowerIn")
    }

    // MARK: input ceiling / flags / pack

    func testInputCeilingPrefersIPDInputPower() {
        let props: [String: Any] = [
            "PowerDistribution": ["IPDInputPower": 89_200] as [String: Any],
            "AdapterDetails": ["AdapterVoltage": 20_000, "PMUConfiguration": 5_000] as [String: Any],
        ]
        XCTAssertEqual(PortPowerParser.inputCeiling_mW(props), 89_200)
    }

    func testInputCeilingFallsBackToNestedAdapterDetails() {
        let props: [String: Any] = ["AdapterDetails": ["AdapterVoltage": 20_000, "PMUConfiguration": 3_250, "Watts": 65] as [String: Any]]
        XCTAssertEqual(PortPowerParser.inputCeiling_mW(props), 65_000, "20 000 mV × 3 250 mA / 1000")
    }

    func testInputCeilingIgnoresATopLevelPMUConfiguration() {
        let props: [String: Any] = ["PMUConfiguration": 3_250,
                                    "AdapterDetails": ["AdapterVoltage": 20_000] as [String: Any]]
        XCTAssertNil(PortPowerParser.inputCeiling_mW(props), "there is no top-level PMUConfiguration (§1.2)")
    }

    func testInputCeilingOverflowIsNilNotATrap() {
        let props: [String: Any] = ["AdapterDetails": ["AdapterVoltage": Int.max, "PMUConfiguration": 2] as [String: Any]]
        XCTAssertNil(PortPowerParser.inputCeiling_mW(props))
    }

    func testExternalConnectedThreeStates() {
        XCTAssertEqual(PortPowerParser.externalConnected(["ExternalConnected": true]), true)
        XCTAssertEqual(PortPowerParser.externalConnected(["ExternalConnected": false]), false)
        XCTAssertNil(PortPowerParser.externalConnected([:]), "missing is unread, not 'on battery'")
        XCTAssertNil(PortPowerParser.externalConnected(["ExternalConnected": "Yes"]))
    }

    func testUpdateTime() {
        XCTAssertEqual(PortPowerParser.updateTime(["UpdateTime": 1_790_630_342]), 1_790_630_342)
        XCTAssertNil(PortPowerParser.updateTime(["UpdateTime": -1]))
        XCTAssertNil(PortPowerParser.updateTime([:]))
    }

    func testBankCountComesFromThePackFold() {
        XCTAssertEqual(PortPowerParser.bankCount([BatteryTelemetryParser.packPropertiesKey: ["BankCount": 3] as [String: Any]]), 3)
        XCTAssertNil(PortPowerParser.bankCount([:]), "no pack fold → unread")
        XCTAssertNil(PortPowerParser.bankCount([BatteryTelemetryParser.packPropertiesKey: ["BankCount": 0] as [String: Any]]))
    }

    func testCapacitiesReuseTheDiagnosticsLadder() {
        let mac27 = PortPowerFixtures.props(ports: nil, frame: nil, externalConnected: false)
        XCTAssertEqual(PortPowerParser.remainingCapacity_mAh(mac27), 2_538)
        XCTAssertEqual(PortPowerParser.fullChargeCapacity_mAh(mac27), 5_400)
        let mac26: [String: Any] = ["AppleRawCurrentCapacity": 3_000, "AppleRawMaxCapacity": 5_200]
        XCTAssertEqual(PortPowerParser.remainingCapacity_mAh(mac26), 3_000)
        XCTAssertEqual(PortPowerParser.fullChargeCapacity_mAh(mac26), 5_200)
        XCTAssertNil(PortPowerParser.remainingCapacity_mAh(["BatteryData": ["RemainingCapacity": -1] as [String: Any]]))
        XCTAssertNil(PortPowerParser.fullChargeCapacity_mAh(["BatteryData": ["FullChargeCapacity": 0] as [String: Any]]))
    }
}

/// spec 31 §2.1: P = (ΔAccumulatedBatteryPower + ΔAccumulatedBatteryDischarge) ÷ (ΔBatteryPowerAccumulatorCount
/// + ΔBatteryDischargeAccumulatorCount) between two distinct frames — from BOTH pairs.
final class PackPowerAveragerTests: XCTestCase {

    private func average(_ from: PortPowerFixtures.Frame, _ to: PortPowerFixtures.Frame) -> Double? {
        PackPowerAverager.averaged_mW(previous: PortPowerFixtures.telemetry(from), current: PortPowerFixtures.telemetry(to))
    }

    func testMixedWindowUsesBothPairs() throws {
        let p = try XCTUnwrap(average(PortPowerFixtures.base, PortPowerFixtures.mixed(PortPowerFixtures.base)))
        XCTAssertEqual(p, (259_000.0 - 69_000.0) / 60.0, accuracy: 0.001, "37 + 23 = 60 counts")
    }

    func testDischargeOnlyWindowReadsNegative() throws {
        let p = try XCTUnwrap(average(PortPowerFixtures.base, PortPowerFixtures.discharging(PortPowerFixtures.base)))
        XCTAssertEqual(p, -25_000, accuracy: 0.001, "ΔcntBP = 0: the discharge pair alone carries the window")
    }

    func testChargeOnlyWindowReadsPositive() throws {
        let p = try XCTUnwrap(average(PortPowerFixtures.base, PortPowerFixtures.charging(PortPowerFixtures.base)))
        XCTAssertEqual(p, 5_600, accuracy: 0.001)
    }

    func testNoCountDeltaIsNil() {
        XCTAssertNil(average(PortPowerFixtures.base, PortPowerFixtures.base))
    }

    func testAMissingFieldIsNil() {
        let full = PortPowerFixtures.telemetry(PortPowerFixtures.base)
        let missing = PowerTelemetry(systemPowerIn_mW: 62_706, systemLoad_mW: 58_028, batteryPower_mW: 4_678,
                                     accBatteryPower: full.accBatteryPower, cntBatteryPower: full.cntBatteryPower,
                                     accBatteryDischarge: nil, cntBatteryDischarge: full.cntBatteryDischarge)
        XCTAssertNil(PackPowerAverager.averaged_mW(previous: full, current: missing))
    }

    func testACounterResetIsNilNotAHugeNumber() {
        var reset = PortPowerFixtures.charging(PortPowerFixtures.base)
        reset.cntDis = 0
        XCTAssertNil(average(PortPowerFixtures.base, reset))
    }

    func testAPositiveDischargeDeltaIsNil() {
        var wrong = PortPowerFixtures.charging(PortPowerFixtures.base)
        wrong.accDis += 5_000                         // the discharge accumulator only ever falls
        XCTAssertNil(average(PortPowerFixtures.base, wrong))
    }

    func testAPairWithZeroCountDeltaButMovedEnergyIsAnInconsistentFrame() {
        var bogus = PortPowerFixtures.discharging(PortPowerFixtures.base)   // discharge pair moved; ΔcntBP = 0
        bogus.accBP += 1_000_000_000                                        // …but the charge energy jumped
        XCTAssertNil(average(PortPowerFixtures.base, bogus))
        var bogus2 = PortPowerFixtures.charging(PortPowerFixtures.base)     // ΔcntDis = 0
        bogus2.accDis -= 1_000_000_000
        XCTAssertNil(average(PortPowerFixtures.base, bogus2))
    }

    func testOverflowingDeltasAreNilNotATrap() {
        let a = PowerTelemetry(systemPowerIn_mW: nil, systemLoad_mW: nil, batteryPower_mW: nil,
                               accBatteryPower: 0, cntBatteryPower: 0, accBatteryDischarge: 1, cntBatteryDischarge: 0)
        let b = PowerTelemetry(systemPowerIn_mW: nil, systemLoad_mW: nil, batteryPower_mW: nil,
                               accBatteryPower: 0, cntBatteryPower: 10, accBatteryDischarge: .min, cntBatteryDischarge: 10)
        XCTAssertNil(PackPowerAverager.averaged_mW(previous: a, current: b))
    }
}
