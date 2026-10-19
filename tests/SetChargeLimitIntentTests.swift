import XCTest
import AppIntents

/// Phase 5 feature #17 STAGE 1: the AppEnum is locked to the sanctioned limit values (so an out-of-range
/// value cannot be chosen), and the AppShortcutsProvider vends the Set Charge Limit intent. The intent's
/// perform plumbing and the agent launch are app-only / on-device (spec sec 7), not unit-tested here.
final class SetChargeLimitIntentTests: XCTestCase {

    func testChargeLimitOptionMatchesValidLimitValues() {
        XCTAssertEqual(ChargeLimitOption.allCases.map(\.rawValue).sorted(),
                       ChargeShortcuts.validLimitValues.sorted(),
                       "the intent's AppEnum must stay in lockstep with the sanctioned limit values")
    }

    func testAppShortcutsProviderVendsAllThreeIntents() {
        XCTAssertEqual(ChargeControlAppShortcuts.appShortcuts.count, 3,
                       "the provider vends three intents: Set Charge Limit, Top Up, and Set Energy Mode")
    }
}
