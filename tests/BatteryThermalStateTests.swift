import XCTest

/// #EI-4 (SPEC 02-SPEC-ei4-heat-awareness.md): the PURE thermal-state classifier, boundary-exact.
/// nil → unknown; below warm → normal (incl. below zero); [warm, hot) → warm; >= hot → hot.
final class BatteryThermalStateTests: XCTestCase {

    func testNilIsUnknown() {
        XCTAssertEqual(BatteryThermalState.from(celsius: nil), .unknown)
    }

    func testNormalRange() {
        XCTAssertEqual(BatteryThermalState.from(celsius: 25.0), .normal)
        XCTAssertEqual(BatteryThermalState.from(celsius: 36.9), .normal, "just below the warm threshold")
    }

    func testWarmRange() {
        XCTAssertEqual(BatteryThermalState.from(celsius: 37.0), .warm, "warm threshold is inclusive")
        XCTAssertEqual(BatteryThermalState.from(celsius: 41.9), .warm, "just below the hot threshold")
    }

    func testHotRange() {
        XCTAssertEqual(BatteryThermalState.from(celsius: 42.0), .hot, "hot threshold is inclusive")
        XCTAssertEqual(BatteryThermalState.from(celsius: 55.0), .hot)
    }

    /// The reading overload: a real number classifies exactly as the Double path, and BOTH absence
    /// cases stay `.unknown` so the badge never invents a judgment (the row says why instead).
    func testReadingOverloadClassifiesAndStaysSilentWhenAbsent() {
        XCTAssertEqual(BatteryThermalState.from(reading: .celsius(39.79)), .warm)
        XCTAssertEqual(BatteryThermalState.from(reading: .celsius(25.0)), .normal)
        XCTAssertEqual(BatteryThermalState.from(reading: .celsius(42.0)), .hot)
        XCTAssertEqual(BatteryThermalState.from(reading: .unsupportedByOS), .unknown)
        XCTAssertEqual(BatteryThermalState.from(reading: .notYetRead), .unknown)
    }

    /// End-to-end for the bug this fixes: the live macOS 27 pack dict must classify, not go inert.
    func testMacOS27PackTemperatureClassifiesAsWarm() {
        let d = BatteryTelemetryParser.parseDiagnostics([
            "CycleCount": 523,
            BatteryTelemetryParser.packPropertiesKey: ["BatteryData": ["Temperature": 3979]],
        ])
        XCTAssertEqual(BatteryThermalState.from(celsius: d.temperatureCelsius), .warm,
                       "39.79 °C is above the 37 °C warm threshold — EI-4 must actually fire")
    }

    func testBelowZeroIsNormal() {
        // No lower/cold flag in v1 — a below-zero reading classifies as normal.
        XCTAssertEqual(BatteryThermalState.from(celsius: -5.0), .normal)
    }
}
