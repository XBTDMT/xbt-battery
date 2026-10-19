import Foundation
import ApplicationServices

/// SPEC sec 8(i) build-time investigation: `AEDeterminePermissionToAutomateTarget` as a PRE-FLIGHT
/// Automation-permission query against Shortcuts, attempted BEFORE any `shortcuts run` can hang.
///
/// Status: ADVISORY ONLY. The mapping below is per the AE documentation; whether the CLI's TCC
/// gate is the same `kTCCServiceAppleEvents` (app → Shortcuts) grant this API reports is
/// UNVERIFIED on-device (the probe requires the real signed app context — WI-N8 owner run).
/// Per spec: investigate, report, promise nothing. The `.automationBlocked` taxon stays collapsed
/// unless/until this verdict proves discriminating on-device.
enum AutomationPreflight {

    enum Verdict: Equatable, Sendable {
        /// noErr — automation of the target is already granted.
        case granted
        /// errAEEventNotPermitted (-1743) — the user has DENIED automation. If this proves
        /// accurate on-device, `.automationBlocked` becomes splittable (Grok B3 condition).
        case denied
        /// errAEEventWouldRequireUserConsent (-1744) — not yet determined; a prompt would show.
        case requiresPrompt
        /// procNotFound (-600) — the determination needs the target RUNNING; Shortcuts isn't.
        /// (Key practical caveat: launching Shortcuts just to probe is not power-polite.)
        case shortcutsNotRunning
        /// Anything else — treat as no signal; never gate behavior on it.
        case indeterminate(OSStatus)
    }

    /// #29 orphan-backlog: the ADVISORY diagnostic line for a recorded verdict, or nil when there is
    /// nothing worth saying. Only `.denied` produces copy: it is the one verdict that names a condition
    /// the owner can act on, and it is phrased as a POSSIBLE cause, never a diagnosis — sec 8(i) rules
    /// that nothing may branch on this probe until on-device verification proves it discriminates.
    /// Rendering a sentence is not branching; promising a cause would be. Pure, so it is testable.
    static func advisoryNote(_ verdict: Verdict?) -> String? {
        guard verdict == .denied else { return nil }
        return "Diagnostic: macOS reported automation of Shortcuts as denied for this app. "
             + "If limit changes don’t take effect, check System Settings → Privacy & Security → Automation."
    }

    /// Pure status→verdict mapping (unit-tested; the live call is on-device-only).
    static func map(status: OSStatus) -> Verdict {
        switch status {
        case noErr:                                  return .granted
        case OSStatus(errAEEventNotPermitted):       return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .requiresPrompt
        case OSStatus(procNotFound):                 return .shortcutsNotRunning
        default:                                     return .indeterminate(status)
        }
    }

    /// Live probe (askUserIfNeeded=false — NEVER triggers a prompt from here; the SetupFlow owns
    /// prompt timing). Call sites treat every verdict as advisory.
    static func probeShortcutsAutomation() -> Verdict {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.shortcuts")
        guard let aeDesc = target.aeDesc else { return .indeterminate(OSStatus(paramErr)) }
        let status = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, false)
        return map(status: status)
    }
}
