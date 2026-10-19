import XCTest
@testable import Battery

/// #29 A1 / Grok F3 — SettingsRouter selection semantics + open(to:) idempotence. The router is the
/// single source of truth for tab deep-links (consumed in Cut D-4); the monotonic open-request token
/// makes the deep-link robust to Settings-window lifecycle timing.
@MainActor
final class SettingsRouterTests: XCTestCase {

    func testDefaultTabIsGeneral() {
        XCTAssertEqual(SettingsRouter().selection, .general)
    }

    func testCustomInitialSelection() {
        XCTAssertEqual(SettingsRouter(selection: .automation).selection, .automation)
    }

    func testOpenSetsSelection() {
        let router = SettingsRouter()
        router.open(to: .notifications)
        XCTAssertEqual(router.selection, .notifications)
    }

    func testOpenToEachTabSelectsIt() {
        let router = SettingsRouter()
        for tab in SettingsTab.allCases {
            router.open(to: tab)
            XCTAssertEqual(router.selection, tab)
        }
    }

    func testRepeatedOpenSameTabIsIdempotentOnSelection() {
        let router = SettingsRouter()
        router.open(to: .automation)
        router.open(to: .automation)
        router.open(to: .automation)
        XCTAssertEqual(router.selection, .automation)   // selection stable under repeated identical opens
    }

    func testOpenRequestTokenAdvancesOnEveryCall() {
        let router = SettingsRouter()
        let t0 = router.openRequestToken
        router.open(to: .general)                       // same as the default tab...
        let t1 = router.openRequestToken
        router.open(to: .general)
        let t2 = router.openRequestToken
        XCTAssertGreaterThan(t1, t0)                    // ...still re-requests the window (deliberately not idempotent)
        XCTAssertGreaterThan(t2, t1)
    }

    // #29 D-4b: select(_:) is the manual tab-change setter (the TabView binding) — it updates selection
    // but must NOT advance the open-request token (only a deep-link open(to:) fronts the window).
    func testSelectSetsSelectionWithoutAdvancingToken() {
        let router = SettingsRouter()
        let t0 = router.openRequestToken
        router.select(.automation)
        XCTAssertEqual(router.selection, .automation)   // manual tab change updates selection...
        XCTAssertEqual(router.openRequestToken, t0)     // ...but does NOT re-request the window (F3)
    }

    func testSelectToEachTabSelectsIt() {
        let router = SettingsRouter()
        for tab in SettingsTab.allCases {
            router.select(tab)
            XCTAssertEqual(router.selection, tab)
        }
    }

    // F3: a deep-link (open) AFTER a manual tab change (select) must still front the window.
    func testOpenAfterSelectStillAdvancesToken() {
        let router = SettingsRouter()
        router.select(.appearance)
        let t = router.openRequestToken
        router.open(to: .automation)
        XCTAssertEqual(router.selection, .automation)
        XCTAssertGreaterThan(router.openRequestToken, t)
    }

    func testTabRawValuesAndCountAreStable() {
        XCTAssertEqual(SettingsTab.general.rawValue, "general")
        XCTAssertEqual(SettingsTab.appearance.rawValue, "appearance")
        XCTAssertEqual(SettingsTab.notifications.rawValue, "notifications")
        XCTAssertEqual(SettingsTab.automation.rawValue, "automation")
        XCTAssertEqual(SettingsTab.allCases.count, 4)
    }
}
