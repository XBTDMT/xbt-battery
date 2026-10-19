import AppKit

/// (1b) keep-awake cluster, cut 2: a per-holder QUIT affordance for the OTHER processes that #EI-1a
/// surfaces (WhatsKeepingAwake). The HARD boundary — GUI-apps-only, and NEVER through the privileged
/// helper — is enforced by the API itself, not a heuristic: `NSRunningApplication(processIdentifier:)`
/// resolves ONLY a real running app and hands back its terminate handle; daemons / CLI tools resolve to
/// nil and are surfaced-but-non-terminable. Graceful `.terminate()` releases the holder's assertion the
/// instant it exits (#EI-1 probe-confirmed), which is the whole goal. This is plain AppKit — NO privilege,
/// NO entitlement, NO helper / XPC (that path does not exist here and is NOT created here).

/// A user GUI app we are allowed to ask to quit (resolved via NSRunningApplication).
struct TerminableApp: Equatable, Identifiable {
    let pid: Int
    let name: String
    let bundleId: String?
    var id: Int { pid }
}

/// The terminate seam — the view + tests depend on this protocol, never on NSRunningApplication directly.
protocol AppTerminating: AnyObject {
    /// Resolve a holder pid to a quit-able user GUI app, or nil if it is not one (daemon / CLI / self).
    func terminableApp(pid: Int) -> TerminableApp?
    /// Graceful terminate. Returns false if the app is already gone (re-resolved at call time).
    @discardableResult func terminate(_ app: TerminableApp) -> Bool
}

/// The LIVE boundary adapter — NOT unit-tested (like LiveAssertionInventory). Every invariant
/// (GUI-apps-only, never-quit-ourselves, graceful-only) lives here, enforced by NSRunningApplication.
final class LiveAppTerminator: AppTerminating {
    func terminableApp(pid: Int) -> TerminableApp? {
        guard pid != Int(ProcessInfo.processInfo.processIdentifier),     // never offer to quit ourselves
              let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              app.activationPolicy != .prohibited                         // .regular/.accessory = a user app
        else { return nil }
        return TerminableApp(pid: pid, name: app.localizedName ?? "this app", bundleId: app.bundleIdentifier)
    }

    @discardableResult
    func terminate(_ app: TerminableApp) -> Bool {
        // Re-resolve at call time — it may have quit since classification. Graceful ONLY (never
        // forceTerminate / SIGKILL): the OS owns Force-Quit for a hung app.
        guard let running = NSRunningApplication(processIdentifier: pid_t(app.pid)) else { return false }
        return running.terminate()
    }
}

/// Pure helpers (testable; no AppKit state).
enum KeepAwakeTerminator {
    /// The confirmation copy: surfaces the app AND its keep-awake reason so a live-call app isn't blind-quit.
    static func confirmMessage(for holder: KeepAwakeHolder) -> (title: String, body: String) {
        let title = "Quit \(holder.displayName)?"
        let body = "It's keeping your Mac awake" + (holder.explanation.isEmpty ? "." : ": \(holder.explanation)")
        return (title, body)
    }

    /// The quit-target seam contract: a holder is quit-able iff the terminator resolves it to a GUI app.
    static func quitTarget(for holder: KeepAwakeHolder, via t: AppTerminating) -> TerminableApp? {
        t.terminableApp(pid: holder.pid)
    }
}
