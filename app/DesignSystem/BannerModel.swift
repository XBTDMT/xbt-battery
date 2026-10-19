import Foundation

/// #29 D5 — the single unified exception surface's severity model + arbitration.
///
/// The popover shows AT MOST one banner. When several exceptions are active at once, the highest
/// severity wins the one slot. Priority order (D5): helper attention > power/limit exceptions >
/// informational. This model is pure and `Sendable` — no UI dependency — so the slot logic is
/// unit-testable host-app-free; the SwiftUI surface is `DSBanner` (DSBanner.swift) and the concrete
/// exception→(symbol/tint/message) mapping is wired when banners go live in Cut D-2.
enum BannerSeverity: Int, Comparable, CaseIterable, Sendable {
    case informational   // 0 — lowest
    case exception       // 1 — power/limit exceptions (auto-energy override, degraded, low power)
    case helperAttention // 2 — highest: needs a user action (helper unapproved / setup)

    static func < (lhs: BannerSeverity, rhs: BannerSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// D5 single-slot arbitration. Pure, deterministic, order-independent on the *winner's severity*;
/// ties resolve to input order so a caller can express a stable preference among equals.
enum BannerArbiter {
    /// The winning severity among the active candidates, or `nil` if none are active (banner silent).
    static func winner(_ severities: [BannerSeverity]) -> BannerSeverity? {
        severities.max()
    }

    /// The ONE candidate that occupies the slot: the FIRST candidate of the highest severity present
    /// (ties resolve to input order — stable). Returns `nil` for an empty candidate list.
    static func resolve<Candidate>(_ candidates: [Candidate],
                                   severity: (Candidate) -> BannerSeverity) -> Candidate? {
        var winner: Candidate?
        var best: BannerSeverity?
        for candidate in candidates {
            let s = severity(candidate)
            if best == nil || s > best! {   // strict > ⇒ first-of-equal-severity wins (stable)
                best = s
                winner = candidate
            }
        }
        return winner
    }
}
