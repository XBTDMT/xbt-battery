import XCTest

/// Phase 5 feature #17 STAGE 1: the pure CommandSource helpers that the `.appIntent` case adds — the
/// status-line prefix (extracted from the app-only popover so "Shortcut: " is unit-testable) and the
/// schedule-pause predicate (the runner's human-primacy guard widens to user-or-intent).
final class CommandSourceTests: XCTestCase {

    func testStatusPrefixForEachSource() {
        XCTAssertEqual(CommandSource.user.statusPrefix, "")
        XCTAssertEqual(CommandSource.schedule.statusPrefix, "Scheduled: ")
        XCTAssertEqual(CommandSource.topUp.statusPrefix, "Top Up: ")
        XCTAssertEqual(CommandSource.appIntent.statusPrefix, "Shortcut: ")
    }

    func testIsExplicitUserOrIntent() {
        XCTAssertTrue(CommandSource.user.isExplicitUserOrIntent, "a direct/external set is explicit")
        XCTAssertTrue(CommandSource.appIntent.isExplicitUserOrIntent, "an App Intent set is explicit")
        XCTAssertFalse(CommandSource.schedule.isExplicitUserOrIntent, "our own scheduled set is not a manual override")
        XCTAssertFalse(CommandSource.topUp.isExplicitUserOrIntent, "the top-up revert leg is not a manual override")
    }
}
