import XCTest

final class PhoneBatteryModelTests: XCTestCase {
    private let sync = PhoneSyncReading(name: "Alex's iPhone", productType: "iPhone18,2", percent: 45, charging: true,
                                        externalConnected: true, viaWiFi: true)
    private let beacon = PhoneBeacon(id: "BEACON-ID", name: "Alex's iPhone", model: "iPhone18,2", percent: 50)

    func testSyncReadingWinsAndCarriesCharging() {
        let r = PhoneBatteryModel.resolve(sync: .reading(sync), beacons: [beacon], beaconSeenAt: 1000, now: 1000)
        XCTAssertEqual(r?.device.deviceClass, .iphone)
        XCTAssertEqual(r?.device.components.first?.percent, 45)
        XCTAssertEqual(r?.device.components.first?.charging, true)
        XCTAssertEqual(r?.provenance, .sync(viaWiFi: true))
        XCTAssertNil(PhoneBatteryModel.note(resolved: r, sync: .reading(sync), beaconUnavailable: nil))
    }

    func testBeaconFillsInWhenSyncFindsNothing() {
        let r = PhoneBatteryModel.resolve(sync: .noDevice, beacons: [beacon], beaconSeenAt: 990, now: 1000)
        XCTAssertEqual(r?.device.components.first?.percent, 50)
        XCTAssertNil(r?.device.components.first?.charging)
        XCTAssertEqual(r?.provenance, .beacon)
        XCTAssertEqual(PhoneBatteryModel.note(resolved: r, sync: .noDevice, beaconUnavailable: nil),
                       "iPhone level from its nearby beacon · approximate")
    }

    func testStaleBeaconIsNotNearby() {
        let r = PhoneBatteryModel.resolve(sync: nil, beacons: [beacon], beaconSeenAt: 0, now: 1000)
        XCTAssertNil(r)
    }

    func testBeaconWithoutPercentIsNoRow() {
        let b = PhoneBeacon(id: "x", name: "iPhone", model: "", percent: nil)
        XCTAssertNil(PhoneBatteryModel.resolve(sync: nil, beacons: [b], beaconSeenAt: 1000, now: 1000))
    }

    func testUnavailableSyncSpeaksWhenNothingElseDoes() {
        let note = PhoneBatteryModel.note(resolved: nil, sync: .unavailable("this Mac is not trusted by the phone"), beaconUnavailable: nil)
        XCTAssertEqual(note, "iPhone unavailable — this Mac is not trusted by the phone")
        XCTAssertNil(PhoneBatteryModel.note(resolved: nil, sync: .noDevice, beaconUnavailable: nil), "absent for a plain reason is silent")
    }

    func testStableIdentityUsesProductType() {
        let r = PhoneBatteryModel.resolve(sync: .reading(sync), beacons: [], beaconSeenAt: nil, now: 1)
        XCTAssertEqual(r?.device.id, "phone:iPhone18,2")
    }

    @MainActor
    func testSourceFoldsBothRoutes() async {
        let src = PhoneBatterySource(sync: FixedPhoneSyncReader(result: .noDevice),
                                     beacon: FixedPhoneBeaconBrowser(beacons: [beacon]), now: { 1000 })
        src.startBeacon()
        XCTAssertEqual(src.resolved?.provenance, .beacon)
        await src.refresh()
        XCTAssertEqual(src.note, "iPhone level from its nearby beacon · approximate")
        XCTAssertEqual(src.resolved?.provenance, .beacon)
        src.stopBeacon()
    }

    // MARK: - 31 §1.3 · interface preference, externalConnected, the link

    func testPreferUSBWins() {
        XCTAssertEqual(PhoneBatteryModel.prefer(candidates: [1, 2]), 0, "USB first")
        XCTAssertEqual(PhoneBatteryModel.prefer(candidates: [2, 1]), 1, "Wi-Fi first, then USB → USB")
        XCTAssertEqual(PhoneBatteryModel.prefer(candidates: [1]), 0, "USB only")
        XCTAssertEqual(PhoneBatteryModel.prefer(candidates: [2]), 0, "Wi-Fi only → Wi-Fi")
        XCTAssertNil(PhoneBatteryModel.prefer(candidates: []))
    }

    func testResolveKeepsExternalConnectedAndTheInterface() {
        let usb = PhoneSyncReading(name: "iPhone", productType: "iPhone18,2", percent: 33, charging: true,
                                   externalConnected: true, viaWiFi: false, viaUSB: true)
        let r = PhoneBatteryModel.resolve(sync: .reading(usb), beacons: [], beaconSeenAt: nil, now: 1)
        XCTAssertEqual(r?.externalConnected, true)
        XCTAssertEqual(r?.viaUSB, true)
        XCTAssertEqual(PhoneBatteryModel.link(r), PhoneLink(percent: 33, charging: true, usbPowered: true))
    }

    func testWiFiReadingIsNotUSBPowered() {
        let r = PhoneBatteryModel.resolve(sync: .reading(sync), beacons: [], beaconSeenAt: nil, now: 1)
        XCTAssertEqual(PhoneBatteryModel.link(r), PhoneLink(percent: 45, charging: true, usbPowered: false))
    }

    func testUSBWithoutExternalPowerIsNotUSBPowered() {
        let usb = PhoneSyncReading(name: "iPhone", productType: "iPhone18,2", percent: 80, charging: false,
                                   externalConnected: false, viaWiFi: false, viaUSB: true)
        let r = PhoneBatteryModel.resolve(sync: .reading(usb), beacons: [], beaconSeenAt: nil, now: 1)
        XCTAssertEqual(PhoneBatteryModel.link(r)?.usbPowered, false)
    }

    func testBeaconRowHasNoLinkAndNoExternalConnected() {
        let r = PhoneBatteryModel.resolve(sync: .noDevice, beacons: [beacon], beaconSeenAt: 990, now: 1000)
        XCTAssertNil(r?.externalConnected)
        XCTAssertNil(PhoneBatteryModel.link(r))
        XCTAssertNil(PhoneBatteryModel.link(nil))
    }

    // MARK: - fix round 3 · the link carries the sync reading's own start time

    func testTheLinkCarriesTheReadingStartTime() {
        let usb = PhoneSyncReading(name: "iPhone", productType: "iPhone18,2", percent: 33, charging: true,
                                   externalConnected: true, viaWiFi: false, viaUSB: true)
        let r = PhoneBatteryModel.resolve(sync: .reading(usb), beacons: [], beaconSeenAt: nil, now: 1, syncReadAt: 42)
        XCTAssertEqual(PhoneBatteryModel.link(r)?.readAt, 42)
    }

    func testAnUnstampedReadingHasNoReadTime() {
        let r = PhoneBatteryModel.resolve(sync: .reading(sync), beacons: [], beaconSeenAt: nil, now: 1)
        XCTAssertNil(PhoneBatteryModel.link(r)?.readAt)
    }

    /// The source stamps the START of the read from its clocks; a later recompute (page open, beacon update)
    /// keeps that stamp — it never becomes "now".
    @MainActor
    func testSourceStampsTheReadStartAndRecomputeKeepsIt() async {
        let clock = MockClockBox(42)
        let usb = PhoneSyncReading(name: "iPhone", productType: "iPhone18,2", percent: 33, charging: true,
                                   externalConnected: true, viaWiFi: false, viaUSB: true)
        let src = PhoneBatterySource(sync: FixedPhoneSyncReader(result: .reading(usb)),
                                     beacon: FixedPhoneBeaconBrowser(beacons: [beacon]), now: { 1000 },
                                     clocks: MonotonicClocks(monotonicRaw: { clock.now }, uptimeRaw: { clock.now }))
        await src.refresh()
        XCTAssertEqual(PhoneBatteryModel.link(src.resolved)?.readAt, 42)
        clock.now = 99
        src.startBeacon()
        XCTAssertEqual(PhoneBatteryModel.link(src.resolved)?.readAt, 42)
        src.stopBeacon()
    }

    func testABeaconRowHasNoReadTime() {
        let r = PhoneBatteryModel.resolve(sync: .noDevice, beacons: [beacon], beaconSeenAt: 990, now: 1000, syncReadAt: 42)
        XCTAssertNil(PhoneBatteryModel.link(r))
    }
}
