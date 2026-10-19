import Foundation

/// Phase 5.6 (S5): owns the notification cooldown ledger and the post-then-stamp sequencing,
/// extracted from NotificationCoordinator so the "stamp a cooldown ONLY after a confirmed post"
/// invariant is testable host-app-free. emit() reads `lastNotified` for the pure shouldNotify
/// decision, then hands the survivor here to post and conditionally stamp.
@MainActor
final class NotificationDispatcher {

    private let presenter: any NotificationPresenting
    private(set) var lastNotified: [String: Date] = [:]

    init(presenter: any NotificationPresenting) {
        self.presenter = presenter
    }

    /// Post the plan; stamp the cooldown under `key` ONLY if the post is confirmed. A dropped post
    /// leaves no stamp, so the next genuine occurrence of the kind is not muzzled. Returns whether it
    /// stamped.
    @discardableResult
    func dispatch(_ plan: NotificationPlan, key: String, now: Date) async -> Bool {
        let posted = await presenter.post(plan)
        if posted { lastNotified[key] = now }
        return posted
    }

    /// Clear a session latch so the kind can fire again next time its condition rises.
    func rearm(_ key: String) {
        lastNotified[key] = nil
    }
}
