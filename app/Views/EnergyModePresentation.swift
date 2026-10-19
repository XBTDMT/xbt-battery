import Foundation
import Shared   // EnergyModeValue / EnergySource (the picker's value + source enums live in Shared)

/// #29 D-4b: presentation helpers for the energy-mode controls, single-homed here.
///
/// BOTH the popover root's active-source Energy-mode card (`app/Views/BatteryPopoverView`) and the
/// Settings · Automation per-source picker (`app/App/SettingsView`) render the same value↔label↔mark
/// mapping. The D-4b ruling was: one shared home over duplication. These four helpers were previously
/// private methods on `BatteryPopoverView` (`energyModeValue` / `currentMode` / `modeLabel` /
/// `modeMatches`); they are pure — no SwiftUI, no state — so the per-source read is passed in and each
/// caller keeps its own `@State`.
enum EnergyModePresentation {
    /// Map a display `EnergyMode` to the picker's `EnergyModeValue`; `.unavailable` has no value (nil).
    static func value(from mode: EnergyMode) -> EnergyModeValue? {
        switch mode {
        case .automatic:   return .automatic
        case .low:         return .low
        case .high:        return .high
        case .unavailable: return nil
        }
    }

    /// The current mode to mark for `source`. Per-source value from `pmset -g custom` when `perSource`
    /// is populated (independent of the active source); before that read lands, fall back to the active
    /// read — correct for the active source, `.unavailable` (no mark) for the other, so a guessed value
    /// is never marked.
    static func currentMode(for source: EnergySource, active: EnergySource, activeMode: EnergyMode,
                            perSource: EnergyModeReader.PerSourceEnergyMode?) -> EnergyMode {
        if let m = perSource { return source == .battery ? m.battery : m.charger }
        return source == active ? activeMode : .unavailable
    }

    /// The short segment label for a picker value.
    static func label(_ mode: EnergyModeValue) -> String {
        switch mode {
        case .automatic: return "Auto"
        case .low:       return "Low"
        case .high:      return "High"
        }
    }

    /// Whether a picker value equals a display mode (the "bold the current" test).
    static func matches(_ value: EnergyModeValue, _ display: EnergyMode) -> Bool {
        switch (value, display) {
        case (.automatic, .automatic), (.low, .low), (.high, .high): return true
        default: return false
        }
    }
}
