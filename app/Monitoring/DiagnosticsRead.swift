import Foundation

/// spec 31 §2.2 / §3.1 (G-2, G-4): one diagnostics read as the monitor's subscribers see it.
/// `.read(props)` is the raw `AppleSmartBattery` dict of a SUCCESSFUL read (the `AppleSmartBatteryPack`
/// child already folded in by `LiveBatteryReader` under `BatteryTelemetryParser.packPropertiesKey`);
/// `.unread` is the failure branch — a failed read reported as such, never silently as "the last value
/// again" (absence is not a fact). MainActor-only by construction: the monitor produces it on the main
/// actor and every subscriber is `@MainActor`, so no Sendable conformance is claimed for the dict.
enum DiagnosticsRead {
    case read([String: Any])
    case unread
}
