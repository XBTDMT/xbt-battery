import XCTest

/// Phase 5 feature #17 Pass 2: the @MainActor Top Up intent surface, mirroring ChargeControlIntentSurfaceTests.
/// requestTopUp awaits the shared IntentReadinessGate (bounded, honest could-not-ready), gates on setup, then
/// routes through the audited TopUpController and reports the START outcome. Host-app-free via a seam mock.
@MainActor
final class TopUpIntentSurfaceTests: XCTestCase {

    /// Records how many times the start action was routed; `outcome` is the StartOutcome the (mock)
    /// controller returns, settable per test to exercise the result mapping.
    final class MockTopUp: TopUpStarting {
        private(set) var calls = 0
        var outcome: TopUpController.StartOutcome = .started
        func topUp() async -> TopUpController.StartOutcome { calls += 1; return outcome }
    }

    /// A surface over a mock start action. Readiness is controlled by `settled` (same pattern as the
    /// migrated charge surface helper): a settled gate routes immediately, an unsettled one times out.
    private func makeSurface(topUp: MockTopUp = MockTopUp(),
                             setUp: Bool = true,
                             settled: Bool = true,
                             timeout: Duration = .milliseconds(50)) -> TopUpIntentSurface {
        let gate = IntentReadinessGate(timeout: timeout)
        if settled { gate.settle() }
        return TopUpIntentSurface(readinessGate: gate,
                                  topUp: topUp,
                                  isSetUp: { setUp })
    }

    // MARK: - the bounded-timeout honest-fail path (could-not-ready, never a hang)

    func testNeverSettledGateProducesNotReadyAndDoesNotRoute() async {
        let topUp = MockTopUp()
        let surface = makeSurface(topUp: topUp, setUp: true, settled: false)
        let r = await surface.requestTopUp()
        XCTAssertEqual(r, .notReady)
        XCTAssertEqual(topUp.calls, 0, "a timed-out readiness must not reach the controller")
    }

    // MARK: - readiness gates on settle, not on object existence (mirror of the charge surface)

    func testReadinessGatesOnSettleNotObjectExistence() async {
        let topUp = MockTopUp()
        let gate = IntentReadinessGate(timeout: .milliseconds(50))
        let surface = TopUpIntentSurface(readinessGate: gate, topUp: topUp, isSetUp: { true })
        let before = await surface.requestTopUp()
        XCTAssertEqual(before, .notReady, "object existence alone is not readiness, it gates on settle")
        XCTAssertEqual(topUp.calls, 0, "must not route before the gate settles")
        gate.settle()
        let after = await surface.requestTopUp()
        XCTAssertEqual(after, .started, "after the gate settles, it routes")
        XCTAssertEqual(topUp.calls, 1)
    }

    // MARK: - honest, non-acting failure: charge control not set up

    func testNotSetUpReturnsNotSetUpAndDoesNotRoute() async {
        let topUp = MockTopUp()
        let surface = makeSurface(topUp: topUp, setUp: false, settled: true)
        let r = await surface.requestTopUp()
        XCTAssertEqual(r, .notSetUp, "not set up, honest and non-acting")
        XCTAssertEqual(topUp.calls, 0, "a not-set-up request must not reach the controller")
    }

    // MARK: - the StartOutcome to TopUpIntentResult mapping (settled gate, set up)

    func testStartedMapsToStarted() async {
        let topUp = MockTopUp(); topUp.outcome = .started
        let r = await makeSurface(topUp: topUp).requestTopUp()
        XCTAssertEqual(r, .started)
        XCTAssertEqual(topUp.calls, 1, "the request routed to the controller")
    }

    func testAlreadyInProgressMapsToAlreadyInProgress() async {
        let topUp = MockTopUp(); topUp.outcome = .alreadyInProgress
        let r = await makeSurface(topUp: topUp).requestTopUp()
        XCTAssertEqual(r, .alreadyInProgress)
        XCTAssertEqual(topUp.calls, 1)
    }

    func testRefusedPausedMapsToPausedFirst() async {
        let topUp = MockTopUp(); topUp.outcome = .refusedPaused
        let r = await makeSurface(topUp: topUp).requestTopUp()
        XCTAssertEqual(r, .pausedFirst)
        XCTAssertEqual(topUp.calls, 1)
    }

    func testControllerNotReadyMapsToNotReady() async {
        let topUp = MockTopUp(); topUp.outcome = .notReady
        let r = await makeSurface(topUp: topUp).requestTopUp()
        XCTAssertEqual(r, .notReady)
        XCTAssertEqual(topUp.calls, 1, "the gate settled, the controller's own not-ready maps through")
    }

    func testCouldNotStartMapsToCouldNotStart() async {
        let topUp = MockTopUp(); topUp.outcome = .couldNotStart
        let r = await makeSurface(topUp: topUp).requestTopUp()
        XCTAssertEqual(r, .couldNotStart)
        XCTAssertEqual(topUp.calls, 1)
    }
}
