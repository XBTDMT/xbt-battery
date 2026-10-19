import XCTest
@testable import Battery

/// Sprint 4.4: the pure event-derivation layer that maps OBSERVED outcomes (telemetry state, the
/// engine's `lastCommandSource`, top-up phase, command status) to a `NotificationEvent` with its
/// cause. This is where the spine's user-vs-autonomous split is decided per event type. The
/// coordinator just feeds transitions in; all the judgement is here and is host-app-free.
final class NotificationEventsTests: XCTestCase {

    // MARK: fully charged — reuses the display-layer proxy (.unknown on AC at SoC ≥ 99). Autonomous.

    func testFullyChargedMatchesDisplayProxy() {
        XCTAssertEqual(NotificationEvents.fullyCharged(onAC: true, soc: 100, state: .unknown)?.cause, .autonomous)
        XCTAssertEqual(NotificationEvents.fullyCharged(onAC: true, soc: 100, state: .unknown)?.kind, .fullyCharged)
        XCTAssertNotNil(NotificationEvents.fullyCharged(onAC: true, soc: 99, state: .unknown))   // ≥ 99 boundary
    }

    func testFullyChargedNegatives() {
        XCTAssertNil(NotificationEvents.fullyCharged(onAC: true, soc: 98, state: .unknown))      // below threshold
        XCTAssertNil(NotificationEvents.fullyCharged(onAC: false, soc: 100, state: .unknown))    // on battery
        XCTAssertNil(NotificationEvents.fullyCharged(onAC: true, soc: 100, state: .charging))    // classifier not idle
        XCTAssertNil(NotificationEvents.fullyCharged(onAC: true, soc: 100, state: .limitHold))   // holding, not "full"
        XCTAssertNil(NotificationEvents.fullyCharged(onAC: true, soc: nil, state: .unknown))     // no reading
    }

    // MARK: limit reached — cause follows WHO set the limit (the spine).

    func testLimitReachedCauseFollowsSource() {
        XCTAssertEqual(NotificationEvents.limitReached(entered: .limitHold, limit: 80, source: .user)?.cause, .userAction)
        XCTAssertEqual(NotificationEvents.limitReached(entered: .limitHold, limit: 80, source: .schedule)?.cause, .autonomous)
        XCTAssertEqual(NotificationEvents.limitReached(entered: .limitHold, limit: 80, source: .topUp)?.cause, .autonomous)
        XCTAssertEqual(NotificationEvents.limitReached(entered: .limitHold, limit: 80, source: .schedule)?.kind, .limitReached(80))
    }

    func testLimitReachedOnlyOnHoldWithKnownLimit() {
        XCTAssertNil(NotificationEvents.limitReached(entered: .charging, limit: 80, source: .schedule))
        XCTAssertNil(NotificationEvents.limitReached(entered: .limitHold, limit: nil, source: .schedule))
    }

    // MARK: top-up complete — ONLY a .topUp revert that actually REACHED 100% (honesty, SPEC sec 4).

    func testTopUpCompleteOnlyForFullTopUpRevert() {
        // Genuine full completion (reached 100 on AC, .topUp revert) → event.
        let e = NotificationEvents.topUpComplete(source: .topUp, restoredLimit: 80, reachedFull: true)
        XCTAssertEqual(e?.kind, .topUpComplete(restored: 80))
        XCTAssertEqual(e?.cause, .autonomous)
        // Abort reverts (unplug / TTL / cancel) did NOT reach 100 → no dishonest "Topped up to 100%".
        XCTAssertNil(NotificationEvents.topUpComplete(source: .topUp, restoredLimit: 80, reachedFull: false))
        // Non-topUp sources never produce it.
        XCTAssertNil(NotificationEvents.topUpComplete(source: .user, restoredLimit: 80, reachedFull: true))
        XCTAssertNil(NotificationEvents.topUpComplete(source: .schedule, restoredLimit: 80, reachedFull: true))
        XCTAssertNil(NotificationEvents.topUpComplete(source: .topUp, restoredLimit: nil, reachedFull: true))
    }

    // MARK: scheduled applied — ONLY a .schedule-sourced change. Autonomous.

    func testScheduledAppliedOnlyForScheduleSource() {
        let e = NotificationEvents.scheduledApplied(source: .schedule, limit: 70)
        XCTAssertEqual(e?.kind, .scheduledApplied(70))
        XCTAssertEqual(e?.cause, .autonomous)
        XCTAssertNil(NotificationEvents.scheduledApplied(source: .user, limit: 70))
        XCTAssertNil(NotificationEvents.scheduledApplied(source: .topUp, limit: 70))
    }

    // MARK: low battery — discharging at or below the CONFIGURED threshold. Autonomous.

    func testLowBatteryFiresAtOrBelowConfiguredThreshold() {
        // threshold 20: fires at 20 and at 15, silent at 21
        XCTAssertEqual(NotificationEvents.lowBattery(state: .discharging, soc: 20, threshold: 20)?.kind, .lowBattery(20))
        XCTAssertEqual(NotificationEvents.lowBattery(state: .discharging, soc: 20, threshold: 20)?.cause, .autonomous)
        XCTAssertNotNil(NotificationEvents.lowBattery(state: .discharging, soc: 15, threshold: 20), "below the threshold fires")
        XCTAssertNil(NotificationEvents.lowBattery(state: .discharging, soc: 21, threshold: 20), "above the configured threshold stays silent")
        // threshold 10: fires at 10, silent at 11
        XCTAssertNotNil(NotificationEvents.lowBattery(state: .discharging, soc: 10, threshold: 10))
        XCTAssertNil(NotificationEvents.lowBattery(state: .discharging, soc: 11, threshold: 10))
    }

    func testLowBatteryNoFireOnACOrNilReading() {
        XCTAssertNil(NotificationEvents.lowBattery(state: .charging, soc: 5, threshold: 20), "not discharging stays silent even below threshold")
        XCTAssertNil(NotificationEvents.lowBattery(state: .discharging, soc: nil, threshold: 20), "a nil reading never fires")
    }

    // MARK: app-intent source — autonomous by the safe default (Phase 5 #17). Locked.

    func testLimitReachedAppIntentSourceIsAutonomous() {
        // cause(of:) returns .autonomous for anything that is not .user, so an App Intent set is
        // autonomous (a Siri/automation set is not an in-app action the person watched). Locks the
        // safe-default mapping for the new .appIntent case (spec sec 3).
        let e = NotificationEvents.limitReached(entered: .limitHold, limit: 80, source: .appIntent)
        XCTAssertEqual(e?.cause, .autonomous)
        XCTAssertEqual(e?.kind, .limitReached(80))
    }

    // MARK: setup / automation problem — only broken-control statuses, not transient command errors.

    func testSetupProblemForBrokenControlClasses() {
        XCTAssertEqual(NotificationEvents.setupProblem(status: .setupRequired)?.kind, .setupProblem)
        XCTAssertEqual(NotificationEvents.setupProblem(status: .setupRequired)?.cause, .autonomous)
        XCTAssertNotNil(NotificationEvents.setupProblem(status: .error(.automationBlocked)))
        XCTAssertNotNil(NotificationEvents.setupProblem(status: .error(.shortcutsBinaryAbsent)))
        XCTAssertNotNil(NotificationEvents.setupProblem(status: .error(.launchFailed)))
    }

    func testSetupProblemIgnoresTransientAndHealthyStatuses() {
        XCTAssertNil(NotificationEvents.setupProblem(status: .confirmedStop))
        XCTAssertNil(NotificationEvents.setupProblem(status: .idle))
        XCTAssertNil(NotificationEvents.setupProblem(status: .error(.limitMismatchAfterSet)))   // transient
        XCTAssertNil(NotificationEvents.setupProblem(status: .error(.telemetryReadFailure)))    // degraded read, not broken
    }

    // MARK: spine end-to-end — same event, opposite outcomes through the real decision layer.

    func testSpineUserSetLimitStaysSilentButScheduleNotifies() {
        var prefs = NotificationPrefs.defaults
        prefs.masterEnabled = true
        prefs.limitReached = true   // opt in so only the cause differs
        let now = Date(timeIntervalSinceReferenceDate: 0)

        let userEvent = NotificationEvents.limitReached(entered: .limitHold, limit: 80, source: .user)!
        let scheduleEvent = NotificationEvents.limitReached(entered: .limitHold, limit: 80, source: .schedule)!

        XCTAssertNil(NotificationDecision.shouldNotify(event: userEvent, prefs: prefs, lastNotified: [:], now: now))
        XCTAssertNotNil(NotificationDecision.shouldNotify(event: scheduleEvent, prefs: prefs, lastNotified: [:], now: now))
    }
}
