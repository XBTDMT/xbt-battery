import XCTest
@testable import Battery

/// #EI-4 / audit item C4 ("real alerts — hot pack"). The PURE hot-pack alert gate: a latched,
/// hysteresis-banded edge detector over the three-state `BatterySnapshot.TemperatureReading`.
///
/// Three properties are asserted here, and they are the whole feature:
///   1. THREE-STATE DISCIPLINE — an unreadable temperature is its own state. It must never fire, and
///      it must never RE-ARM either (re-arming is a "you're fine" signal in disguise: it says the pack
///      cooled, which an absent reading cannot support). Absence preserves whatever we last knew.
///   2. HYSTERESIS — fire on the rising edge at `hotThreshold`, re-arm only after the pack falls back
///      below `warmThreshold`. The band between the two is the A6 deadband lesson applied to a live
///      signal: a value that wanders across ONE boundary must not produce endless churn.
///   3. BOUNDARY EXACTNESS — both thresholds are inclusive-at-the-hot-side, exactly as the EI-4 spec's
///      classifier defines them (42.0 is hot; 37.0 is still warm, so it does NOT re-arm).
final class BatteryHeatAlertTests: XCTestCase {

    // The thresholds are the SPEC's, not this test's — assert the wiring, not a magic number.
    private let hot = BatteryThermalState.hotThreshold      // 42.0
    private let warm = BatteryThermalState.warmThreshold    // 37.0

    private func gate() -> BatteryHeatAlert { BatteryHeatAlert() }

    // MARK: - the three temperature states

    func testNotYetReadFiresNothing() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.notYetRead), .silent)
        XCTAssertFalse(g.isEngaged, "a not-yet-read battery is not a hot battery")
    }

    func testUnsupportedByOSFiresNothing() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.unsupportedByOS), .silent,
                       "a macOS that does not report temperature must not produce an alarm")
        XCTAssertFalse(g.isEngaged)
    }

    func testReadableCoolTemperatureFiresNothing() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.celsius(25.0)), .silent)
        XCTAssertFalse(g.isEngaged)
    }

    // MARK: - the thresholds, exactly

    func testJustBelowHotDoesNotFire() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.celsius(hot - 0.1)), .silent, "41.9 is warm, not hot")
        XCTAssertFalse(g.isEngaged)
    }

    func testHotThresholdIsInclusiveAndFires() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.celsius(hot)), .fire(celsius: hot),
                       "the hot threshold is inclusive — 42.0 fires")
        XCTAssertTrue(g.isEngaged)
    }

    func testFiresOnTheRisingEdgeOnlyOnce() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.celsius(43.0)), .fire(celsius: 43.0))
        XCTAssertEqual(g.evaluate(.celsius(44.0)), .silent, "still hot is not news")
        XCTAssertEqual(g.evaluate(.celsius(48.0)), .silent)
    }

    // MARK: - hysteresis / anti-flapping (the A6 lesson)

    /// The whole point of the band: a signal wandering across the HOT boundary alone must never
    /// re-fire. Under a single-threshold design this sequence pings five times.
    func testWanderingAcrossTheHotBoundaryFiresExactlyOnce() {
        var g = gate()
        var fires = 0
        for c in [42.1, 41.8, 42.3, 41.9, 42.0, 41.7, 42.4] {
            if case .fire = g.evaluate(.celsius(c)) { fires += 1 }
        }
        XCTAssertEqual(fires, 1, "the deadband must absorb boundary wander (A6: a rolling mean across a "
                       + "boundary produces endless churn)")
        XCTAssertTrue(g.isEngaged, "never fell below the warm threshold, so the latch stays engaged")
    }

    func testInsideTheBandDoesNotRearm() {
        var g = gate()
        _ = g.evaluate(.celsius(43.0))
        XCTAssertEqual(g.evaluate(.celsius(warm + 1.0)), .silent, "38.0 is inside the band")
        XCTAssertTrue(g.isEngaged)
    }

    func testWarmThresholdIsNotYetCoolEnoughToRearm() {
        var g = gate()
        _ = g.evaluate(.celsius(43.0))
        XCTAssertEqual(g.evaluate(.celsius(warm)), .silent,
                       "37.0 is still WARM by the spec classifier — re-arm requires falling BELOW it")
        XCTAssertTrue(g.isEngaged)
    }

    func testFallingBelowTheWarmThresholdRearms() {
        var g = gate()
        _ = g.evaluate(.celsius(43.0))
        XCTAssertEqual(g.evaluate(.celsius(warm - 0.1)), .rearm, "36.9 is normal — the episode ended")
        XCTAssertFalse(g.isEngaged)
    }

    func testASecondGenuineEpisodeFiresAgain() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.celsius(43.0)), .fire(celsius: 43.0))
        XCTAssertEqual(g.evaluate(.celsius(30.0)), .rearm)
        XCTAssertEqual(g.evaluate(.celsius(42.5)), .fire(celsius: 42.5),
                       "a real second heat episode is real news")
    }

    func testRearmIsReportedOnceNotOnEverySample() {
        var g = gate()
        _ = g.evaluate(.celsius(43.0))
        XCTAssertEqual(g.evaluate(.celsius(25.0)), .rearm)
        XCTAssertEqual(g.evaluate(.celsius(24.0)), .silent, "already re-armed — nothing changed")
    }

    /// A cool pack that was never hot has nothing to re-arm; `.rearm` is an EDGE, not a level.
    func testCoolWithoutAPriorEpisodeIsSilentNotRearm() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.celsius(20.0)), .silent)
    }

    // MARK: - absence never moves the latch, in EITHER direction

    /// The rule that makes this safe: "couldn't read" is NOT "cool". While engaged, an unreadable
    /// sample must not re-arm — otherwise the next hot sample would fire a duplicate alarm for the
    /// SAME episode, purely because a read failed in the middle of it.
    func testAbsenceWhileEngagedDoesNotRearmAndDoesNotRefire() {
        var g = gate()
        XCTAssertEqual(g.evaluate(.celsius(43.0)), .fire(celsius: 43.0))
        XCTAssertEqual(g.evaluate(.unsupportedByOS), .silent)
        XCTAssertEqual(g.evaluate(.notYetRead), .silent)
        XCTAssertTrue(g.isEngaged, "an absent reading is not evidence the pack cooled")
        XCTAssertEqual(g.evaluate(.celsius(43.5)), .silent,
                       "same episode — the read gap must not manufacture a second alarm")
    }

    /// The mirror: absence must not fire either. A permanently-unreporting macOS produces silence
    /// forever, never a false alarm.
    func testAbsenceForeverIsSilentForever() {
        var g = gate()
        for _ in 0..<50 {
            XCTAssertEqual(g.evaluate(.unsupportedByOS), .silent)
            XCTAssertEqual(g.evaluate(.notYetRead), .silent)
        }
        XCTAssertFalse(g.isEngaged)
    }

    // MARK: - the classifier agrees with the gate (one set of thresholds, not two)

    func testGateAgreesWithTheSpecClassifier() {
        // Anything the gate fires on must classify as `.hot`; anything that re-arms must be `.normal`.
        XCTAssertEqual(BatteryThermalState.from(celsius: hot), .hot)
        XCTAssertEqual(BatteryThermalState.from(celsius: warm - 0.1), .normal)
        XCTAssertEqual(BatteryThermalState.from(celsius: warm), .warm)
    }
}

/// The notification half of C4: the event derivation, the defaults, the copy, and the cooldown
/// backstop. Kept in this file (not appended to the 4.4 suites) so EI-4's surface is auditable in
/// one place.
@MainActor
final class HotBatteryNotificationTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func masterOn(hot: Bool) -> NotificationPrefs {
        var p = NotificationPrefs.defaults
        p.masterEnabled = true
        p.hotBattery = hot
        return p
    }

    // MARK: derivation

    func testOnlyAFireOutcomeBecomesAnEvent() {
        XCTAssertNil(NotificationEvents.hotBattery(outcome: .silent))
        XCTAssertNil(NotificationEvents.hotBattery(outcome: .rearm),
                     "cooling down is not something to interrupt the user about")
        let e = NotificationEvents.hotBattery(outcome: .fire(celsius: 43.4))
        XCTAssertEqual(e?.kind, .hotBattery(43))
        XCTAssertEqual(e?.cause, .autonomous, "the hardware got hot; the user did not do it")
    }

    func testCelsiusIsRoundedForDisplay() {
        XCTAssertEqual(NotificationEvents.hotBattery(outcome: .fire(celsius: 42.6))?.kind,
                       .hotBattery(43))
        XCTAssertEqual(NotificationEvents.hotBattery(outcome: .fire(celsius: 42.4))?.kind,
                       .hotBattery(42))
    }

    // MARK: the toggle

    func testHotBatteryIsOffByDefaultEvenWithMasterOn() {
        XCTAssertFalse(NotificationPrefs.defaults.hotBattery,
                       "opt-in, like low battery — heat is informational, not an emergency")
        XCTAssertNil(NotificationDecision.shouldNotify(
            event: NotificationEvent(kind: .hotBattery(45), cause: .autonomous),
            prefs: masterOn(hot: false), lastNotified: [:], now: now),
            "the user must be able to turn it off — and off is the default")
    }

    func testEnabledHotBatteryNotifiesWithTheTemperature() {
        let plan = NotificationDecision.shouldNotify(
            event: NotificationEvent(kind: .hotBattery(45), cause: .autonomous),
            prefs: masterOn(hot: true), lastNotified: [:], now: now)
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan?.body.contains("45") == true, "the body must state the reading it fired on")
    }

    func testMasterOffSuppressesHotBattery() {
        var p = NotificationPrefs.defaults
        p.hotBattery = true                      // per-event on, master off
        XCTAssertNil(NotificationDecision.shouldNotify(
            event: NotificationEvent(kind: .hotBattery(45), cause: .autonomous),
            prefs: p, lastNotified: [:], now: now))
    }

    func testTypeMappingAndCooldownBackstop() {
        XCTAssertEqual(NotificationKind.hotBattery(45).type, .hotBattery)
        let key = NotificationDecision.cooldownKey(for: .hotBattery(45))
        XCTAssertEqual(key, NotificationEventType.hotBattery.rawValue)
        XCTAssertNil(NotificationDecision.shouldNotify(
            event: NotificationEvent(kind: .hotBattery(46), cause: .autonomous),
            prefs: masterOn(hot: true),
            lastNotified: [key: now.addingTimeInterval(-60)], now: now),
            "the cooldown is the second guard behind the latch")
    }

    func testStoreRoundTripsTheNewToggle() {
        let suite = "battery.tests.hotBattery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotificationPreferencesStore(defaults: defaults)
        XCTAssertFalse(store.prefs.hotBattery)
        store.setEnabled(true, for: .hotBattery)
        XCTAssertTrue(store.prefs.hotBattery)
    }
}
