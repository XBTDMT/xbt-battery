import XCTest

/// Clocks the naming tests drive by hand (MONOTONIC_RAW and UPTIME_RAW advance together: no sleep).
private final class NamingClocks: @unchecked Sendable {
    private let lock = NSLock()
    private var mono: TimeInterval = 1_000
    func advance(_ s: TimeInterval) { lock.lock(); mono += s; lock.unlock() }
    var value: TimeInterval { lock.lock(); defer { lock.unlock() }; return mono }
    var clocks: MonotonicClocks { MonotonicClocks(monotonicRaw: { self.value }, uptimeRaw: { self.value - 100 }) }
}

/// One AppleSmartBattery frame as the monitor's reader returns it (keys as captured 2026-09-28, spec §1).
func portTestFrame(update: Int, onAC: Bool?, ports: [(Int, Int)], step: Int) -> DiagnosticsRead {
    var props: [String: Any] = [
        "UpdateTime": update,
        "AppleRawMaxCapacity": 5_435,
        "BatteryData": ["FullChargeCapacity": 5_435, "RemainingCapacity": 1_739] as [String: Any],
        "PowerTelemetryData": ["SystemPowerIn": onAC == true ? 62_741 : 0, "SystemLoad": 57_141, "BatteryPower": 5_600,
                               "AccumulatedBatteryPower": 1_000_000_000 + 336_000 * step,
                               "BatteryPowerAccumulatorCount": 40_000 + 60 * step,
                               "AccumulatedBatteryDischarge": -1_200_000_000 - 1_668_000 * (onAC == false ? step : 0),
                               "BatteryDischargeAccumulatorCount": 50_000 + (onAC == false ? 60 * step : 0)] as [String: Any],
        "PowerDistribution": ["IPDInputPower": 65_000] as [String: Any],
        BatteryTelemetryParser.packPropertiesKey: ["BankCount": 3] as [String: Any],
    ]
    if let onAC { props["ExternalConnected"] = onAC }
    if !ports.isEmpty {
        props["PowerOutDetails"] = ports.map { (index, mW) -> [String: Any] in
            ["PortIndex": index, "PortType": 0, "PowerState": 0, "Watts": mW, "FilteredPower": mW,
             "Current": mW * 1_000 / 5_190, "AdapterVoltage": 5_190, "ConfiguredVoltage": 5_000,
             "ConfiguredCurrent": 3_000, "PDPowermW": 15_000, "AccumulatedPower": 169_827 + 1_000 * step,
             "AccumulatorCount": 15 + step, "AccumulatorErrorCount": 0]
        }
    }
    return .read(props)
}

/// 31 §1.3 · names through the real port source: the per-read stamp walk (G-7), (b) from the phone, the
/// fallback label, and "a failed walk never names anything".
@MainActor
final class PortPowerSourceNamingTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var time: NamingClocks!
    private var usb: SettableUSBLeafEnumerator!
    private var src: PortPowerSource!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let iPhone = USBLeaf(registryID: 0x1000_1001, productName: "iPhone", vendorName: "Apple Inc.", kind: .iphone)
    private let keyboard = USBLeaf(registryID: 0x1000_1002, productName: "Magic Keyboard", vendorName: "Apple Inc.", kind: .keyboard)

    override func setUp() {
        super.setUp()
        suite = "PortPowerSourceNamingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        time = NamingClocks()
        usb = SettableUSBLeafEnumerator()
        let fixedNow = now
        src = PortPowerSource(defaults: defaults, now: { fixedNow }, clocks: time.clocks, usb: usb,
                              osBuild: { "26B5091g" })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// One read, 60 s after the previous one (step 0 = the launch read).
    private func read(_ ports: [(Int, Int)], leaves: [USBLeaf], step: Int) {
        if step > 0 { time.advance(60) }
        usb.set(leaves)
        src.ingest(portTestFrame(update: Int(now.timeIntervalSince1970) - 200 + 60 * step, onAC: true, ports: ports, step: step))
    }

    private var names: [String] { src.display.rows.map(\.name) }

    func testTimingMatchNamesTheIPhone() {
        read([], leaves: [], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        XCTAssertEqual(names, ["iPhone"])
        XCTAssertEqual(src.display.rows.first?.symbol, "iphone")
        XCTAssertEqual(src.display.rows.first?.state, .drawing(tenthsW: 92))
    }

    func testLeafThatArrivesOneReadBeforeTheElementStillMatches() {
        read([], leaves: [], step: 0)
        read([], leaves: [iPhone], step: 1)
        read([(2, 9_200)], leaves: [iPhone], step: 2)
        XCTAssertEqual(names, ["iPhone"])
    }

    func testPortDrawingAtLaunchStaysUnnamed() {
        read([(2, 9_200)], leaves: [iPhone], step: 0)
        XCTAssertEqual(names, ["USB-C device"])
    }

    func testTwoPortsStartingOnOneReadStayUnnamed() {
        read([], leaves: [], step: 0)
        read([(1, 4_500), (2, 9_200)], leaves: [iPhone, keyboard], step: 1)
        XCTAssertEqual(names, ["USB-C device", "USB-C device"])
    }

    func testAClaimedLeafIsNotReusedForTheNextPort() {
        read([], leaves: [], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        read([(2, 9_200), (1, 1_000)], leaves: [iPhone, keyboard], step: 2)
        XCTAssertEqual(names, ["iPhone", "Magic Keyboard"])
    }

    func testNameIsDroppedWhenThePortGoesAbsent() {
        read([], leaves: [], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        read([], leaves: [iPhone], step: 2)
        read([(2, 9_200)], leaves: [iPhone], step: 3)
        XCTAssertEqual(names, ["USB-C device"], "back on the port, but no NEW leaf")
    }

    func testEmptyWalkNeverNamesAChargeOnlyDevice() {
        read([], leaves: [keyboard], step: 0)
        read([], leaves: [], step: 1)
        read([(3, 5_000)], leaves: [keyboard], step: 2)
        XCTAssertEqual(names, ["USB-C device"])
    }

    // MARK: final review M1 · a failed walk is no information

    /// A failed FIRST walk must not seed the stamps: the next good walk would stamp every leaf already on the bus
    /// (a keyboard plugged in before launch) as new, and a charge-only port drawing within 130 s would take its name.
    func testAFailedFirstWalkNeverNamesAChargeOnlyPortAfterAnOldKeyboard() {
        usb.setFailed()
        src.ingest(portTestFrame(update: Int(now.timeIntervalSince1970) - 200, onAC: true, ports: [], step: 0))
        read([], leaves: [keyboard], step: 1)                                       // first GOOD walk: the keyboard
        read([(3, 5_000)], leaves: [keyboard], step: 2)                             // charge-only port, 60 s later
        XCTAssertEqual(names, ["USB-C device"])
        XCTAssertNil(src.names[3])
    }

    /// Same, with the port starting on the very read of the first good walk.
    func testAFailedFirstWalkThenAPortOnTheFirstGoodWalkStaysUnnamed() {
        usb.setFailed()
        src.ingest(portTestFrame(update: Int(now.timeIntervalSince1970) - 200, onAC: true, ports: [], step: 0))
        read([(3, 5_000)], leaves: [keyboard], step: 1)
        XCTAssertEqual(names, ["USB-C device"])
    }

    /// A failed walk mid-run neither stamps nor matches, and a leaf that really arrives is still named later.
    func testAFailedWalkOnTheDrawingReadNamesNothing() {
        read([], leaves: [keyboard], step: 0)
        usb.setFailed()
        time.advance(60)
        src.ingest(portTestFrame(update: Int(now.timeIntervalSince1970) - 200 + 60, onAC: true, ports: [(3, 5_000)], step: 1))
        XCTAssertNil(src.names[3])
        read([(3, 5_000)], leaves: [keyboard, iPhone], step: 2)
        XCTAssertNil(src.names[3], "the timing match runs only on the port's first drawing read")
    }

    func testRefreshLeavesIgnoresAFailedWalk() {
        read([], leaves: [], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        usb.setFailed()
        src.refreshLeaves()
        XCTAssertEqual(names, ["iPhone"])
    }

    func testPhoneOverUSBNamesTheOnlySourcingPort() {
        read([(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(PhoneLink(percent: 45, charging: true, usbPowered: true, readAt: time.value))
        XCTAssertEqual(names, ["iPhone"])
        XCTAssertEqual(src.display.rows.first?.detail, "· cable · 45% \u{26A1}\u{FE0E}")
        XCTAssertTrue(src.display.phoneInPowered)
    }

    func testPhoneWithTwoUnnamedPortsBecomesItsOwnRow() {
        read([(1, 6_100), (2, 4_200)], leaves: [iPhone], step: 0)
        src.notePhone(PhoneLink(percent: 33, charging: true, usbPowered: true, readAt: time.value))
        XCTAssertEqual(src.display.rows.first?.state, .phonePortUnknown)
        XCTAssertTrue(src.display.oneIsPhoneCaption)
    }

    func testRefreshLeavesDropsANameWhoseLeafLeft() {
        read([], leaves: [], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        usb.set([keyboard])
        src.refreshLeaves()
        XCTAssertEqual(names, ["USB-C device"])
    }

    func testRefreshLeavesIgnoresAnEmptyWalk() {
        read([], leaves: [], step: 0)
        read([(2, 9_200)], leaves: [iPhone], step: 1)
        usb.set([])
        src.refreshLeaves()
        XCTAssertEqual(names, ["iPhone"])
    }

    func testUnreadAfterSeenSaysCouldntRead() {
        read([(2, 9_200)], leaves: [], step: 0)
        src.ingest(.unread)
        XCTAssertEqual(src.display.visibility, .unread)
        XCTAssertTrue(src.display.rows.isEmpty)
    }

    // MARK: carried findings (S4.5 brief)

    /// One read `seconds` after the previous one, optionally with an element the parser drops (no FilteredPower).
    private func read(after seconds: TimeInterval, _ ports: [(Int, Int)], leaves: [USBLeaf], step: Int, badElement: Bool = false) {
        time.advance(seconds)
        usb.set(leaves)
        guard case .read(var props) = portTestFrame(update: Int(now.timeIntervalSince1970) - 200 + step, onAC: true,
                                                    ports: ports, step: step) else { return XCTFail("frame") }
        if badElement {
            var raw = (props["PowerOutDetails"] as? [Any]) ?? []
            raw.append(["PortIndex": 2, "PortType": 0] as [String: Any])
            props["PowerOutDetails"] = raw
        }
        src.ingest(.read(props))
    }

    private let reMarkable = USBLeaf(registryID: 0x1000_1003, productName: "Paper Pro", vendorName: "reMarkable", kind: .other)

    /// Owner's live run 2026-09-28, replayed as measured: iPhone leaf 51 s before port 2's element; the
    /// reMarkable leaf 61 s before port 3's. T = the read that first sees the iPhone. At port 3's read the
    /// iPhone leaf is 132 s old, so the 130 s window ALONE already rejects it: this pins the live timeline,
    /// not the claimed-leaf filter (that is `testClaimedLeafFilterAloneKeepsPort3FromTheIPhone`).
    func testLiveReplay_MeasuredTimeline() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [], leaves: [iPhone], step: 1)                                  // T: iPhone leaf appears
        read(after: 51, [(2, 9_200)], leaves: [iPhone], step: 2)                        // T+51: port 2 draws
        XCTAssertEqual(names, ["iPhone"])
        read(after: 20, [(2, 9_200)], leaves: [iPhone, reMarkable], step: 3)            // T+71: reMarkable leaf
        read(after: 61, [(2, 9_200), (3, 6_000)], leaves: [iPhone, reMarkable], step: 4) // T+132: port 3 draws
        XCTAssertEqual(names, ["iPhone", "Paper Pro"])
    }

    /// Both leaves are new before port 2 draws: two candidates, so never a guess.
    func testLiveReplay_TwoNewLeavesBeforeTheFirstPortDrawsFallBackToTheGenericLabel() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [], leaves: [iPhone], step: 1)                                  // T
        read(after: 40, [], leaves: [iPhone, reMarkable], step: 2)                      // T+40: reMarkable leaf
        read(after: 11, [(2, 9_200)], leaves: [iPhone, reMarkable], step: 3)            // T+51: port 2 draws
        XCTAssertEqual(names, ["USB-C device"])
    }

    /// (a): newlySourcingPortCount is this read's count — a second port arriving on the same read as the
    /// first stays unnamed even with exactly one fresh leaf on the bus.
    func testNewlySourcingCountIsPerReadNotPerEpisode() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(1, 4_500), (2, 9_200)], leaves: [iPhone], step: 1)
        XCTAssertEqual(names, ["USB-C device", "USB-C device"])
    }

    /// S3.4 review M3: a partly bad element hides its port for one read; the name survives when the port is
    /// back on the very next good read with the same leaf still on the bus.
    func testPartlyBadElementKeepsTheStoredNameWhenThePortReturnsWithTheSameLeaf() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 1)
        read(after: 60, [(1, 1_000)], leaves: [iPhone], step: 2, badElement: true)      // port 2's element unparseable
        read(after: 60, [(1, 1_000), (2, 9_200)], leaves: [iPhone], step: 3)
        XCTAssertEqual(Set(names), ["USB-C device", "iPhone"])
        XCTAssertEqual(src.names[2]?.name, "iPhone")
    }

    func testPartlyBadElementDoesNotKeepTheNameIfItsLeafLeft() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 1)
        read(after: 60, [(1, 1_000)], leaves: [iPhone], step: 2, badElement: true)
        read(after: 60, [(1, 1_000), (2, 9_200)], leaves: [keyboard], step: 3)
        XCTAssertNotEqual(src.names[2]?.name, "iPhone")
    }

    func testPartlyBadElementDoesNotKeepTheNameIfTheWalkIsEmpty() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 1)
        read(after: 60, [(1, 1_000)], leaves: [iPhone], step: 2, badElement: true)
        read(after: 60, [(1, 1_000), (2, 9_200)], leaves: [], step: 3)
        XCTAssertNil(src.names[2])
    }

    /// Only the very next good read: a second absent read ends the hold.
    func testPartlyBadElementHoldLastsOneGoodReadOnly() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 1)
        read(after: 60, [(1, 1_000)], leaves: [iPhone], step: 2, badElement: true)
        read(after: 60, [(1, 1_000)], leaves: [iPhone], step: 3, badElement: true)
        read(after: 60, [(1, 1_000), (2, 9_200)], leaves: [iPhone], step: 4)
        XCTAssertNil(src.names[2])
    }

    /// A failed read carries no information: it neither consumes nor extends the hold.
    func testAnUnreadBetweenTheBadElementAndTheReturnKeepsTheHold() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 1)
        read(after: 60, [(1, 1_000)], leaves: [iPhone], step: 2, badElement: true)
        time.advance(60)
        src.ingest(.unread)
        read(after: 60, [(1, 1_000), (2, 9_200)], leaves: [iPhone], step: 3)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
    }

    /// S3.4 review M4 (spec §1.3, accepted as written): a different device on the same PortIndex with no absent
    /// read in between keeps the old episode and name.
    func testSameIndexSwapWithoutAnAbsentReadKeepsTheOldNameAsSpecified() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 1)
        read(after: 60, [(2, 9_200)], leaves: [keyboard], step: 2)
        XCTAssertEqual(names, ["iPhone"])
    }

    /// Same run, but port 3's element lands at T+100: the iPhone leaf (100 s old) is INSIDE the window, so
    /// only the claimed-leaf filter keeps it from port 3.
    func testClaimedLeafFilterAloneKeepsPort3FromTheIPhone() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [], leaves: [iPhone], step: 1)                                   // T
        read(after: 51, [(2, 9_200)], leaves: [iPhone], step: 2)                         // T+51: port 2 = iPhone
        read(after: 20, [(2, 9_200)], leaves: [iPhone, reMarkable], step: 3)             // T+71
        read(after: 29, [(2, 9_200), (3, 6_000)], leaves: [iPhone, reMarkable], step: 4) // T+100
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        XCTAssertEqual(src.names[3]?.name, "Paper Pro")
    }

    // MARK: fix round 1 · (b) freshness, retraction, gate; re-enumerated leaves

    private let watchCharger = 6_000

    /// A sync reading that STARTED now (its `readAt` is the reading's own time, never the time it is noted).
    private var phoneLink: PhoneLink { PhoneLink(percent: 45, charging: true, usbPowered: true, readAt: time.value) }

    /// The iPhone (named by timing) and a Watch charger are both plugged in; the iPhone is unplugged much later.
    /// The phone link is hours old by then: the sole remaining port must NOT become "iPhone".
    func testStalePhoneLinkNeverNamesTheWatchChargerAfterTheIPhoneLeaves() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(3, 2_000)], leaves: [], step: 1)                       // the Watch charger, unnamed
        read(after: 60, [(2, 9_200), (3, 2_000)], leaves: [iPhone], step: 2)     // the iPhone, named by (c)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        src.notePhone(phoneLink)
        read(after: 200, [(3, 2_000)], leaves: [iPhone], step: 3)                      // iPhone gone, link 200 s old
        XCTAssertEqual(names, ["USB-C device"])
        XCTAssertNil(src.names[3])
    }

    func testNotePhoneNilRetractsAPhoneCorroboratedName() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        XCTAssertEqual(names, ["iPhone"])
        src.notePhone(nil)
        XCTAssertEqual(names, ["USB-C device"])
    }

    func testALinkThatIsNoLongerUSBPoweredRetractsTheName() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        src.notePhone(PhoneLink(percent: 45, charging: false, usbPowered: false))
        XCTAssertEqual(names, ["USB-C device"])
    }

    /// Final review I1 (spec §1.3 "reused by the rows until the port goes absent"): the 130 s window gates only
    /// the FIRST naming. The page syncs once per open, so the link ages while the popover is closed; the name,
    /// the phone's "45% ⚡" detail and its place under "Powered by this Mac" must survive that.
    func testAnAgedLinkKeepsTheNameWhileThePortStaysPresent() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        XCTAssertEqual(names, ["iPhone"])
        read(after: 131, [(2, 9_200)], leaves: [iPhone], step: 1)
        XCTAssertEqual(names, ["iPhone"], "131 s after the reading")
        XCTAssertEqual(src.display.rows.first?.detail, "· cable · 45% \u{26A1}\u{FE0E}")
        XCTAssertTrue(src.display.phoneInPowered)
    }

    func testANameSurvives131And600SecondsWithTheSameLinkAndPort() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        let link = phoneLink
        src.notePhone(link)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        read(after: 131, [(2, 9_200)], leaves: [iPhone], step: 1)
        XCTAssertEqual(src.names[2]?.name, "iPhone", "131 s")
        src.notePhone(link)                                                        // the page re-notes the same reading
        XCTAssertEqual(src.names[2]?.name, "iPhone", "re-noting the naming reading keeps it")
        for step in 2...8 { read(after: 60, [(2, 9_200)], leaves: [iPhone], step: step) }   // 131 + 7 × 60 = 551 s
        read(after: 49, [(2, 9_200)], leaves: [iPhone], step: 9)                         // 600 s
        XCTAssertEqual(src.names[2]?.name, "iPhone", "600 s")
        XCTAssertEqual(names, ["iPhone"])
        XCTAssertEqual(src.display.rows.first?.detail, "· cable · 45% \u{26A1}\u{FE0E}")
        XCTAssertTrue(src.display.phoneInPowered)
    }

    /// Ruling (iii): a NEWER reading saying not USB-powered takes the name back.
    func testANewerReadingThatIsNotUSBPoweredRetractsAnAgedName() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        read(after: 300, [(2, 9_200)], leaves: [iPhone], step: 1)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        src.notePhone(PhoneLink(percent: 60, charging: false, usbPowered: false, readAt: time.value))
        XCTAssertNil(src.names[2])
        XCTAssertEqual(names, ["USB-C device"])
    }

    /// Ruling (iv): a second port joining is harmless; any port going absent after the naming reading takes the
    /// name back (the phone may have moved), and the old reading never re-names.
    func testAnyUnplugAfterTheNamingReadingRetractsAnAgedName() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        let old = phoneLink
        src.notePhone(old)
        read(after: 200, [(2, 9_200), (3, 2_000)], leaves: [iPhone], step: 1)          // a Watch charger joins
        XCTAssertEqual(src.names[2]?.name, "iPhone", "a port joining is not an unplug")
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 2)                        // the Watch charger comes off
        XCTAssertNil(src.names[2], "an unplug after the naming reading")
        src.notePhone(old)
        XCTAssertNil(src.names[2], "re-noting the old reading never re-names")
        time.advance(5)
        src.notePhone(phoneLink)                                                   // a NEW reading, after the unplug
        XCTAssertEqual(src.names[2]?.name, "iPhone")
    }

    /// The display's port-unknown iPhone row has no age limit either (two drawing ports, no unplug since).
    func testThePortUnknownPhoneRowOutlivesTheWindow() {
        read(after: 0, [(1, 6_100), (2, 4_200)], leaves: [iPhone], step: 0)
        src.notePhone(PhoneLink(percent: 33, charging: true, usbPowered: true, readAt: time.value))
        read(after: 600, [(1, 6_100), (2, 4_200)], leaves: [iPhone], step: 1)
        XCTAssertEqual(src.display.rows.first?.state, .phonePortUnknown)
        XCTAssertTrue(src.display.oneIsPhoneCaption)
    }

    func testCNamesAreNeverOverriddenNorRetractedByThePhoneLink() {
        read(after: 0, [], leaves: [iPhone], step: 0)
        read(after: 60, [(2, 9_200)], leaves: [iPhone, keyboard], step: 1)               // (c): Magic Keyboard
        src.notePhone(phoneLink)                                                  // (b) never overrides (c)
        XCTAssertEqual(names, ["Magic Keyboard"])
        src.notePhone(nil)
        XCTAssertEqual(names, ["Magic Keyboard"])
    }

    /// The link's age is measured at the read: 131 s does not name, 130 s does (inclusive).
    func testAPhoneLinkOlderThanTheWindowDoesNotName() {
        src.notePhone(phoneLink)
        time.advance(131)
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        XCTAssertEqual(names, ["USB-C device"])
    }

    func testAPhoneLinkExactlyAtTheWindowNames() {
        src.notePhone(phoneLink)
        time.advance(130)
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        XCTAssertEqual(names, ["iPhone"])
    }

    /// Spec §1.3 "exactly one port is sourcing": a lone quiet (0.2 W) element is not a sourcing port.
    func testAQuietLonePortIsNotNamedTheIPhone() {
        src.notePhone(phoneLink)
        read(after: 0, [(2, 200)], leaves: [iPhone], step: 0)
        XCTAssertEqual(src.drawingPortIndices, [])
        XCTAssertNil(src.names[2])
    }

    /// One drawing port plus one quiet port: two elements present, so (b) stays silent.
    func testADrawingPortBesideAQuietOneIsNotNamedTheIPhone() {
        src.notePhone(phoneLink)
        read(after: 0, [(1, 200), (2, 9_200)], leaves: [iPhone], step: 0)
        XCTAssertNil(src.names[2])
    }

    /// The iPhone blips (new registry id, same product) within one refresh; its episode and name continue.
    /// A charge-only device starting on another port must not inherit the name through the new id.
    func testAReEnumeratedIPhoneLeafDoesNotNameAnotherPort() {
        let reEnumerated = USBLeaf(registryID: 0x1000_2001, productName: "iPhone", vendorName: "Apple Inc.", kind: .iphone)
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 1)
        read(after: 60, [(2, 9_200)], leaves: [reEnumerated], step: 2)
        read(after: 60, [(2, 9_200), (3, 2_000)], leaves: [reEnumerated], step: 3)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        XCTAssertNil(src.names[3])
    }

    // MARK: owner hub fix 2026-09-29 · a (b) name needs an iPhone on the USB bus

    /// A powered hub: the iPhone is pulled from the hub, the hub's port stays present and drawing, and the walk
    /// (successful) shows no iPhone leaf. The name, the "45% ⚡" and the phone's place under Powered go on that read.
    func testAPoweredHubPortLosesTheIPhoneNameWhenNoIPhoneLeafIsOnTheBus() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        read(after: 60, [(2, 9_200)], leaves: [], step: 1)                        // the hub, still drawing
        XCTAssertNil(src.names[2])
        XCTAssertEqual(names, ["USB-C device"])
        XCTAssertEqual(src.display.rows.first?.detail, "· cable")
        XCTAssertFalse(src.display.phoneInPowered)
    }

    /// Same, but the walk FAILED: no information, the name and details stay.
    func testAFailedWalkNeverRetractsTheIPhoneName() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        usb.setFailed()
        time.advance(60)
        src.ingest(portTestFrame(update: Int(now.timeIntervalSince1970) - 200 + 60, onAC: true, ports: [(2, 9_200)], step: 1))
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        XCTAssertEqual(src.display.rows.first?.detail, "· cable · 45% \u{26A1}\u{FE0E}")
        XCTAssertTrue(src.display.phoneInPowered)
    }

    /// A same-port swap to a Watch charger with no absent read: the name goes as soon as the iPhone leaf does.
    func testASamePortSwapToAWatchChargerDropsTheNameWithTheIPhoneLeaf() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        read(after: 60, [(2, 9_200)], leaves: [iPhone], step: 1)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        read(after: 60, [(2, watchCharger)], leaves: [], step: 2)                 // swapped within one refresh
        XCTAssertNil(src.names[2])
        XCTAssertEqual(names, ["USB-C device"])
    }

    /// The phone-port-unknown row and its caption go when no iPhone leaf is on the bus.
    func testThePortUnknownPhoneRowGoesWhenNoIPhoneLeafIsPresent() {
        read(after: 0, [(1, 6_100), (2, 4_200)], leaves: [iPhone], step: 0)
        src.notePhone(PhoneLink(percent: 33, charging: true, usbPowered: true, readAt: time.value))
        XCTAssertEqual(src.display.rows.first?.state, .phonePortUnknown)
        read(after: 60, [(1, 6_100), (2, 4_200)], leaves: [], step: 1)
        XCTAssertFalse(src.display.rows.contains { $0.state == .phonePortUnknown })
        XCTAssertFalse(src.display.oneIsPhoneCaption)
        XCTAssertFalse(src.display.phoneInPowered)
    }

    /// An iPhone-over-USB reading with no iPhone leaf on the bus is contradictory: the first naming refuses it.
    func testAUSBPhoneReadingWithNoIPhoneLeafNamesNothing() {
        read(after: 0, [(2, 9_200)], leaves: [keyboard], step: 0)
        src.notePhone(phoneLink)
        XCTAssertNil(src.names[2])
        XCTAssertEqual(names, ["USB-C device"])
    }

    /// A leaf blip (one read without the iPhone leaf) drops the name for that read. With the link still inside
    /// the 130 s window the name comes back on its own on the next read; with an older link it waits for the
    /// Devices page's next sync (a lost name, never a false one).
    func testALeafBlipDropsTheNameForOneReadAndAFreshLinkBringsItBack() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        read(after: 10, [(2, 9_200)], leaves: [], step: 1)
        XCTAssertNil(src.names[2], "the blip read")
        read(after: 10, [(2, 9_200)], leaves: [iPhone], step: 2)
        XCTAssertEqual(src.names[2]?.name, "iPhone", "back on its own: the link is 20 s old")
    }

    func testALeafBlipAfterTheWindowWaitsForTheNextSync() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        read(after: 200, [(2, 9_200)], leaves: [], step: 1)
        read(after: 10, [(2, 9_200)], leaves: [iPhone], step: 2)
        XCTAssertNil(src.names[2], "the link is 210 s old: no first naming")
        src.notePhone(phoneLink)                                                  // the page's next sync
        XCTAssertEqual(src.names[2]?.name, "iPhone")
    }

    // MARK: fix round 2 · a phone unplug invalidates the current link

    /// The Critical scenario inside the freshness window: the reading started 60 s before the iPhone came off
    /// its port. Port 3 (the Watch charger) is then the only drawing port and that reading is still fresh, but
    /// the unplug invalidates it: port 3 stays unnamed. RE-NOTING THE SAME OLD READING (the page does, on
    /// every open and beacon update) changes nothing; only a reading that STARTED after the unplug reopens it.
    func testAnUnplugInvalidatesTheReadingAndReNotingItDoesNotReopenTheGate() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(3, 2_000)], leaves: [], step: 1)                       // the Watch charger, unnamed
        read(after: 60, [(2, 9_200), (3, 2_000)], leaves: [iPhone], step: 2)     // the iPhone, named by (c)
        let old = phoneLink                                                       // reading started here ...
        src.notePhone(old)
        read(after: 60, [(3, 2_000)], leaves: [iPhone], step: 3)                 // ... unplug 60 s later, still fresh
        XCTAssertNil(src.names[3], "the unplug read itself")
        read(after: 10, [(3, 2_000)], leaves: [iPhone], step: 4)
        XCTAssertNil(src.names[3], "every later read")
        src.notePhone(old)                                                        // the page opens: same old reading
        time.advance(3)
        src.notePhone(old)                                                        // a beacon update, seconds later
        XCTAssertNil(src.names[3], "re-noting the old reading never reopens the gate")
        XCTAssertEqual(src.display.rows.map(\.name), ["USB-C device"])
        src.notePhone(phoneLink)                                                  // a NEW reading, started after the unplug
        XCTAssertEqual(src.names[3]?.name, "iPhone", "the gate reopens: the phone really is on the only port")
    }

    /// Lag: the reading STARTED before the unplug but is only noted after it (the sync read takes seconds).
    func testAReadingStartedBeforeTheUnplugButNotedAfterItDoesNotName() {
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(3, 2_000)], leaves: [], step: 1)
        read(after: 60, [(2, 9_200), (3, 2_000)], leaves: [iPhone], step: 2)
        let lagged = phoneLink                                                    // sync read starts here
        read(after: 5, [(3, 2_000)], leaves: [iPhone], step: 3)                  // the phone comes off meanwhile
        time.advance(4)
        src.notePhone(lagged)                                                     // the slow read lands afterwards
        XCTAssertNil(src.names[3])
    }

    /// A link with no known start time (beacon-only / unknown) never corroborates.
    func testALinkWithoutAReadTimeNeverNames() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(PhoneLink(percent: 45, charging: true, usbPowered: true, readAt: nil))
        XCTAssertEqual(names, ["USB-C device"])
    }

    /// reMarkable #1 is claimed on port 2; a USB stick appears (via a hub, or quiet); reMarkable #2 then goes
    /// into port 3 within 130 s. Two fresh unclaimed leaves: never a guess (not "USB stick").
    func testAStickBesideASecondCopyOfAClaimedDeviceNamesNothing() {
        let stick = USBLeaf(registryID: 0x1000_1004, productName: "USB stick", vendorName: "Generic", kind: .massStorage)
        let reMarkable2 = USBLeaf(registryID: 0x1000_1005, productName: "Paper Pro", vendorName: "reMarkable", kind: .other)
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(2, 6_000)], leaves: [reMarkable], step: 1)
        XCTAssertEqual(src.names[2]?.name, "Paper Pro")
        read(after: 20, [(2, 6_000)], leaves: [reMarkable, stick], step: 2)
        read(after: 20, [(2, 6_000), (3, 6_000)], leaves: [reMarkable, stick, reMarkable2], step: 3)
        XCTAssertEqual(src.names[2]?.name, "Paper Pro")
        XCTAssertNil(src.names[3])
    }

    /// A (b)-named iPhone that leaves counts as an unplug too.
    func testAnUnplugOfAPhoneNamedByBInvalidatesTheOldLink() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        read(after: 10, [(3, 2_000)], leaves: [iPhone], step: 1)
        XCTAssertNil(src.names[3])
    }

    // MARK: fix round 4 · ANY port going absent invalidates the current link

    /// The iPhone and a Watch charger both draw at the seed read, so neither is named (two newly drawing ports,
    /// two present). A fresh reading comes in; within 130 s the iPhone comes off. Its port was never named, but
    /// the unplug still invalidates the reading: port 3 (the Watch charger) stays unnamed on the unplug read and
    /// every later read, until a reading that STARTED after the unplug — and then only while port 3 is the only
    /// port present AND drawing.
    func testAnUnplugOfAnUnnamedPortInvalidatesTheLinkSoTheWatchChargerIsNeverTheIPhone() {
        read(after: 0, [(2, 9_200), (3, 2_000)], leaves: [iPhone], step: 0)     // seed: both drawing, unnamed
        XCTAssertNil(src.names[2])
        XCTAssertNil(src.names[3])
        let old = phoneLink                                                       // Devices opens: fresh reading
        src.notePhone(old)
        XCTAssertTrue(src.display.oneIsPhoneCaption, "one of these is the iPhone")
        read(after: 60, [(3, 2_000)], leaves: [iPhone], step: 1)                       // the iPhone comes off (unnamed port)
        XCTAssertNil(src.names[3], "the unplug read itself")
        XCTAssertEqual(names, ["USB-C device"])
        read(after: 10, [(3, 2_000)], leaves: [iPhone], step: 2)
        XCTAssertNil(src.names[3], "a later read, reading still inside the window")
        src.notePhone(old)                                                        // the page re-notes the OLD reading
        XCTAssertNil(src.names[3], "re-noting the old reading never reopens the gate")
        read(after: 10, [(3, 200)], leaves: [iPhone], step: 3)                          // port 3 goes quiet (below 0.3 W)
        src.notePhone(phoneLink)                                                  // a NEW reading, after the unplug
        XCTAssertNil(src.names[3], "a new reading names only a port that is alone AND drawing")
        read(after: 10, [(3, 2_000)], leaves: [iPhone], step: 4)                        // drawing again, alone
        XCTAssertEqual(src.names[3]?.name, "iPhone", "the gate reopens on a reading started after the unplug")
    }

    /// A NON-phone port going absent invalidates the link too: here a USB stick, named by the timing match, is
    /// pulled. Only "any port" catches this — the stick's name is not `.iphone`.
    func testANonPhonePortGoingAbsentAlsoInvalidatesTheLink() {
        let stick = USBLeaf(registryID: 0x1000_1004, productName: "USB stick", vendorName: "Generic", kind: .massStorage)
        read(after: 0, [], leaves: [], step: 0)
        read(after: 60, [(1, 4_500)], leaves: [stick], step: 1)                  // (c): the stick
        XCTAssertEqual(src.names[1]?.name, "USB stick")
        read(after: 60, [(1, 4_500), (3, 2_000)], leaves: [stick], step: 2)      // port 3: no new leaf, unnamed
        XCTAssertNil(src.names[3])
        src.notePhone(phoneLink)                                                  // two ports: (b) silent
        XCTAssertNil(src.names[3])
        read(after: 30, [(3, 2_000)], leaves: [iPhone], step: 3)                       // the stick is pulled
        XCTAssertNil(src.names[3], "the stick's absence invalidates the reading")
        XCTAssertEqual(names, ["USB-C device"])
    }

    /// A failed read carries no information: it never sets the mark (a link noted before it still names after
    /// it), and it does not hide an absence either — a port gone on the next good read, compared with the last
    /// GOOD read, still invalidates the link.
    func testAnUnreadNeverSetsTheMarkNorHidesAnAbsence() {
        read(after: 0, [(2, 9_200)], leaves: [iPhone], step: 0)
        src.notePhone(phoneLink)
        XCTAssertEqual(src.names[2]?.name, "iPhone")
        time.advance(10)
        src.ingest(.unread)
        read(after: 10, [(2, 9_200)], leaves: [iPhone], step: 1)
        XCTAssertEqual(src.names[2]?.name, "iPhone", "the unread did not set the mark")
        src.notePhone(nil)                                                        // (b) name retracted: port 2 unnamed
        XCTAssertNil(src.names[2])
        read(after: 10, [(2, 9_200), (3, 2_000)], leaves: [iPhone], step: 2)           // a second port joins
        src.notePhone(phoneLink)                                                  // a fresh reading, two ports
        time.advance(10)
        src.ingest(.unread)
        read(after: 10, [(3, 2_000)], leaves: [iPhone], step: 3)                       // port 2 absent vs the last GOOD read
        XCTAssertNil(src.names[3], "an absence across an unread still invalidates the link")
    }
}
