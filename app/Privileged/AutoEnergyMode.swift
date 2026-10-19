import Foundation
import Shared   // EnergyModeValue / EnergySource (the validated {0,1,2} set values + per-source target)

// auto-energy-mode PHASE 1 (02-SPEC-auto-energy-mode.md). An app-side automation that watches live
// conditions and drives the EXISTING, helper-validated `setEnergyMode` op through `EnergyModeController`.
// It adds NO privilege: it calls the same {0,1,2} op the user can already invoke from the picker. Off by
// default; every automatic switch discloses on success; a manual choice holds until conditions next move.

// MARK: - System thermal level (sec 11) — mirrors ProcessInfo.ThermalState; kept here so the policy stays I/O-free.

/// The four-state system thermal level. `forcesLowPower` is the LOCKED Phase-2 trigger (sec 11): serious
/// or critical (>= serious). `fair` is early-warning only — the public enum collapses two internal levels
/// into it, so its severity is ambiguous — and NEVER forces Low. Mapped 1:1 from `ProcessInfo.ThermalState`
/// at the wiring edge (BatteryApp), so the policy below stays a pure, testable function.
enum ThermalLevel {
    case nominal, fair, serious, critical
    var forcesLowPower: Bool { self == .serious || self == .critical }
}

// MARK: - Pure policy (sec 3/11) — the headline TDD target, no I/O.

/// The `desiredMode`: the battery SOC sub-decision (with hysteresis), with a thermal force and a
/// plugged-High overlay on top (precedence thermal > battery-low > High > automatic, sec 12). The runner
/// carries the one hysteresis bit (`lowEngaged`), computed from SOC ALONE — neither the thermal force nor
/// the High overlay feeds it, so a thermal or High episode leaves no sticky Low once it releases (sec 11/12).
enum AutoEnergyPolicy {
    /// Enter Low at/below this SOC. Owner-tunable at acceptance (no other code change).
    static let lowEnterSoc = 20
    /// Release Low only at/above this SOC (the 20→30 hysteresis band).
    static let lowExitSoc = 30

    /// Pure, total function. Precedence: thermal force > battery-low > plugged-High (`highAllowed`) >
    /// Automatic. `nil` SOC (unknown) → battery `.automatic` with the flag cleared. The returned
    /// `lowEngaged` reflects ONLY the SOC branch (neither the thermal force nor the High overlay feeds it).
    /// `highAllowed` is the runner's collapse of plugged AND highAvailable AND the second opt-in (sec 12),
    /// so the policy never returns `.high` when High is not permitted.
    static func evaluate(thermal: ThermalLevel, soc: Int?, highAllowed: Bool,
                         lowEngaged: Bool) -> (desired: EnergyMode, lowEngaged: Bool) {
        // Battery sub-decision from SOC ALONE (the unchanged Phase 1 hysteresis) — this and ONLY this
        // feeds the returned `lowEngaged` bit.
        let batteryDesired: EnergyMode
        let newEngaged: Bool
        if let soc {
            if lowEngaged {
                (batteryDesired, newEngaged) = soc >= lowExitSoc ? (.automatic, false) : (.low, true)
            } else {
                (batteryDesired, newEngaged) = soc <= lowEnterSoc ? (.low, true) : (.automatic, false)
            }
        } else {
            (batteryDesired, newEngaged) = (.automatic, false)   // unknown SOC → no action, no flag
        }
        // Precedence (sec 12), highest to lowest: (1) a thermal force (serious/critical) → Low; (2) else
        // battery-low → Low; (3) else the plugged-High overlay (`highAllowed`) → High; (4) else Automatic.
        // The bit above already captured the SOC-only branch, so NEITHER the thermal force NOR the High
        // overlay ever feeds `lowEngaged` — no sticky Low from a thermal episode, no sticky state from a
        // High episode once you unplug or withdraw consent.
        let desired: EnergyMode
        if thermal.forcesLowPower || batteryDesired == .low {
            desired = .low
        } else if highAllowed {
            desired = .high
        } else {
            desired = .automatic
        }
        return (desired, newEngaged)
    }
}

// MARK: - Live conditions the runner reads (sec 2)

/// The live inputs the runner reads each evaluation: battery SOC, plugged state (selects the current
/// source), the High-Power hardware fact, the CURRENT (active) source's live Energy Mode (the comparison
/// baseline — `monitor.snapshot.energyMode`, the active `pmset -g` read), and (Phase 4, sec 13) the
/// INACTIVE source's live Energy Mode (from `pmset -g custom`) so the runner can release a transient Low
/// it set on a source that is not the one in use.
struct AutoEnergyConditions {
    let thermal: ThermalLevel   // sec 11: the live system thermal level (Phase 2 trigger)
    let soc: Int?
    let plugged: Bool
    let highAvailable: Bool     // sec 12: the live High-Power hardware fact (gates the Phase 3 branch)
    let currentSourceMode: EnergyMode    // the ACTIVE source's live mode (the Option 3 BRANCH baseline)
    let inactiveSourceMode: EnergyMode   // sec 13: the INACTIVE source's live mode (the release HARD-LIMIT guard)
}

// MARK: - The set seam (sec 0/6)

/// The runner drives sets through this seam. `EnergyModeController` conforms; a mock is injected in
/// tests. The completion (the ADDITIVE one on `setMode`) reports the outcome of EACH attempt — success,
/// honest failure, or a serialization drop — so the runner advances only on success and re-evaluates.
@MainActor
protocol AutoEnergyModeSetting: AnyObject {
    func setMode(_ mode: Int, source: Int,
                 completion: (@MainActor (Result<String, HelperClientError>) -> Void)?)
}

extension EnergyModeController: AutoEnergyModeSetting {}

// MARK: - The runner (sec 4–7)

@MainActor
final class AutoEnergyModeRunner: ObservableObject {

    /// Opt-in, persisted (UserDefaults), DEFAULT OFF. Toggling ON re-seeds + applies (init-on-enable);
    /// toggling OFF clears the note and leaves the runner inert.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: enabledKey)
            if enabled {
                // A fresh opt-in: drop any stale per-source baselines + hysteresis, then seed/apply for
                // the current source from scratch (sec 4/5 init-on-enable). The nil baselines force the
                // first evaluation to treat the current source as an edge.
                lastBattery = nil; lastCharger = nil; lowEngaged = false; recentlyFailed = nil
                evaluate()
            } else {
                autoNote = nil
                isHolding = false
            }
        }
    }

    /// The SECOND opt-in (sec 12): consent to auto-RAISE to High Power when plugged in, persisted,
    /// DEFAULT OFF. Narrower than `enabled` — its didSet persists + re-evaluates but does NOT reset the
    /// per-source baselines (only the full `enabled` opt-in does the fresh reset, being the opt-in to the
    /// whole automation). The High branch stays inert unless this is on AND `enabled` is on AND the
    /// hardware exposes High Power (the runner ANDs `highAvailable` into `highAllowed`).
    @Published var highWhenPluggedEnabled: Bool {
        didSet {
            guard highWhenPluggedEnabled != oldValue else { return }
            defaults.set(highWhenPluggedEnabled, forKey: highEnabledKey)
            evaluate()   // a consent change re-evaluates; it does NOT reset the baselines.
        }
    }

    /// The honesty spine: the disclosure published on a successful auto-switch, the DERIVED hold note
    /// when a manual choice diverges from the policy, or an honest failure note. `nil` when in sync.
    @Published private(set) var autoNote: String?

    /// ISSUE-9 disclosure (additive — NO policy/precedence/latch change): true iff the current persistent
    /// status is a BRANCH-A protection hold (`desired == .low`, i.e. battery-low or thermal). The popover
    /// renders the status salient + drives the picker-local "why" affordance when this is set. Kept in
    /// LOCKSTEP with `autoNote` at EVERY assignment — including the drive completions, which are the
    /// authority after a drive (afterSet `evaluate()` does not reassign the note). Purely derived from the
    /// existing BRANCH-A condition; no decision changes.
    @Published private(set) var isHolding = false

    /// Per-source baselines — the mode the policy LAST computed for each source (sec 4). `nil` = the
    /// "unknown" sentinel that forces a first evaluation to treat the source as an edge. Manual picker
    /// changes NEVER touch these; the policy reasserts only when its computed desired next changes.
    private(set) var lastBattery: EnergyMode?
    private(set) var lastCharger: EnergyMode?

    /// The one bit of hysteresis state (sec 3). SOC is global so the bit is source-agnostic.
    private(set) var lowEngaged = false

    private let setter: AutoEnergyModeSetting
    private let liveConditions: @MainActor () -> AutoEnergyConditions
    private let defaults: UserDefaults
    private let enabledKey: String
    private let highEnabledKey: String

    /// The runner's own in-flight bit so it never issues overlapping sets (which the controller would
    /// drop anyway); a newer edge during a set is deferred and picked up by the completion's re-evaluate.
    private var inFlight = false

    /// The (source, desired) of the most recent attempt that did NOT succeed (honest failure or drop).
    /// Blocks an immediate identical re-drive within the same synchronous re-evaluate (so a persistent
    /// failure can't spin); cleared at the start of the next EXTERNAL evaluation, which retries once.
    private var recentlyFailed: Attempt?

    private struct Attempt: Equatable { let source: EnergySource; let mode: EnergyMode }

    init(setter: AutoEnergyModeSetting,
         conditions: @escaping @MainActor () -> AutoEnergyConditions,
         defaults: UserDefaults = .standard,
         enabledKey: String = "autoEnergyModeEnabled",
         highEnabledKey: String = "autoEnergyHighWhenPluggedEnabled") {
        self.setter = setter
        self.liveConditions = conditions
        self.defaults = defaults
        self.enabledKey = enabledKey
        self.highEnabledKey = highEnabledKey
        self.enabled = defaults.bool(forKey: enabledKey)                    // init assignment does NOT fire didSet
        self.highWhenPluggedEnabled = defaults.bool(forKey: highEnabledKey) // ditto — the second opt-in seeds inertly
    }

    /// The single decision pass (sec 4–6). Triggered EXTERNALLY by the snapshot stream and the
    /// opt-in/enable transition; and INTERNALLY (`afterSet`) by every set completion, to catch a newer
    /// edge / recover a dropped set without waiting for an unrelated trigger.
    func evaluate(afterSet: Bool = false) {
        guard enabled else { autoNote = nil; isHolding = false; return }
        if !afterSet { recentlyFailed = nil }   // a fresh external trigger → allow one retry

        let c = liveConditions()
        let activeSource: EnergySource = c.plugged ? .charger : .battery
        let inactiveSource: EnergySource = c.plugged ? .battery : .charger
        // The High branch's three preconditions collapsed into ONE boolean (sec 12): plugged AND the
        // hardware fact AND the second opt-in.
        let highAllowed = c.plugged && c.highAvailable && highWhenPluggedEnabled
        let (desired, newEngaged) = AutoEnergyPolicy.evaluate(thermal: c.thermal, soc: c.soc,
                                                              highAllowed: highAllowed, lowEngaged: lowEngaged)
        lowEngaged = newEngaged

        let activeLive = c.currentSourceMode
        // Never act on an unread active mode (robustness — never a spurious set on a failed/absent read).
        guard activeLive != .unavailable else { return }

        // ===== ACTIVE SOURCE — Option 3 BRANCH A/B/C (sec 15.1 / 16) =====
        // `desired == .low` IS the protection signal (sec 15.0): the pure policy emits `.low` ONLY under
        // thermal or battery-low, so the runner reads "a protection is firing" straight off the output.
        let baseline = last(for: activeSource)
        // SENTINEL RULE (16 must-fix 1): a manual is "present" ONLY when the baseline holds a REAL mode
        // (not the nil sentinel of a cold start / post-enable reset) and the live mode diverges from it.
        let manualPresent = baseline != nil && activeLive != baseline! && activeLive != .unavailable

        let status: String?
        var activeTarget: EnergyMode? = nil   // mode to drive on the active source (nil = no drive)
        var adoptValue: EnergyMode? = nil     // in-sync value to adopt into last[active] (no set)

        if desired == .low {
            // BRANCH A — protection is ABSOLUTE: it overrides any manual choice. Driving is gated on
            // "live != .low" (NOT the old desired-vs-baseline edge), so a manual High under sustained
            // protection is reasserted each time the user re-raises it.
            status = holdStatus(c)
            if activeLive != .low { activeTarget = .low } else { adoptValue = .low }
        } else if manualPresent {
            // BRANCH B — outside protection, the manual choice STANDS: no drive, baseline untouched.
            status = manualStatus(activeLive)
        } else {
            // BRANCH C — express auto's own desired (High when plugged+consented, else Automatic). When
            // `live != last` is false (no manual) and the cause has cleared, this is the active-source
            // counterpart of the section 13 release (auto undoes its OWN Low).
            if activeLive != desired {
                activeTarget = desired
                status = autoStatus(desired)
            } else {
                // In sync: a held High is remarkable; an unremarkable Automatic renders as no banner
                // (sec 15.3, owner-tunable). Adopt the live value as auto's baseline (no set) so a later
                // manual change is recognised as `manualPresent`.
                adoptValue = desired
                status = (desired == .high) ? autoStatus(.high) : nil
            }
        }

        if !afterSet { autoNote = status; isHolding = (desired == .low) }   // PERSISTENT status (15.3); isHolding ⟺ BRANCH-A
        if let adoptValue { setLast(activeSource, adoptValue) }  // adopt the in-sync value (no set)
        if let activeTarget { driveIfAllowed(activeTarget, activeSource, successStatus: status) }

        // ===== INACTIVE SOURCE — section 13 release-only, Low-only =====
        // Undo a TRANSIENT Low auto set on the inactive source once its Low-cause clears — but ONLY if the
        // inactive live is still that `.low` (THE HARD LIMIT: never revert a since-changed manual). last is
        // the authority (advanced on success), so a lagging snapshot never re-triggers a release. Never
        // drive an inactive source toward Low or High — only release its own transient Low to Automatic.
        let inactiveLive = c.inactiveSourceMode
        let inactiveStillWantsLow = c.thermal.forcesLowPower || lowEngaged
        if last(for: inactiveSource) == .low && !inactiveStillWantsLow && inactiveLive == .low {
            // If the active branch just drove (inFlight), this defers and is picked up by the completion's
            // re-evaluate (active-first sequencing via single-in-flight).
            driveIfAllowed(.automatic, inactiveSource, successStatus: status)
        }
    }

    // MARK: - Driving a set (success-callback-only advancement; re-evaluate-after-set)

    /// Drive `mode` on `source` ONLY if no set is in flight and this exact attempt did not just fail (the
    /// recently-failed guard now covers BRANCH A overrides, BRANCH C drives, AND inactive releases alike —
    /// sec 16 must-fix 5). On success it advances `last[source]` and publishes `successStatus`; on
    /// failure/drop it sets recently-failed and publishes the honest-failure note; either way it
    /// re-evaluates against live conditions (catching a newer edge / a deferred inactive release).
    private func driveIfAllowed(_ mode: EnergyMode, _ source: EnergySource, successStatus: String?) {
        guard !inFlight, recentlyFailed != Attempt(source: source, mode: mode) else { return }
        guard let value = setValue(mode) else { return }
        inFlight = true
        setter.setMode(value, source: source.rawValue) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success:
                // Advance the baseline + publish the status ONLY here (never optimistically before success).
                self.setLast(source, mode)
                self.recentlyFailed = nil
                self.autoNote = successStatus
                self.isHolding = (mode == .low)   // the only .low drive is the BRANCH-A active-source hold
            case .failure(let error):
                // Honest failure OR serialization drop: do NOT advance last; note honestly; block an
                // immediate identical re-drive so a persistent failure can't spin.
                self.recentlyFailed = Attempt(source: source, mode: mode)
                self.autoNote = self.failureNote(error, desired: mode)
                self.isHolding = false            // a failure note is not a hold
            }
            // Re-evaluate against LIVE conditions: catch a newer edge / recover a drop / run the deferred
            // inactive release after the active set (active-first sequencing via single-in-flight).
            self.evaluate(afterSet: true)
        }
    }

    // MARK: - Per-source baseline access

    private func last(for source: EnergySource) -> EnergyMode? {
        source == .charger ? lastCharger : lastBattery
    }
    private func setLast(_ source: EnergySource, _ mode: EnergyMode?) {
        if source == .charger { lastCharger = mode } else { lastBattery = mode }
    }

    /// Map a policy desired to the validated set value. The policy now yields {.automatic, .low, .high}
    /// (Phase 3 added the plugged-High branch); `.unavailable` is never a desired → nil guards it out.
    private func setValue(_ mode: EnergyMode) -> Int? {
        switch mode {
        case .automatic:   return EnergyModeValue.automatic.rawValue
        case .low:         return EnergyModeValue.low.rawValue
        case .high:        return EnergyModeValue.high.rawValue
        case .unavailable: return nil
        }
    }

    // MARK: - Notes (owner-tunable wording, sec 5)

    private func label(_ mode: EnergyMode) -> String {
        switch mode {
        case .automatic:   return "Automatic"
        case .low:         return "Low Power"
        case .high:        return "High Power"
        case .unavailable: return "—"
        }
    }
    /// The Low reason, DERIVED from live conditions at call time (sec 11), leading with the higher-priority
    /// cause: a hot system → "(high temperature)", else battery-low → "(battery below 20%)". Re-reading
    /// `liveConditions()` here keeps the cause out of the policy return (it stays `(desired, lowEngaged)`).
    private func reason(_ mode: EnergyMode) -> String {
        switch mode {
        case .high:
            // sec 12: the plugged-High disclosure reads "Auto: High Power (plugged in)".
            return " (plugged in)"
        case .low:
            // The Low reason leads with the higher-priority cause: a hot system, else battery-low.
            return liveConditions().thermal.forcesLowPower
                ? " (high temperature)"
                : " (battery below \(AutoEnergyPolicy.lowEnterSoc)%)"
        default:
            return ""
        }
    }
    private func disclosure(_ mode: EnergyMode) -> String {
        "Auto: \(label(mode))\(reason(mode))"
    }
    /// BRANCH A persistent status (sec 15.3): auto holds Low for an ACTIVE protection, naming the
    /// higher-priority cause (thermal leads battery-low). Derived from THIS pass's conditions.
    private func holdStatus(_ c: AutoEnergyConditions) -> String {
        let cause = c.thermal.forcesLowPower ? "high temperature" : "battery below \(AutoEnergyPolicy.lowEnterSoc)%"
        return "Auto holds Low Power: \(cause)"
    }
    /// BRANCH B persistent status (sec 15.3): a manual choice stands OUTSIDE protection; auto defers to it.
    private func manualStatus(_ live: EnergyMode) -> String { "Manual \(label(live)) in effect" }
    /// BRANCH C persistent status (sec 15.3): auto's own expressed desired (== the success disclosure).
    private func autoStatus(_ mode: EnergyMode) -> String { disclosure(mode) }
    private func failureNote(_ error: HelperClientError, desired: EnergyMode) -> String {
        switch error {
        case .unreachable: return "Auto couldn’t set \(label(desired)) — approve the energy helper."
        case .helperError: return "Auto couldn’t set \(label(desired)); will retry."
        }
    }
}
