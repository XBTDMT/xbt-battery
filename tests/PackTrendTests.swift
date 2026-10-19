import XCTest

final class PackTrendTests: XCTestCase {
    func testEmptyIsFlat() {
        XCTAssertEqual(PackTrend().verdict(at: 100), .flat)
    }

    func testOneStepUpWithinWindowIsRising() {
        var t = PackTrend(window: 90)
        t.push(percent: 28, at: 0); t.push(percent: 28, at: 30); t.push(percent: 29, at: 55)
        XCTAssertEqual(t.verdict(at: 60), .rising)
    }

    func testRisingHoldsForTheWindowThenGoesFlat() {
        var t = PackTrend(window: 90)
        t.push(percent: 28, at: 0); t.push(percent: 29, at: 10)
        for s in stride(from: 20, through: 80, by: 10) { t.push(percent: 29, at: TimeInterval(s)) }
        XCTAssertEqual(t.verdict(at: 89), .rising)     // the 28 at t=0 is still in the window
        for s in stride(from: 90, through: 200, by: 10) { t.push(percent: 29, at: TimeInterval(s)) }
        XCTAssertEqual(t.verdict(at: 200), .flat)      // it aged out: no step in the last 90 s
    }

    func testStepDownIsFalling() {
        var t = PackTrend(window: 90)
        t.push(percent: 30, at: 0); t.push(percent: 29, at: 40)
        XCTAssertEqual(t.verdict(at: 45), .falling)
    }

    func testStaleSamplesOutsideWindowAreIgnored() {
        var t = PackTrend(window: 90)
        t.push(percent: 20, at: 0)
        t.push(percent: 30, at: 500)   // the 20 is 500 s old: not a rise "within the window"
        XCTAssertEqual(t.verdict(at: 500), .flat)
    }

    func testResetForgets() {
        var t = PackTrend(window: 90)
        t.push(percent: 20, at: 0); t.push(percent: 21, at: 10)
        t.reset()
        XCTAssertEqual(t.verdict(at: 10), .flat)
    }
}
