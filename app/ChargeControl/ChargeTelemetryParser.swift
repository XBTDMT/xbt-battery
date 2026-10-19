import Foundation

/// WI-N2: the charge-control parse of a raw `AppleSmartBattery` property dict — same
/// pure-function, host-app-free pattern as Phase 1's `BatteryTelemetryParser` (dict in →
/// typed struct out; no IOKit calls; the caller supplies the monotonic timestamp).
///
/// macOS 27 LAYOUT: `AppleRawCurrentCapacity` is one of the gas-gauge keys the OS RELOCATED off
/// the `AppleSmartBattery` top level (the same move that silently emptied Health and FCC — see
/// `knowledge/03-REF-applesmartbattery-layout.md`). It is resolved through the SAME three-rung
/// ladder those readers use, over the pack dict `LiveBatteryReader` already folds in. See
/// `rawCurrentCapacity_mAh`.
enum ChargeTelemetryParser {

    static func parse(_ props: [String: Any], timestamp: TimeInterval) -> ChargeTelemetrySnapshot {
        let chargerData = props["ChargerData"] as? [String: Any]
        return ChargeTelemetrySnapshot(
            timestamp: timestamp,
            socPercent: intValue(props["CurrentCapacity"]),
            rawCapacity_mAh: rawCurrentCapacity_mAh(props),
            instantAmperage_mA: signedMilliamps(props["InstantAmperage"]),
            notChargingReason: uint32Value(chargerData?["NotChargingReason"]),
            isChargingFlag: props["IsCharging"] as? Bool,
            externalConnected: props["ExternalConnected"] as? Bool,
            // `ChargerData.ChargingCurrent` — top-level on pre-27. On macOS 27.0 the top-level
            // `ChargerData` carries only six keys and this is not one of them: it lives in the
            // SIBLING `AppleChargerData` node, which the diagnostics reader does not walk, so it
            // is nil here. Left nil DELIBERATELY: no code reads `chargingCurrent_mA` (it is
            // display/fingerprint-only and the fingerprint never adopted it), and the honest fix
            // would be a second registry walk in `LiveBatteryReader` for a field nothing consumes.
            // It is also a discredited signal — "armed, not flowing" (run-02 12:51:39: 3692 mA
            // armed at +31 mA of real flow). Do NOT resurrect it as evidence.
            chargingCurrent_mA: intValue(chargerData?["ChargingCurrent"]))
    }

    // MARK: - the macOS 27 relocation ladder

    /// Plausibility band for a raw mAh capacity, the same discipline (and the same numbers) as
    /// `BatteryLifetimeParser.Band.capacity_mAh`: an unlatched gauge publishes saturated
    /// placeholders (0xFFFF and friends), and one of those must be treated as "not published at
    /// this rung" so the ladder moves on — never as a 65 Ah reading that would then anchor
    /// `BehaviorConfirm.baselineRAW` and make every RAW comparison meaningless.
    private static let rawCapacityBand_mAh = 1...50_000

    /// `AppleRawCurrentCapacity` (mAh) resolved across every layout this app has seen, newest
    /// relocation LAST — the idiom `BatteryTelemetryParser.parseDiagnostics` and
    /// `BatteryLifetimeParser.parse` already implement for the other relocated capacities:
    ///
    ///   1. `AppleSmartBattery` TOP LEVEL — macOS ≤ 26.
    ///   2. that node's own nested `BatteryData`.
    ///   3. the CHILD `AppleSmartBatteryPack` node's `BatteryData` — where macOS 27.0 actually
    ///      publishes it (verified live on this machine 2026-09-08: 1431 mAh at 27 %). Rung 3
    ///      arrives only because `LiveBatteryReader.readDiagnosticsProperties` folds the pack
    ///      child in under `BatteryTelemetryParser.packPropertiesKey` — ONE registry visit, and
    ///      this parser stays pure dict-in / struct-out.
    ///   4. LOWER RUNG, substitute name: `BatteryData.RemainingCapacity`, which publishes the same
    ///      figure under a different name (measured EQUAL on this machine, 1431 == 1431). Ranked
    ///      below every own-name rung per 03-REF rule 3 — kept for a machine that publishes it and
    ///      no pack.
    ///
    /// THREE-STATE: nil out of here means the figure resolved at NO KNOWN RUNG — drift, not a
    /// legitimate zero and not "unchanged". `BehaviorConfirm` must treat that as evidence it did
    /// not get, never as evidence that passed. It is deliberately NOT substituted from a different
    /// quantity (`AppleRawMaxCapacity` is the FULL capacity; `MaxCapacity` is a 0–100 % value on
    /// Apple Silicon — the R-06 trap).
    private static func rawCurrentCapacity_mAh(_ props: [String: Any]) -> Int? {
        let batteryData = props["BatteryData"] as? [String: Any]
        let packData = (props[BatteryTelemetryParser.packPropertiesKey] as? [String: Any])?["BatteryData"] as? [String: Any]
        return banded(props["AppleRawCurrentCapacity"])
            ?? banded(batteryData?["AppleRawCurrentCapacity"])
            ?? banded(packData?["AppleRawCurrentCapacity"])
            ?? banded(batteryData?["RemainingCapacity"])
            ?? banded(packData?["RemainingCapacity"])
    }

    private static func banded(_ any: Any?) -> Int? {
        guard let value = intValue(any), rawCapacityBand_mAh.contains(value) else { return nil }
        return value
    }

    // MARK: - helpers (same numeric discipline as Phase 1)

    private static func intValue(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }

    /// NCR arrives as a plain non-negative integer; fold defensively through UInt32 bit patterns
    /// (registry numerics can surface as wider types).
    private static func uint32Value(_ any: Any?) -> UInt32? {
        guard let n = any as? NSNumber else { return nil }
        return UInt32(truncatingIfNeeded: n.int64Value)
    }

    /// Signed two's-complement mA — identical fold to Phase 1's parser: `InstantAmperage` is a
    /// small signed value that can surface as a huge unsigned 64-bit (observed live:
    /// 18446744073709546403 == −5213 mA, run-02 raw log 12:55:26).
    private static func signedMilliamps(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber else { return nil }
        let raw = n.int64Value
        if raw > Int64(Int32.max) || raw < Int64(Int32.min) {
            return Int(Int32(truncatingIfNeeded: raw))
        }
        return Int(raw)
    }
}
