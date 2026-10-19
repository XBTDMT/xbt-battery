import XCTest
import Combine

/// Sprint 4.C + 4g: the runner's behaviors against injected seams (clock/pacer/store) and a real
/// engine driven by the scripted mock shortcut runner — firing, idempotence, the 4g thermostat-hold
/// (a manual change holds via the fired-set then the next trigger reasserts; no skip), Resume =
/// apply-the-schedule-now, the deferred-action consumption (human primacy mid-deferral, == .user),
/// in-flight deference (+5-min cap), pause suspension, setup gating, wake catch-up, and the
/// `.schedule` source tag. No real timers or wall-clock waits.
@MainActor
final class ScheduleRunnerTests: XCTestCase {

    // MARK: - seams

    final class MockScheduleClock: ScheduleClock, @unchecked Sendable {
        private let lock = NSLock(); private var v: Date
        init(_ d: Date) { v = d }
        var nowValue: Date {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
        func now() -> Date { nowValue }
    }

    final class MockPacer: SchedulePacing {
        private var onTick: (() -> Void)?
        /// B-arc B3: the pacer's lifecycle is now behavior under test, so record it.
        private(set) var isRunning = false
        private(set) var startCount = 0
        func start(interval: TimeInterval, onTick: @escaping () -> Void) {
            self.onTick = onTick; isRunning = true; startCount += 1
        }
        func stop() { onTick = nil; isRunning = false }
        func tick() { onTick?() }
    }

    final class MemStore: ScheduleStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var c: ChargeScheduleConfig; private var f: Set<FiredOccurrence>
        init(_ c: ChargeScheduleConfig) { self.c = c; self.f = [] }
        func loadConfig() -> ChargeScheduleConfig { lock.lock(); defer { lock.unlock() }; return c }
        func saveConfig(_ x: ChargeScheduleConfig) { lock.lock(); c = x; lock.unlock() }
        func loadFired() -> Set<FiredOccurrence> { lock.lock(); defer { lock.unlock() }; return f }
        func saveFired(_ x: Set<FiredOccurrence>) { lock.lock(); f = x; lock.unlock() }
    }

    // MARK: - harness

    private func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal().date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    private let A = ChargeRule(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!, hour: 22, minute: 0, limit: 80)
    private let B = ChargeRule(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!, hour: 7, minute: 30, limit: 100)

    /// Build an engine whose current limit is `baseline`, plus a runner wired to mock seams.
    private func makeRunner(rules: [ChargeRule], enabled: Bool, now: Date, baseline: Int,
                            setupReady: Bool = true,
                            isSetupReady: (() -> Bool)? = nil)
    async -> (ScheduleRunner, ChargeLimitEngine, MockShortcutRunner, MockScheduleClock, MockPacer, MemStore) {
        let mockRunner = MockShortcutRunner([.init(.success(stdout: ""), file: String(baseline))])
        let engine = ChargeLimitEngine(runner: mockRunner, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)   // engine.limit = .known(baseline), BEFORE the runner observes
        let clock = MockScheduleClock(now); let pacer = MockPacer()
        let store = MemStore(ChargeScheduleConfig(enabled: enabled, rules: rules, presetOffered: false))
        let runner = ScheduleRunner(engine: engine, store: store, clock: clock, pacer: pacer,
                                    isSetupReady: isSetupReady ?? { setupReady }, calendarProvider: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c })
        return (runner, engine, mockRunner, clock, pacer, store)
    }

    private func setupFlow(_ stdout: String) async -> SetupFlow {
        let f = SetupFlow(runner: MockShortcutRunner([.init(.success(stdout: stdout))]))
        await f.checkNow()
        return f
    }
    private static let fiveSetsNoGet = "Battery Limit 80\nBattery Limit 85\nBattery Limit 90\nBattery Limit 95\nBattery Limit 100"

    private func drain(until cond: @autoclosure () -> Bool, _ msg: String = "",
                       file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<3000 { if cond() { return }; await Task.yield() }
        XCTFail("condition never met: \(msg)", file: file, line: line)
    }

    // MARK: - firing

    func testFiresScheduledSetWhenDueAndTagsSource() async {
        let (runner, engine, mock, _, _, store) = await makeRunner(rules: [A], enabled: true,
                                                                   now: date(2026, 6, 10, 22, 1), baseline: 100)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()   // recompute(.launch): operative = today 22:00 → 80, limit is 100 → fires
        await drain(until: engine.limit == .known(80), "scheduled set should apply 80")
        XCTAssertEqual(engine.lastCommandSource, .schedule, "the Set must be tagged .schedule")
        XCTAssertTrue(mock.invocationNames.contains("Battery Limit 80"))
        XCTAssertEqual(store.loadFired().count, 1, "occurrence recorded for idempotence")
    }

    func testRecomputeProceedsInDegradedViaIsOperational() async {
        // The bug: the schedule was gated strict on .ready, so on macOS 27 (.readyDegraded) it never ran.
        // Wired to setupFlow.isOperational, a degraded-but-set-up flow proceeds (the schedule only SETS).
        let degraded = await setupFlow(Self.fiveSetsNoGet)
        XCTAssertEqual(degraded.state, .readyDegraded)
        let (runner, engine, mock, _, _, _) = await makeRunner(rules: [A], enabled: true,
                                                               now: date(2026, 6, 10, 22, 1), baseline: 100,
                                                               isSetupReady: { degraded.isOperational })
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()   // recompute(.launch)
        await drain(until: engine.limit == .known(80), "degraded schedule should still fire the set")
        XCTAssertNotEqual(runner.note, "Schedule paused — setup required",
                          "degraded is operational, not a setup wall")
    }

    func testRecomputeStillPausesForGenuinelyNotSetUp() async {
        // A genuinely-not-set-up flow (the five SET shortcuts missing) is NOT operational → honest pause.
        let missing = await setupFlow("")   // empty list → .missing(the five sets)
        XCTAssertFalse(missing.isOperational)
        let (runner, _, _, _, _, _) = await makeRunner(rules: [A], enabled: true,
                                                       now: date(2026, 6, 10, 22, 1), baseline: 100,
                                                       isSetupReady: { missing.isOperational })
        runner.start()
        XCTAssertEqual(runner.note, "Schedule paused — setup required")
    }

    func testIdempotentDoesNotDoubleFire() async {
        let (runner, engine, mock, _, pacer, _) = await makeRunner(rules: [A], enabled: true,
                                                                   now: date(2026, 6, 10, 22, 1), baseline: 100)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()
        await drain(until: engine.limit == .known(80))
        let setsAfterFirst = mock.invocationNames.filter { $0 == "Battery Limit 80" }.count
        // Many more ticks must NOT re-fire (fired-key guard, even though limit is now 80 anyway).
        for _ in 0..<5 { pacer.tick(); await Task.yield() }
        XCTAssertEqual(mock.invocationNames.filter { $0 == "Battery Limit 80" }.count, setsAfterFirst)
    }

    func testValueAlreadyMatchesDoesNotFire() async {
        let (runner, _, mock, _, _, _) = await makeRunner(rules: [A], enabled: true,
                                                          now: date(2026, 6, 10, 22, 1), baseline: 80)
        runner.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"), "limit already 80 → nothing to do")
    }

    func testDisabledDoesNotFire() async {
        let (runner, _, mock, _, _, _) = await makeRunner(rules: [A], enabled: false,
                                                          now: date(2026, 6, 10, 22, 1), baseline: 100)
        runner.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"))
    }

    func testWakeCatchUpFiresMissedOccurrence() async {
        // Launch at 00:30 (asleep through 22:00): wake/launch recompute fires yesterday's 22:00→80.
        let (runner, engine, mock, _, _, _) = await makeRunner(rules: [A], enabled: true,
                                                               now: date(2026, 6, 10, 0, 30), baseline: 100)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()
        runner.recompute(.wake)
        await drain(until: engine.limit == .known(80), "catch-up should fire yesterday's 22:00 rule")
    }

    // MARK: - setup gating / pause

    func testSetupNotReadyShowsNoteNoFire() async {
        let (runner, _, mock, _, _, _) = await makeRunner(rules: [A], enabled: true,
                                                          now: date(2026, 6, 10, 22, 1), baseline: 100,
                                                          setupReady: false)
        runner.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(runner.note, "Schedule paused — setup required")
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"))
    }

    func testPauseSuspendsWithNoteNoFire() async {
        let (runner, engine, mock, _, _, _) = await makeRunner(rules: [A], enabled: true,
                                                               now: date(2026, 6, 10, 22, 1), baseline: 100)
        // Put the engine into a paused state (script a pause).
        let store2 = MockPauseCaptureStore(PauseCapture(pausedFromLimit: 100, pauseTarget: 80, capturedAt: Date()))
        _ = store2
        // Simpler: drive engine.pause() with scripted Set+Get.
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        engine.ingest(ChargeTelemetrySnapshot(timestamp: 0, socPercent: 90, rawCapacity_mAh: 4000,
            instantAmperage_mA: 2000, notChargingReason: 0, isChargingFlag: true,
            externalConnected: true, chargingCurrent_mA: 3000), state: .charging)
        _ = await engine.pause()
        XCTAssertTrue(engine.isPaused)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        let setsBefore = mock.invocationNames.count
        runner.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(runner.note, "Schedule paused — charging is paused")
        XCTAssertEqual(mock.invocationNames.count, setsBefore, "no scheduled fire while paused")
    }

    /// SWEEP H2 amendment 2 — a pause the app INFERRED from unreadable bytes must not borrow the
    /// sentence for a pause the user pressed.
    ///
    /// RED-FIRST: against the pre-fix runner this asserted a note that did not exist and a symbol
    /// (`engine.pauseRestorePointLost`) that did not compile. `ScheduleRunner.swift`'s single
    /// `"Schedule paused — charging is paused"` served BOTH cases, so a corrupt capture suspended the
    /// whole schedule while telling the user they had paused charging. They had not.
    func testACorruptPauseSuspendsWithTheHonestNoteNotTheUserPausedOne() async {
        let (_, _, mock, clock, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                 now: date(2026, 6, 10, 22, 1), baseline: 100)
        // A fresh engine over a store whose bytes will not decode — the launch shape, not a pause() call.
        let corruptEngine = ChargeLimitEngine(runner: mock,
                                              captureStore: MockPauseCaptureStore(nil, corrupt: true),
                                              custodyStore: MockLastSetCustodyStore(),
                                              clock: MockMonotonicClock(box: MockClockBox(0)))
        XCTAssertTrue(corruptEngine.isPaused, "precondition: change 1")
        XCTAssertTrue(corruptEngine.pauseRestorePointLost)
        let runner2 = ScheduleRunner(engine: corruptEngine, store: store, clock: clock, pacer: pacer,
                                     isSetupReady: { true },
                                     calendarProvider: { var c = Calendar(identifier: .gregorian)
                                                         c.timeZone = TimeZone(identifier: "America/Chicago")!
                                                         return c })
        let setsBefore = mock.invocationNames.count
        runner2.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(runner2.note, ChargeStatusStrings.schedulePausedRestorePointLostNote)
        XCTAssertNotEqual(runner2.note, "Schedule paused — charging is paused",
                          "the shared string IS the defect — it claims a user action that never happened")
        XCTAssertEqual(mock.invocationNames.count, setsBefore,
                       "the suspend itself is unchanged: `.corrupt` still stops the scheduler")
    }

    // MARK: - human primacy

    func testManualLowerDoesNotSkipScheduledRaise() async {
        // 4g HEADLINE (the trip fix): a manual change the night before must NOT suppress the morning
        // deadline-raise. rules [A 22:00→80, B 07:30→100]; the night-hold fires 80 (records A); the
        // user lowers to 90 at 23:00; the next morning's 07:30→100 raise must STILL fire (no skip).
        let (runner, engine, mock, clock, _, _) = await makeRunner(
            rules: [A, B], enabled: true, now: date(2026, 6, 10, 22, 1), baseline: 100)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()                                   // 22:00→80 fires, records A's occurrence
        await drain(until: engine.limit == .known(80), "night-hold should apply 80")
        engine.confirm.supersede()                       // clear the scheduled-set window

        // 23:00: the user manually lowers to 90.
        clock.nowValue = date(2026, 6, 10, 23, 0)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "90")])
        _ = await engine.userSetLimit(90)
        await drain(until: engine.limit == .known(90), "the user's manual 90 stands")
        engine.confirm.supersede()                       // tidy the user-set window (N1: an armed
                                                         // window no longer defers the scheduler)

        // Next day 07:31: the 07:30→100 deadline-raise must fire DESPITE the manual lower.
        clock.nowValue = date(2026, 6, 11, 7, 31)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "100")])
        runner.recompute(.timer)
        await drain(until: engine.limit == .known(100),
                    "the morning deadline-raise must fire; a manual lower must NOT skip it (the 4g trip fix)")
    }

    func testManualChangeHoldsThenNextTriggerReasserts() async {
        // 4g thermostat core: a manual change HOLDS (the fired occurrence does not re-fire — no skip
        // needed) until the NEXT trigger reasserts the schedule.
        let (runner, engine, mock, clock, pacer, _) = await makeRunner(
            rules: [A, B], enabled: true, now: date(2026, 6, 10, 22, 1), baseline: 100)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()
        await drain(until: engine.limit == .known(80), "night-hold applies 80")
        engine.confirm.supersede()

        clock.nowValue = date(2026, 6, 10, 23, 0)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "90")])
        _ = await engine.userSetLimit(90)
        await drain(until: engine.limit == .known(90), "the user's 90 stands")
        engine.confirm.supersede()

        // HOLD: several ticks leave the limit at 90 (the fired 22:00 occurrence does not re-fire).
        for _ in 0..<5 { pacer.tick(); await Task.yield() }
        XCTAssertEqual(engine.limit, .known(90), "the manual change holds via the fired-set, no skip")

        // REASSERT: the next morning's 07:30→100 trigger fires.
        clock.nowValue = date(2026, 6, 11, 7, 31)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "100")])
        pacer.tick()
        await drain(until: engine.limit == .known(100), "the next trigger reasserts the schedule")
    }

    func testResumeNowAppliesScheduleNow() async {
        // 4g Resume = apply the schedule's current dictate NOW. From an off-schedule state (night-hold
        // fired 80, user set 90), resumeNow applies the operative value (80) via a .schedule Set.
        let (runner, engine, mock, clock, _, _) = await makeRunner(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1), baseline: 100)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()
        await drain(until: engine.limit == .known(80))
        engine.confirm.supersede()

        clock.nowValue = date(2026, 6, 10, 23, 0)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "90")])
        _ = await engine.userSetLimit(90)
        await drain(until: engine.limit == .known(90))
        engine.confirm.supersede()

        // Resume applies the operative value (today's 22:00→80) via a .schedule-sourced Set.
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.resumeNow()
        await drain(until: engine.limit == .known(80), "Resume applies the schedule's current dictate (80) now")
        XCTAssertEqual(engine.lastCommandSource, .schedule, "Resume issues a .schedule-sourced Set")
    }

    // MARK: - #30 §4.7 isFired (read-only accessor for the Automation tab's "fired ›" caption)

    func testIsFiredReflectsTheFiredSetAndNeverMutatesIt() async {
        let (runner, engine, mock, clock, pacer, store) = await makeRunner(
            rules: [A, B], enabled: true, now: date(2026, 6, 10, 22, 1), baseline: 100)
        XCTAssertFalse(runner.isFired(A), "nothing has fired before start")
        XCTAssertFalse(runner.isFired(B))
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()
        await drain(until: engine.limit == .known(80))
        XCTAssertTrue(runner.isFired(A), "A's 22:00 occurrence fired → caption 'fired'")
        XCTAssertFalse(runner.isFired(B), "B (07:30 → 100) was superseded, never fired")
        // Reading is pure: the persisted set is unchanged and no tick changes the answer.
        let before = store.loadFired()
        for _ in 0..<3 { pacer.tick(); await Task.yield() }
        XCTAssertEqual(store.loadFired(), before)
        XCTAssertTrue(runner.isFired(A))
        // Past midnight A's most recent occurrence is still YESTERDAY's 22:00 (fired) until 22:00 today.
        clock.nowValue = date(2026, 6, 11, 9, 0)
        XCTAssertTrue(runner.isFired(A), "the same occurrence is still the most recent one")
        clock.nowValue = date(2026, 6, 11, 22, 5)
        XCTAssertFalse(runner.isFired(A), "a new (unfired) occurrence is now the most recent")
        XCTAssertEqual(engine.limit, .known(80), "isFired issued no Set")
    }

    // MARK: - in-flight deference (ONLY a command actually holding the engine lock is "busy")

    /// Arm a real `.chargingToCap` confirm window via BehaviorConfirm's PUBLIC API (no limit change,
    /// no engine modification) so `confirm.isWindowArmed == true` without a human override. Used to
    /// prove the window does NOT defer the scheduler — it is observation, not a command.
    private func armWindow(_ engine: ChargeLimitEngine) {
        engine.confirm.commandIssued(target: 95, preSetNCR: 0, socAtSet: 70,
                                     telemetryState: .charging, at: 0)
        XCTAssertTrue(engine.confirm.isWindowArmed)
    }

    /// The honest stand-in for "busy": an engine whose command lock can be HELD.
    ///
    /// The gated runner suspends inside a user Set of the limit the engine is ALREADY at, so
    /// `engine.commandInFlight` stays true until `release()` while nothing else moves — the value
    /// never changes (no `handleLimitChange`, so no human-primacy consumption) and no confirm window
    /// arms (`3af47ec`: a `target == 100` Set arms none). Returns the runner, the engine, the gated
    /// shortcut runner, the clock, the pacer, the store, and the held Task.
    private func makeBusyEngine(rules: [ChargeRule], enabled: Bool, now: Date)
    async -> (ScheduleRunner, ChargeLimitEngine, GatedShortcutRunner, MockScheduleClock, MockPacer,
              MemStore, Task<Void, Never>) {
        let gated = GatedShortcutRunner(getValue: "100", blockSetName: "Battery Limit 100")
        let engine = ChargeLimitEngine(runner: gated, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)
        XCTAssertEqual(engine.limit, .known(100))
        let clock = MockScheduleClock(now); let pacer = MockPacer()
        let store = MemStore(ChargeScheduleConfig(enabled: enabled, rules: rules, presetOffered: false))
        let runner = ScheduleRunner(engine: engine, store: store, clock: clock, pacer: pacer,
                                    isSetupReady: { true },
                                    calendarProvider: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c })
        // Take the lock and BLOCK inside it.
        let held = Task { @MainActor in _ = await engine.userSetLimit(100, source: .user) }
        await drain(until: gated.blockedSetEntered, "the held Set must own the engine command lock")
        XCTAssertTrue(engine.commandInFlight, "the engine command lock is genuinely held")
        return (runner, engine, gated, clock, pacer, store, held)
    }

    /// Release the held lock and wait for the engine to be free again, leaving the limit at 100.
    private func releaseLock(_ gated: GatedShortcutRunner, _ engine: ChargeLimitEngine,
                             _ held: Task<Void, Never>) async {
        gated.release()
        await held.value
        await drain(until: !engine.commandInFlight, "the command lock clears")
        XCTAssertEqual(engine.limit, .known(100), "the held Set re-asserted the value it started at")
    }

    // MARK: - N1: an armed confirm window is NOT a command in flight

    /// Grok N1, asked across three review rounds. `fire()` used to defer on
    /// `commandInFlight || confirm.isWindowArmed`. A `.chargingToCap` window is OBSERVATION AFTER a
    /// successful Set — it may stand for up to two hours of SAMPLED time (`capMaxWindow_s`), and the
    /// ceiling cannot rescue the colliding occurrence because `maxDeferral` (300 s) consumes it
    /// first. A daily rule landing inside such a window lost that day's fire. It must FIRE THROUGH.
    func testArmedConfirmWindowDoesNotDeferAScheduledSet() async {
        let (runner, engine, mock, _, _, store) = await makeRunner(rules: [A], enabled: true,
                                                                   now: date(2026, 6, 10, 22, 1), baseline: 100)
        armWindow(engine)                       // a .chargingToCap window is standing (up to 2 h)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()                          // operative 22:00 → 80 is due
        await drain(until: engine.limit == .known(80),
                    "the occurrence must fire THROUGH an armed confirm window — observation is not busy")
        XCTAssertTrue(store.loadFired().contains(occ(A, "2026-06-10")), "and it is recorded as fired")
        XCTAssertNil(runner.note, "no busy-skip note: the app was not busy, it was watching a climb")
        XCTAssertEqual(engine.lastCommandSource, .schedule, "the scheduled Set owns the command")
    }

    /// The consequence the reviewer stated and ACCEPTED: `commandIssued` supersedes the standing
    /// window, so a scheduled Set clobbers a manual Set still being watched. That is the schedule
    /// working; "manual Set owns the evening" would be a scheduler concept, not a 2-hour lock.
    func testAScheduledSetSupersedesTheWatchedManualWindow() async {
        let (runner, engine, mock, _, _, _) = await makeRunner(rules: [A], enabled: true,
                                                               now: date(2026, 6, 10, 22, 1), baseline: 100)
        armWindow(engine)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()
        await drain(until: engine.limit == .known(80), "the scheduled Set lands")
        XCTAssertFalse(engine.confirm.isWindowArmed,
                       "the manual window was superseded by the scheduled Set, not obeyed by it")
    }

    /// The 5-minute cap must never be reachable from a standing window any more: hold a window open
    /// well past `maxDeferral` and the occurrence is neither deferred nor consumed — it fires.
    func testArmedWindowPastTheFiveMinuteCapStillFiresRatherThanSkipping() async {
        let (runner, engine, mock, clock, pacer, store) = await makeRunner(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1), baseline: 100)
        armWindow(engine)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()
        await drain(until: engine.limit == .known(80), "fires immediately, so there is nothing to cap")
        clock.nowValue = date(2026, 6, 10, 22, 7)   // past what used to be the skip cap
        pacer.tick()
        for _ in 0..<6 { await Task.yield() }
        XCTAssertNotEqual(runner.note, "Scheduled change skipped — the app was busy",
                          "the busy-skip must be unreachable from an armed window")
        XCTAssertTrue(store.loadFired().contains(occ(A, "2026-06-10")), "fired by firing, not by skipping")
    }

    /// THE HALF THAT STAYS: a command genuinely holding the engine lock still defers the occurrence,
    /// and the deferral is a re-attempt, not a skip — it fires on the next tick once the lock clears.
    func testInFlightDefersThenFiresAfterClear() async {
        let (runner, engine, gated, _, pacer, _, held) = await makeBusyEngine(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1))
        runner.start()   // operative 22:00→80 due, but a command holds the lock → defer
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(gated.invocationNames.contains("Battery Limit 80"), "deferred, not fired")
        // The command completes; next tick fires.
        await releaseLock(gated, engine, held)
        gated.setGetValue("80")
        pacer.tick()
        await drain(until: engine.limit == .known(80), "fires once the command lock clears")
    }

    /// The 5-min cap (`maxDeferral` = 300 s) still converts a genuinely-busy deferral into a
    /// skip-with-note. NOTE: that note is set but structurally never rendered — see the honesty
    /// comment on the production line; this test pins the STATE, not a user-visible claim.
    func testInFlightDeferralExceedsCapSkipsWithNote() async {
        let (runner, engine, gated, clock, pacer, _, held) = await makeBusyEngine(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1))
        runner.start()
        for _ in 0..<5 { await Task.yield() }
        clock.nowValue = date(2026, 6, 10, 22, 7)   // past the 5-min cap
        pacer.tick()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(runner.note, "Scheduled change skipped — the app was busy")
        XCTAssertFalse(gated.invocationNames.contains("Battery Limit 80"))
        XCTAssertNotNil(runner.resumeTarget(),
                        "and the Resume button owns the note's only render slot, so it is never seen")
        await releaseLock(gated, engine, held)
    }

    func testUserOverrideDuringDeferralConsumesIt() async {
        // Human primacy: a deferred trigger must NOT fire over a user change made mid-deferral. The
        // deferral outlives the lock (only a fire or a limit change clears it), so the user's Set
        // lands with `deferring` still standing — exactly the state the consumption is about.
        let (runner, engine, gated, _, pacer, _, held) = await makeBusyEngine(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1))
        runner.start()                       // 22:00→80 deferred
        for _ in 0..<5 { await Task.yield() }
        await releaseLock(gated, engine, held)
        // User sets 90 while the trigger is still deferred (no tick has run).
        gated.setGetValue("90")
        _ = await engine.userSetLimit(90)
        await drain(until: engine.limit == .known(90), "the user's manual 90 lands")
        // Tick: the deferred 80 must be consumed, NOT fired over the user's 90.
        gated.setGetValue("80")
        for _ in 0..<10 { pacer.tick(); await Task.yield() }
        XCTAssertEqual(engine.limit, .known(90), "the user's value stands; the deferred 80 was consumed")
        XCTAssertFalse(gated.invocationNames.contains("Battery Limit 80"))
    }

    func testNonUserChangeDoesNotConsumeDeferral() async {
        // The == .user guard in the slimmed handleLimitChange: a NON-user change mid-deferral does NOT
        // consume the deferred trigger, so the legitimately-deferred occurrence still fires once clear.
        let (runner, engine, gated, _, pacer, _, held) = await makeBusyEngine(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1))
        runner.start()                       // 22:00→80 deferred
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(gated.invocationNames.contains("Battery Limit 80"), "deferred, not fired")
        await releaseLock(gated, engine, held)
        // A .topUp-sourced change mid-deferral must NOT consume the deferred occurrence.
        gated.setGetValue("95")
        _ = await engine.userSetLimit(95, source: .topUp)
        await drain(until: engine.limit == .known(95), "the .topUp change lands")
        // Tick: the deferred 80 STILL fires (not consumed by the non-user change).
        gated.setGetValue("80")
        for _ in 0..<10 { pacer.tick(); await Task.yield() }
        await drain(until: engine.limit == .known(80),
                    "the deferred trigger still fires; a non-user change didn't consume it")
    }

    // MARK: - audit A3/A4: awaited scheduled-Set outcome + bounded retry-then-give-up

    /// A runner that genuinely SUSPENDS one chosen Set invocation (via a continuation) so a foreign
    /// command can hold the engine's command lock deterministically while a scheduled Set races for
    /// it — the only way to drive the engine to return `.busy` to the scheduled Set.
    final class GatedShortcutRunner: ShortcutRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var conts: [CheckedContinuation<Void, Never>] = []
        private var names: [String] = []
        private var blockName: String?
        private var getValue: String
        private var sawBlocked = false
        init(getValue: String, blockSetName: String) { self.getValue = getValue; self.blockName = blockSetName }
        // Sync helpers: NSLock's lock()/unlock() are unavailable in async contexts (Swift 6).
        private func recordShouldBlock(_ name: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            names.append(name)
            let block = (name == blockName)
            if block { sawBlocked = true }
            return block
        }
        private func storeContinuation(_ c: CheckedContinuation<Void, Never>) {
            lock.lock(); conts.append(c); lock.unlock()
        }
        private func snapshotGetValue() -> String { lock.lock(); defer { lock.unlock() }; return getValue }
        var invocationNames: [String] { lock.lock(); defer { lock.unlock() }; return names }
        var blockedSetEntered: Bool { lock.lock(); defer { lock.unlock() }; return sawBlocked }
        func setGetValue(_ v: String) { lock.lock(); getValue = v; lock.unlock() }
        func release() {
            lock.lock(); let cs = conts; conts = []; blockName = nil; lock.unlock()
            cs.forEach { $0.resume() }
        }
        func run(name: String, outputPath: String?) async -> ShortcutRunOutcome {
            if recordShouldBlock(name) {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in storeContinuation(c) }
            }
            if let path = outputPath {
                try? snapshotGetValue().write(toFile: path, atomically: true, encoding: .utf8)
            }
            return .success(stdout: "")
        }
        func list() async -> ShortcutRunOutcome { .success(stdout: "") }
    }

    private func occ(_ rule: ChargeRule, _ dayKey: String) -> FiredOccurrence {
        FiredOccurrence(ruleID: rule.id, dayKey: dayKey)
    }
    private func bl80Count(_ mock: MockShortcutRunner) -> Int {
        mock.invocationNames.filter { $0 == "Battery Limit 80" }.count
    }

    func testDegradedScheduledSetIsSuccessNoRetry() async {
        // appliedUnconfirmed (write landed, read-back unavailable) is the NORMAL degraded success:
        // occurrence fired, no un-fire, no failure note. The degraded-no-infinite-retry guarantee.
        let (runner, engine, mock, _, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                       now: date(2026, 6, 10, 22, 1), baseline: 100)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""))])   // Set ok, Get unavailable
        runner.start()
        await drain(until: engine.limit == .known(80), "the degraded set lands as-set (80)")
        let occA = occ(A, "2026-06-10")
        XCTAssertTrue(store.loadFired().contains(occA), "occurrence stays fired on a degraded success")
        XCTAssertNil(runner.note, "no failure note on a degraded success")
        XCTAssertNil(runner.scheduleSetMisses[occA], "no miss recorded on success")
        let count = bl80Count(mock)
        for _ in 0..<6 { pacer.tick(); await Task.yield() }
        XCTAssertEqual(bl80Count(mock), count, "a degraded success must never retry")
        XCTAssertNil(runner.note)
    }

    func testScheduledSetIssueFailedRetriesThenGivesUp() async {
        // issueFailed with the scheduled Set still the operative command (lastCommandSource == .schedule):
        // un-fire and re-fire on subsequent ticks, then on the 3rd consecutive failure give up — stays
        // fired, sticky failure note, no further re-fire.
        let (runner, engine, mock, _, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                       now: date(2026, 6, 10, 22, 1), baseline: 100)
        let occA = occ(A, "2026-06-10")
        // A missing Set shortcut → issueFailed, NOT internally retried → exactly one invocation/attempt.
        mock.script([.init(.missingShortcut)])
        runner.start()
        await drain(until: bl80Count(mock) == 1 && !store.loadFired().contains(occA), "attempt 1 fails + un-fires")
        XCTAssertEqual(runner.scheduleSetMisses[occA], 1, "miss = 1 after the first failure")
        XCTAssertNil(runner.note, "no give-up note before the cap")
        XCTAssertEqual(engine.lastCommandSource, .schedule, "the scheduled Set is still the operative command")
        mock.script([.init(.missingShortcut)]); pacer.tick()
        await drain(until: bl80Count(mock) == 2 && !store.loadFired().contains(occA), "attempt 2 re-fires + un-fires")
        XCTAssertEqual(runner.scheduleSetMisses[occA], 2, "miss = 2 after the second failure")
        XCTAssertNil(runner.note)
        mock.script([.init(.missingShortcut)]); pacer.tick()
        await drain(until: bl80Count(mock) == 3 && store.loadFired().contains(occA) && runner.note != nil,
                    "attempt 3 gives up")
        XCTAssertNil(runner.scheduleSetMisses[occA], "miss cleared on give-up")
        XCTAssertTrue(runner.note!.contains("80"), "the give-up note names the target percent")
        mock.script([.init(.missingShortcut)])
        for _ in 0..<6 { pacer.tick(); await Task.yield() }
        XCTAssertEqual(bl80Count(mock), 3, "no re-fire after give-up")
        XCTAssertNotNil(runner.note, "the sticky give-up note persists")
    }

    func testScheduledSetMismatchSupersededNoRetry() async {
        // mismatch(observed:): the engine adopted an external value (adopt-don't-fight). Leave fired,
        // no un-fire, no re-attempt, no failure note — the external value stands.
        let (runner, engine, mock, _, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                       now: date(2026, 6, 10, 22, 1), baseline: 100)
        // Set 80 runs; read-back yields 90 twice (across the engine's single internal re-Set) → mismatch(90).
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "90"),
                     .init(.success(stdout: "")), .init(.success(stdout: ""), file: "90")])
        runner.start()
        await drain(until: engine.limit == .known(90), "the external value (90) is adopted")
        let occA = occ(A, "2026-06-10")
        XCTAssertTrue(store.loadFired().contains(occA), "occurrence stays fired on a superseded mismatch")
        XCTAssertNil(runner.scheduleSetMisses[occA], "no miss recorded on a mismatch")
        XCTAssertNil(runner.note, "no failure note on a mismatch — the external value stands")
        let count = bl80Count(mock)
        for _ in 0..<6 { pacer.tick(); await Task.yield() }
        XCTAssertEqual(bl80Count(mock), count, "a superseded mismatch must not retry")
        XCTAssertEqual(engine.limit, .known(90), "the external value still stands")
    }

    func testRetriableFailureWithForeignLockOwnerDoesNotUnfire() async {
        // A scheduled Set that comes back retriable (.busy) because a FOREIGN command holds the engine
        // lock (lastCommandSource != .schedule) must be adopted, not retried: leave fired, no un-fire,
        // no failure note. Re-firing would fight the intervening user command.
        let gated = GatedShortcutRunner(getValue: "100", blockSetName: "Battery Limit 95")
        let engine = ChargeLimitEngine(runner: gated, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)
        XCTAssertEqual(engine.limit, .known(100))
        let clock = MockScheduleClock(date(2026, 6, 10, 22, 1)); let pacer = MockPacer()
        let store = MemStore(ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: false))
        let runner = ScheduleRunner(engine: engine, store: store, clock: clock, pacer: pacer,
                                    isSetupReady: { true },
                                    calendarProvider: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c })
        let occA = occ(A, "2026-06-10")
        // A foreign user Set grabs the engine lock and BLOCKS — enqueued BEFORE the scheduled fire so it
        // wins the lock race; the scheduled Set then comes back .busy.
        let foreign = Task { @MainActor in _ = await engine.userSetLimit(95, source: .user) }
        runner.recompute(.launch)   // fire: lock is free at check-time → marks A fired, spawns the Set Task
        await drain(until: gated.blockedSetEntered, "the foreign Set holds the lock")
        for _ in 0..<10 { await Task.yield() }   // let the scheduled Set resolve to .busy + finish
        XCTAssertTrue(store.loadFired().contains(occA), "a foreign-lock .busy leaves the occurrence fired")
        XCTAssertNil(runner.scheduleSetMisses[occA], "no miss recorded — not our retry to make")
        XCTAssertNil(runner.note, "no failure note for a foreign-lock supersession")
        XCTAssertFalse(gated.invocationNames.contains("Battery Limit 80"),
                       "the scheduled Set never issued its shortcut (it was .busy)")
        XCTAssertEqual(engine.lastCommandSource, .user, "the foreign command owns the lock")
        // Cleanup: release the foreign Set; it lands 95. The occurrence stays fired (no retry).
        gated.setGetValue("95"); gated.release()
        await drain(until: engine.limit == .known(95), "the foreign command completes")
        _ = await foreign.value
        XCTAssertTrue(store.loadFired().contains(occA), "still fired after the foreign command lands")
        XCTAssertFalse(gated.invocationNames.contains("Battery Limit 80"), "still no scheduled Set issued")
    }

    func testHumanChangeMidRetryConsumesAndStopsRetry() async {
        // After a failed attempt has un-fired the occurrence (miss = 1), an explicit user limit change
        // marks the operative occurrence fired, clears its miss + the failure note, and the next tick
        // does NOT re-fire it (the manual change is not clobbered by the in-flight retry).
        let (runner, engine, mock, _, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                       now: date(2026, 6, 10, 22, 1), baseline: 100)
        let occA = occ(A, "2026-06-10")
        mock.script([.init(.missingShortcut)]); runner.start()
        await drain(until: bl80Count(mock) == 1 && !store.loadFired().contains(occA), "attempt 1 un-fires")
        XCTAssertEqual(runner.scheduleSetMisses[occA], 1)
        // The user explicitly sets 90 — mid-retry.
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "90")])
        _ = await engine.userSetLimit(90)
        await drain(until: engine.limit == .known(90), "the user's 90 lands")
        XCTAssertTrue(store.loadFired().contains(occA), "the human change consumes (fires) the operative occurrence")
        XCTAssertNil(runner.scheduleSetMisses[occA], "the retry miss is cleared by the human change")
        XCTAssertNil(runner.note, "no lingering failure note after the human change")
        let count = bl80Count(mock)
        for _ in 0..<6 { pacer.tick(); await Task.yield() }
        XCTAssertEqual(bl80Count(mock), count, "the retry stops; the manual change is not clobbered")
        XCTAssertEqual(engine.limit, .known(90), "the user's value stands")
    }

    func testResumeNowDoesNotDoubleIssueWhileBusy() async {
        // resumeNow routes through fire's `commandInFlight` guard: while a command holds the engine
        // lock it defers instead of spawning its own Set, so there is no second concurrent Set. Once
        // the lock clears, the single fire path issues exactly one Set.
        let (runner, engine, gated, _, pacer, _, held) = await makeBusyEngine(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1))
        runner.start()
        runner.resumeNow()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(gated.invocationNames.contains("Battery Limit 80"), "no Set issued while busy")
        await releaseLock(gated, engine, held)
        gated.setGetValue("80")
        pacer.tick()
        await drain(until: engine.limit == .known(80), "fires once the command lock clears")
        XCTAssertEqual(gated.invocationNames.filter { $0 == "Battery Limit 80" }.count, 1,
                       "exactly one Set — resumeNow did not double-issue")
    }

    func testStickyFailureNoteSurvivesDoNothingTickAndClearsOnSuccess() async {
        // The give-up note is STICKY: it survives a recompute whose action is .none, and clears when a
        // later scheduled Set succeeds.
        let (runner, engine, mock, clock, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                           now: date(2026, 6, 10, 22, 1), baseline: 100)
        let occA = occ(A, "2026-06-10")
        mock.script([.init(.missingShortcut)]); runner.start()
        await drain(until: bl80Count(mock) == 1 && !store.loadFired().contains(occA))
        mock.script([.init(.missingShortcut)]); pacer.tick()
        await drain(until: bl80Count(mock) == 2 && !store.loadFired().contains(occA))
        mock.script([.init(.missingShortcut)]); pacer.tick()
        await drain(until: bl80Count(mock) == 3 && runner.note != nil, "give up sets the sticky note")
        let sticky = runner.note!
        XCTAssertTrue(sticky.contains("80"))
        // A do-nothing tick (action .none, A still fired) must NOT clear the sticky note.
        pacer.tick()
        for _ in 0..<6 { await Task.yield() }
        XCTAssertEqual(runner.note, sticky, "the sticky note survives a do-nothing tick")
        // A later scheduled Set succeeds (next day's occurrence) → clears the note.
        clock.nowValue = date(2026, 6, 11, 22, 1)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        pacer.tick()
        await drain(until: engine.limit == .known(80), "the next day's scheduled set succeeds")
        XCTAssertNil(runner.note, "a later success clears the sticky failure note")
    }

    func testStickyFailureNoteClearsOnRuleEdit() async {
        let (runner, _, mock, _, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                  now: date(2026, 6, 10, 22, 1), baseline: 100)
        let occA = occ(A, "2026-06-10")
        mock.script([.init(.missingShortcut)]); runner.start()
        await drain(until: bl80Count(mock) == 1 && !store.loadFired().contains(occA))
        mock.script([.init(.missingShortcut)]); pacer.tick()
        await drain(until: bl80Count(mock) == 2 && !store.loadFired().contains(occA))
        mock.script([.init(.missingShortcut)]); pacer.tick()
        await drain(until: bl80Count(mock) == 3 && runner.note != nil)
        XCTAssertNotNil(runner.note, "give-up note is set")
        _ = runner.addRule(B)   // a config edit (mutate)
        XCTAssertNil(runner.note, "a rule edit clears the sticky failure note")
    }

    func testStickyFailureNoteClearsOnUserChange() async {
        let (runner, engine, mock, _, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                       now: date(2026, 6, 10, 22, 1), baseline: 100)
        let occA = occ(A, "2026-06-10")
        mock.script([.init(.missingShortcut)]); runner.start()
        await drain(until: bl80Count(mock) == 1 && !store.loadFired().contains(occA))
        mock.script([.init(.missingShortcut)]); pacer.tick()
        await drain(until: bl80Count(mock) == 2 && !store.loadFired().contains(occA))
        mock.script([.init(.missingShortcut)]); pacer.tick()
        await drain(until: bl80Count(mock) == 3 && runner.note != nil)
        XCTAssertNotNil(runner.note)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "90")])
        _ = await engine.userSetLimit(90)
        await drain(until: engine.limit == .known(90))
        XCTAssertNil(runner.note, "a user change clears the sticky failure note")
    }

    func testBusyDeferralReattemptsWhenBusyClears() async {
        // Documents that the busy-deferral path is NOT a permanent skip: a trigger deferred while a
        // command holds the engine lock fires on the next tick once that lock clears (before the cap).
        let (runner, engine, gated, _, pacer, store, held) = await makeBusyEngine(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1))
        runner.start()
        for _ in 0..<6 { await Task.yield() }
        XCTAssertFalse(gated.invocationNames.contains("Battery Limit 80"), "deferred, not fired")
        XCTAssertFalse(store.loadFired().contains(occ(A, "2026-06-10")), "not consumed while merely deferred")
        await releaseLock(gated, engine, held)
        gated.setGetValue("80")
        pacer.tick()
        await drain(until: engine.limit == .known(80), "the deferred trigger re-attempts once busy clears")
        XCTAssertNil(runner.note, "a re-attempt that succeeds leaves no skip note")
    }

    func testSupersededOccurrenceMissClearedOnPrune() async {
        // A miss entry keys an UN-FIRED occurrence the fired-prune does not touch; pruneFired must drop
        // miss entries older than the prune horizon so the map can't leak.
        let (runner, engine, mock, clock, pacer, store) = await makeRunner(rules: [A], enabled: true,
                                                                           now: date(2026, 6, 10, 22, 1), baseline: 100)
        let occOld = occ(A, "2026-06-10")
        mock.script([.init(.missingShortcut)]); runner.start()
        await drain(until: bl80Count(mock) == 1 && !store.loadFired().contains(occOld))
        XCTAssertEqual(runner.scheduleSetMisses[occOld], 1, "miss recorded for the un-fired occurrence")
        // Jump well past the 2-day prune horizon; the next recompute prunes, then a fresh fire succeeds.
        clock.nowValue = date(2026, 6, 13, 0, 30)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        pacer.tick()
        await drain(until: engine.limit == .known(80), "the fresh occurrence fires and prune runs")
        XCTAssertNil(runner.scheduleSetMisses[occOld], "the stale miss for the old occurrence is pruned")
    }

    func testUserChangeDoesNotClearValidNonStickyNote() async {
        // Regression (audit obs 1): an explicit user/intent limit change must clear ONLY the sticky
        // scheduled-failure note. A valid NON-sticky note (here the setup-required note) must SURVIVE
        // the change — handleLimitChange has no immediate recompute to restore it (unlike resumeNow /
        // mutate), so an unconditional clear would blank a still-true note for up to one tick.
        let (runner, engine, mock, _, _, _) = await makeRunner(rules: [A], enabled: true,
                                                               now: date(2026, 6, 10, 22, 1), baseline: 100,
                                                               setupReady: false)
        runner.start()   // setup not ready → a non-sticky "setup required" note is shown, no fire
        let before = runner.note
        XCTAssertNotNil(before, "precondition: a non-sticky note is showing")
        // An explicit user change settles; the valid non-sticky note must be UNCHANGED.
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "90")])
        _ = await engine.userSetLimit(90)
        await drain(until: engine.limit == .known(90))
        XCTAssertEqual(runner.note, before, "a user change must not blank a valid non-sticky note")
    }

    // MARK: - B-arc B3: the pacer earns its wakes (start/stop lifecycle)

    /// The default user has the feature off. The 30 s timer must never start — that is the whole saving.
    func testPacerDoesNotStartWhenScheduleDisabled() async {
        let (runner, _, _, _, pacer, _) = await makeRunner(rules: [A], enabled: false,
                                                           now: date(2026, 6, 10, 22, 1), baseline: 100)
        runner.start()
        XCTAssertFalse(pacer.isRunning, "schedule off → no pacer")
        XCTAssertEqual(pacer.startCount, 0)
    }

    /// Enabled but with nothing to fire is equally inert — `recompute` would find no rule to act on.
    func testPacerDoesNotStartWhenEnabledButNoRules() async {
        let (runner, _, _, _, pacer, _) = await makeRunner(rules: [], enabled: true,
                                                           now: date(2026, 6, 10, 22, 1), baseline: 100)
        runner.start()
        XCTAssertFalse(pacer.isRunning, "enabled with zero rules → nothing a tick could do")
    }

    func testPacerStartsWhenEnabledWithRules() async {
        let (runner, _, _, _, pacer, _) = await makeRunner(rules: [A], enabled: true,
                                                           now: date(2026, 6, 10, 21, 0), baseline: 100)
        runner.start()
        XCTAssertTrue(pacer.isRunning, "a live schedule pays for its pacer")
        XCTAssertEqual(pacer.startCount, 1)
    }

    /// The config edges, in both directions, through the real `mutate` hooks.
    func testPacerFollowsEnableDisableAndRuleEmptying() async {
        let (runner, _, _, _, pacer, _) = await makeRunner(rules: [A], enabled: true,
                                                           now: date(2026, 6, 10, 21, 0), baseline: 100)
        runner.start()
        XCTAssertTrue(pacer.isRunning)

        runner.setEnabled(false)
        XCTAssertFalse(pacer.isRunning, "disabling stops the pacer")
        runner.setEnabled(true)
        XCTAssertTrue(pacer.isRunning, "re-enabling starts it again")
        XCTAssertEqual(pacer.startCount, 2)

        runner.removeRule(id: A.id)
        XCTAssertFalse(pacer.isRunning, "emptying the rules stops it")
        XCTAssertTrue(runner.addRule(A))
        XCTAssertTrue(pacer.isRunning, "adding a rule back starts it")

        runner.stop()
        XCTAssertFalse(pacer.isRunning, "an explicit stop always wins")
    }

    /// EDGE-triggered: `LiveSchedulePacer.start` re-creates its timer, so re-starting an already-running
    /// pacer would reset the interval. A burst of edits that leave the schedule live must not touch it —
    /// otherwise rapid rule editing could starve the tick indefinitely.
    func testPacerIsNotRestartedByEditsThatKeepItRunning() async {
        let (runner, _, _, _, pacer, _) = await makeRunner(rules: [A], enabled: true,
                                                           now: date(2026, 6, 10, 21, 0), baseline: 100)
        runner.start()
        XCTAssertEqual(pacer.startCount, 1)
        XCTAssertTrue(runner.addRule(B))
        runner.markPresetOffered()
        runner.setEnabled(true)                      // already enabled — a no-op transition
        XCTAssertTrue(pacer.isRunning)
        XCTAssertEqual(pacer.startCount, 1, "still the ONE start — the timer was never reset")
    }

    /// Disabling MID-DEFERRAL stops the pacer. Safe because `recompute` early-returns on a disabled
    /// config anyway, so the ticks it would have served were already no-ops: the deferred occurrence
    /// stays unfired and un-consumed, and re-enabling restores both the pacer and the retry path.
    func testDisableMidDeferralStopsPacerAndLeavesTheOccurrenceUnfired() async {
        let (runner, engine, gated, _, pacer, store, held) = await makeBusyEngine(
            rules: [A], enabled: true, now: date(2026, 6, 10, 22, 1))
        // The app is genuinely busy (a command holds the lock) → the due 22:00→80 defers.
        runner.start()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(pacer.isRunning)
        XCTAssertFalse(store.loadFired().contains(occ(A, "2026-06-10")), "deferred, not fired")

        runner.setEnabled(false)
        XCTAssertFalse(pacer.isRunning, "no pacer while disabled — recompute would early-return anyway")
        XCTAssertFalse(store.loadFired().contains(occ(A, "2026-06-10")),
                       "disabling neither fires nor consumes the deferred occurrence")

        await releaseLock(gated, engine, held)
        gated.setGetValue("80")
        runner.setEnabled(true)
        XCTAssertTrue(pacer.isRunning, "re-enabling restores the retry path")
        await drain(until: store.loadFired().contains(occ(A, "2026-06-10")),
                    "the re-enable recompute fires the still-due occurrence")
    }

    // MARK: - SWEEP H4: a corrupt persisted read is not an empty one

    /// A store whose two reads can be made to answer `.corrupt` — the state `MemStore` (an in-memory
    /// double with no decode step) can never reach. Everything else behaves like `MemStore`.
    ///
    /// RED-FIRST RECORD: before the fix, `ScheduleStoring` had no `loadConfigDetailed` /
    /// `loadFiredDetailed` at all, so this double could not be written and none of the tests below
    /// could COMPILE. That is the point: the old API had no vocabulary in which "the bytes would not
    /// decode" could be distinguished from "nothing was ever stored", so no assertion over it could
    /// have caught the defect.
    final class CorruptibleStore: ScheduleStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var c: ChargeScheduleConfig
        private var f: Set<FiredOccurrence>
        private let configCorrupt: Bool
        private var firedCorrupt: Bool
        /// Every `saveFired` the runner performed, in order — proves the corrupt blob is replaced.
        private(set) var firedWrites: [Set<FiredOccurrence>] = []

        init(_ c: ChargeScheduleConfig, fired: Set<FiredOccurrence> = [],
             configCorrupt: Bool = false, firedCorrupt: Bool = false) {
            self.c = c; self.f = fired
            self.configCorrupt = configCorrupt; self.firedCorrupt = firedCorrupt
        }
        func loadConfig() -> ChargeScheduleConfig { lock.lock(); defer { lock.unlock() }; return c }
        func saveConfig(_ x: ChargeScheduleConfig) { lock.lock(); c = x; lock.unlock() }
        func loadFired() -> Set<FiredOccurrence> { lock.lock(); defer { lock.unlock() }; return f }
        func saveFired(_ x: Set<FiredOccurrence>) {
            lock.lock(); f = x; firedCorrupt = false; firedWrites.append(x); lock.unlock()
        }
        func loadConfigDetailed() -> ScheduleConfigLoad {
            lock.lock(); defer { lock.unlock() }
            return configCorrupt ? .corrupt : .config(c)
        }
        func loadFiredDetailed() -> FiredSetLoad {
            lock.lock(); defer { lock.unlock() }
            return firedCorrupt ? .corrupt : .fired(f)
        }
    }

    /// `makeRunner`, with the store injected so its reads can be made to fail.
    private func makeRunner(store: CorruptibleStore, now: Date, baseline: Int)
    async -> (ScheduleRunner, ChargeLimitEngine, MockShortcutRunner, MockScheduleClock, MockPacer) {
        let mockRunner = MockShortcutRunner([.init(.success(stdout: ""), file: String(baseline))])
        let engine = ChargeLimitEngine(runner: mockRunner, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)
        let clock = MockScheduleClock(now); let pacer = MockPacer()
        let runner = ScheduleRunner(engine: engine, store: store, clock: clock, pacer: pacer,
                                    isSetupReady: { true },
                                    calendarProvider: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c })
        return (runner, engine, mockRunner, clock, pacer)
    }

    /// THE H4 DEFECT, stated as behaviour. The world: 22:00 fired 80, the user then deliberately set
    /// 100, and the fired-set is what holds that manual change (4g thermostat-hold). If the record
    /// reads as EMPTY, the operative occurrence looks un-fired, the limit diverges from its dictate,
    /// and the runner re-asserts 80 over the user — an autonomous Set clobbering an explicit human
    /// decision. That is not "one duplicate": it is the human-primacy mechanism failing open.
    func testCorruptFiredRecordDoesNotRefireOverAManualChange() async {
        let store = CorruptibleStore(ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true),
                                     firedCorrupt: true)
        let (runner, _, mock, _, pacer) = await makeRunner(store: store, now: date(2026, 6, 10, 22, 1),
                                                           baseline: 100)
        runner.start()
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<5 { pacer.tick(); await Task.yield() }
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"),
                       "an unreadable fired-set must bias toward NOT firing: firing is autonomous and "
                       + "physical, not firing is inert and self-heals at the next occurrence")
        XCTAssertTrue(runner.firedRecordUnreadable)
    }

    /// The control: the SAME world with a legitimately empty fired-set DOES fire. Corrupt and empty
    /// are distinguishable at the behavioural level, not merely in the type.
    func testTheLegitimateEmptyFiredRecordStillFires() async {
        let store = CorruptibleStore(ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true))
        let (runner, engine, mock, _, _) = await makeRunner(store: store, now: date(2026, 6, 10, 22, 1),
                                                            baseline: 100)
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "80")])
        runner.start()
        await drain(until: engine.limit == .known(80), "an empty fired-set is not a corrupt one")
        XCTAssertFalse(runner.firedRecordUnreadable)
    }

    /// Rule 4, discharged without a new screen: the suppression is exactly co-extensive with the
    /// EXISTING "Resume schedule (N% now)" affordance — both key off `limit != operative.rule.limit`.
    /// So the one reassertion this withholds is always on screen, one tap away.
    func testCorruptFiredRecordAlwaysLeavesTheResumeAffordanceOnScreen() async {
        let store = CorruptibleStore(ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true),
                                     firedCorrupt: true)
        let (runner, _, _, _, _) = await makeRunner(store: store, now: date(2026, 6, 10, 22, 1),
                                                    baseline: 100)
        runner.start()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(runner.resumeTarget(), 80,
                       "the withheld reassertion must be offered back, not silently dropped")
    }

    /// The other half of that invariant: when the limit ALREADY matches the dictate there is nothing
    /// to offer — and nothing was going to fire either, so nothing is hidden.
    func testCorruptFiredRecordHidesNothingWhenTheLimitAlreadyMatches() async {
        let store = CorruptibleStore(ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true),
                                     firedCorrupt: true)
        let (runner, _, mock, _, _) = await makeRunner(store: store, now: date(2026, 6, 10, 22, 1),
                                                       baseline: 80)
        runner.start()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(runner.resumeTarget())
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"))
    }

    /// One-shot and self-healing: the undecodable blob is replaced with a decodable one that names
    /// the presumed-fired occurrence, so the next launch reads a normal record.
    func testCorruptFiredRecordIsReplacedWithADecodableOne() async {
        let store = CorruptibleStore(ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true),
                                     firedCorrupt: true)
        _ = await makeRunner(store: store, now: date(2026, 6, 10, 22, 1), baseline: 100)
        XCTAssertEqual(store.loadFiredDetailed(), .fired([occ(A, "2026-06-10")]),
                       "the operative occurrence is marked presumed-fired and persisted")
        XCTAssertEqual(store.firedWrites.count, 1, "exactly one repair write, at construction")
    }

    /// The suppression covers ONLY the occurrence whose record was lost. Every LATER occurrence
    /// fires normally — which is why not-firing costs at most one reassertion.
    func testTheNextOccurrenceStillFiresAfterACorruptFiredRecord() async {
        let store = CorruptibleStore(ChargeScheduleConfig(enabled: true, rules: [A, B], presetOffered: true),
                                     firedCorrupt: true)
        let (runner, engine, mock, clock, pacer) = await makeRunner(store: store,
                                                                    now: date(2026, 6, 10, 22, 1),
                                                                    baseline: 90)
        runner.start()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"), "A is presumed-fired")

        clock.nowValue = date(2026, 6, 11, 7, 31)          // B's occurrence, a record we never lost
        mock.script([.init(.success(stdout: "")), .init(.success(stdout: ""), file: "100")])
        pacer.tick()
        await drain(until: engine.limit == .known(100), "the NEXT occurrence must fire normally")
    }

    /// A corrupt fired-set on a config with no operative occurrence (disabled / no rules) still
    /// replaces the blob, and invents nothing.
    func testCorruptFiredRecordWithNoOperativeOccurrenceJustRepairsTheBlob() async {
        let store = CorruptibleStore(ChargeScheduleConfig(enabled: false, rules: [], presetOffered: true),
                                     firedCorrupt: true)
        _ = await makeRunner(store: store, now: date(2026, 6, 10, 22, 1), baseline: 100)
        XCTAssertEqual(store.loadFiredDetailed(), .fired([]))
    }

    /// THE FINDING THE SWEEP MISSED: the same generic decoder backs `loadConfig`, where the collapse
    /// value is `.empty` — `enabled == false`, `presetOffered == false`. An unreadable config
    /// therefore presents as "the user never set up a schedule". The behaviour is already the safe
    /// one (an unreadable schedule must not run autonomous Sets), but the CLAIM is manufactured, so
    /// the state is now modelled and observable. Its screen is still owed (see `configUnreadable`).
    func testCorruptConfigIsDistinguishableFromNoConfig() async {
        let corrupt = CorruptibleStore(.empty, configCorrupt: true)
        let (r1, _, _, _, _) = await makeRunner(store: corrupt, now: date(2026, 6, 10, 22, 1), baseline: 100)
        XCTAssertTrue(r1.configUnreadable)
        XCTAssertEqual(r1.config, .empty, "we still have nothing to run on — but we no longer pretend we know that")

        let firstRun = CorruptibleStore(.empty)
        let (r2, _, _, _, _) = await makeRunner(store: firstRun, now: date(2026, 6, 10, 22, 1), baseline: 100)
        XCTAssertFalse(r2.configUnreadable, "a genuine first run is not a corrupt read")
    }

    /// REVERSED by redman sweep item 1 (was `testAuthoringAConfigClearsTheUnreadableState`, which
    /// asserted that an edit saves over the unreadable blob and clears the state — the data-loss path
    /// itself). A deliberate edit now first moves the unreadable bytes ASIDE (final review F1); this double
    /// cannot set anything aside (`CorruptibleStore` inherits the no-op), so it pins the fallback: when the
    /// set-aside does not take, the edit is still REFUSED. Real-bytes coverage of the set-aside itself:
    /// `ScheduleConfigUnreadableTests`.
    func testAnEditIsRefusedWhenTheUnreadableConfigCannotBeSetAside() async {
        let corrupt = CorruptibleStore(.empty, configCorrupt: true)
        let (runner, _, _, _, _) = await makeRunner(store: corrupt, now: date(2026, 6, 10, 22, 1), baseline: 100)
        runner.start()
        XCTAssertTrue(runner.configUnreadable)
        runner.setEnabled(true)
        XCTAssertTrue(runner.configUnreadable, "an edit does not make the stored config readable")
        XCTAssertFalse(runner.config.enabled, "and it did not take effect")
    }

    /// The REAL store over REAL bytes — a double with no decode step could never prove the `try?` was
    /// the defect. Both keys, both directions.
    func testUserDefaultsScheduleStoreSeparatesCorruptFromEmptyOnBothKeys() {
        let suite = "ScheduleRunnerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsScheduleStore(suiteName: suite)

        XCTAssertEqual(store.loadConfigDetailed(), .none)
        XCTAssertEqual(store.loadFiredDetailed(), .none)

        let cfg = ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true)
        store.saveConfig(cfg)
        store.saveFired([occ(A, "2026-06-10")])
        XCTAssertEqual(store.loadConfigDetailed(), .config(cfg))
        XCTAssertEqual(store.loadFiredDetailed(), .fired([occ(A, "2026-06-10")]))

        defaults.set(Data("{\"enabled\":".utf8), forKey: "chargeSchedule.config.v1")
        defaults.set(Data("[{\"ruleID\":".utf8), forKey: "chargeSchedule.fired.v1")
        XCTAssertEqual(store.loadConfigDetailed(), .corrupt)
        XCTAssertEqual(store.loadFiredDetailed(), .corrupt)
        XCTAssertNotEqual(store.loadConfigDetailed(), ScheduleConfigLoad.none)
        XCTAssertNotEqual(store.loadFiredDetailed(), FiredSetLoad.none)

        // And the preserved call shapes still collapse, byte-identically to before.
        XCTAssertEqual(store.loadConfig(), .empty)
        XCTAssertEqual(store.loadFired(), [])
    }
}
