import XCTest

/// Sprint 4.E (#20): the live wattage readout — watts = (Voltage_mV × InstAmp_mA)/1e6, signed,
/// rounded 0.1 W; "Charging"/"Discharging"/"0 W"; nil on missing inputs.
final class WattageReadoutTests: XCTestCase {

    private func label(_ v: Double?, _ mA: Int?) -> String? {
        WattageReadout.label(voltageVolts: v, amperageMilliamps: mA)
    }

    func testChargingPositiveFlow() {
        // 12.6 V × 5100 mA / 1000 = 64.26 W → 64.3 W charging
        XCTAssertEqual(label(12.6, 5100), "Charging — 64.3 W")
    }

    func testDischargingNegativeFlow() {
        // 11.3 V × -1088 mA / 1000 = -12.29 W → 12.3 W discharging (magnitude shown)
        XCTAssertEqual(label(11.3, -1088), "Discharging — 12.3 W")
    }

    func testZeroAtHold() {
        XCTAssertEqual(label(12.4, 0), "0 W")
        // sub-0.05 W rounds to zero → "0 W" (no Charging/Discharging direction at a hold)
        XCTAssertEqual(label(12.0, 2), "0 W")   // 0.024 W → 0
    }

    func testRoundingToTenthWatt() {
        // 10.0 V × 1234 mA / 1000 = 12.34 W → 12.3 W
        XCTAssertEqual(label(10.0, 1234), "Charging — 12.3 W")
        // 10.0 V × 1250 mA / 1000 = 12.50 W → 12.5 W
        XCTAssertEqual(label(10.0, 1250), "Charging — 12.5 W")
    }

    func testNilOnMissingInputs() {
        XCTAssertNil(label(nil, 5000))
        XCTAssertNil(label(12.0, nil))
        XCTAssertNil(label(nil, nil))
    }

    /// The twin of `testCompactNilOnNonFiniteVoltage` — `label` carried the identical defect and would
    /// have rendered "Discharging — nan W" on the Details Power card. A value we cannot compute is a
    /// MISSING value, not a negative one.
    func testLabelNilOnNonFiniteVoltage() {
        XCTAssertNil(label(.nan, 5000), "NaN volts must not render as 'Discharging — nan W'")
        XCTAssertNil(label(.infinity, 5000))
        XCTAssertNil(label(-.infinity, 5000))
        XCTAssertNil(WattageReadout.label(voltageVolts: .nan, amperageMilliamps: 5000, adapterWatts: 96),
                     "the adapter-ceiling path is guarded too")
        XCTAssertEqual(label(12.4, 0), "0 W", "a finite hold reading is still the honest 0 W")
    }

    // MARK: - #EI-3 adapter wattage ceiling (appends only while charging)

    func testChargingAppendsAdapterCeiling() {
        XCTAssertEqual(WattageReadout.label(voltageVolts: 12.6, amperageMilliamps: 5100, adapterWatts: 75),
                       "Charging — 64.3 W of 75 W")
    }

    func testChargingNilAdapterUnchanged() {
        XCTAssertEqual(WattageReadout.label(voltageVolts: 12.6, amperageMilliamps: 5100, adapterWatts: nil),
                       "Charging — 64.3 W", "nil adapter → no ceiling (backward-compatible)")
    }

    func testDischargingIgnoresAdapterCeiling() {
        XCTAssertEqual(WattageReadout.label(voltageVolts: 11.3, amperageMilliamps: -1088, adapterWatts: 75),
                       "Discharging — 12.3 W", "no ceiling on discharge")
    }

    func testZeroIgnoresAdapterCeiling() {
        XCTAssertEqual(WattageReadout.label(voltageVolts: 12.4, amperageMilliamps: 0, adapterWatts: 75),
                       "0 W", "idle/hold → no ceiling")
    }

    // MARK: - compact() — the hero stat-row form: signed magnitude, no direction word

    func testCompactChargingSigned() {
        // 12.6 V × 5100 mA / 1000 = 64.26 W → "+64.3 W"
        XCTAssertEqual(WattageReadout.compact(voltageVolts: 12.6, amperageMilliamps: 5100), "+64.3 W")
    }
    func testCompactDischargingSigned() {
        // 11.3 V × -1088 mA / 1000 = -12.29 W → "−12.3 W" (U+2212 minus)
        XCTAssertEqual(WattageReadout.compact(voltageVolts: 11.3, amperageMilliamps: -1088), "−12.3 W")
    }
    func testCompactZeroAtHold() {
        XCTAssertEqual(WattageReadout.compact(voltageVolts: 12.4, amperageMilliamps: 0), "0 W")
    }
    func testCompactNilOnMissingInputs() {
        XCTAssertNil(WattageReadout.compact(voltageVolts: nil, amperageMilliamps: 5000))
        XCTAssertNil(WattageReadout.compact(voltageVolts: 12.0, amperageMilliamps: nil))
    }

    /// B-arc seam 1 (the 5749e0d review's recorded non-security defect): a non-finite voltage fails BOTH
    /// the `== 0` and `> 0` tests, so it used to fall through to the negative branch and print "−nan W".
    /// A number we cannot compute is a MISSING number — nil, so the hero row renders "—".
    func testCompactNilOnNonFiniteVoltage() {
        XCTAssertNil(WattageReadout.compact(voltageVolts: .nan, amperageMilliamps: 5000),
                     "NaN volts is not a reading — must not render as '−nan W'")
        XCTAssertNil(WattageReadout.compact(voltageVolts: .infinity, amperageMilliamps: 5000))
        XCTAssertNil(WattageReadout.compact(voltageVolts: -.infinity, amperageMilliamps: 5000))
        // A zero amperage against a finite voltage is still the honest hold reading, not a missing one.
        XCTAssertEqual(WattageReadout.compact(voltageVolts: 12.4, amperageMilliamps: 0), "0 W")
    }
}
