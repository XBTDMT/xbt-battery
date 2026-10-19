import SwiftUI

// MARK: - #29 DesignSystem — foundation layer (Cut D-1)
//
// SWIFT-6 CLOSURE-HYGIENE RULE (A1 / Grok F6) — binding on every line of new code in this cut
// and every #29 cut after it:
//
//   A new closure that captures main-actor state must be one of —
//     (1) non-Sendable AND only ever invoked on the main actor (SwiftUI view bodies and
//         Button/action closures already satisfy this — they are @MainActor by construction), OR
//     (2) explicitly @MainActor, or hop the boundary via MainActor.assumeIsolated, OR
//     (3) closes over ONLY Sendable values (no main-actor-isolated captures at all).
//
//   Never let a closure that captures main-actor state cross an @Sendable boundary implicitly —
//   that is the exact tracked BatteryMonitor / SleepWakeScheduleController warning idiom, and it
//   is forbidden in DesignSystem code. Enforced structurally here: the tokens (DSColor / DSType /
//   DSMetric) are nonisolated Sendable constants; the components and SettingsRouter are @MainActor;
//   the banner arbiter (BannerModel.swift) is a pure, Sendable, side-effect-free function.
//
// The tokens map 1:1 to `29-phase1-foundation-tokens.md`; the components realize `29-phase2-locked-
// design.md` §4. No hex anywhere — every color is a semantic system color. This cut ships the layer
// only: nothing here is wired into a live view yet, so the app looks and behaves exactly as before.

/// DesignSystem namespace marker. Tokens live in `DSColor` / `DSType` / `DSMetric`; reusable
/// components in the `DS*` view files; pure models in `BannerModel.swift` and `SettingsRouter.swift`.
enum DesignSystem {
    /// Design-layer revision marker (bump when the token set changes materially).
    static let version = "d1"
}
