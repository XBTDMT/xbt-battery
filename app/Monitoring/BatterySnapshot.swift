import Foundation
import IOKit.ps   // for the kIOPS…Key string constants (constants only — no IOKit calls here)

/// Merged, display-ready battery state for this Mac. `Equatable` for SwiftUI diffing.
/// (SPEC WI-1.1; decisions #13 health, #14 units.)
struct BatterySnapshot: Equatable {
    // Nested enums (SPEC WI-1.1). The file-scope typealiases below keep the unqualified
    // `PowerSource` / `EnergyMode` references the spec uses elsewhere (LiveTelemetry, the
    // parsers, the reader, the view, the tests) resolving to these nested types.
    enum PowerSource { case ac, battery, unknown }
    enum EnergyMode { case automatic, low, high, unavailable }

    var chargePercent: Int?
    var isCharging: Bool?
    var powerSource: PowerSource = .unknown
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var healthPercent: Double?
    var cycleCount: Int?
    var temperatureCelsius: Double?
    var voltageVolts: Double?
    var amperageMilliamps: Int?
    /// The rolling-mean current (via `AmperageSmoother`) the hero's Time projection uses, so the
    /// estimate doesn't jump with each raw sample. Additive, DEFAULT nil so existing consumers are
    /// unaffected; the monitor populates it. Signed like `amperageMilliamps` (+ into the pack / − out).
    var smoothedAmperageMilliamps: Int?
    var fullChargeCapacity_mAh: Int?
    var designCapacity_mAh: Int?
    var energyMode: EnergyMode = .unavailable
    /// Phase 4 (sec 13.2): BOTH sources' saved Energy Modes (`pmset -g custom`), so the auto-energy
    /// runner can read the INACTIVE source's mode (the active `energyMode` above is the live `-g` read).
    /// Additive, DEFAULT `.unavailable` so every existing consumer is unaffected; the monitor populates it
    /// on cadence ONLY while the automation is enabled (`BatteryMonitor.readPerSourceModes`).
    var perSourceMode: EnergyModeReader.PerSourceEnergyMode = .unavailable
    /// #BOLT-TREND / #POPOVER-TREND: on AC and the charge % stepped up within `PackTrend`'s window. On
    /// macOS 27 this is the honest "power is going in" signal — `isCharging` and the sampled current stay
    /// stale-negative for ~98 % of a real climb. Computed once, in the monitor, so the menu-bar bolt and
    /// the popover can never disagree about it. The raw `isCharging` / current above stay RAW.
    var packRising: Bool = false
    /// While `packRising`: the net mAh/h the pack is gaining, from `PackInflowEstimator`. nil otherwise, and
    /// nil for the first ~2 gauge steps of a rise (not enough step-aligned history to quote a rate).
    var packInflowMilliamps: Int?

    /// First-launch placeholder (all nil / defaults).
    static let empty = BatterySnapshot()

    /// The charging answer for DISPLAY copy (Time / Limit / hero colour): a live rise on AC is a charge
    /// whatever the stale OS flag says; otherwise the flag, unread stays unread.
    var isChargingForDisplay: Bool? {
        powerSource == .ac && packRising ? true : isCharging
    }
}

extension BatterySnapshot {
    /// #EI-4. What the Temperature row actually knows. Before this, a missing temperature and a
    /// not-yet-read battery both rendered the same bare em-dash, so a capability this macOS does not
    /// publish was indistinguishable from a UI bug. Absence-by-design and failure-to-read must be
    /// distinguishable — and a permanently-missing capability should say so, once, honestly.
    enum TemperatureReading: Equatable {
        case celsius(Double)
        /// The `AppleSmartBattery` node read fine, but no rung of the ladder carried a temperature —
        /// this macOS does not publish one anywhere we can reach without root or SMC.
        case unsupportedByOS
        /// No successful diagnostics read yet (first launch, or the read failed).
        case notYetRead
        // #30 stage 10: `unavailableText` (the Details Temperature row's "Not reported on this macOS") is
        // gone with that row — the live-temperature surface is struck by #30 §14 R14 (no live temperature
        // on macOS 27). The reading itself stays: the heat alert evaluates it.
    }

    /// DERIVED, not stored — so the (separately owned) monitor needs no change to carry it. A successful
    /// `AppleSmartBattery` parse always yields at least one of these slow-moving figures; having them
    /// WITHOUT a temperature is positive evidence that this macOS simply does not report one.
    var temperatureReading: TemperatureReading {
        if let c = temperatureCelsius { return .celsius(c) }
        let diagnosticsDidRead = cycleCount != nil || voltageVolts != nil || designCapacity_mAh != nil
        return diagnosticsDidRead ? .unsupportedByOS : .notYetRead
    }
}

/// Keep the spec's unqualified `PowerSource` / `EnergyMode` names usable module-wide while the
/// enums live nested inside `BatterySnapshot` (SPEC WI-1.1).
typealias PowerSource = BatterySnapshot.PowerSource
typealias EnergyMode = BatterySnapshot.EnergyMode

/// IOPS live source result (charge/charging/AC/time-remaining).
struct LiveTelemetry {
    var chargePercent: Int?
    var isCharging: Bool?
    var powerSource: PowerSource
    var minutesToFull: Int?
    var minutesToEmpty: Int?
}

/// `AppleSmartBattery` diagnostics result (health/cycles/temp/voltage/amperage/capacities).
struct DiagnosticsTelemetry {
    var healthPercent: Double?
    var cycleCount: Int?
    var temperatureCelsius: Double?
    var voltageVolts: Double?
    var amperageMilliamps: Int?
    var fullChargeCapacity_mAh: Int?
    var designCapacity_mAh: Int?
    /// Raw mAh in the pack now — feeds `PackInflowEstimator` only (not published on the snapshot).
    var remainingCapacity_mAh: Int?
}

/// A short rolling mean of signed current, so the hero's Time projection reads steadily instead of
/// jumping with each raw sample. Resets on a charge↔discharge flip so the mean never straddles a sign
/// change (which would yield a bogus near-zero current). Pure + value-typed → unit-testable.
struct AmperageSmoother {
    private var samples: [Int] = []
    private let window: Int

    init(window: Int = 5) { self.window = window }

    /// Push a raw signed mA reading; returns the rolling mean (rounded).
    mutating func push(_ milliamps: Int) -> Int {
        // A change of regime — charge ↔ discharge, or into / out of an exact 0 — starts a fresh window. 0 is a
        // regime of its own: it is the limit hold. Averaged in, it walked the last charging current down one
        // poll at a time and the Time row said "Charging" beside "0 W · Holding at 90%" for ~3.5 min (live
        // capture 2026-09-14 18:29–18:33: 2450 → 1956 → 1468 → 980 → 490 → 0 at 0 mA reads).
        if let last = samples.last, last.signum() != milliamps.signum() {
            samples.removeAll(keepingCapacity: true)
        }
        samples.append(milliamps)
        if samples.count > window { samples.removeFirst(samples.count - window) }
        return Int((Double(samples.reduce(0, +)) / Double(samples.count)).rounded())
    }
}

/// Pure parsers: dict in → typed struct out. No IOKit calls, no `Bundle.main`, no side effects —
/// so they are unit-testable host-app-free. (SPEC WI-1.1; R-06.)
enum BatteryTelemetryParser {

    /// Parse an IOPS power-source description (read via the `kIOPS…Key` constants, not raw strings).
    static func parseLive(_ desc: [String: Any]) -> LiveTelemetry {
        let charge = desc[kIOPSCurrentCapacityKey] as? Int
        let isCharging = desc[kIOPSIsChargingKey] as? Bool

        let state = desc[kIOPSPowerSourceStateKey] as? String
        let powerSource: PowerSource
        switch state {
        case kIOPSACPowerValue:      powerSource = .ac
        case kIOPSBatteryPowerValue: powerSource = .battery
        default:                     powerSource = .unknown
        }

        // A time value of -1 means "still calculating" → nil.
        let toFull = nilIfCalculating(desc[kIOPSTimeToFullChargeKey] as? Int)
        let toEmpty = nilIfCalculating(desc[kIOPSTimeToEmptyKey] as? Int)

        return LiveTelemetry(chargePercent: charge, isCharging: isCharging, powerSource: powerSource,
                             minutesToFull: toFull, minutesToEmpty: toEmpty)
    }

    /// Parse an `AppleSmartBattery` property dict. (decision #13 health + #14 units; R-06.)
    static func parseDiagnostics(_ props: [String: Any]) -> DiagnosticsTelemetry {
        // macOS 27 relocated the raw mAh capacities out of the top-level keys (`AppleRawMaxCapacity`,
        // `DesignCapacity` are absent there now) into a nested `BatteryData` dict. Prefer the pre-27
        // top-level keys, falling back to `BatteryData` so both OS layouts read correctly.
        let batteryData = props["BatteryData"] as? [String: Any]
        let fcc = intValue(props["AppleRawMaxCapacity"]) ?? intValue(batteryData?["FullChargeCapacity"])
        let design = intValue(props["DesignCapacity"]) ?? intValue(batteryData?["DesignCapacity"])
        let remaining = intValue(props["AppleRawCurrentCapacity"]) ?? intValue(batteryData?["RemainingCapacity"])

        // Percentage-vs-mAh guard (R-06 "2% health" bug): on Apple Silicon `MaxCapacity` is a 0–100 %
        // value, NOT mAh. Health is computed ONLY from the raw-mAh capacities, never from `MaxCapacity`.
        var health: Double?
        if let fcc, let design, design > 0 {
            health = Double(fcc) / Double(design) * 100.0   // raw; the model smooths (WI-1.3)
        }

        let cycles = intValue(props["CycleCount"])
        let temp = temperatureCentiCelsius(props).map { $0 / 100.0 }   // ladder below; centi-°C → °C
        let volts = doubleValue(props["Voltage"]).map { $0 / 1000.0 }     // mV → V
        let amps = signedMilliamps(props["Amperage"] ?? props["InstantAmperage"])

        return DiagnosticsTelemetry(healthPercent: health, cycleCount: cycles,
                                    temperatureCelsius: temp, voltageVolts: volts,
                                    amperageMilliamps: amps, fullChargeCapacity_mAh: fcc,
                                    designCapacity_mAh: design, remainingCapacity_mAh: remaining)
    }

    // MARK: - temperature ladder (macOS 26 → 27 drift)

    /// The synthetic key under which `LiveBatteryReader` folds the CHILD `AppleSmartBatteryPack` node's
    /// properties into the `AppleSmartBattery` dict. Deliberately NOT an Apple key name (the `__` prefix
    /// marks it as ours) so nothing mistakes it for something the registry published.
    static let packPropertiesKey = "__batteryApp_packProperties"

    /// Pure: the pack temperature in CENTI-Celsius, from whichever layout this macOS uses. First rung wins:
    ///  1. `Temperature` at the `AppleSmartBattery` top level — macOS ≤ 26 (SPEC EI-4, on-device 2026-06-19).
    ///  2. `BatteryData.Temperature` on that same node — the exact relocation the capacities took on 27.
    ///  3. the CHILD `AppleSmartBatteryPack` node's `BatteryData.Temperature` (else `VirtualTemperature`) —
    ///     where macOS 27.0 actually publishes the gas gauge (verified on-device: 3979 → 39.79 °C, and the
    ///     same dict's `LifetimeData` Min/MaximumTemperature 9/46 °C brackets it).
    /// Rung 3 arrives only when the reader supplied the child node; the parser stays pure and dict-driven.
    /// Values outside −40…120 °C are gauge placeholders (0xFFFF and friends), not readings → nil.
    static func temperatureCentiCelsius(_ props: [String: Any]) -> Double? {
        let batteryData = props["BatteryData"] as? [String: Any]
        let packData = (props[packPropertiesKey] as? [String: Any])?["BatteryData"] as? [String: Any]
        let raw = doubleValue(props["Temperature"])
            ?? doubleValue(batteryData?["Temperature"])
            ?? doubleValue(packData?["Temperature"])
            ?? doubleValue(packData?["VirtualTemperature"])
        guard let raw, raw >= -4000, raw <= 12000 else { return nil }
        return raw
    }

    // MARK: - helpers

    private static func nilIfCalculating(_ minutes: Int?) -> Int? {
        guard let minutes, minutes != -1 else { return nil }
        return minutes
    }

    private static func intValue(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }
    private static func doubleValue(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    /// Interpret a raw amperage as signed two's-complement mA (negative = discharging).
    /// `AppleSmartBattery` reports a small signed value; if it arrives as an unsigned wider than
    /// `Int32.max`, fold the low 32 bits as `Int32` then widen. (SPEC WI-1.1.)
    private static func signedMilliamps(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber else { return nil }
        let raw = n.int64Value
        if raw > Int64(Int32.max) || raw < Int64(Int32.min) {
            return Int(Int32(truncatingIfNeeded: raw))
        }
        return Int(raw)
    }
}
