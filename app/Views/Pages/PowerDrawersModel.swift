import Foundation

/// Owner ruling 2026-09-09 evening: "who is drawing power" is ONE shared ranking. The Now tab shows its
/// first five as icons; the Energy tab shows the full list. Both views call `PowerDrawers.current(…)`
/// (the single place that picks the source and resolves identity), so the two tabs can never disagree.
///
/// This file is the PURE half (host-app-free): source preference, the row → `Drawer` mapping, ordering
/// and shares. The identity lookup (AppKit) sits behind `DrawerIdentityResolving`.
enum PowerDrawersModel {

    enum Source: Equatable { case sustained, snapshot }

    struct Drawer: Identifiable {
        let id: String
        let displayName: String
        let subtitle: String?
        let icon: AppIconChoice
        /// Honest share of the sample's total (§14-D7), 0…1.
        let share: Double
    }

    /// The longest list either tab shows.
    static let cap = 12
    /// The Now tab's icon strip shows this many of the head of the list.
    static let nowStripCount = 5

    /// Sustained (the helper's coalition ranking — every process, not just the readable ones) whenever
    /// it is available with entries; else the 0.5 s snapshot. `userChoice` is the Energy strip's flip;
    /// a choice of Sustained while it is unavailable falls back to the snapshot.
    static func preferredSource(sustainedAvailable: Bool, sustainedHasEntries: Bool, userChoice: Source?) -> Source {
        let sustainedUsable = sustainedAvailable && sustainedHasEntries
        switch userChoice {
        case .snapshot?: return .snapshot
        case .sustained?: return sustainedUsable ? .sustained : .snapshot
        case nil: return sustainedUsable ? .sustained : .snapshot
        }
    }

    /// Snapshot rows → drawers. Sorted by energy (desc), top `cap`, share = energy ÷ the sample total.
    static func drawers(snapshot rows: [EnergyImpactRow], totalMillijoules: Double,
                        resolver: any DrawerIdentityResolving) -> [Drawer] {
        rows.sorted { $0.energyMillijoules > $1.energyMillijoules }.prefix(cap).map { row in
            let id = resolver.identity(pid: row.pid, bundleID: nil, name: row.name)
            return Drawer(id: "pid:\(row.pid)", displayName: id.displayName, subtitle: id.subtitle, icon: id.icon,
                          share: EnergyPageModel.share(row.energyMillijoules, of: totalMillijoules))
        }
    }

    /// Sustained rows → drawers. Denominator: the helper's all-tasks total when present, else the sum of
    /// the entries (the honest denominator that is available). Identity by coalition bundle id.
    static func drawers(sustained rows: [SustainedEnergyEntry], total: Double?,
                        resolver: any DrawerIdentityResolving) -> [Drawer] {
        let denominator: Double = {
            if let total, total.isFinite, total > 0 { return total }
            return rows.reduce(0) { $0 + $1.energyImpact }
        }()
        return rows.sorted { $0.energyImpact > $1.energyImpact }.prefix(cap).map { e in
            let id = resolver.identity(pid: nil, bundleID: e.id, name: e.name)
            return Drawer(id: "bundle:\(e.id)", displayName: id.displayName, subtitle: id.subtitle, icon: id.icon,
                          share: EnergyPageModel.share(e.energyImpact, of: denominator))
        }
    }

    /// The caption each tab prints under its list, by source.
    static func caption(for source: Source) -> String {
        source == .sustained ? EnergyPageModel.sustainedCaption : EnergyPageModel.sampleCaption
    }

    /// A stable key for "the inputs changed" — the views re-resolve identity (plist parses, icon fetches)
    /// only when this changes, never per render.
    static func inputsKey(source: Source, snapshotIDs: [Int], sustainedIDs: [String]) -> String {
        switch source {
        case .snapshot:  return "snapshot:" + snapshotIDs.map(String.init).joined(separator: ",")
        case .sustained: return "sustained:" + sustainedIDs.joined(separator: ",")
        }
    }
}
