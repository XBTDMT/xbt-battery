import XCTest

/// Pins the shared app-level readiness latch in isolation (sec 11). These mirror, without a surface, what
/// the two ChargeControlIntentSurface readiness tests assert through setLimit: an already-settled gate is
/// ready at once, a never-settled waiter times out false without hanging, settle resumes pending waiters
/// true, and settle cancels the per-waiter timeout so each waiter resumes exactly once (the B2 property).
@MainActor
final class IntentReadinessGateTests: XCTestCase {

    // (a) already settled: awaitReady returns true immediately, without exercising the timeout.
    func testAwaitReadyReturnsTrueImmediatelyWhenAlreadySettled() async {
        let gate = IntentReadinessGate(timeout: .seconds(10))
        gate.settle()
        let ready = await gate.awaitReady()
        XCTAssertTrue(ready, "an already-settled gate is ready immediately")
    }

    // (b) never settled: the waiter resumes false after the bounded timeout and does not hang.
    func testNeverSettledTimesOutFalseAndDoesNotHang() async {
        let gate = IntentReadinessGate(timeout: .milliseconds(50))
        let ready = await gate.awaitReady()
        XCTAssertFalse(ready, "a never-settled waiter resumes false after the bounded timeout")
    }

    // (c) settle resumes a pending waiter with true.
    func testSettleResumesPendingWaiterWithTrue() async {
        let gate = IntentReadinessGate(timeout: .seconds(10))   // long: settle must win, not the timer
        async let waited = gate.awaitReady()
        await Task.yield()          // let the waiter register before settle
        gate.settle()
        let ready = await waited
        XCTAssertTrue(ready, "settle resumes the pending waiter with ready true")
    }

    // (d) the B2 property: settle cancels the pending timeout so the waiter resumes EXACTLY once with true,
    // it does not also time out. The timeout is SHORT so that if the cancel and the remove did not hold, the
    // timeout body would try to resume the same checked continuation a second time and crash this test.
    func testSettleCancelsTimeoutSoWaiterResumesExactlyOnce() async {
        let gate = IntentReadinessGate(timeout: .milliseconds(50))
        async let waited = gate.awaitReady()
        await Task.yield()
        gate.settle()
        let ready = await waited
        XCTAssertTrue(ready, "settle wins, the waiter resumes true")
        try? await Task.sleep(for: .milliseconds(120))   // outlast the timeout window
        XCTAssertTrue(ready, "no second resume: the cancelled timeout did not also fire the waiter false")
    }

    // (e) settle is idempotent: a second call is a harmless no-op.
    func testSettleIsIdempotent() async {
        let gate = IntentReadinessGate(timeout: .seconds(10))
        gate.settle()
        gate.settle()
        let ready = await gate.awaitReady()
        XCTAssertTrue(ready, "after settle called twice the gate is still ready")
    }
}
