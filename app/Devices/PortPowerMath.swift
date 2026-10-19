import Foundation

/// spec 31 §2.1 (T8, G-6) — the on-power line. Every claim is backed; anything else is NO line.
enum OnPowerBand: Equatable, Sendable {
    /// Clear headroom and the pack actually charging: "doesn't slow your Mac's charging".
    case headroom
    /// Saturated and the pack gaining: "your Mac charges ≈ N W slower".
    case slower(watts: Int)
    /// Saturated and the pack losing: "≈ N W is coming from your battery" (N capped by −P).
    case fromBattery(watts: Int)
    /// No line: the ±0.5 W dead band (a limit hold / full), unsaturated and losing, or any input unread.
    case none
}

/// spec 31 §2.1 (G-6) — the band on the Mac's real input ceiling, with hysteresis held ACROSS reads:
/// enter "saturated" at `SystemPowerIn` ≥ 92 % of the ceiling, leave at ≤ 85 %. A different ceiling
/// (another charger) re-evaluates fresh; the port source resets the whole state when the power source
/// changes. P is the ACCUMULATOR-AVERAGED pack power (never the single frame).
struct OnPowerBandState: Equatable, Sendable {
    static let enterSaturated = 0.92
    static let leaveSaturated = 0.85
    static let deadBand_mW = 500.0

    var saturated: Bool = false
    /// The ceiling the hysteresis was last evaluated on.
    private(set) var lastCeiling_mW: Int?

    mutating func update(systemPowerIn_mW: Int?, ceiling_mW: Int?, packPower_mW: Double?,
                         portWatts: Double) -> OnPowerBand {
        // SystemPowerIn ≤ 0 on AC is a transient (§1.2) — unread: no claim AND no change to the hold.
        guard let systemIn = systemPowerIn_mW, systemIn > 0,
              let ceiling = ceiling_mW, ceiling > 0 else { return .none }
        let ratio = Double(systemIn) / Double(ceiling)
        if ceiling != lastCeiling_mW {
            lastCeiling_mW = ceiling
            saturated = ratio >= Self.enterSaturated
        } else if saturated {
            if ratio <= Self.leaveSaturated { saturated = false }
        } else if ratio >= Self.enterSaturated {
            saturated = true
        }
        guard let p = packPower_mW, p.isFinite, portWatts.isFinite, portWatts > 0,
              portWatts <= PortPowerMath.maxPlausibleWatts else { return .none }
        if p > Self.deadBand_mW {
            guard saturated else { return .headroom }
            let n = Int(portWatts.rounded())
            return n > 0 ? .slower(watts: n) : .none
        }
        if p < -Self.deadBand_mW, saturated {
            let n = Int(min(portWatts, -p / 1000).rounded())
            return n > 0 ? .fromBattery(watts: n) : .none
        }
        return .none
    }
}

/// spec 31 §2.1 / D6 — a port counts as DRAWING from 0.5 W and stops below 0.3 W, per `PortIndex`,
/// held across reads. `retain(only:)` forgets ports absent on a successful read.
struct PortPowerHysteresis: Equatable, Sendable {
    static let on_mW = 500
    static let off_mW = 300

    private var drawing: Set<Int> = []

    mutating func isDrawing(portIndex: Int, filteredPower_mW: Int) -> Bool {
        let threshold = drawing.contains(portIndex) ? Self.off_mW : Self.on_mW
        let now = filteredPower_mW >= threshold
        if now { drawing.insert(portIndex) } else { drawing.remove(portIndex) }
        return now
    }

    mutating func retain(only portIndices: Set<Int>) {
        drawing.formIntersection(portIndices)
    }
}

/// spec 31 §2.1 — the on-battery line: "≈ X% of your battery per hour — T left with them, ≈ T′ without".
/// T and T′ are whole minutes (so frame jitter yields an EQUAL value — §3.7); the "> 10 h" cap is the
/// formatter's (stage 4).
struct BatteryCostLine: Equatable, Sendable {
    let percentPerHour: Int
    let timeLeft: TimeInterval
    let timeLeftWithout: TimeInterval?
}

enum BatteryCost {
    /// Nominal volts per bank: 72.4 Wh ÷ 6.249 Ah ÷ 3 banks (§2.1). `CellVoltage` is not used.
    static let nominalCellVolts = 3.86
    /// T′ shows only when what is left after the ports is ≥ 25 % of the draw.
    static let withoutGuardFraction = 0.25

    /// The pack's volts: banks × nominal. The ONE place the multiplication order is fixed.
    static func packVolts(bankCount: Int) -> Double { Double(bankCount) * nominalCellVolts }

    /// Full-charge Wh = mAh × volts ÷ 1000; nil unless both are read and positive. Shared by the cost line and
    /// the plug-in notice so the same watts always round to the same X (S5.3 fix: two operation orders split
    /// an exact .5 tie by 1 %).
    static func packWh(fullCharge_mAh: Int?, bankCount: Int?) -> Double? {
        guard let full = fullCharge_mAh, full > 0, let banks = bankCount, banks > 0 else { return nil }
        return Double(full) * packVolts(bankCount: banks) / 1000
    }

    /// X, whole percent of the pack per hour: port W ÷ pack Wh × 100, rounded. Non-finite → nil.
    static func percentPerHour(portWatts: Double, packWh: Double) -> Int? {
        let percent = (portWatts / packWh * 100).rounded()
        guard percent.isFinite, percent < Double(Int.max) else { return nil }
        return Int(percent)
    }

    /// nil unless the pack is LOSING (P < 0), every input is read, and the frame is consistent: on battery the
    /// ports' power comes out of the pack, so a pack draw BELOW the ports' draw (mismatched sample windows) is
    /// no line; equal is allowed (T′ is then hidden by the 25 % guard). X = port W ÷ pack Wh × 100;
    /// T = remaining Wh ÷ draw W; T′ = remaining Wh ÷ (draw W − port W). A T that overflows to infinity is no
    /// line; a T′ that does is nil.
    static func line(portWatts: Double, packPower_mW: Double?, remaining_mAh: Int?,
                     fullCharge_mAh: Int?, bankCount: Int?) -> BatteryCostLine? {
        guard let p = packPower_mW, p.isFinite, p < 0,
              let remaining = remaining_mAh, remaining >= 0,
              let packWh = packWh(fullCharge_mAh: fullCharge_mAh, bankCount: bankCount),
              let banks = bankCount,
              portWatts.isFinite, portWatts > 0, portWatts <= PortPowerMath.maxPlausibleWatts else { return nil }
        let volts = packVolts(bankCount: banks)
        let remainingWh = Double(remaining) * volts / 1000
        let drawW = -p / 1000
        guard drawW >= portWatts else { return nil }
        let hoursLeft = remainingWh / drawW
        let secondsLeft = hoursLeft * 3600
        guard let percent = percentPerHour(portWatts: portWatts, packWh: packWh),
              hoursLeft.isFinite, secondsLeft.isFinite else { return nil }
        let otherW = drawW - portWatts
        var without: TimeInterval?
        if otherW >= withoutGuardFraction * drawW {
            let secondsWithout = remainingWh / otherW * 3600
            if secondsWithout.isFinite { without = wholeMinutes(secondsWithout) }
        }
        return BatteryCostLine(percentPerHour: percent,
                               timeLeft: wholeMinutes(secondsLeft),
                               timeLeftWithout: without)
    }

    private static func wholeMinutes(_ seconds: TimeInterval) -> TimeInterval {
        (seconds / 60).rounded() * 60
    }
}

/// Shared rules for the port source.
enum PortPowerMath {
    /// Anything above this is registry garbage, not a device (no claim is made on it).
    static let maxPlausibleWatts = 10_000.0

    /// spec 31 §1.2 / §3.3 / §5.5 — the input power, or nil when it cannot be trusted. nil when the telemetry
    /// carries no `SystemPowerIn`; nil when `externalConnected` is nil (the AC state is unread, so no on-power
    /// line whatever the value); nil when `externalConnected == true` and the value is exactly 0 (a transient
    /// seen ~40 s after a replug with −52 W from the battery). On battery (`false`) 0 is simply true.
    /// `OnPowerBandState` also refuses any value ≤ 0 as defence in depth. `externalConnected` is the same
    /// read's flag.
    static func systemPowerIn(_ telemetry: PowerTelemetry?, externalConnected: Bool?) -> Int? {
        guard let value = telemetry?.systemPowerIn_mW, let external = externalConnected else { return nil }
        if external && value == 0 { return nil }
        return value
    }

    /// Sum of `FilteredPower` in watts, in Double so garbage cannot overflow an Int sum.
    static func portWatts(_ ports: [PortPower]) -> Double {
        ports.reduce(0.0) { $0 + Double($1.filteredPower_mW) } / 1000
    }
}
