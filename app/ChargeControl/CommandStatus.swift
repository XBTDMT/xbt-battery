import Foundation

/// LAST-COMMAND STATUS — layer 2 of the two-layer status model (SPEC v4.0 sec 2). A distinct
/// type from `TelemetryChargeState`; the UI composes the two, never merges them.
enum CommandStatus: Equatable, Sendable {
    case idle
    case confirming
    case confirmedStop
    case confirmedResume
    /// Set landed with SoC below the new limit: charging legitimately continues toward the cap —
    /// no stop expectation (sec 2 arming rules). Lifecycle: resolves / clears / TTL-decays.
    case limitSetChargingToCap
    /// Issued from `.ambiguousHold` on a raise: the mechanism may not engage and that is not a
    /// failure (S-N2) — report, don't promise.
    case requestedNoPromise
    /// Issued at `target == 100`, where there is NO CAP — so there is no cap-hold reason for macOS to
    /// publish, `.limitHold` cannot occur, and exit E1 is unreachable. Arming a `.chargingToCap` window
    /// here would start a stopwatch that can only ever time out. Evidence: 33 rows at a full pack on AC
    /// all read `NotChargingReason == 0`, and 150 of the 151 recorded `.limitHold` hours cap at a
    /// SUB-100 SoC (the one exception spans 90 to 100 in a single hour bucket, so its dominant hold is
    /// consistent with a sub-100 cap plus a later climb rather than a hold AT 100).
    ///
    /// Split from `requestedNoPromise` deliberately. That case's string warns that macOS may not resume
    /// charging and points at Optimized Battery Charging — correct for a raise out of `.ambiguousHold`
    /// (Grok S-N2), and a FALSE ALARM here, where the pack is charging normally and the user simply
    /// removed the cap. `TopUpController` sets 100 on EVERY Top Up, so sharing the case would put that
    /// warning on screen after every single one.
    case requestedNoCapToHold
    case confirmInconclusive(InconclusiveReason)
    case confirmFailed
    /// Required shortcuts missing (sec 6) — SetupFlow surfaces the walkthrough.
    case setupRequired
    /// The collapsed `.automationBlocked` taxon and other runner failures map here via
    /// `ErrorCause` (sec 6: each taxon → state + user string).
    case error(ErrorCause)
}

enum InconclusiveReason: Equatable, Sendable {
    /// NCR transitioned to 0x80 (system idle inhibit) during an armed window while awake —
    /// the limit mechanism is not at fault; no failure is declared.
    case systemInhibit
    /// `.limitSetChargingToCap` decay after the pack REACHED the target — its MAX SoC in the window
    /// came within `capNearTargetSlack_pct` of it — with no flow, but the 0x01000000 hold never
    /// appeared.
    ///
    /// THIS IS A GENUINE FAILED VERIFY, and the comment here used to say the opposite. It described
    /// this as the normal shape of a charge to a target of **100**, where there is no cap and so no
    /// cap-hold reason to publish. THAT PATH NO LONGER EXISTS: `BehaviorConfirm.commandIssued` stops
    /// arming a `.chargingToCap` window at `target == 100` altogether, so every window that can
    /// still land here has a REAL cap (`target < 100`) — which is exactly where this machine DOES
    /// publish the bit (150 of the 151 recorded `.limitHold` hours are at sub-100 caps). A missing
    /// flag at a cap the hardware can signal has a live cause, so the user string names the
    /// hypothesis (OBC or a stale hold) instead of shrugging.
    ///
    /// Still NOT evidence the bit is gone: an earlier version of this comment claimed it "has never
    /// been observed on this hardware (0 of 6,312 samples)", which was a confounded read of a 7-day
    /// window that sat entirely at limit == 100.
    case noCleanHoldObserved
    /// `.limitSetChargingToCap` decay when the pack NEVER got near the target — its MAX SoC across
    /// the whole window stayed outside the slack band. The flagship audit-B1 case (Apple's OBC
    /// parking at 80 against a target of 100). Split from `noCleanHoldObserved` because "stopped at
    /// the limit" is simply untrue here: charging never approached the limit at any point, and
    /// something else is demonstrably managing it — so this one keeps the full guidance while
    /// `noCleanHoldObserved` carries only a short hint.
    case neverReachedLimit
}

/// Runner/reader failure causes (sec 6 taxonomy). Kept separate from CommandStatus so the
/// user-string table stays one-to-one with taxons.
enum ErrorCause: Equatable, Sendable {
    /// Empty-stderr hang → timeout: TCC deny / silent block / revoke / waiting prompt — ONE
    /// taxon, user string names BOTH hypotheses + both recovery routes (Grok B3).
    case automationBlocked
    case shortcutsBinaryAbsent
    case nonzeroExit(code: Int32)
    case launchFailed
    /// Get output had no extractable in-range integer ("Apple may have changed the action's
    /// output format" — sec 6).
    case getOutputUnparseable
    /// Read-back after Set mismatched twice (retry exhausted, S-N4).
    case limitMismatchAfterSet
    case telemetryReadFailure
}
