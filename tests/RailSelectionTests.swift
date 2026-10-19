import XCTest
@testable import Battery

/// #30 stage 1 — the navigator-path → rail-tab mapping (spec §8). The channel itself is covered by
/// PopoverNavigatorTests; this pins what the view does with the path it is handed.
@MainActor
final class RailSelectionTests: XCTestCase {

    func testRootLandsOnNow() {
        XCTAssertEqual(RailSelection.tab(for: []), .now)          // every normal show (consumer a) and every close (c)
    }

    func testDetailsDeepLinkLandsOnDay() {
        XCTAssertEqual(RailSelection.tab(for: [.details]), .day)  // show-history quick action (consumer b)
    }

    func testRailOrderIsTheSpecOrder() {
        XCTAssertEqual(RailTab.allCases, [.now, .day, .energy, .health, .devices, .automation])
    }

    func testEveryTabHasATitleAndASymbol() {
        for tab in RailTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.symbol.isEmpty)
        }
    }
}
