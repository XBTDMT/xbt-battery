import XCTest

/// Sprint 4.E (#27): launch-at-login model against a SEAMED service — toggle wiring,
/// register/unregister, honest status reflection (incl. .requiresApproval), one-time suggestion.
@MainActor
final class LoginItemTests: XCTestCase {

    final class MockLoginService: LoginItemServicing {
        var status: LoginStatus
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0
        var registerError: Error?
        init(_ status: LoginStatus = .notRegistered) { self.status = status }
        func register() throws {
            registerCalls += 1
            if let e = registerError { throw e }
            status = .enabled
        }
        func unregister() throws { unregisterCalls += 1; status = .notRegistered }
    }

    private func model(_ status: LoginStatus = .notRegistered) -> (LoginItemModel, MockLoginService, UserDefaults) {
        let svc = MockLoginService(status)
        let defaults = UserDefaults(suiteName: "loginitem.tests.\(UUID().uuidString)")!
        return (LoginItemModel(service: svc, defaults: defaults), svc, defaults)
    }

    func testDefaultsOffReflectingService() {
        let (m, _, _) = model(.notRegistered)
        XCTAssertEqual(m.status, .notRegistered)
        XCTAssertFalse(m.isOn)
        XCTAssertFalse(m.needsApproval)
    }

    func testToggleOnRegisters() {
        let (m, svc, _) = model(.notRegistered)
        m.setEnabled(true)
        XCTAssertEqual(svc.registerCalls, 1)
        XCTAssertEqual(m.status, .enabled)
        XCTAssertTrue(m.isOn)
    }

    func testToggleOffUnregisters() {
        let (m, svc, _) = model(.enabled)
        m.setEnabled(false)
        XCTAssertEqual(svc.unregisterCalls, 1)
        XCTAssertEqual(m.status, .notRegistered)
        XCTAssertFalse(m.isOn)
    }

    func testRequiresApprovalIsHonestAndCountsAsOn() {
        let (m, _, _) = model(.requiresApproval)
        XCTAssertTrue(m.needsApproval, "the approval path must be surfaced honestly")
        XCTAssertTrue(m.isOn, "registered-but-pending reads as on (the user asked for it)")
    }

    func testRegisterErrorSurfacesNotThrows() {
        let (m, svc, _) = model(.notRegistered)
        svc.registerError = NSError(domain: "test", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "denied"])
        m.setEnabled(true)             // must not throw to the UI
        XCTAssertEqual(m.lastError, "denied")
        XCTAssertEqual(m.status, .notRegistered, "status reflects the failed register")
    }

    func testRefreshReflectsExternalApproval() {
        let (m, svc, _) = model(.requiresApproval)
        svc.status = .enabled          // user approved in System Settings
        m.refresh()
        XCTAssertEqual(m.status, .enabled)
    }

    func testOneTimeSuggestionFlag() {
        let (m, _, _) = model(.notRegistered)
        XCTAssertFalse(m.suggestionShown)
        m.markSuggestionShown()
        XCTAssertTrue(m.suggestionShown, "the suggestion is shown once and remembered")
    }
}
