import Foundation

/// Stable identifiers and the code-sign requirement builder shared by the agent app and the
/// privileged ENERGY helper (Sprint 3.7; supersedes the Phase-2 charge-helper identity).
///
/// Sprint 3.7 ruling (SPEC sec 0/11): the privileged scaffolding is REPURPOSED but the registration
/// IDENTITY is FRESH — a stale registration of the retired SMC daemon must not shadow the new energy
/// service. Hence new bundle id + Mach service + plist name here.
public enum BatteryAppIDs {

    /// The agent app's bundle identifier — and, because an app's code-sign identifier equals
    /// its `CFBundleIdentifier`, also its code-sign identifier (pinned by the helper).
    public static let app = "com.example.batteryapp"

    /// The privileged ENERGY helper's bundle identifier (FRESH — Sprint 3.7). The helper's code-sign
    /// identifier must equal this (set via `CFBundleIdentifier` in its in-binary Info.plist) or the
    /// app's pinned requirement rejects the peer and the channel fails opaquely.
    public static let helper = "com.example.batteryapp.energyhelper"

    /// The Mach service the helper vends and the app connects to. FRESH and distinct from the retired
    /// `com.example.batteryapp.helper` service so the old registration cannot shadow this one. Must
    /// match the helper launchd plist `MachServices` key and the app's `NSXPCConnection(machServiceName:)`.
    public static let machService = "com.example.batteryapp.energyhelper"

    /// The launchd plist file name passed to `SMAppService.daemon(plistName:)` — note the required
    /// `.plist` extension (omitting it = SMAppService error 108). FRESH (Sprint 3.7).
    public static let helperPlistName = "EnergyHelper.plist"

    /// The RETIRED Phase-2 charge helper's plist name. Sprint 3.7 sec-6b migration: on an upgrade the
    /// old SMC daemon may still hold a BTM registration under this label; the app detects it, shows a
    /// one-time notice, and unregisters it. No longer shipped in the bundle — used only to address the
    /// stale registration for cleanup.
    public static let legacyHelperPlistName = "com.example.batteryapp.helper.plist"

    // The designated-requirement builder + the audit-token peer validator now live in the codified
    // single source `DesignatedRequirement.swift` (Sprint 3.7 sec 6): `designatedRequirement(...)`
    // (Apple anchor + Team ID + bundle id + min-version), `helperRequirement`/`appRequirement`, and
    // `peerSatisfies(auditToken:requirement:)`. They are used IDENTICALLY for the XPC pin and the
    // SMAppService registration validation, so the two cannot drift.

    /// Reads the signing Team ID injected into the running bundle's Info.plist as
    /// `TeamID = $(DEVELOPMENT_TEAM)` (app Info.plist / helper in-binary section). Fails loudly
    /// if absent — that means `$(DEVELOPMENT_TEAM)` did not expand in the built Info.plist (a
    /// build misconfiguration), which we want to catch rather than silently emit an empty-OU
    /// requirement.
    public static func mainBundleTeamID() -> String {
        guard let teamID = Bundle.main.infoDictionary?["TeamID"] as? String, !teamID.isEmpty else {
            fatalError("TeamID missing from Info.plist — $(DEVELOPMENT_TEAM) did not expand in the build. Check Signing.xcconfig.")
        }
        return teamID
    }

    /// Non-trapping Team-ID read for the helper's **launch path** (that path must never `fatalError`,
    /// or a misconfigured build crash-loops under `KeepAlive`). Returns nil if absent; the helper then
    /// refuses XPC connections (fail-closed). (App side keeps using `mainBundleTeamID()`.)
    public static func mainBundleTeamIDOrNil() -> String? {
        guard let teamID = Bundle.main.infoDictionary?["TeamID"] as? String, !teamID.isEmpty else { return nil }
        return teamID
    }
}
