import Foundation

/// The ONE place both tabs get the ranking from (owner ruling 2026-09-09 evening). `@MainActor` because
/// it reads the two published sources; the policy it applies lives in `PowerDrawersModel` (pure, tested).
@MainActor
enum PowerDrawers {
    /// Identity seam. `static var` so the R15 render harness can substitute a fixture resolver.
    static var identityResolver: any DrawerIdentityResolving = LiveDrawerIdentityResolver()

    static func source(energySource: EnergyImpactSource, sustained: SustainedEnergySource,
                       userChoice: PowerDrawersModel.Source? = nil) -> PowerDrawersModel.Source {
        PowerDrawersModel.preferredSource(sustainedAvailable: !sustained.isUnavailable,
                                          sustainedHasEntries: !sustained.apps.isEmpty, userChoice: userChoice)
    }

    /// The inputs key for the chosen source (drives the views' `.task(id:)`).
    static func key(energySource: EnergyImpactSource, sustained: SustainedEnergySource,
                    userChoice: PowerDrawersModel.Source? = nil) -> String {
        let src = source(energySource: energySource, sustained: sustained, userChoice: userChoice)
        return PowerDrawersModel.inputsKey(source: src, snapshotIDs: energySource.candidates.map(\.pid),
                                           sustainedIDs: sustained.apps.map(\.id))
    }

    /// The shared ranking (top 12, sorted by energy) with identity resolved. Costs plist parses and icon
    /// fetches — call from a `.task(id: key(...))`, not from `body`.
    static func current(energySource: EnergyImpactSource, sustained: SustainedEnergySource,
                        userChoice: PowerDrawersModel.Source? = nil) -> [PowerDrawersModel.Drawer] {
        switch source(energySource: energySource, sustained: sustained, userChoice: userChoice) {
        case .sustained:
            return PowerDrawersModel.drawers(sustained: sustained.apps, total: sustained.total, resolver: identityResolver)
        case .snapshot:
            return PowerDrawersModel.drawers(snapshot: energySource.candidates, totalMillijoules: energySource.totalMillijoules,
                                             resolver: identityResolver)
        }
    }
}
