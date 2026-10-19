import XCTest

/// G-7 · first-seen stamps. A registry id is unique for the boot, so a stamp is never re-issued: a walk
/// that returns nothing (a failed walk looks the same) must never make an old leaf "new".
final class LeafStampsTests: XCTestCase {
    private let keyboard = USBLeaf(registryID: 1, productName: "Magic Keyboard", vendorName: "Apple Inc.", kind: .keyboard)
    private let phone = USBLeaf(registryID: 2, productName: "iPhone", vendorName: "Apple Inc.", kind: .iphone)

    func testFirstWalkIsTheSeed() {
        var s = LeafStamps()
        XCTAssertNil(s.seedAt)
        s.observe([keyboard], at: 100)
        XCTAssertEqual(s.seedAt, 100)
        XCTAssertEqual(s.firstSeen(1), 100)
    }

    func testStampIsTheWalkThatFirstSawTheLeaf() {
        var s = LeafStamps()
        s.observe([keyboard], at: 100)
        s.observe([keyboard, phone], at: 160)
        s.observe([keyboard, phone], at: 220)
        XCTAssertEqual(s.firstSeen(1), 100)
        XCTAssertEqual(s.firstSeen(2), 160)
        XCTAssertEqual(s.seedAt, 100)
    }

    func testEmptyWalkDoesNotMakeOldLeavesNew() {
        var s = LeafStamps()
        s.observe([keyboard], at: 100)
        s.observe([], at: 160)
        s.observe([keyboard], at: 220)
        XCTAssertEqual(s.firstSeen(1), 100)
    }

    func testUnknownLeafHasNoStamp() {
        XCTAssertNil(LeafStamps().firstSeen(99))
    }

    func testCapacityEvictsOnlyDepartedLeavesOldestFirst() {
        var s = LeafStamps()
        s.observe([keyboard], at: 0)
        for i in 0..<(LeafStamps.capacity + 10) {
            s.observe([keyboard, USBLeaf(registryID: UInt64(1_000 + i), productName: "", vendorName: nil)],
                      at: TimeInterval(i + 1))
        }
        XCTAssertEqual(s.firstSeen(1), 0, "a leaf still on the bus is never evicted")
        XCTAssertNil(s.firstSeen(1_000), "the oldest departed leaf goes first")
        XCTAssertNotNil(s.firstSeen(UInt64(1_000 + LeafStamps.capacity + 9)))
    }
}
