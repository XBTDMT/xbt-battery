import XCTest
@testable import Battery

/// 31 §2.2 (T2, T4, Q2; owner U6 "B") · the notice's words: the name alone as the title, "Drawing …" as the subline, never "charging"; watts at 0.1 W; the % only
/// when the pack Wh is read; one notice for devices appearing on one read; the switch's own key.
/// Every "≈" before a number carries a non-breaking space (U+00A0), as PortPowerDisplay.swift does.
final class DeviceNoticeTests: XCTestCase {
    private func port(_ name: String?, _ kind: USBLeafKind?, _ mW: Int) -> DeviceNoticePort {
        DeviceNoticePort(name: name, kind: kind, filteredPower_mW: mW)
    }

    func testSingleNamedDevice() {
        XCTAssertEqual(DeviceNoticeComposer.compose([port("iPhone", .iphone, 14_171)], percentPerHour: 22),
                       DeviceNotice(title: "iPhone",
                                    subline: "Drawing 14.2 W · ≈\u{00A0}22% of battery per hour",
                                    spoken: "iPhone is drawing power from your Mac. Drawing 14.2 W, about 22% of battery per hour",
                                    symbol: "iphone"))
    }

    func testUnnamedDevice() {
        XCTAssertEqual(DeviceNoticeComposer.compose([port(nil, nil, 4_500)], percentPerHour: 7),
                       DeviceNotice(title: "USB-C device",
                                    subline: "Drawing 4.5 W · ≈\u{00A0}7% of battery per hour",
                                    spoken: "A USB-C device is drawing power from your Mac. Drawing 4.5 W, about 7% of battery per hour",
                                    symbol: "cable.connector"))
    }

    func testDevicesOnOneReadAggregate() {
        let n = DeviceNoticeComposer.compose([port("iPhone", .iphone, 9_200), port(nil, nil, 9_200)], percentPerHour: 29)
        XCTAssertEqual(n?.title, "2 devices")
        XCTAssertEqual(n?.subline, "Drawing 18.4 W · ≈\u{00A0}29% of battery per hour")
        XCTAssertEqual(n?.spoken, "2 devices are drawing power from your Mac. Drawing 18.4 W, about 29% of battery per hour")
        XCTAssertEqual(n?.symbol, "cable.connector")
    }

    func testPackWattHoursUnreadShowsWattsOnly() {
        let n = DeviceNoticeComposer.compose([port("iPhone", .iphone, 9_200)], percentPerHour: nil)
        XCTAssertEqual(n?.subline, "Drawing 9.2 W")
        XCTAssertEqual(n?.spoken, "iPhone is drawing power from your Mac. Drawing 9.2 W")
    }

    /// The Devices tab never prints "0%": a rate that rounds to 0 %/h reads "< 1%" (no "≈" — it is a bound).
    func testRateThatRoundsToZeroReadsUnderOnePercentNeverZero() {
        let n = DeviceNoticeComposer.compose([port(nil, nil, 400)], percentPerHour: 0)
        XCTAssertEqual(n?.subline, "Drawing 0.4 W · < 1% of battery per hour")
        XCTAssertFalse(n?.subline.contains("0%") ?? true, "never '0%'")
        XCTAssertFalse(n?.subline.contains("≈") ?? true, "a bound, not an estimate")
        XCTAssertEqual(n?.spoken, "A USB-C device is drawing power from your Mac. Drawing 0.4 W, less than 1% of battery per hour")
    }

    /// A one-percent rate keeps its estimate wording (the boundary of `formatPercent`).
    func testOnePercentRateIsAnEstimate() {
        XCTAssertEqual(DeviceNoticeComposer.compose([port(nil, nil, 1_200)], percentPerHour: 1)?.subline,
                       "Drawing 1.2 W · ≈\u{00A0}1% of battery per hour")
    }

    /// The composer never shortens a name — the HUD truncates the title on one line at 320 pt. The title is the
    /// name alone now, so "AirPods Max USB Audio" is a short title and the verb cannot be cut off it.
    func testLongDeviceNameIsNeverShortenedAndTheVerbIsNotInTheTitle() {
        let n = DeviceNoticeComposer.compose([port("AirPods Max USB Audio", .other, 3_100)], percentPerHour: 5)
        XCTAssertEqual(n?.title, "AirPods Max USB Audio")
        XCTAssertEqual(n?.subline, "Drawing 3.1 W · ≈\u{00A0}5% of battery per hour")
        let veryLong = String(repeating: "Long Name ", count: 12) + "End"
        let long = DeviceNoticeComposer.compose([port(veryLong, nil, 3_100)], percentPerHour: nil)
        XCTAssertEqual(long?.title, veryLong)
        XCTAssertEqual(long?.subline, "Drawing 3.1 W", "the numbers stay on the second line however long the name is")
    }

    /// A blank or whitespace-only name is not a name: the notice falls back to the unnamed label (never a blank lead).
    func testBlankNameFallsBackToUnnamedLabel() {
        for blank in ["", "   ", " \n\t "] {
            let n = DeviceNoticeComposer.compose([port(blank, .massStorage, 4_500)], percentPerHour: 7)
            XCTAssertEqual(n?.title, "USB-C device", "name=\(blank.debugDescription)")
            XCTAssertEqual(n?.symbol, "cable.connector", "an unnamed title never claims a kind")
        }
    }

    /// A real name is trimmed of surrounding whitespace and newlines, nothing else.
    func testNameIsTrimmedOfSurroundingWhitespace() {
        let n = DeviceNoticeComposer.compose([port("  iPhone \n", .iphone, 9_200)], percentPerHour: nil)
        XCTAssertEqual(n?.title, "iPhone")
        XCTAssertEqual(n?.symbol, "iphone")
    }

    /// The glyph must not claim a kind the title withholds: unnamed + `.iphone` reads "USB-C device" + cable glyph.
    func testUnnamedPortNeverShowsAKindGlyph() {
        for kind in [USBLeafKind.iphone, .massStorage, .keyboard, .other] {
            let n = DeviceNoticeComposer.compose([port(nil, kind, 4_500)], percentPerHour: nil)
            XCTAssertEqual(n?.title, "USB-C device")
            XCTAssertEqual(n?.symbol, "cable.connector", "kind=\(kind)")
        }
    }

    func testNothingFiredIsNoNotice() {
        XCTAssertNil(DeviceNoticeComposer.compose([], percentPerHour: 10))
    }

    func testNeverSaysCharging() {
        for n in [DeviceNoticeComposer.compose([port("T7 Shield", .massStorage, 4_500)], percentPerHour: 7),
                  DeviceNoticeComposer.compose([port(nil, nil, 1_000), port(nil, nil, 2_000)], percentPerHour: nil)] {
            XCTAssertNotNil(n)
            XCTAssertFalse(n.map { "\($0.title) \($0.subline) \($0.spoken)".lowercased().contains("charging") } ?? true)
        }
    }

    /// Absence is not a fact: a stored value of the wrong type is unreadable, not "off" — the notice stays on.
    func testWrongTypedStoredValueReadsAsDefaultOn() {
        let suite = "DeviceNoticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("abc", forKey: DeviceNoticeSetting.key)
        XCTAssertTrue(DeviceNoticeSetting.isOn(defaults), "String")
        defaults.set(Data([0x00, 0x01]), forKey: DeviceNoticeSetting.key)
        XCTAssertTrue(DeviceNoticeSetting.isOn(defaults), "Data")
    }

    func testSwitchHasItsOwnKeyAndDefaultsOn() {
        let suite = "DeviceNoticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DeviceNoticeSetting.key, "deviceNotice.enabled.v1")
        XCTAssertTrue(DeviceNoticeSetting.isOn(defaults), "absent key → on (Q2)")
        defaults.set(false, forKey: DeviceNoticeSetting.key)
        XCTAssertFalse(DeviceNoticeSetting.isOn(defaults))
        defaults.set(true, forKey: DeviceNoticeSetting.key)
        XCTAssertTrue(DeviceNoticeSetting.isOn(defaults))
        defaults.set(0, forKey: DeviceNoticeSetting.key)   // NSNumber 0 / 1 still read as a Bool
        XCTAssertFalse(DeviceNoticeSetting.isOn(defaults))
        defaults.set(1, forKey: DeviceNoticeSetting.key)
        XCTAssertTrue(DeviceNoticeSetting.isOn(defaults))
        XCTAssertFalse(NotificationEventType.allCases.map(\.rawValue).contains("deviceNotice"),
                       "not a NotificationEventType (T9)")
    }
}
