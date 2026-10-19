import Foundation

/// #30 · the six rail tabs, in rail order (spec §4.1). Pure: no SwiftUI, so it compiles into the test
/// target and the selection mapping below is assertable host-app-free.
enum RailTab: Int, CaseIterable, Hashable {
    case now, day, energy, health, devices, automation

    /// The page title (also the rail button's accessibility label).
    var title: String {
        switch self {
        case .now: "Now"
        case .day: "Day"
        case .energy: "Energy"
        case .health: "Health"
        case .devices: "Devices"
        case .automation: "Automation"
        }
    }

    /// SF Symbol per spec §4.1. `gauge.with.dots.needle.33percent` is macOS 14.0 — exactly the
    /// deployment target (verified by the red team against CoreGlyphs' availability table).
    var symbol: String {
        switch self {
        case .now: "gauge.with.dots.needle.33percent"
        case .day: "chart.xyaxis.line"
        case .energy: "bolt.fill"
        case .health: "heart"
        case .devices: "airpods.gen3"
        case .automation: "timer"
        }
    }
}

/// #30 spec §8 · the ONLY mapping from the `PopoverNavigator` channel to a rail tab. The navigator keeps
/// its single `Route.details` and its three consumers; this function is what the view does with the
/// path it is handed. `[.details]` (the show-history deep link and the Details row) ⇒ Day; the root
/// (`[]`, set on every show and on close) ⇒ Now — so every normal show lands on Now (red-team C3: the
/// banner slot lives on Now and must be seen). No persisted tab, by ruling.
enum RailSelection {
    static func tab(for path: [PopoverNavigator.Route]) -> RailTab {
        path.last == .details ? .day : .now
    }
}
