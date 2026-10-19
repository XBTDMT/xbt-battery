import Foundation
import Combine

/// WI-N6: first-run + self-heal detection of the required user-created Shortcuts (SPEC v4.0
/// sec 2 SetupFlow). Re-checked on every launch; if shortcuts vanish mid-life the engine
/// degrades to `.setupRequired` (the runner's missing-shortcut fingerprint catches the same
/// condition at command time — this flow catches it proactively).
@MainActor
final class SetupFlow: ObservableObject {

    enum SetupState: Equatable {
        case unknown
        /// All five Set shortcuts AND the Get shortcut present — VERIFIED read-back mode.
        case ready
        /// 4.I: all five Set shortcuts present but the Get shortcut is ABSENT — still READY, in
        /// DEGRADED mode (changes confirmed by battery behavior; no read-back). Never a setup wall.
        case readyDegraded
        /// One or more of the five SET shortcuts are missing — the walkthrough lists them.
        case missing([String])
        /// `shortcuts list` itself failed — setup state cannot be determined.
        case listUnavailable(ListProblem)
    }

    enum ListProblem: Equatable {
        case binaryAbsent
        case automationBlocked
        case failure
    }

    @Published private(set) var state: SetupState = .unknown

    /// "The limit can be SET" — true for both `.ready` and `.readyDegraded`. Degraded means the Set
    /// shortcuts work but the Get read-back is absent (macOS 27); SET-only actions (the schedule, Top Up)
    /// must treat that as operational. Use this for any gate that only sets the limit; keep the strict
    /// `state == .ready` for gates that genuinely need a working read-back (the engine's Get re-syncs).
    var isOperational: Bool { state == .ready || state == .readyDegraded }

    /// 4.I (architect amendment bb37cd6): a ONE-TIME dismissible notice shown ONLY on a TRANSITION
    /// INTO degraded (was verified, then a seed re-pulled the Get action). A steady degraded state
    /// gets only the "· as set" value tag — never a banner. Upgrades to verified need nothing.
    @Published private(set) var degradedNoticePending = false
    private static let lastVerifiedKey = "setup.lastVerified.v1"

    /// Redman sweep item 7: how the verified-mode record READ. `object(forKey:) as? Bool` made a stored
    /// value of the wrong type identical to "never recorded".
    enum LastVerifiedRecord: Equatable {
        case none
        case recorded(Bool)
        case unreadable
    }
    /// Redman sweep item 7: the last check found a record it could not read (test-observable, NSLog'd;
    /// NOT `@Published` — the notice it gates is itself inert, see BatteryPopoverView).
    private(set) var lastVerifiedRecordUnreadable = false

    private func readLastVerified() -> LastVerifiedRecord {
        guard let stored = defaults.object(forKey: Self.lastVerifiedKey) else { return .none }
        guard let b = stored as? Bool else { return .unreadable }
        return .recorded(b)
    }

    /// sec 8(i) ADVISORY ONLY: the AE pre-flight verdict, recorded for diagnostics/WI-N8.
    /// NO behavior branches on it until on-device verification proves it discriminates
    /// (the `.automationBlocked` taxon stays collapsed regardless — promise nothing).
    @Published private(set) var automationPreflight: AutomationPreflight.Verdict?

    private let runner: any ShortcutRunning
    private let preflightProbe: @Sendable () -> AutomationPreflight.Verdict
    private let defaults: UserDefaults
    private let clock: any MonotonicClock

    /// **A12.** `checkNow()` runs once on launch and again on every popover open (the self-heal
    /// re-check). The popover call site guards on `state != .ready` — which is exactly WHY it fires on
    /// every single open on this machine: macOS 27 removed the "Get Battery Charge Limit" action, so
    /// the app's steady state is `.readyDegraded`, and a guard written for the ready case never
    /// suppresses anything in the state the app actually lives in. Every open therefore paid for an
    /// AppleEvent preflight probe AND a `shortcuts list` subprocess, the latter taking a slot in the
    /// runner's serialised FIFO ahead of real charge-limit commands.
    ///
    /// Same gate, same idiom, same 60 s as its sibling on the very next line of that call site —
    /// `ChargeLimitEngine.sync(.popoverOpen)` / `popoverOpenMinInterval` (B5). Its ruling applies
    /// verbatim: kill the open/close/open burst, don't ration the check.
    ///
    /// TWO things are deliberately NOT gated. The FIRST check of a session (`lastCheckAt == nil`) —
    /// the launch pass always runs, so the state is never `.unknown` for want of a gate. And nothing
    /// downstream: unlike the engine's `.verify`, no caller awaits `checkNow()` as a precondition —
    /// every consumer (`ChargeControlIntentSurface`, `TopUpIntentSurface`, the popover, Settings) reads
    /// the ALREADY-DETERMINED `state`/`isOperational`, so a suppressed refresh cannot let a command
    /// proceed against a stale reading. The one behavioural cost is a self-heal that lands up to 60 s
    /// late on a REOPEN — the user who just created the missing shortcuts spends far longer than that
    /// in Shortcuts.app, so the realistic path is unaffected.
    static let checkMinInterval: TimeInterval = 60
    private var lastCheckAt: TimeInterval?

    init(runner: any ShortcutRunning,
         preflightProbe: @escaping @Sendable () -> AutomationPreflight.Verdict
             = { AutomationPreflight.probeShortcutsAutomation() },
         defaults: UserDefaults = .standard,
         clock: any MonotonicClock = LiveMonotonicClock()) {
        self.runner = runner
        self.preflightProbe = preflightProbe
        self.defaults = defaults
        self.clock = clock
    }

    /// Detect via `shortcuts list` (one name per line). Call on launch and on popover open
    /// while unconfigured.
    func checkNow() async {
        // A12: stamped BEFORE the awaits, so two opens racing each other collapse to one probe + one
        // `shortcuts list` rather than two — which is the burst this gate exists to kill.
        let t = clock.now()
        if let last = lastCheckAt, t - last < Self.checkMinInterval { return }
        lastCheckAt = t
        automationPreflight = preflightProbe()
        switch await runner.list() {
        case .success(let stdout):
            let installed = Set(stdout.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
            // 4.I: setup-ready requires the five SET shortcuts ONLY. The Get shortcut is OPTIONAL —
            // present → verified mode; absent → ready-DEGRADED (the OS may have removed its action,
            // e.g. 27.0; never demand a shortcut the OS made impossible). Self-heals both ways on
            // re-check: a restored + recreated Get upgrades to .ready silently.
            let missingSets = ChargeShortcuts.validLimitValues
                .map(ChargeShortcuts.setName(for:))
                .filter { !installed.contains($0) }
            if !missingSets.isEmpty {
                state = .missing(missingSets)
            } else if installed.contains(ChargeShortcuts.get) {
                state = .ready
            } else {
                state = .readyDegraded
            }
            recordModeTransition()
        case .shortcutsBinaryAbsent:
            state = .listUnavailable(.binaryAbsent)
        case .automationBlocked:
            state = .listUnavailable(.automationBlocked)
        case .missingShortcut, .failed, .launchFailed:
            state = .listUnavailable(.failure)
        }
    }

    /// Fire the one-time notice ONLY when crossing verified → degraded (a previously-recorded
    /// verified state, then Get pulled). First-ever-degraded (no record) gets just the tag, no nag.
    ///
    /// Redman sweep item 7: three-state. An UNREADABLE record fires no notice — there is no evidence of
    /// a verified → degraded crossing, and the standing degraded banner already shows the state. The
    /// record IS then rewritten, deliberately: it is a one-bit mode the app regenerates from what this
    /// check just observed (never user-authored, never derived from the failed read), and leaving the
    /// unreadable value in place would disable transition detection for good.
    private func recordModeTransition() {
        let record = readLastVerified()
        lastVerifiedRecordUnreadable = (record == .unreadable)
        if record == .unreadable {
            NSLog("battery_app: setup's verified-mode record (%@) is not a Bool — no transition notice; "
                  + "rewriting it from this check.", Self.lastVerifiedKey)
        }
        switch state {
        case .ready:
            defaults.set(true, forKey: Self.lastVerifiedKey)
        case .readyDegraded:
            if record == .recorded(true) { degradedNoticePending = true }
            defaults.set(false, forKey: Self.lastVerifiedKey)
        default:
            break
        }
    }

    func dismissDegradedNotice() { degradedNoticePending = false }
}

/// The guided-walkthrough CONTENT (sec 2: per-value, no-input, exact names; the flow explains
/// the one-time prompt BEFORE firing it; sec 8h: the trust boundary is stated, not mitigated).
/// Pure data so the strings are testable for exactness; WI-N7 renders it.
enum SetupWalkthrough {

    struct Step: Equatable {
        let shortcutName: String
        let instruction: String
    }

    /// One step per REQUIRED shortcut — the five Set shortcuts, exact canonical names (sec 3).
    /// 4.I: the Get shortcut is no longer required (it's `getRecommendation` below).
    static var steps: [Step] {
        ChargeShortcuts.validLimitValues.map { value in
            Step(shortcutName: ChargeShortcuts.setName(for: value),
                 instruction: "In Shortcuts, create a shortcut named “\(ChargeShortcuts.setName(for: value))” with the single built-in “Set Battery Charge Limit” action set to \(value)%, not this app’s “Set Charge Limit” action. If your macOS labels it differently, choose the system’s built-in charge-limit action. No input, no other actions.")
        }
    }

    /// 4.I: Get is OPTIONAL — recommended where the OS still offers the action, skippable where it
    /// doesn't (27.0 removed it). We can't probe action availability, so we frame it honestly.
    static let getRecommendation =
        "Recommended: create a shortcut named “\(ChargeShortcuts.get)” with the single built-in “Get Battery Charge Limit” action (no Text wrapper). This lets the app read your live limit and show changes made outside the app; without it, the app shows its last-set value and confirms changes by battery behavior. If your macOS doesn’t offer that action, skip it."

    /// 4.I: the ONE honest line shown in DEGRADED mode (Get absent / OS-removed) — never a wall.
    static let degradedNote =
        "Live limit read-back is off. To enable it, create a shortcut named “\(ChargeShortcuts.get)” with the single built-in “Get Battery Charge Limit” action. If your macOS doesn’t offer that action, the app keeps confirming changes by battery behavior."

    /// Shown BEFORE the first invocation fires (the ONE-TIME grant, sec 2).
    static let grantExplanation = """
        The first time the app runs one of your shortcuts, macOS shows a one-time permission \
        prompt ("Battery" wants to access "Shortcuts"). Approve it once and every later run is \
        silent. If the prompt never appears and controls stay stuck, check System Settings → \
        Privacy & Security → Automation and enable Shortcuts for this app.
        """

    /// The 8h trust boundary — DOCUMENTED, deliberately not code-mitigated (Grok-accepted):
    /// the app executes whatever these names resolve to; read-verify validates the VALUE only.
    static let trustBoundaryNotice = """
        Keep these shortcuts single-action. The app executes whatever the shortcut names \
        resolve to — if another program rewrites their contents, the app will run that instead. \
        It verifies the resulting limit value, not what the shortcut did.
        """
}
