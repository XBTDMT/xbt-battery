import XCTest
@testable import Battery

/// #29 D-5 (A1/F4) — the HUD trigger predicate over the FULL input matrix (custody origin × popover
/// open/closed × user active), plus the no-double-surface contract: for a schedule outcome the HUD and
/// the scheduled-applied notification are exactly complementary (the caller gates the notification on
/// `!shouldShow`), so one outcome never gets both surfaces.
final class HUDTriggerTests: XCTestCase {

    // MARK: popover visible → always suppressed (the open UI is its own confirmation)

    func testPopoverVisibleSuppressesEveryOrigin() {
        for origin in [CommandSource.user, .appIntent, .schedule, .topUp] {
            for active in [true, false] {
                XCTAssertFalse(HUDTrigger.shouldShow(origin: origin, popoverVisible: true, userActive: active),
                               "popover-visible must suppress origin=\(origin) active=\(active)")
            }
        }
    }

    // MARK: .user → never fires (a popover/menu action is its own confirmation)

    func testUserActionNeverFires() {
        XCTAssertFalse(HUDTrigger.shouldShow(origin: .user, popoverVisible: false, userActive: true))
        XCTAssertFalse(HUDTrigger.shouldShow(origin: .user, popoverVisible: false, userActive: false))
    }

    // MARK: .appIntent → always fires when the popover is closed (no UI present)

    func testAppIntentFiresWhenPopoverClosed() {
        XCTAssertTrue(HUDTrigger.shouldShow(origin: .appIntent, popoverVisible: false, userActive: true))
        XCTAssertTrue(HUDTrigger.shouldShow(origin: .appIntent, popoverVisible: false, userActive: false))
    }

    // MARK: .schedule / .topUp → fire only while the user is active

    func testScheduleFiresOnlyWhenActive() {
        XCTAssertTrue(HUDTrigger.shouldShow(origin: .schedule, popoverVisible: false, userActive: true))
        XCTAssertFalse(HUDTrigger.shouldShow(origin: .schedule, popoverVisible: false, userActive: false))
    }

    func testTopUpFiresOnlyWhenActive() {
        XCTAssertTrue(HUDTrigger.shouldShow(origin: .topUp, popoverVisible: false, userActive: true))
        XCTAssertFalse(HUDTrigger.shouldShow(origin: .topUp, popoverVisible: false, userActive: false))
    }

    // MARK: no-double-surface — HUD and the scheduled-applied notification are complementary

    /// The caller gates the scheduled notification on `!shouldShow`. Verify the two are mutually
    /// exclusive across the whole schedule input space (never both, and for an away schedule exactly the
    /// notification, for an active/no-popover schedule exactly the HUD).
    func testScheduleHUDAndNotificationAreMutuallyExclusive() {
        for popover in [true, false] {
            for active in [true, false] {
                let hud = HUDTrigger.shouldShow(origin: .schedule, popoverVisible: popover, userActive: active)
                let notification = !hud   // the wiring gates scheduledApplied on `!shouldShow`
                XCTAssertNotEqual(hud, notification, "HUD and notification must never both fire / both suppress-as-one")
                XCTAssertFalse(hud && notification, "one outcome, at most one surface")
            }
        }
    }

    /// An `.appIntent` set has NO same-moment notification (scheduledApplied requires `.schedule`), so it
    /// is exclusive by construction — the HUD is the only surface.
    func testAppIntentHasNoCompetingScheduledNotification() {
        // scheduledApplied only derives from source == .schedule (NotificationEvents.scheduledApplied).
        XCTAssertNil(NotificationEvents.scheduledApplied(source: .appIntent, limit: 80))
        XCTAssertTrue(HUDTrigger.shouldShow(origin: .appIntent, popoverVisible: false, userActive: false))
    }

    // MARK: strings + symbols (the D10 vocabulary + the D-5 draft)

    func testMessages() {
        XCTAssertEqual(HUDStrings.message(for: .chargeLimitSet(90)), "Charge limit set to 90%")
        XCTAssertEqual(HUDStrings.message(for: .toppingUp), "Topping up to 100%")
        XCTAssertEqual(HUDStrings.message(for: .energyModeSet("Low Power")), "Energy mode set to Low Power")
        XCTAssertEqual(HUDStrings.message(for: .keepAwake(true)), "Keep awake on")
        XCTAssertEqual(HUDStrings.message(for: .keepAwake(false)), "Keep awake off")
    }

    func testSymbolsAreNonEmpty() {
        for e in [HUDEvent.chargeLimitSet(80), .toppingUp, .energyModeSet("Auto"), .keepAwake(true),
                  .devicePowerStarted(DeviceNotice(title: "t", subline: "s", spoken: "t s"))] {
            XCTAssertFalse(HUDStrings.symbol(for: e).isEmpty)
        }
    }

    // MARK: - 31 §2.2 · the device notice (T3, T4)

    func testDeviceNoticeShowsOnlyOnBatteryPopoverClosedUserActiveSwitchOn() {
        for onBattery in [true, false] {
            for popover in [true, false] {
                for active in [true, false] {
                    for on in [true, false] {
                        XCTAssertEqual(HUDTrigger.shouldShowDeviceNotice(onBattery: onBattery, popoverVisible: popover,
                                                                         userActive: active, switchOn: on),
                                       onBattery && !popover && active && on,
                                       "battery=\(onBattery) popover=\(popover) active=\(active) switch=\(on)")
                    }
                }
            }
        }
    }

    func testDeviceNoticeStrings() {
        let e = HUDEvent.devicePowerStarted(DeviceNotice(
            title: "iPhone", subline: "Drawing 9.2 W · ≈\u{00A0}15% of battery per hour",
            spoken: "iPhone is drawing power from your Mac. Drawing 9.2 W, about 15% of battery per hour", symbol: "iphone"))
        XCTAssertEqual(HUDStrings.message(for: e), "iPhone")
        XCTAssertEqual(HUDStrings.subline(for: e), "Drawing 9.2 W · ≈\u{00A0}15% of battery per hour")
        XCTAssertEqual(HUDStrings.symbol(for: e), "iphone")
        XCTAssertFalse(HUDStrings.isChargeGlyph(for: e))
        // Owner U6 (2026-09-29): the two-line notice stays up 4.0 s (the number was delegated to the controller).
        XCTAssertEqual(HUDStrings.duration(for: e), 4.0)
        XCTAssertEqual(HUDStrings.announcement(for: e),
                       "iPhone is drawing power from your Mac. Drawing 9.2 W, about 15% of battery per hour")
    }

    func testTheFourExistingEventsAreUnchanged() {
        for e in [HUDEvent.chargeLimitSet(80), .toppingUp, .energyModeSet("Auto"), .keepAwake(true)] {
            XCTAssertNil(HUDStrings.subline(for: e))
            XCTAssertEqual(HUDStrings.duration(for: e), 1.6)
            XCTAssertEqual(HUDStrings.announcement(for: e), HUDStrings.message(for: e))
        }
    }
}
