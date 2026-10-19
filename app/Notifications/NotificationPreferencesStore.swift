import Foundation

/// Sprint 4.4: UserDefaults-backed notification preferences. Keys follow the project convention
/// (`notifications.*.v1`, dot-separated, versioned — like `loginItem.suggestionShown.v1`). Defaults
/// are read with an explicit per-key fallback sourced from `NotificationPrefs.defaults` (the single
/// source of truth), matching the codebase's "hardcode defaults in the initializer" pattern rather
/// than `register(defaults:)` (which mutates a process-global registration domain). `UserDefaults`
/// is injected so the store is testable host-app-free against a throwaway suite.
@MainActor
final class NotificationPreferencesStore {

    private let defaults: UserDefaults

    private static let masterKey = "notifications.master.v1"
    private static func key(for type: NotificationEventType) -> String {
        "notifications.event.\(type.rawValue).v1"
    }
    private static let lowBatteryThresholdKey = "notifications.lowBatteryThreshold.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read with the SPEC default as the fallback when the key has never been written.
    private func bool(_ key: String, default def: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? def : defaults.bool(forKey: key)
    }

    private func int(_ key: String, default def: Int) -> Int {
        defaults.object(forKey: key) == nil ? def : defaults.integer(forKey: key)
    }

    var masterEnabled: Bool {
        get { bool(Self.masterKey, default: NotificationPrefs.defaults.masterEnabled) }
        set { defaults.set(newValue, forKey: Self.masterKey) }
    }

    /// The configurable low-battery warning threshold (percent), SPEC default (20) as the fallback.
    var lowBatteryThreshold: Int {
        get { int(Self.lowBatteryThresholdKey, default: NotificationPrefs.defaults.lowBatteryThreshold) }
        set { defaults.set(newValue, forKey: Self.lowBatteryThresholdKey) }
    }

    /// The current per-event toggle, with the SPEC default as the fallback for an unwritten key.
    func isEnabled(_ type: NotificationEventType) -> Bool {
        bool(Self.key(for: type), default: NotificationPrefs.defaults.isEnabled(type))
    }

    func setEnabled(_ on: Bool, for type: NotificationEventType) {
        defaults.set(on, forKey: Self.key(for: type))
    }

    /// The full snapshot the pure decision layer consumes.
    var prefs: NotificationPrefs {
        NotificationPrefs(
            masterEnabled: masterEnabled,
            fullyCharged: isEnabled(.fullyCharged),
            limitReached: isEnabled(.limitReached),
            topUpComplete: isEnabled(.topUpComplete),
            scheduledApplied: isEnabled(.scheduledApplied),
            lowBattery: isEnabled(.lowBattery),
            setupProblem: isEnabled(.setupProblem),
            hotBattery: isEnabled(.hotBattery),
            lowBatteryThreshold: lowBatteryThreshold)
    }
}
