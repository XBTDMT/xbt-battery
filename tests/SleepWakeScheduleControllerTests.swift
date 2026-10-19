import XCTest
import Shared

/// Sprint 3.7 (sleep/wake) STAGE 2b: the app-side controller. Host-app-free (the app source compiles
/// into the test target). Covers the should-fix-5 apply/cancel gates (pure), the edit setters and the
/// day-bit toggle, and that apply/cancel ENFORCE their gate and map the helper reply. The live pmset
/// read (LivePmsetScheduleReader) spawns a real subprocess and is exercised on-device, not here; the
/// controller's handling of a nil (failed / unverifiable) read-back is pinned through the gates.
@MainActor
final class SleepWakeScheduleControllerTests: XCTestCase {

    // MARK: - fakes

    final class FakeReader: SleepScheduleReading {
        let result: RepeatingSchedule?
        init(_ r: RepeatingSchedule?) { result = r }
        func readRepeatingSchedule() -> RepeatingSchedule? { result }
    }

    final class FakeStore: SleepWakeScheduleStoring {
        var saved: SleepWakeScheduleConfig = .empty
        /// H3. When set, this is what the store reports on load — the only way to express the
        /// `.unreadable` third state, which a `SleepWakeScheduleConfig`-typed field cannot.
        var detailed: SleepWakeConfigLoad?
        func loadConfigDetailed() -> SleepWakeConfigLoad { detailed ?? .config(saved) }
        func loadConfig() -> SleepWakeScheduleConfig { loadConfigDetailed().configOrEmpty }
        func saveConfig(_ c: SleepWakeScheduleConfig) { saved = c; detailed = .config(c) }
        /// Models the real store's set-aside (final review F5 re-reads after it): the unreadable bytes
        /// move off the live key, which then reads as nothing stored.
        func setAsideUnreadableConfig() { if detailed == .unreadable { detailed = SleepWakeConfigLoad.none } }
    }

    @MainActor
    final class FakeSetter: SleepWakeSetter {
        private(set) var callCount = 0
        private(set) var last: (sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                                wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int)?
        var cannedResult: Result<String, HelperClientError> = .success("ok")
        func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                                   wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int,
                                   completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
            callCount += 1
            last = (sleepEnabled, sleepHour, sleepMinute, wakeEnabled, wakeHour, wakeMinute, weekdayMask)
            completion(cannedResult)   // synchronous: the test is @MainActor, so assumeIsolated runs inline
        }
    }

    /// A setter that HOLDS its completion so a call can be observed while still in flight (the
    /// synchronous FakeSetter above can never be in flight from the test's point of view).
    @MainActor
    final class DeferredSetter: SleepWakeSetter {
        private(set) var callCount = 0
        private var pending: [(Result<String, HelperClientError>) -> Void] = []
        var isPending: Bool { !pending.isEmpty }
        func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                                   wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int,
                                   completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
            callCount += 1
            pending.append(completion)
        }
        /// Land every outstanding reply with the same result.
        func completeAll(_ r: Result<String, HelperClientError>) {
            let outstanding = pending
            pending = []
            for reply in outstanding { reply(r) }
        }
    }

    // MARK: - helpers + fixtures

    private func makeController(reader: RepeatingSchedule?, setter: FakeSetter = FakeSetter(),
                                store: FakeStore = FakeStore()) -> SleepWakeScheduleController {
        SleepWakeScheduleController(setter: setter, reader: FakeReader(reader), store: store)
    }

    private func configureBoth(_ c: SleepWakeScheduleController) {
        c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
        c.setWakeEnabled(true);  c.setWakeTime(hour: 7, minute: 0); c.setWeekdayMask(31)
    }

    private var oursReadback: RepeatingSchedule {
        SleepWakeReadback.parse("""
        Repeating power events:
          sleep at 11:30PM weekdays only
          wakepoweron at 7:00AM weekdays only
        """)
    }
    private var foreignReadback: RepeatingSchedule {
        SleepWakeReadback.parse("Repeating power events:\n  sleep at 9:00AM every day")
    }

    // MARK: - applyDecision (should-fix 5 apply gate, pure)

    func testApplyDecision_matrix() {
        let c = makeController(reader: nil)
        configureBoth(c)
        XCTAssertEqual(c.applyDecision(for: oursReadback), .ready, "the live schedule is ours")
        XCTAssertEqual(c.applyDecision(for: foreignReadback), .needsConfirm, "a foreign schedule must confirm")
        XCTAssertEqual(c.applyDecision(for: RepeatingSchedule(events: [])), .ready, "empty system: nothing to clobber")
        XCTAssertEqual(c.applyDecision(for: nil), .needsConfirm, "a failed/absent read cannot be verified")
        c.setWakeTime(hour: 23, minute: 30)   // both sides identical → invalid
        XCTAssertEqual(c.applyDecision(for: oursReadback), .blocked, "an invalid config blocks")
    }

    // MARK: - cancelNeedsConfirm (should-fix 5 cancel gate, pure)

    func testCancelNeedsConfirm_matrix() {
        let c = makeController(reader: nil)
        configureBoth(c)
        XCTAssertTrue(c.cancelNeedsConfirm(for: foreignReadback), "cancelling a foreign schedule must confirm")
        XCTAssertFalse(c.cancelNeedsConfirm(for: oursReadback), "cancelling our own schedule is free")
        XCTAssertFalse(c.cancelNeedsConfirm(for: RepeatingSchedule(events: [])), "nothing scheduled: free")
        XCTAssertTrue(c.cancelNeedsConfirm(for: nil), "an unverifiable read must confirm")
    }

    // MARK: - edit setters persist; the day toggle flips the right bit

    func testEditSettersMutateAndPersist() {
        let store = FakeStore()
        let c = makeController(reader: nil, store: store)
        c.setSleepEnabled(true); c.setSleepTime(hour: 22, minute: 15)
        XCTAssertTrue(c.config.sleepEnabled)
        XCTAssertEqual(c.config.sleepHour, 22); XCTAssertEqual(c.config.sleepMinute, 15)
        XCTAssertEqual(store.saved.sleepHour, 22, "every edit is persisted")
    }

    func testToggleWeekdayFlipsTheBit() {
        let c = makeController(reader: nil)
        c.setWeekdayMask(0)
        c.toggleWeekday(bit: 0)
        XCTAssertEqual(c.config.weekdayMask, 0b0000001, "Mon set")
        c.toggleWeekday(bit: 6)
        XCTAssertEqual(c.config.weekdayMask, 0b1000001, "Sun added")
        c.toggleWeekday(bit: 0)
        XCTAssertEqual(c.config.weekdayMask, 0b1000000, "Mon cleared")
        c.toggleWeekday(bit: 9)
        XCTAssertEqual(c.config.weekdayMask, 0b1000000, "out of range is a no-op")
    }

    // MARK: - apply ENFORCES the gate + maps the reply

    func testApply_unconfirmed_isNoOp() {
        let setter = FakeSetter()
        let c = makeController(reader: nil, setter: setter)   // lastReadback nil → needsConfirm
        configureBoth(c)
        c.apply(confirmed: false)
        XCTAssertEqual(setter.callCount, 0, "an unconfirmed unverifiable apply must not call the helper")
    }

    func testApply_confirmed_callsSetterWithConfigAndAppliesStatus() {
        let setter = FakeSetter()
        setter.cannedResult = .success("ok")
        let c = makeController(reader: foreignReadback, setter: setter)
        configureBoth(c)
        c.apply(confirmed: true)
        XCTAssertEqual(setter.callCount, 1)
        XCTAssertEqual(setter.last?.sleepEnabled, true)
        XCTAssertEqual(setter.last?.sleepHour, 23); XCTAssertEqual(setter.last?.sleepMinute, 30)
        XCTAssertEqual(setter.last?.wakeHour, 7);   XCTAssertEqual(setter.last?.weekdayMask, 31)
        XCTAssertEqual(c.lastApplyStatus, .applied, "a success reply sets .applied")
    }

    func testApply_helperError_mapsToFailed() {
        let setter = FakeSetter()
        setter.cannedResult = .failure(.helperError("error:set_failed"))
        let c = makeController(reader: RepeatingSchedule(events: []), setter: setter)
        configureBoth(c)
        c.apply(confirmed: true)
        XCTAssertEqual(c.lastApplyStatus, .failed("error:set_failed"))
    }

    // MARK: - cancel ENFORCES the gate + disables the config

    func testCancel_unconfirmed_isNoOp() {
        let setter = FakeSetter()
        let c = makeController(reader: nil, setter: setter)   // nil read-back → cancel needs confirm
        configureBoth(c)
        c.cancel(confirmed: false)
        XCTAssertEqual(setter.callCount, 0, "an unconfirmed cancel over an unverifiable schedule must not call the helper")
        XCTAssertTrue(c.config.sleepEnabled, "the config is untouched when the cancel is gated")
    }

    func testCancel_confirmed_disablesConfigAndCallsCancel() {
        let setter = FakeSetter()
        let c = makeController(reader: foreignReadback, setter: setter)
        configureBoth(c)
        c.cancel(confirmed: true)
        XCTAssertEqual(setter.callCount, 1)
        XCTAssertEqual(setter.last?.sleepEnabled, false)
        XCTAssertEqual(setter.last?.wakeEnabled, false, "an all-disabled call is the cancel (pmset repeat cancel)")
        XCTAssertFalse(c.config.sleepEnabled, "the persisted config reflects off")
        XCTAssertFalse(c.config.wakeEnabled)
    }

    func testCancel_failure_leavesConfigEnabled() {
        let setter = FakeSetter()
        setter.cannedResult = .failure(.unreachable)
        let c = makeController(reader: foreignReadback, setter: setter)
        configureBoth(c)
        c.cancel(confirmed: true)
        XCTAssertEqual(setter.callCount, 1, "the cancel call is still attempted")
        XCTAssertEqual(c.lastApplyStatus, .unreachable, "an unreachable reply is surfaced")
        XCTAssertTrue(c.config.sleepEnabled, "a failed cancel must NOT disable the config (the schedule is still live)")
        XCTAssertTrue(c.config.wakeEnabled)
    }

    // MARK: - B8 (a): the in-flight guard — overlapping applies never reach the helper twice
    //
    // Without it a double-click submits twice inside the helper's 250 ms cooldown; the second is
    // rejected and (before B8 (b)) its reply overwrote the first's `.applied` with a failure.

    func testApply_whileInFlight_secondCallIsRejectedByTheGuard() {
        let setter = DeferredSetter()
        let c = SleepWakeScheduleController(setter: setter, reader: FakeReader(RepeatingSchedule(events: [])),
                                            store: FakeStore())
        configureBoth(c)
        c.apply(confirmed: true)
        XCTAssertEqual(setter.callCount, 1)
        XCTAssertTrue(c.isApplyInFlight, "the first apply is outstanding")

        c.apply(confirmed: true)
        c.apply(confirmed: true)
        XCTAssertEqual(setter.callCount, 1, "an apply in flight must swallow every further apply")

        setter.completeAll(.success("ok"))
        XCTAssertFalse(c.isApplyInFlight, "the reply clears the gate")
        XCTAssertEqual(c.lastApplyStatus, .applied)

        c.apply(confirmed: true)
        XCTAssertEqual(setter.callCount, 2, "once the reply lands, a new apply is allowed through")
    }

    func testCancel_whileApplyInFlight_isRejectedByTheSameGuard() {
        let setter = DeferredSetter()
        let store = FakeStore()
        let c = SleepWakeScheduleController(setter: setter, reader: FakeReader(RepeatingSchedule(events: [])),
                                            store: store)
        configureBoth(c)
        c.apply(confirmed: true)
        XCTAssertEqual(setter.callCount, 1)

        c.cancel(confirmed: true)
        XCTAssertEqual(setter.callCount, 1, "apply and cancel share one gate — one privileged op at a time")
        XCTAssertTrue(c.config.sleepEnabled, "the swallowed cancel must not touch the config")

        setter.completeAll(.success("ok"))
        c.cancel(confirmed: true)
        XCTAssertEqual(setter.callCount, 2, "with the gate released the cancel goes through")
        setter.completeAll(.success("ok"))
        XCTAssertFalse(c.config.sleepEnabled, "the cancel that DID run disables the config on its success reply")
        XCTAssertFalse(c.config.wakeEnabled)
    }

    func testApply_whileInFlight_leavesTheAuthoredComparisonUntouched() {
        let setter = DeferredSetter()
        let c = SleepWakeScheduleController(setter: setter, reader: FakeReader(nil), store: FakeStore())
        configureBoth(c)
        c.apply(confirmed: true)
        // The gate is a submission guard only: the should-fix-5 decisions stay pure functions of
        // (config, read-back) and are unchanged by an apply being in flight.
        XCTAssertEqual(c.applyDecision(for: oursReadback), .ready)
        XCTAssertEqual(c.applyDecision(for: foreignReadback), .needsConfirm)
        XCTAssertEqual(c.applyDecision(for: nil), .needsConfirm)
        XCTAssertTrue(c.cancelNeedsConfirm(for: foreignReadback))
        XCTAssertFalse(c.cancelNeedsConfirm(for: oursReadback))
    }

    // MARK: - B8 (b): error:cooldown means "no change by THIS call", not "the operation failed"

    func testCooldownToken_isClassifiedAsANoChangeRejection() {
        XCTAssertTrue(SleepWakeReply.isNoChangeRejection(SleepWakeCommand.errCooldown))
        XCTAssertEqual(SleepWakeCommand.errCooldown, "error:cooldown", "the token the helper actually replies")
        for real in [SleepWakeCommand.errSetFailed, SleepWakeCommand.errInvalidTime,
                     SleepWakeCommand.errInvalidDays, SleepWakeCommand.errSleepEqualsWake] {
            XCTAssertFalse(SleepWakeReply.isNoChangeRejection(real), "\(real) is a real failure")
        }
    }

    func testApply_cooldownRejection_doesNotOverwriteTheSuccessItRacedWith() {
        let setter = FakeSetter()
        let c = makeController(reader: RepeatingSchedule(events: []), setter: setter)
        configureBoth(c)
        c.apply(confirmed: true)
        XCTAssertEqual(c.lastApplyStatus, .applied, "the first apply really applied")

        setter.cannedResult = .failure(.helperError(SleepWakeCommand.errCooldown))
        c.apply(confirmed: true)   // the double-click: reaches the helper, is refused inside the cooldown
        XCTAssertEqual(setter.callCount, 2)
        XCTAssertEqual(c.lastApplyStatus, .applied,
                       "a cooldown rejection changed nothing, so the applied outcome must stand — the user "
                       + "must NOT be told the schedule failed when it applied")
        XCTAssertNotEqual(c.lastApplyStatus, .failed(SleepWakeCommand.errCooldown))
    }

    func testApply_cooldownRejection_fromIdle_staysIdle() {
        let setter = FakeSetter()
        setter.cannedResult = .failure(.helperError(SleepWakeCommand.errCooldown))
        let c = makeController(reader: RepeatingSchedule(events: []), setter: setter)
        configureBoth(c)
        c.apply(confirmed: true)   // e.g. collided with a wake-behaviour apply on the SHARED helper clock
        XCTAssertEqual(c.lastApplyStatus, .idle, "nothing was applied and nothing failed")
        XCTAssertFalse(c.isApplyInFlight, "the gate is released either way")
    }

    func testCancel_cooldownRejection_neitherFailsNorDisablesTheConfig() {
        let setter = FakeSetter()
        setter.cannedResult = .failure(.helperError(SleepWakeCommand.errCooldown))
        let c = makeController(reader: foreignReadback, setter: setter)
        configureBoth(c)
        c.cancel(confirmed: true)
        XCTAssertEqual(setter.callCount, 1)
        XCTAssertEqual(c.lastApplyStatus, .idle, "a refused cancel is not a failed cancel")
        XCTAssertTrue(c.config.sleepEnabled, "nothing was cleared, so the config must still say enabled")
        XCTAssertTrue(c.config.wakeEnabled)
    }

    func testRealHelperErrorsStillPresentAsFailures() {
        for token in [SleepWakeCommand.errSetFailed, SleepWakeCommand.errInvalidTime,
                      SleepWakeCommand.errInvalidDays, SleepWakeCommand.errSleepEqualsWake] {
            let setter = FakeSetter()
            setter.cannedResult = .failure(.helperError(token))
            let c = makeController(reader: RepeatingSchedule(events: []), setter: setter)
            configureBoth(c)
            c.apply(confirmed: true)
            XCTAssertEqual(c.lastApplyStatus, .failed(token), "\(token) must still surface as a failure")
        }
        let unreachable = FakeSetter()
        unreachable.cannedResult = .failure(.unreachable)
        let c = makeController(reader: RepeatingSchedule(events: []), setter: unreachable)
        configureBoth(c)
        c.apply(confirmed: true)
        XCTAssertEqual(c.lastApplyStatus, .unreachable, "an unreachable helper still surfaces")
    }

    func testFailure_thenCooldownRejection_keepsTheRealFailureVisible() {
        let setter = FakeSetter()
        setter.cannedResult = .failure(.helperError(SleepWakeCommand.errSetFailed))
        let c = makeController(reader: RepeatingSchedule(events: []), setter: setter)
        configureBoth(c)
        c.apply(confirmed: true)
        XCTAssertEqual(c.lastApplyStatus, .failed(SleepWakeCommand.errSetFailed))

        setter.cannedResult = .failure(.helperError(SleepWakeCommand.errCooldown))
        c.apply(confirmed: true)
        XCTAssertEqual(c.lastApplyStatus, .failed(SleepWakeCommand.errSetFailed),
                       "a call that changed nothing must not erase the last real outcome either")
    }
}

// MARK: - hand-off 4: say WHY the destructive confirm appeared
//
// The safe bias is CORRECT and is unchanged here: `pmset repeat cancel` clears the ENTIRE repeating
// schedule, so confirming when authorship is unknown is right. What was missing is the REASON. The
// two facts that force a confirm are not the same fact, and the dialog stated only one of them —
// "A repeating schedule is set that this app didn't create" — which on a FAILED READ is not a
// caveat, it is a claim we cannot support: we do not know that a schedule is set at all.
@MainActor
final class SleepWakeConfirmReasonTests: XCTestCase {

    private func makeController() -> SleepWakeScheduleController {
        let c = SleepWakeScheduleController(
            setter: SleepWakeScheduleControllerTests.FakeSetter(),
            reader: SleepWakeScheduleControllerTests.FakeReader(nil),
            store: SleepWakeScheduleControllerTests.FakeStore())
        c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
        c.setWakeEnabled(true);  c.setWakeTime(hour: 7, minute: 0); c.setWeekdayMask(31)
        return c
    }

    private var oursReadback: RepeatingSchedule {
        SleepWakeReadback.parse("""
        Repeating power events:
          sleep at 11:30PM weekdays only
          wakepoweron at 7:00AM weekdays only
        """)
    }
    private var foreignReadback: RepeatingSchedule {
        SleepWakeReadback.parse("Repeating power events:\n  sleep at 9:00AM every day")
    }

    func testConfirmReason_matrix() {
        let c = makeController()
        XCTAssertNil(c.confirmReason(for: oursReadback), "our own schedule needs no confirm")
        XCTAssertNil(c.confirmReason(for: RepeatingSchedule(events: [])), "nothing scheduled: no confirm")
        XCTAssertEqual(c.confirmReason(for: foreignReadback), .foreignSchedule)
        XCTAssertEqual(c.confirmReason(for: nil), .scheduleUnreadable,
                       "a failed read is NOT the same fact as a foreign schedule")
    }

    // The three views of the gate are one predicate. If they ever drift, the sentence on screen stops
    // matching the branch that produced it.
    func testConfirmReason_agreesWithApplyDecisionAndCancelGate() {
        let c = makeController()
        for readback in [oursReadback, foreignReadback, RepeatingSchedule(events: []), nil] {
            let needs = c.confirmReason(for: readback) != nil
            XCTAssertEqual(c.applyDecision(for: readback) == .needsConfirm, needs)
            XCTAssertEqual(c.cancelNeedsConfirm(for: readback), needs)
        }
    }

    func testUnreadableCopy_namesTheReadRatherThanClaimingASchedule() {
        let unreadable = SleepWakeScheduleController.ConfirmReason.scheduleUnreadable
        let foreign = SleepWakeScheduleController.ConfirmReason.foreignSchedule
        for text in [unreadable.applyMessage, unreadable.cancelMessage] {
            XCTAssertTrue(text.contains("couldn't be read"),
                          "the unreadable confirm must say the read failed: \(text)")
            XCTAssertFalse(text.contains("this app didn't create."),
                           "it must NOT assert a schedule exists — that is the unsupported claim: \(text)")
        }
        XCTAssertNotEqual(unreadable.applyMessage, foreign.applyMessage)
        XCTAssertNotEqual(unreadable.cancelMessage, foreign.cancelMessage)
    }

    func testApplyAndCancelCopy_nameTheActionThatFollows() {
        for reason in [SleepWakeScheduleController.ConfirmReason.foreignSchedule, .scheduleUnreadable] {
            XCTAssertNotEqual(reason.applyMessage, reason.cancelMessage,
                              "replacing a schedule and removing one are different outcomes")
            XCTAssertTrue(reason.cancelMessage.lowercased().contains("turning it off"))
        }
    }

    // The safe bias itself must not have moved: an unconfirmed apply/cancel over an unreadable
    // schedule still reaches no helper.
    func testSafeBiasUnchanged_unreadableStillGatesBothActions() {
        let setter = SleepWakeScheduleControllerTests.FakeSetter()
        let c = SleepWakeScheduleController(setter: setter,
                                            reader: SleepWakeScheduleControllerTests.FakeReader(nil),
                                            store: SleepWakeScheduleControllerTests.FakeStore())
        c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
        c.setWakeEnabled(true);  c.setWakeTime(hour: 7, minute: 0); c.setWeekdayMask(31)
        c.apply(confirmed: false)
        c.cancel(confirmed: false)
        XCTAssertEqual(setter.callCount, 0, "an unreadable schedule still gates both actions")
    }
}

// MARK: - the e498c86 sibling: an unverified schedule write must not read as a verified one
//
// `handleReply` set `.applied` on a helper success and then fired `refreshReadback()` to CONFIRM it —
// but nothing ever looked at what came back. Identical in shape to the `WakeBehaviorController` defect
// `e498c86` fixed, and it carries the same unnamed second half: `refreshReadback` can be REFUSED by
// `BoundedReadGate` when a read that BEGAN before the apply is still in flight. Then no post-apply read
// runs at all, `lastReadback` keeps its PRE-apply value, and the Automation tab renders the OLD live
// schedule under an "applied" status — strictly worse than nil, and it defeats any
// `applied && lastReadback == nil` shape. Hence the token compare.
//
// ⚠️ NO RETRY. `PmsetProbe.worstCaseSeconds(retry: .onceIfCutShort)` is 17 s against
// `BoundedReadGate.staleAfterSeconds` of 10, so a retry would let a gated caller reclaim its own read
// mid-retry and spawn a third child. The recovery is verify-the-effect and stay ARMED: the next read
// the Automation tab was going to take anyway lifts the caveat, at no extra spawn.
@MainActor
final class SleepWakeVerificationTests: XCTestCase {

    /// A setter that HOLDS its completion, so the reply can be landed at a chosen moment.
    @MainActor
    final class HoldingSetter: SleepWakeSetter {
        var pendingCompletion: (@Sendable (Result<String, HelperClientError>) -> Void)?
        private(set) var callCount = 0
        func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                                   wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int,
                                   completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
            callCount += 1
            pendingCompletion = completion
        }
    }

    /// A reader whose answer can change between reads — the fixed `FakeReader` cannot express
    /// "the read failed, then a later one worked", which is the whole recovery path.
    final class SwitchableReader: SleepScheduleReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _result: RepeatingSchedule?
        init(_ r: RepeatingSchedule?) { _result = r }
        var result: RepeatingSchedule? {
            get { lock.lock(); defer { lock.unlock() }; return _result }
            set { lock.lock(); _result = newValue; lock.unlock() }
        }
        func readRepeatingSchedule() -> RepeatingSchedule? { result }
    }

    /// A reader that PARKS inside the read, so the gate can be observed while genuinely claimed.
    final class ParkingReader: SleepScheduleReading, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let result: RepeatingSchedule?
        init(_ r: RepeatingSchedule?) { result = r }
        func readRepeatingSchedule() -> RepeatingSchedule? {
            entered.signal()
            release.wait()
            return result
        }
    }

    private static var truth: RepeatingSchedule {
        SleepWakeReadback.parse("""
        Repeating power events:
          sleep at 11:30PM weekdays only
          wakepoweron at 7:00AM weekdays only
        """)
    }

    /// Bounded yield-poll — no sleeps, no timing dependency.
    private func settle(until predicate: @escaping @MainActor () -> Bool, ticks: Int = 1000) async {
        for _ in 0..<ticks {
            if predicate() { return }
            await Task.yield()
        }
    }

    private func configured(setter: any SleepWakeSetter,
                            reader: any SleepScheduleReading) -> SleepWakeScheduleController {
        let c = SleepWakeScheduleController(setter: setter, reader: reader,
                                            store: SleepWakeScheduleControllerTests.FakeStore())
        c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
        c.setWakeEnabled(true);  c.setWakeTime(hour: 7, minute: 0); c.setWeekdayMask(31)
        return c
    }

    // MARK: the pure decision

    func testResolveVerification_notArmed_isNotEvidence() {
        XCTAssertNil(SleepWakeScheduleController.resolveVerification(
            settledToken: 7, verifyFromToken: nil, readSucceeded: true),
                     "an ordinary on-open read must never touch the apply status")
        XCTAssertNil(SleepWakeScheduleController.resolveVerification(
            settledToken: 7, verifyFromToken: nil, readSucceeded: false))
    }

    func testResolveVerification_readThatBeganBeforeTheApply_isNotEvidence() {
        XCTAssertNil(SleepWakeScheduleController.resolveVerification(
            settledToken: 4, verifyFromToken: 5, readSucceeded: true),
                     "a read started before the apply describes the machine before the write")
    }

    func testResolveVerification_successfulReadConfirmsAndDisarms() {
        let out = SleepWakeScheduleController.resolveVerification(
            settledToken: 5, verifyFromToken: 5, readSucceeded: true)
        XCTAssertEqual(out?.status, .applied)
        XCTAssertEqual(out?.stayArmed, false)
    }

    func testResolveVerification_failedReadIsUnverifiedAndStaysArmed() {
        let out = SleepWakeScheduleController.resolveVerification(
            settledToken: 9, verifyFromToken: 5, readSucceeded: false)
        XCTAssertEqual(out?.status, .appliedUnverified, "no confirmation is not a confirmation")
        XCTAssertEqual(out?.stayArmed, true,
                       "stay armed so the read the tab takes anyway lifts it — NOT a retry")
    }

    // MARK: the controller

    func testApply_successThenFailedReadback_reportsUnverified() async {
        let setter = HoldingSetter()
        let c = configured(setter: setter, reader: SwitchableReader(nil))
        c.apply(confirmed: true)
        setter.pendingCompletion?(.success("ok"))
        await settle { c.lastApplyStatus == .appliedUnverified }
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified,
                       "the post-apply read came back empty — nothing confirmed the change")
        XCTAssertNil(c.lastReadback)
    }

    func testApply_successThenGoodReadback_staysApplied() async {
        let setter = HoldingSetter()
        let c = configured(setter: setter, reader: SwitchableReader(Self.truth))
        c.apply(confirmed: true)
        setter.pendingCompletion?(.success("ok"))
        await settle { c.lastReadback == Self.truth }
        XCTAssertEqual(c.lastApplyStatus, .applied, "a read-back that landed IS the confirmation")
    }

    func testUnverified_isLiftedByTheNextReadThatWorks() async {
        let setter = HoldingSetter()
        let reader = SwitchableReader(nil)
        let c = configured(setter: setter, reader: reader)
        c.apply(confirmed: true)
        setter.pendingCompletion?(.success("ok"))
        await settle { c.lastApplyStatus == .appliedUnverified }
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified)

        reader.result = Self.truth        // the read recovers
        c.refreshReadback()               // the read the Automation tab was going to take anyway
        await settle { c.lastReadback == Self.truth }
        XCTAssertEqual(c.lastApplyStatus, .applied,
                       "the caveat lifts on evidence, with no extra spawn of its own")
    }

    func testOrdinaryReadFailure_withNoApplyPending_leavesTheStatusAlone() async {
        let c = configured(setter: HoldingSetter(), reader: SwitchableReader(nil))
        c.refreshReadback()
        await settle { c.lastApplyStatus != .idle }
        XCTAssertEqual(c.lastApplyStatus, .idle,
                       "a failed read with nothing applied is not an unverified apply")
    }

    // The half the hand-off did not name: the post-apply read is REFUSED by the gate because a read
    // that began BEFORE the apply is still in flight. Nothing re-reads; `lastReadback` keeps its
    // pre-apply value; the old code left the status at `.applied` over a stale reading.
    func testApply_whenTheGateRefusesThePostApplyRead_saysUnverifiedAtOnce() async {
        let setter = HoldingSetter()
        let reader = ParkingReader(Self.truth)
        let c = configured(setter: setter, reader: reader)
        c.refreshReadback()                                    // claims the gate; parks off-main
        XCTAssertEqual(reader.entered.wait(timeout: .now() + 5), .success, "the read must actually start")

        c.apply(confirmed: true)
        setter.pendingCompletion?(.success("ok"))              // post-apply refreshReadback → REFUSED
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified,
                       "no post-apply read ran, so nothing confirmed the change")

        reader.release.signal()                                // let the PRE-apply read land
        await settle { c.lastReadback == Self.truth }
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified,
                       "a read that began before the apply is not evidence about it")
    }

    // The cancel path shares `beginApply`/`handleReply`, so it must share the verification.
    func testCancel_successThenFailedReadback_reportsUnverified() async {
        let setter = HoldingSetter()
        let c = configured(setter: setter, reader: SwitchableReader(nil))
        c.cancel(confirmed: true)
        setter.pendingCompletion?(.success("ok"))
        await settle { c.lastApplyStatus == .appliedUnverified }
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified,
                       "a cancel the app never read back is not a confirmed cancel")
    }

    // B8's no-change rejection means no `pmset` ran. There is nothing to verify and nothing to deny:
    // the status restored from before this call must survive the read-back that follows.
    func testCooldownRejection_armsNoVerification() async {
        let setter = HoldingSetter()
        let c = configured(setter: setter, reader: SwitchableReader(nil))
        c.apply(confirmed: true)
        setter.pendingCompletion?(.failure(.helperError(SleepWakeCommand.errCooldown)))
        await settle { c.lastApplyStatus != .idle }
        XCTAssertEqual(c.lastApplyStatus, .idle,
                       "nothing was attempted, so nothing is unverified — the prior status stands")
    }
}

// MARK: - H3: a config that will not decode is not a user who never set one
//
// `loadConfig()` collapsed a DECODE FAILURE into `.empty` — the value that means "no schedule, feature
// off". The direction of the resulting claim is the tell: with `.empty` in hand the app goes on to
// assert, in the read-back line and in the destructive confirm, that the live schedule is FOREIGN
// ("This app didn't set this schedule") — a positive claim about authorship built on a config it could
// not read. It then invites the user to remove it. The first edit afterwards silently overwrites the
// undecodable blob with defaults, so the real stored schedule is gone for good with no cue.
//
// The safe bias is UNCHANGED: an unreadable config still forces the confirm. Only the sentence, and
// the fact that the user is told at all, are new.
@MainActor
final class SleepWakeConfigLoadTests: XCTestCase {

    private static let sample = SleepWakeScheduleConfig(
        sleepEnabled: true, sleepHour: 23, sleepMinute: 30,
        wakeEnabled: true, wakeHour: 7, wakeMinute: 0, weekdayMask: 31)

    private var foreignReadback: RepeatingSchedule {
        SleepWakeReadback.parse("Repeating power events:\n  sleep at 9:00AM every day")
    }

    // MARK: the pure decode

    func testDecode_absentIsNone() {
        XCTAssertEqual(UserDefaultsSleepWakeStore.decode(nil), .none)
    }

    func testDecode_undecodableIsUnreadable_notAnEmptyConfig() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let load = UserDefaultsSleepWakeStore.decode(garbage)
        XCTAssertEqual(load, .unreadable)
        XCTAssertNotEqual(load, .config(.empty),
                          "the whole defect: a blob that will not decode is not 'no schedule'")
    }

    func testDecode_validRoundTrips() throws {
        let data = try JSONEncoder().encode(Self.sample)
        XCTAssertEqual(UserDefaultsSleepWakeStore.decode(data), .config(Self.sample))
    }

    // MARK: the controller

    private func controller(_ load: SleepWakeConfigLoad,
                            store: SleepWakeScheduleControllerTests.FakeStore
                                = SleepWakeScheduleControllerTests.FakeStore())
    -> SleepWakeScheduleController {
        store.detailed = load
        return SleepWakeScheduleController(setter: SleepWakeScheduleControllerTests.FakeSetter(),
                                           reader: SleepWakeScheduleControllerTests.FakeReader(nil),
                                           store: store)
    }

    func testReadableConfig_doesNotRaiseTheFlag() {
        let c = controller(.config(Self.sample))
        XCTAssertFalse(c.configUnreadable)
        XCTAssertEqual(c.config, Self.sample)
    }

    func testAbsentConfig_isNotUnreadable() {
        let c = controller(.none)
        XCTAssertFalse(c.configUnreadable, "a user who never set one is not a failed read")
        XCTAssertEqual(c.config, .empty)
    }

    func testUnreadableConfig_raisesTheFlag_andStillDefaultsTheFields() {
        let c = controller(.unreadable)
        XCTAssertTrue(c.configUnreadable)
        XCTAssertEqual(c.config, .empty, "the fields must still be usable")
    }

    // The claim that must stop being made.
    func testUnreadableConfig_doesNotClaimForeignAuthorship() {
        let c = controller(.unreadable)
        XCTAssertEqual(c.confirmReason(for: foreignReadback), .configUnreadable,
                       "we cannot call a schedule foreign on a config we could not read")
        XCTAssertNotEqual(c.confirmReason(for: foreignReadback), .foreignSchedule)
    }

    func testUnreadableConfig_stillNeedsNoConfirmWhenNothingIsScheduled() {
        let c = controller(.unreadable)
        XCTAssertNil(c.confirmReason(for: RepeatingSchedule(events: [])),
                     "an empty live schedule is nothing to clobber, whatever our config says")
    }

    func testUnreadableConfig_failedReadStillReportsTheFailedRead() {
        let c = controller(.unreadable)
        XCTAssertEqual(c.confirmReason(for: nil), .scheduleUnreadable,
                       "the live read is the nearer fact; it is reported first")
    }

    func testConfigUnreadableCopy_saysWhatWeCouldNotRead_notWhoSetIt() {
        let reason = SleepWakeScheduleController.ConfirmReason.configUnreadable
        for text in [reason.applyMessage, reason.cancelMessage] {
            XCTAssertFalse(text.contains("this app didn't create"),
                           "that is exactly the unsupported claim: \(text)")
            XCTAssertTrue(text.lowercased().contains("its own saved"),
                          "it must name OUR config as the thing that could not be read: \(text)")
        }
        XCTAssertNotEqual(reason.applyMessage, reason.cancelMessage)
        XCTAssertTrue(reason.cancelMessage.lowercased().contains("turning it off"))
    }

    // The safe bias is untouched: pmset repeat cancel clears the ENTIRE schedule, so an unverifiable
    // authorship still gates both destructive actions.
    func testSafeBiasUnchanged_anUnreadableConfigStillGatesBothActions() {
        let c = controller(.unreadable)
        XCTAssertEqual(c.applyDecision(for: foreignReadback), .needsConfirm)
        XCTAssertTrue(c.cancelNeedsConfirm(for: foreignReadback))

        // ...and the actions themselves still refuse to reach the helper unconfirmed.
        let setter = SleepWakeScheduleControllerTests.FakeSetter()
        let store = SleepWakeScheduleControllerTests.FakeStore()
        store.detailed = .unreadable
        let live = SleepWakeScheduleController(
            setter: setter, reader: SleepWakeScheduleControllerTests.FakeReader(nil), store: store)
        live.setSleepEnabled(true); live.setSleepTime(hour: 23, minute: 30)
        live.apply(confirmed: false)
        live.cancel(confirmed: false)
        XCTAssertEqual(setter.callCount, 0, "an unreadable config still gates both actions")
    }

    // An EDIT does not end the condition. The flag means "the app's record of what it set is lost",
    // and typing a new time does not make the schedule ON THE MACHINE one the app can account for —
    // so the foreign-authorship claim must stay suppressed until the app has actually written one.
    //
    // REVERSED in part by redman sweep item 3 (was `testEdit_persists_butTheFlagSurvivesUntilSomething
    // IsApplied`, which asserted "the edit is persisted" — i.e. saved over the unreadable blob, the
    // data-loss path itself). The edit now lives in memory only until an apply succeeds.
    func testEdit_isHeldInMemoryNotSaved_andTheFlagSurvivesUntilSomethingIsApplied() {
        let store = SleepWakeScheduleControllerTests.FakeStore()
        let c = controller(.unreadable, store: store)
        XCTAssertTrue(c.configUnreadable)
        c.setSleepEnabled(true)
        XCTAssertTrue(c.config.sleepEnabled, "the edit takes effect in memory")
        XCTAssertFalse(store.saved.sleepEnabled, "but is not saved over the unreadable config")
        XCTAssertTrue(c.configUnreadable, "but nothing has been applied, so we still can't account for the live schedule")
        XCTAssertEqual(c.confirmReason(for: foreignReadback), .configUnreadable)
    }

    // A successful apply DOES end it: the app has just written the schedule, so its config describes it.
    func testSuccessfulApply_clearsTheFlag() {
        let setter = SleepWakeScheduleControllerTests.FakeSetter()
        let store = SleepWakeScheduleControllerTests.FakeStore()
        store.detailed = .unreadable
        let c = SleepWakeScheduleController(
            setter: setter, reader: SleepWakeScheduleControllerTests.FakeReader(nil), store: store)
        c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
        XCTAssertTrue(c.configUnreadable)
        c.apply(confirmed: true)
        XCTAssertEqual(setter.callCount, 1)
        XCTAssertFalse(c.configUnreadable, "the app has now authored the live schedule")
    }

    // ...and a FAILED apply does not: nothing was written, so nothing is accounted for.
    func testFailedApply_leavesTheFlagUp() {
        let setter = SleepWakeScheduleControllerTests.FakeSetter()
        setter.cannedResult = .failure(.helperError("error:set-failed"))
        let store = SleepWakeScheduleControllerTests.FakeStore()
        store.detailed = .unreadable
        let c = SleepWakeScheduleController(
            setter: setter, reader: SleepWakeScheduleControllerTests.FakeReader(nil), store: store)
        c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
        c.apply(confirmed: true)
        XCTAssertTrue(c.configUnreadable, "a failed write accounts for nothing")
    }
}
