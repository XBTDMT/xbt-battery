import XCTest

/// Phase 5 feature #17 Pass 1 (re-spin, SPEC 02-SPEC-phase-5-app-intents.md sec 10/11): the @MainActor
/// intent surface. The set entry point routes through the audited engine (`userSetLimit`, source
/// `.appIntent`). Honest + non-acting when not ready or not set up; reports `.applied` ONLY after the
/// engine's read-verify confirms the target, else `.couldNotConfirm`. Readiness is an AWAITED gate with
/// a bounded timeout: it suspends until the engine's first known-limit read settles (or the setup-failure
/// path is taken), NOT merely until the surface object exists (sec 11 sharpening). Host-app-free: routing
/// is tested through a seam mock; serialization, the non-blocking lock, and the read-verify drive the
/// REAL engine with a scripted/gating runner.
@MainActor
final class ChargeControlIntentSurfaceTests: XCTestCase {

    /// Records the routed (target, source) so a test asserts the surface forwards correctly. `outcome`
    /// is the CommandOutcome the (mock) engine returns; DEFAULTS to `.applied` so existing usages are
    /// unaffected, settable per test to exercise the verdict mapping (audit A2).
    final class MockSetter: ChargeLimitSetting {
        private(set) var calls: [(target: Int, source: CommandSource)] = []
        var outcome: CommandOutcome = .applied
        func userSetLimit(_ target: Int, source: CommandSource) async -> CommandOutcome {
            calls.append((target, source)); return outcome
        }
    }

    /// A surface over a mock setter. Readiness is controlled by `settled`; the engine's verdict is the
    /// MockSetter's `outcome`. Audit B1 removed the surface's current-limit read, so a set routes on
    /// readiness + set-up alone and reports whatever CommandOutcome the engine returns.
    private func makeSurface(setter: MockSetter = MockSetter(),
                             setUp: Bool = true,
                             settled: Bool = true,
                             timeout: Duration = .milliseconds(50)) -> ChargeControlIntentSurface {
        let gate = IntentReadinessGate(timeout: timeout)
        if settled { gate.settle() }
        return ChargeControlIntentSurface(setter: setter,
                                          isSetUp: { setUp },
                                          readinessGate: gate)
    }

    // MARK: - routing

    func testSetRoutesToUserSetLimitWithAppIntentSource() async {
        let setter = MockSetter()
        let surface = makeSurface(setter: setter, setUp: true, settled: true)
        let result = await surface.setLimit(80)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(setter.calls.count, 1)
        XCTAssertEqual(setter.calls.first?.target, 80)
        XCTAssertEqual(setter.calls.first?.source, .appIntent)
    }

    // MARK: - readiness gates on the first KNOWN-LIMIT READ, not on object existence (sec 11)

    func testReadinessGatesOnFirstReadNotObjectExistence() async {
        let setter = MockSetter()
        // The surface object EXISTS, but the engine's first known-limit read has NOT settled.
        let gate = IntentReadinessGate(timeout: .milliseconds(50))
        let surface = ChargeControlIntentSurface(setter: setter, isSetUp: { true },
                                                 readinessGate: gate)
        let before = await surface.setLimit(80)
        XCTAssertEqual(before, .notReady, "object existence alone is not readiness — it gates on the first read")
        XCTAssertTrue(setter.calls.isEmpty, "must not route before the first known-limit read settles")
        // The engine's first known-limit read completes:
        gate.settle()
        let after = await surface.setLimit(80)
        XCTAssertEqual(after, .applied, "after the first known-limit read settles, it routes")
        XCTAssertEqual(setter.calls.count, 1)
        XCTAssertEqual(setter.calls.first?.source, .appIntent)
    }

    // MARK: - the bounded-timeout honest-fail path (could-not-ready, never a hang)

    func testBoundedTimeoutProducesCouldNotReadyNotHang() async {
        let setter = MockSetter()
        // Never settled → the bounded readiness timeout must elapse and return an honest could-not-ready,
        // not hang the test.
        let gate = IntentReadinessGate(timeout: .milliseconds(50))
        let surface = ChargeControlIntentSurface(setter: setter, isSetUp: { true },
                                                 readinessGate: gate)
        let r = await surface.setLimit(80)
        XCTAssertEqual(r, .notReady)
        XCTAssertTrue(setter.calls.isEmpty, "a timed-out readiness must not reach the engine")
    }

    // MARK: - honest, non-acting failure: charge control not set up

    func testNotSetUpReturnsNotSetUpAndDoesNotRoute() async {
        let setter = MockSetter()
        let surface = makeSurface(setter: setter, setUp: false, settled: true)
        let result = await surface.setLimit(80)
        XCTAssertEqual(result, .notSetUp, "charge control not set up → honest, non-acting")
        XCTAssertTrue(setter.calls.isEmpty, "a not-set-up set must not reach the engine (never a stuck shortcuts run)")
    }

    // MARK: - audit B1 (00-AUDIT item 5): a set-up, settled Mac that cannot read its limit back (degraded
    // read-back, no custody) must still ROUTE the Set and report the engine's honest verdict — setting a
    // limit does not require reading the current one. Against today's step-3 guard this dead-ends at
    // .notReady before routing (the engine is never called) → RED.

    func testDegradedSetUpRoutesInsteadOfDeadEnd() async {
        let setter = MockSetter(); setter.outcome = .appliedUnconfirmed
        let surface = makeSurface(setter: setter, setUp: true, settled: true)
        let result = await surface.setLimit(80)
        XCTAssertEqual(result, .appliedUnconfirmed,
                       "a set-up, settled Mac with no readable limit must route and report the engine's honest verdict")
        XCTAssertEqual(setter.calls.count, 1, "the Set must reach the engine, not dead-end at .notReady")
        XCTAssertEqual(setter.calls.first?.source, .appIntent)
    }

    // MARK: - success confirmation through the REAL engine read-verify (sec 10)

    // The runner is driven via its `fallback` so EVERY Get read-back returns a fixed value — the
    // assertion is then robust to the engine's internal retry-read count and BehaviorConfirm's own
    // out-of-band reads (both consume the FIFO queue). Custody seeds a known pre-state for the engine's
    // read-verify (audit B1 removed the surface's own known-limit pre-check).

    func testReportsAppliedOnlyWhenEngineConfirmsTarget() async {
        let runner = MockShortcutRunner()
        runner.fallback = .init(.success(stdout: ""), file: "80")   // every read-verify Get reads 80
        let engine = ChargeLimitEngine(runner: runner,
                                       custodyStore: MockLastSetCustodyStore(LastSetCustody(value: 90, at: Date())))
        let gate = IntentReadinessGate(timeout: .milliseconds(50))
        gate.settle()
        let surface = ChargeControlIntentSurface(setter: engine, isSetUp: { true },
                                                 readinessGate: gate)
        let r = await surface.setLimit(80)
        XCTAssertEqual(r, .applied, "the engine's read-verify confirmed 80 → applied")
        XCTAssertEqual(engine.limit, .known(80))
    }

    func testReportsCouldNotConfirmOnReadVerifyMismatch() async {
        let runner = MockShortcutRunner()
        // The read-back is a VALID in-range value (95, ∈ 80...100) that ≠ the target 80 — a genuine
        // mismatch the engine adopts, NOT an out-of-range value that would degrade to "as set".
        runner.fallback = .init(.success(stdout: ""), file: "95")   // every read-verify Get reads 95 ≠ 80
        let engine = ChargeLimitEngine(runner: runner,
                                       custodyStore: MockLastSetCustodyStore(LastSetCustody(value: 90, at: Date())))
        let gate = IntentReadinessGate(timeout: .milliseconds(50))
        gate.settle()
        let surface = ChargeControlIntentSurface(setter: engine, isSetUp: { true },
                                                 readinessGate: gate)
        let r = await surface.setLimit(80)
        XCTAssertEqual(r, .couldNotConfirm, "the engine never reached 80 (read-verify keeps reading 95) → honest could-not-confirm")
        XCTAssertEqual(engine.limit, .known(95))
    }

    // MARK: - audit A2 (00-AUDIT item 3): the verdict maps the engine's CommandOutcome, NOT a re-read of
    // the current limit. The mock setter returns each CommandOutcome and the surface asserts the
    // SetLimitResult it maps to — a degraded write must never be reported as verified .applied (the A2 hole).

    func testVerdictMapsAppliedToApplied() async {
        let m = MockSetter(); m.outcome = .applied
        let r = await makeSurface(setter: m).setLimit(80)
        XCTAssertEqual(r, .applied)
        XCTAssertEqual(m.calls.count, 1, "the set routed to the engine")
    }

    func testVerdictMapsAppliedUnconfirmedToAppliedUnconfirmed() async {
        // The CORE A2 fix: a degraded write the engine could not read-verify must NOT report verified
        // .applied — the surface maps the engine's `.appliedUnconfirmed` honestly, not to `.applied`.
        let m = MockSetter(); m.outcome = .appliedUnconfirmed
        let r = await makeSurface(setter: m).setLimit(80)
        XCTAssertEqual(r, .appliedUnconfirmed)
    }

    func testVerdictMapsIssueFailedToCouldNotConfirm() async {
        let m = MockSetter(); m.outcome = .issueFailed(.setupRequired)
        let r = await makeSurface(setter: m).setLimit(80)
        XCTAssertEqual(r, .couldNotConfirm)
    }

    func testVerdictMapsMismatchToCouldNotConfirm() async {
        let m = MockSetter(); m.outcome = .mismatch(observed: 95)
        let r = await makeSurface(setter: m).setLimit(80)
        XCTAssertEqual(r, .couldNotConfirm)
    }

    func testVerdictMapsBusyToCouldNotConfirm() async {
        let m = MockSetter(); m.outcome = .busy
        let r = await makeSurface(setter: m).setLimit(80)
        XCTAssertEqual(r, .couldNotConfirm)
    }

    func testVerdictMapsInvalidTargetToCouldNotConfirm() async {
        let m = MockSetter(); m.outcome = .invalidTarget(83)
        let r = await makeSurface(setter: m).setLimit(80)
        XCTAssertEqual(r, .couldNotConfirm)
    }

    // MARK: - serialization (the engine's commandInFlight guard applies to .appIntent too)

    func testSecondAppIntentSetWhileInFlightIsNoOp() async {
        let runner = GatingShortcutRunner()
        let engine = ChargeLimitEngine(runner: runner)
        let first = Task { await engine.userSetLimit(80, source: .appIntent) }
        while !engine.commandInFlight { await Task.yield() }   // wait until the first set is genuinely in-flight
        _ = await engine.userSetLimit(85, source: .appIntent)       // second while in-flight → guarded no-op
        runner.release()                                        // let the first finish
        _ = await first.value
        XCTAssertFalse(runner.setNames.contains("Battery Limit 85"), "the in-flight guard blocks the second set")
        XCTAssertTrue(runner.setNames.contains("Battery Limit 80"), "the first set still ran")
    }

    // MARK: - non-blocking lock (spec sec 8 / sec 10): an .appIntent set uses the same non-blocking
    // read-verify path as .user — no synchronous modal — and applies.

    func testAppIntentSetUsesNonBlockingReadVerifyAndApplies() async {
        let runner = MockShortcutRunner([
            .init(.success(stdout: "")),              // the Set shortcut
            .init(.success(stdout: ""), file: "80"),  // the read-verify Get → reads 80
        ])
        let engine = ChargeLimitEngine(runner: runner)
        _ = await engine.userSetLimit(80, source: .appIntent)
        XCTAssertEqual(engine.limit, .known(80))
        XCTAssertEqual(engine.lastCommandSource, .appIntent)
    }
}

/// A runner that holds its FIRST `run` (the first Set) suspended until released, so a test can issue a
/// second set while the first is in-flight and confirm the engine's commandInFlight guard no-ops it.
final class GatingShortcutRunner: ShortcutRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var runCount = 0
    private var releasedFlag = false
    private var names: [String] = []
    var setNames: [String] { lock.lock(); defer { lock.unlock() }; return names }
    func release() { lock.lock(); releasedFlag = true; lock.unlock() }
    private func isReleased() -> Bool { lock.lock(); defer { lock.unlock() }; return releasedFlag }

    /// Sync helper: NSLock lock()/unlock() are unavailable in async contexts (Swift 6) — do the
    /// mutation here, off the async path (mirrors MockShortcutRunner.record).
    private func recordRun(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        runCount += 1; names.append(name); return runCount
    }
    func run(name: String, outputPath: String?) async -> ShortcutRunOutcome {
        let n = recordRun(name)
        if n == 1 { while !isReleased() { await Task.yield() } }   // gate ONLY the first Set
        return .success(stdout: "")
    }
    func list() async -> ShortcutRunOutcome { .success(stdout: "") }
}
