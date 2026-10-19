import XCTest

/// #EI-1 keep-awake (SPEC 02-SPEC-ei1-keep-awake.md): the keep-awake state machine + the release
/// spine (off / timer-expiry / app-quit / unplug-for-AC), driven through a MOCK SleepAssertion — never
/// a real assertion. The pure tested logic; the Live IOPMAssertion wrapper is a boundary adapter.
@MainActor
final class KeepAwakeTests: XCTestCase {

    // MARK: - seam mocks

    /// Records create/release so a test can assert the net-held assertion set and the legible name.
    final class MockSleepAssertion: SleepAssertion {
        private(set) var created: [(kind: SleepAssertionKind, name: String, id: UInt32)] = []
        private(set) var releasedIDs: [UInt32] = []
        /// Kinds for which create() returns nil (simulate a creation failure).
        var failKinds: Set<SleepAssertionKind> = []
        private var nextID: UInt32 = 1

        func create(_ kind: SleepAssertionKind, name: String) -> UInt32? {
            if failKinds.contains(kind) { return nil }
            let id = nextID; nextID += 1
            created.append((kind, name, id))
            return id
        }
        func release(_ id: UInt32) { releasedIDs.append(id) }

        /// Currently-held ids = created minus released.
        var activeIDs: [UInt32] { created.map(\.id).filter { !releasedIDs.contains($0) } }
        /// Currently-held kinds, in creation order.
        var activeKinds: [SleepAssertionKind] {
            created.filter { !releasedIDs.contains($0.id) }.map(\.kind)
        }
    }

    /// Captures scheduled one-shots so a test can fire them to simulate timer expiry.
    final class MockOneShot: OneShotScheduling {
        private(set) var scheduled: [(TimeInterval, () -> Void)] = []
        func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) { scheduled.append((seconds, work)) }
        func fireAll() { let s = scheduled; scheduled = []; s.forEach { $0.1() } }
        var count: Int { scheduled.count }
        var lastDelay: TimeInterval? { scheduled.last?.0 }
    }

    /// #30 §14-C7: `enable()` persists the last preset; tests write to a throwaway suite, never `.standard`.
    private let isolatedDefaults = UserDefaults(suiteName: "KeepAwakeTests.\(UUID().uuidString)")!

    private func makeController()
    -> (KeepAwakeController, MockSleepAssertion, MockOneShot, MockClockBox) {
        let assertion = MockSleepAssertion()
        let oneShot = MockOneShot()
        let box = MockClockBox(0)
        let c = KeepAwakeController(assertion: assertion, scheduler: oneShot,
                                    clock: MockMonotonicClock(box: box),
                                    presetStore: KeepAwakePresetStore(defaults: isolatedDefaults))
        return (c, assertion, oneShot, box)
    }

    // MARK: - enable creates exactly the chosen assertion(s), with the legible name

    func testEnableSystemCreatesOnlyTheSystemAssertion() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertEqual(a.activeKinds, [.systemIdle], "system scope creates only PreventUserIdleSystemSleep")
        XCTAssertTrue(c.isOn)
        XCTAssertEqual(a.created.map(\.name), [KeepAwakeController.assertionName],
                       "the assertion carries the legible name (pmset -g assertions / Energy tab)")
    }

    func testEnableSystemAndDisplayCreatesBothAssertions() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        XCTAssertEqual(a.activeKinds, [.systemIdle, .displayIdle],
                       "display-on ADDS PreventUserIdleDisplaySleep to the system assertion")
        XCTAssertTrue(a.created.allSatisfy { $0.name == KeepAwakeController.assertionName })
    }

    // MARK: - off releases

    func testDisableReleasesEverythingAndGoesOff() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        c.disable()
        XCTAssertTrue(a.activeIDs.isEmpty, "off releases every held assertion")
        XCTAssertFalse(c.isOn)
        XCTAssertNil(c.session)
    }

    func testDisableWhenAlreadyOffIsANoOp() {
        let (c, a, _, _) = makeController()
        c.disable()
        XCTAssertTrue(a.activeIDs.isEmpty)
        XCTAssertFalse(c.isOn)
    }

    // MARK: - timed session releases at expiry (mock clock + mock one-shot)

    func testTimedSessionSchedulesAndReleasesAtExpiry() {
        let (c, a, oneShot, box) = makeController()
        c.enable(scope: .system, duration: .timed(1800))   // 30 min
        XCTAssertEqual(a.activeKinds, [.systemIdle])
        XCTAssertEqual(oneShot.count, 1, "a single per-session expiry timer is scheduled")
        XCTAssertEqual(oneShot.lastDelay, 1800)
        XCTAssertEqual(c.remainingSeconds(), 1800, "remaining = the full duration at t0")
        box.now = 1200
        XCTAssertEqual(c.remainingSeconds(), 600, "remaining counts down with the clock")

        oneShot.fireAll()                                  // the Timer fires at expiry
        XCTAssertTrue(a.activeIDs.isEmpty, "expiry releases the assertion")
        XCTAssertFalse(c.isOn)
        XCTAssertNil(c.remainingSeconds(), "no session → no remaining")
    }

    func testIndefiniteAndWhileOnACScheduleNoTimer() {
        let (c, _, oneShot, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertEqual(oneShot.count, 0, "indefinite arms no expiry timer")
        XCTAssertNil(c.remainingSeconds())
        c.enable(scope: .system, duration: .whileOnAC)
        XCTAssertEqual(oneShot.count, 0, "while-on-AC arms no expiry timer")
    }

    func testExpiryAfterManualDisableDoesNotReleaseANewSession() {
        // A stale timer from a finished session must not tear down a later session.
        let (c, a, oneShot, _) = makeController()
        c.enable(scope: .system, duration: .timed(60))     // schedules expire #1
        c.disable()                                        // released; #1 now stale
        c.enable(scope: .systemAndDisplay, duration: .indefinite)  // a fresh, indefinite session
        let kindsBefore = a.activeKinds
        oneShot.fireAll()                                  // the stale #1 fires
        XCTAssertEqual(a.activeKinds, kindsBefore, "the stale expiry must not release the new session")
        XCTAssertTrue(c.isOn, "the indefinite session survives the stale timer")
    }

    // MARK: - setScope: change scope mid-session WITHOUT disturbing the timer/deadline

    func testSetScopePreservesTimedDeadlineAndTimer() {
        let (c, a, oneShot, box) = makeController()
        c.enable(scope: .system, duration: .timed(1800))
        XCTAssertEqual(oneShot.count, 1)
        box.now = 1200                                  // 600 s left
        c.setScope(.systemAndDisplay)                   // add display-on mid-session
        XCTAssertEqual(a.activeKinds, [.systemIdle, .displayIdle], "scope swapped to both")
        XCTAssertEqual(c.remainingSeconds(), 600, "the original deadline is preserved — NOT reset to 1800")
        XCTAssertEqual(oneShot.count, 1, "a scope change schedules NO second expiry timer")
        XCTAssertEqual(c.session?.duration, .timed(1800), "duration unchanged")
        oneShot.fireAll()                               // the ORIGINAL timer still fires at the real deadline
        XCTAssertTrue(a.activeIDs.isEmpty, "expiry still releases after a scope change")
        XCTAssertFalse(c.isOn)
    }

    func testSetScopeReleasesOldAssertionsAndCreatesNew() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .systemAndDisplay, duration: .indefinite)   // 2 created
        c.setScope(.system)                                         // down to 1
        XCTAssertEqual(a.activeKinds, [.systemIdle])
        XCTAssertEqual(a.releasedIDs.count, 2, "both prior assertions released on the scope swap")
    }

    func testSetScopeWhenOffIsNoOp() {
        let (c, a, oneShot, _) = makeController()
        c.setScope(.systemAndDisplay)
        XCTAssertTrue(a.activeIDs.isEmpty, "no assertion created when off")
        XCTAssertFalse(c.isOn)
        XCTAssertEqual(oneShot.count, 0)
    }

    // MARK: - partial create-failure (DECIDED: partial success COUNTS as on, and says what it holds)

    func testPartialCreateFailureHoldsOnlySucceededKinds() {
        let (c, a, _, _) = makeController()
        a.failKinds = [.displayIdle]
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        XCTAssertEqual(a.activeKinds, [.systemIdle], "a failed kind is omitted from the held set")
        XCTAssertTrue(c.isOn, "the session is still on for the kind(s) that did succeed")
        // The honesty half: the session records the REQUESTED scope, `heldKinds` records the truth, so
        // a surface can say the display is not actually being held awake.
        XCTAssertEqual(c.heldKinds, [.systemIdle], "heldKinds reports only what was really created")
        XCTAssertEqual(c.session?.scope, .systemAndDisplay, "session.scope is still the REQUESTED scope")
        XCTAssertNil(c.lastEnd, "a partial success is a running session, not an end")
        c.disable()
        XCTAssertTrue(a.activeIDs.isEmpty, "disable still releases the succeeded one cleanly")
        XCTAssertTrue(c.heldKinds.isEmpty, "off holds nothing")
    }

    func testPartialCreateFailureOfTheSystemKindStillCounts() {
        // The display assertion alone keeps the system awake too, so the headline claim still holds —
        // but heldKinds must not pretend the system kind was created.
        let (c, a, _, _) = makeController()
        a.failKinds = [.systemIdle]
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        XCTAssertTrue(c.isOn, "one surviving idle assertion still prevents idle sleep")
        XCTAssertEqual(c.heldKinds, [.displayIdle])
        XCTAssertEqual(a.activeKinds, [.displayIdle])
    }

    // MARK: - DEFECT B7: an activation that created NOTHING must not present as on

    func testAllCreateFailuresDoNotPresentAsOn() {
        let (c, a, _, _) = makeController()
        a.failKinds = [.systemIdle, .displayIdle]
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        XCTAssertFalse(c.isOn, "no assertion held → the badge/menu must NOT claim keep-awake is on")
        XCTAssertNil(c.session, "an empty session is an active lie, not a silent no-op")
        XCTAssertTrue(c.heldKinds.isEmpty)
        XCTAssertTrue(a.activeIDs.isEmpty)
        XCTAssertEqual(c.lastEnd, .activationFailed, "the failure is recorded, not swallowed")
    }

    func testAllCreateFailuresOnATimedSessionArmNoTimer() {
        let (c, a, oneShot, _) = makeController()
        a.failKinds = [.systemIdle]
        c.enable(scope: .system, duration: .timed(1800))
        XCTAssertFalse(c.isOn)
        XCTAssertEqual(oneShot.count, 0, "a session that never started arms no expiry timer")
        XCTAssertNil(c.remainingSeconds(), "no session → no remaining time to display")
    }

    func testFailedActivationDoesNotLeaveAPriorSessionOn() {
        // Re-arming over a live session releases FIRST (the no-stacking spine). If the new creates all
        // fail, the old assertions are gone — so the app must read off, not keep claiming the old one.
        let (c, a, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        a.failKinds = [.systemIdle, .displayIdle]
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        XCTAssertFalse(c.isOn, "the prior session's assertions were released; nothing is held now")
        XCTAssertTrue(a.activeIDs.isEmpty, "no leak: the prior ids were released exactly once")
        XCTAssertEqual(a.releasedIDs.count, 1)
        XCTAssertEqual(c.lastEnd, .activationFailed)
    }

    func testSuccessfulEnableClearsAPriorFailure() {
        let (c, a, _, _) = makeController()
        a.failKinds = [.systemIdle]
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertEqual(c.lastEnd, .activationFailed)
        a.failKinds = []
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertTrue(c.isOn)
        XCTAssertNil(c.lastEnd, "a live session is not an ended one")
    }

    func testSetScopeThatCreatesNothingEndsTheSessionHonestly() {
        let (c, a, oneShot, _) = makeController()
        c.enable(scope: .system, duration: .timed(3600))
        a.failKinds = [.systemIdle, .displayIdle]
        c.setScope(.systemAndDisplay)                 // releases the old set, creates nothing
        XCTAssertFalse(c.isOn, "a scope swap that holds nothing must not present as on")
        XCTAssertNil(c.session)
        XCTAssertTrue(a.activeIDs.isEmpty)
        XCTAssertEqual(c.lastEnd, .activationFailed)
        oneShot.fireAll()                             // the now-stale expiry fires
        XCTAssertNil(c.session, "the stale expiry must not resurrect a session")
    }

    // MARK: - DEFECT 2: a sleep the assertions could not prevent marks the session INTERRUPTED

    func testSleepWhileHeldMarksTheSessionInterrupted() {
        // Our assertions are idle-sleep only (IOPMLib.h:286 — lid close / Apple menu / low battery
        // still sleep the Mac). A session that lived through a sleep must not read as an unbroken "On".
        let (c, a, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertFalse(c.isInterrupted, "a fresh session is not interrupted")
        c.systemWillSleep()
        XCTAssertTrue(c.isInterrupted, "the machine slept through a held session — say so")
        XCTAssertEqual(c.session?.sleepInterruptions, 1)
        XCTAssertTrue(c.session?.wasInterrupted ?? false)
        // The session is NOT torn down: the assertions are still held and still effective from here.
        XCTAssertTrue(c.isOn)
        XCTAssertEqual(a.activeKinds, [.systemIdle], "no assertion is released by the interruption")
        XCTAssertNil(c.lastEnd, "an interruption is not an end")
    }

    func testRepeatedSleepsAccumulateOnTheSameSession() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.systemWillSleep()
        c.systemWillSleep()
        XCTAssertEqual(c.session?.sleepInterruptions, 2, "each broken promise is counted")
    }

    func testSleepWhenOffRecordsNothing() {
        let (c, a, _, _) = makeController()
        c.systemWillSleep()
        XCTAssertFalse(c.isOn)
        XCTAssertFalse(c.isInterrupted, "an ordinary sleep with keep-awake off is not an interruption")
        XCTAssertNil(c.session)
        XCTAssertTrue(a.activeIDs.isEmpty)
    }

    func testEnableStartsACleanUninterruptedSession() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.systemWillSleep()
        c.enable(scope: .system, duration: .indefinite)   // a fresh claim
        XCTAssertFalse(c.isInterrupted, "a new session starts with a clean claim")
        XCTAssertEqual(c.session?.sleepInterruptions, 0)
        c.systemWillSleep()
        c.disable()
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertFalse(c.isInterrupted, "off → on also starts clean")
    }

    func testSetScopeCarriesTheInterruptionForward() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .timed(1800))
        c.systemWillSleep()
        c.setScope(.systemAndDisplay)                     // a scope swap is not a fresh claim
        XCTAssertTrue(c.isInterrupted, "the same session is still the one that was slept through")
        XCTAssertEqual(c.session?.sleepInterruptions, 1)
        XCTAssertEqual(c.session?.duration, .timed(1800), "the release spine is untouched by all this")
    }

    func testInterruptedTimedSessionStillReleasesAtExpiry() {
        let (c, a, oneShot, _) = makeController()
        c.enable(scope: .system, duration: .timed(1800))
        c.systemWillSleep()
        oneShot.fireAll()
        XCTAssertFalse(c.isOn, "an interruption does not disarm the expiry release")
        XCTAssertTrue(a.activeIDs.isEmpty)
        XCTAssertEqual(c.lastEnd, .expired)
    }

    func testInterruptedSessionStillReleasesOnTerminate() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        c.systemWillSleep()
        c.releaseForTermination()
        XCTAssertTrue(a.activeIDs.isEmpty, "no dangling assertion, interrupted or not")
        XCTAssertFalse(c.isOn)
    }

    // MARK: - every automatic release names ITSELF (the disclosure signal; HUD wiring reported, not built)

    func testEachReleasePathRecordsItsReason() {
        let (c1, _, oneShot, _) = makeController()
        c1.enable(scope: .system, duration: .timed(60))
        oneShot.fireAll()
        XCTAssertEqual(c1.lastEnd, .expired, "timed expiry")

        let (c2, _, _, _) = makeController()
        c2.enable(scope: .system, duration: .whileOnAC)
        c2.powerSourceChanged(onAC: false)
        XCTAssertEqual(c2.lastEnd, .unplugged, "while-on-AC unplug")

        let (c3, _, _, _) = makeController()
        c3.enable(scope: .system, duration: .indefinite)
        c3.batteryLevelChanged(percent: 4, onAC: false)
        XCTAssertEqual(c3.lastEnd, .lowBattery, "the safety floor")

        let (c4, _, _, _) = makeController()
        c4.enable(scope: .system, duration: .indefinite)
        c4.disable()
        XCTAssertEqual(c4.lastEnd, .user, "an explicit toggle-off")

        let (c5, _, _, _) = makeController()
        c5.enable(scope: .system, duration: .indefinite)
        c5.releaseForTermination()
        XCTAssertEqual(c5.lastEnd, .terminating, "app quit")
    }

    func testDisableWhenAlreadyOffRecordsNoEnd() {
        let (c, _, _, _) = makeController()
        c.disable()
        XCTAssertNil(c.lastEnd, "nothing ended — we were already off")
    }

    func testNonFiringGuardsRecordNoEnd() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.powerSourceChanged(onAC: false)               // not a whileOnAC session
        c.batteryLevelChanged(percent: nil, onAC: false) // nil reading fails OPEN (specified)
        c.batteryLevelChanged(percent: 6, onAC: false)
        XCTAssertTrue(c.isOn, "the session survives every non-firing guard")
        XCTAssertNil(c.lastEnd, "a guard that didn't fire ended nothing")
    }

    // MARK: - remaining-time label (relative formatting; hr + min)

    func testRemainingLabelFormatsHoursAndMinutes() {
        XCTAssertEqual(KeepAwakeController.remainingLabel(1800), "30 min")
        XCTAssertEqual(KeepAwakeController.remainingLabel(3600), "1 hr")
        XCTAssertEqual(KeepAwakeController.remainingLabel(7200), "2 hr")
        XCTAssertEqual(KeepAwakeController.remainingLabel(3900), "1 hr 5 min")
        XCTAssertEqual(KeepAwakeController.remainingLabel(59), "1 min", "floors at 1 min while a session is live")
        XCTAssertEqual(KeepAwakeController.remainingLabel(0), "1 min")
    }

    // MARK: - quit releases (terminate path)

    func testReleaseForTerminationReleasesEverything() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        c.releaseForTermination()
        XCTAssertTrue(a.activeIDs.isEmpty, "the terminate path must release — no dangling assertion")
        XCTAssertFalse(c.isOn)
    }

    // MARK: - while-on-AC releases on unplug

    func testWhileOnACReleasesOnUnplug() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .system, duration: .whileOnAC)
        c.powerSourceChanged(onAC: true)                   // still plugged → unaffected
        XCTAssertTrue(c.isOn)
        XCTAssertEqual(a.activeKinds, [.systemIdle])
        c.powerSourceChanged(onAC: false)                  // unplugged → release
        XCTAssertTrue(a.activeIDs.isEmpty)
        XCTAssertFalse(c.isOn)
    }

    func testUnplugDoesNotReleaseANonACSession() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.powerSourceChanged(onAC: false)
        XCTAssertEqual(a.activeKinds, [.systemIdle], "an indefinite session ignores unplug")
        XCTAssertTrue(c.isOn)
    }

    func testTimedSessionIgnoresUnplug() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .system, duration: .timed(3600))
        c.powerSourceChanged(onAC: false)
        XCTAssertEqual(a.activeKinds, [.systemIdle], "a timed session ignores unplug (only while-on-AC reacts)")
        XCTAssertTrue(c.isOn)
    }

    // MARK: - double-enable does not stack or leak (idempotent)

    func testDoubleEnableDoesNotStackAssertions() {
        let (c, a, oneShot, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertEqual(a.activeKinds, [.systemIdle], "re-enable releases the prior set — no stacking/leak")
        XCTAssertEqual(a.created.count, 2, "two creates total")
        XCTAssertEqual(a.releasedIDs.count, 1, "the first was released before the second was created")
        XCTAssertEqual(oneShot.count, 0)
    }

    func testReEnableSwitchesScopeWithoutLeaking() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .systemAndDisplay, duration: .indefinite)   // 2 assertions
        c.enable(scope: .system, duration: .indefinite)             // re-arm to 1
        XCTAssertEqual(a.activeKinds, [.systemIdle], "switching scope leaves only the new set held")
        XCTAssertEqual(a.releasedIDs.count, 2, "both prior assertions released")
    }

    // MARK: - low-battery auto-stop (safety floor; SPEC increment 2026-06-21)

    func testBatteryUnderFloorOnBatteryReleasesSession() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        c.batteryLevelChanged(percent: 4, onAC: false)     // under 5% on battery → release
        XCTAssertNil(c.session, "a session under the floor on battery auto-releases")
        XCTAssertFalse(c.isOn)
        XCTAssertTrue(a.activeIDs.isEmpty, "the held assertions are released")
    }

    func testBatteryAtFloorOnBatteryKeepsSession() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.batteryLevelChanged(percent: 5, onAC: false)     // 5 is NOT under 5
        XCTAssertTrue(c.isOn, "at exactly the floor the session stays on")
        XCTAssertEqual(a.activeKinds, [.systemIdle])
    }

    func testBatteryAboveFloorOnBatteryKeepsSession() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.batteryLevelChanged(percent: 6, onAC: false)
        XCTAssertTrue(c.isOn, "above the floor the session stays on")
    }

    func testBatteryUnderFloorOnACIsNoOp() {
        let (c, a, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.batteryLevelChanged(percent: 4, onAC: true)      // on AC → nothing to guard
        XCTAssertTrue(c.isOn, "on AC the floor does not fire")
        XCTAssertEqual(a.activeKinds, [.systemIdle])
    }

    func testNilReadingNeverReleasesSession() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.batteryLevelChanged(percent: nil, onAC: false)   // missing reading → never drop
        XCTAssertTrue(c.isOn, "a nil reading must never silently release the session")
    }

    func testBatteryUnderFloorWhenOffIsNoOp() {
        let (c, a, _, _) = makeController()
        c.batteryLevelChanged(percent: 4, onAC: false)     // already off → no-op, no crash
        XCTAssertFalse(c.isOn)
        XCTAssertTrue(a.activeIDs.isEmpty)
    }

    func testTimedSessionAutoStoppedAtFloorInvalidatesPendingExpiry() {
        // A timed session auto-stopped by the floor must also have its pending expiry callback
        // invalidated (the generation bump via disable()), so a stale timer can't resurrect a session.
        let (c, a, oneShot, _) = makeController()
        c.enable(scope: .system, duration: .timed(3600))   // schedules an expiry
        c.batteryLevelChanged(percent: 4, onAC: false)     // floor fires → release now
        XCTAssertNil(c.session, "the floor releases the timed session")
        XCTAssertTrue(a.activeIDs.isEmpty)
        oneShot.fireAll()                                  // the now-stale expiry fires
        XCTAssertNil(c.session, "the stale expiry must not resurrect a session")
        XCTAssertFalse(c.isOn)
    }

    // MARK: - #29 orphan-backlog: the two captions that read `heldKinds` and `lastEnd`

    func testPartialHoldNoteIsSilentWhenEverythingRequestedIsHeld() {
        XCTAssertNil(KeepAwakeController.partialHoldNote(requested: .system, held: [.systemIdle]))
        XCTAssertNil(KeepAwakeController.partialHoldNote(requested: .systemAndDisplay,
                                                        held: [.systemIdle, .displayIdle]))
    }

    func testPartialHoldNoteNamesTheDisplayWhenOnlyTheDisplayKindWasLost() {
        // The case the caption exists for: `.systemAndDisplay` asked for, only the system kind obtained.
        let note = KeepAwakeController.partialHoldNote(requested: .systemAndDisplay, held: [.systemIdle])
        XCTAssertEqual(note, "the display is not being held on")
    }

    func testPartialHoldNoteFallsBackWhenTheSystemKindItselfIsMissing() {
        // Losing the system kind is a different (worse) failure and must not claim it is a display issue.
        let note = KeepAwakeController.partialHoldNote(requested: .systemAndDisplay, held: [.displayIdle])
        XCTAssertEqual(note, "not everything you asked for is being held")
        XCTAssertNotNil(KeepAwakeController.partialHoldNote(requested: .system, held: []))
    }

    func testPartialHoldNoteIsDrivenByTheLIVEControllerAfterAPartialCreateFailure() {
        // End to end through the state machine: the display kind fails to create, so `heldKinds`
        // carries only the system kind and the caption must disclose it.
        let (c, a, _, _) = makeController()
        a.failKinds = [.displayIdle]
        c.enable(scope: .systemAndDisplay, duration: .indefinite)
        XCTAssertEqual(c.heldKinds, [.systemIdle], "only the kind that actually created is held")
        let scope = try? XCTUnwrap(c.session?.scope)
        XCTAssertEqual(KeepAwakeController.partialHoldNote(requested: scope ?? .system, held: c.heldKinds),
                       "the display is not being held on")
    }

    func testLastEndNoteIsSilentForSelfEvidentEndings() {
        XCTAssertNil(KeepAwakeController.lastEndNote(nil), "before any session there is nothing to tell")
        XCTAssertNil(KeepAwakeController.lastEndNote(.user), "you turned it off; saying so is noise")
        XCTAssertNil(KeepAwakeController.lastEndNote(.terminating), "you quit the app")
    }

    func testLastEndNoteSpeaksForEveryEndingThatHappenedTOTheSession() {
        for reason in [KeepAwakeController.EndReason.activationFailed, .expired, .unplugged, .lowBattery] {
            XCTAssertNotNil(KeepAwakeController.lastEndNote(reason),
                            "\(reason) is invisible to the owner unless the caption says it")
        }
        XCTAssertTrue(KeepAwakeController.lastEndNote(.lowBattery)?
            .contains("\(KeepAwakeController.lowBatteryFloorPercent)%") ?? false,
                      "the floor note must quote the actual floor, not a hardcoded number")
    }

    func testLastEndNoteRendersTheReasonTheLIVEControllerRecordedForAnUnplug() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .whileOnAC)
        c.powerSourceChanged(onAC: false)                  // the AC session loses AC
        XCTAssertFalse(c.isOn)
        XCTAssertEqual(c.lastEnd, .unplugged)
        XCTAssertEqual(KeepAwakeController.lastEndNote(c.lastEnd),
                       "Last session ended when you unplugged.")
    }

    // MARK: - the lid: the promise the feature CANNOT keep, said at the point of use
    //
    // Measured (audit 2026-09 §2.D / §2.D.1): the two assertions we hold are idle-sleep only.
    // `PreventSystemSleep` is granted to the process but never enters the system aggregate on battery,
    // and `AppliesToLimitedPower` is refused with kIOReturnBadArgument both at create and via
    // IOPMAssertionSetProperty. There is no safe lid-close mechanism left, so the fix is COPY: the
    // toggle must say what it guarantees AND what closing the lid does, or the owner loses a download
    // and never learns why.

    func testCoverageNoteLeadsWithWhatIsActuallyGuaranteed() {
        let note = KeepAwakeController.coverageNote
        XCTAssertTrue(note.hasPrefix("Keeps running with the lid open"),
                      "the true half comes first — the copy is not an apology")
        XCTAssertTrue(note.contains("screen locks"),
                      "locking the screen never stopped background work; say so, it is the useful half")
    }

    func testCoverageNoteNamesTheLidCloseLimitAndItsConsequence() {
        let note = KeepAwakeController.coverageNote
        XCTAssertTrue(note.contains("Closing the lid sleeps your Mac"),
                      "the one thing a user will actually try must be named, not implied")
        XCTAssertTrue(note.contains("stops there"),
                      "name the CONSEQUENCE (the job dies), not just the mechanism")
        XCTAssertFalse(note.lowercased().contains("sorry"), "plain and specific, never apologetic")
    }

    // MARK: - the interruption reader: `wasInterrupted` had no screen (the project's silent-failure class)

    func testInterruptionNoteIsSilentUntilTheClaimHasActuallyBeenBroken() {
        XCTAssertNil(KeepAwakeController.interruptionNote(0),
                     "an unbroken session says nothing — this is not a nag")
        XCTAssertNil(KeepAwakeController.interruptionNote(-1), "a nonsense count is still silence")
    }

    func testInterruptionNoteCountsTheBrokenPromisesInPlainWords() {
        let one = KeepAwakeController.interruptionNote(1)
        XCTAssertEqual(one?.hasPrefix("Your Mac slept once while this was on"), true)
        let three = KeepAwakeController.interruptionNote(3)
        XCTAssertEqual(three?.hasPrefix("Your Mac slept 3 times while this was on"), true)
        XCTAssertTrue(one?.contains("stopped there") ?? false,
                      "say what it cost the owner, not merely that an event occurred")
    }

    func testInterruptionNoteNamesTheLidAsTheLikelyCause() {
        // The whole point of surfacing this: the user shut the lid, lost the job, and the badge was
        // still steaming on wake. The note has to connect those two facts.
        XCTAssertTrue(KeepAwakeController.interruptionNote(1)?.contains("closed lid") ?? false)
    }

    func testInterruptionNoteIsDrivenByTheLIVEControllerAcrossARealSleep() {
        // End to end through the state machine — the reader the audit says did not exist.
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertNil(KeepAwakeController.interruptionNote(c.session?.sleepInterruptions ?? 0),
                     "a fresh session has nothing to disclose")
        c.systemWillSleep()
        XCTAssertTrue(c.isInterrupted)
        XCTAssertNotNil(KeepAwakeController.interruptionNote(c.session?.sleepInterruptions ?? 0),
                        "the machine slept through a held session — the surface must have a string for it")
    }

    func testInterruptionNoteClearsWithTheNextFreshSession() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.systemWillSleep()
        c.enable(scope: .system, duration: .indefinite)      // a new claim starts clean
        XCTAssertNil(KeepAwakeController.interruptionNote(c.session?.sleepInterruptions ?? 0),
                     "a new session must not inherit the last one's broken promise")
    }

    // MARK: - the REAL sleep timers (`pmset -g custom`) — the parser

    /// Verbatim `pmset -g custom` from this machine (M4 Max, macOS 27.0, 2026-09-08). The two
    /// numbers the whole finding turns on: AC `sleep 0`, battery `sleep 1` / `displaysleep 10`.
    private static let realPmsetCustom = """
    Battery Power:
     Sleep On Power Button 1
     powermode            0
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             0
     hibernatefile        /var/vm/sleepimage
     displaysleep         10
     womp                 1
     networkoversleep     0
     sleep                1
     lessbright           1
     tcpkeepalive         1
     disksleep            10
     SleepServices        0
    AC Power:
     Sleep On Power Button 1
     powermode            0
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             0
     hibernatefile        /var/vm/sleepimage
     displaysleep         20
     womp                 1
     networkoversleep     0
     sleep                0
     tcpkeepalive         1
     disksleep            10
     SleepServices        0
    """

    func testParsesBothProfilesFromRealPmsetOutput() {
        let s = SleepTimerReader.parse(Self.realPmsetCustom)
        XCTAssertEqual(s.battery.systemMinutes, 1)
        XCTAssertEqual(s.battery.displayMinutes, 10)
        XCTAssertEqual(s.charger.systemMinutes, 0, "AC sleep 0 = never idle-sleeps — the whole finding")
        XCTAssertEqual(s.charger.displayMinutes, 20)
    }

    func testParserNeverConfusesSleepWithItsNeighbouringKeys() {
        // `disksleep`, `displaysleep`, `ttyskeepawake` and `Sleep On Power Button` all live in the same
        // block; a hasPrefix("sleep") match would be wrong for three of them.
        let s = SleepTimerReader.parse("""
        Battery Power:
         Sleep On Power Button 1
         ttyskeepawake        1
         disksleep            77
         displaysleep         10
         sleep                5
        """)
        XCTAssertEqual(s.battery.systemMinutes, 5, "the WHOLE token must be `sleep`, not a prefix of it")
        XCTAssertEqual(s.battery.displayMinutes, 10)
    }

    func testAProfileWithNoValuesNeverBorrowsTheOthers() {
        let s = SleepTimerReader.parse("""
        Battery Power:
         sleep                3
         displaysleep         4
        AC Power:
         powermode            0
        """)
        XCTAssertEqual(s.battery.systemMinutes, 3)
        XCTAssertNil(s.charger.systemMinutes, "an unread profile stays nil — it must never guess")
        XCTAssertNil(s.charger.displayMinutes)
    }

    func testGarbledAndHeaderlessLinesAreIgnoredRatherThanGuessed() {
        let s = SleepTimerReader.parse("""
         sleep                9
        Battery Power:
         sleep                banana
         displaysleep         -3
        """)
        XCTAssertNil(s.battery.systemMinutes, "a non-integer value is not a reading")
        XCTAssertNil(s.battery.displayMinutes, "a negative minute count is not a reading")
        XCTAssertNil(s.charger.systemMinutes, "a key before any profile header belongs to no profile")
    }

    func testEmptyOutputIsUnknownNotZero() {
        // `0` means "never idle-sleeps" to macOS. Decoding a failed read as 0 would make the app
        // announce the exact opposite of the truth, so unreadable must stay nil.
        XCTAssertEqual(SleepTimerReader.parse(""), SleepTimerSettings.unknown)
    }

    // MARK: - effectiveSystemSleepMinutes (powerd's "prevent sleep while display is on")

    func testEffectiveIdleSleepIsNotTheRawSleepValueWhenTheDisplayOutlastsIt() {
        // This machine on battery: sleep 1, displaysleep 10. powerd holds
        // "Prevent sleep while display is on", so the Mac idle-sleeps at ~10 min, NOT at 1.
        let t = SleepTimers(systemMinutes: 1, displayMinutes: 10)
        XCTAssertEqual(t.effectiveSystemSleepMinutes, 10,
                       "quoting the raw 1 at the user would be flatly wrong")
    }

    func testEffectiveIdleSleepIsTheSleepValueWhenItOutlastsTheDisplay() {
        XCTAssertEqual(SleepTimers(systemMinutes: 30, displayMinutes: 10).effectiveSystemSleepMinutes, 30)
    }

    func testSleepZeroMeansNeverIdleSleeps() {
        XCTAssertNil(SleepTimers(systemMinutes: 0, displayMinutes: 20).effectiveSystemSleepMinutes)
    }

    func testADisplayThatNeverSleepsMeansTheSystemNeverIdleSleepsEither() {
        // powerd's assertion never drops, so the system sleep timer can never elapse.
        XCTAssertNil(SleepTimers(systemMinutes: 5, displayMinutes: 0).effectiveSystemSleepMinutes)
    }

    func testAnUnknownDisplayTimerFallsBackToTheRawSleepValue() {
        XCTAssertEqual(SleepTimers(systemMinutes: 5, displayMinutes: nil).effectiveSystemSleepMinutes, 5)
    }

    func testUnknownTimersProduceNoEffectiveValue() {
        XCTAssertNil(SleepTimers.unknown.effectiveSystemSleepMinutes)
    }

    func testTimersPicksTheProfileForTheCurrentPowerSource() {
        let s = SleepTimerReader.parse(Self.realPmsetCustom)
        XCTAssertEqual(s.timers(onAC: true).systemMinutes, 0)
        XCTAssertEqual(s.timers(onAC: false).systemMinutes, 1)
    }

    // MARK: - isInert: does the toggle prevent anything that was going to happen?

    func testSystemScopeIsInertOnACWhenTheMacNeverIdleSleeps() {
        // THE FINDING. AC `sleep 0` ⇒ PreventUserIdleSystemSleep prevents nothing.
        let ac = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: true)
        XCTAssertTrue(KeepAwakeController.isInert(scope: .system, timers: ac))
    }

    func testDisplayScopeIsNOTInertOnACBecauseDisplaysleepIsASeparateNonZeroTimer() {
        // The half of the finding that does NOT survive contact with the real settings: AC
        // `displaysleep 20` is live, so the display assertion still does real work on power.
        let ac = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: true)
        XCTAssertFalse(KeepAwakeController.isInert(scope: .systemAndDisplay, timers: ac),
                       "the display half is not inert on AC — displaysleep is a separate timer")
    }

    func testNothingIsInertOnBatteryWhereTheMacDoesIdleSleep() {
        let batt = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: false)
        XCTAssertFalse(KeepAwakeController.isInert(scope: .system, timers: batt))
        XCTAssertFalse(KeepAwakeController.isInert(scope: .systemAndDisplay, timers: batt))
    }

    func testBothScopesAreInertWhenNeitherTimerCanEverFire() {
        let t = SleepTimers(systemMinutes: 0, displayMinutes: 0)
        XCTAssertTrue(KeepAwakeController.isInert(scope: .system, timers: t))
        XCTAssertTrue(KeepAwakeController.isInert(scope: .systemAndDisplay, timers: t))
    }

    func testUnknownTimersAreNeverCalledInert() {
        // Never accuse the toggle of doing nothing on a reading we do not have.
        XCTAssertFalse(KeepAwakeController.isInert(scope: .system, timers: nil))
        XCTAssertFalse(KeepAwakeController.isInert(scope: .system, timers: .unknown))
        XCTAssertFalse(KeepAwakeController.isInert(scope: .systemAndDisplay,
                                                   timers: SleepTimers(systemMinutes: 0, displayMinutes: nil)))
    }

    // MARK: - the live effect clause: what the toggle achieves ON THIS POWER SOURCE, right now

    func testEffectClauseOnACSaysTheSystemHalfChangesNothingAndPointsAtTheDisplayFix() {
        let ac = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: true)
        let s = KeepAwakeController.sleepTimerClause(scope: .system, onAC: true, timers: ac)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("on power"), "the claim is scoped to the CURRENT power source")
        XCTAssertTrue(s!.contains("never idle-sleeps"), "say the setting that makes this inert")
        XCTAssertTrue(s!.contains("Keep the display on too"),
                      "an inert toggle must name the one-tap thing that isn't inert")
        XCTAssertTrue(s!.contains("20 min"), "quote the real displaysleep value, not a guess")
    }

    func testEffectClauseOnACWithDisplayScopeClaimsOnlyTheDisplay() {
        let ac = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: true)
        let s = KeepAwakeController.sleepTimerClause(scope: .systemAndDisplay, onAC: true, timers: ac)!
        XCTAssertTrue(s.contains("never idle-sleeps"))
        XCTAssertTrue(s.contains("keep the display on"),
                      "on AC the display half is the ONLY thing this buys — say so")
        XCTAssertTrue(s.contains("20 min"))
    }

    func testEffectClauseOnBatteryQuotesTheEFFECTIVEIdleSleepNotTheRawSleepValue() {
        let batt = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: false)   // sleep 1, display 10
        let s = KeepAwakeController.sleepTimerClause(scope: .system, onAC: false, timers: batt)!
        XCTAssertTrue(s.contains("on battery"))
        XCTAssertTrue(s.contains("10 min"), "the Mac idle-sleeps at max(sleep, displaysleep)")
        XCTAssertFalse(s.contains("1 min"), "the raw `sleep 1` is NOT when the Mac actually sleeps")
    }

    func testEffectClauseOnBatteryWithDisplayScopeClaimsBoth() {
        let batt = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: false)
        let s = KeepAwakeController.sleepTimerClause(scope: .systemAndDisplay, onAC: false, timers: batt)!
        XCTAssertTrue(s.contains("stops both"))
    }

    func testEffectClauseIsSilentWhenTheTimersWereNeverRead() {
        // No reading ⇒ no claim. The static coverage note still carries the guarantee.
        XCTAssertNil(KeepAwakeController.sleepTimerClause(scope: .system, onAC: true, timers: nil))
        XCTAssertNil(KeepAwakeController.sleepTimerClause(scope: .system, onAC: true, timers: .unknown))
    }

    // MARK: - the cost clause (knowledge/09-MEASURE-keepawake-cost.md)

    func testCostClauseOnBatteryStatesTheMeasuredFloorAndTheSleepBaseline() {
        let s = KeepAwakeController.energyCostClause(onAC: false)!
        XCTAssertTrue(s.contains("at least"), "the number is a FLOOR, and must be framed as one")
        XCTAssertTrue(s.contains("6%"), "the measured marginal idle cost, rounded down")
        XCTAssertTrue(s.contains("3%"), "the counterfactual: what the same hours cost asleep")
    }

    func testCostClauseOnACIsAboutWhatUnpluggingWouldCostNotAPresentDrain() {
        // Measured: there is no system-draw telemetry at all on AC (macOS 27 ChargerData reads 0), and
        // holding a Mac awake on mains costs no battery. The honest AC framing is conditional.
        let s = KeepAwakeController.energyCostClause(onAC: true)!
        XCTAssertTrue(s.contains("unplug"), "on power the cost is contingent, not current")
        XCTAssertTrue(s.contains("6%"))
    }

    func testNoCostNumberIsEverAttachedToTheDisplayScope() {
        // The measurement could NOT price the display half (4 minutes of awake-with-screen-off in 14
        // days). Neither clause may imply it did.
        let batt = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: false)
        for scope in [KeepAwakeController.Scope.system, .systemAndDisplay] {
            let note = KeepAwakeController.liveEffectNote(scope: scope, onAC: false, timers: batt)!
            XCTAssertEqual(note.components(separatedBy: "6%").count - 1, 1,
                           "exactly one cost figure, and it prices NOT SLEEPING — never the display")
        }
    }

    // MARK: - liveEffectNote: the composed paragraph the popover renders

    func testLiveEffectNoteJoinsWhatItDoesWithWhatItCosts() {
        let batt = SleepTimerReader.parse(Self.realPmsetCustom).timers(onAC: false)
        let note = KeepAwakeController.liveEffectNote(scope: .system, onAC: false, timers: batt)!
        XCTAssertTrue(note.contains("10 min"), "the effect half")
        XCTAssertTrue(note.contains("at least"), "the cost half")
    }

    func testLiveEffectNoteStillCarriesTheCostWhenTheTimersCouldNotBeRead() {
        // A failed pmset read must not also swallow the cost disclosure — they are independent facts.
        let note = KeepAwakeController.liveEffectNote(scope: .system, onAC: false, timers: nil)
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("6%"))
    }

    // MARK: - the reader seam: cached, off the main thread, never on a timer

    /// Deterministic stand-in for the `pmset` spawn; counts calls so the cache can be pinned.
    final class FakeSleepTimerReader: SleepTimerReading, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        let settings: SleepTimerSettings
        init(_ settings: SleepTimerSettings) { self.settings = settings }
        func readSleepTimers() -> SleepTimerSettings {
            lock.lock(); n += 1; lock.unlock()
            return settings
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeControllerWithTimers(_ settings: SleepTimerSettings)
    -> (KeepAwakeController, FakeSleepTimerReader, MockClockBox) {
        let reader = FakeSleepTimerReader(settings)
        let box = MockClockBox(0)
        let c = KeepAwakeController(assertion: MockSleepAssertion(), scheduler: MockOneShot(),
                                    clock: MockMonotonicClock(box: box), sleepTimerReader: reader,
                                    presetStore: KeepAwakePresetStore(defaults: isolatedDefaults))
        return (c, reader, box)
    }

    func testSleepTimersAreUnreadUntilSomethingAsksForThem() {
        let (c, reader, _) = makeControllerWithTimers(.unknown)
        XCTAssertNil(c.sleepTimers, "nothing is read at construction — no spawn on app launch")
        c.enable(scope: .system, duration: .indefinite)
        XCTAssertEqual(reader.calls, 0, "the state machine itself never spawns a subprocess")
    }

    func testRefreshReadsOnceAndPublishesTheTimers() async {
        let real = SleepTimerReader.parse(Self.realPmsetCustom)
        let (c, reader, _) = makeControllerWithTimers(real)
        await c.refreshSleepTimers()
        XCTAssertEqual(reader.calls, 1)
        XCTAssertEqual(c.sleepTimers, real)
    }

    func testRepeatedRefreshesInsideTheCacheWindowDoNotRespawn() async {
        // Audit A11/A12: a subprocess spawn per popover open is a finding this project has already
        // fixed twice. Re-opening the disclosure must NOT be a third.
        let (c, reader, box) = makeControllerWithTimers(.unknown)
        await c.refreshSleepTimers()
        box.now = KeepAwakeController.sleepTimerCacheSeconds - 1
        await c.refreshSleepTimers()
        await c.refreshSleepTimers()
        XCTAssertEqual(reader.calls, 1, "one spawn, cached — this is a rarely-changing setting")
    }

    func testTheCacheExpiresSoAChangedSettingIsPickedUp() async {
        let (c, reader, box) = makeControllerWithTimers(.unknown)
        await c.refreshSleepTimers()
        box.now = KeepAwakeController.sleepTimerCacheSeconds + 1
        await c.refreshSleepTimers()
        XCTAssertEqual(reader.calls, 2, "the user can change this in System Settings at any time")
    }

    func testTheLIVEControllerComposesTheNoteFromTheTimersItRead() async {
        // End to end: read the seam, then render the claim the popover shows on AC.
        let (c, _, _) = makeControllerWithTimers(SleepTimerReader.parse(Self.realPmsetCustom))
        await c.refreshSleepTimers()
        let note = KeepAwakeController.liveEffectNote(scope: .system, onAC: true,
                                                      timers: c.sleepTimers?.timers(onAC: true))!
        XCTAssertTrue(note.contains("never idle-sleeps"))
        XCTAssertTrue(note.contains("Keep the display on too"))
    }

    // MARK: - #30 §14-C7: the last-used preset (keepAwake.lastPreset.v1)

    func testPresetStoreDefaultIsIndefiniteSystem() {
        let store = KeepAwakePresetStore(defaults: isolatedDefaults)
        XCTAssertEqual(store.load(), .default)
        XCTAssertEqual(KeepAwakePreset.default, KeepAwakePreset(duration: .indefinite, scope: .system))
    }

    func testPresetStoreRoundTripsEveryDurationAndScope() {
        let store = KeepAwakePresetStore(defaults: isolatedDefaults)
        let durations: [KeepAwakeController.Duration] = [.indefinite, .timed(1800), .timed(3600.5), .whileOnAC]
        let scopes: [KeepAwakeController.Scope] = [.system, .systemAndDisplay]
        for d in durations { for sc in scopes {
            let p = KeepAwakePreset(duration: d, scope: sc)
            store.save(p)
            XCTAssertEqual(store.load(), p)
        } }
        XCTAssertNotNil(isolatedDefaults.data(forKey: "keepAwake.lastPreset.v1"), "stored under the versioned key")
        store.clear()
        XCTAssertEqual(store.load(), .default)
    }

    func testPresetStoreTolerantDecode() {
        let store = KeepAwakePresetStore(defaults: isolatedDefaults)
        isolatedDefaults.set(Data("garbage".utf8), forKey: "keepAwake.lastPreset.v1")
        XCTAssertEqual(store.load(), .default)
        isolatedDefaults.set(Data("{\"duration\":{\"bogus\":{}},\"scope\":{\"system\":{}}}".utf8), forKey: "keepAwake.lastPreset.v1")
        XCTAssertEqual(store.load(), .default, "an unknown case → default, never a crash")
        isolatedDefaults.set(42, forKey: "keepAwake.lastPreset.v1")
        XCTAssertEqual(store.load(), .default, "wrong storage type → default")
    }

    func testEnableWritesThePresetEveryTimeAndExposesIt() {
        let (c, _, _, _) = makeController()
        XCTAssertEqual(c.lastPreset, .default, "nothing persisted → default")
        c.enable(scope: .systemAndDisplay, duration: .timed(3600))
        XCTAssertEqual(c.lastPreset, KeepAwakePreset(duration: .timed(3600), scope: .systemAndDisplay))
        XCTAssertEqual(KeepAwakePresetStore(defaults: isolatedDefaults).load(), c.lastPreset, "persisted on enable")
        c.enable(scope: .system, duration: .whileOnAC)
        XCTAssertEqual(c.lastPreset, KeepAwakePreset(duration: .whileOnAC, scope: .system))
        // A fresh controller over the same defaults starts from the persisted preset (survives relaunch).
        let (c2, _, _, _) = makeController()
        XCTAssertEqual(c2.lastPreset, KeepAwakePreset(duration: .whileOnAC, scope: .system))
    }

    func testFailedActivationStillRecordsTheAskedForPreset() {
        let (c, assertion, _, _) = makeController()
        assertion.failKinds = [.systemIdle, .displayIdle]
        c.enable(scope: .systemAndDisplay, duration: .timed(60))
        XCTAssertFalse(c.isOn)
        XCTAssertEqual(c.lastPreset, KeepAwakePreset(duration: .timed(60), scope: .systemAndDisplay),
                       "what the user asked for is recorded regardless of outcome")
    }

    func testSetScopeDoesNotRewriteThePreset() {
        let (c, _, _, _) = makeController()
        c.enable(scope: .system, duration: .indefinite)
        c.setScope(.systemAndDisplay)
        XCTAssertEqual(c.lastPreset, KeepAwakePreset(duration: .indefinite, scope: .system),
                       "only enable() writes the preset (spec: written on every enable)")
    }
}
