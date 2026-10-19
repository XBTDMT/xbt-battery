import XCTest

/// The crash-loop **storm guard** (S-1) — Sprint 3.7: DECOUPLED from the retired charge engine.
///
/// These assertions prove the guard SURVIVED the decoupling INTACT. Its five load-bearing properties:
///   1. `recordLaunchAttempt()` advances the persisted counter (the accumulating half).
///   2. `markHealthyUptime()` resets it (so only RAPID crashes accumulate).
///   3. below threshold → `.vend` (start the listener).
///   4. at/above threshold → `.gated` (do NOT vend — storm contained).
///   5. a tripped state PERSISTS across relaunches (re-reading the same store stays gated) and the
///      gated path never auto-clears the counter.
/// Host-app-free, deterministic, engine-free (no SMC, no ChargeInhibitEngine, no SafetyPolicy).
final class DaemonLifecycleTests: XCTestCase {

    /// In-memory `StormGuardStore` (replaces the deleted charge `MockStateStore`; crashCount only).
    private final class MockStormGuardStore: StormGuardStore, @unchecked Sendable {
        var crashCount: Int = 0
        var backoffLevel: Int = 0        // Cut 2 (uses the default increment/incrementBackoff/reset extensions)
    }

    private func make(threshold: Int = 5) -> (DaemonLifecycle, MockStormGuardStore) {
        let store = MockStormGuardStore()
        return (DaemonLifecycle(store: store, guardThreshold: threshold), store)
    }

    func testRecordLaunchAttemptAdvancesCounter() {
        let (lc, store) = make()
        XCTAssertEqual(store.crashCount, 0)
        lc.recordLaunchAttempt(); XCTAssertEqual(store.crashCount, 1)
        lc.recordLaunchAttempt(); XCTAssertEqual(store.crashCount, 2)
    }

    func testHealthyUptimeResetsCounter() {
        let (lc, store) = make()
        lc.recordLaunchAttempt(); lc.recordLaunchAttempt(); lc.recordLaunchAttempt()
        XCTAssertEqual(store.crashCount, 3)
        lc.markHealthyUptime()
        XCTAssertEqual(store.crashCount, 0)
    }

    func testBelowThresholdVends() {
        let (lc, store) = make(threshold: 5)
        store.crashCount = 4
        let out = lc.launch()
        XCTAssertEqual(out.decision, .vend)
        XCTAssertFalse(out.gated)
        XCTAssertEqual(out.crashCount, 4)
    }

    func testAtThresholdGatesListener() {
        let (lc, store) = make(threshold: 5)
        store.crashCount = 5
        let out = lc.launch()
        XCTAssertEqual(out.decision, .gated)
        XCTAssertTrue(out.gated)
    }

    func testRapidCrashesAccumulateToTrip() {
        let (lc, _) = make(threshold: 3)
        XCTAssertFalse(lc.launch().gated)                              // launch with 0 crashes
        lc.recordLaunchAttempt(); XCTAssertFalse(lc.launch().gated)    // 1
        lc.recordLaunchAttempt(); XCTAssertFalse(lc.launch().gated)    // 2
        lc.recordLaunchAttempt(); XCTAssertTrue(lc.launch().gated)     // 3 → tripped
    }

    func testHealthyResetPreventsTrip() {
        let (lc, store) = make(threshold: 3)
        lc.recordLaunchAttempt(); lc.recordLaunchAttempt()   // 2 rapid crashes
        lc.markHealthyUptime()                                // survived 60 s → reset
        lc.recordLaunchAttempt()                              // 1 again
        XCTAssertFalse(lc.launch().gated, "a healthy reset between crashes prevents accumulation")
        XCTAssertEqual(store.crashCount, 1)
    }

    func testTrippedStaysTrippedAcrossRelaunch() {
        let store = MockStormGuardStore()
        store.crashCount = 5
        // First process: tripped.
        XCTAssertTrue(DaemonLifecycle(store: store, guardThreshold: 5).launch().gated)
        // A NEW process re-reads the SAME persisted store → still gated (the gated path never
        // auto-clears the counter; only a deliberate healthy reset / manual reset would).
        XCTAssertTrue(DaemonLifecycle(store: store, guardThreshold: 5).launch().gated)
        XCTAssertEqual(store.crashCount, 5, "gated launch (launch() alone) must NOT mutate the counter")
    }

    /// Fidelity to main.swift's REAL per-launch sequence on the gated path: `recordLaunchAttempt()`
    /// runs UNCONDITIONALLY (main.swift:19) before `launch()` (main.swift:20), so a gated relaunch
    /// DOES advance the persisted counter while staying gated every time (monotonic, never
    /// auto-cleared — main.swift schedules `markHealthyUptime()` only on the vend branch).
    func testGatedRelaunchSequenceMatchesMainSwift() {
        let (lc, store) = make(threshold: 5)
        store.crashCount = 5
        for expected in 6...8 {
            lc.recordLaunchAttempt()                 // main.swift:19 — unconditional, BEFORE the branch
            let out = lc.launch()                    // main.swift:20
            XCTAssertTrue(out.gated, "stays gated at crashCount=\(expected)")
            XCTAssertEqual(store.crashCount, expected,
                           "the production record();launch() loop advances the counter while gated")
        }
    }

    // ── Cut 2: probation backoff ──
    func testProbationDelayGrowsExponentiallyWithBackoff() {
        let (lc, store) = make()
        store.backoffLevel = 0; XCTAssertEqual(lc.probationDelay(), 60,  accuracy: 0.001)
        store.backoffLevel = 1; XCTAssertEqual(lc.probationDelay(), 120, accuracy: 0.001)
        store.backoffLevel = 3; XCTAssertEqual(lc.probationDelay(), 480, accuracy: 0.001)   // 60 × 2^3
    }
    func testProbationDelayCapsAtMaxBackoffLevel() {
        let (lc, store) = make()
        store.backoffLevel = 6;  XCTAssertEqual(lc.probationDelay(), 60 * 64, accuracy: 0.001)   // 2^6 cap
        store.backoffLevel = 20; XCTAssertEqual(lc.probationDelay(), 60 * 64, accuracy: 0.001)   // clamped, no overflow
    }
    func testProbationDelayClampsNegativeBackoff() {                         // NO-TRAP
        let (lc, store) = make(); store.backoffLevel = -5
        XCTAssertEqual(lc.probationDelay(), 60, accuracy: 0.001)             // 2^0, never 1 << negative
    }
    func testBeginProbationIncrementsBackoff() {
        let (lc, store) = make()
        lc.beginProbation(); XCTAssertEqual(store.backoffLevel, 1)
        lc.beginProbation(); XCTAssertEqual(store.backoffLevel, 2)
    }
    func testBeginProbationCapsAtMaxBackoffLevel() {
        let (lc, store) = make(); store.backoffLevel = 6
        lc.beginProbation(); XCTAssertEqual(store.backoffLevel, 6, "must not grow past maxBackoffLevel")
    }
    func testHealthyUptimeResetsBothCounters() {                             // KEY RED
        let (lc, store) = make(); store.crashCount = 3; store.backoffLevel = 4
        lc.markHealthyUptime()
        XCTAssertEqual(store.crashCount, 0)
        XCTAssertEqual(store.backoffLevel, 0, "60s survival clears backoffLevel too")
    }
}
