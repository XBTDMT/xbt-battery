import XCTest

/// 31 §2.1 · the section's pure model: every row state, the header, the cost line, the bands, the stale
/// label, the "listed once" flag, and quantisation (raw jitter inside a tenth is the same display).
final class PortPowerDisplayModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let bolt = "\u{26A1}\u{FE0E}"
    private let iPhone = PortName(name: "iPhone", kind: .iphone)
    private let keyboard = PortName(name: "Magic Keyboard", kind: .keyboard)

    private func port(_ i: Int, _ mW: Int, contract: Int? = 15_000) -> PortPower {
        PortPower(portIndex: i, filteredPower_mW: mW, watts_mW: mW, contract_mW: contract, current_mA: nil,
                  voltage_mV: nil, accumulatedPower: nil, accumulatorCount: nil)
    }

    private func build(_ ports: [PortPower], drawing: Set<Int>? = nil, names: [Int: PortName] = [:],
                       phone: PhoneLink? = nil, onBattery: Bool? = false, band: OnPowerBand = .none,
                       cost: BatteryCostLine? = nil, age: Int = 30, everSeen: Bool = true,
                       reading: PortPowerReading? = nil) -> PortPowerDisplay {
        PortPowerDisplayModel.build(PortPowerDisplayInput(
            everSeen: everSeen, reading: reading ?? .read(ports),
            drawing: drawing ?? Set(ports.filter { $0.filteredPower_mW >= 500 }.map(\.portIndex)),
            names: names, phone: phone, onBattery: onBattery, band: band, cost: cost,
            updateTime: Int(now.timeIntervalSince1970) - age, now: now))
    }

    // MARK: visibility

    func testHiddenUntilSeenOnThisBuild() {
        XCTAssertEqual(build([port(2, 9_200)], everSeen: false), .hidden)
    }

    func testHiddenBeforeTheFirstRead() {
        XCTAssertEqual(build([], reading: .notYetRead), .hidden)
    }

    func testUnreadSaysSoAndHasNoRows() {
        let d = build([], reading: .unread)
        XCTAssertEqual(d.visibility, .unread)
        XCTAssertTrue(d.rows.isEmpty)
    }

    func testNothingSourcingIsHidden() {
        XCTAssertEqual(build([]), .hidden)
    }

    // MARK: rows

    func testNamedDrawingRowIsMeasuredWithTheContractOnlyInTheHover() {
        let d = build([port(2, 9_200)], names: [2: iPhone], phone: PhoneLink(percent: 88, charging: true, usbPowered: true))
        XCTAssertEqual(d.visibility, .shown)
        XCTAssertEqual(d.rows, [.init(id: "port2", symbol: "iphone", name: "iPhone", detail: "· cable · 88% \(bolt)",
                                      state: .drawing(tenthsW: 92), contractW: 15)])
        XCTAssertEqual(d.totalTenthsW, 92)
        XCTAssertEqual(PortPowerDisplayModel.watts(tenths: 92), "9.2 W")
        XCTAssertEqual(PortPowerDisplayModel.spokenValue(d.rows[0]), "9.2 watts, exact, up to 15 watts")
    }

    func testUnnamedDrawingPortIsAUSBCDevice() {
        let d = build([port(1, 4_500)])
        XCTAssertEqual(d.rows.first?.name, "USB-C device")
        XCTAssertEqual(d.rows.first?.symbol, "cable.connector")
        XCTAssertEqual(d.rows.first?.detail, "· cable")
    }

    func testUnnamedQuietPortIsNotListed() {
        XCTAssertEqual(build([port(1, 200)], drawing: []), .hidden)
    }

    func testNamedQuietPortIsConnectedWithNoPowerClaim() {
        let d = build([port(1, 200, contract: 2_500)], drawing: [], names: [1: keyboard])
        XCTAssertEqual(d.rows.first?.state, .notDrawing)
        XCTAssertNil(d.totalTenthsW)
        XCTAssertNil(d.costSentence)
        XCTAssertEqual(PortPowerDisplayModel.notDrawingWording, "connected")
    }

    func testRowsSortByWattsCapAtThreeAndTheTotalCountsEveryDrawingPort() {
        let d = build([port(1, 1_000), port(2, 9_200), port(3, 4_500), port(4, 600), port(5, 2_000)])
        XCTAssertEqual(d.rows.map(\.id), ["port2", "port3", "port5"])
        XCTAssertEqual(d.overflow, 2)
        XCTAssertEqual(d.totalTenthsW, 10 + 92 + 45 + 6 + 20)
    }

    func testPhonePortUnknownRowComesFirstWithTheCaption() {
        let d = build([port(1, 6_100), port(2, 4_200)], phone: PhoneLink(percent: 33, charging: true, usbPowered: true))
        XCTAssertEqual(d.rows.first, .init(id: "phone", symbol: "iphone", name: "iPhone", detail: "· cable · 33% \(bolt)",
                                           state: .phonePortUnknown, contractW: nil))
        XCTAssertEqual(d.rows.count, 3)
        XCTAssertTrue(d.oneIsPhoneCaption)
        XCTAssertTrue(d.phoneInPowered)
    }

    func testPhoneInPoweredFlagFollowsNamedOrUnknownPhone() {
        let usbPhone = PhoneLink(percent: 33, charging: true, usbPowered: true)
        XCTAssertTrue(build([port(1, 6_100), port(2, 4_200)], names: [2: iPhone], phone: usbPhone).phoneInPowered)
        XCTAssertFalse(build([port(1, 6_100), port(2, 4_200)], names: [2: iPhone], phone: usbPhone).oneIsPhoneCaption)
        XCTAssertFalse(build([port(1, 6_100)], phone: usbPhone).phoneInPowered,
                       "one port: corroboration (b) is the source's job, not a port-unknown row")
        XCTAssertFalse(build([port(1, 6_100), port(2, 4_200)],
                             phone: PhoneLink(percent: 33, charging: false, usbPowered: false)).phoneInPowered)
    }

    // MARK: header + cost line

    func testHeaderFigureNeverSaysTotalUntilU2AndU4() {
        XCTAssertEqual(PortPowerDisplayModel.headerFigure(totalTenths: 147, onBattery: false), "14.7 W")
        XCTAssertEqual(PortPowerDisplayModel.headerFigure(totalTenths: 147, onBattery: true), "14.7 W from battery")
    }

    func testOnBatteryCostSentenceWithAndWithoutTPrime() {
        let full = build([port(2, 9_200)], onBattery: true,
                         cost: BatteryCostLine(percentPerHour: 23, timeLeft: 43 * 60, timeLeftWithout: 92 * 60))
        XCTAssertTrue(full.onBattery)
        XCTAssertEqual(full.costSentence, "≈ 23% of your battery per hour — 43 min left with them, ≈ 1 h 32 m without")
        let noPrime = build([port(2, 9_200)], onBattery: true,
                            cost: BatteryCostLine(percentPerHour: 23, timeLeft: 43 * 60, timeLeftWithout: nil))
        XCTAssertEqual(noPrime.costSentence, "≈ 23% of your battery per hour — 43 min left with them")
        XCTAssertNil(build([port(2, 9_200)], onBattery: true, cost: nil).costSentence, "any input unread → no line")
    }

    func testDurationFormattingIncludingOverTenHours() {
        XCTAssertEqual(PortPowerDisplayModel.formatDuration(38 * 60), "38 min")
        XCTAssertEqual(PortPowerDisplayModel.formatDuration(75 * 60), "1 h 15 m")
        XCTAssertEqual(PortPowerDisplayModel.formatDuration(120 * 60), "2 h")
        XCTAssertEqual(PortPowerDisplayModel.formatDuration(10 * 3_600), "10 h")
        XCTAssertEqual(PortPowerDisplayModel.formatDuration(10 * 3_600 + 60), "> 10 h")
    }

    func testOnPowerBandSentences() {
        XCTAssertEqual(build([port(2, 9_200)], band: .headroom).costSentence, "Doesn't slow your Mac's charging")
        XCTAssertEqual(build([port(2, 9_200)], band: .slower(watts: 11)).costSentence, "Your Mac charges ≈ 11 W slower")
        XCTAssertEqual(build([port(2, 9_200)], band: .fromBattery(watts: 4)).costSentence, "≈ 4 W is coming from your battery")
        XCTAssertNil(build([port(2, 9_200)], band: .none).costSentence, "dead band / limit hold → no line")
    }

    func testUnreadPowerSourceShowsNoCostAndNoYellow() {
        let d = build([port(2, 9_200)], onBattery: nil, band: .slower(watts: 9),
                      cost: BatteryCostLine(percentPerHour: 15, timeLeft: 3_600, timeLeftWithout: nil))
        XCTAssertFalse(d.onBattery)
        XCTAssertNil(d.costSentence)
    }

    // MARK: freshness, quantisation, percent per hour

    func testStaleAsOfAfter120Seconds() {
        XCTAssertNil(build([port(2, 9_200)], age: 120).staleAsOf)
        XCTAssertEqual(build([port(2, 9_200)], age: 121).staleAsOf?.hasPrefix("as of "), true)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PortPowerDisplayModel.staleStamp(updateTime: 1_790_000_000 - 300, now: now, calendar: utc), "as of 14:08")
    }

    func testRawJitterInsideATenthIsTheSameDisplay() {
        XCTAssertEqual(build([port(2, 14_054)]), build([port(2, 14_071)]))
        XCTAssertNotEqual(build([port(2, 14_054)]), build([port(2, 14_160)]))
    }

    func testPercentPerHourFromThePackWattHours() {
        XCTAssertEqual(PortPowerDisplayModel.percentPerHour(portWatts: 9.2, fullCharge_mAh: 5_435, bankCount: 3), 15)
        XCTAssertNil(PortPowerDisplayModel.percentPerHour(portWatts: 9.2, fullCharge_mAh: 5_435, bankCount: nil))
        XCTAssertNil(PortPowerDisplayModel.percentPerHour(portWatts: 9.2, fullCharge_mAh: nil, bankCount: 3))
        XCTAssertNil(PortPowerDisplayModel.percentPerHour(portWatts: 0, fullCharge_mAh: 5_435, bankCount: 3))
    }

    // MARK: carried review rulings (S3.3 / S3.4)

    func testUnreadReadingWinsOverKeptDrawingAndNames() {
        // the source keeps drawing/names/updateTime at their last good values on an unread; none may become rows.
        let d = build([port(2, 9_200)], drawing: [2], names: [2: iPhone],
                      phone: PhoneLink(percent: 88, charging: true, usbPowered: true), onBattery: true,
                      band: .headroom, cost: BatteryCostLine(percentPerHour: 23, timeLeft: 3_600, timeLeftWithout: nil),
                      age: 500, reading: .unread)
        XCTAssertEqual(d, PortPowerDisplay(visibility: .unread))
        XCTAssertTrue(d.rows.isEmpty)
        XCTAssertNil(d.totalTenthsW)
        XCTAssertNil(d.costSentence)
        XCTAssertNil(d.staleAsOf)
        XCTAssertFalse(d.phoneInPowered)
    }

    func testCostSentenceNeverReadsZeroPercent() {
        let tiny = build([port(2, 9_200)], onBattery: true,
                         cost: BatteryCostLine(percentPerHour: 0, timeLeft: 5 * 3_600, timeLeftWithout: nil))
        XCTAssertEqual(tiny.costSentence, "< 1% of your battery per hour \u{2014} 5 h left with them")
        XCTAssertFalse(tiny.costSentence?.contains("0%") ?? true)
        XCTAssertEqual(PortPowerDisplayModel.formatPercent(0), "< 1%")
        XCTAssertEqual(PortPowerDisplayModel.formatPercent(1), "1%")
        XCTAssertEqual(PortPowerDisplayModel.formatPercent(23), "23%")
    }

    func testPercentPerHourForAHalfWattPortIsBelowOneAndFormatsAsSuch() {
        let x = PortPowerDisplayModel.percentPerHour(portWatts: 0.3, fullCharge_mAh: 5_435, bankCount: 3)
        XCTAssertEqual(x, 0)
        XCTAssertEqual(PortPowerDisplayModel.formatPercent(x ?? 0), "< 1%")
    }

    // MARK: fix round 1

    func testContractBelowHalfAWattOrZeroIsNoContract() {
        XCTAssertEqual(build([port(2, 9_200, contract: 0)]).rows.first?.contractW, nil)
        XCTAssertEqual(build([port(2, 9_200, contract: 499)]).rows.first?.contractW, nil)
        XCTAssertEqual(build([port(2, 9_200, contract: 500)]).rows.first?.contractW, 1)
        XCTAssertEqual(build([port(2, 9_200, contract: -5)]).rows.first?.contractW, nil)
        let quiet = build([port(1, 200, contract: 0)], drawing: [], names: [1: keyboard])
        XCTAssertNil(quiet.rows.first?.contractW)
        let d = build([port(2, 9_200, contract: 0)])
        XCTAssertEqual(PortPowerDisplayModel.spokenValue(d.rows[0]), "9.2 watts, exact")
    }

    func testSpokenValueNeverClaimsDrawingForAnUnknownPhonePort() {
        let d = build([port(1, 6_100), port(2, 4_200)], phone: PhoneLink(percent: 33, charging: true, usbPowered: true))
        XCTAssertEqual(d.rows.first?.state, .phonePortUnknown)
        XCTAssertEqual(PortPowerDisplayModel.spokenValue(d.rows[0]), "connected, port not identified")
    }

    func testTPrimeOverTenHoursDropsTheApproxSign() {
        let c = build([port(2, 9_200)], onBattery: true,
                      cost: BatteryCostLine(percentPerHour: 5, timeLeft: 3_600, timeLeftWithout: 11 * 3_600))
        XCTAssertEqual(c.costSentence, "≈ 5% of your battery per hour — 1 h left with them, > 10 h without them")
    }

    func testFormatDurationIsSafeForNonFiniteInput() {
        XCTAssertEqual(PortPowerDisplayModel.formatDuration(.nan), "> 10 h")
        XCTAssertEqual(PortPowerDisplayModel.formatDuration(.infinity), "> 10 h")
    }

    func testTheCaptionAndTheAsOfStampShareOneLine() {
        XCTAssertEqual(PortPowerDisplayModel.noteLine(oneIsPhoneCaption: true, staleAsOf: "as of 13:16"),
                       "one of these is the iPhone · as of 13:16", "owner ruling Q3 B")
        XCTAssertEqual(PortPowerDisplayModel.noteLine(oneIsPhoneCaption: true, staleAsOf: nil), "one of these is the iPhone")
        XCTAssertEqual(PortPowerDisplayModel.noteLine(oneIsPhoneCaption: false, staleAsOf: "as of 13:16"), "as of 13:16")
        XCTAssertNil(PortPowerDisplayModel.noteLine(oneIsPhoneCaption: false, staleAsOf: nil))
    }
}
