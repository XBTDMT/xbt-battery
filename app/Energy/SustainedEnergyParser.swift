import Foundation

// Sprint 3.7 STAGE 4 (#19-real), CORRECTED in fix A2 — PURE parser for the privileged helper's
// `powermetrics --samplers tasks -f plist --show-process-energy --show-process-coalition` output. This
// is the SUSTAINED, app-ATTRIBUTED energy data the "responsible-app" view rides on. Host-app-free.
//
// STRUCTURE (confirmed against a real root capture, /tmp/pm.plist, M4 Max / macOS 27 — A2):
//   - TOP-LEVEL `coalitions` (LIST): the per-responsible-app rows, ALREADY grouped. Each: `name`
//     (responsible app as a bundle id, e.g. "com.mitchellh.ghostty"), `id` (coalition id),
//     `energy_impact` (the unitless composite — the ranking metric), plus a `tasks` sublist (members,
//     for future drill-down). The Stage 4/5 parser wrongly assumed a top-level `tasks` array; there is
//     none. Same-`name` coalitions are folded (the real plist carries two `com.apple.Spotlight`).
//   - TOP-LEVEL `all_tasks` (DICT, pid -2, name "ALL_TASKS"): the grand total — `parseTotal` reads its
//     `energy_impact` as the denominator B1 may use.
//
// HONESTY CONTRACT (the whole point): garbled/truncated/empty input degrades SAFELY — never crash,
// never return partial-as-real. `parse` returns nil on a parse failure (the UI hides / shows an honest
// "unavailable"), [] when there is genuinely no attributable activity (also hidden), or the ranked list
// on success. `energy_impact` is a UNITLESS composite — shown as a RELATIVE ranking, NEVER watts.

/// One responsible-app (coalition) row: a `name` and its `energyImpact` (the unitless powermetrics
/// composite — never presented as watts; the app's one true watt number is #20's).
public struct SustainedEnergyEntry: Equatable, Identifiable {
    public let id: String          // the responsible-app key (coalition name, or id when unnamed)
    public let name: String        // coalition / responsible-app name
    public let energyImpact: Double
    public init(id: String, name: String, energyImpact: Double) {
        self.id = id; self.name = name; self.energyImpact = energyImpact
    }
}

public enum SustainedEnergyParser {

    // Real powermetrics tasks-sampler keys (A2: confirmed against /tmp/pm.plist).
    static let kCoalitions = "coalitions"
    static let kAllTasks = "all_tasks"
    static let kName = "name"
    static let kID = "id"
    static let kEnergyImpact = "energy_impact"

    /// Parse + fold the per-responsible-app rows. Returns:
    ///   - nil  → could not parse (empty/garbled/truncated, not a dict, or no `coalitions` list) → HIDE
    ///   - []   → parsed fine but no attributable activity (empty / all-zero) → HIDE
    ///   - rows → folded by responsible-app name, sorted by energy impact descending
    public static func parse(plistData: Data) -> [SustainedEnergyEntry]? {
        guard let root = rootDict(plistData) else { return nil }
        guard let coalitions = root[kCoalitions] as? [[String: Any]] else { return nil }  // unexpected shape → hide
        if coalitions.isEmpty { return [] }                                                // honest empty

        // Fold by responsible-app name: the coalitions are already per-app, but the real plist can carry
        // more than one coalition for one responsible app (e.g. two com.apple.Spotlight) — sum those.
        var order: [String] = []
        var byKey: [String: (name: String, energy: Double)] = [:]
        for coalition in coalitions {
            // SKIP (never surface/fabricate) a coalition whose energy_impact is missing, non-numeric, a
            // CFBoolean, NaN, ±inf, or negative. Skipping (not zero-filling) also means one bad row can
            // never poison a folded total (the honesty contract).
            guard let energy = finiteNonNegative(coalition[kEnergyImpact]) else { continue }
            let rawName = (coalition[kName] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let idStr = (coalition[kID] as? NSNumber).map { String($0.intValue) }
            let key = rawName ?? idStr ?? "unknown"
            let display = rawName ?? idStr ?? "unknown"
            if let existing = byKey[key] {
                byKey[key] = (name: existing.name, energy: existing.energy + energy)
            } else {
                order.append(key)
                byKey[key] = (name: display, energy: energy)
            }
        }
        let entries = order.compactMap { key -> SustainedEnergyEntry? in
            guard let v = byKey[key] else { return nil }
            return SustainedEnergyEntry(id: key, name: v.name, energyImpact: v.energy)
        }
        // Sort by energy desc, name tie-break for deterministic ordering (parity with EnergyImpactParser).
        let sorted = entries.sorted {
            $0.energyImpact != $1.energyImpact ? $0.energyImpact > $1.energyImpact : $0.name < $1.name
        }
        // All-zero guard: if even the top row is zero, every row is — no real activity to attribute, so
        // HIDE ([]) rather than show named rows with collapsed empty bars (reads as "real" when it isn't).
        guard let top = sorted.first, top.energyImpact > 0 else { return [] }
        return sorted
    }

    /// The grand total = `all_tasks.energy_impact` (the denominator B1 may use for relative bars). nil
    /// when all_tasks is absent or its energy is non-finite/negative — the caller then falls back (e.g.
    /// to the busiest row) rather than dividing by a bad number.
    public static func parseTotal(plistData: Data) -> Double? {
        guard let root = rootDict(plistData),
              let all = root[kAllTasks] as? [String: Any] else { return nil }
        return finiteNonNegative(all[kEnergyImpact])
    }

    // MARK: - shared helpers

    /// Deserialize the plist root dict (XML or binary). A garbled/truncated/empty stream → nil (no crash).
    private static func rootDict(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = object as? [String: Any] else { return nil }
        return root
    }

    /// A finite, non-negative numeric value — or nil. Rejects missing, non-numeric, CFBoolean (<true/>
    /// bridges to NSNumber → an invented 1.0), NaN, ±inf, and negatives.
    private static func finiteNonNegative(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d >= 0 else { return nil }
        return d
    }
}
