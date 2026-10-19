import XCTest
@testable import Battery

/// #29 D5 — the single-slot banner arbitration: helper attention > power/limit exception >
/// informational; highest severity wins the one slot; ties resolve to input order (stable).
final class BannerArbitrationTests: XCTestCase {

    func testSeverityOrdering() {
        XCTAssertLessThan(BannerSeverity.informational, .exception)
        XCTAssertLessThan(BannerSeverity.exception, .helperAttention)
    }

    func testAllSeveritiesCovered() {
        XCTAssertEqual(BannerSeverity.allCases.count, 3)
    }

    func testWinnerEmptyIsNil() {
        XCTAssertNil(BannerArbiter.winner([]))
    }

    func testWinnerSingle() {
        XCTAssertEqual(BannerArbiter.winner([.exception]), .exception)
    }

    func testHelperAttentionBeatsEverything() {
        XCTAssertEqual(BannerArbiter.winner([.informational, .exception, .helperAttention]), .helperAttention)
    }

    func testExceptionBeatsInformational() {
        XCTAssertEqual(BannerArbiter.winner([.informational, .informational, .exception]), .exception)
    }

    func testWinnerIsOrderIndependent() {
        XCTAssertEqual(BannerArbiter.winner([.helperAttention, .exception, .informational]), .helperAttention)
        XCTAssertEqual(BannerArbiter.winner([.informational, .helperAttention, .exception]), .helperAttention)
    }

    func testResolveEmptyIsNil() {
        let picked = BannerArbiter.resolve([Int]()) { _ in BannerSeverity.informational }
        XCTAssertNil(picked)
    }

    func testResolvePicksHighestSeverityCandidate() {
        let candidates: [(id: String, sev: BannerSeverity)] = [
            ("info", .informational), ("helper", .helperAttention), ("exc", .exception),
        ]
        let picked = BannerArbiter.resolve(candidates) { $0.sev }
        XCTAssertEqual(picked?.id, "helper")
    }

    func testResolveTieKeepsFirstInInputOrder() {
        let candidates: [(id: String, sev: BannerSeverity)] = [
            ("first", .exception), ("second", .exception),
        ]
        let picked = BannerArbiter.resolve(candidates) { $0.sev }
        XCTAssertEqual(picked?.id, "first")   // stable: first of equal severity wins the slot
    }

    func testResolveSingleInformationalStillWins() {
        let candidates: [(id: String, sev: BannerSeverity)] = [("only", .informational)]
        XCTAssertEqual(BannerArbiter.resolve(candidates) { $0.sev }?.id, "only")
    }
}
