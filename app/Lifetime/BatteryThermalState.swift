import Foundation

/// #EI-4 (SPEC 02-SPEC-ei4-heat-awareness.md). A PURE thermal-state classifier over the battery PACK
/// temperature the app already parses (Temperature centi-Celsius → Celsius at BatterySnapshot). This
/// is read-only awareness — no control, no auto-stop (the discharge/auto-stop family was cut,
/// research-10). Parallel to BatteryLifetime's pure logic: fully unit-testable, no I/O.
enum BatteryThermalState: Equatable {
    case unknown, normal, warm, hot

    /// Pack-Celsius thresholds (conservative, TUNABLE single constants). A pack runs above ambient
    /// under load, so 30–36 C is normal even under light load (avoid crying wolf); 37 C is the upper
    /// edge of normal; 42 C and above is genuinely working hard (heavy load / fast charge / hot spot).
    static let warmThreshold = 37.0   // pack Celsius, tunable
    static let hotThreshold  = 42.0   // pack Celsius, tunable

    /// nil → `.unknown`; >= hotThreshold → `.hot`; >= warmThreshold → `.warm`; else `.normal`
    /// (including below 0 — there is no lower/cold flag in v1).
    static func from(celsius: Double?) -> BatteryThermalState {
        guard let c = celsius else { return .unknown }
        if c >= hotThreshold { return .hot }
        if c >= warmThreshold { return .warm }
        return .normal
    }

    /// The same classification over the richer reading. BOTH absence cases stay `.unknown` (no badge):
    /// the badge must never invent a judgment, and the row itself now says WHY there is no number —
    /// "Not reported on this macOS" for a capability this OS lacks, "—" for not-yet-read.
    static func from(reading: BatterySnapshot.TemperatureReading) -> BatteryThermalState {
        switch reading {
        case .celsius(let c):                  from(celsius: c)
        case .unsupportedByOS, .notYetRead:    .unknown
        }
    }
}
