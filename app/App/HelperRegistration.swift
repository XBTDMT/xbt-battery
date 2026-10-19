import Foundation

// Sprint 3.7 STAGE 2 — registration / approval / migration DECISION logic, host-app-free + seamed so
// it is unit-testable without ServiceManagement or an installed daemon. The thin SMAppService adapter
// (LiveDaemonService) lives in an app-only file; tests drive a mock `DaemonService`.

/// The SMAppService daemon states we act on (seam mirror of `SMAppService.Status`).
public enum DaemonServiceStatus: Equatable, Sendable {
    case enabled            // registered + approved → ready
    case requiresApproval   // registered, awaiting the user's approval in Login Items & Extensions
    case notRegistered      // not registered yet
    case notFound           // bundle/plist not found (a packaging problem)
}

/// Seam over a registerable daemon (SMAppService in production; a mock in tests).
public protocol DaemonService: AnyObject {
    var statusValue: DaemonServiceStatus { get }
    func register() throws
    func unregister() throws
}

/// Honest, user-facing helper state — every state is visible/actionable (no silent no-ops).
public enum HelperUIState: Equatable, Sendable {
    case enabled                // ready
    case requiresApproval       // approve in Login Items & Extensions
    case notRegistered          // not registered
    case notFound               // packaging problem
    case needsManualReset       // macOS-26 fullPath-nil etc. survived a re-register → manual reset
    case signatureMismatch      // the bundled helper does NOT satisfy its codified DR (build/sign problem)

    /// Honest guidance shown to the owner. Never claims success it can't confirm.
    public var guidance: String {
        switch self {
        case .enabled:          return "Energy helper ready."
        case .requiresApproval: return "Approve the energy helper in System Settings → General → Login Items & Extensions."
        case .notRegistered:    return "Energy helper not registered yet."
        case .notFound:         return "Energy helper missing from the app bundle (packaging problem)."
        case .needsManualReset: return "Energy helper registration is stuck. Run `sudo sfltool resetbtm` and reboot, then reopen the app."
        case .signatureMismatch: return "The bundled energy helper's signature does not match the expected identity/team — rebuild and re-sign the app."
        }
    }

    /// Whether the app should open Login Items & Extensions to prompt approval.
    public var shouldOpenLoginItems: Bool { self == .requiresApproval }
}

/// sec-6b: whether to migrate away from an OLD (charge-era) helper registration.
public enum MigrationAction: Equatable, Sendable {
    case none            // clean install — nothing to migrate
    case migrateFromOld  // a live/stale old registration exists → notice + unregister it
}

public enum HelperRegistrar {

    /// Map a daemon status to the honest UI state.
    public static func uiState(for status: DaemonServiceStatus) -> HelperUIState {
        switch status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered:    return .notRegistered
        case .notFound:         return .notFound
        }
    }

    /// sec-6b decision: migrate iff the OLD helper still holds a registration (enabled or awaiting
    /// approval). A clean install (notRegistered/notFound) needs no migration.
    public static func migrationAction(oldStatus: DaemonServiceStatus) -> MigrationAction {
        switch oldStatus {
        case .enabled, .requiresApproval: return .migrateFromOld
        case .notRegistered, .notFound:   return .none
        }
    }

    /// Register the fresh helper, driving `.notRegistered → .requiresApproval/.enabled`, with the
    /// macOS-26 `fullPath`-nil mitigation: if a `register()` does not advance the status, unregister +
    /// re-register ONCE (register/unregister is NOT idempotent); if it still does not advance, surface
    /// `.needsManualReset` (sfltool resetbtm + reboot). Never traps. Returns the final honest state.
    @discardableResult
    public static func ensureRegistered(_ service: DaemonService,
                                        logger: (String) -> Void = { _ in }) -> HelperUIState {
        switch service.statusValue {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound:
            do { try service.register() } catch { logger("register failed: \(error)") }
            switch service.statusValue {
            case .enabled:          return .enabled
            case .requiresApproval: return .requiresApproval
            case .notRegistered, .notFound:
                // macOS-26 ~0.2% fullPath-nil regression (register is not idempotent): re-register once.
                logger("registration did not advance — unregister + re-register (macOS-26 fullPath-nil mitigation)")
                try? service.unregister()
                do { try service.register() } catch { logger("re-register failed: \(error)") }
                switch service.statusValue {
                case .enabled:          return .enabled
                case .requiresApproval: return .requiresApproval
                case .notRegistered, .notFound: return .needsManualReset
                }
            }
        }
    }

    /// sec-6b orchestration: PREFLIGHT-validate the bundled helper against its codified DR (sec 6 —
    /// "the DR validated against the SMAppService registration": refuse to register a mis-signed /
    /// wrong-identity helper), then detect + clean up the OLD helper (one-time notice + unregister),
    /// then register the fresh one. Handles old-present (upgrade) and old-absent (clean install).
    @discardableResult
    public static func migrateAndRegister(old: DaemonService,
                                          new: DaemonService,
                                          validateNewBinary: () -> Bool = { true },
                                          onMigrationNotice: () -> Void,
                                          logger: (String) -> Void = { _ in }) -> HelperUIState {
        guard validateNewBinary() else {
            logger("registration PREFLIGHT failed: the bundled helper does not satisfy its codified DR — refusing to register")
            return .signatureMismatch
        }
        if migrationAction(oldStatus: old.statusValue) == .migrateFromOld {
            onMigrationNotice()                       // one-time honest notice (caller dedupes)
            do { try old.unregister(); logger("migration: unregistered the old SMC helper") }
            catch { logger("migration: old-helper unregister failed (will rely on fresh identity): \(error)") }
        }
        return ensureRegistered(new, logger: logger)
    }
}
