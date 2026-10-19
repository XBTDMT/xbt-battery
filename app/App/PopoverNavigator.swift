import Combine

/// #29 D-6 · the ONE sanctioned AppDelegate↔popover-view navigation channel — the entire build's single
/// hosting touch. It has EXACTLY THREE consumers, and no others, ever:
///
///   (a) a normal popover-show resets navigation to root (`[]`), fixing the D-2 known limitation
///       (reopening the transient NSPopover used to land on the last-viewed page);
///   (b) the show-history quick-action opens directly on Details (`[.details]`);
///   (c) a popover CLOSE resets to root, which is what tears the Details page down.
///
/// (c) was added 2026-09-08 under an explicit exception to the original two-consumer contract, because
/// the audit reproduced a real leak: `NSPopover.close()` leaves the hosting view in a live window, so
/// SwiftUI never fires `onDisappear` and the Details page's IOReport sampling `.task` ran until the next
/// open — or forever if there was no next open. Resetting the path is the only thing that cancels it, and
/// it must happen on CLOSE, not on the next show. It also makes a deep-linked reopen a genuine
/// [] → [.details] transition rather than a no-op assignment over itself.
///
/// The AppDelegate sets `path` in `popoverWillShow` (from a per-show pending value it stages in
/// `showPopover(openTo:)`), so the correct page is in place before the popover renders — no flash, and
/// in `popoverDidClose` (animation-suppressed). The popover view binds its `NavigationStack` to `path`
/// and writes it only for in-view navigation (the Details row / footer history button push `.details`;
/// the "‹ Battery" back control pops). If a FOURTH consumer is ever proposed it does NOT ride this
/// channel — this doc comment is the contract.
@MainActor
final class PopoverNavigator: ObservableObject {
    enum Route: Hashable { case details }
    @Published var path: [Route] = []
}
