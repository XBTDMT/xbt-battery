import Foundation

// Sprint 3.7 (wake behavior) STAGE 2a — the pure read-back + UI-mapping core for the 4th op. Parses
// `pmset -g custom` (read app-side, unprivileged) into the current per-source powernap/womp state, and
// maps between that per-source boolean truth and the three-way UI scope (Never / On power adapter /
// Always). Pure and fully unit-testable; the Process spawn is the controller's LivePmsetCustomReader.
public enum WakeBehaviorReadback {

    /// The live per-source state of the two keys, as read from `pmset -g custom`.
    public struct State: Sendable, Equatable {
        public let powerNapBattery: Bool
        public let powerNapAC: Bool
        public let wakeOnNetworkBattery: Bool
        public let wakeOnNetworkAC: Bool
        public init(powerNapBattery: Bool, powerNapAC: Bool,
                    wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool) {
            self.powerNapBattery = powerNapBattery
            self.powerNapAC = powerNapAC
            self.wakeOnNetworkBattery = wakeOnNetworkBattery
            self.wakeOnNetworkAC = wakeOnNetworkAC
        }
    }

    /// The three-way per-feature control state (matches Apple's Wake-for-network model).
    public enum Scope: Sendable, Hashable, CaseIterable {
        case never           // off on both sources
        case onPowerAdapter  // off on battery, on on AC (Apple's womp default)
        case always          // on on both sources
    }

    /// Map a three-way scope to the (battery, AC) booleans for one feature.
    public static func bools(for scope: Scope) -> (battery: Bool, ac: Bool) {
        switch scope {
        case .never:          return (false, false)
        case .onPowerAdapter: return (false, true)
        case .always:         return (true, true)
        }
    }

    /// Map a feature's (battery, AC) booleans to the nearest three-way scope. The degenerate
    /// (battery on, AC off) state, reachable only if another tool set it, normalizes to .always; the
    /// read-back line shows the literal per-source truth, so the display is never misleading.
    public static func scope(battery: Bool, ac: Bool) -> Scope {
        switch (battery, ac) {
        case (false, false): return .never
        case (false, true):  return .onPowerAdapter
        case (true, true):   return .always
        case (true, false):  return .always
        }
    }

    /// Parse `pmset -g custom` output into State. Returns nil if either power-source block, or any of
    /// the four key values, cannot be found (a read we cannot fully trust; the controller treats nil as
    /// "unknown" rather than guessing).
    public static func parse(_ output: String) -> State? {
        func block(_ header: String) -> String? {
            guard let start = output.range(of: header) else { return nil }
            let rest = output[start.upperBound...]
            var end = rest.endIndex
            for other in ["Battery Power:", "AC Power:", "UPS Power:"] where other != header {
                if let r = rest.range(of: other), r.lowerBound < end { end = r.lowerBound }
            }
            return String(rest[..<end])
        }
        func value(_ key: String, in blockText: String) -> Bool? {
            for rawLine in blockText.split(whereSeparator: \.isNewline) {
                let parts = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if parts.count >= 2, parts[0] == key { return parts[1] == "1" }
            }
            return nil
        }
        guard let battery = block("Battery Power:"), let ac = block("AC Power:") else { return nil }
        guard let pnB = value("powernap", in: battery), let pnA = value("powernap", in: ac),
              let wnB = value("womp", in: battery), let wnA = value("womp", in: ac) else { return nil }
        return State(powerNapBattery: pnB, powerNapAC: pnA,
                     wakeOnNetworkBattery: wnB, wakeOnNetworkAC: wnA)
    }
}
