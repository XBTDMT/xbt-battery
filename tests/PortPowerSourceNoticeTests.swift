import XCTest

private final class NoticeClocks: @unchecked Sendable {
    private let lock = NSLock()
    private var mono: TimeInterval = 1_000
    func advance(_ s: TimeInterval) { lock.lock(); mono += s; lock.unlock() }
    var value: TimeInterval { lock.lock(); defer { lock.unlock() }; return mono }
    var clocks: MonotonicClocks { MonotonicClocks(monotonicRaw: { self.value }, uptimeRaw: { self.value - 100 }) }
}

/// 31 §2.2 · the notice through the real port source: named by the per-read stamps (no fire-time walk),
/// quiet at launch, ExternalConnected unread = no information, aggregated, tracked on AC too.
@MainActor
final class PortPowerSourceNoticeTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var time: NoticeClocks!
    private var usb: SettableUSBLeafEnumerator!
    private var src: PortPowerSource!
    private var notices: [[DeviceNotice]] = []
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let iPhone = USBLeaf(registryID: 0x1000_2001, productName: "iPhone", vendorName: "Apple Inc.", kind: .iphone)
    private let keyboard = USBLeaf(registryID: 0x1000_2002, productName: "Magic Keyboard", vendorName: "Apple Inc.", kind: .keyboard)

    override func setUp() {
        super.setUp()
        suite = "PortPowerSourceNoticeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        time = NoticeClocks()
        usb = SettableUSBLeafEnumerator()
        notices = []
        let fixedNow = now
        src = PortPowerSource(defaults: defaults, now: { fixedNow }, clocks: time.clocks, usb: usb,
                              osBuild: { "26B5091g" })
        src.onDeviceNotice = { [weak self] batch in self?.notices.append(batch) }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// `badElement` appends a `PowerOutDetails` element the parser drops (no `FilteredPower`).
    private func read(_ ports: [(Int, Int)], leaves: [USBLeaf], step: Int, onAC: Bool? = false, badElement: Bool = false) {
        if step > 0 { time.advance(60) }
        usb.set(leaves)
        var frame = portTestFrame(update: Int(now.timeIntervalSince1970) - 200 + 60 * step, onAC: onAC, ports: ports, step: step)
        if badElement, case .read(var props) = frame {
            props["PowerOutDetails"] = ((props["PowerOutDetails"] as? [Any]) ?? []) + [["PortIndex": 9] as [String: Any]]
            frame = .read(props)
        }
        src.ingest(frame)
    }

    func testPlugInAfterAFreshFrameFiresOneNamedNotice() {
        read([], leaves: [], step: 0)
        read([], leaves: [], step: 1)
        read([(2, 9_200)], leaves: [iPhone], step: 2)
        XCTAssertEqual(notices, [[DeviceNotice(title: "iPhone",
                                               subline: "Drawing 9.2 W · ≈\u{00A0}15% of battery per hour",
                                               spoken: "iPhone is drawing power from your Mac. Drawing 9.2 W, about 15% of battery per hour",
                                               symbol: "iphone")]])
    }

    func testLaunchAndTheFirstFreshFrameAreQuiet() {
        read([(2, 9_200)], leaves: [iPhone], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        read([(2, 9_300)], leaves: [iPhone], step: 2)
        XCTAssertTrue(notices.isEmpty)
    }

    func testUnreadExternalConnectedFiresNothing() {
        read([], leaves: [], step: 0, onAC: nil)
        read([], leaves: [], step: 1, onAC: nil)
        read([(2, 9_200)], leaves: [iPhone], step: 2, onAC: nil)
        XCTAssertTrue(notices.isEmpty)
    }

    func testTrackedOnACToo() {
        read([], leaves: [], step: 0, onAC: true)
        read([], leaves: [], step: 1, onAC: true)
        read([(2, 9_200)], leaves: [iPhone], step: 2, onAC: true)
        XCTAssertEqual(notices.count, 1, "only the SHOWING is gated on battery (the HUD coordinator)")
    }

    func testTwoDevicesOnOneReadAggregateIntoOneNotice() {
        read([], leaves: [], step: 0)
        read([], leaves: [], step: 1)
        read([(2, 9_200), (1, 4_500)], leaves: [iPhone, keyboard], step: 2)
        XCTAssertEqual(notices, [[DeviceNotice(title: "2 devices",
                                               subline: "Drawing 13.7 W · ≈\u{00A0}22% of battery per hour",
                                               spoken: "2 devices are drawing power from your Mac. Drawing 13.7 W, about 22% of battery per hour")]])
    }

    func testFailedReadsInBetweenChangeNothing() {
        read([], leaves: [], step: 0)
        read([], leaves: [], step: 1)
        src.ingest(.unread)
        src.ingest(.unread)
        read([(2, 9_200)], leaves: [iPhone], step: 2)
        XCTAssertEqual(notices.count, 1)
    }

    // MARK: - what the brief did not pin (disk gaps)

    func testAnUnnamedPortFallsBackToTheUnnamedLabelAndTheCable() {
        read([], leaves: [], step: 0)
        read([], leaves: [], step: 1)
        read([(2, 9_200)], leaves: [], step: 2)
        XCTAssertEqual(notices.first?.first?.title, DeviceNaming.unnamedLabel)
        XCTAssertEqual(notices.first?.first?.symbol, "cable.connector")
    }

    func testTheNoticeNamesThePortExactlyAsTheRowDoes() {
        read([], leaves: [], step: 0)
        read([], leaves: [], step: 1)
        read([(2, 9_200)], leaves: [iPhone], step: 2)
        XCTAssertEqual(src.display.rows.map(\.name), ["iPhone"])
        XCTAssertEqual(notices.first?.first?.title, src.display.rows[0].name)
        XCTAssertEqual(notices.first?.first?.symbol, src.display.rows[0].symbol)
    }

    func testTheNoticeRateIsTheDevicesCostLineRate() throws {
        read([], leaves: [], step: 0)
        read([], leaves: [], step: 1)
        read([(2, 9_200)], leaves: [iPhone], step: 2)
        read([(2, 9_200)], leaves: [iPhone], step: 3)   // the pair now spans two frames on battery
        let line = try XCTUnwrap(src.costLine, "the fixture must produce a cost line for the comparison to mean anything")
        let subline = try XCTUnwrap(notices.first?.first?.subline)
        XCTAssertTrue(subline.contains("\(line.percentPerHour)% of battery per hour"),
                      "notice '\(subline)' must carry the row's \(line.percentPerHour)%")
    }

    func testAReadThatDroppedAnElementCannotRearmAPortThatOnlyLooksAbsent() {
        // Port 2 is live and drawing; from step 2 its element is unparseable (so it is "absent" to the parser)
        // for 180 s — longer than the 120 s re-arm — then it parses again. A failed read is no information:
        // that is NOT a plug-in.
        read([(2, 9_200)], leaves: [iPhone], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        read([(1, 0)], leaves: [iPhone], step: 2, badElement: true)
        read([(1, 0)], leaves: [iPhone], step: 3, badElement: true)
        read([(1, 0)], leaves: [iPhone], step: 4, badElement: true)
        read([(2, 9_200), (1, 0)], leaves: [iPhone], step: 5)
        XCTAssertTrue(notices.isEmpty)
    }

    func testARealUnplugForLongerThanTheRearmThenPlugInFires() {
        read([(2, 9_200)], leaves: [iPhone], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        read([], leaves: [], step: 2)
        read([], leaves: [], step: 3)
        read([], leaves: [], step: 4)
        read([(2, 9_200)], leaves: [iPhone], step: 5)
        XCTAssertEqual(notices.count, 1)
    }
}
