import XCTest
import CoreGraphics
@testable import Battery

/// #29 D-5 (A1/F4) — the status-item anchor helper: a normal button frame yields a top-trailing anchor
/// under the item; every degenerate frame (nil / zero / non-finite / off-screen) falls back to the
/// screen's top-trailing corner, and the result is NEVER (0,0).
final class StatusItemAnchorTests: XCTestCase {

    // A 1440×900 screen with the menu bar at the top; a status item near the top-right.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let panel = CGSize(width: 240, height: 44)

    func testNormalButtonAnchorsCenteredUnderItem() {
        let button = CGRect(x: 1180, y: 878, width: 40, height: 22)   // near the top-right, room to center
        let p = StatusItemAnchor.topLeft(buttonFrame: button, screenFrame: screen, panelSize: panel)
        XCTAssertEqual(p.x, button.midX - panel.width / 2, accuracy: 0.5)  // centered under the item's center-x
        XCTAssertLessThan(p.y, button.minY)                               // sits below the button
        XCTAssertGreaterThanOrEqual(p.x, screen.minX)                     // on-screen
        XCTAssertLessThanOrEqual(p.x, screen.maxX - panel.width)
    }

    func testNilButtonFallsBackToTopTrailing() {
        let p = StatusItemAnchor.topLeft(buttonFrame: nil, screenFrame: screen, panelSize: panel)
        XCTAssertEqual(p.x, screen.maxX - panel.width - 6, accuracy: 0.5)
        XCTAssertEqual(p.y, screen.maxY - 6, accuracy: 0.5)
        XCTAssertFalse(p.x == 0 && p.y == 0)
    }

    func testZeroSizeButtonFallsBack() {
        let p = StatusItemAnchor.topLeft(buttonFrame: .zero, screenFrame: screen, panelSize: panel)
        XCTAssertEqual(p.x, screen.maxX - panel.width - 6, accuracy: 0.5)
        XCTAssertFalse(p.x == 0 && p.y == 0)
    }

    func testNonFiniteButtonFallsBack() {
        let bad = CGRect(x: CGFloat.nan, y: 878, width: 40, height: 22)
        let p = StatusItemAnchor.topLeft(buttonFrame: bad, screenFrame: screen, panelSize: panel)
        XCTAssertEqual(p.x, screen.maxX - panel.width - 6, accuracy: 0.5)
        XCTAssertFalse(p.x.isNaN || p.y.isNaN)
    }

    func testOffScreenButtonFallsBack() {
        let offscreen = CGRect(x: 5000, y: 5000, width: 40, height: 22)   // on another (absent) display
        let p = StatusItemAnchor.topLeft(buttonFrame: offscreen, screenFrame: screen, panelSize: panel)
        XCTAssertEqual(p.x, screen.maxX - panel.width - 6, accuracy: 0.5)
    }

    func testNeverOrigin() {
        // Even a pathological button at the origin must not yield (0,0).
        let atOrigin = CGRect(x: 0, y: 0, width: 0, height: 0)
        let p = StatusItemAnchor.topLeft(buttonFrame: atOrigin, screenFrame: screen, panelSize: panel)
        XCTAssertFalse(p.x == 0 && p.y == 0)
    }
}
