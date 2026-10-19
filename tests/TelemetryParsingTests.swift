import XCTest
import IOKit.ps   // for the kIOPS…Key constants used in fixtures
// app/Monitoring is compiled into this test target → parsers visible host-app-free.

/// Pure-parser tests, incl. the 2%-bug regression guard. (SPEC WI-1.7; decision #8 pattern.)
final class TelemetryParsingTests: XCTestCase {

    /// The 2%-bug fixture: health must be ~90% (from raw mAh), NOT ~2% (from MaxCapacity).
    func testHealthGuardAgainstTwoPercentBug() {
        let d = BatteryTelemetryParser.parseDiagnostics([
            "MaxCapacity": 100, "AppleRawMaxCapacity": 4500, "DesignCapacity": 5000,
        ])
        XCTAssertNotNil(d.healthPercent)
        XCTAssertEqual(d.healthPercent!, 90.0, accuracy: 0.5)
        XCTAssertFalse(abs(d.healthPercent! - 2.0) < 0.5,
                       "health must never be computed from MaxCapacity (the 2% bug)")
    }

    /// macOS 27 relocated the raw mAh capacities into a nested `BatteryData` dict; the parser must read
    /// them there when the pre-27 top-level keys are absent — otherwise FCC + health go nil (the bug that
    /// silently broke Health and blocked the hero Time projection on 27).
    func testCapacityAndHealthReadFromNestedBatteryData() {
        let d = BatteryTelemetryParser.parseDiagnostics([
            "MaxCapacity": 100,   // the 0–100 % value — must NOT be used for capacity/health
            "BatteryData": ["FullChargeCapacity": 5292, "DesignCapacity": 6249],
        ])
        XCTAssertEqual(d.fullChargeCapacity_mAh, 5292)
        XCTAssertEqual(d.designCapacity_mAh, 6249)
        XCTAssertNotNil(d.healthPercent)
        XCTAssertEqual(d.healthPercent!, 84.7, accuracy: 0.2)   // 5292 / 6249
    }

    func testTopLevelCapacityKeysPreferredWhenPresent() {
        // pre-27 layout: top-level raw keys present → used verbatim, the nested dict ignored.
        let d = BatteryTelemetryParser.parseDiagnostics([
            "AppleRawMaxCapacity": 4500, "DesignCapacity": 5000,
            "BatteryData": ["FullChargeCapacity": 9999, "DesignCapacity": 9999],
        ])
        XCTAssertEqual(d.fullChargeCapacity_mAh, 4500)
        XCTAssertEqual(d.designCapacity_mAh, 5000)
        XCTAssertEqual(d.healthPercent!, 90.0, accuracy: 0.5)
    }

    // MARK: - temperature ladder (macOS 26 → 27 drift)

    /// The macOS 27.0 layout, captured VERBATIM off this machine (`ioreg -r -c AppleSmartBatteryPack`):
    /// the top-level `Temperature` key is gone from AppleSmartBattery and the gas gauge — Temperature
    /// included — lives on the CHILD AppleSmartBatteryPack node's nested `BatteryData`. Without the last
    /// ladder rung the Details row is permanently "—" and every EI-4 heat classification is inert.
    func testTemperatureReadFromChildPackOnMacOS27() {
        let d = BatteryTelemetryParser.parseDiagnostics([
            "CycleCount": 523, "Voltage": 12019,
            "BatteryData": ["FullChargeCapacity": 5466, "DesignCapacity": 6249],   // no Temperature here
            BatteryTelemetryParser.packPropertiesKey: [
                "BatteryData": ["Temperature": 3979, "VirtualTemperature": 3979,
                                "AppleRawMaxCapacity": 5466, "DesignCapacity": 6249],
            ],
        ])
        XCTAssertEqual(d.temperatureCelsius!, 39.79, accuracy: 0.001)   // centi-°C → °C
    }

    func testTopLevelTemperaturePreferredOverThePack() {
        // pre-27 layout still wins outright: the top-level key is used verbatim, the child ignored.
        let d = BatteryTelemetryParser.parseDiagnostics([
            "Temperature": 3000,
            BatteryTelemetryParser.packPropertiesKey: ["BatteryData": ["Temperature": 9999]],
        ])
        XCTAssertEqual(d.temperatureCelsius!, 30.0, accuracy: 0.001)
    }

    func testTemperatureFallsBackToNestedBatteryDataThenVirtual() {
        let nested = BatteryTelemetryParser.parseDiagnostics(["BatteryData": ["Temperature": 3150]])
        XCTAssertEqual(nested.temperatureCelsius!, 31.5, accuracy: 0.001)

        // `Temperature` absent on the pack → `VirtualTemperature` is the last rung.
        let virtual = BatteryTelemetryParser.parseDiagnostics([
            BatteryTelemetryParser.packPropertiesKey: ["BatteryData": ["VirtualTemperature": 3969]],
        ])
        XCTAssertEqual(virtual.temperatureCelsius!, 39.69, accuracy: 0.001)
    }

    func testTemperatureNilWhenNoRungCarriesIt() {
        // Every rung absent → nil, and the snapshot must then say WHY (see the reading tests below).
        let d = BatteryTelemetryParser.parseDiagnostics(["Voltage": 12300])
        XCTAssertNil(d.temperatureCelsius)
    }

    func testImplausibleTemperatureIsRejectedAsAPlaceholder() {
        // 0xFFFF and friends are gauge placeholders, not a 655 °C pack — never render them.
        XCTAssertNil(BatteryTelemetryParser.parseDiagnostics(["Temperature": 65535]).temperatureCelsius)
        XCTAssertNil(BatteryTelemetryParser.parseDiagnostics(["Temperature": -9999]).temperatureCelsius)
    }

    /// Absence-by-design vs failure-to-read: a bare em-dash used to cover both.
    func testTemperatureReadingDistinguishesUnsupportedFromNotYetRead() {
        XCTAssertEqual(BatterySnapshot.empty.temperatureReading, .notYetRead)

        var read = BatterySnapshot()
        read.cycleCount = 523            // the battery node WAS read; it just carries no temperature
        read.voltageVolts = 12.019
        XCTAssertEqual(read.temperatureReading, .unsupportedByOS)

        read.temperatureCelsius = 39.79
        XCTAssertEqual(read.temperatureReading, .celsius(39.79))
    }

    func testUnitConversions() {
        let d = BatteryTelemetryParser.parseDiagnostics(["Temperature": 3000, "Voltage": 12000])
        XCTAssertEqual(d.temperatureCelsius!, 30.0, accuracy: 0.001)   // centi-°C → °C
        XCTAssertEqual(d.voltageVolts!, 12.0, accuracy: 0.001)         // mV → V

        let live = BatteryTelemetryParser.parseLive([kIOPSCurrentCapacityKey: 82])
        XCTAssertEqual(live.chargePercent, 82)
    }

    func testSignedAmperage() {
        // 0xFFFFF93C as an unsigned > Int32.max → two's-complement −1732 (discharging).
        let discharging = BatteryTelemetryParser.parseDiagnostics(["Amperage": 4_294_965_564])
        XCTAssertEqual(discharging.amperageMilliamps, -1732)

        let charging = BatteryTelemetryParser.parseDiagnostics(["Amperage": 1500])
        XCTAssertEqual(charging.amperageMilliamps, 1500)
    }

    func testCalculatingSentinelMapsToNil() {
        let live = BatteryTelemetryParser.parseLive([
            kIOPSTimeToEmptyKey: -1, kIOPSTimeToFullChargeKey: -1,
        ])
        XCTAssertNil(live.minutesToEmpty)
        XCTAssertNil(live.minutesToFull)
    }

    func testPowerSourceMapping() {
        XCTAssertEqual(BatteryTelemetryParser.parseLive([kIOPSPowerSourceStateKey: kIOPSACPowerValue]).powerSource, .ac)
        XCTAssertEqual(BatteryTelemetryParser.parseLive([kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]).powerSource, .battery)
        XCTAssertEqual(BatteryTelemetryParser.parseLive([kIOPSPowerSourceStateKey: "Something Else"]).powerSource, .unknown)
    }

    /// Bonus: the on-device M4 Max powermode line parses to .high (WI-1.6 / WI-1.8 reality).
    func testEnergyModeParsesPowermode() {
        XCTAssertEqual(EnergyModeReader.parsePowermode(" powermode            2\n"), .high)
        XCTAssertEqual(EnergyModeReader.parsePowermode(" powermode            1\n"), .low)   // #2-glyph: yellow
        XCTAssertEqual(EnergyModeReader.parsePowermode(" powermode            0\n"), .automatic)
        XCTAssertEqual(EnergyModeReader.parsePowermode("no mode here"), .unavailable)
    }
}
