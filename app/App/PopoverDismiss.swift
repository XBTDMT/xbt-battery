import AppKit

/// #22 popover auto-dismiss (SPEC sec 1). `.transient` is ineffective for an NSStatusItem-anchored
/// popover (known AppKit gap), so we install a global mouse-down monitor while the popover is shown
/// and tear it down on every close path.
///
/// Seam over `NSEvent.addGlobalMonitorForEvents` / `removeMonitor` so the install/remove PAIRING —
/// the correctness core — is unit-testable without a live event tap.
@MainActor
protocol GlobalClickMonitoring: AnyObject {
    /// Install a global monitor for outside (other-app) mouse-downs; `onClick` fires per event.
    /// IDEMPOTENT: a second install with one already live removes the prior first (never stacks).
    func install(onClick: @escaping () -> Void)
    /// Remove the monitor if installed. IDEMPOTENT: a no-op when nothing is installed.
    func remove()
    var isInstalled: Bool { get }
}

/// Live monitor: watches left/right mouse-downs in OTHER apps (global monitors never see our own
/// windows — so a click on our status-item button does NOT reach this; the local button action
/// handles that, no double-fire, per spec sec 1).
@MainActor
final class LiveGlobalClickMonitor: GlobalClickMonitoring {
    private var token: Any?
    var isInstalled: Bool { token != nil }

    func install(onClick: @escaping () -> Void) {
        remove()   // idempotent: never stack a second tap
        token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            onClick()
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Coordinates the monitor lifecycle against the popover's OWN show/close callbacks. Driven by
/// `NSPopoverDelegate` (`popoverDidShow`/`popoverDidClose`) so EVERY close path — outside click,
/// status-item re-click, programmatic `performClose`, resign-active — funnels through `didClose`
/// and removes the monitor exactly once. Testable: inject the monitor seam, call the lifecycle
/// hooks directly.
@MainActor
final class PopoverDismissCoordinator {
    private let monitor: GlobalClickMonitoring
    private let requestClose: () -> Void

    /// Diagnostics for the pairing tests.
    private(set) var installCount = 0
    private(set) var removeCount = 0

    init(monitor: GlobalClickMonitoring, requestClose: @escaping () -> Void) {
        self.monitor = monitor
        self.requestClose = requestClose
    }

    /// The popover became visible → arm the outside-click monitor.
    func didShow() {
        monitor.install { [weak self] in self?.requestClose() }   // outside click → close
        installCount += 1
    }

    /// The popover closed (ANY path) → disarm. Idempotent via the monitor seam.
    func didClose() {
        monitor.remove()
        removeCount += 1
    }

    /// App lost focus (cmd-tab) → close if shown; the resulting `didClose` removes the monitor.
    /// (Mirrors the native battery menu.) A no-op `requestClose` on an already-closed popover is
    /// harmless.
    func resignActive() {
        requestClose()
    }

    var isMonitorInstalled: Bool { monitor.isInstalled }
}
