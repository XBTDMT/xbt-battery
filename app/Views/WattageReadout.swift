import Foundation

/// #20 (4.E sec 3): the live wattage readout — pure and host-app-free so it unit-tests like the
/// glyph decision layer. watts = (Voltage_mV × InstantAmperage_mA) / 1e6 = V × mA / 1000, signed.
enum WattageReadout {
    /// "Charging — 64.2 W" (into the pack) / "Discharging — 12.3 W" (out) / "0 W" at holds, rounded
    /// 0.1 W. Instantaneous truth — NO smoothing (flicker reassessed on-device; see hand-back). nil
    /// if either input is missing. Adapter max ("of 96 W") deliberately skipped (not cheaply
    /// available without a new AdapterDetails parse — recorded in the hand-back).
    static func label(voltageVolts: Double?, amperageMilliamps: Int?, adapterWatts: Int? = nil) -> String? {
        // Same non-finite guard as `compact` (ruled: an identical known defect doesn't get to survive on a
        // scope line). NaN volts fails both the `== 0` and `> 0` tests below and would render
        // "Discharging — nan W". Only the voltage needs it — `mA` is an Int and cannot be non-finite.
        guard let v = voltageVolts, let mA = amperageMilliamps, v.isFinite else { return nil }
        let watts = v * Double(mA) / 1000.0
        let rounded = (watts * 10).rounded() / 10        // 0.1 W
        if rounded == 0 { return "0 W" }                 // holds / idle
        let direction = rounded > 0 ? "Charging" : "Discharging"
        let base = "\(direction) — \(String(format: "%.1f", abs(rounded))) W"
        // #EI-3: the adapter ceiling appends ONLY while charging (positive flow) and only when known —
        // "Charging — 64.2 W of 75 W". Discharging / 0 W / nil-adapter are unchanged.
        if rounded > 0, let adapterWatts {
            return base + " of \(adapterWatts) W"
        }
        return base
    }

    /// The compact hero stat-row form: a SIGNED wattage — "+64.3 W" charging / "−12.3 W" discharging /
    /// "0 W" at a hold — so a single glance carries both magnitude and direction. Same signed 0.1 W math
    /// as `label`, without the direction word; nil if either input is missing (the row renders "—").
    static func compact(voltageVolts: Double?, amperageMilliamps: Int?) -> String? {
        // B-arc seam 1 (recorded in the 5749e0d review): a non-finite voltage from a bad telemetry parse
        // fails BOTH the `== 0` and `> 0` tests below and would print "−nan W". Treat it as missing so the
        // row renders "—". Only the voltage needs the check — `mA` is an Int and cannot be non-finite.
        guard let v = voltageVolts, let mA = amperageMilliamps, v.isFinite else { return nil }
        let watts = v * Double(mA) / 1000.0
        let rounded = (watts * 10).rounded() / 10        // 0.1 W
        if rounded == 0 { return "0 W" }                 // holds / idle — no direction
        let sign = rounded > 0 ? "+" : "−"               // + into the pack / − out
        return "\(sign)\(String(format: "%.1f", abs(rounded))) W"
    }
}
