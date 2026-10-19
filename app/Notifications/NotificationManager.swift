import Foundation
import UserNotifications

/// Sprint 4.4: the THIN UNUserNotificationCenter glue (SPEC sec 0/3/6 — "NotificationManager is the
/// thin UNUserNotificationCenter glue: request, post, category/toggle plumbing"). All judgement
/// lives in the pure decision/derivation layers; this only translates to/from the OS center.
///
/// App-only: `UNUserNotificationCenter.current()` requires a real bundle, so this file is NOT in the
/// BatteryTests target (the seams it conforms to are exercised with mocks). It conforms to both
/// authorization and posting seams so a single live instance serves the enable controller AND the
/// coordinator.
final class LiveNotificationCenter: NotificationAuthorizing, NotificationPresenting, @unchecked Sendable {

    private let center = UNUserNotificationCenter.current()

    func currentStatus() async -> NotificationAuthState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:                       return .notDetermined
        case .denied:                              return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default:                          return .denied
        }
    }

    /// The ONLY call that may surface the system prompt. SPEC sec 1: options [.alert, .sound] — no
    /// badge (a menu-bar accessory app has no dock badge use here). A throw is treated as denied.
    func requestAuthorization() async -> NotificationAuthState {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    /// Post immediately (nil trigger). The stable per-kind identifier means a newer banner of the
    /// same kind replaces the older entry in Notification Center rather than stacking duplicates.
    @discardableResult
    func post(_ plan: NotificationPlan) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.threadIdentifier = plan.threadIdentifier
        content.sound = .default
        let request = UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
