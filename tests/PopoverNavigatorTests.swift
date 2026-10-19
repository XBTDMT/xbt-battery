import XCTest
@testable import Battery

/// #29 D-6 — the PopoverNavigator channel (the build's one sanctioned AppDelegate↔view seam). The
/// reset-to-root / deep-link *policy* lives in the AppDelegate (popoverWillShow, app-only, proven
/// on-device); here we cover the channel's own contract — it starts at root, holds the Details deep-link
/// target, and pops.
@MainActor
final class PopoverNavigatorTests: XCTestCase {

    func testDefaultPathIsRoot() {
        XCTAssertTrue(PopoverNavigator().path.isEmpty)   // reset-to-root default (consumer a)
    }

    func testDeepLinkTargetAndPop() {
        let nav = PopoverNavigator()
        nav.path = [.details]                            // the show-history deep-link target (consumer b)
        XCTAssertEqual(nav.path, [.details])
        nav.path.removeLast()                            // the "‹ Battery" back control
        XCTAssertTrue(nav.path.isEmpty)
    }
}
