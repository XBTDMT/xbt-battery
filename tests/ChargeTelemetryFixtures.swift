import Foundation

/// WI-N2 fixtures: REAL telemetry vectors from the on-device characterization, cited row-by-row
/// from `validation/phase2/raw/` (run-02 = uncaffeinated morning log, run-03 = corrected
/// caffeinated log) and the session-recorded live probes. These are the values the engine must
/// classify correctly — including the lying armed-flags rows and the 0x01002080 transient.
///
/// Snapshot builders take `t:` so tests control the monotonic timeline; the cited wall-clock is
/// provenance only.
enum ChargeFixtures {

    // MARK: - snapshot fixtures (state machine / confirm inputs)

    /// run-03 15:55:06 — genuine charge-limit hold at the cap. IsCharging honestly false here.
    static func limitHold80(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 80, rawCapacity_mAh: 4206, instantAmperage_mA: 0,
              notChargingReason: 0x0100_0000, isChargingFlag: false, externalConnected: true,
              chargingCurrent_mA: 0)
    }

    /// Session probe 16:02:50 (raw/README.md "Session probe rows" — NOT in the run logs) —
    /// pure limit hold at 84 with a STALE disengage-dip amperage (−1534).
    /// Precedence gold: the NCR limit hold must beat the negative flow reading.
    static func limitHold84StaleDip(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 84, rawCapacity_mAh: 4477, instantAmperage_mA: -1534,
              notChargingReason: 0x0100_0000, isChargingFlag: false, externalConnected: true,
              chargingCurrent_mA: 0)
    }

    /// run-03 15:55:36 — real charging 30 s after the limit-raise (the resume row).
    static func charging80(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 80, rawCapacity_mAh: 4223, instantAmperage_mA: 2496,
              notChargingReason: 0, isChargingFlag: true, externalConnected: true,
              chargingCurrent_mA: 3496)
    }

    /// run-03 15:57:38 — mid-climb charging row.
    static func charging82(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 82, rawCapacity_mAh: 4314, instantAmperage_mA: 2929,
              notChargingReason: 0, isChargingFlag: true, externalConnected: true,
              chargingCurrent_mA: 2923)
    }

    /// run-03 16:00:50 — the stop TRANSIENT: composite NCR 0x01002080 with the −1599 mA
    /// disengage dip, 10 s after the limit was dropped below SoC.
    static func stopTransient84(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 84, rawCapacity_mAh: 4425, instantAmperage_mA: -1599,
              notChargingReason: 0x0100_2080, isChargingFlag: false, externalConnected: true,
              chargingCurrent_mA: 0)
    }

    /// run-03 16:01:10 — transient still composite one sample later (decays to pure 0x01000000).
    static func stopDecaying84(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 84, rawCapacity_mAh: 4425, instantAmperage_mA: -1051,
              notChargingReason: 0x0100_2080, isChargingFlag: false, externalConnected: true,
              chargingCurrent_mA: 0)
    }

    /// run-02 12:51:39 — THE LYING ARMED FLAGS: IsCharging=true, ChargingCurrent=3692 armed,
    /// but zero flow (+31 mA) at 79% under an 80 limit, NCR=0. The ambiguous/OBC fingerprint.
    static func ambiguousHold79(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 79, rawCapacity_mAh: 4075, instantAmperage_mA: 31,
              notChargingReason: 0, isChargingFlag: true, externalConnected: true,
              chargingCurrent_mA: 3692)
    }

    /// run-02 12:51:49 — ON-AC discharge under CPU load (load > adapter): −3790 mA while
    /// plugged, IsCharging still (lying) true. Flow must classify this as discharging.
    static func dischargingOnACUnderLoad(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 79, rawCapacity_mAh: 4073, instantAmperage_mA: -3790,
              notChargingReason: 0, isChargingFlag: true, externalConnected: true,
              chargingCurrent_mA: 3661)
    }

    /// run-02 12:55:26 — idle/sleep inhibit right after the load kill: NCR=0x80, −5213 mA tail.
    static func idleInhibitPostLoad(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 74, rawCapacity_mAh: 3788, instantAmperage_mA: -5213,
              notChargingReason: 0x80, isChargingFlag: false, externalConnected: true,
              chargingCurrent_mA: 0)
    }

    /// run-02 13:20:43 — quiet idle inhibit (the 25-min no-charge nap window's last row).
    static func idleInhibitQuiet(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 70, rawCapacity_mAh: 3559, instantAmperage_mA: 0,
              notChargingReason: 0x80, isChargingFlag: false, externalConnected: true,
              chargingCurrent_mA: 0)
    }

    /// Session probe 20:04:25 (raw/README.md "Session probe rows" — NOT in the run logs) —
    /// UNPLUGGED discharge, and NCR reads 0x80 while on battery.
    /// Drives the ext-gate rule: hold taxons require ExternalConnected=true.
    static func dischargingOnBattery(t: TimeInterval) -> ChargeTelemetrySnapshot {
        .init(timestamp: t, socPercent: 61, rawCapacity_mAh: 3139, instantAmperage_mA: -1150,
              notChargingReason: 0x80, isChargingFlag: false, externalConnected: false,
              chargingCurrent_mA: nil)
    }

    // MARK: - registry-dict fixtures (parser inputs, ioreg-shaped)

    /// run-02 12:55:26 row in registry shape. `InstantAmperage` carries the REAL 64-bit-folded
    /// negative observed live: 18446744073709546403 == −5213 mA.
    /// (Functions, not stored statics: `[String: Any]` is non-Sendable under Swift 6.)
    static func registryIdleInhibitDict() -> [String: Any] { [
        "CurrentCapacity": 74,
        "AppleRawCurrentCapacity": 3788,
        "InstantAmperage": NSNumber(value: 18_446_744_073_709_546_403 as UInt64),
        "IsCharging": false,
        "ExternalConnected": true,
        "ChargerData": [
            "NotChargingReason": 0x80,
            "ChargingCurrent": 0,
            "ChargerPower": 0, "ChargerIBUS": 0, "ChargerVBUS": 0,   // dead fields, present in dumps
        ] as [String: Any],
    ] }

    /// run-03 15:55:36 resume row in registry shape (positive small amperage path).
    static func registryChargingDict() -> [String: Any] { [
        "CurrentCapacity": 80,
        "AppleRawCurrentCapacity": 4223,
        "InstantAmperage": 2496,
        "IsCharging": true,
        "ExternalConnected": true,
        "ChargerData": [
            "NotChargingReason": 0,
            "ChargingCurrent": 3496,
        ] as [String: Any],
    ] }

    // MARK: - macOS 27 relocated-layout registry fixtures (03-REF-applesmartbattery-layout.md)

    /// THE macOS 27.0 LAYOUT, transcribed from a live `ioreg` dump of THIS machine
    /// (M4 Max, macOS 27.0, 2026-09-08 — on battery, 27 %, discharging −2683 mA). Not invented.
    ///
    /// What changed vs. the pre-27 fixtures above, and why this fixture exists:
    ///  * `AppleRawCurrentCapacity` is **absent from the top level** and absent from the NODE's own
    ///    `BatteryData` — it lives only in the CHILD `AppleSmartBatteryPack` node's `BatteryData`
    ///    (folded in by `LiveBatteryReader` under `BatteryTelemetryParser.packPropertiesKey`).
    ///    The node's `BatteryData.RemainingCapacity` publishes the SAME figure (1431) under a
    ///    different name — the substitute rung.
    ///  * the top-level `ChargerData` carries only SIX keys and `ChargingCurrent` is not one of
    ///    them: that key lives in the SIBLING `AppleChargerData` node, which the reader does not
    ///    walk. So `chargingCurrent_mA` is structurally nil on this OS and this fixture says so.
    static func registryMacOS27NestedDict() -> [String: Any] { [
        "CurrentCapacity": 27,
        "InstantAmperage": NSNumber(value: 18_446_744_073_709_548_933 as UInt64),   // == −2683 mA
        "IsCharging": false,
        "ExternalConnected": false,
        // Verbatim: the six keys the top-level ChargerData actually has on 27.0.
        "ChargerData": [
            "NotChargingReason": 128, "SlowChargingReason": 0, "PMUConfigured": 0,
            "PMUConfiguration": 0, "TimeChargingThermallyLimited": 0, "IsCharging": 0,
        ] as [String: Any],
        // RUNG 2 — the node's own nested dict. Note: NO `AppleRawCurrentCapacity` here.
        "BatteryData": [
            "FullChargeCapacity": 5399, "NominalChargeCapacity": 5551, "FullyCharged": 0,
            "AvgTimeToEmpty": 27, "RemainingCapacity": 1431, "AbsoluteCapacity": 0,
            "MaxCapacity": 100, "DesignCapacity": 6249, "CurrentCapacity": 27,
            "TrueRemainingCapacity": 0,
        ] as [String: Any],
        // RUNG 3 — the pack child, as the live reader folds it in.
        BatteryTelemetryParser.packPropertiesKey: [
            "BatteryData": [
                "AppleRawCurrentCapacity": 1431, "AppleRawMaxCapacity": 5399,
                "CurrentCapacity": 27, "DesignCapacity": 6249, "MaxCapacity": 100,
                "Temperature": 3400, "NominalChargeCapacity": 5551,
            ] as [String: Any],
        ] as [String: Any],
    ] }

    /// Same OS-27 shape but with NO pack child (a machine that publishes the node's `BatteryData`
    /// and nothing below it) — exercises the substitute rung `BatteryData.RemainingCapacity`.
    static func registryNodeBatteryDataOnlyDict() -> [String: Any] { [
        "CurrentCapacity": 27,
        "InstantAmperage": 100,
        "ExternalConnected": true,
        "BatteryData": ["RemainingCapacity": 1431, "FullChargeCapacity": 5399] as [String: Any],
    ] }

    /// The gauge published a SATURATED PLACEHOLDER at the top rung (0xFFFF), with the real figure
    /// one rung down. A placeholder must be treated as "not published here" so the ladder moves on
    /// — a 65535 must never become a 65 Ah reading (03-REF rule 4).
    static func registrySaturatedTopRungDict() -> [String: Any] { [
        "CurrentCapacity": 27,
        "AppleRawCurrentCapacity": 65535,
        "ExternalConnected": true,
        BatteryTelemetryParser.packPropertiesKey: [
            "BatteryData": ["AppleRawCurrentCapacity": 1431] as [String: Any],
        ] as [String: Any],
    ] }

    /// The gauge publishes the raw capacity at NO known rung — the three-state case that must stay
    /// distinguishable from a real reading (it becomes nil, and BehaviorConfirm must SAY it had
    /// less evidence rather than treat the missing half of the truth pair as corroboration).
    static func registryRawCapacityUnresolvableDict() -> [String: Any] { [
        "CurrentCapacity": 27,
        "InstantAmperage": 100,
        "ExternalConnected": true,
        "BatteryData": ["FullChargeCapacity": 5399] as [String: Any],
        BatteryTelemetryParser.packPropertiesKey: [
            "BatteryData": ["AppleRawMaxCapacity": 5399] as [String: Any],
        ] as [String: Any],
    ] }
}
