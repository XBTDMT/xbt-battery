import XCTest

/// Sprint 4.H (#12) / 4.I: the IOPS accessory parse (against a REAL captured dictionary from this
/// machine), multi-component labelling via `Part Identifier`, dedupe via `Accessory Identifier`, the
/// retained `ioreg` fallback parser, class→symbol totality, staleness, empty→hidden, the live reader's
/// symbol-missing path, and the ProcessProbe timeout kill-test (a real subprocess).
final class DeviceBatteryTests: XCTestCase {

    private func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/devices/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "<<MISSING FIXTURE \(name)>>"
    }

    /// Loads a captured IOPS description array the way the boundary adapter hands it to the parser.
    private func iopsFixture(_ name: String) -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/devices/\(name)")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("missing/invalid IOPS fixture \(name)"); return []
        }
        return json
    }

    // MARK: - IOPS parse vs the REAL captured dictionary

    func testParseAccessoriesAgainstLiveCapturedDictionary() {
        let acc = DeviceParsers.parseAccessories(iopsFixture("iops-bytype0-live.json"))
        XCTAssertEqual(acc.count, 1, "the InternalBattery source is the popover's own subject, not a device")
        let ap = acc[0]
        XCTAssertEqual(ap.name, "Alex\u{2019}s AirPods Max", "clean UTF-8 straight from IOPS — no pmset mojibake")
        XCTAssertEqual(ap.accessoryID, "A1A1A1A1-0000-4000-8000-000000000001")
        XCTAssertEqual(ap.partID, "Single")
        XCTAssertEqual(ap.category, "Headset")
        XCTAssertEqual(ap.percent, 43)
        XCTAssertEqual(ap.isCharging, false)
        XCTAssertEqual(ap.transport, "Bluetooth LE")
    }

    func testLiveCapturedDictionaryMergesToOneUnlabeledRow() {
        let acc = DeviceParsers.parseAccessories(iopsFixture("iops-bytype0-live.json"))
        let merged = DeviceMerge.merge(accessories: acc, ioreg: [], asOf: 1_000)
        XCTAssertEqual(merged.count, 1)
        let d = merged[0]
        XCTAssertEqual(d.id, "A1A1A1A1-0000-4000-8000-000000000001", "identity is the Accessory Identifier, not the name")
        XCTAssertEqual(d.deviceClass, .airpodsMax)
        XCTAssertEqual(d.components, [DeviceBatteryComponent(label: nil, percent: 43, charging: false)],
                       "Part Identifier == Single → one UNLABELED component")
        XCTAssertEqual(d.asOf, 1_000)
    }

    func testInternalBatteryIsNeverADeviceRow() {
        let internalOnly: [[String: Any]] = [["Name": "InternalBattery-0", "Type": "InternalBattery",
                                              "Transport Type": "Internal", "Current Capacity": 85,
                                              "Max Capacity": 100, "Is Present": true]]
        XCTAssertTrue(DeviceParsers.parseAccessories(internalOnly).isEmpty)
    }

    func testParseAccessoriesToleratesGarbage() {
        XCTAssertTrue(DeviceParsers.parseAccessories([]).isEmpty)
        XCTAssertTrue(DeviceParsers.parseAccessories([[:]]).isEmpty, "no Name / no capacity → no row")
        XCTAssertTrue(DeviceParsers.parseAccessories([["Name": "Ghost", "Current Capacity": 40,
                                                       "Is Present": false]]).isEmpty, "absent → dropped")
        // A non-100 Max Capacity is normalised rather than assumed.
        let scaled = DeviceParsers.parseAccessories([["Name": "Odd", "Current Capacity": 25, "Max Capacity": 50]])
        XCTAssertEqual(scaled.first?.percent, 50)
    }

    // MARK: - multi-component labelling via Part Identifier (retires the percent-matching guess)

    func testMultiComponentPartsAreLabeledFromPartIdentifier() {
        let acc = DeviceParsers.parseAccessories(iopsFixture("iops-bytype0-multipart.json"))
        XCTAssertEqual(acc.count, 3)
        let merged = DeviceMerge.merge(accessories: acc, ioreg: [], asOf: 1)
        XCTAssertEqual(merged.count, 1, "three parts, one Accessory Identifier → ONE device row")
        let d = merged[0]
        XCTAssertEqual(d.deviceClass, .airpods)
        XCTAssertEqual(d.components.map { $0.label }, ["Case", "Left", "Right"], "Case → Left → Right order")
        XCTAssertEqual(d.components.map { $0.percent }, [84, 80, 80])
        // The point of the cut: Left and Right COLLIDE at 80%. The pre-4.I percent-matching guess had to
        // drop to unlabeled here; Part Identifier is fact, so the labels and the per-part charging survive.
        XCTAssertEqual(d.components.map { $0.charging }, [false, true, false],
                       "charging is per-part fact, not a nearest-percent match")
    }

    func testPartLabelMapping() {
        XCTAssertNil(DeviceMerge.partLabel("Single"), "Single is a lone battery → no label")
        XCTAssertNil(DeviceMerge.partLabel("single"))
        XCTAssertNil(DeviceMerge.partLabel(nil))
        XCTAssertNil(DeviceMerge.partLabel("  "))
        XCTAssertEqual(DeviceMerge.partLabel("Left"), "Left")
        XCTAssertEqual(DeviceMerge.partLabel("Case"), "Case")
        XCTAssertEqual(DeviceMerge.partLabel("Neckband"), "Neckband", "a FUTURE part surfaces verbatim, never vanishes")
    }

    // MARK: - dedupe via Accessory Identifier

    private func source(_ name: String, _ id: String?, _ part: String?, _ pct: Int,
                        charging: Bool? = nil, category: String? = "Headset") -> AccessoryPowerSource {
        AccessoryPowerSource(name: name, accessoryID: id, partID: part, category: category,
                             percent: pct, isCharging: charging, transport: "Bluetooth LE")
    }

    func testDistinctIdentifiersWithTheSameNameStayDistinctDevices() {
        // Two identically-named single-part devices are TWO devices — this is exactly what the old
        // name-string dedupe key collapsed into one row.
        let acc = [source("Magic Mouse", "AAA", "Single", 55, category: "Mouse"),
                   source("Magic Mouse", "BBB", "Single", 91, category: "Mouse")]
        let merged = DeviceMerge.merge(accessories: acc, ioreg: [], asOf: 1)
        XCTAssertEqual(merged.count, 2, "same name, different Accessory Identifier → two rows")
        XCTAssertEqual(Set(merged.map { $0.id }), ["AAA", "BBB"])
        XCTAssertTrue(merged.allSatisfy { $0.deviceClass == .mouse })
    }

    func testSameIdentifierAlwaysCollapsesToOneRow() {
        let acc = [source("Buds", "SAME", "Left", 70), source("Buds", "SAME", "Right", 71)]
        XCTAssertEqual(DeviceMerge.merge(accessories: acc, ioreg: [], asOf: 1).count, 1)
    }

    func testLabeledPartsSplitAcrossIdentifiersStillCoalesce() {
        // Apple does not document whether the parts of ONE accessory share an Accessory Identifier, and
        // only a single-part accessory was available to observe. If they DON'T, the disjoint-part
        // coalesce keeps an AirPods set on one row instead of splintering it into three.
        let acc = [source("Alex’s AirPods Pro", "P1", "Case", 84),
                   source("Alex’s AirPods Pro", "P2", "Left", 80),
                   source("Alex’s AirPods Pro", "P3", "Right", 80)]
        let merged = DeviceMerge.merge(accessories: acc, ioreg: [], asOf: 1)
        XCTAssertEqual(merged.count, 1, "same name + disjoint labelled parts → one device under either reading")
        XCTAssertEqual(merged[0].components.map { $0.label }, ["Case", "Left", "Right"])
    }

    func testSourcesWithNoIdentifierFallBackToTheNameKey() {
        let acc = [source("Nameless Buds", nil, "Left", 40), source("Nameless Buds", nil, "Right", 41)]
        let merged = DeviceMerge.merge(accessories: acc, ioreg: [], asOf: 1)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "name:Nameless Buds")
    }

    // MARK: - the retained ioreg fallback

    func testParseIoregSyntheticFixture() {
        let devs = DeviceParsers.parseIoreg(fixture("ioreg-batterypercent-synthetic.txt"))
        XCTAssertEqual(devs.count, 1)
        XCTAssertEqual(devs[0].name, "Magic Mouse")
        XCTAssertEqual(devs[0].percent, 55)
        XCTAssertNil(devs[0].charging, "charging never inferred from BatteryStatusFlags")
    }

    func testIoregGarbledYieldsNothing() {
        XCTAssertTrue(DeviceParsers.parseIoreg(fixture("ioreg-garbled.txt")).isEmpty, "no BatteryPercent → no device")
        XCTAssertTrue(DeviceParsers.parseIoreg("").isEmpty)
    }

    func testIoregRowsMergeAsUnlabeledDevicesButNeverShadowIOPS() {
        let io = DeviceParsers.parseIoreg(fixture("ioreg-batterypercent-synthetic.txt"))
        let alone = DeviceMerge.merge(accessories: [], ioreg: io, asOf: 5)
        XCTAssertEqual(alone.count, 1)
        XCTAssertEqual(alone[0].components, [DeviceBatteryComponent(label: nil, percent: 55, charging: nil)])
        XCTAssertEqual(alone[0].address, "aa-bb-cc-dd-ee-04", "the fallback carries the BT address for free")

        // Same device seen by BOTH: IOPS wins, no duplicate row.
        let both = DeviceMerge.merge(accessories: [source("Magic Mouse", "MID", "Single", 60, category: "Mouse")],
                                     ioreg: io, asOf: 5)
        XCTAssertEqual(both.count, 1, "IOPS + ioreg saw the same device → one row")
        XCTAssertEqual(both[0].id, "MID")
        XCTAssertEqual(both[0].components.first?.percent, 60)
    }

    // MARK: - class → symbol totality

    func testClassToSymbolTotality() {
        for cls in DeviceClass.allCases {
            XCTAssertFalse(cls.sfSymbol.isEmpty, "\(cls) must map to a non-blank symbol")
        }
        XCTAssertEqual(DeviceClass.classify(name: "Alex’s AirPods Max", category: "Headset"), .airpodsMax)
        XCTAssertEqual(DeviceClass.classify(name: "Alex’s AirPods Pro #3", category: "Headset"), .airpods)
        XCTAssertEqual(DeviceClass.classify(name: "Magic Mouse", category: nil), .mouse)
        // Accessory Category carries the class when the name says nothing (replaces sp's "Minor Type").
        XCTAssertEqual(DeviceClass.classify(name: "SMSL BT4.2", category: "Headset"), .headphones)
        XCTAssertEqual(DeviceClass.classify(name: "Model A1657", category: "Keyboard"), .keyboard)
        XCTAssertEqual(DeviceClass.classify(name: "Weird Speaker", category: nil), .generic)   // fallback
    }

    // MARK: - staleness

    func testStalenessFormatting() {
        XCTAssertNil(DeviceStaleness.note(asOf: 100, now: 105), "fresh < 10 s → no note")
        XCTAssertEqual(DeviceStaleness.note(asOf: 100, now: 130), "as of 30s ago")
        XCTAssertEqual(DeviceStaleness.note(asOf: 100, now: 100 + 3 * 60), "as of 3m ago")
        XCTAssertEqual(DeviceStaleness.note(asOf: 100, now: 100 + 2 * 3600), "as of 2h ago")
    }

    // MARK: - empty → hidden (the card shows the state note, never nothing at all)

    func testEmptyMergeYieldsNoDevices() {
        XCTAssertTrue(DeviceMerge.merge(accessories: [], ioreg: [], asOf: 1).isEmpty)
    }

    func testReadStateNotes() {
        XCTAssertNil(DeviceReadState.devices.note, "the healthy state is the only silent one")
        XCTAssertEqual(DeviceReadState.noneConnected.note, "No connected device reports a battery.")
        XCTAssertEqual(DeviceReadState.unavailable("the sky fell").note,
                       "Device batteries unavailable — the sky fell.")
    }

    // MARK: - the live reader (boundary): symbol-missing must be honest, never a crash or silent empty

    func testLiveReaderReportsUnavailableWhenTheSymbolIsMissing() {
        let reader = LiveAccessoryPowerSourceReader(symbolName: "IOPSCopyPowerSourcesByType_NOT_A_REAL_SYMBOL")
        guard case .unavailable(let why) = reader.read() else {
            return XCTFail("a missing symbol must report .unavailable, not an empty read")
        }
        XCTAssertTrue(why.contains("IOPSCopyPowerSourcesByType_NOT_A_REAL_SYMBOL"), "the reason names the symbol")
    }

    func testLiveReaderResolvesTheRealSymbolAndReadsWithoutCrashing() {
        // Smoke test of the real boundary: the symbol resolves on this OS and the read completes. The
        // accessory list depends on what is connected, so only the outcome SHAPE is asserted.
        guard case .read = LiveAccessoryPowerSourceReader().read() else {
            return XCTFail("IOPSCopyPowerSourcesByType must resolve and read on this OS")
        }
    }

    // MARK: - ProcessProbe timeout kill-test (real subprocess; still used by the ioreg fallback)

    func testProcessProbeKillsOnTimeout() async {
        let r = await ProcessProbe().run("/bin/sleep", args: ["10"], timeout: 0.3)
        XCTAssertTrue(r.timedOut, "a 10 s sleep with a 0.3 s timeout is killed, not awaited")
        XCTAssertLessThan(r.duration, 3.0, "returns promptly after the kill — never hangs")
    }

    func testProcessProbeReturnsStdoutOnSuccess() async {
        let r = await ProcessProbe().run("/bin/echo", args: ["hello"], timeout: 5)
        XCTAssertFalse(r.timedOut); XCTAssertFalse(r.launchFailed)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testProcessProbeLaunchFailure() async {
        let r = await ProcessProbe().run("/nonexistent/binary/xyz", args: [], timeout: 1)
        XCTAssertTrue(r.launchFailed)
    }
}
