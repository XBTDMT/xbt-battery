import Foundation
import Combine

/// The four Settings tabs (D8). Raw values are stable identifiers for persistence and deep-links.
enum SettingsTab: String, CaseIterable, Sendable {
    case general, appearance, notifications, automation
}

/// #29 A1 / Grok F3 — the single source of truth for "open Settings on tab X".
///
/// A naive shared `@Published` selection is timing-fragile: a deep-link set before the Settings
/// window exists is silently lost. This router pairs an idempotent `selection` with a *monotonic*
/// `openRequestToken` that an observer reads both on appear and on change — so the request survives
/// regardless of when the window materializes. Both the footer gear and the `open schedule`
/// quick-action route through `open(to:)`. Consumed in Cut D-4; seeded and unit-tested here.
///
/// Closure hygiene (DesignSystem rule): `@MainActor`-isolated; every mutation is on the main actor,
/// so no `@Sendable` closure ever captures this state.
@MainActor
final class SettingsRouter: ObservableObject {
    /// The tab that should be shown. Idempotent: repeated `open(to:)` with the same tab leaves this
    /// unchanged (no toggling, no drift).
    @Published private(set) var selection: SettingsTab

    /// Monotonic open-request signal. Advances on EVERY `open(to:)` so an observer can bring the
    /// window forward even when the tab is unchanged. Deliberately *not* idempotent — re-requesting
    /// the window is its whole job (that is what fixes the F3 timing fragility).
    @Published private(set) var openRequestToken: Int = 0

    init(selection: SettingsTab = .general) {
        self.selection = selection
    }

    /// Select `tab` and request that Settings open / come forward.
    func open(to tab: SettingsTab) {
        selection = tab
        openRequestToken &+= 1
    }

    /// #29 D-4: a manual tab change (the user clicked a toolbar tab) — updates `selection` WITHOUT
    /// re-requesting the window. This is the setter the Settings TabView binds to; deep-links use
    /// `open(to:)` (which also advances `openRequestToken` to front the window).
    func select(_ tab: SettingsTab) {
        selection = tab
    }
}
