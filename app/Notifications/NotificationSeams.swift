import Foundation

/// Sprint 4.4: the seams between the testable logic and the OS notification center. The live
/// implementation (`LiveNotificationCenter` in NotificationManager.swift) wraps
/// `UNUserNotificationCenter`; tests inject mocks. Keeping authorization + posting behind protocols
/// is what lets the enable-only-on-explicit-act rule and the decision spine be tested host-app-free.

/// The app's view of the OS authorization state. Provisional/ephemeral collapse to `.authorized`
/// (we can post); `.notDetermined` means we have never asked (and must not, until the user enables).
enum NotificationAuthState: Equatable {
    case notDetermined
    case authorized
    case denied
}

/// Authorization seam. `currentStatus()` only reads; `requestAuthorization()` is the ONLY call that
/// may surface the system prompt, and the controller invokes it solely on an explicit user enable.
protocol NotificationAuthorizing: Sendable {
    func currentStatus() async -> NotificationAuthState
    func requestAuthorization() async -> NotificationAuthState
}

/// Posting seam — the coordinator's only outbound action.
protocol NotificationPresenting: Sendable {
    /// Returns whether the post was accepted by the center (false if it threw / was rejected), so the
    /// caller can decide whether to stamp a cooldown. Phase 5.6 S5.
    @discardableResult
    func post(_ plan: NotificationPlan) async -> Bool
}

/// Drives authorization off explicit user intent (SPEC sec 1). Constructing it touches nothing —
/// there is no launch-time probe or prompt. The system prompt appears only when the user flips the
/// master toggle ON while authorization is `.notDetermined`. A `.denied` state is surfaced honestly
/// and never re-prompted (the UI deep-links to System Settings instead; we never nag).
@MainActor
final class NotificationEnableController {

    private let authorizer: any NotificationAuthorizing
    private(set) var lastKnownAuth: NotificationAuthState = .notDetermined

    init(authorizer: any NotificationAuthorizing) {
        self.authorizer = authorizer
    }

    /// Call ONLY when the user enables notifications in Settings. Requests authorization the first
    /// time (status `.notDetermined`); otherwise reports the existing state without re-prompting.
    @discardableResult
    func userEnabledNotifications() async -> NotificationAuthState {
        let current = await authorizer.currentStatus()
        let result = (current == .notDetermined) ? await authorizer.requestAuthorization() : current
        lastKnownAuth = result
        return result
    }

    /// Refresh the honest state (e.g. when Settings opens, or after the user returns from System
    /// Settings) WITHOUT ever prompting.
    @discardableResult
    func refreshStatus() async -> NotificationAuthState {
        let s = await authorizer.currentStatus()
        lastKnownAuth = s
        return s
    }
}
