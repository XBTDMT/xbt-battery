import XCTest
import AppKit

/// 31 §1.3 (c) / G-7 · the timing match: exactly one port starts sourcing and exactly one USB leaf is NEW —
/// first enumerated after the port's last present read (or after the launch seed) and no more than 130 s
/// before the port's first drawing read.
final class DeviceNamingTests: XCTestCase {
    private let keyboard = USBLeaf(registryID: 3, productName: "Magic Keyboard", vendorName: "Apple Inc.", kind: .keyboard)
    private let phone = USBLeaf(registryID: 7, productName: "iPhone", vendorName: "Apple Inc.", kind: .iphone)
    private let drive = USBLeaf(registryID: 8, productName: "T7 Shield", vendorName: "Samsung", kind: .massStorage)

    /// Seed at 1000 with the keyboard already on the bus, then the given walks.
    private func stamps(_ walks: [(TimeInterval, [USBLeaf])]) -> LeafStamps {
        var s = LeafStamps()
        s.observe([keyboard], at: 1_000)
        for (t, leaves) in walks { s.observe(leaves, at: t) }
        return s
    }

    private func match(_ s: LeafStamps, _ leaves: [USBLeaf], lastPresent: TimeInterval? = nil,
                       firstDrawing: TimeInterval, newly: Int = 1) -> USBLeaf? {
        DeviceNaming.timingMatch(stamps: s, leaves: leaves, portLastPresentAt: lastPresent,
                                 portFirstDrawingAt: firstDrawing, newlySourcingPortCount: newly)
    }

    func testLeafFirstSeenWhileThePortWasStillAbsentMatchesOnTheNextRead() {
        let s = stamps([(1_010, [keyboard, phone]), (1_060, [keyboard, phone])])
        XCTAssertEqual(match(s, [keyboard, phone], firstDrawing: 1_060), phone)
    }

    func testLeafOnTheSameReadAsTheElementMatches() {
        let s = stamps([(1_060, [keyboard, phone])])
        XCTAssertEqual(match(s, [keyboard, phone], firstDrawing: 1_060), phone)
    }

    func testWindowIs130SecondsInclusive() {
        let s = stamps([(1_010, [keyboard, phone])])
        XCTAssertEqual(match(s, [keyboard, phone], firstDrawing: 1_140), phone)
        XCTAssertNil(match(s, [keyboard, phone], firstDrawing: 1_141), "first seen > 130 s before the first drawing read")
    }

    /// Live evidence (2026-09-28): the iPhone shows as a leaf ~50-60 s BEFORE the battery record reports the
    /// port's power (the element lands on the next ~60 s refresh). That is inside the window.
    func testLeafStampedAboutSixtySecondsBeforeTheFirstDrawingReadMatches() {
        let s = stamps([(1_100, [keyboard, phone])])
        XCTAssertEqual(match(s, [keyboard, phone], firstDrawing: 1_160), phone)
    }

    func testLeafStampedJustOver130SecondsBeforeTheFirstDrawingReadDoesNotMatch() {
        let s = stamps([(1_100, [keyboard, phone])])
        XCTAssertNil(match(s, [keyboard, phone], firstDrawing: 1_231), "131 s before")
    }

    func testWindowBoundaryFractionalSecondsPinBothSides() {
        let s = stamps([(1_100, [keyboard, phone])])
        XCTAssertEqual(match(s, [keyboard, phone], firstDrawing: 1_230), phone, "exactly 130 s is inside")
        XCTAssertNil(match(s, [keyboard, phone], firstDrawing: 1_230.001), "130.001 s is outside")
    }

    func testLeafFirstSeenAfterTheFirstDrawingReadDoesNotMatch() {
        let s = stamps([(1_070, [keyboard, phone])])
        XCTAssertNil(match(s, [keyboard, phone], firstDrawing: 1_060))
    }

    func testLeafStampedAtTheLaunchSeedIsNotNew() {
        XCTAssertNil(match(stamps([]), [keyboard], firstDrawing: 1_060))
    }

    func testLeafOlderThanThePortsLastPresentReadDoesNotMatch() {
        let s = stamps([(1_010, [keyboard, phone])])
        XCTAssertNil(match(s, [keyboard, phone], lastPresent: 1_030, firstDrawing: 1_090))
    }

    func testTwoNewLeavesDoNotMatch() {
        let s = stamps([(1_010, [keyboard, phone, drive])])
        XCTAssertNil(match(s, [keyboard, phone, drive], firstDrawing: 1_060))
    }

    func testTwoNewlySourcingPortsDoNotMatch() {
        let s = stamps([(1_010, [keyboard, phone])])
        XCTAssertNil(match(s, [keyboard, phone], firstDrawing: 1_060, newly: 2))
    }

    /// A port whose last present read predates the first leaf walk: the seed is the later floor, so a leaf
    /// stamped exactly at the seed (already on the bus at launch) is not new.
    func testLastPresentEarlierThanTheSeedStillUsesTheSeedAsFloor() {
        let s = stamps([])   // keyboard stamped at seed 1000
        XCTAssertNil(match(s, [keyboard], lastPresent: 900, firstDrawing: 1_060))
        XCTAssertEqual(s.seedAt, 1_000)
    }

    func testLastPresentLaterThanTheSeedIsTheFloor() {
        let s = stamps([(1_010, [keyboard, phone])])
        XCTAssertEqual(match(s, [keyboard, phone], lastPresent: 1_005, firstDrawing: 1_060), phone)
    }

    func testSoleNewNamelessLeafMatchesAndIsNamedUnnamedWithItsRealKind() {
        let nameless = USBLeaf(registryID: 11, productName: "", vendorName: nil, kind: .massStorage)
        let s = stamps([(1_010, [keyboard, nameless])])
        let matched = match(s, [keyboard, nameless], firstDrawing: 1_060)
        XCTAssertEqual(matched, nameless)
        XCTAssertEqual(PortName(leaf: matched!), PortName(name: "USB-C device", kind: .massStorage))
    }

    func testBlankOrWhitespaceProductNameFallsBackAndAPaddedNameIsTrimmed() {
        for blank in ["  ", "\n", " \t\n ", ""] {
            let leaf = USBLeaf(registryID: 12, productName: blank, vendorName: nil, kind: .iphone)
            XCTAssertEqual(PortName(leaf: leaf), PortName(name: "USB-C device", kind: .iphone), "\(blank.debugDescription)")
        }
        XCTAssertEqual(PortName(leaf: USBLeaf(registryID: 13, productName: " iPhone ", vendorName: nil, kind: .iphone)),
                       PortName(name: "iPhone", kind: .iphone))
    }

    func testPortNameFromALeaf() {
        XCTAssertEqual(PortName(leaf: drive), PortName(name: "T7 Shield", kind: .massStorage))
        XCTAssertEqual(PortName(leaf: USBLeaf(registryID: 9, productName: "", vendorName: nil)).name, "USB-C device")
        XCTAssertEqual(DeviceNaming.unnamedLabel, "USB-C device")
    }

    func testSymbolsByKindAndEveryOneResolves() {
        XCTAssertEqual(DeviceNaming.symbol(for: .iphone), "iphone")
        XCTAssertEqual(DeviceNaming.symbol(for: .massStorage), "externaldrive.fill")
        XCTAssertEqual(DeviceNaming.symbol(for: .keyboard), "keyboard")
        XCTAssertEqual(DeviceNaming.symbol(for: .other), "cable.connector")
        XCTAssertEqual(DeviceNaming.symbol(for: nil), "cable.connector")
        for s in DeviceNaming.allSymbols {
            XCTAssertNotNil(NSImage(systemSymbolName: s, accessibilityDescription: nil), "\(s) must exist on this OS")
        }
    }
}
