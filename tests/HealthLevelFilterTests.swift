import XCTest
import IOKit.ps

/// #HEALTH-STEADY. The battery-health filter's contract, pinned against the OWNER'S REAL NOISE.
///
/// `ownerFCC` below is 152 consecutive `AppleRawMaxCapacity` readings lifted verbatim from the owner's
/// `~/Library/Application Support/BatteryApp/history/health.jsonl` — the last 7 days, cycle count flat
/// (510 → 523, i.e. the battery did not measurably change), sampled every 15th recorded row so the
/// sequence spans the whole week. They range 5198…5639 mAh against a 6249 mAh design capacity: a
/// **7.06 percentage-point** raw band on a quantity that moves ~1 pp per MONTH.
///
/// The old 5-sample rolling mean passed 4.60 pp of that straight through to the UI and the history
/// store (`testRollingMeanBaselineDrifts` pins that, so the regression is impossible to reintroduce
/// silently). The settle-and-hold filter publishes ONE value across the same week.
@MainActor
final class HealthLevelFilterTests: XCTestCase {

    /// 6249 mAh — the M4 Max design capacity these readings were taken against (decision #13 denominator).
    private static let design = 6249.0

    /// The real thing. Do not "clean" these numbers: the outliers are the point.
    private static let ownerFCC: [Int] = [
        5378, 5352, 5459, 5469, 5440, 5438, 5436, 5453, 5439, 5443, 5471, 5441,
        5539, 5550, 5507, 5543, 5454, 5373, 5418, 5353, 5485, 5448, 5472, 5470,
        5493, 5492, 5479, 5502, 5540, 5438, 5456, 5489, 5485, 5476, 5430, 5474,
        5477, 5432, 5499, 5483, 5456, 5478, 5501, 5496, 5511, 5498, 5501, 5478,
        5460, 5478, 5508, 5466, 5462, 5481, 5469, 5579, 5604, 5564, 5400, 5539,
        5549, 5539, 5577, 5595, 5587, 5559, 5576, 5576, 5586, 5639, 5463, 5414,
        5462, 5389, 5388, 5420, 5352, 5366, 5270, 5198, 5316, 5377, 5322, 5350,
        5398, 5382, 5367, 5406, 5412, 5384, 5408, 5420, 5426, 5464, 5453, 5351,
        5311, 5330, 5446, 5380, 5339, 5325, 5400, 5368, 5358, 5402, 5432, 5404,
        5422, 5421, 5415, 5415, 5433, 5406, 5451, 5400, 5410, 5408, 5405, 5419,
        5423, 5400, 5417, 5434, 5415, 5443, 5433, 5409, 5422, 5380, 5376, 5416,
        5449, 5453, 5422, 5490, 5441, 5437, 5415, 5419, 5446, 5490, 5507, 5499,
        5509, 5488, 5489, 5491, 5467, 5505, 5462, 5476,
    ]

    /// The real average spacing of those 152 readings: 7 days / 152 ≈ 66 minutes. Replaying them at
    /// their true cadence is HARDER than production (the 12 h level window then holds ~11 samples
    /// instead of ~720), so a pass here is a floor, not a best case.
    private static let ownerSpacing: TimeInterval = 7 * 86_400 / 152

    private static func pct(_ mAh: Int) -> Double { Double(mAh) / design * 100 }

    // MARK: - the defect: the owner's real week must publish a value that holds

    func testOwnerWeekOfRealNoiseIsPublishedAsOneSteadyValue() {
        let raw = Self.ownerFCC.map(Self.pct)
        let rawBand = raw.max()! - raw.min()!
        XCTAssertGreaterThan(rawBand, 7.0, "fixture sanity: the raw week really does span >7 pp")

        var f = HealthLevelFilter()
        let out = raw.enumerated().map { f.push($1, at: Double($0) * Self.ownerSpacing) }

        // The settle phase (the first `minLevelSpan` of uptime) is allowed to move — that is how a
        // fresh launch reaches an honest number instead of freezing on read #1.
        let settled = Array(out.dropFirst(20))
        XCTAssertEqual(Set(settled).count, 1,
                       "the published health must HOLD across the owner's week, not walk: got \(Set(settled).sorted())")
        XCTAssertEqual(settled.first!, 87.0, accuracy: 0.001, "and hold at the level, not at an extreme")
    }

    /// The characterization the fix exists for: the same fixture through the 5-sample rolling MEAN this
    /// replaced. If this ever stops drifting, the fixture stopped being representative.
    func testRollingMeanBaselineDrifts() {
        var window: [Double] = []
        let out: [Double] = Self.ownerFCC.map { mAh in
            window.append(Self.pct(mAh))
            if window.count > 5 { window.removeFirst(window.count - 5) }
            return (window.reduce(0, +) / Double(window.count) * 10).rounded() / 10
        }
        XCTAssertGreaterThan(out.max()! - out.min()!, 4.0,
                             "the replaced rolling mean drifted >4 pp over a week of a flat battery")
        XCTAssertGreaterThan(Set(out).count, 25,
                             "and it re-crossed the store's 0.1 pp dedup grid dozens of times")
    }

    /// Same week, sampled at the monitor's 60 s passive cadence instead: still one value.
    func testHoldsAtThePassivePollCadenceToo() {
        var f = HealthLevelFilter()
        let out = Self.ownerFCC.map(Self.pct).enumerated().map { f.push($1, at: Double($0) * 60) }
        XCTAssertEqual(Set(out.dropFirst(20)).count, 1, "60 s cadence must hold just as flat")
    }

    // MARK: - what the filter must still report

    /// A genuine capacity drop (a 300 mAh / 4.8 pp step, on top of the owner's real jitter) must show
    /// up, and within hours — not months. Health is a months-scale quantity; a few hours is prompt.
    func testGenuineCapacityDropIsReportedPromptly() {
        var f = HealthLevelFilter()
        var t: TimeInterval = 0
        let base = Array(Self.ownerFCC.prefix(80))

        var before = 0.0
        for i in 0..<200 { before = f.push(Self.pct(base[i % base.count]), at: t); t += 60 }
        let dropAt = t

        var firstMove: TimeInterval?
        var last = before
        for i in 0..<600 {
            let v = f.push(Self.pct(base[i % base.count] - 300), at: t)
            if v != last, firstMove == nil { firstMove = t - dropAt }
            last = v
            t += 60
        }

        XCTAssertNotNil(firstMove, "a real 4.8 pp capacity drop must be reported, not held away")
        XCTAssertLessThan(firstMove!, 6 * 3600, "and reported within hours of the drop")
        XCTAssertLessThan(last, before - 2.0, "the published level must actually step DOWN")
        // The step lands within the deadband of the true new level — that IS the claimed resolution.
        let trueLevel = Self.pct(5450 - 300)
        XCTAssertEqual(last, trueLevel, accuracy: HealthLevelFilter.deadband)
    }

    /// The first reading is published at once — the UI must never be blank waiting for a window to fill.
    func testFirstReadingIsPublishedImmediately() {
        var f = HealthLevelFilter()
        XCTAssertEqual(f.push(87.34, at: 0), 87.3, accuracy: 0.001)
        XCTAssertEqual(f.held!, 87.3, accuracy: 0.001)
    }

    // MARK: - noise rejection

    /// The raw stream carries genuine single-read outliers (a 4958 mAh read landed on a day whose median
    /// was 5306). A mean drags one into the output for its whole window; the median must swallow it.
    func testASingleWildReadNeverMovesTheDisplayedValue() {
        var f = HealthLevelFilter()
        var t: TimeInterval = 0
        var out: [Double] = []
        for _ in 0..<40 { out.append(f.push(Self.pct(5450), at: t)); t += 60 }
        for _ in 0..<3 { out.append(f.push(Self.pct(4958), at: t)); t += 60 }   // the outlier burst
        for _ in 0..<40 { out.append(f.push(Self.pct(5450), at: t)); t += 60 }
        XCTAssertEqual(Set(out).count, 1, "a spike must not reach the display: got \(Set(out).sorted())")
    }

    /// Sub-deadband wander — the gauge breathing ±1 pp over days — must produce NO motion at all. This
    /// is the specific failure of the rolling mean: it tracked exactly this and called it a reading.
    func testSubDeadbandWanderProducesNoMotion() {
        var f = HealthLevelFilter()
        var out: [Double] = []
        for i in 0..<(1440 * 7) {                       // a week at 60 s
            let v = 87.0 + 1.0 * sin(2 * .pi * Double(i) / (1440 * 2))   // ±1 pp, 2-day period
            out.append(f.push(v, at: Double(i) * 60))
        }
        XCTAssertEqual(Set(out.dropFirst(20)).count, 1, "±1 pp of gauge breathing is noise, not a reading")
    }

    /// A non-finite read (a zero/garbage denominator upstream) must not poison the held level.
    func testNonFiniteReadingLeavesTheLevelUntouched() {
        var f = HealthLevelFilter()
        for i in 0..<40 { _ = f.push(Self.pct(5450), at: Double(i) * 60) }
        let held = f.held!
        XCTAssertEqual(f.push(.nan, at: 2400), held, accuracy: 0.001)
        XCTAssertEqual(f.push(.infinity, at: 2460), held, accuracy: 0.001)
        XCTAssertEqual(f.held!, held, accuracy: 0.001)
    }

    /// The published value sits on the 0.1 pp grid `HistoryStore.recordHealth` dedups on, so one step
    /// here is at most one recorded row — the two mechanisms compose instead of fighting.
    func testPublishedValueSitsOnTheStoresDedupGrid() {
        var f = HealthLevelFilter()
        for i in 0..<200 {
            let v = f.push(Self.pct(Self.ownerFCC[i % Self.ownerFCC.count]), at: Double(i) * 60)
            XCTAssertEqual(v, (v * 10).rounded() / 10, accuracy: 1e-9, "value must be on the 0.1 pp grid")
        }
    }

    /// Time going backwards (a clock seam misuse) must not wedge the filter into never pruning.
    func testClockGoingBackwardsDoesNotWedgeTheFilter() {
        var f = HealthLevelFilter()
        for i in 0..<40 { _ = f.push(Self.pct(5450), at: Double(i) * 60) }
        let v = f.push(Self.pct(5450), at: 0)              // clock jumped back
        XCTAssertEqual(v, f.held!, accuracy: 0.001)
        for i in 0..<40 { _ = f.push(Self.pct(5450), at: Double(i) * 60) }
        XCTAssertEqual(f.held!, Self.pct(5450), accuracy: 0.2, "and it re-settles on the same level")
    }
}
