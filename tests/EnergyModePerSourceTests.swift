import XCTest
// app/Monitoring compiles into this target → EnergyModeReader visible host-app-free.

/// Sprint 3.7 fix A1: per-source Energy Mode read-back via `pmset -g custom`. The single active read
/// (`pmset -g`) reflects only the CURRENT source's profile, so on battery an AC-profile set looked
/// inert in the picker. `pmset -g custom` prints BOTH profiles; the parser keys each `powermode` to
/// its profile header, so the value for each source is correct INDEPENDENT of which source is active.
final class EnergyModePerSourceTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/energy/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The handoff's named case: battery 0 / AC 2 → battery = .automatic, charger = .high.
    func testParseCustom_battery0_AC2() throws {
        let m = EnergyModeReader.parseCustomPerSource(try fixture("pmset-g-custom-bat0-ac2.txt"))
        XCTAssertEqual(m.battery, .automatic, "Battery Power powermode 0 → Automatic")
        XCTAssertEqual(m.charger, .high, "AC Power powermode 2 → High")
    }

    /// INDEPENDENT OF ACTIVE SOURCE: the reversed fixture (battery 2 / AC 0) must flip both, proving the
    /// parser keys each value to its profile header — not to position, order, or the active source.
    func testParseCustom_reversed_battery2_AC0_provesPerProfileKeying() throws {
        let m = EnergyModeReader.parseCustomPerSource(try fixture("pmset-g-custom-bat2-ac0.txt"))
        XCTAssertEqual(m.battery, .high, "Battery Power powermode 2 → High")
        XCTAssertEqual(m.charger, .automatic, "AC Power powermode 0 → Automatic")
    }

    /// Low Power on battery, High on AC — the full ladder across both profiles.
    func testParseCustom_lowBattery_highAC() {
        let out = """
        Battery Power:
         powermode            1
        AC Power:
         powermode            2
        """
        let m = EnergyModeReader.parseCustomPerSource(out)
        XCTAssertEqual(m.battery, .low)
        XCTAssertEqual(m.charger, .high)
    }

    /// "lowpowermode" (a different pmset key) must NOT be misread as the `powermode` value.
    func testParseCustom_lowpowermodeKeyNotMisread() {
        let out = """
        Battery Power:
         lowpowermode         1
         powermode            2
        AC Power:
         lowpowermode         0
         powermode            1
        """
        let m = EnergyModeReader.parseCustomPerSource(out)
        XCTAssertEqual(m.battery, .high, "battery powermode is 2, not the lowpowermode 1")
        XCTAssertEqual(m.charger, .low, "AC powermode is 1, not the lowpowermode 0")
    }

    /// DEGRADATION: a profile with no powermode line → .unavailable for THAT profile only (never crash,
    /// never borrow the other profile's value).
    func testParseCustom_missingPowermodeInOneProfile_isUnavailableForThatProfileOnly() {
        let out = """
        Battery Power:
         powermode            1
        AC Power:
         standby              1
        """
        let m = EnergyModeReader.parseCustomPerSource(out)
        XCTAssertEqual(m.battery, .low)
        XCTAssertEqual(m.charger, .unavailable, "AC has no powermode line → unavailable, not borrowed from battery")
    }

    /// Fully garbled / no headers → both .unavailable, no crash.
    func testParseCustom_garbled_bothUnavailable() {
        let m = EnergyModeReader.parseCustomPerSource("not a pmset output at all\n???")
        XCTAssertEqual(m.battery, .unavailable)
        XCTAssertEqual(m.charger, .unavailable)
    }

    /// An out-of-range powermode value → .unavailable (defensive; matches the active parser).
    func testParseCustom_outOfRangeValue_isUnavailable() {
        let out = """
        Battery Power:
         powermode            9
        AC Power:
         powermode            2
        """
        let m = EnergyModeReader.parseCustomPerSource(out)
        XCTAssertEqual(m.battery, .unavailable, "powermode 9 is out of {0,1,2} → unavailable")
        XCTAssertEqual(m.charger, .high)
    }
}
