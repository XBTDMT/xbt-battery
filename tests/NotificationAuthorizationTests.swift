import XCTest
@testable import Battery

/// Sprint 4.4 (SPEC sec 1 + sec 5 "Authorization seam"): authorization is requested ONLY the first
/// time the user enables notifications (an explicit act) — never a cold launch prompt. Denied is a
/// quiet, honest terminal state (never nag). Tested through the `NotificationAuthorizing` seam with a
/// counting mock, host-app-free (the live UNUserNotificationCenter glue is app-only).
@MainActor
final class NotificationAuthorizationTests: XCTestCase {

    /// A counting authorizer seam (an actor for safe async mutable state): records how many times
    /// status/request were called and what to grant.
    private actor MockAuthorizer: NotificationAuthorizing {
        private var _status: NotificationAuthState
        private let grantResult: NotificationAuthState
        private(set) var requestCount = 0
        private(set) var statusCount = 0
        init(status: NotificationAuthState, grants: NotificationAuthState) {
            _status = status; grantResult = grants
        }
        func currentStatus() async -> NotificationAuthState { statusCount += 1; return _status }
        func requestAuthorization() async -> NotificationAuthState {
            requestCount += 1; _status = grantResult; return grantResult
        }
    }

    func testConstructionNeverTouchesAuthorizer() async {
        // No cold prompt, no probe at launch — building the controller must do nothing.
        let mock = MockAuthorizer(status: .notDetermined, grants: .authorized)
        _ = NotificationEnableController(authorizer: mock)
        let requests = await mock.requestCount
        let statuses = await mock.statusCount
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(statuses, 0)
    }

    func testEnableRequestsAuthorizationWhenNotDetermined() async {
        let mock = MockAuthorizer(status: .notDetermined, grants: .authorized)
        let controller = NotificationEnableController(authorizer: mock)
        let result = await controller.userEnabledNotifications()
        XCTAssertEqual(result, .authorized)
        let requests = await mock.requestCount
        XCTAssertEqual(requests, 1)                       // requested exactly once, on enable
    }

    func testEnableDoesNotRequestWhenAlreadyAuthorized() async {
        let mock = MockAuthorizer(status: .authorized, grants: .authorized)
        let controller = NotificationEnableController(authorizer: mock)
        let result = await controller.userEnabledNotifications()
        XCTAssertEqual(result, .authorized)
        let requests = await mock.requestCount
        XCTAssertEqual(requests, 0)                       // already granted → no second prompt
    }

    func testEnableWhenDeniedYieldsHonestStateWithoutReprompting() async {
        // Already denied at the OS level: surface it honestly, never nag with another request.
        let mock = MockAuthorizer(status: .denied, grants: .authorized)
        let controller = NotificationEnableController(authorizer: mock)
        let result = await controller.userEnabledNotifications()
        XCTAssertEqual(result, .denied)
        let requests = await mock.requestCount
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(controller.lastKnownAuth, .denied)
    }

    func testDeniedAfterRequestIsRecordedHonestly() async {
        let mock = MockAuthorizer(status: .notDetermined, grants: .denied)
        let controller = NotificationEnableController(authorizer: mock)
        let result = await controller.userEnabledNotifications()
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(controller.lastKnownAuth, .denied)
    }

    func testRefreshStatusNeverRequests() async {
        // Settings opening refreshes the honest state but must never trigger a prompt.
        let mock = MockAuthorizer(status: .denied, grants: .authorized)
        let controller = NotificationEnableController(authorizer: mock)
        let s = await controller.refreshStatus()
        XCTAssertEqual(s, .denied)
        let requests = await mock.requestCount
        XCTAssertEqual(requests, 0)
    }
}
