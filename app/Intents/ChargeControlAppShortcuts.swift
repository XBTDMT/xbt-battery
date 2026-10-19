import AppIntents

/// Phase 5 feature #17 (STAGE 1 + Pass 2): vends the Set Charge Limit, Top Up, and Set Energy Mode intents
/// to Shortcuts / Siri / Spotlight with spoken phrases. Phrase copy + short titles are owner-tunable (spec
/// sec 1 / §4). Each shortTitle is kept DISTINCT from the native macOS action in its class (the "Set Charge
/// Limit" vs native "Set Battery Charge Limit" lesson) — "Set Energy Mode" is distinct from the native "Set
/// Low Power Mode" action; confirm in the live action picker on-device.
struct ChargeControlAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetChargeLimitIntent(),
            phrases: ["Set \(.applicationName) charge limit"],
            shortTitle: "Set Charge Limit",
            systemImageName: "minus.plus.batteryblock")
        AppShortcut(
            intent: TopUpIntent(),
            phrases: ["Top up \(.applicationName)", "Top up my battery with \(.applicationName)"],
            shortTitle: "Top Up Battery",
            systemImageName: "battery.100.bolt")
        AppShortcut(
            intent: EnergyModeIntent(),
            phrases: ["Set \(.applicationName) energy mode"],
            shortTitle: "Set Energy Mode",
            systemImageName: "bolt.fill")
    }
}
