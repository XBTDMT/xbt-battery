import Foundation

/// spec 31 §1.1 / §1.2 fixtures — live captures from this Mac (2026-09-28), never invented shapes.
/// Shared by PortPowerParserTests, PortPowerMathTests and PortPowerSourceTests.
enum PortPowerFixtures {

    /// §1.1 VERBATIM — one `PowerOutDetails` element, the owner's iPhone charging on a cable.
    static func capturedIPhoneElement() -> [String: Any] {
        ["PortIndex": 2, "PortType": 0, "PowerState": 0, "Watts": 14097, "FilteredPower": 14054, "Current": 2716,
         "AdapterVoltage": 5190, "ConfiguredVoltage": 5000, "ConfiguredCurrent": 3000, "PDPowermW": 15000,
         "AccumulatedPower": 169827, "AccumulatorCount": 15, "AccumulatorErrorCount": 0,
         "USBSleepPoolPowermW": 12000, "USBWakePoolPowermW": 12000,
         "VConnPower": 87, "VConnCurrent": 16, "VConnMaxCurrent": 330, "VConnAccumulatedPower": 1236,
         "VConnAccumulatorCount": 15, "VConnAccumulatorErrorCount": 0, "NumLDCMCollisions": 0]
    }

    /// What `capturedIPhoneElement()` must parse to.
    static let capturedIPhonePort = PortPower(
        portIndex: 2, filteredPower_mW: 14_054, watts_mW: 14_097, contract_mW: 15_000,
        current_mA: 2_716, voltage_mV: 5_190, accumulatedPower: 169_827, accumulatorCount: 15)

    /// A minimal element for hysteresis / multi-port cases.
    static func element(portIndex: Int, filteredPower: Int) -> [String: Any] {
        ["PortIndex": portIndex, "FilteredPower": filteredPower, "Watts": filteredPower, "PDPowermW": 15_000]
    }

    /// One accumulator snapshot of `PowerTelemetryData`.
    struct Frame: Equatable {
        var accBP: Int64
        var cntBP: Int64
        var accDis: Int64
        var cntDis: Int64
    }

    /// The live frame of 2026-09-28 (ioreg, on the 65 W charger). `AccumulatedBatteryDischarge` printed
    /// by ioreg as 18446744072507381006 = 2^64 − 1_202_170_610: the signed value CF bridging delivers.
    static let base = Frame(accBP: 1_229_859_229, cntBP: 45_395, accDis: -1_202_170_610, cntDis: 52_621)

    /// A charge-only window: only the charge pair moves (ΔcntDischarge = 0).
    static func charging(_ f: Frame, counts: Int64 = 60, mW: Int64 = 5_600) -> Frame {
        Frame(accBP: f.accBP + counts * mW, cntBP: f.cntBP + counts, accDis: f.accDis, cntDis: f.cntDis)
    }

    /// A discharge-only window: only the (negative) discharge pair moves (ΔcntBatteryPower = 0).
    static func discharging(_ f: Frame, counts: Int64 = 60, mW: Int64 = 25_000) -> Frame {
        Frame(accBP: f.accBP, cntBP: f.cntBP, accDis: f.accDis - counts * mW, cntDis: f.cntDis + counts)
    }

    /// §2.1's verified mixed window: 37 charge counts + 23 discharge counts = 60 over ~62 s.
    static func mixed(_ f: Frame) -> Frame {
        Frame(accBP: f.accBP + 37 * 7_000, cntBP: f.cntBP + 37,
              accDis: f.accDis - 23 * 3_000, cntDis: f.cntDis + 23)
    }

    static func telemetry(_ f: Frame) -> PowerTelemetry {
        PowerTelemetry(systemPowerIn_mW: 62_706, systemLoad_mW: 58_028, batteryPower_mW: 4_678,
                       accBatteryPower: f.accBP, cntBatteryPower: f.cntBP,
                       accBatteryDischarge: f.accDis, cntBatteryDischarge: f.cntDis)
    }

    static func telemetryDict(_ f: Frame, systemPowerIn: Int = 62_706, batteryPower: Int = 4_678) -> [String: Any] {
        ["SystemPowerIn": systemPowerIn,
         "SystemLoad": max(0, systemPowerIn - batteryPower),   // SystemLoad = SystemPowerIn − BatteryPower (§1.2)
         "BatteryPower": batteryPower,
         "AdapterEfficiencyLoss": 1_847,
         "AccumulatedBatteryPower": f.accBP,
         "BatteryPowerAccumulatorCount": f.cntBP,
         "AccumulatedBatteryDischarge": f.accDis,
         "BatteryDischargeAccumulatorCount": f.cntDis]
    }

    /// The full live `PowerTelemetryData` dict of 2026-09-28, verbatim except the discharge accumulator,
    /// which is given as the signed value CF bridging delivers.
    static func liveTelemetryDict() -> [String: Any] {
        ["AccumulatedWallEnergyEstimate": 2_122_299_784, "SystemEnergyConsumed": 17_418,
         "SystemPowerInAccumulatorCount": 205_890, "AdapterEfficiencyLoss": 1_847, "SystemLoad": 58_028,
         "AccumulatedSystemLoad": 6_927_936_812, "AccumulatedSystemEnergyConsumed": 5_655_779_401_428,
         "SystemCurrentIn": 3_251, "WallEnergyEstimate": 19_265, "AccumSystemEffectiveTotalLoadCount": 0,
         "SystemLoadAccumulatorCount": 394_149, "AdapterEfficiencyLossAccumulatorCount": 201_166,
         "AccumSystemEffectiveTotalLoad": 0, "SystemVoltageIn": 19_286, "SystemPowerIn": 62_706,
         "AccumulatedBatteryPower": 1_229_859_229, "PowerTelemetryErrorCount": 0,
         "AccumulatedAdapterEfficiencyLoss": 149_301_840_973_803, "SystemEffectiveTotalLoad": 0,
         "BatteryPowerAccumulatorCount": 45_395, "AccumulatedSystemPowerIn": 20_360_805_641_175,
         "BatteryPower": 4_678, "AccumulatedBatteryDischarge": Int64(-1_202_170_610),
         "BatteryDischargeAccumulatorCount": 52_621]
    }

    /// A whole `AppleSmartBattery` props dict in the macOS 27 layout. `BatteryData.BatteryPower` is a
    /// DECOY in every fixture (Voltage × the sampled Amperage — the stale number §1.2 forbids), so any
    /// code that reads it shows up as a wrong value.
    static func props(ports: [[String: Any]]?,
                      frame: Frame?,
                      externalConnected: Bool?,
                      updateTime: Int = 1_790_630_342,
                      ipdInputPower: Int? = 65_000,
                      bankCount: Int? = 3,
                      systemPowerIn: Int = 62_706,
                      batteryPower: Int = 4_678) -> [String: Any] {
        var p: [String: Any] = [
            "UpdateTime": updateTime,
            "BatteryData": ["FullChargeCapacity": 5_400, "RemainingCapacity": 2_538,
                            "BatteryPower": -12_000] as [String: Any],
        ]
        if let ports { p[PortPowerParser.portsKey] = ports }
        if let frame {
            p[PortPowerParser.telemetryKey] = telemetryDict(frame, systemPowerIn: systemPowerIn,
                                                            batteryPower: batteryPower)
        }
        if let externalConnected { p["ExternalConnected"] = externalConnected }
        if let ipdInputPower { p["PowerDistribution"] = ["IPDInputPower": ipdInputPower] as [String: Any] }
        if let bankCount { p[BatteryTelemetryParser.packPropertiesKey] = ["BankCount": bankCount] as [String: Any] }
        return p
    }
}
