import XCTest
@testable import Battery

/// Sprint 4.4: the UserDefaults-backed preferences store. Default-OFF is the natural unset-bool
/// value; default-ON keys read true via an explicit fallback (matching the codebase's
/// "hardcode defaults in the initializer" convention — no register(defaults:) global side effects).
@MainActor
final class NotificationPreferencesStoreTests: XCTestCase {

    /// A throwaway suite so tests never touch the real .standard domain.
    private func freshStore() -> (NotificationPreferencesStore, UserDefaults, String) {
        let name = "test.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (NotificationPreferencesStore(defaults: defaults), defaults, name)
    }

    func testFreshStoreReadsSpecDefaults() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(store.prefs, NotificationPrefs.defaults)
        XCTAssertFalse(store.masterEnabled)            // sec 1: master default OFF
    }

    func testMasterTogglePersistsAcrossInstances() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.masterEnabled = true
        let reloaded = NotificationPreferencesStore(defaults: defaults)
        XCTAssertTrue(reloaded.masterEnabled)
        XCTAssertTrue(reloaded.prefs.masterEnabled)
    }

    func testPerEventTogglePersists() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.setEnabled(false, for: .fullyCharged)    // flip a default-ON event off
        store.setEnabled(true, for: .limitReached)     // flip a default-OFF event on
        let reloaded = NotificationPreferencesStore(defaults: defaults)
        XCTAssertFalse(reloaded.prefs.fullyCharged)
        XCTAssertTrue(reloaded.prefs.limitReached)
    }

    func testTogglingOneEventLeavesOthersAtDefault() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.setEnabled(false, for: .setupProblem)
        let p = store.prefs
        XCTAssertFalse(p.setupProblem)                 // changed
        XCTAssertTrue(p.fullyCharged)                  // untouched default-ON
        XCTAssertTrue(p.topUpComplete)
        XCTAssertTrue(p.scheduledApplied)
        XCTAssertFalse(p.lowBattery)                   // untouched default-OFF
        XCTAssertFalse(p.limitReached)
    }

    func testIsEnabledReflectsStoredState() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(store.isEnabled(.topUpComplete))   // default ON
        store.setEnabled(false, for: .topUpComplete)
        XCTAssertFalse(store.isEnabled(.topUpComplete))
    }

    func testLowBatteryThresholdDefaultsToTwentyAndPersists() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(store.prefs.lowBatteryThreshold, 20, "fresh store defaults the threshold to 20")
        store.lowBatteryThreshold = 15
        let reloaded = NotificationPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.lowBatteryThreshold, 15, "a written threshold persists across instances")
        XCTAssertEqual(reloaded.prefs.lowBatteryThreshold, 15)
    }
}
