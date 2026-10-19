import Foundation
import ServiceManagement

/// #27 (4.E sec 4): launch-at-login via `SMAppService.mainApp`, behind a popover toggle (default
/// OFF). The service is SEAMED so the model's toggle/status logic unit-tests without touching real
/// Login Items. Status is reflected HONESTLY — including `.requiresApproval` (the user enabled it
/// but must approve in System Settings → Login Items).

enum LoginStatus: Equatable {
    case enabled          // launches at login
    case notRegistered    // off (the default)
    case requiresApproval // registered but awaiting the user's approval in System Settings
    case notFound         // the service isn't installed/visible
    case unknown
}

protocol LoginItemServicing: AnyObject {
    var status: LoginStatus { get }
    func register() throws
    func unregister() throws
}

/// Live `SMAppService.mainApp` wrapper.
final class LiveLoginItemService: LoginItemServicing {
    private let service = SMAppService.mainApp
    var status: LoginStatus {
        switch service.status {
        case .enabled:         return .enabled
        case .notRegistered:   return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound:        return .notFound
        @unknown default:      return .unknown
        }
    }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status: LoginStatus
    @Published private(set) var lastError: String?

    private let service: any LoginItemServicing
    private let defaults: UserDefaults
    private static let suggestionKey = "loginItem.suggestionShown.v1"

    init(service: any LoginItemServicing = LiveLoginItemService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.status = service.status
    }

    /// Registered-and-approved. The toggle treats `.requiresApproval` as ON-but-pending (the user
    /// asked for it); the section surfaces the approval path separately.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    var suggestionShown: Bool { defaults.bool(forKey: Self.suggestionKey) }
    func markSuggestionShown() { defaults.set(true, forKey: Self.suggestionKey) }

    func refresh() { status = service.status }

    /// Toggle target: register on, unregister off; reflect the resulting real status. Never throws
    /// to the UI — errors surface as `lastError`.
    func setEnabled(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
