import XCTest
@testable import Battery

/// Phase 5.6 (S5): the cooldown ledger must reflect ONLY confirmed posts. A dropped post must leave
/// no stamp, so the next genuine occurrence of the kind is not silently muzzled. Tested through the
/// NotificationPresenting seam with a mock that can fail the post, host-app-free.
@MainActor
final class NotificationDispatcherTests: XCTestCase {

    private actor MockPresenter: NotificationPresenting {
        private let succeeds: Bool
        private(set) var postCount = 0
        init(succeeds: Bool) { self.succeeds = succeeds }
        func post(_ plan: NotificationPlan) async -> Bool { postCount += 1; return succeeds }
    }

    private func samplePlan() -> NotificationPlan {
        NotificationDecision.plan(for: .fullyCharged)
    }

    func testFailedPostLeavesNoStamp() async {
        let mock = MockPresenter(succeeds: false)
        let dispatcher = NotificationDispatcher(presenter: mock)
        let stamped = await dispatcher.dispatch(samplePlan(), key: "k", now: Date())
        XCTAssertFalse(stamped)
        XCTAssertNil(dispatcher.lastNotified["k"], "a dropped post must not stamp the cooldown")
        let calls = await mock.postCount
        XCTAssertEqual(calls, 1)
    }

    func testConfirmedPostStamps() async {
        let mock = MockPresenter(succeeds: true)
        let dispatcher = NotificationDispatcher(presenter: mock)
        let when = Date()
        let stamped = await dispatcher.dispatch(samplePlan(), key: "k", now: when)
        XCTAssertTrue(stamped)
        XCTAssertEqual(dispatcher.lastNotified["k"], when, "a confirmed post must stamp the cooldown")
    }

    func testRearmClearsStamp() async {
        let mock = MockPresenter(succeeds: true)
        let dispatcher = NotificationDispatcher(presenter: mock)
        _ = await dispatcher.dispatch(samplePlan(), key: "k", now: Date())
        XCTAssertNotNil(dispatcher.lastNotified["k"])
        dispatcher.rearm("k")
        XCTAssertNil(dispatcher.lastNotified["k"])
    }
}
