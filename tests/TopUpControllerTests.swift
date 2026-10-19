import XCTest

/// Sprint 4.F (#8): the full Top Up lifecycle matrix (SPEC sec 2), driven against a real engine
/// (scripted MockShortcutRunner) + injected reading/store/now seams. Every edge is named.
@MainActor
final class TopUpControllerTests: XCTestCase {

    // MARK: - seams

    final class ReadingBox { var soc: Int?; var onAC: Bool
        init(soc: Int?, onAC: Bool) { self.soc = soc; self.onAC = onAC } }
    final class NowBox { var t: Date; init(_ t: Date) { self.t = t } }
    final class MemTopUpStore: TopUpStoring, @unchecked Sendable {
        private let lock = NSLock(); private var s: TopUpState?
        init(_ s: TopUpState? = nil) { self.s = s }
        func load() -> TopUpState? { lock.lock(); defer { lock.unlock() }; return s }
        func save(_ x: TopUpState) { lock.lock(); s = x; lock.unlock() }
        func clear() { lock.lock(); s = nil; lock.unlock() }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func setOutcome() -> MockShortcutRunner.Scripted { .init(.success(stdout: "")) }
    private func getOutcome(_ v: Int) -> MockShortcutRunner.Scripted { .init(.success(stdout: ""), file: String(v)) }

    /// Engine at `baseline`, a controller wired to the boxes. Paused via a seeded capture.
    private func make(baseline: Int, soc: Int, onAC: Bool = true, paused: Bool = false,
                      store: MemTopUpStore = MemTopUpStore(), now: Date? = nil,
                      custody: LastSetCustody? = nil)
    async -> (TopUpController, ChargeLimitEngine, MockShortcutRunner, ReadingBox, NowBox, MemTopUpStore) {
        let mock = MockShortcutRunner([getOutcome(baseline)])
        let capture = paused ? MockPauseCaptureStore(PauseCapture(pausedFromLimit: baseline, pauseTarget: 80, capturedAt: base))
                             : MockPauseCaptureStore()
        let engine = ChargeLimitEngine(runner: mock, captureStore: capture,
                                       custodyStore: MockLastSetCustodyStore(custody),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)   // engine.limit = baseline
        let reading = ReadingBox(soc: soc, onAC: onAC)
        let nowBox = NowBox(now ?? base)
        let controller = TopUpController(engine: engine,
                                         reading: { TopUpController.Reading(soc: reading.soc, onAC: reading.onAC) },
                                         store: store, now: { nowBox.t })
        return (controller, engine, mock, reading, nowBox, store)
    }

    // MARK: - happy path

    func testHappyPath_climbToFullThenRevert() async {
        let (c, engine, mock, reading, _, store) = await make(baseline: 80, soc: 90)
        mock.script([setOutcome(), getOutcome(100),   // Set 100
                     getOutcome(100),                  // pre-revert Get
                     setOutcome(), getOutcome(80)])    // revert Set 80
        let start = await c.topUp()
        XCTAssertEqual(start, .started, "the start succeeded (climbing)")
        XCTAssertEqual(c.phase, .climbing)
        XCTAssertEqual(engine.limit, .known(100), "climb leg sets 100")
        reading.soc = 100
        await c.evaluate()                              // full → revert
        XCTAssertEqual(engine.limit, .known(80), "reverted to the captured 80")
        XCTAssertEqual(engine.lastCommandSource, .topUp, "revert leg is .topUp")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.note, "Top Up: limit restored to 80%")
        XCTAssertNil(store.load(), "persisted state cleared on completion")
    }

    // MARK: - unplug

    func testUnplugMidClimb_cancelsAndRestores() async {
        let (c, engine, mock, reading, _, _) = await make(baseline: 80, soc: 90)
        mock.script([setOutcome(), getOutcome(100), getOutcome(100), setOutcome(), getOutcome(80)])
        await c.topUp()
        reading.onAC = false
        await c.evaluate()                              // unplug → restore
        XCTAssertEqual(engine.limit, .known(80), "unplug restores the capture immediately")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.note, "Top Up ended — unplugged. Limit restored.")
    }

    // MARK: - external change mid-climb (no restore)

    func testExternalChangeMidClimb_cancelsNoRestore() async {
        let (c, engine, mock, _, _, _) = await make(baseline: 80, soc: 90)
        mock.script([setOutcome(), getOutcome(100)])    // Set 100 only
        await c.topUp()
        // Simulate an external/manual change to 90 mid-climb (a re-sync reads it). B-arc B5: `.wake`
        // rather than `.popoverOpen` — the harness already spent this engine's popover-open budget
        // seeding the baseline, and the trigger is incidental here (both read and adopt identically).
        mock.script([getOutcome(90)])
        await engine.sync(.wake)
        XCTAssertEqual(engine.limit, .known(90))
        await c.evaluate()                              // limit != 100 → cancel, NO restore
        XCTAssertEqual(engine.limit, .known(90), "their value stands; no restore Set")
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"), "no restore was issued")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.note, "Top Up ended — the limit was changed.")
    }

    // MARK: - cancel button

    /// REGRESSION (owner-reported 2026-08-12): a climb that can never progress must still be escapable.
    /// On macOS 27 a stale sub-limit hold (NotChargingReason 0x01000000) IGNORES the raise to 100, so the
    /// battery sits on AC at the old ceiling with InstantAmperage 0 and SoC never moves. Every one of
    /// `evaluate()`'s self-exits is then unreachable — still on AC, limit still 100, SoC < 100 — so the
    /// climb holds until the 12 h TTL. Verified live: 80% / AC attached / not charging / limit 100.
    func testStalledClimbNeverSelfExits_butCancelAlwaysEscapes() async {
        let (c, engine, mock, reading, _, store) = await make(baseline: 80, soc: 80)
        mock.script([setOutcome(), getOutcome(100)])
        let start = await c.topUp()
        XCTAssertEqual(start, .started)
        XCTAssertEqual(engine.limit, .known(100), "the ceiling was raised")
        XCTAssertEqual(c.phase, .climbing)

        // The hold ignores the raise: still on AC, limit still 100, SoC pinned at the old ceiling.
        // Drive the watcher repeatedly — this is what the snapshot loop does, and it changes nothing.
        for _ in 0..<5 {
            await c.evaluate()
            XCTAssertEqual(c.phase, .climbing, "no self-exit is reachable while the hold persists")
        }
        XCTAssertTrue(c.isInProgress, "so the spinner stays up…")
        XCTAssertNotNil(store.load(), "…and the state persists, surviving relaunch")
        XCTAssertTrue(c.canCancel, "Cancel MUST be offered — it is the only way out short of the TTL")

        // The escape hatch: restores the captured ceiling and clears the persisted state.
        mock.script([getOutcome(100), setOutcome(), getOutcome(80)])
        await c.cancel()
        XCTAssertEqual(engine.limit, .known(80), "the owner's real limit is restored")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(c.isInProgress, "spinner cleared")
        XCTAssertFalse(c.canCancel)
        XCTAssertNil(store.load(), "and nothing is left to resume on the next launch")
        _ = reading
    }

    /// Cancel is offered ONLY while climbing — never during an in-flight Set, which it would not interrupt.
    func testCanCancelOnlyWhileClimbing() async {
        let (c, engine, mock, _, _, _) = await make(baseline: 80, soc: 90)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(c.canCancel, "nothing to cancel when idle")

        mock.script([setOutcome(), getOutcome(100)])
        await c.topUp()
        XCTAssertTrue(c.canCancel, "climbing → offered")

        mock.script([getOutcome(100), setOutcome(), getOutcome(80)])
        await c.cancel()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(c.canCancel, "back to idle → withdrawn")
        XCTAssertEqual(engine.limit, .known(80))
    }

    func testCancelButton_revertsViaPreVerifiedPath() async {
        let (c, engine, mock, _, _, _) = await make(baseline: 80, soc: 90)
        mock.script([setOutcome(), getOutcome(100), getOutcome(100), setOutcome(), getOutcome(80)])
        await c.topUp()
        await c.cancel()
        XCTAssertEqual(engine.limit, .known(80))
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.note, "Top Up cancelled. Limit restored.")
    }

    // MARK: - pre-revert mismatch

    func testPreRevertMismatch_abortsNoRestore() async {
        let (c, engine, mock, reading, _, _) = await make(baseline: 80, soc: 90)
        mock.script([setOutcome(), getOutcome(100),     // Set 100
                     getOutcome(90)])                    // pre-revert Get returns 90 (changed mid-flight)
        await c.topUp()
        reading.soc = 100
        await c.evaluate()                              // full → revert → pre-Get mismatch → abort
        XCTAssertEqual(engine.limit, .known(90), "pre-revert Get adopted 90; no restore over it")
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"))
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.note, "Top Up ended — the limit was changed.")
    }

    // MARK: - relaunch

    func testRelaunchResume_limitStill100ResumesWatching() async {
        let store = MemTopUpStore(TopUpState(capturedLimit: 80, startedAt: base.addingTimeInterval(-3600)))
        let (c, _, mock, _, _, _) = await make(baseline: 100, soc: 95, store: store)
        mock.script([getOutcome(100)])                  // resume Get → still 100
        await c.resumeOnLaunch()
        XCTAssertEqual(c.phase, .climbing, "still 100 → resume watching")
        XCTAssertEqual(c.capturedLimit, 80)
    }

    func testRelaunchCancel_limitChangedCancelsNoRestore() async {
        let store = MemTopUpStore(TopUpState(capturedLimit: 80, startedAt: base.addingTimeInterval(-3600)))
        let (c, engine, mock, _, _, _) = await make(baseline: 90, soc: 95, store: store)
        mock.script([getOutcome(90)])                   // resume Get → 90 (world changed)
        await c.resumeOnLaunch()
        XCTAssertEqual(c.phase, .idle, "changed → cancel, no restore")
        XCTAssertEqual(engine.limit, .known(90))
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"))
        XCTAssertEqual(c.note, "Top Up ended — the limit was changed.")
    }

    // MARK: - TTL

    func testTTL_olderThan12hCancelsWithRestoreAttempt() async {
        let store = MemTopUpStore(TopUpState(capturedLimit: 80, startedAt: base.addingTimeInterval(-13 * 3600)))
        let (c, engine, mock, _, _, _) = await make(baseline: 100, soc: 100, store: store, now: base)
        mock.script([getOutcome(100), setOutcome(), getOutcome(80)])   // pre-Get 100 → restore 80
        await c.resumeOnLaunch()
        XCTAssertEqual(engine.limit, .known(80), "a forgotten Top Up restores, not pins 100")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.note, "Top Up timed out — restoring your limit.")
    }

    // MARK: - paused

    func testPaused_topUpRefusedWithHint() async {
        let (c, _, mock, _, _, _) = await make(baseline: 80, soc: 90, paused: true)
        XCTAssertTrue(c.phase == .idle)
        let start = await c.topUp()
        XCTAssertEqual(start, .refusedPaused, "paused refuses with the resume hint")
        XCTAssertEqual(c.phase, .idle, "contradictory intents refused, not reconciled")
        XCTAssertEqual(c.note, "Resume charging first")
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 100"), "no Set while paused")
    }

    // MARK: - full at start (near no-op)

    // MARK: - 4.I addendum: relaunch-resume consults the persisted custody when the Get is degraded

    private func degradedEngine(custodyValue: Int) -> ChargeLimitEngine {
        let mock = MockShortcutRunner([]); mock.fallback = .init(.missingShortcut)   // no Get
        return ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                 custodyStore: MockLastSetCustodyStore(LastSetCustody(value: custodyValue, at: base)),
                                 clock: MockMonotonicClock(box: MockClockBox(0)))
    }
    private func controller(_ engine: ChargeLimitEngine, store: MemTopUpStore) -> TopUpController {
        let reading = ReadingBox(soc: 95, onAC: true); let nowBox = NowBox(base)
        return TopUpController(engine: engine,
                               reading: { TopUpController.Reading(soc: reading.soc, onAC: reading.onAC) },
                               store: store, now: { nowBox.t })
    }

    func testRelaunchResumeViaCustody_degraded() async {
        // Active Top Up persisted; custody == 100 (the climb's Set); Get unavailable.
        let store = MemTopUpStore(TopUpState(capturedLimit: 80, startedAt: base.addingTimeInterval(-3600)))
        let engine = degradedEngine(custodyValue: 100)
        XCTAssertEqual(engine.limit, .known(100), "custody restored on relaunch")
        let c = controller(engine, store: store)
        await c.resumeOnLaunch()
        XCTAssertEqual(c.phase, .climbing, "custody == 100 → resume watching despite no Get")
        XCTAssertEqual(c.capturedLimit, 80)
    }

    func testRelaunchCancelWhenCustodyDiverged_degraded() async {
        // custody == 90 ≠ 100 → the climb is no longer intact → cancel, no restore.
        let store = MemTopUpStore(TopUpState(capturedLimit: 80, startedAt: base.addingTimeInterval(-3600)))
        let c = controller(degradedEngine(custodyValue: 90), store: store)
        await c.resumeOnLaunch()
        XCTAssertEqual(c.phase, .idle, "diverged custody → cancel")
        XCTAssertEqual(c.note, "Top Up ended — the limit was changed.")
    }

    // MARK: - 4.I degraded revert (Get unavailable → proceed on LastSetTracker custody + caveat)

    func testDegradedRevert_proceedsWithCaveat() async {
        let (c, engine, mock, reading, _, _) = await make(baseline: 80, soc: 90)
        mock.script([setOutcome(), getOutcome(100)])   // verified climb to 100
        await c.topUp()
        XCTAssertEqual(engine.limit, .known(100))
        reading.soc = 100
        // Revert with NO working Get (27.0 removed the action): pre-revert Get + the revert Set's
        // read-verify both fall to .missingShortcut → degraded.
        mock.fallback = .init(.missingShortcut)
        mock.script([.init(.missingShortcut),          // pre-revert Get → engine.limit = .unknown
                     setOutcome()])                    // revert Set 80 (read-verify Get → fallback missing)
        await c.evaluate()                             // full → revert PROCEEDS in degraded mode
        XCTAssertEqual(engine.limit, .known(80), "revert proceeded on LastSetTracker custody, not cancelled")
        XCTAssertEqual(engine.lastCommandSource, .topUp)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertTrue(c.note?.contains("read-back unavailable") ?? false,
                      "the degraded caveat rides the Top Up status: \(c.note ?? "nil")")
    }

    // MARK: - audit A1 (00-AUDIT item 2): revert/start consume the keystone CommandOutcome instead of
    // reconstructing success from a re-read of engine.limit.

    func testRevert_restoreSetFails_doesNotClaimRestored() async {
        // Climb verified to 100, full → revert; the pre-revert Get is intact (100) but the RESTORE Set
        // itself fails (shortcut missing). The honest note must NOT claim the limit was restored, and must
        // tell the user to set it manually. (RED today: revert finishes "limit restored to N%" regardless.)
        let (c, engine, mock, reading, _, _) = await make(baseline: 80, soc: 90)
        mock.script([setOutcome(), getOutcome(100),    // topUp Set 100 (verified)
                     getOutcome(100),                  // pre-revert Get → intact 100
                     .init(.missingShortcut)])         // restore Set 80 FAILS → .issueFailed
        await c.topUp()
        reading.soc = 100
        await c.evaluate()                             // full → revert → restore Set fails
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(c.note?.contains("restored") ?? true,
                       "a failed restore must NOT claim the limit was restored: \(c.note ?? "nil")")
        XCTAssertTrue(c.note?.contains("manually") ?? false,
                      "the honest note tells the user to set the limit manually: \(c.note ?? "nil")")
        XCTAssertEqual(engine.limit, .known(100), "the failed restore did not change the limit")
    }

    func testRevert_restoreReadBackUnavailable_carriesUnconfirmedCaveat() async {
        // VERIFIED pre-revert Get (100) but the RESTORE Set's own read-back is unavailable → the restore
        // outcome is .appliedUnconfirmed, which is now the authoritative verified-vs-unconfirmed signal.
        // (RED today: the caveat is driven by the pre-revert syncProblem, which is nil here → no caveat.)
        let (c, engine, mock, reading, _, _) = await make(baseline: 80, soc: 90)
        mock.script([setOutcome(), getOutcome(100),    // topUp Set 100 (verified)
                     getOutcome(100),                  // pre-revert Get → VERIFIED 100 (syncProblem nil)
                     setOutcome(),                     // restore Set 80 succeeds
                     .init(.missingShortcut)])         // restore read-verify Get unavailable → .appliedUnconfirmed
        await c.topUp()
        reading.soc = 100
        await c.evaluate()                             // full → revert
        XCTAssertEqual(engine.limit, .known(80), "the as-set restore value is adopted")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertTrue(c.note?.contains("read-back unavailable") ?? false,
                      "the .appliedUnconfirmed restore carries the read-back caveat: \(c.note ?? "nil")")
    }

    func testStart_setFailsWhenAlreadyAt100_abortsHonestly() async {
        // Limit already 100; the Set 100 FAILS. The old engine.limit == .known(100) re-read wrongly sees
        // "100, good" and climbs; gating on outcome.didWrite honestly aborts. (RED today → .climbing.)
        let (c, _, mock, _, _, _) = await make(baseline: 100, soc: 90)
        mock.script([.init(.missingShortcut)])         // Set 100 FAILS → .issueFailed, didWrite false
        let start = await c.topUp()
        XCTAssertEqual(start, .couldNotStart, "a failed start reports couldNotStart")
        XCTAssertEqual(c.phase, .idle, "a failed start aborts even when the limit was already 100")
        XCTAssertEqual(c.note, "Top Up couldn't start")
    }

    func testFullAtStart_nearNoOp() async {
        let (c, engine, mock, _, _, _) = await make(baseline: 100, soc: 100)
        mock.script([setOutcome(), getOutcome(100),     // Set 100 (already 100)
                     getOutcome(100), setOutcome(), getOutcome(100)])   // revert restores 100
        await c.topUp()
        await c.evaluate()                              // already full → immediate revert to 100
        XCTAssertEqual(engine.limit, .known(100))
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.note, "Top Up: limit restored to 100%")
    }
}
