import XCTest
import Shared

/// B-arc follow-on — the helper-reachability LATCH and the conditional popover-open probe.
///
/// Context (the regression this locks down): B4 moved sustained energy's `collectTaskEnergy` off the
/// popover-open path, which was right — nothing on the root page reads it. But that call's SUCCESS was
/// incidentally what cleared `helperUnreachable`, so the "Energy helper isn't responding" banner had been
/// self-healing as an undocumented SIDE EFFECT. With the fetch moved, a healthy daemon kept a stuck banner
/// until the user opened Details or set a mode. The fix is a ping issued on popover open ONLY while the
/// latch is set, so the healthy path still pays nothing.
///
/// These tests drive the latch through its own entry points — no XPC connection is ever opened (a
/// `HelperClient` only connects when a privileged op or `ping()` is actually called).
@MainActor
final class HelperClientReachabilityTests: XCTestCase {

    /// `markUnreachable` / `reportPong` hop to the main queue via `DispatchQueue.main.async`; enqueueing
    /// behind them and awaiting is what makes the transition observable.
    private func drainMainQueue() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    // MARK: - the healthy path costs nothing (B4's saving is preserved)

    func testHealthyHelperIssuesNoProbe() {
        let client = HelperClient()
        XCTAssertFalse(client.helperUnreachable, "a fresh client is not latched")
        XCTAssertFalse(client.needsReachabilityProbe,
                       "the common case — popover open on a healthy helper must spawn no round-trip")
    }

    func testRecoveredHelperGoesBackToCostingNothing() async {
        // The point of the conditional: recovery must not leave a permanent per-open probe behind.
        let client = HelperClient()
        client.markUnreachable(dropConnection: false)
        await drainMainQueue()
        XCTAssertTrue(client.needsReachabilityProbe)

        client.reportPong("pong")
        await drainMainQueue()
        XCTAssertFalse(client.needsReachabilityProbe, "once healthy, later opens are free again")
    }

    // MARK: - the latched → recovered transition (the regression)

    func testLatchedBannerSelfHealsOnPong() async {
        let client = HelperClient()

        // A dropped/invalidated connection latches the banner — this is what the owner saw after a
        // daemon bounce: the old image's connection invalidates, the latch sets, and nothing clears it.
        client.markUnreachable(dropConnection: true)
        await drainMainQueue()
        XCTAssertTrue(client.helperUnreachable, "an invalidated connection latches the banner")
        XCTAssertTrue(client.needsReachabilityProbe, "so the NEXT popover open re-tests reachability")

        // The helper is back; the probe's reply clears the latch. This is the self-heal that
        // collectTaskEnergy used to provide by accident.
        client.reportPong("pong")
        await drainMainQueue()
        XCTAssertFalse(client.helperUnreachable, "a successful probe clears the not-responding banner")
        XCTAssertEqual(client.lastPong, "pong")
    }

    func testLatchSurvivesUntilSomethingSucceeds() async {
        // The latch is not time-based and nothing else clears it — which is precisely why the probe had
        // to be wired. Repeated failures keep it set.
        let client = HelperClient()
        for _ in 0..<3 {
            client.markUnreachable(dropConnection: false)
            await drainMainQueue()
        }
        XCTAssertTrue(client.helperUnreachable, "still latched — no self-clearing, no timeout")
        XCTAssertTrue(client.needsReachabilityProbe, "every open keeps re-testing while it is down")
    }
}

/// B4 — the POSITIVE half of the reachability signal.
///
/// `helperUnreachable` alone cannot say the helper is healthy: a fresh client is un-latched because
/// nothing has asked it anything yet, which is the same value a working helper produces. So the app
/// could not distinguish "fine" from "never contacted", and the honest surface needs both. This
/// records the fact separately: has this helper EVER completed a round trip in this process?
@MainActor
final class HelperClientContactEvidenceTests: XCTestCase {

    private func drainMainQueue() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    func testFreshClientHasNoEvidenceOfContact() {
        let client = HelperClient()
        XCTAssertFalse(client.hasResponded,
                       "an un-latched fresh client is silence, not health — it has proved nothing")
        XCTAssertFalse(client.helperUnreachable)
    }

    func testAReplyIsEvidence() async {
        let client = HelperClient()
        client.reportPong("pong")
        await drainMainQueue()
        XCTAssertTrue(client.hasResponded)
    }

    // The evidence is HISTORICAL — a later outage latches `helperUnreachable` but does not un-prove
    // that the helper answered once. Keeping the two independent is what lets the surface say
    // "isn't responding" without also claiming it was never there.
    func testAnOutageDoesNotErasePastContact() async {
        let client = HelperClient()
        client.reportPong("pong")
        await drainMainQueue()
        client.markUnreachable(dropConnection: true)
        await drainMainQueue()
        XCTAssertTrue(client.hasResponded, "it answered once; that stays true")
        XCTAssertTrue(client.helperUnreachable, "and it is down now")
    }
}
