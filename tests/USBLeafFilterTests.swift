import XCTest

/// 31 §1.3 · the IOUSB leaf filter: hubs and billboard devices are never leaves; every other device is,
/// named or not (a nameless device still counts toward G-7's "exactly one new leaf").
final class USBLeafFilterTests: XCTestCase {

    private func node(_ id: UInt64, _ name: String?, cls: Int? = 0, ifaces: [Int] = [],
                      children: Bool = false, vendor: String? = "Apple Inc.", vendorID: Int? = nil) -> USBNode {
        USBNode(registryID: id, productName: name, vendorName: vendor, deviceClass: cls,
                interfaceClasses: ifaces, hasChildDevices: children, vendorID: vendorID)
    }

    func testHubsAreFilteredByClassInterfaceAndChildren() {
        let leaves = USBLeafFilter.leaves([node(1, "USB2.0 Hub", cls: 9), node(2, "Dock", children: true),
                                           node(3, "Hub Interface", ifaces: [9]), node(4, "iPhone")])
        XCTAssertEqual(leaves.map(\.registryID), [4])
    }

    func testBillboardIsFilteredByClassInterfaceAndName() {
        let leaves = USBLeafFilter.leaves([node(5, "USB-C Billboard", cls: 0), node(6, "Adapter", cls: 0x11),
                                           node(7, "Adapter 2", ifaces: [0x11])])
        XCTAssertTrue(leaves.isEmpty)
    }

    func testKindFromNameAndInterfaces() {
        let leaves = USBLeafFilter.leaves([node(10, "iPhone"), node(11, "T7 Shield", ifaces: [8]),
                                           node(12, "Magic Keyboard", ifaces: [3]), node(13, "USB Receiver", ifaces: [3])])
        XCTAssertEqual(leaves.map(\.kind), [.iphone, .massStorage, .keyboard, .other])
    }

    func testIPhoneNeedsAnAppleVendor() {
        let leaves = USBLeafFilter.leaves([
            node(30, "iPhone"),                                        // Apple by vendor name (no numeric id)
            node(31, "iPhone", vendor: nil, vendorID: 0x05AC),         // Apple by numeric id
            node(32, "iPhone Dock", vendor: "Acme Docks"),             // third party: not a phone
            node(33, "iPhone Dock", vendor: "Apple Inc.", vendorID: 0x1234), // the numeric id wins over the name
            node(34, "iPad")])                                         // G-5 only corroborates iPhones
        XCTAssertEqual(leaves.map(\.kind), [.iphone, .iphone, .other, .other, .other])
    }

    func testMassStorageByDeviceClass() {
        XCTAssertEqual(USBLeafFilter.leaves([node(40, "Disk", cls: 8)]).first?.kind, .massStorage)
    }

    func testChildDevicesMakeAHubEvenWithoutAHubClass() {
        XCTAssertTrue(USBLeafFilter.leaves([node(41, "Thing", cls: 0xEF, children: true)]).isEmpty)
    }

    func testBillboardNameMatchIsCaseInsensitive() {
        XCTAssertTrue(USBLeafFilter.leaves([node(42, "USB-C BillBoard"), node(43, "BILLBOARD DEVICE")]).isEmpty)
    }

    func testHubIsNeverDecidedByNameAlone() {
        // Hubs are recognised by class 9, a hub interface or child devices — never by the word "hub" — so a
        // mixed-case "USB2.0 HUB" is filtered when it carries the class, and a device merely named "Hub" is not.
        XCTAssertTrue(USBLeafFilter.leaves([node(44, "USB2.0 HUB", cls: 9)]).isEmpty)
        XCTAssertEqual(USBLeafFilter.leaves([node(45, "Hub Lamp")]).count, 1)
    }

    func testNamelessLeafIsKeptWithAnEmptyName() {
        let leaves = USBLeafFilter.leaves([node(20, nil)])
        XCTAssertEqual(leaves.count, 1, "a nameless device still counts toward 'exactly one new leaf'")
        XCTAssertEqual(leaves.first?.productName, "")
        XCTAssertEqual(leaves.first?.kind, .other)
    }

    func testDefaultKindKeepsTheThreeArgumentInit() {
        XCTAssertEqual(USBLeaf(registryID: 1, productName: "x", vendorName: nil).kind, .other)
    }

    func testSettableEnumeratorReturnsWhatWasSet() {
        let e = SettableUSBLeafEnumerator()
        XCTAssertEqual(e.leaves(), [])
        let leaf = USBLeaf(registryID: 1, productName: "iPhone", vendorName: "Apple Inc.", kind: .iphone)
        e.set([leaf])
        XCTAssertEqual(e.leaves(), [leaf])
        e.setFailed()
        XCTAssertNil(e.leaves(), "a failed walk is nil, never an empty bus")
        e.set([])
        XCTAssertEqual(e.leaves(), [])
    }

    func testLiveWalkReturnsOnlyLeaves() {
        // The build Mac's IOUSB plane may be empty; the walk must return (never trap), and nothing it
        // returns may be a billboard.
        let leaves = LiveUSBLeafEnumerator().leaves() ?? []
        XCTAssertTrue(leaves.allSatisfy { !$0.productName.localizedCaseInsensitiveContains("billboard") })
    }
}
