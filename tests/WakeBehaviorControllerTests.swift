import XCTest
import Shared

/// Sprint 3.7 (power-nap / wake-for-network) STAGE 2b-i: the app-side controller. Host-app-free (the
/// app source compiles into the test target, mirroring SleepWakeScheduleControllerTests). Covers the
/// scope→bools mapping on apply, the readback→scope adoption (incl. the degenerate normalization and
/// the nil no-op), and that apply maps the helper reply. The live pmset read (LivePmsetCustomReader)
/// spawns a real subprocess and is exercised on-device, not here.
@MainActor
final class WakeBehaviorControllerTests: XCTestCase {

    // MARK: - fakes (annotations mirror SleepWakeScheduleControllerTests.FakeSetter)

    @MainActor
    final class FakeSetter: WakeBehaviorSetter {
        var captured: (Bool, Bool, Bool, Bool)?
        var pendingCompletion: (@Sendable (Result<String, HelperClientError>) -> Void)?
        func setWakeBehavior(powerNapBattery: Bool, powerNapAC: Bool,
                             wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool,
                             completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
            captured = (powerNapBattery, powerNapAC, wakeOnNetworkBattery, wakeOnNetworkAC)
            pendingCompletion = completion
        }
    }

    struct FakeReader: WakeBehaviorReading {
        let state: WakeBehaviorReadback.State?
        func readCurrent() -> WakeBehaviorReadback.State? { state }
    }

    // MARK: - apply maps the two scopes to the four bools (protocol order)

    func testApply_passesBoolsForScopes() {
        let setter = FakeSetter()
        let c = WakeBehaviorController(setter: setter, reader: FakeReader(state: nil))
        c.powerNap = .always
        c.wakeOnNetwork = .onPowerAdapter
        c.apply()
        XCTAssertEqual(c.lastApplyStatus, .applying)
        XCTAssertEqual(setter.captured?.0, true)
        XCTAssertEqual(setter.captured?.1, true)
        XCTAssertEqual(setter.captured?.2, false)
        XCTAssertEqual(setter.captured?.3, true)
    }

    func testApply_neverAndNever() {
        let setter = FakeSetter()
        let c = WakeBehaviorController(setter: setter, reader: FakeReader(state: nil))
        c.powerNap = .never
        c.wakeOnNetwork = .never
        c.apply()
        XCTAssertEqual(setter.captured?.0, false)
        XCTAssertEqual(setter.captured?.1, false)
        XCTAssertEqual(setter.captured?.2, false)
        XCTAssertEqual(setter.captured?.3, false)
    }

    // MARK: - adopt maps the live readback to the pickers

    func testAdopt_mapsStateToScopes() {
        let c = WakeBehaviorController(setter: FakeSetter(), reader: FakeReader(state: nil))
        let s = WakeBehaviorReadback.State(powerNapBattery: true, powerNapAC: true,
                                           wakeOnNetworkBattery: false, wakeOnNetworkAC: true)
        c.adopt(s)
        XCTAssertEqual(c.powerNap, .always)
        XCTAssertEqual(c.wakeOnNetwork, .onPowerAdapter)
        XCTAssertEqual(c.lastReadback, s)
    }

    func testAdopt_degenerateNormalizesToAlways() {
        let c = WakeBehaviorController(setter: FakeSetter(), reader: FakeReader(state: nil))
        let s = WakeBehaviorReadback.State(powerNapBattery: true, powerNapAC: false,
                                           wakeOnNetworkBattery: false, wakeOnNetworkAC: false)
        c.adopt(s)
        XCTAssertEqual(c.powerNap, .always, "battery-on/AC-off normalizes to .always")
        XCTAssertEqual(c.wakeOnNetwork, .never)
    }

    func testAdopt_nilLeavesScopesUntouched() {
        let c = WakeBehaviorController(setter: FakeSetter(), reader: FakeReader(state: nil))
        c.powerNap = .onPowerAdapter
        c.wakeOnNetwork = .always
        c.adopt(nil)
        XCTAssertNil(c.lastReadback)
        XCTAssertEqual(c.powerNap, .onPowerAdapter, "nil read does not change selections")
        XCTAssertEqual(c.wakeOnNetwork, .always)
    }

    // MARK: - apply maps the helper reply

    func testHandleReply_successApplied() {
        let setter = FakeSetter()
        let c = WakeBehaviorController(setter: setter, reader: FakeReader(state: nil))
        c.apply()
        setter.pendingCompletion?(.success("ok"))
        XCTAssertEqual(c.lastApplyStatus, .applied)
    }

    func testHandleReply_helperErrorFailed() {
        let setter = FakeSetter()
        let c = WakeBehaviorController(setter: setter, reader: FakeReader(state: nil))
        c.apply()
        setter.pendingCompletion?(.failure(.helperError("error:set-failed")))
        XCTAssertEqual(c.lastApplyStatus, .failed("error:set-failed"))
    }

    func testHandleReply_unreachable() {
        let setter = FakeSetter()
        let c = WakeBehaviorController(setter: setter, reader: FakeReader(state: nil))
        c.apply()
        setter.pendingCompletion?(.failure(.unreachable))
        XCTAssertEqual(c.lastApplyStatus, .unreachable)
    }

    // MARK: - read-clobber mitigation (Stage 2b-ii)

    func testSetPowerNap_setsValueAndBumpsGeneration() {
        let c = WakeBehaviorController(setter: FakeSetter(), reader: FakeReader(state: nil))
        let g0 = c.editGeneration
        c.setPowerNap(.never)
        XCTAssertEqual(c.powerNap, .never)
        XCTAssertEqual(c.editGeneration, g0 + 1, "a user edit bumps the edit generation")
    }

    func testSetWakeOnNetwork_setsValueAndBumpsGeneration() {
        let c = WakeBehaviorController(setter: FakeSetter(), reader: FakeReader(state: nil))
        let g0 = c.editGeneration
        c.setWakeOnNetwork(.always)
        XCTAssertEqual(c.wakeOnNetwork, .always)
        XCTAssertEqual(c.editGeneration, g0 + 1)
    }

    func testApplyReadResult_generationUnchanged_adoptsPickers() {
        let c = WakeBehaviorController(setter: FakeSetter(), reader: FakeReader(state: nil))
        c.powerNap = .never            // direct set — does NOT bump the generation
        c.wakeOnNetwork = .never
        let s = WakeBehaviorReadback.State(powerNapBattery: true, powerNapAC: true,
                                           wakeOnNetworkBattery: false, wakeOnNetworkAC: true)
        c.applyReadResult(s, readGeneration: c.editGeneration)   // no edit since kickoff
        XCTAssertEqual(c.powerNap, .always)
        XCTAssertEqual(c.wakeOnNetwork, .onPowerAdapter)
        XCTAssertEqual(c.lastReadback, s)
    }

    func testApplyReadResult_generationAdvanced_keepsPickers() {
        let c = WakeBehaviorController(setter: FakeSetter(), reader: FakeReader(state: nil))
        let genAtKickoff = c.editGeneration    // a read starts here
        c.setPowerNap(.never)                  // user edits mid-read (generation advances)
        c.setWakeOnNetwork(.never)
        let s = WakeBehaviorReadback.State(powerNapBattery: true, powerNapAC: true,
                                           wakeOnNetworkBattery: true, wakeOnNetworkAC: true)
        c.applyReadResult(s, readGeneration: genAtKickoff)   // the read returns, now stale
        XCTAssertEqual(c.powerNap, .never, "an edit during the read must not be reverted")
        XCTAssertEqual(c.wakeOnNetwork, .never)
        XCTAssertEqual(c.lastReadback, s, "the read-back line still updates to the live truth")
    }

    // The pickers stay live during .applying (the view disables only the Apply button, line 950). An edit
    // made while the helper set is in flight must survive the post-apply re-read. The cleared-at-read-start
    // boolean reverted it; the generation captured at apply kickoff preserves it.
    func testEditDuringApply_postApplyReadKeepsTheNewEdit() async {
        let setter = FakeSetter()
        // The reader returns the APPLIED (pre-edit) truth (.always/.always); if the post-apply read adopted
        // it, the edit-to-.never would be lost.
        let appliedTruth = WakeBehaviorReadback.State(powerNapBattery: true, powerNapAC: true,
                                                      wakeOnNetworkBattery: true, wakeOnNetworkAC: true)
        let c = WakeBehaviorController(setter: setter, reader: FakeReader(state: appliedTruth))
        c.setPowerNap(.always)                       // the user's committed choice
        c.apply()                                    // captures generation + bools; helper set "in flight"
        c.setPowerNap(.never)                        // EDIT during the in-flight apply
        setter.pendingCompletion?(.success("ok"))    // reply → handleReply → post-apply refreshReadback
        await Self.settleReadback(c, until: appliedTruth)   // drain the off-main read + main-actor hop
        XCTAssertEqual(c.lastReadback, appliedTruth,
                       "the post-apply read must actually land — guards against a vacuous pass if it stops running")
        XCTAssertEqual(c.powerNap, .never, "an edit made during the apply must survive the post-apply re-read")
    }

    /// Bounded yield-poll until the async off-main read + main-actor hop settle. lastReadback is set in
    /// BOTH the keep and adopt branches, so it converges as soon as the read returns; the assertion on
    /// powerNap distinguishes keep (.never) from revert (.always). No sleeps / no timing dependency.
    static func settleReadback(_ c: WakeBehaviorController,
                               until: WakeBehaviorReadback.State, ticks: Int = 500) async {
        for _ in 0..<ticks {
            if c.lastReadback == until { return }
            await Task.yield()
        }
    }
}

// MARK: - hand-off 3: an unverified write must not read as a verified one
//
// `handleReply` set `.applied` on a helper success and then fired a post-apply read-back to CONFIRM
// it. When that read came back nil the status stayed `.applied` and `lastReadback` went nil — so the
// surface showed no error, held the pickers at the values the user chose, and nothing on screen had
// actually confirmed anything. Same shape as `8c2cbe4`: a missing witness counted as an agreeing one.
//
// The nastier half, which the hand-off did not name: `refreshReadback` can be REFUSED by
// `BoundedReadGate` when a read that began BEFORE the apply is still in flight. Then no post-apply
// read runs at all and `lastReadback` keeps its PRE-apply value — a stale reading rendered as the
// current one under a `.applied` status.
//
// NO RETRY: this read sits behind `BoundedReadGate` (staleAfterSeconds 10) and
// `PmsetProbe.RetryPolicy.onceIfCutShort` worst-cases at 17 s, so a retry here would let a gated
// caller reclaim its own read mid-retry and spawn a third child. The recovery is to say what was
// confirmed and stay ARMED, so the next read the app was going to take anyway lifts the caveat.
@MainActor
final class WakeBehaviorVerificationTests: XCTestCase {

    private static let truth = WakeBehaviorReadback.State(powerNapBattery: true, powerNapAC: true,
                                                          wakeOnNetworkBattery: false, wakeOnNetworkAC: true)

    @MainActor
    final class FakeSetter: WakeBehaviorSetter {
        var pendingCompletion: (@Sendable (Result<String, HelperClientError>) -> Void)?
        func setWakeBehavior(powerNapBattery: Bool, powerNapAC: Bool,
                             wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool,
                             completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
            pendingCompletion = completion
        }
    }

    /// A reader whose answer can be changed between reads (the fixed FakeReader cannot express
    /// "the read failed, then a later one worked" — which is the whole recovery path).
    final class SwitchableReader: WakeBehaviorReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _state: WakeBehaviorReadback.State?
        init(_ s: WakeBehaviorReadback.State?) { _state = s }
        var state: WakeBehaviorReadback.State? {
            get { lock.lock(); defer { lock.unlock() }; return _state }
            set { lock.lock(); _state = newValue; lock.unlock() }
        }
        func readCurrent() -> WakeBehaviorReadback.State? { state }
    }

    /// A reader that PARKS inside the read, so the gate can be observed while genuinely claimed.
    final class ParkingReader: WakeBehaviorReading, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let state: WakeBehaviorReadback.State?
        init(_ s: WakeBehaviorReadback.State?) { state = s }
        func readCurrent() -> WakeBehaviorReadback.State? {
            entered.signal()
            release.wait()
            return state
        }
    }

    /// Bounded yield-poll — no sleeps, no timing dependency.
    private func settle(until predicate: @escaping @MainActor () -> Bool, ticks: Int = 1000) async {
        for _ in 0..<ticks {
            if predicate() { return }
            await Task.yield()
        }
    }

    // MARK: the pure decision

    func testResolveVerification_notArmed_isNotEvidence() {
        XCTAssertNil(WakeBehaviorController.resolveVerification(settledToken: 7, verifyFromToken: nil,
                                                                readSucceeded: true),
                     "an ordinary on-open read must never touch the apply status")
        XCTAssertNil(WakeBehaviorController.resolveVerification(settledToken: 7, verifyFromToken: nil,
                                                                readSucceeded: false))
    }

    func testResolveVerification_readThatBeganBeforeTheApply_isNotEvidence() {
        XCTAssertNil(WakeBehaviorController.resolveVerification(settledToken: 4, verifyFromToken: 5,
                                                                readSucceeded: true),
                     "a read started before the apply cannot confirm it")
    }

    func testResolveVerification_successfulReadConfirmsAndDisarms() {
        let out = WakeBehaviorController.resolveVerification(settledToken: 5, verifyFromToken: 5,
                                                             readSucceeded: true)
        XCTAssertEqual(out?.status, .applied)
        XCTAssertEqual(out?.stayArmed, false)
    }

    func testResolveVerification_failedReadIsUnverifiedAndStaysArmed() {
        let out = WakeBehaviorController.resolveVerification(settledToken: 9, verifyFromToken: 5,
                                                             readSucceeded: false)
        XCTAssertEqual(out?.status, .appliedUnverified,
                       "no confirmation is not a confirmation")
        XCTAssertEqual(out?.stayArmed, true,
                       "stay armed so the next read the app takes anyway can lift the caveat — NOT a retry")
    }

    // MARK: the controller

    func testApply_successThenFailedReadback_reportsUnverified() async {
        let setter = FakeSetter()
        let c = WakeBehaviorController(setter: setter, reader: SwitchableReader(nil))
        c.apply()
        setter.pendingCompletion?(.success("ok"))
        XCTAssertEqual(c.lastApplyStatus, .applied, "the helper said yes; the read has not answered yet")
        await settle { c.lastApplyStatus == .appliedUnverified }
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified,
                       "the post-apply read came back empty — nothing confirmed the change")
        XCTAssertNil(c.lastReadback)
    }

    func testApply_successThenGoodReadback_staysApplied() async {
        let setter = FakeSetter()
        let c = WakeBehaviorController(setter: setter, reader: SwitchableReader(Self.truth))
        c.apply()
        setter.pendingCompletion?(.success("ok"))
        await settle { c.lastReadback == Self.truth }
        XCTAssertEqual(c.lastApplyStatus, .applied, "a read-back that landed IS the confirmation")
    }

    func testUnverified_isLiftedByTheNextReadThatWorks() async {
        let setter = FakeSetter()
        let reader = SwitchableReader(nil)
        let c = WakeBehaviorController(setter: setter, reader: reader)
        c.apply()
        setter.pendingCompletion?(.success("ok"))
        await settle { c.lastApplyStatus == .appliedUnverified }
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified)

        reader.state = Self.truth              // the machine recovers
        c.refreshReadback()                    // the read the tab was going to take anyway
        await settle { c.lastReadback == Self.truth }
        XCTAssertEqual(c.lastApplyStatus, .applied,
                       "the caveat lifts on evidence, with no extra spawn of its own")
    }

    func testOrdinaryReadFailure_withNoApplyPending_leavesTheStatusAlone() async {
        let c = WakeBehaviorController(setter: FakeSetter(), reader: SwitchableReader(nil))
        c.refreshReadback()
        await settle { c.lastApplyStatus != .idle }
        XCTAssertEqual(c.lastApplyStatus, .idle,
                       "a failed read with nothing applied is not an unverified apply")
    }

    // The case the hand-off did not name. A read that began BEFORE the apply is still in flight, so
    // the post-apply read is REFUSED by the gate: nothing re-reads, `lastReadback` keeps its pre-apply
    // value, and the old code left the status at `.applied` over a stale reading.
    func testApply_whenTheGateRefusesThePostApplyRead_saysUnverifiedAtOnce() async {
        let setter = FakeSetter()
        let reader = ParkingReader(Self.truth)
        let c = WakeBehaviorController(setter: setter, reader: reader)
        c.refreshReadback()                                       // claims the gate; parks off-main
        XCTAssertEqual(reader.entered.wait(timeout: .now() + 5), .success, "the read must actually start")

        c.apply()
        setter.pendingCompletion?(.success("ok"))                  // post-apply refreshReadback → REFUSED
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified,
                       "no post-apply read ran, so nothing confirmed the change")

        reader.release.signal()                                   // let the PRE-apply read land
        await settle { c.lastReadback == Self.truth }
        XCTAssertEqual(c.lastApplyStatus, .appliedUnverified,
                       "a read that began before the apply is not evidence about it")
    }
}
