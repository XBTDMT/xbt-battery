import XCTest
import AppKit

/// #30 R8 / §14-B6: the device icon rule. The crux is the LAST assertion group — every symbol the
/// table can return must resolve via `NSImage(systemSymbolName:)` on this OS, which is exactly the
/// check the old `trackpad` mapping never had (it rendered nil = a blank row).
final class DeviceIconTests: XCTestCase {

    // MARK: - name rules

    func testAirPodsVariantsByName() {
        XCTAssertEqual(DeviceIcon.symbol(for: .airpods, name: "Alex’s AirPods Pro"), "airpodspro")
        XCTAssertEqual(DeviceIcon.symbol(for: .airpods, name: "AirPods Pro 2"), "airpodspro")
        XCTAssertEqual(DeviceIcon.symbol(for: .airpods, name: "AirPods 3"), "airpods.gen3")
        XCTAssertEqual(DeviceIcon.symbol(for: .airpods, name: "AirPods (3rd generation)"), "airpods.gen3")
        XCTAssertEqual(DeviceIcon.symbol(for: .airpods, name: "Alex’s AirPods"), "airpods")
        XCTAssertEqual(DeviceIcon.symbol(for: .airpods, name: "Alex’s AirPods #3"), "airpods",
                       "a numbered pair is not the third generation")
        XCTAssertEqual(DeviceIcon.symbol(for: .airpodsMax, name: "AirPods Max"), "airpodsmax")
    }

    func testBeatsByName() {
        XCTAssertEqual(DeviceIcon.symbol(for: .headphones, name: "Beats Studio Pro"), "beats.headphones")
        XCTAssertEqual(DeviceIcon.symbol(for: .headphones, name: "beats solo"), "beats.headphones")
        XCTAssertEqual(DeviceIcon.symbol(for: .generic, name: "Beats Fit"), "beats.headphones")
        XCTAssertEqual(DeviceIcon.symbol(for: .headphones, name: "SMSL BT4.2"), "headphones")
    }

    func testClassOnlyRules() {
        XCTAssertEqual(DeviceIcon.symbol(for: .mouse, name: "Magic Mouse"), "magicmouse")
        XCTAssertEqual(DeviceIcon.symbol(for: .keyboard, name: "Magic Keyboard"), "keyboard")
        XCTAssertEqual(DeviceIcon.symbol(for: .trackpad, name: "Magic Trackpad"), "rectangle.and.hand.point.up.left",
                       "§14-B6: `trackpad` is not a symbol on this OS")
        XCTAssertEqual(DeviceIcon.symbol(for: .applewatch, name: "Watch"), "applewatch")
        XCTAssertEqual(DeviceIcon.symbol(for: .iphone, name: "iPhone"), "iphone")
        XCTAssertEqual(DeviceIcon.symbol(for: .generic, name: "Unknown thing"), "battery.100")
    }

    func testLegacyClassOnlyAccessorDelegates() {
        for cls in DeviceClass.allCases {
            XCTAssertEqual(cls.sfSymbol, DeviceIcon.symbol(for: cls, name: ""))
        }
        XCTAssertNotEqual(DeviceClass.trackpad.sfSymbol, "trackpad", "the old blank mapping is gone")
    }

    // MARK: - the totality gate: every returned symbol exists on this OS

    /// Every class × a spread of sample names, plus the declared `allSymbols` table. A nil here is a
    /// blank row in the Devices tab — the exact defect §14-B6 recorded.
    func testEverySymbolResolvesOnThisOS() {
        let sampleNames = ["", "AirPods Pro", "AirPods 3", "AirPods (3rd generation)", "AirPods Max",
                           "Beats Studio", "Magic Mouse", "Magic Keyboard", "Magic Trackpad",
                           "Alex’s Watch", "iPhone", "SMSL BT4.2", "Some Gadget"]
        var seen = Set<String>()
        for cls in DeviceClass.allCases {
            for name in sampleNames {
                let sym = DeviceIcon.symbol(for: cls, name: name)
                XCTAssertFalse(sym.isEmpty, "\(cls) / \(name) must never be blank")
                XCTAssertNotNil(NSImage(systemSymbolName: sym, accessibilityDescription: nil),
                                "\(cls) / \"\(name)\" → \(sym) does not exist as an SF Symbol on this OS")
                seen.insert(sym)
            }
        }
        for sym in DeviceIcon.allSymbols {
            XCTAssertNotNil(NSImage(systemSymbolName: sym, accessibilityDescription: nil), "\(sym) missing on this OS")
        }
        // The samples exercise the whole table — a new branch must be reachable from a sample name.
        XCTAssertEqual(seen, Set(DeviceIcon.allSymbols), "samples must cover every symbol the table can return")
    }

    func testTheOldTrackpadSymbolReallyIsAbsentHere() {
        // Documents WHY the mapping changed; if Apple ships `trackpad` later this test tells us.
        XCTAssertNil(NSImage(systemSymbolName: "trackpad", accessibilityDescription: nil))
    }
}
