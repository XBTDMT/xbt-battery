import Foundation
import ServiceManagement

// Sprint 3.7 STAGE 2 — the thin production adapter mapping `SMAppService` to the host-app-free
// `DaemonService` seam (HelperRegistration.swift). App-only (NOT compiled into the test target — the
// tests drive a mock `DaemonService`, never the live system registration).
final class LiveDaemonService: DaemonService {
    private let service: SMAppService

    /// A daemon identified by its launchd plist file name in Contents/Library/LaunchDaemons/.
    init(plistName: String) {
        self.service = SMAppService.daemon(plistName: plistName)
    }

    var statusValue: DaemonServiceStatus {
        switch service.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered:    return .notRegistered
        case .notFound:         return .notFound
        @unknown default:       return .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}
