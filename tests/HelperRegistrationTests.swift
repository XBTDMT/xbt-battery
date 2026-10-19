import XCTest

/// Sprint 3.7 STAGE 2 — registration / approval / sec-6b migration DECISION logic, driven through the
/// `DaemonService` seam (host-app-free; no live SMAppService). Covers old-present (upgrade) and
/// old-absent (clean install), plus the macOS-26 fullPath-nil unregister/re-register mitigation.
final class HelperRegistrationTests: XCTestCase {

    private enum MockError: Error { case boom }

    /// In-memory `DaemonService`. The seam deliberately models STATUS PROGRESSION + throw behavior
    /// (not SMAppService's internals): a settable status, register/unregister counters, optional
    /// register/unregister errors, and an `onRegister` closure to model the status advancing.
    private final class MockDaemonService: DaemonService {
        var statusValue: DaemonServiceStatus
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0
        var registerError: Error?
        var unregisterError: Error?
        var onRegister: ((MockDaemonService) -> Void)?
        init(_ status: DaemonServiceStatus) { statusValue = status }
        func register() throws { registerCount += 1; if let e = registerError { throw e }; onRegister?(self) }
        func unregister() throws { unregisterCount += 1; if let e = unregisterError { throw e } }
    }

    // MARK: status → honest UI state
    func testUIStateMapping() {
        XCTAssertEqual(HelperRegistrar.uiState(for: .enabled), .enabled)
        XCTAssertEqual(HelperRegistrar.uiState(for: .requiresApproval), .requiresApproval)
        XCTAssertEqual(HelperRegistrar.uiState(for: .notRegistered), .notRegistered)
        XCTAssertEqual(HelperRegistrar.uiState(for: .notFound), .notFound)
        XCTAssertTrue(HelperUIState.requiresApproval.shouldOpenLoginItems)
        XCTAssertFalse(HelperUIState.enabled.shouldOpenLoginItems)
    }

    // MARK: sec-6b migration decision
    func testMigrationAction_oldPresent_migrates() {
        XCTAssertEqual(HelperRegistrar.migrationAction(oldStatus: .enabled), .migrateFromOld)
        XCTAssertEqual(HelperRegistrar.migrationAction(oldStatus: .requiresApproval), .migrateFromOld)
    }
    func testMigrationAction_oldAbsent_none() {
        XCTAssertEqual(HelperRegistrar.migrationAction(oldStatus: .notRegistered), .none)
        XCTAssertEqual(HelperRegistrar.migrationAction(oldStatus: .notFound), .none)
    }

    // MARK: ensureRegistered
    func testEnsureRegistered_alreadyEnabled_noRegisterCall() {
        let s = MockDaemonService(.enabled)
        XCTAssertEqual(HelperRegistrar.ensureRegistered(s), .enabled)
        XCTAssertEqual(s.registerCount, 0)
    }
    func testEnsureRegistered_registerDrivesToRequiresApproval() {
        let s = MockDaemonService(.notRegistered)
        s.onRegister = { $0.statusValue = .requiresApproval }
        XCTAssertEqual(HelperRegistrar.ensureRegistered(s), .requiresApproval)
        XCTAssertEqual(s.registerCount, 1)
    }
    func testEnsureRegistered_fullPathNil_reregisterRecovers() {
        let s = MockDaemonService(.notRegistered)
        // Model the macOS-26 NON-IDEMPOTENCY: a re-register succeeds ONLY after an intervening
        // unregister. This makes the test PROVE the unregister is load-bearing + correctly ordered —
        // dropping `try? service.unregister()` would leave the mock stuck → .needsManualReset → fail.
        s.onRegister = { svc in if svc.unregisterCount >= 1 && svc.registerCount >= 2 { svc.statusValue = .enabled } }
        XCTAssertEqual(HelperRegistrar.ensureRegistered(s), .enabled)
        XCTAssertEqual(s.unregisterCount, 1, "the fullPath-nil mitigation unregistered once")
        XCTAssertEqual(s.registerCount, 2, "initial register + one re-register")
    }

    func testEnsureRegistered_registerThrows_failsClosedNoTrap() {
        let s = MockDaemonService(.notRegistered)
        s.registerError = MockError.boom   // every register() throws (the throw-shaped fullPath-nil case)
        XCTAssertEqual(HelperRegistrar.ensureRegistered(s), .needsManualReset,
                       "a throwing register must be caught and surfaced as an honest stuck state, never trap")
        XCTAssertEqual(s.registerCount, 2)
        XCTAssertEqual(s.unregisterCount, 1)
    }
    func testEnsureRegistered_fullPathNil_stillStuck_needsManualReset() {
        let s = MockDaemonService(.notRegistered)   // register never advances the status
        XCTAssertEqual(HelperRegistrar.ensureRegistered(s), .needsManualReset)
        XCTAssertEqual(s.registerCount, 2)
        XCTAssertEqual(s.unregisterCount, 1)
    }

    // MARK: migrateAndRegister (the full sec-6b orchestration)
    func testMigrateAndRegister_upgrade_firesNoticeAndUnregistersOld() {
        let old = MockDaemonService(.enabled)
        let new = MockDaemonService(.notRegistered)
        new.onRegister = { $0.statusValue = .requiresApproval }
        var noticeFired = false
        let state = HelperRegistrar.migrateAndRegister(old: old, new: new, onMigrationNotice: { noticeFired = true })
        XCTAssertTrue(noticeFired, "an upgrade with an old registration must fire the one-time notice")
        XCTAssertEqual(old.unregisterCount, 1, "the old SMC helper must be unregistered")
        XCTAssertEqual(state, .requiresApproval)
    }
    func testMigrateAndRegister_cleanInstall_noNotice() {
        let old = MockDaemonService(.notFound)
        let new = MockDaemonService(.notRegistered)
        new.onRegister = { $0.statusValue = .enabled }
        var noticeFired = false
        let state = HelperRegistrar.migrateAndRegister(old: old, new: new, onMigrationNotice: { noticeFired = true })
        XCTAssertFalse(noticeFired, "a clean install must NOT fire the migration notice")
        XCTAssertEqual(old.unregisterCount, 0)
        XCTAssertEqual(state, .enabled)
    }

    func testMigrateAndRegister_oldUnregisterThrows_stillRegistersNew() {
        let old = MockDaemonService(.enabled)
        old.unregisterError = MockError.boom         // the old-helper unregister fails…
        let new = MockDaemonService(.notRegistered)
        new.onRegister = { $0.statusValue = .requiresApproval }
        let state = HelperRegistrar.migrateAndRegister(old: old, new: new, onMigrationNotice: {})
        XCTAssertEqual(new.registerCount, 1, "a throwing old-unregister must NOT abort fresh registration")
        XCTAssertEqual(state, .requiresApproval, "fresh registration still proceeds (the fresh identity stands alone)")
    }

    func testMigrateAndRegister_preflightFails_refusesToRegister() {
        // sec 6 preflight: a bundled helper that does NOT satisfy the codified DR must be refused.
        let old = MockDaemonService(.notFound)
        let new = MockDaemonService(.notRegistered)
        new.onRegister = { $0.statusValue = .enabled }
        var noticeFired = false
        let state = HelperRegistrar.migrateAndRegister(
            old: old, new: new,
            validateNewBinary: { false },            // DR preflight FAILS (mis-signed helper)
            onMigrationNotice: { noticeFired = true })
        XCTAssertEqual(state, .signatureMismatch, "a DR-preflight failure must surface signatureMismatch")
        XCTAssertEqual(new.registerCount, 0, "must NOT register a helper that fails its codified DR")
        XCTAssertFalse(noticeFired, "must not run migration when refusing to register")
    }
}
