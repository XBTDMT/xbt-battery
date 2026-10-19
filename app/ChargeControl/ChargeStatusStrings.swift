import Foundation
import Combine

/// WI-N7: the user-string tables — sec 5 labels (status names the taxonomy) and the sec 6
/// taxon→string map. Pure data, testable for the normative wording (the `.automationBlocked`
/// string MUST name both hypotheses and both recovery routes, Grok B3).
enum ChargeStatusStrings {

    static func telemetryLabel(_ state: TelemetryChargeState, limit: ChargeLimitValue) -> String {
        switch state {
        case .charging:
            return "Charging"
        case .limitHold:
            if case .known(let v) = limit { return "Holding at limit (\(v)%)" }
            return "Holding at limit"
        case .idleInhibit:
            return "Not charging — system idle"
        case .ambiguousHold:
            return "Charging managed by macOS (check Optimized Battery Charging)"
        case .discharging:
            return "Discharging"
        case .unknown:
            return "—"
        }
    }

    /// LOW-1 (SPEC sec 3): DISPLAY-LAYER composition only — the ChargeStateMachine stays FROZEN
    /// and still publishes `.unknown`. When the telemetry state would render `.unknown` AND
    /// Phase-1 data says the pack is effectively full (FullyCharged OR SoC >= 99) AND on AC,
    /// show "Fully charged" instead of the bare "—". Every other state is unchanged.
    static func composedTelemetryLabel(_ state: TelemetryChargeState, limit: ChargeLimitValue,
                                       socPercent: Int?, fullyCharged: Bool, onAC: Bool) -> String {
        if state == .unknown, onAC, fullyCharged || (socPercent ?? 0) >= 99 {
            return "Fully charged"
        }
        return telemetryLabel(state, limit: limit)
    }

    /// nil = nothing to show (idle).
    static func commandLabel(_ status: CommandStatus) -> String? {
        switch status {
        case .idle:
            return nil
        case .confirming:
            return "Confirming…"
        case .confirmedStop:
            return "Hold confirmed"
        case .confirmedResume:
            return "Charging resumed"
        case .limitSetChargingToCap:
            return "Charging to the limit"
        case .requestedNoPromise:
            return "Requested — macOS may not resume charging from this state. If it doesn't, "
                 + "check Optimized Battery Charging or unplug and replug the charger."
        // At 100 there is no cap, so there is nothing to hold at and nothing to confirm. It says what
        // happened and stops: no OBC guidance, because nothing is being managed against the user here.
        case .requestedNoCapToHold:
            return "Limit set to 100% \u{2014} no cap, so there is nothing to hold at."
        case .confirmInconclusive(.systemInhibit):
            return "Couldn't confirm — the system paused charging while idle; "
                 + "the limit mechanism is not at fault."
        // The pack REACHED the target (max SoC in the window, within the slack band) and charging
        // stopped, with no hold flag.
        //
        // WHY THE OBC CLAUSE IS BACK. This sentence was once calmed to a plain completion, on the
        // rationale that `.noCleanHoldObserved` was the only terminal state a charge to a target of
        // 100 could reach — no cap there, so no cap-hold reason for macOS to publish, so nothing
        // was actually wrong. That rationale is DEAD: `BehaviorConfirm.commandIssued` no longer
        // arms a `.chargingToCap` window at `target == 100` at all, so this taxon now fires ONLY at
        // `target < 100` — which is exactly where this machine DOES publish the bit (150 of the 151
        // recorded `.limitHold` hours are at sub-100 caps). A missing flag at a cap the hardware
        // can signal is a real failed verify with a live hypothesis behind it, and stripping that
        // hypothesis out is a loss to the user, not a kindness.
        //
        // What it must NOT become again is the old "Stopped near the limit…" scare (explicit review
        // ruling). The register stays calm and observation-first — what happened, then the honest
        // limit of the evidence, then a short hedged hint. The FULL guidance ("is likely managing
        // charging", "check System Settings") stays with `.neverReachedLimit`, the case where
        // something else demonstrably IS managing charging; here it is only "may be why".
        //
        // CORRECTION (do not re-derive): an earlier version of this comment claimed macOS 27 never
        // publishes the hold flag "on this hardware (0 of 6,312 samples)". That was WRONG — the
        // 7-day raw window it came from sits entirely inside a limit==100 configuration. Do not
        // delete the hold signal.
        case .confirmInconclusive(.noCleanHoldObserved):
            return "Charging stopped at the limit, but macOS didn't report the hold flag, so the "
                 + "app couldn't verify it \u{2014} Optimized Battery Charging or a stale hold "
                 + "may be why."
        // The pack never got near the target AT ANY POINT in the window (its max SoC stayed outside
        // the slack band) — the flagship audit-B1 case (OBC parking at 80 against a target of 100).
        // "Stopped at the limit" would be a lie here; this one IS the "something else is managing
        // charging" case and keeps the FULL guidance, which is what separates it from the hedged
        // hint on `.noCleanHoldObserved` above.
        case .confirmInconclusive(.neverReachedLimit):
            return "Charging never reached the limit and never held there — Optimized Battery "
                 + "Charging or a stale hold is likely managing charging. Check System Settings, "
                 + "or unplug and replug."
        case .confirmFailed:
            return "The change didn't take effect within the expected window."
        case .setupRequired:
            return "Setup required — create the Battery Limit shortcuts."
        // B1 (soft failure): the genuinely TRANSIENT Set failures read soft + actionable ("Try again")
        // rather than a scary exit code / tool-launch error. The actionable taxons keep their guidance:
        // automationBlocked (permission route) and shortcutsBinaryAbsent (structural) are NOT transient,
        // and setupRequired keeps the walkthrough. Routing is unchanged; this is wording only.
        case .error(.nonzeroExit), .error(.launchFailed):
            return "Couldn't set the limit. Try again."
        case .error(let cause):
            return errorLabel(cause)
        }
    }

    /// The degraded limit-row provenance suffix. Re-sourced from the VERIFIED `.limitHold` state (the
    /// same already-classified state that drives the #26 glyph hold mark), not a charge-proximity guess,
    /// so the tag and the mark share one truth and the tag stays "· as set" at an ambiguous hold. We
    /// consume the classified state, never the raw NCR codes. Not paused (a pause stop is the user's).
    ///
    /// Override-aware: when the native macOS "Charge to 100% Now" suspends the cap for this cycle, the
    /// pack charges PAST the app's set limit. We cannot read the limit back in degraded mode, but
    /// `.charging` while the SoC is clearly past our own set limit (and that limit is below 100) can
    /// only mean the cap is not being enforced right now — under enforcement charging stops at the limit
    /// and flips to a hold, never continuing past it. We consume the already-classified `.charging`
    /// state, never the raw NCR codes. Boundary guard: require the SoC STRICTLY above the limit
    /// (`soc > v`, the live-validated +1 at limit 80), so the brief normal at-limit top-off
    /// (`soc == v`, about to flip to a hold) never flashes the override text.
    static func limitProvenanceTag(telemetryState: TelemetryChargeState, isPaused: Bool,
                                   limit: ChargeLimitValue, socPercent: Int?) -> String {
        if !isPaused, telemetryState == .charging, case .known(let v) = limit, v < 100,
           let soc = socPercent, soc > v {
            return "· Overridden Externally"
        }
        return (telemetryState == .limitHold && !isPaused) ? "· holding" : "· as set"
    }

    /// sec 5 Pause caveats — the honest envelope of the sanctioned mechanism.
    static let pauseFloorCaveat = "The native limit can't go below 80% — charge may still "
                                + "rise to 80%."
    static let pauseBleedCaveat = "Above 95%, the pack will discharge to 95% before holding."

    // MARK: - SWEEP H2: the pause the app INFERRED, which the user did not press
    //
    // A pause capture that will not decode still means a pause happened (only `pause()` writes that
    // key, and `pause()` is SET-THEN-CAPTURE — the hold was applied BEFORE the capture write, so bytes
    // that went wrong leave the pack capped). The app therefore shows a pause. What it must never do is
    // borrow the sentence for a pause the user pressed: it does not know the previous limit, and its
    // only exit sets 100 — the uncapped, battery-ageing direction. These three sentences are the
    // amendment the review required, not polish. Each says the condition, what it means for the pack,
    // and where Resume lands.

    /// The IDLE surface — under the Pause/Resume button, standing, from launch. The disclosure has to be
    /// here and not only after the Resume click: the user decides whether to press it.
    static let pauseRestorePointLostCaveat =
        "Pause data unreadable — the pack may still be held. Resume will set the limit to 100%."

    /// The scheduler's suspend note. The shared "Schedule paused — charging is paused" was the defect:
    /// in this case nobody paused charging, and saying so hides that the app is guessing.
    static let schedulePausedRestorePointLostNote =
        "Schedule paused — pause data unreadable, so the pack may still be held"

    /// After Resume lands. `engineNote` voice (lower-case fragment, like "limit was changed outside the
    /// app"). Never the word "restored": 100 is where we land because the previous limit is GONE.
    static let resumeRestorePointLostNote =
        "charging resumed — the limit from before the pause couldn't be read, so set it again"

    /// The re-sync failure surface (S-N4 fail-toward-visibility on the Get path).
    static func limitReadProblemLabel(_ problem: LimitReadProblem) -> String {
        switch problem {
        case .missingShortcut:   return "Setup required — the “Battery Limit Get” shortcut is missing."
        case .automationBlocked: return errorLabel(.automationBlocked)
        case .outputUnparseable: return errorLabel(.getOutputUnparseable)
        case .runnerFailure:     return "Couldn't read the charge limit."
        }
    }

    static func errorLabel(_ cause: ErrorCause) -> String {
        switch cause {
        case .automationBlocked:
            // The collapsed taxon (Grok B3): BOTH hypotheses, BOTH recovery routes, one string.
            return "Couldn't run your shortcut. A permission prompt may be waiting for "
                 + "approval — or this app may be silently denied. Approve the prompt if "
                 + "visible; otherwise check System Settings → Privacy & Security → Automation "
                 + "and enable Shortcuts for this app."
        case .shortcutsBinaryAbsent:
            return "The macOS shortcuts tool is missing — the charge limit can't be controlled."
        case .nonzeroExit(let code):
            return "The shortcut failed (exit \(code))."
        case .launchFailed:
            return "Couldn't launch the shortcuts tool."
        case .getOutputUnparseable:
            return "Couldn't read the charge limit — Apple may have changed the action's "
                 + "output format."
        case .limitMismatchAfterSet:
            return "The limit didn't stick (read-back mismatched twice) — something else may "
                 + "be controlling it."
        case .telemetryReadFailure:
            return "Battery telemetry is unavailable."
        }
    }
}

/// WI-N7 / sec 2 OBCAdvisor: when `.ambiguousHold` persists ≥3 min, surface guidance + the
/// VERIFIED Battery-pane deep-link. Sample-timestamp driven (deterministic under test).
@MainActor
final class OBCAdvisor: ObservableObject {

    static let persistence: TimeInterval = 180
    /// VERIFIED on 27.0: opens the Battery pane (sec 8a closed).
    static let batterySettingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
    static let guidanceText = "Optimized Battery Charging or a stale hold may be managing "
                            + "charging — check System Settings, or unplug/replug."

    @Published private(set) var guidance: String?
    private var ambiguousSince: TimeInterval?

    func observe(state: TelemetryChargeState, at time: TimeInterval) {
        guard state == .ambiguousHold else {
            ambiguousSince = nil
            guidance = nil
            return
        }
        if ambiguousSince == nil { ambiguousSince = time }
        if let since = ambiguousSince, time - since >= Self.persistence {
            guidance = Self.guidanceText
        }
    }
}

/// #29 A3 (DRAFT register, D-4b-β2): the Settings · General "Charge control" group's status-row words
/// and captions — the capability's single health-and-setup home. The status row is always present and
/// 3-state (Active / Needs setup / Read-back off); the transient `.unknown` setup state shows "Checking…".
/// Sentence case (D7), states a fact, no jargon. DRAFT: wording sign-off happens at the architect audit +
/// owner PNG gate; any true-up is a trivial follow-up (this is the register so it's a one-line change).
enum ChargeControlStatusStrings {
    static let active = "Active"
    static let activeDetail = "Charge control is set up and enforcing your limit."
    static let needsSetup = "Needs setup"
    static let needsSetupDetail = "Create the shortcuts below to turn on charge control."
    static let readbackOff = "Read-back off"
    static let readbackOffDetail = "The limit shown is the value the app last set — changes made outside the app can’t be seen here."
    static let checking = "Checking…"
}
