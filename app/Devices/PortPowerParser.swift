import Foundation

/// spec 31 §1.1 — one element of `AppleSmartBattery.PowerOutDetails`: a port SOURCING power. Units as the
/// registry publishes them: mW, mA, mV. Only the fields the feature uses are kept.
struct PortPower: Equatable, Sendable {
    let portIndex: Int
    /// `FilteredPower` mW — the measured figure a row shows (T7). Never negative: such an element is dropped.
    let filteredPower_mW: Int
    let watts_mW: Int?
    /// `PDPowermW` — the negotiated contract ("up to"): hover / VoiceOver only, never a row figure.
    let contract_mW: Int?
    let current_mA: Int?
    /// `AdapterVoltage` mV at the port.
    let voltage_mV: Int?
    let accumulatedPower: Int64?
    let accumulatorCount: Int64?
}

/// spec 31 §3.1 — absence is not a fact. `.read([])` = a successful read on which no port sources power;
/// `.unread` = the latest read failed (or its `PowerOutDetails` was malformed); `.notYetRead` = before the
/// first read since launch.
enum PortPowerReading: Equatable, Sendable {
    case notYetRead
    case read([PortPower])
    case unread
}

/// spec 31 §1.2 — `AppleSmartBattery.PowerTelemetryData`. mW; `batteryPower_mW` signed (+ = pack gaining).
/// Accumulators are signed 64-bit: the discharge accumulator is NEGATIVE (ioreg prints it wrapped as
/// 2^64 − n; CF bridging delivers the signed value). Nothing here ever comes from `BatteryData`.
struct PowerTelemetry: Equatable, Sendable {
    let systemPowerIn_mW: Int?
    let systemLoad_mW: Int?
    let batteryPower_mW: Int?
    let accBatteryPower: Int64?
    let cntBatteryPower: Int64?
    let accBatteryDischarge: Int64?
    let cntBatteryDischarge: Int64?
}

/// Pure parsers over one `AppleSmartBattery` props dict (the pack child folded in by `LiveBatteryReader`).
/// Dict in, values out: no IOKit, no clock, no defaults — host-app-free. Garbage never traps: every
/// multiplication reports overflow, every negative mW is dropped (except the signed pack figures).
enum PortPowerParser {
    static let portsKey = "PowerOutDetails"
    static let telemetryKey = "PowerTelemetryData"

    /// The sourcing ports, sorted by `portIndex`. Absent key → `[]` (no port sources power). A non-dict
    /// element, a missing / negative `FilteredPower` or `PortIndex` drops that element; a repeated
    /// `PortIndex` keeps the first. A present-but-malformed key also yields `[]` here — callers MUST check
    /// `portsKeyIsMalformed` first and report `.unread` (a malformed key is not "no port").
    static func ports(_ props: [String: Any]) -> [PortPower] {
        guard let raw = props[portsKey] as? [Any] else { return [] }
        var byIndex: [Int: PortPower] = [:]
        for item in raw {
            guard let dict = item as? [String: Any], let parsed = element(dict),
                  byIndex[parsed.portIndex] == nil else { continue }
            byIndex[parsed.portIndex] = parsed
        }
        return byIndex.values.sorted { $0.portIndex < $1.portIndex }
    }

    /// `PowerOutDetails` present but unreadable: not an array, or a NON-EMPTY array of which not one element
    /// parses into a `PortPower` (e.g. `FilteredPower` renamed by an OS change). The read happened but says
    /// nothing trustworthy about the ports → the caller reports `.unread`, never `.read([])`. An empty array
    /// is a real "no port sources power" (false); a mix of good and bad elements is NOT malformed (bad ones
    /// are dropped, good ones kept).
    static func portsKeyIsMalformed(_ props: [String: Any]) -> Bool {
        guard let value = props[portsKey] else { return false }
        guard let raw = value as? [Any] else { return true }
        return !raw.isEmpty && ports(props).isEmpty
    }

    /// `PowerTelemetryData` only — NEVER `BatteryData.BatteryPower` (Voltage × the sampled Amperage, the
    /// stale current the project forbids). Absent or non-dict → nil (unread).
    static func telemetry(_ props: [String: Any]) -> PowerTelemetry? {
        guard let d = props[telemetryKey] as? [String: Any] else { return nil }
        // Negative by construction (§1.2); a positive value is garbage, not a discharge.
        let discharge = int64(d["AccumulatedBatteryDischarge"]).flatMap { $0 <= 0 ? $0 : nil }
        return PowerTelemetry(
            systemPowerIn_mW: nonNegativeInt(d["SystemPowerIn"]),
            systemLoad_mW: nonNegativeInt(d["SystemLoad"]),
            batteryPower_mW: int64(d["BatteryPower"]).map { Int($0) },
            accBatteryPower: nonNegativeInt64(d["AccumulatedBatteryPower"]),
            cntBatteryPower: nonNegativeInt64(d["BatteryPowerAccumulatorCount"]),
            accBatteryDischarge: discharge,
            cntBatteryDischarge: nonNegativeInt64(d["BatteryDischargeAccumulatorCount"]))
    }

    /// The Mac's real input ceiling (mW): `PowerDistribution.IPDInputPower` (89 200 on a 100 W charger),
    /// else the NESTED `AdapterDetails.AdapterVoltage` mV × `AdapterDetails.PMUConfiguration` mA / 1000.
    /// There is no top-level `PMUConfiguration`. Overflow → nil.
    static func inputCeiling_mW(_ props: [String: Any]) -> Int? {
        if let distribution = props["PowerDistribution"] as? [String: Any],
           let ipd = positiveInt(distribution["IPDInputPower"]) {
            return ipd
        }
        guard let adapter = props["AdapterDetails"] as? [String: Any],
              let millivolts = positiveInt(adapter["AdapterVoltage"]),
              let milliamps = positiveInt(adapter["PMUConfiguration"]) else { return nil }
        let (product, overflow) = millivolts.multipliedReportingOverflow(by: milliamps)
        guard !overflow else { return nil }
        return product / 1000
    }

    /// `ExternalConnected` from THIS read — the one power-source signal for the port source, the band,
    /// the cost line and (stage 5) the latch. Missing / non-Bool → nil (unread, §3.5).
    static func externalConnected(_ props: [String: Any]) -> Bool? {
        props["ExternalConnected"] as? Bool
    }

    /// `UpdateTime` (epoch seconds of the record's last refresh, ~60 s cadence). Non-positive → nil.
    static func updateTime(_ props: [String: Any]) -> Int? {
        positiveInt(props["UpdateTime"])
    }

    /// The pack child's `BankCount` (3 on this Mac), from the fold `LiveBatteryReader` adds under
    /// `BatteryTelemetryParser.packPropertiesKey`. Absent / non-positive → nil (no cost line).
    static func bankCount(_ props: [String: Any]) -> Int? {
        let pack = props[BatteryTelemetryParser.packPropertiesKey] as? [String: Any]
        return positiveInt(pack?["BankCount"])
    }

    /// Reuses the diagnostics parser's ladder (top-level `AppleRawCurrentCapacity`, else
    /// `BatteryData.RemainingCapacity`) — never `TrueRemainingCapacity`, which reads 0. Negative → nil.
    static func remainingCapacity_mAh(_ props: [String: Any]) -> Int? {
        BatteryTelemetryParser.parseDiagnostics(props).remainingCapacity_mAh.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Reuses the diagnostics parser's ladder (`AppleRawMaxCapacity`, else `BatteryData.FullChargeCapacity`).
    static func fullChargeCapacity_mAh(_ props: [String: Any]) -> Int? {
        BatteryTelemetryParser.parseDiagnostics(props).fullChargeCapacity_mAh.flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: - helpers

    private static func element(_ d: [String: Any]) -> PortPower? {
        guard let index = nonNegativeInt(d["PortIndex"]),
              let filtered = nonNegativeInt(d["FilteredPower"]) else { return nil }
        return PortPower(portIndex: index, filteredPower_mW: filtered,
                         watts_mW: nonNegativeInt(d["Watts"]),
                         contract_mW: nonNegativeInt(d["PDPowermW"]),
                         current_mA: nonNegativeInt(d["Current"]),
                         voltage_mV: nonNegativeInt(d["AdapterVoltage"]),
                         accumulatedPower: nonNegativeInt64(d["AccumulatedPower"]),
                         accumulatorCount: nonNegativeInt64(d["AccumulatorCount"]))
    }

    /// Signed 64-bit, never folded to Int32.
    private static func int64(_ any: Any?) -> Int64? { (any as? NSNumber)?.int64Value }
    private static func nonNegativeInt64(_ any: Any?) -> Int64? { int64(any).flatMap { $0 >= 0 ? $0 : nil } }
    private static func nonNegativeInt(_ any: Any?) -> Int? { nonNegativeInt64(any).map { Int($0) } }
    private static func positiveInt(_ any: Any?) -> Int? { nonNegativeInt(any).flatMap { $0 > 0 ? $0 : nil } }
}

/// spec 31 §2.1 — the ONE pack-power estimator. P = (ΔaccBP + ΔaccDischarge) ÷ (ΔcntBP + ΔcntDischarge)
/// between two distinct frames (mW; + = pack gaining). The pack splits charging and discharging into two
/// accumulators whose counts sum to ~1/s, and either alone reads zero in the other direction, so BOTH pairs
/// are always used. nil when any field is missing, a counter went backwards (reset), the charge
/// accumulator fell or the discharge accumulator rose (garbage), a pair's energy moved while its own
/// count did not (inconsistent frame), the count delta is ≤ 0, or any
/// arithmetic would overflow.
enum PackPowerAverager {
    static func averaged_mW(previous: PowerTelemetry, current: PowerTelemetry) -> Double? {
        guard let a0 = previous.accBatteryPower, let a1 = current.accBatteryPower,
              let c0 = previous.cntBatteryPower, let c1 = current.cntBatteryPower,
              let d0 = previous.accBatteryDischarge, let d1 = current.accBatteryDischarge,
              let k0 = previous.cntBatteryDischarge, let k1 = current.cntBatteryDischarge,
              let chargeEnergy = delta(a1, a0), let chargeCount = delta(c1, c0),
              let dischargeEnergy = delta(d1, d0), let dischargeCount = delta(k1, k0),
              chargeCount >= 0, dischargeCount >= 0, chargeEnergy >= 0, dischargeEnergy <= 0,
              // A pair whose own count did not move cannot have moved its energy: an inconsistent frame,
              // never divided by the other pair's count.
              chargeCount > 0 || chargeEnergy == 0, dischargeCount > 0 || dischargeEnergy == 0 else { return nil }
        let (count, countOverflow) = chargeCount.addingReportingOverflow(dischargeCount)
        let (energy, energyOverflow) = chargeEnergy.addingReportingOverflow(dischargeEnergy)
        guard !countOverflow, !energyOverflow, count > 0 else { return nil }
        return Double(energy) / Double(count)
    }

    private static func delta(_ later: Int64, _ earlier: Int64) -> Int64? {
        let (value, overflow) = later.subtractingReportingOverflow(earlier)
        return overflow ? nil : value
    }
}
