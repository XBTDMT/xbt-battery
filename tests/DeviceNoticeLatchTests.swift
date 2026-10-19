
import XCTest

/// 31 §2.2 (G-4) · the plug-in latch, fed on every read: seeded quietly, a port absent at the seed arms only
/// after a frame newer than the seed, sleep = (MONOTONIC_RAW − UPTIME_RAW) grew ≥ 1 s, re-armed only after
/// 120 s from the first absent read to the latest, `.unread` = no information, aggregated.
final class DeviceNoticeLatchTests: XCTestCase {

    /// A read at awake time `t` with `slept` seconds of sleep behind it: MONOTONIC_RAW − UPTIME_RAW = 50 + slept.
    private func r(_ ports: [Int: Int]?, ut: Int?, t: TimeInterval, slept: TimeInterval = 0) -> DeviceLatchRead {
        DeviceLatchRead(ports: ports, updateTime: ut, monotonicRaw: t + 50 + slept, uptimeRaw: t)
    }

    /// Seed at t = 0 with nothing sourcing, then the first fresh frame (UpdateTime 160 > 100).
    private func live() -> DeviceNoticeLatch {
        var l = DeviceNoticeLatch()
        XCTAssertEqual(l.ingest(r([:], ut: 100, t: 0)), [])
        XCTAssertEqual(l.ingest(r([:], ut: 160, t: 60)), [])
        return l
    }

    func testSeedReadDoesNotFire() {
        var l = DeviceNoticeLatch()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 100, t: 0)), [])
    }

    func testFirstFreshFrameIsQuietEvenForANewPort() {
        var l = DeviceNoticeLatch()
        _ = l.ingest(r([:], ut: 100, t: 0))
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 60)), [], "it may have been plugged in before that frame")
    }

    func testPlugInAfterTheFirstFreshFrameFires() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 70)), [2])
    }

    func testAPortPresentAtTheSeedStaysQuiet() {
        var l = DeviceNoticeLatch()
        _ = l.ingest(r([2: 9_000], ut: 100, t: 0))
        _ = l.ingest(r([2: 9_000], ut: 160, t: 60))
        XCTAssertEqual(l.ingest(r([2: 9_100], ut: 220, t: 120)), [])
    }

    func testStaleFrameAtWakeThenDrawingOnTheNextFrameIsQuiet() {
        var l = live()
        XCTAssertEqual(l.ingest(r([:], ut: 160, t: 80, slept: 3_600)), [], "wake read: a stale frame, re-seeds")
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 220, t: 90, slept: 3_600)), [], "plugged in during sleep: quiet")
    }

    func testPlugInAfterTheFirstFreshFrameAfterWakeFires() {
        var l = live()
        _ = l.ingest(r([:], ut: 160, t: 80, slept: 3_600))
        _ = l.ingest(r([:], ut: 220, t: 90, slept: 3_600))
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 220, t: 100, slept: 3_600)), [2])
    }

    func testMicrosecondDriftDoesNotReseed() {
        var l = live()
        var drift: TimeInterval = 0
        for i in 0..<20 {
            drift += 0.000_006
            XCTAssertEqual(l.ingest(r([:], ut: 160 + 60 * i, t: 70 + 10 * TimeInterval(i), slept: drift)), [])
        }
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 1_400, t: 300, slept: drift)), [2], "µs slew is not sleep")
    }

    func testAOneSecondJumpReseeds() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 220, t: 70, slept: 1.0)), [], "≥ 1 s of divergence = the Mac slept")
    }

    func testBelowThresholdDoesNotFireUntilDrawing() {
        var l = live()
        XCTAssertEqual(l.ingest(r([3: 400], ut: 160, t: 70)), [])
        XCTAssertEqual(l.ingest(r([3: 700], ut: 220, t: 130)), [3])
    }

    func testBelowThresholdPresenceNeverReArms() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 70)), [2])
        XCTAssertEqual(l.ingest(r([2: 250], ut: 220, t: 130)), [], "a full phone trickling: present, not drawing")
        XCTAssertEqual(l.ingest(r([2: 600], ut: 280, t: 190)), [], "never absent, so never re-armed")
    }

    func testFilteredPowerChangeWithoutANewUpdateTimeCountsAsFresh() {
        var l = DeviceNoticeLatch()
        _ = l.ingest(r([1: 5_000], ut: 100, t: 0))
        XCTAssertEqual(l.ingest(r([1: 5_200], ut: 100, t: 10)), [], "new evidence at the same UpdateTime (U3): quiet")
        XCTAssertEqual(l.ingest(r([1: 5_200, 2: 9_000], ut: 100, t: 20)), [2])
    }

    func testARepeatedFrameIsNotFresh() {
        var l = DeviceNoticeLatch()
        _ = l.ingest(r([1: 5_000], ut: 100, t: 0))
        XCTAssertEqual(l.ingest(r([1: 5_000, 2: 9_000], ut: 100, t: 10)), [], "still waiting for fresh evidence")
        XCTAssertEqual(l.ingest(r([1: 5_000, 2: 9_000], ut: 160, t: 70)), [], "present at the fresh frame: quiet")
    }

    func testF1AbsentThenF1DrawingThenF2DrawingFiresOnce() {
        var l = live()                                                   // ends on frame F1 = 160, nothing sourcing
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 70)), [2])     // F1, drawing
        XCTAssertEqual(l.ingest(r([2: 9_100], ut: 220, t: 130)), [])     // F2, drawing
    }

    func testReArmNeedsAbsenceOf120sFromTheFirstAbsentRead() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 70)), [2])
        _ = l.ingest(r([:], ut: 220, t: 130))
        _ = l.ingest(r([:], ut: 280, t: 190))
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 340, t: 200)), [], "back after 60 s: a loose cable")
        _ = l.ingest(r([:], ut: 400, t: 210))
        _ = l.ingest(r([:], ut: 460, t: 270))
        _ = l.ingest(r([:], ut: 520, t: 330))
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 580, t: 340)), [2], "away 120 s: a new plug-in")
    }

    func testOneMissedFrameDoesNotReArm() {
        var l = live()
        _ = l.ingest(r([2: 9_000], ut: 160, t: 70))
        _ = l.ingest(r([:], ut: 220, t: 130))
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 280, t: 190)), [])
    }

    func testUnreadRunsCarryNoInformation() {
        var l = live()
        _ = l.ingest(r([2: 9_000], ut: 160, t: 70))
        _ = l.ingest(r([:], ut: 220, t: 130))
        for t in stride(from: 140.0, through: 400, by: 10) {
            XCTAssertEqual(l.ingest(r(nil, ut: nil, t: t)), [])
        }
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 460, t: 410)), [], "one absent read only — failed reads are not absence")
    }

    func testUnreadBeforeTheSeedDoesNotSeed() {
        var l = DeviceNoticeLatch()
        XCTAssertEqual(l.ingest(r(nil, ut: nil, t: 0)), [])
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 100, t: 10)), [], "the first SUCCESSFUL read is the seed")
    }

    func testDevicesOnOneReadAggregate() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000, 1: 4_500], ut: 160, t: 70)), [1, 2])
    }

    // Stage-0 live evidence (spec 7.1): an iPhone blipped off the bus for 1-10 s; its element vanished for a read
    // or more and came back ~70 s later on the next battery-record refresh. That must NOT fire a second notice.
    func testTheStage0SeventySecondBlipDoesNotFireASecondNotice() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 70)), [2], "the real plug-in")
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 220, t: 100)), [], "drawing")
        XCTAssertEqual(l.ingest(r([:], ut: 280, t: 130)), [], "element gone for a refresh")
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 340, t: 200)), [], "back 70 s after the first absent read: a blip, not a plug-in")
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 400, t: 260)), [], "and it stays quiet")
    }

    /// The same blip with several absent reads inside the 70 s (each read counts from the FIRST absent one).
    func testTheStage0BlipWithSeveralAbsentReadsStaysQuiet() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 70)), [2])
        _ = l.ingest(r([:], ut: 220, t: 100))
        _ = l.ingest(r([:], ut: 220, t: 130))
        _ = l.ingest(r([:], ut: 280, t: 160))
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 340, t: 170)), [], "70 s from the first absent read")
    }

    // MARK: fix round 1

    /// A port PRESENT at the seed that drops out just before the first fresh frame is not "absent at the seed":
    /// the transition to live must not arm it, so its return is a blip (normal 120 s re-arm), not a plug-in.
    func testPortPresentAtSeedDroppingBeforeTheFirstFreshFrameDoesNotFireOnReturn() {
        var l = DeviceNoticeLatch()
        _ = l.ingest(r([2: 9_000], ut: 100, t: 0))
        XCTAssertEqual(l.ingest(r([:], ut: 160, t: 60)), [], "the first fresh frame; the seeded port is gone")
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 220, t: 70)), [], "a device already drawing at launch: no notice")
    }

    /// Same, when the blip lands on a NON-fresh awaitingFresh read (same UpdateTime) and the fresh frame finds it still gone.
    func testPortPresentAtSeedDroppingOnANonFreshReadDoesNotFireOnReturn() {
        var l = DeviceNoticeLatch()
        _ = l.ingest(r([2: 9_000], ut: 100, t: 0))
        XCTAssertEqual(l.ingest(r([:], ut: 100, t: 10)), [], "non-fresh: same UpdateTime, port gone")
        XCTAssertEqual(l.ingest(r([:], ut: 160, t: 70)), [], "first fresh frame, still gone")
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 220, t: 80)), [], "back after 70 s: already drawing at launch")
    }

    /// A seeded port that drops out and returns while still waiting for a fresh frame stays quiet too.
    func testPortPresentAtSeedBlippingWithinAwaitingFreshStaysQuiet() {
        var l = DeviceNoticeLatch()
        _ = l.ingest(r([2: 9_000], ut: 100, t: 0))
        _ = l.ingest(r([:], ut: 100, t: 10))
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 20)), [])
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 220, t: 80)), [])
    }

    /// A port that WAS present at the seed still re-arms by the normal rule (120 s absent) after going live.
    func testSeededPortDroppedThenAbsent120sThenReturnsFires() {
        var l = DeviceNoticeLatch()
        _ = l.ingest(r([2: 9_000], ut: 100, t: 0))
        _ = l.ingest(r([:], ut: 160, t: 60))          // first absent read
        _ = l.ingest(r([:], ut: 220, t: 120))
        _ = l.ingest(r([:], ut: 280, t: 180))         // 120 s from the first absent read
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 340, t: 190)), [2], "a genuinely new plug-in")
    }

    /// The `.unread` elapsed-time rule: unread reads carry no information but the clock still runs between the
    /// first and the LATEST ABSENT read, so absent 130 s, unread 270 s, absent 410 s re-arms the port.
    func testUnreadGapBetweenTwoAbsentReadsCountsTowardTheReArmClock() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 70)), [2])
        _ = l.ingest(r([:], ut: 220, t: 130))                                   // first absent read
        for t in stride(from: 140.0, through: 400, by: 10) {
            XCTAssertEqual(l.ingest(r(nil, ut: nil, t: t)), [])
        }
        _ = l.ingest(r([:], ut: 460, t: 410))                                   // 280 s after the first absent read
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 520, t: 420)), [2])
    }

    // Boundaries.

    private func absentThenReturn(secondAbsentAt: TimeInterval, returnAt: TimeInterval) -> [Int] {
        var l = live()
        _ = l.ingest(r([2: 9_000], ut: 160, t: 70))
        _ = l.ingest(r([:], ut: 220, t: 130))                                   // first absent read
        _ = l.ingest(r([:], ut: 280, t: secondAbsentAt))
        return l.ingest(r([2: 9_000], ut: 340, t: returnAt))
    }

    func testReArmBoundaryJustUnder120sDoesNotFire() {
        XCTAssertEqual(absentThenReturn(secondAbsentAt: 249.9, returnAt: 250), [], "119.9 s of absence")
    }

    func testReArmBoundaryExactly120sFires() {
        XCTAssertEqual(absentThenReturn(secondAbsentAt: 250, returnAt: 251), [2], "120.0 s of absence")
    }

    func testSleepJumpJustUnderOneSecondDoesNotReseed() {
        var l = live()
        XCTAssertEqual(l.ingest(r([2: 9_000], ut: 160, t: 70, slept: 0.99)), [2], "0.99 s is not sleep")
    }
}
