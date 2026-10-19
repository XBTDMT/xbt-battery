import XCTest
@testable import Battery

/// Sprint 4.4 (SPEC sec 3 + sec 5): the PURE NOTIFY decision layer.
/// `shouldNotify(event, prefs, lastNotified, now) -> NotificationPlan?` is the whole logic spine:
/// master gate, the never-notify-for-a-user-action rule, per-event toggles, and per-event-type
/// cooldown/de-dupe. No I/O, no UNUserNotificationCenter — host-app-free.
final class NotificationDecisionTests: XCTestCase {

    /// The SPEC sec 2 defaults with the master flipped ON (the per-event defaults then apply).
    private func masterOn() -> NotificationPrefs {
        var p = NotificationPrefs.defaults
        p.masterEnabled = true
        return p
    }

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func autonomous(_ kind: NotificationKind) -> NotificationEvent {
        NotificationEvent(kind: kind, cause: .autonomous)
    }

    // MARK: master + spine

    func testMasterOffSuppressesEverything() {
        // Master default OFF (sec 1): even a fully-enabled-by-default autonomous event stays silent.
        let plan = NotificationDecision.shouldNotify(
            event: autonomous(.fullyCharged), prefs: .defaults, lastNotified: [:], now: now)
        XCTAssertNil(plan)
    }

    func testUserInitiatedActionNeverNotifies() {
        // The SPINE: a purely user-initiated in-app action never pings, even with master + toggle on.
        var prefs = masterOn(); prefs.limitReached = true
        let plan = NotificationDecision.shouldNotify(
            event: NotificationEvent(kind: .limitReached(80), cause: .userAction),
            prefs: prefs, lastNotified: [:], now: now)
        XCTAssertNil(plan)
    }

    func testAutonomousSameEventDoesNotify() {
        // Same event, autonomous cause (schedule/top-up/hardware): DOES notify.
        var prefs = masterOn(); prefs.limitReached = true
        let plan = NotificationDecision.shouldNotify(
            event: NotificationEvent(kind: .limitReached(80), cause: .autonomous),
            prefs: prefs, lastNotified: [:], now: now)
        XCTAssertNotNil(plan)
    }

    // MARK: per-event toggles + SPEC defaults

    func testPerEventToggleOffSuppresses() {
        var prefs = masterOn(); prefs.fullyCharged = false
        XCTAssertNil(NotificationDecision.shouldNotify(
            event: autonomous(.fullyCharged), prefs: prefs, lastNotified: [:], now: now))
    }

    func testFullyChargedDefaultOnNotifies() {
        let plan = NotificationDecision.shouldNotify(
            event: autonomous(.fullyCharged), prefs: masterOn(), lastNotified: [:], now: now)
        XCTAssertNotNil(plan)
    }

    func testLimitReachedDefaultOffHonored() {
        // sec 2: charge-limit-reached default OFF (chatty) — silent even autonomous, until opted in.
        XCTAssertNil(NotificationDecision.shouldNotify(
            event: autonomous(.limitReached(80)), prefs: masterOn(), lastNotified: [:], now: now))
    }

    func testLowBatteryDefaultOffHonored() {
        // sec 2: low-battery default OFF (macOS already warns).
        XCTAssertNil(NotificationDecision.shouldNotify(
            event: autonomous(.lowBattery(8)), prefs: masterOn(), lastNotified: [:], now: now))
    }

    func testSetupProblemDefaultOnNotifies() {
        // sec 2: setup/automation-problem default ON (a silently broken control is worse than a ping).
        XCTAssertNotNil(NotificationDecision.shouldNotify(
            event: autonomous(.setupProblem), prefs: masterOn(), lastNotified: [:], now: now))
    }

    func testTopUpCompleteDefaultOnCarriesRestoredLimit() {
        let plan = NotificationDecision.shouldNotify(
            event: autonomous(.topUpComplete(restored: 80)), prefs: masterOn(), lastNotified: [:], now: now)
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan?.body.contains("80") == true)
    }

    func testScheduledAppliedDefaultOnNotifies() {
        XCTAssertNotNil(NotificationDecision.shouldNotify(
            event: autonomous(.scheduledApplied(70)), prefs: masterOn(), lastNotified: [:], now: now))
    }

    // MARK: cooldown / de-dupe (fully-charged once per session)

    func testFullyChargedDeDupedWithinCooldown() {
        let key = NotificationDecision.cooldownKey(for: .fullyCharged)
        let cd = NotificationDecision.cooldown(for: .fullyCharged)
        let ledger = [key: now.addingTimeInterval(-(cd - 1))]   // fired just inside the window
        XCTAssertNil(NotificationDecision.shouldNotify(
            event: autonomous(.fullyCharged), prefs: masterOn(), lastNotified: ledger, now: now))
    }

    func testCooldownExpiryAllowsRefire() {
        let key = NotificationDecision.cooldownKey(for: .fullyCharged)
        let cd = NotificationDecision.cooldown(for: .fullyCharged)
        let ledger = [key: now.addingTimeInterval(-(cd + 1))]   // window elapsed (or session re-armed)
        XCTAssertNotNil(NotificationDecision.shouldNotify(
            event: autonomous(.fullyCharged), prefs: masterOn(), lastNotified: ledger, now: now))
    }

    func testDistinctKindsDoNotShareCooldown() {
        // A recent fully-charged must not suppress a setup-problem (different cooldown key).
        let ledger = [NotificationDecision.cooldownKey(for: .fullyCharged): now]
        XCTAssertNotNil(NotificationDecision.shouldNotify(
            event: autonomous(.setupProblem), prefs: masterOn(), lastNotified: ledger, now: now))
    }

    func testPerEventCooldownDurations() {
        // Pin the documented per-event-type cooldowns (SPEC sec 6: "tested per event type") so a
        // refactor can't silently shorten them. fully-charged is the long session-latch backstop.
        XCTAssertEqual(NotificationDecision.cooldown(for: .fullyCharged), 3600)
        XCTAssertEqual(NotificationDecision.cooldown(for: .limitReached(80)), 1800)
        XCTAssertEqual(NotificationDecision.cooldown(for: .topUpComplete(restored: 80)), 300)
        XCTAssertEqual(NotificationDecision.cooldown(for: .scheduledApplied(70)), 300)
        XCTAssertEqual(NotificationDecision.cooldown(for: .lowBattery(8)), 1800)
        XCTAssertEqual(NotificationDecision.cooldown(for: .setupProblem), 1800)
    }
}
