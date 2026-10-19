import Foundation
import Combine
import IOKit
import os

/// #EI-2 (SPEC 02-SPEC-ei2-lifetime-analyzer.md). The slow-moving battery LONGEVITY figures, read from
/// the AppleSmartBattery IORegistry node. READ-ONLY — we never write these keys. v1 surfaces the three
/// solid figures (cycle count, maximum capacity %, condition); age + LifetimeData sub-stats are deferred.
///
/// LAYOUT DRIFT (audit finding B0, then B0b). On macOS 27 only `CycleCount` is still published at the TOP
/// level of the node. Some capacities moved one level down into the node's own nested `BatteryData` dict —
/// and the REST of the gas gauge moved off this node entirely, onto its CHILD `AppleSmartBatteryPack`
/// node's nested `BatteryData` (`AppleRawMaxCapacity`, `PermanentFailureStatus`, `LifetimeData`,
/// `DailyMin/MaxSoc`, `Temperature`). See knowledge/03-REF-applesmartbattery-layout.md for the full table.
/// So every figure except the cycle count is OPTIONAL here, and each resolves through a THREE-rung ladder
/// (top level → node `BatteryData` → pack `BatteryData`). A figure the OS stopped publishing at every rung
/// degrades to nil — its row/chip simply doesn't render — instead of nil-ing the whole read and silently
/// deleting the Battery-health card (exactly how B0 presented). `unresolvedKeys` names what could not be
/// resolved at ANY known layout, so the next relocation surfaces as something legible rather than a card
/// that quietly stops existing.
struct BatteryLifetime: Equatable {
    let cycleCount: Int
    /// `DesignCapacity` (macOS 27: node or pack `BatteryData.DesignCapacity`). nil = published at no
    /// layout we know.
    let designCapacity_mAh: Int?
    /// `NominalChargeCapacity` (macOS 27: node or pack `BatteryData.NominalChargeCapacity`) — the v1
    /// "maximum capacity" numerator (Apple's historical basis).
    let nominalCapacity_mAh: Int?
    /// `AppleRawMaxCapacity` — the RAW full-charge mAh that decision #13 makes health's numerator. Still
    /// published under its own name on macOS 27, on the PACK child (`pack.BatteryData.AppleRawMaxCapacity`);
    /// the node's `BatteryData.FullChargeCapacity` is the lower rung (measured equal on this machine).
    let rawMaxCapacity_mAh: Int?
    /// `PermanentFailureStatus` (macOS 27: `pack.BatteryData.PermanentFailureStatus`, reading 0). nil only
    /// when it resolves at NO rung — then `condition` reads "Unknown" rather than a fabricated 0
    /// ("Normal") we never actually read.
    let permanentFailureStatus: Int?

    /// #EI-2 v2 (SPEC 02-SPEC-ei2v2-lifetime-substats.md): OPTIONAL LifetimeData / BatteryData sub-stats,
    /// one level deeper. On macOS 27 that dict lives on the PACK child (`pack.BatteryData.LifetimeData`);
    /// pre-27 it was the node's own. nil on a machine carrying neither, so v1 still renders.
    /// lifetimeMin/MaxTempC are whole Celsius; lifetimeAvgTempDeciC is DECI-Celsius (244 → 24.4 C).
    let lifetimeMinTempC: Int?
    let lifetimeMaxTempC: Int?
    let lifetimeAvgTempDeciC: Int?
    let dailyMinSoc: Int?
    let dailyMaxSoc: Int?

    /// #EI-2 v2.1 (SPEC sec 8): lifetime ELECTRICAL extremes from LifetimeData (additive, nil-safe; the v1
    /// required reads and the v2 temperature/charge reads stay byte-unchanged). The pack-voltage range
    /// pairs with the temperature range; the peak currents live in the same dict. Discharge is reported
    /// NEGATIVE (shown as its magnitude). nil on a machine missing the keys, so v1/v2 still render.
    let lifetimeMinPackVoltage_mV: Int?
    let lifetimeMaxPackVoltage_mV: Int?
    let lifetimeMaxChargeCurrent_mA: Int?
    let lifetimeMaxDischargeCurrent_mA: Int?   // reported negative

    /// B0 legibility: the key PATHS ("TopLevelKey / BatteryData.Key / Pack.BatteryData.Key") that resolved
    /// at NO known layout — i.e. drift we did not anticipate. `LifetimeData` (and the v2 / v2.1 sub-stats
    /// that hang off it) is deliberately NOT listed: it is genuinely optional per machine and OS, and a
    /// row that doesn't render is its designed degradation, not drift. Empty on a healthy read. The live
    /// reader logs a warning when it is non-empty.
    var unresolvedKeys: [String] = []

    /// SWEEP §2.G (knowledge/12-SWEEP-silent-absence.md, hit 2). The sentence `unresolvedKeys` never had.
    ///
    /// `lastFailure` only fires on a TOTAL read failure. A PARTIAL relocation — macOS moves ONE figure
    /// off every rung we know — is not a failure at all: the parse succeeds, `lastFailure` stays nil, and
    /// the affected row simply stops rendering on a card that still looks perfectly healthy. That is
    /// finding B0 recurring one notch BELOW the branch built to catch it, and until now the only trace
    /// was an `os.Logger` warning nobody reads. The model always knew; the screen didn't.
    ///
    /// Names the Apple KEY, not the internal three-rung path string: a 320-pt card cannot render
    /// "DesignCapacity / BatteryData.DesignCapacity / Pack.BatteryData.DesignCapacity", and the key name
    /// is what a search or a bug report is actually made of. nil on a healthy read — this is drift
    /// reporting, never a standing disclaimer (verified live 2026-09-08: every figure resolves here).
    var driftNote: String? {
        let keys = unresolvedKeys.compactMap {
            $0.split(separator: "/").first?.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return nil }
        let subject = keys.count == 1 ? "One battery figure is" : "\(keys.count) battery figures are"
        return "\(subject) missing — \(keys.joined(separator: ", ")) resolved at no layout this app knows (macOS may have moved them)."
    }

    /// round(100 * AppleRawMaxCapacity / DesignCapacity). v1 numerator is `rawMaxCapacity_mAh`
    /// (5428/6249 → 87%), continuous with the prior "Health (computed)" figure; `nominalCapacity_mAh`
    /// (→ 89%) is the one-line alternative. nil if either figure is absent, or DesignCapacity is
    /// non-positive (guards divide-by-zero) — the chip/row then renders nothing rather than a wrong number.
    var maxCapacityPercent: Int? {
        guard let rawMax = rawMaxCapacity_mAh, let design = designCapacity_mAh, design > 0 else { return nil }
        return Int((100.0 * Double(rawMax) / Double(design)).rounded())
    }

    /// `PermanentFailureStatus == 0` → "Normal"; non-zero → "Service recommended" (v1: just those two).
    /// ABSENT (macOS 27) → "Unknown": we cannot confirm the pack is healthy, so we don't claim it is.
    /// The popover paints anything that is not "Normal" with the attention token — the right posture for
    /// an unverifiable condition, and never a green "Normal" derived from a key we never read.
    var condition: String {
        guard let pfs = permanentFailureStatus else { return "Unknown" }
        return pfs == 0 ? "Normal" : "Service recommended"
    }

    // #30 stage 10: the four `*Text` formatters that used to live here (lifetime temperature, daily
    // charge range, pack-voltage range, peak current) were the pre-#30 Details card's wording. The Health
    // page formats the same fields through `HealthPageModel.temperatureText / peakCurrentText /
    // packVoltageText` (spec §4.5 wording); the raw fields above are the contract.
}

/// Why a lifetime read produced NOTHING. The split is B0's lesson: "there was no battery node to read"
/// and "the node was there but the key we need has moved" are different facts that used to collapse into
/// the same anonymous `nil`. The second is the macOS-relocation signature, and it names the keys it tried.
enum BatteryLifetimeReadFailure: Error, Equatable, Sendable {
    /// No `AppleSmartBattery` service matched (no battery, or the node itself is gone).
    case noBatteryService
    /// The service matched but its property dictionary could not be copied.
    case propertiesUnavailable
    /// The dictionary was readable but carried NO layout of a figure a lifetime cannot exist without.
    /// Carries the key paths that were tried.
    case missingRequiredKeys([String])

    /// One-line, log-safe description (no user data — these are Apple's key names).
    var summary: String {
        switch self {
        case .noBatteryService:            return "no AppleSmartBattery service matched"
        case .propertiesUnavailable:       return "AppleSmartBattery properties could not be copied"
        case .missingRequiredKeys(let ks): return "required key(s) absent at every known layout: \(ks.joined(separator: ", "))"
        }
    }
}

/// Pure parser: an `AppleSmartBattery` property dict in → a lifetime (or a NAMED failure) out. No IOKit
/// call, no `Bundle.main`, no side effects — unit-testable host-app-free, mirroring `BatteryTelemetryParser`
/// (SPEC WI-1.1; R-06). This is where the macOS layout ladder lives.
enum BatteryLifetimeParser {

    /// Synthetic key under which the live reader folds the CHILD `AppleSmartBatteryPack` node's property
    /// dict into the `AppleSmartBattery` dict, so this parser stays pure dict-in / struct-out and the whole
    /// lifetime still comes from ONE registry visit. Not an Apple key — it never collides with a real one.
    static let packPropertiesKey = "__batteryApp_packProperties"

    /// PLAUSIBILITY BANDS. A gas gauge that has not latched a figure publishes a saturated placeholder
    /// (0xFFFF and friends). The temperature fix's rule — a placeholder must never render as a real figure
    /// — applies to every numeric we surface: a value outside its band is treated as "not published at this
    /// rung" and the ladder moves on, so a 65535 never becomes a 65 Ah pack or a 655 °C lifetime maximum.
    private enum Band {
        static let capacity_mAh = 1...50_000
        static let soc_percent = 0...100
        static let temperature_C = -40...120
        static let temperature_deciC = -400...1_200
        static let packVoltage_mV = 1...30_000
        static let current_mA = -30_000...30_000
        /// A failure BITFIELD: 0 is healthy, any real bit means service. All-ones is the placeholder, not
        /// a pack that failed every way at once — reject it rather than shout "Service recommended".
        static let failureStatus = 0...0xFFFE
    }

    static func parse(_ props: [String: Any]) -> Result<BatteryLifetime, BatteryLifetimeReadFailure> {
        func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }
        func banded(_ any: Any?, _ band: ClosedRange<Int>) -> Int? {
            guard let value = int(any), band.contains(value) else { return nil }
            return value
        }

        // RUNG 2: macOS 27 relocated some raw mAh capacities out of the top-level keys into this nested dict.
        let batteryData = props["BatteryData"] as? [String: Any]
        // RUNG 3: and moved the REST of the gas gauge off this node entirely, onto the child
        // `AppleSmartBatteryPack`'s own nested `BatteryData` — where AppleRawMaxCapacity,
        // PermanentFailureStatus, LifetimeData and DailyMin/MaxSoc all still live under their own names.
        let packData = (props[packPropertiesKey] as? [String: Any])?["BatteryData"] as? [String: Any]
        var unresolved: [String] = []

        /// One key path across every layout we know, newest relocation LAST — the idiom commit 92a1398
        /// established in `BatteryTelemetryParser`: pre-27 TOP-LEVEL key, then the node's macOS 27
        /// `BatteryData` home, then the pack child's. Silent (no drift recorded); `ladder` reports.
        func resolve(top: String?, nested: String, _ band: ClosedRange<Int>) -> Int? {
            if let top, let value = banded(props[top], band) { return value }
            if let value = banded(batteryData?[nested], band) { return value }
            return banded(packData?[nested], band)
        }

        /// `resolve`, plus: a figure that resolves at NO rung is recorded by its full key path (drift we
        /// did not anticipate) and returns nil.
        func ladder(_ top: String, nested: String, _ band: ClosedRange<Int>) -> Int? {
            if let value = resolve(top: top, nested: nested, band) { return value }
            unresolved.append("\(top) / BatteryData.\(nested) / Pack.BatteryData.\(nested)")
            return nil
        }

        // The ONE figure a lifetime cannot be built without: the popover prints the cycle count
        // unconditionally. It is top-level on every OS to date and has no nested home to fall back to,
        // so its absence is a genuine read failure — reported BY NAME, not as a bare nil.
        guard let cycle = int(props["CycleCount"]) else {
            return .failure(.missingRequiredKeys(["CycleCount"]))
        }

        let design = ladder("DesignCapacity", nested: "DesignCapacity", Band.capacity_mAh)
        let nominal = ladder("NominalChargeCapacity", nested: "NominalChargeCapacity", Band.capacity_mAh)
        // Decision #13 computes health from the RAW mAh, so PREFER the raw key wherever it is published:
        // top level pre-27, `pack.BatteryData.AppleRawMaxCapacity` on macOS 27 (5479 on this machine). The
        // node's `BatteryData.FullChargeCapacity` is the LOWER rung — the same figure here (5479), kept for
        // a machine that publishes it and no pack. Never `BatteryData.MaxCapacity`: that is a 0–100 % value
        // on Apple Silicon, not mAh (the R-06 "2% health" trap).
        let rawMax = resolve(top: "AppleRawMaxCapacity", nested: "AppleRawMaxCapacity", Band.capacity_mAh)
            ?? resolve(top: nil, nested: "FullChargeCapacity", Band.capacity_mAh)
        if rawMax == nil {
            unresolved.append("AppleRawMaxCapacity / Pack.BatteryData.AppleRawMaxCapacity / BatteryData.FullChargeCapacity")
        }

        // macOS 27 moved this to `pack.BatteryData.PermanentFailureStatus` (reading 0 here) — it was never
        // deleted, just relocated. Resolving at NO rung still means `condition` reads "Unknown": we never
        // fabricate a 0, and we never paint a green "Normal" from a key we did not read.
        let pfs = ladder("PermanentFailureStatus", nested: "PermanentFailureStatus", Band.failureStatus)

        // #EI-2 v2: navigate one level deeper for the OPTIONAL sub-stats. `LifetimeData` sits inside the
        // node's `BatteryData` pre-27 and inside the PACK's on macOS 27 — same ladder order, dict-valued.
        // A machine carrying neither still yields the v1 figures and nil sub-stat text, which is the honest
        // outcome (a row that does not render beats a wrong number), so this is NOT recorded as drift.
        let ld = (batteryData?["LifetimeData"] as? [String: Any])
            ?? (packData?["LifetimeData"] as? [String: Any])
        func optInt(_ d: [String: Any]?, _ key: String, _ band: ClosedRange<Int>) -> Int? {
            guard let value = (d?[key] as? NSNumber)?.intValue, band.contains(value) else { return nil }
            return value
        }

        return .success(BatteryLifetime(cycleCount: cycle, designCapacity_mAh: design,
                                        nominalCapacity_mAh: nominal, rawMaxCapacity_mAh: rawMax,
                                        permanentFailureStatus: pfs,
                                        lifetimeMinTempC: optInt(ld, "MinimumTemperature", Band.temperature_C),
                                        lifetimeMaxTempC: optInt(ld, "MaximumTemperature", Band.temperature_C),
                                        lifetimeAvgTempDeciC: optInt(ld, "AverageTemperature", Band.temperature_deciC),
                                        // DailyMin/MaxSoc are BatteryData siblings of LifetimeData — node's pre-27, pack's on 27.
                                        dailyMinSoc: resolve(top: nil, nested: "DailyMinSoc", Band.soc_percent),
                                        dailyMaxSoc: resolve(top: nil, nested: "DailyMaxSoc", Band.soc_percent),
                                        // #EI-2 v2.1: the lifetime electrical extremes (same nested dict, same nil-safe read).
                                        lifetimeMinPackVoltage_mV: optInt(ld, "MinimumPackVoltage", Band.packVoltage_mV),
                                        lifetimeMaxPackVoltage_mV: optInt(ld, "MaximumPackVoltage", Band.packVoltage_mV),
                                        lifetimeMaxChargeCurrent_mA: optInt(ld, "MaximumChargeCurrent", Band.current_mA),
                                        lifetimeMaxDischargeCurrent_mA: optInt(ld, "MaximumDischargeCurrent", Band.current_mA),
                                        unresolvedKeys: unresolved))
    }
}

/// Seam over the READ-ONLY AppleSmartBattery lifetime read (parallel to the #EI-1a AssertionInventory /
/// the project's reader seams): production reads the IORegistry node; tests inject a mock. The seam
/// returns a Result so a failure arrives WITH its reason instead of as an anonymous nil — no crash; the
/// section still simply does not render (same posture as #EI-1a).
protocol BatteryLifetimeReading: AnyObject {
    func readDetailed() -> Result<BatteryLifetime, BatteryLifetimeReadFailure>
}

extension BatteryLifetimeReading {
    /// Value-or-nothing convenience for callers that don't care WHY (the seam's original shape).
    func read() -> BatteryLifetime? { try? readDetailed().get() }
}

/// Production reader: match the AppleSmartBattery node, copy its properties AND its `AppleSmartBatteryPack`
/// child's, hand the pair to the pure parser. READ-ONLY — no IOKit write, no SMC, no charge-inhibit, no
/// assertion. Boundary adapter — exercised in tests only through the seam's mock (never the live
/// IORegistry); the parsing it delegates IS tested.
final class LiveBatteryLifetimeReader: BatteryLifetimeReading {
    /// B0 legibility: a relocation must leave a trace. Key names only — no user data.
    private static let log = Logger(subsystem: "com.example.batteryapp", category: "Lifetime")

    func readDetailed() -> Result<BatteryLifetime, BatteryLifetimeReadFailure> {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .failure(.noBatteryService) }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              var props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return .failure(.propertiesUnavailable)
        }
        // macOS 27 moved most of the gas gauge OFF this node and onto its CHILD `AppleSmartBatteryPack`.
        // Fold that child in under the parser's synthetic key so the SINGLE lifetime read still feeds every
        // figure (no second registry visit) and the parser stays pure dict-in / struct-out.
        if let pack = Self.copyPackProperties(of: service) {
            props[BatteryLifetimeParser.packPropertiesKey] = pack
        }

        let result = BatteryLifetimeParser.parse(props)
        switch result {
        case .failure(let failure):
            Self.log.error("AppleSmartBattery lifetime read failed: \(failure.summary, privacy: .public)")
        case .success(let lifetime) where !lifetime.unresolvedKeys.isEmpty:
            let keys = lifetime.unresolvedKeys.joined(separator: ", ")
            Self.log.warning("AppleSmartBattery lifetime figures unresolved at every known layout: \(keys, privacy: .public) — those rows degrade to absent (likely an OS key relocation)")
        default:
            break
        }
        return result
    }

    /// READ-ONLY registry walk for the `AppleSmartBatteryPack` child of the battery node — the same walk
    /// `LiveBatteryReader` uses for temperature. nil where the child does not exist or has no properties
    /// (pre-27 machines); the parser's ladder then just uses the top-level / node-`BatteryData` rungs.
    /// No IOKit write, no SMC.
    private static func copyPackProperties(of battery: io_service_t) -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(battery, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var found: [String: Any]?
        var child = IOIteratorNext(iterator)
        while child != 0 {
            if found == nil, IOObjectConformsTo(child, "AppleSmartBatteryPack") != 0 {
                var childProps: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(child, &childProps, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                    found = childProps?.takeRetainedValue() as? [String: Any]
                }
            }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return found
    }
}

/// #EI-2 popover source: reads the lifetime ON DEMAND (popover-open) and publishes it. NO timer —
/// battery health changes far too slowly to justify one. nil = read failed / not yet read → no render.
@MainActor
final class BatteryLifetimeSource: ObservableObject {
    @Published private(set) var lifetime: BatteryLifetime?
    /// Why the last refresh produced nothing (nil when the last read succeeded, or before the first read).
    /// Nothing renders it today; it exists so "read failed" is inspectable rather than indistinguishable
    /// from "not read yet" — the collapse that made B0 silent.
    @Published private(set) var lastFailure: BatteryLifetimeReadFailure?

    private let reader: BatteryLifetimeReading

    init(reader: BatteryLifetimeReading = LiveBatteryLifetimeReader()) {
        self.reader = reader
    }

    /// On-demand read (synchronous IORegistry read; fast). No polling timer.
    func refresh() {
        switch reader.readDetailed() {
        case .success(let value):
            lifetime = value
            lastFailure = nil
        case .failure(let failure):
            lifetime = nil
            lastFailure = failure
        }
    }
}
