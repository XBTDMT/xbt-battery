import XCTest

/// spec 31 §3 / §5 "Port source": the three-state reading, port hysteresis across reads, sourcing
/// episodes, the per-OS-build "ever seen" key, the averaged pair and its resets, the band held across
/// reads, and the unread paths. Host-app-free: fixture defaults suite, fixture clocks, no USB bus.
@MainActor
final class PortPowerSourceTests: XCTestCase {

    private let mono = MockClockBox(0)
    private let up = MockClockBox(0)
    private let iPhone = [PortPowerFixtures.capturedIPhoneElement()]

    private func freshDefaults() throws -> UserDefaults {
        let suite = "portpower-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSource(defaults: UserDefaults? = nil, build: String = "26B5091g") throws -> PortPowerSource {
        let mono = self.mono, up = self.up
        return PortPowerSource(defaults: try defaults ?? freshDefaults(),
                               now: { Date(timeIntervalSince1970: 1_790_630_400) },
                               clocks: MonotonicClocks(monotonicRaw: { mono.now }, uptimeRaw: { up.now }),
                               usb: EmptyUSBLeafEnumerator(),
                               osBuild: { build })
    }

    private func feed(_ source: PortPowerSource, _ props: [String: Any], at t: TimeInterval) {
        mono.now = t
        up.now = t - 10
        source.ingest(.read(props))
    }

    private func unread(_ source: PortPowerSource, at t: TimeInterval) {
        mono.now = t
        up.now = t - 10
        source.ingest(.unread)
    }

    // MARK: three states

    func testBeforeTheFirstReadIsNotYetRead() throws {
        let source = try makeSource()
        XCTAssertEqual(source.reading, .notYetRead)
        XCTAssertNil(source.launchSeedAt)
    }

    func testCapturedElementReadsAsOnePort() throws {
        let source = try makeSource()
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: PortPowerFixtures.base, externalConnected: true), at: 100)
        XCTAssertEqual(source.reading, .read([PortPowerFixtures.capturedIPhonePort]))
        XCTAssertEqual(source.drawingPortIndices, [2])
        XCTAssertEqual(source.drawingWatts, 14.054, accuracy: 0.000_1)
        XCTAssertEqual(source.updateTime, 1_790_630_342)
        XCTAssertEqual(source.externalConnected, true)
    }

    func testAbsentKeyReadsAsNoPorts() throws {
        let source = try makeSource()
        feed(source, PortPowerFixtures.props(ports: nil, frame: PortPowerFixtures.base, externalConnected: true), at: 100)
        XCTAssertEqual(source.reading, .read([]))
        XCTAssertEqual(source.drawingPortIndices, [])
    }

    func testFailedReadIsUnreadNeverStaleRows() throws {
        let source = try makeSource()
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: PortPowerFixtures.base, externalConnected: true), at: 100)
        unread(source, at: 160)
        XCTAssertEqual(source.reading, .unread, "a failed read replaces the rows — never the last rows again")
        XCTAssertEqual(source.band, .none)
        XCTAssertNil(source.costLine)
    }

    func testMalformedPortsKeyIsUnread() throws {
        let source = try makeSource()
        var props = PortPowerFixtures.props(ports: nil, frame: PortPowerFixtures.base, externalConnected: true)
        props[PortPowerParser.portsKey] = "garbage"
        feed(source, props, at: 100)
        XCTAssertEqual(source.reading, .unread)
    }

    func testFirstReadFailingLeavesNoSeed() throws {
        let source = try makeSource()
        unread(source, at: 100)
        XCTAssertEqual(source.reading, .unread)
        XCTAssertNil(source.launchSeedAt, "only a SUCCESSFUL read seeds")
        feed(source, PortPowerFixtures.props(ports: nil, frame: PortPowerFixtures.base, externalConnected: false), at: 160)
        XCTAssertEqual(source.launchSeedAt, 160)
    }

    // MARK: hysteresis + episodes + clocks

    func testPortHysteresisHeldAcrossReadsAndForgottenWhenAbsent() throws {
        let source = try makeSource()
        let steps: [(Int?, Set<Int>)] = [(600, [2]), (400, [2]), (250, []), (400, []), (520, [2]), (nil, []), (400, [])]
        for (i, step) in steps.enumerated() {
            let ports = step.0.map { [PortPowerFixtures.element(portIndex: 2, filteredPower: $0)] }
            feed(source, PortPowerFixtures.props(ports: ports, frame: PortPowerFixtures.base, externalConnected: true),
                 at: 100 + 60 * Double(i))
            XCTAssertEqual(source.drawingPortIndices, step.1, "step \(i): \(String(describing: step.0)) mW")
        }
    }

    func testEpisodesStampFirstDrawingAndThePreviousPresentRead() throws {
        let source = try makeSource()
        let base = PortPowerFixtures.base
        feed(source, PortPowerFixtures.props(ports: nil, frame: base, externalConnected: false), at: 100)
        XCTAssertEqual(source.launchSeedAt, 100)

        feed(source, PortPowerFixtures.props(ports: iPhone, frame: base, externalConnected: false), at: 160)
        XCTAssertEqual(source.episodes[2], PortEpisode(startedAt: 160, previousPresentAt: nil, firstDrawingAt: 160))
        XCTAssertEqual(source.newlyDrawingPortIndices, [2])

        feed(source, PortPowerFixtures.props(ports: iPhone, frame: base, externalConnected: false), at: 220)
        XCTAssertEqual(source.newlyDrawingPortIndices, [], "only the first drawing read of an episode is new")

        unread(source, at: 250)
        XCTAssertNotNil(source.episodes[2], ".unread carries no information — the episode goes on")

        feed(source, PortPowerFixtures.props(ports: nil, frame: base, externalConnected: false), at: 280)
        XCTAssertNil(source.episodes[2], "absent on a good read ends the episode")

        feed(source, PortPowerFixtures.props(ports: [PortPowerFixtures.element(portIndex: 2, filteredPower: 200)],
                                             frame: base, externalConnected: false), at: 400)
        XCTAssertEqual(source.episodes[2], PortEpisode(startedAt: 400, previousPresentAt: 220, firstDrawingAt: nil))
        XCTAssertEqual(source.newlyDrawingPortIndices, [])

        feed(source, PortPowerFixtures.props(ports: [PortPowerFixtures.element(portIndex: 2, filteredPower: 600)],
                                             frame: base, externalConnected: false), at: 460)
        XCTAssertEqual(source.episodes[2], PortEpisode(startedAt: 400, previousPresentAt: 220, firstDrawingAt: 460))
        XCTAssertEqual(source.newlyDrawingPortIndices, [2])
    }

    func testClocksAreSampledOnEveryIngestIncludingUnread() throws {
        let source = try makeSource()
        unread(source, at: 500)
        XCTAssertEqual(source.lastClocks?.monotonicRaw, 500)
        XCTAssertEqual(source.lastClocks?.uptimeRaw, 490)
        feed(source, PortPowerFixtures.props(ports: nil, frame: nil, externalConnected: nil), at: 560)
        XCTAssertEqual(source.lastClocks?.monotonicRaw, 560)
    }

    // MARK: ever seen on this OS build

    func testEverSeenKeyIsPerOSBuild() throws {
        let defaults = try freshDefaults()
        let first = try makeSource(defaults: defaults, build: "26B5091g")
        feed(first, PortPowerFixtures.props(ports: nil, frame: PortPowerFixtures.base, externalConnected: true), at: 100)
        XCTAssertFalse(first.seenOnThisBuild, "no PowerOutDetails yet on this build")
        feed(first, PortPowerFixtures.props(ports: iPhone, frame: PortPowerFixtures.base, externalConnected: true), at: 160)
        XCTAssertTrue(first.seenOnThisBuild)
        XCTAssertEqual(defaults.string(forKey: PortPowerSource.seenOnBuildKey), "26B5091g")

        let relaunch = try makeSource(defaults: defaults, build: "26B5091g")
        XCTAssertTrue(relaunch.seenOnThisBuild, "seen survives a relaunch on the same build")

        let updated = try makeSource(defaults: defaults, build: "26C5010a")
        XCTAssertFalse(updated.seenOnThisBuild, "every macOS update (betas included) resets it")
    }

    func testEmptyOSBuildNeverMarksSeen() throws {
        let defaults = try freshDefaults()
        let source = try makeSource(defaults: defaults, build: "")
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: PortPowerFixtures.base, externalConnected: true), at: 100)
        XCTAssertFalse(source.seenOnThisBuild, "an unreadable build is not a build")
        XCTAssertNil(defaults.string(forKey: PortPowerSource.seenOnBuildKey))
    }

    func testLiveOSBuildIsReadable() {
        XCTAssertFalse(PortPowerSource.liveOSBuild().isEmpty, "kern.osversion reads on this Mac")
    }

    // MARK: averaged pair → cost line (on battery)

    func testOnBatteryCostLineFromTheAveragedPair() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.discharging(f0)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: false, systemPowerIn: 0, batteryPower: -24_000), at: 100)
        XCTAssertNil(source.costLine, "one frame is not a pair")
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: false, systemPowerIn: 0, batteryPower: -26_000), at: 160)
        XCTAssertEqual(source.packPower_mW ?? .nan, -25_000, accuracy: 0.001)
        XCTAssertEqual(source.costLine, BatteryCostLine(percentPerHour: 22, timeLeft: 4_260, timeLeftWithout: 9_660))
        XCTAssertEqual(source.band, .none, "no on-power band on battery")
    }

    func testAPairStraddlingAnUnplugMakesNoLine() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.discharging(f0), f2 = PortPowerFixtures.discharging(f1)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: true), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: false, systemPowerIn: 0), at: 160)
        XCTAssertNil(source.packPower_mW, "the pair reset when ExternalConnected changed")
        XCTAssertNil(source.costLine)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f2, externalConnected: false, systemPowerIn: 0), at: 220)
        XCTAssertEqual(source.packPower_mW ?? .nan, -25_000, accuracy: 0.001)
        XCTAssertNotNil(source.costLine)
    }

    func testRepeatedFrameDoesNotCollapseThePair() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.discharging(f0)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: false, systemPowerIn: 0), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: false, systemPowerIn: 0), at: 160)
        let before = source.costLine
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: false, systemPowerIn: 0), at: 170)
        XCTAssertEqual(source.packPower_mW ?? .nan, -25_000, accuracy: 0.001, "a repeated frame (same counts) is not a new frame")
        XCTAssertEqual(source.costLine, before)
    }

    func testAnUnreadReadBetweenFramesKeepsThePair() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.discharging(f0), f2 = PortPowerFixtures.discharging(f1)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: false, systemPowerIn: 0), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: false, systemPowerIn: 0), at: 160)
        unread(source, at: 190)
        XCTAssertNil(source.costLine, "unread → no claim")
        XCTAssertEqual(source.reading, .unread)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f2, externalConnected: false, systemPowerIn: 0), at: 220)
        XCTAssertEqual(source.costLine, BatteryCostLine(percentPerHour: 22, timeLeft: 4_260, timeLeftWithout: 9_660),
                       "the pair and the hysteresis survived the unread read")
        XCTAssertEqual(source.drawingPortIndices, [2])
    }

    func testMissingExternalConnectedMakesNoClaims() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.discharging(f0)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: nil), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: nil), at: 160)
        XCTAssertNil(source.externalConnected)
        XCTAssertNil(source.packPower_mW)
        XCTAssertNil(source.costLine)
        XCTAssertEqual(source.band, .none)
        XCTAssertEqual(source.reading, .read([PortPowerFixtures.capturedIPhonePort]), "the rows themselves still read")
    }

    func testBankCountAbsentMakesNoCostLine() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.discharging(f0)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: false, bankCount: nil, systemPowerIn: 0), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: false, bankCount: nil, systemPowerIn: 0), at: 160)
        XCTAssertEqual(source.packPower_mW ?? .nan, -25_000, accuracy: 0.001)
        XCTAssertNil(source.costLine, "no BankCount → no nominal volts → no line")
    }

    func testBatteryDataBatteryPowerIsNeverAFallback() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.discharging(f0)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: false, systemPowerIn: 0), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: false, systemPowerIn: 0), at: 160)
        XCTAssertNotNil(source.costLine)
        // PowerTelemetryData gone; BatteryData.BatteryPower (−12 000, the decoy) is still in the dict.
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: nil, externalConnected: false), at: 220)
        XCTAssertNil(source.packPower_mW)
        XCTAssertNil(source.costLine)
        XCTAssertEqual(source.reading, .read([PortPowerFixtures.capturedIPhonePort]))
    }

    // MARK: on-power band across reads

    func testFlipFloppingSingleFramesHoldOneBand() throws {
        let source = try makeSource()
        var f = PortPowerFixtures.base
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f, externalConnected: true,
                                             systemPowerIn: 50_000, batteryPower: 7_200), at: 100)
        XCTAssertEqual(source.band, .none, "one frame is not a pair — no claim yet")
        for (i, single) in [7_600, -3_600, 7_200].enumerated() {
            f = PortPowerFixtures.charging(f)
            feed(source, PortPowerFixtures.props(ports: iPhone, frame: f, externalConnected: true,
                                                 updateTime: 1_790_630_342 + 60 * (i + 1),
                                                 systemPowerIn: 50_000, batteryPower: single),
                 at: 160 + 60 * Double(i))
            XCTAssertEqual(source.packPower_mW ?? .nan, 5_600, accuracy: 0.001)
            XCTAssertEqual(source.band, .headroom, "single frame \(single) mW must not move the band")
        }
    }

    func testSystemPowerInZeroOnACIsUnreadAndHoldsSaturation() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base
        let f1 = PortPowerFixtures.charging(f0), f2 = PortPowerFixtures.charging(f1), f3 = PortPowerFixtures.charging(f2)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: true, systemPowerIn: 61_000), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: true, systemPowerIn: 61_000), at: 160)
        XCTAssertEqual(source.band, .slower(watts: 14))
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f2, externalConnected: true, systemPowerIn: 0, batteryPower: -52_000), at: 220)
        XCTAssertEqual(source.band, .none, "SystemPowerIn 0 on AC is unread → no line")
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f3, externalConnected: true, systemPowerIn: 57_000), at: 280)
        XCTAssertEqual(source.band, .slower(watts: 14), "87.7 % is inside the hold the 0 frame did not disturb")
    }

    func testChargerSwapReEvaluatesTheBand() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.charging(f0), f2 = PortPowerFixtures.charging(f1)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: true, systemPowerIn: 61_000), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: true, systemPowerIn: 61_000), at: 160)
        XCTAssertEqual(source.band, .slower(watts: 14))
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f2, externalConnected: true,
                                             ipdInputPower: 68_000, systemPowerIn: 60_000), at: 220)
        XCTAssertEqual(source.band, .headroom, "88.2 % of the new 68 W ceiling, judged fresh")
    }

    // MARK: fix round 1 (S3.4) — behaviour pins + the unread-flag band hold

    func testGoodUnreadGoodKeepsTheEpisodeAndNothingIsNewAgain() throws {
        let source = try makeSource()
        let base = PortPowerFixtures.base
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: base, externalConnected: false), at: 100)
        XCTAssertEqual(source.newlyDrawingPortIndices, [2])
        unread(source, at: 130)
        XCTAssertEqual(source.newlyDrawingPortIndices, [], "an unread read announces nothing")
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: base, externalConnected: false), at: 160)
        XCTAssertEqual(source.newlyDrawingPortIndices, [], "the port was already drawing before the unread read")
        XCTAssertEqual(source.episodes[2]?.firstDrawingAt, 100, "the episode and its first-drawing stamp survived")
        XCTAssertEqual(source.episodes[2]?.startedAt, 100)
    }

    func testAPortHeldOnBetweenThresholdsSurvivesAnUnreadRead() throws {
        let source = try makeSource()
        let base = PortPowerFixtures.base
        func one(_ mW: Int) -> [String: Any] {
            PortPowerFixtures.props(ports: [PortPowerFixtures.element(portIndex: 2, filteredPower: mW)],
                                    frame: base, externalConnected: true)
        }
        feed(source, one(600), at: 100)
        feed(source, one(400), at: 160)
        XCTAssertEqual(source.drawingPortIndices, [2])
        unread(source, at: 190)
        XCTAssertEqual(source.drawingPortIndices, [2], "unread carries no information — the hold is untouched")
        feed(source, one(400), at: 220)
        XCTAssertEqual(source.drawingPortIndices, [2], "400 mW is between 0.3 and 0.5 W: still held on")
    }

    func testMalformedPortsReadLeavesThePairAndEpisodesIntact() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base, f1 = PortPowerFixtures.discharging(f0), f2 = PortPowerFixtures.discharging(f1)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: false, systemPowerIn: 0), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: false, systemPowerIn: 0), at: 160)
        let episode = source.episodes[2]
        XCTAssertNotNil(episode)
        var bad = PortPowerFixtures.props(ports: nil, frame: f2, externalConnected: false, systemPowerIn: 0)
        bad[PortPowerParser.portsKey] = "garbage"
        feed(source, bad, at: 190)
        XCTAssertEqual(source.reading, .unread)
        XCTAssertNil(source.costLine)
        XCTAssertEqual(source.episodes[2], episode, "a malformed read ends no episode")
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f2, externalConnected: false, systemPowerIn: 0), at: 220)
        XCTAssertEqual(source.costLine, BatteryCostLine(percentPerHour: 22, timeLeft: 4_260, timeLeftWithout: 9_660),
                       "the malformed read's frame was not ingested and did not disturb the pair")
    }

    func testTheSeedReadAnnouncesADeviceAlreadyDrawing() throws {
        let source = try makeSource()
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: PortPowerFixtures.base, externalConnected: false), at: 100)
        XCTAssertEqual(source.launchSeedAt, 100)
        XCTAssertEqual(source.newlyDrawingPortIndices, [2],
                       "fires on the seed read for a device already plugged in — so it must not drive a notice")
        XCTAssertEqual(source.episodes[2], PortEpisode(startedAt: 100, previousPresentAt: nil, firstDrawingAt: 100))
    }

    func testACBatteryACResetsTheBandHold() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base
        let f1 = PortPowerFixtures.charging(f0), f2 = PortPowerFixtures.charging(f1)
        let f3 = PortPowerFixtures.charging(f2), f4 = PortPowerFixtures.charging(f3)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: true, systemPowerIn: 61_000), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: true, systemPowerIn: 61_000), at: 160)
        XCTAssertEqual(source.band, .slower(watts: 14), "saturated before the unplug")
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f2, externalConnected: false, systemPowerIn: 0), at: 220)
        XCTAssertEqual(source.band, .none)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f3, externalConnected: true, systemPowerIn: 57_000), at: 280)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f4, externalConnected: true, systemPowerIn: 57_000), at: 340)
        XCTAssertEqual(source.band, .headroom, "a real power-source change re-judges fresh: 87.7 % is not saturated")
    }

    func testAnUnreadACFlagKeepsTheBandHoldOnTheSameCharger() throws {
        let source = try makeSource()
        let f0 = PortPowerFixtures.base
        let f1 = PortPowerFixtures.charging(f0), f2 = PortPowerFixtures.charging(f1)
        let f3 = PortPowerFixtures.charging(f2), f4 = PortPowerFixtures.charging(f3)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f0, externalConnected: true, systemPowerIn: 61_000), at: 100)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f1, externalConnected: true, systemPowerIn: 61_000), at: 160)
        XCTAssertEqual(source.band, .slower(watts: 14))
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f2, externalConnected: nil), at: 220)
        XCTAssertEqual(source.band, .none, "ExternalConnected unread → no line")
        XCTAssertNil(source.packPower_mW, "the pair is dropped: that frame's source is unknown")
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f3, externalConnected: true, systemPowerIn: 57_000), at: 280)
        feed(source, PortPowerFixtures.props(ports: iPhone, frame: f4, externalConnected: true, systemPowerIn: 57_000), at: 340)
        XCTAssertEqual(source.band, .slower(watts: 14),
                       "an unread flag is neither a power-source nor a ceiling change: 87.7 % stays inside the hold")
    }
}
