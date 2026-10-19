import XCTest

/// Sprint 4.2: the pure history-graph view-model (SPEC sec 4) — range filter, downsample-for-pixels
/// (cap + average), on-AC/charge/hold spans from stored fields, UTC→local monotonicity. Fixture
/// series, no files.
final class GraphVMTests: XCTestCase {

    private let now = 1_762_000_000   // a fixed UTC epoch
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func cp(_ ts: Int, soc: Int?, onAC: Bool = true, state: String = "discharging") -> ChargePoint {
        ChargePoint(ts: ts, soc: soc, watts: nil, onAC: onAC, state: state, limit: 80)
    }
    // MARK: - charge: empty / single / two

    func testEmptyRangeIsEmpty() {
        XCTAssertTrue(GraphVM.charge([], range: .h24, now: now, tz: chicago).isEmpty)
        // points exist but all OUTSIDE the 24h window:
        let old = [cp(now - 200_000, soc: 80), cp(now - 190_000, soc: 81)]
        XCTAssertTrue(GraphVM.charge(old, range: .h24, now: now, tz: chicago).isEmpty)
    }

    func testSinglePointRangeIsEmpty() {
        let one = [cp(now - 100, soc: 80)]
        XCTAssertTrue(GraphVM.charge(one, range: .h24, now: now, tz: chicago).isEmpty,
                      "< 2 points → 'Not enough history yet'")
    }

    func testTwoPointsRenderLine() {
        let s = GraphVM.charge([cp(now - 200, soc: 80), cp(now - 100, soc: 82)],
                               range: .h24, now: now, tz: chicago)
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.points.count, 2)
        XCTAssertEqual(s.points.map(\.soc), [80, 82])
    }

    // MARK: - downsample-for-pixels

    func testDownsampleCapsAndAverages() {
        // 2000 points across 24h → capped at ≤200, averaged (smooth, not 2000 → no lag, no lie).
        let raw = (0..<2000).map { i in cp(now - 86_400 + i * 43, soc: 50 + (i % 40)) }
        let s = GraphVM.charge(raw, range: .h24, now: now, tz: chicago, maxPoints: 200)
        XCTAssertLessThanOrEqual(s.points.count, 200)
        XCTAssertGreaterThan(s.points.count, 100, "still a dense smooth line, not collapsed")
        // averaged SoC stays in the data's band
        XCTAssertTrue(s.points.allSatisfy { $0.soc >= 50 && $0.soc <= 90 })
        // monotonic in time
        XCTAssertTrue(zip(s.points, s.points.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    func testUnderCapNotDownsampled() {
        let raw = (0..<50).map { i in cp(now - 5_000 + i * 100, soc: 70 + i % 10) }
        let s = GraphVM.charge(raw, range: .h24, now: now, tz: chicago, maxPoints: 200)
        XCTAssertEqual(s.points.count, 50, "≤ cap → kept verbatim")
    }

    // MARK: - spans from stored fields (never recomputed)

    func testACAndHoldSpansFromStoredFields() {
        let raw = [
            cp(now - 500, soc: 80, onAC: true,  state: "limitHold"),
            cp(now - 400, soc: 80, onAC: true,  state: "limitHold"),
            cp(now - 300, soc: 79, onAC: false, state: "discharging"),
            cp(now - 200, soc: 78, onAC: false, state: "discharging"),
            cp(now - 100, soc: 90, onAC: true,  state: "charging"),
        ]
        let s = GraphVM.charge(raw, range: .h24, now: now, tz: chicago)
        XCTAssertEqual(s.acSpans.count, 2, "two on-AC runs: [-500..-400] and [-100]")
        XCTAssertEqual(s.acSpans.first?.start, Date(timeIntervalSince1970: TimeInterval(now - 500)))
        XCTAssertEqual(s.acSpans.first?.end, Date(timeIntervalSince1970: TimeInterval(now - 400)))
        XCTAssertEqual(s.holdSpans.count, 1, "one limit-hold run")
        // #29 C1: `chargeSpans` was deleted with its only (excised) consumer — the D6 chart tints AC and
        // limit-hold only, and a charging run is already the rising edge of the plotted line.
    }

    // MARK: - tz / DST crossing stays monotonic

    func testDSTCrossingRangeStaysMonotonic() {
        // America/Chicago fall-back: 2026-11-01 02:00 CDT → 01:00 CST (local clock repeats an hour).
        // Absolute instants are monotonic; the view-model must keep the output sorted regardless.
        let boundary = 1_762_066_800   // ~2026-11-01 07:00 UTC (the fall-back instant)
        let raw = (0..<10).map { i in cp(boundary - 5_000 + i * 1_000, soc: 60 + i) }
        let s = GraphVM.charge(raw, range: .h24, now: boundary + 5_000, tz: chicago)   // now after the last point
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.points.count, 10, "no point dropped or duplicated across the boundary")
        XCTAssertTrue(zip(s.points, s.points.dropFirst()).allSatisfy { $0.date < $1.date },
                      "strictly increasing absolute time → monotonic local render")
    }

    // MARK: - tier-boundary (raw + aggregate stitched) handled uniformly

    func testTierBoundaryRangeStitchedUniformly() {
        // series() hides the tier — the VM gets a mix: sparse hourly (old, from aggregates) + dense
        // recent (raw). It must produce one continuous, capped, monotonic series.
        var raw: [ChargePoint] = []
        for h in stride(from: 28 * 86_400, through: 2 * 86_400, by: 3_600) {   // hourly, old
            raw.append(cp(now - h, soc: 70))
        }
        for m in 0..<120 { raw.append(cp(now - 7_200 + m * 60, soc: 80 + m % 15)) }   // per-minute, recent
        let s = GraphVM.charge(raw, range: .d30, now: now, tz: chicago, maxPoints: 200)
        XCTAssertFalse(s.isEmpty)
        XCTAssertLessThanOrEqual(s.points.count, 200)
        XCTAssertTrue(zip(s.points, s.points.dropFirst()).allSatisfy { $0.date < $1.date })
        XCTAssertLessThan(s.points.first!.date, s.points.last!.date, "spans old → recent")
    }
}
