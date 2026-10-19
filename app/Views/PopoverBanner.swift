import Foundation

/// #29 D5 (Cut D-2, banner goes live) — the concrete exception→banner mapping for the popover root,
/// layered over the pure severity model (`BannerSeverity` / `BannerArbiter`, DesignSystem).
///
/// The VIEW extracts the live exception state into `PopoverBannerInputs` (plain flags — no UI, no
/// model coupling); this pure mapper builds the candidate banners and arbitrates them to the single
/// winning slot (D5: helper attention > power/limit exception > informational; silent when healthy).
/// Kept pure so the routing is unit-testable host-app-free; the SwiftUI surface is `DSBanner` and the
/// tint is a semantic token the view maps to `DSColor`. Strings are the draft register (sentence
/// case, D7) and live here — a sibling of `ChargeStatusStrings` — never inline in the view (§4).

/// What the banner's single trailing action does (D5-A3): each exception routes to its standing home.
/// The charge-control family (setup required, degraded, helper attention) opens Settings · General's
/// Charge control group; the auto-energy hold opens Settings · Automation. (Low Power is action-less.)
enum PopoverBannerAction: Equatable, Sendable {
    case openGeneral
    case openAutomation
}

/// Semantic tint for the banner symbol — mapped to `DSColor` by the view (keeps this file SwiftUI-free).
enum BannerTint: Equatable, Sendable {
    case attention   // needs-action / enforced hold → DSColor.attention (orange)
    case lowPower    // Low Power Mode → DSColor.lowPower (yellow)
    case neutral     // calm/informational → DSColor.holding (secondary)
}

/// The resolved banner to show in the one root slot.
struct PopoverBannerContent: Equatable, Sendable {
    let severity: BannerSeverity
    let symbol: String
    let message: String
    let tint: BannerTint
    let actionTitle: String?
    let action: PopoverBannerAction?
}

/// The active-exception snapshot, extracted by the view from the live models (all plain values, so the
/// mapper stays pure/testable). Each flag is "is this exception currently active."
struct PopoverBannerInputs: Equatable, Sendable {
    var helperAttention = false
    var helperMessage = ""
    var setupRequired = false
    var degraded = false
    /// #29 C1 re-home: the charge-control honesty layer's single arbitrated PERSISTENT problem, already
    /// resolved by `ChargeHonesty.problem(_:)`. Empty/false = no standing charge-control problem.
    var chargeProblem = false
    var chargeProblemMessage = ""
    var autoEnergyHold = false
    var autoEnergyNote: String? = nil
    var lowPower = false
}

/// #29 C1 re-home — the PERSISTENT half of the charge-control honesty layer.
///
/// Ten warning conditions lost their only call site when `44cfb79` deleted the pre-#29 status-notes
/// block; `f2f1eaa` then excised the builders because nothing referenced them. The block STACKED its
/// lines (up to five at once). #29 replaced that idiom with one arbitrated banner slot, so the standing
/// problem states cannot simply come back as a stack: they are collapsed HERE into the single most
/// important sentence, which then competes for the banner slot like every other exception.
///
/// The TRANSIENT half (`commandLabel` + `CommandSource.statusPrefix`, `transientConfirmation`,
/// `pauseCaveat`) is deliberately NOT here — a 4-second confirmation must not evict a standing helper
/// warning from the one slot. Those render inline under the charge card.
///
/// AUDIT B2 amends that split in exactly one place, and narrowly: `commandLabel` is transient for every
/// outcome EXCEPT the two runner failures that neither notify nor age out (`missedCommandFailure`).
/// Those are standing states wearing a transient's clothes, and the surface that was supposed to carry
/// them is closed at the moment they occur — the quick-actions menu dismisses the popover before it
/// runs the command. They join the persistent chain; the rest still render inline, and only one of the
/// two homes ever draws a given sentence (`bannerAlreadyCarries`).
struct ChargeHonestyInputs: Equatable, Sendable {
    /// `ChargeLimitEngine.engineNote` — the engine's own accumulated caveat.
    var engineNote: String? = nil
    /// `BehaviorConfirm.statusNote` — the confirm layer's standing note. Second to `engineNote`, which is
    /// what the pre-#29 block did (`engine.engineNote ?? confirm.statusNote`).
    var statusNote: String? = nil
    /// `ChargeLimitEngine.syncProblem` — a FAILED limit read-back (S-N4 fail-toward-visibility).
    var syncProblem: LimitReadProblem? = nil
    /// `BehaviorConfirm.verdictWasDegraded` — the confirm window closed without a verified read-back.
    var unverifiedExternalChange = false
    /// `ChargeTelemetryPipeline.telemetryReadFailed`.
    var telemetryReadFailed = false
    /// `setupFlow.state == .readyDegraded` / `engine.readBackDegraded`. In permanent-degraded mode a
    /// read-back can NEVER succeed, so both read-back complaints are EXPECTED, not news — the standing
    /// "Read-back is off" banner (and the "· as set" provenance tag on the hero Limit row) is the honest
    /// disclosure there. Suppressing them here preserves the pre-#29 rule (ISSUE-6 + S-N4 amendment)
    /// rather than nagging about a state the user already accepted.
    var readBackDegraded = false
    /// AUDIT B2 — `BehaviorConfirm.status`, the LAST command's outcome. Only the two taxa
    /// `missedCommandFailure` recognises reach the banner; everything else here is inert.
    var lastCommandStatus: CommandStatus = .idle
    /// `CommandSource.statusPrefix` for that command, so an autonomous failure never reads as
    /// something the user just did. Empty for `.user`.
    var lastCommandPrefix: String = ""
}

/// Draft-register strings for the re-homed honesty layer (sentence case, D7). The other nine strings
/// already live in `ChargeStatusStrings` and are consumed, never re-typed.
enum ChargeHonestyStrings {
    static let unverifiedExternalChange = "Couldn't verify external changes (limit read-back unavailable)."
}

enum ChargeHonesty {
    /// The ONE standing charge-control problem worth the banner slot, most-severe first, or nil when
    /// charge control has nothing to confess.
    ///
    /// Order is by "how badly is the app failing at the job the user asked for":
    /// 1. a failed limit READ — the app cannot see the limit at all (and `automationBlocked` names the
    ///    permission route out);
    /// 2. a command the user asked for that did not happen and that they may never have seen fail
    ///    (AUDIT B2, `missedCommandFailure`);
    /// 3. the engine / confirm note — the limit in effect is not the one the user set;
    /// 4. an unverified external change — we could not confirm what happened;
    /// 5. telemetry unavailable — the readouts are blind, but charge control itself may be fine.
    static func problem(_ i: ChargeHonestyInputs) -> String? {
        if !i.readBackDegraded, let problem = i.syncProblem {
            return ChargeStatusStrings.limitReadProblemLabel(problem)
        }
        // AUDIT B2, ranked second: a write that did not happen outranks every note ABOUT a write,
        // and is not suppressed by degraded mode — read-back being off explains a read-back complaint,
        // never a shortcut that exited nonzero.
        if let failure = missedCommandFailure(i.lastCommandStatus, prefix: i.lastCommandPrefix) {
            return failure
        }
        if let note = i.engineNote ?? i.statusNote { return note }
        if i.unverifiedExternalChange && !i.readBackDegraded {
            return ChargeHonestyStrings.unverifiedExternalChange
        }
        if i.telemetryReadFailed { return ChargeStatusStrings.errorLabel(.telemetryReadFailure) }
        return nil
    }

    /// AUDIT B2 — the POST-HOC failure surface: the last command's outcome, but ONLY when the user
    /// could have missed the moment it happened and has nowhere else to learn of it.
    ///
    /// The quick-actions menu closes the popover BEFORE it runs the command (`showQuickActionsMenu`),
    /// so `confirm.status` — whose only home is the charge card inside that popover — has no reader at
    /// the instant a quick-action Set fails. Two taxa fall entirely through:
    ///   * they are deliberately excluded from `NotificationEvents.setupProblem` (a command outcome is
    ///     not "charge control is broken", and the SPEC declines to be chatty), and
    ///   * neither is age-capped — `commandFailed` skips the `scheduleVerdictExpiry` every published
    ///     VERDICT gets, so they simply stand until the next command.
    /// Both are also plainly actionable: set the limit again, or go look at what else is holding it.
    ///
    /// Everything else is excluded on purpose. `.setupRequired` / `.automationBlocked` /
    /// `.shortcutsBinaryAbsent` / `.launchFailed` already notify at the moment they happen, and setup
    /// additionally owns its own banner — re-stating them here is the stack the one arbitrated slot
    /// exists to prevent. Verdicts age out and retire on unplug. The inconclusive family is not a
    /// failure at all: `.noCleanHoldObserved` fires only at target < 100 since 3af47ec stopped arming at 100 — and that is exactly where the hold bit IS published, so a missing flag there is a real failed verify (it was: the NORMAL end of a charge to a target of 100), and
    /// nagging about a healthy machine is the other half of the brief.
    ///
    /// Pure, and returns the COMPOSED sentence (tag included) so the banner and the inline card note
    /// can be compared for equality rather than each re-deriving it.
    static func missedCommandFailure(_ status: CommandStatus, prefix: String = "") -> String? {
        guard case .error(let cause) = status else { return nil }
        switch cause {
        case .nonzeroExit, .limitMismatchAfterSet:
            guard let label = ChargeStatusStrings.commandLabel(status) else { return nil }
            return prefix + label
        case .automationBlocked, .shortcutsBinaryAbsent, .launchFailed,
             .getOutputUnparseable, .telemetryReadFailure:
            return nil
        }
    }

    /// EXACTLY ONE HOME. `nowNoteItems` (the Now note fold) carries the last command's line inline; `problem(_:)` may
    /// have just put the SAME sentence in the banner. The inline note stands down only in that case —
    /// matched on the composed, tagged string, and never on any other grounds. A failure that lost the
    /// slot to a helper or setup banner still renders under the card, which is the whole point: the
    /// promotion must not be able to make a failure disappear.
    static func bannerAlreadyCarries(status: CommandStatus, prefix: String,
                                     bannerMessage: String?) -> Bool {
        guard let failure = missedCommandFailure(status, prefix: prefix) else { return false }
        return bannerMessage == failure
    }
}

/// Draft-register banner strings (sentence case; trued against real behavior at build time).
enum PopoverBannerStrings {
    static let setupRequired = "Charge control needs a quick setup."
    static let degraded = "Read-back is off — the limit shown is the value the app last set."
    static let lowPowerBatteryLow = "Battery is low, so Low Power Mode is on."
    static let autoEnergyHold = "Low Power is held while the battery is low."
    // D5-A3 action labels (draft): the charge-control family routes to General, auto-energy to Automation.
    static let setupAction = "Set up"
    static let openSettingsAction = "Open settings"
}

/// #29 C1 re-home: the composed strings the re-homed rows render. They are here rather than interpolated
/// at the call site for the §4 reason ("never inline in the view") and for a sharper one — the whole C1
/// class of bug is a string with no reader, and a string that lives in a `@ViewBuilder` cannot be asserted
/// on. Every one of these has a test; the views only place them.
enum PopoverDetailStrings {
    /// The running Top Up pill. `soc` is live and updating throughout the climb; the pill showed a bare
    /// spinner because this had no reader, making a stalled climb indistinguishable from a working one.
    /// Falls back to the plain word only while the SoC is genuinely unread.
    static func topUpProgress(soc: Int?) -> String { soc.map { "\($0)% → 100%" } ?? "Top Up" }

    /// The 24-hour chart's empty state. Naming the start date is the whole point: "recording since today"
    /// and "recording since three weeks ago, still empty" are the same sentence without it.
    static func historyEmpty(recordingSince: Date?, formatted: (Date) -> String) -> String {
        guard let since = recordingSince else { return "Not enough history yet — check back soon." }
        return "Not enough history yet — recording since \(formatted(since))."
    }

    /// `HistoryStore.maintenanceStalled` — the raw days can never be pruned while this is true.
    static let maintenanceStalled = "History maintenance couldn't write to disk — older days aren't being compacted."

    /// B5: a row `JSONEncoder` rejected is DROPPED, not written as a literal `{}` and counted as saved.
    /// Dropping is the honest outcome, but it is still lost history, so it has to be said out loud —
    /// a silent skip is the same defect class as the silent `{}` it replaced. Takes the count because
    /// "one row" and "four hundred rows" are different problems.
    static func historyRowsDropped(_ n: Int) -> String {
        n == 1 ? "1 history row couldn\u{2019}t be saved and was dropped — that moment is missing from the charts."
               : "\(n) history rows couldn\u{2019}t be saved and were dropped — those moments are missing from the charts."
    }

    /// The one-time launch-at-login nudge (shown once, only while it is genuinely off).
    static let loginItemSuggestion = "Tip: enable this so your charge limit keeps being enforced after a reboot."
}

/// #29 D-3 hero status-line strings (sentence case, D7). Registered here, never inline in the view.
/// The discharging case is the D-3 caption true-up: "Holding at N%" is wrong while on battery.
enum PopoverHeroStrings {
    static let charging = "Charging"
    static let onBattery = "On battery"
    static let notCharging = "Not charging"
    static func holding(_ pct: Int) -> String { "Holding at \(pct)%" }
    static func paused(_ pct: Int) -> String { "Paused at \(pct)%" }
}

enum PopoverBannerMapper {
    /// Build the active-exception candidates and return the single arbitrated winner (nil = silent).
    static func banner(for inputs: PopoverBannerInputs) -> PopoverBannerContent? {
        var candidates: [PopoverBannerContent] = []

        if inputs.helperAttention {
            candidates.append(PopoverBannerContent(
                severity: .helperAttention, symbol: "exclamationmark.triangle.fill",
                message: inputs.helperMessage, tint: .attention,
                actionTitle: PopoverBannerStrings.openSettingsAction, action: .openGeneral))
        }
        if inputs.setupRequired {
            candidates.append(PopoverBannerContent(
                severity: .helperAttention, symbol: "exclamationmark.triangle.fill",
                message: PopoverBannerStrings.setupRequired, tint: .attention,
                actionTitle: PopoverBannerStrings.setupAction, action: .openGeneral))
        }
        // #29 C1 re-home: FIRST among the `.exception` candidates, so on a tie (arbitration resolves ties
        // to input order) an active charge-control failure outranks the standing "read-back is off" note
        // and the energy-mode holds. It stays BELOW `.helperAttention`: when charge control needs SETUP,
        // `setupRequired` is both more severe and the more actionable sentence.
        if inputs.chargeProblem {
            candidates.append(PopoverBannerContent(
                severity: .exception, symbol: "exclamationmark.triangle.fill",
                message: inputs.chargeProblemMessage, tint: .attention,
                actionTitle: PopoverBannerStrings.openSettingsAction, action: .openGeneral))
        }
        if inputs.degraded {
            candidates.append(PopoverBannerContent(
                severity: .exception, symbol: "info.circle.fill",
                message: PopoverBannerStrings.degraded, tint: .neutral,
                actionTitle: PopoverBannerStrings.openSettingsAction, action: .openGeneral))
        }
        if inputs.autoEnergyHold {
            candidates.append(PopoverBannerContent(
                severity: .exception, symbol: "lock.fill",
                message: inputs.autoEnergyNote ?? PopoverBannerStrings.autoEnergyHold, tint: .attention,
                actionTitle: PopoverBannerStrings.openSettingsAction, action: .openAutomation))
        }
        if inputs.lowPower {
            candidates.append(PopoverBannerContent(
                severity: .exception, symbol: "leaf.fill",
                message: PopoverBannerStrings.lowPowerBatteryLow, tint: .lowPower,
                actionTitle: nil, action: nil))
        }

        return BannerArbiter.resolve(candidates) { $0.severity }
    }
}

// MARK: - Now page honesty notes (spec 31 stage 2 · T12 · G-8 option F · G-9 option F2)

/// One transient honesty note on the Now page. The view gathers whichever of these exist; `NowNotes`
/// orders and counts them. The two keep-awake EXPLANATIONS (coverage, live effect) are not here: they live
/// on Automation's Keep awake row (G-8, ruled by the owner 2026-09-28: "i think F. agree?").
struct NowNote: Equatable, Sendable {
    /// Declaration order IS urgency order (most urgent first) — `allCases` and `rawValue` are the ranking.
    enum Kind: Int, CaseIterable, Sendable {
        case keepAwakeInterruption   // the claim was broken: work already lost (orange)
        case pauseCaveat             // the honest limits of Pause, standing under the Resume button
        case lastCommand             // the last command's source-tagged outcome (+ its transient confirmation)
        case topUp                   // the Top Up controller's narration
        case highPower               // High Power availability (orange)
        case autoEnergy              // the auto-energy note, when the banner does not carry it
    }
    let kind: Kind
    /// The FULL text. The hover card always carries this, unshortened.
    let text: String
    /// A hand-written short form of `text` for the resting line (G-9), used when `text` is over budget.
    /// Includes any source prefix. nil = derive one (`NowNotes.restForm`).
    var rest: String? = nil

    /// The tint the note had on Now before it folded: the interruption and High Power notes are orange.
    var isAttention: Bool { kind == .keepAwakeInterruption || kind == .highPower }
}

/// What the Now page shows at rest: the single most urgent note in its SHORT form (fits two lines, never
/// cut mid-sentence — G-9 "I say F2"), a "+N more ›" chip when N > 0, and the full list (most urgent first)
/// for the hover / tap card, whose FIRST entry is the lead's full text. `all` always holds EVERY note —
/// the fold hides nothing, it only stacks it behind one line.
struct NowNotesSummary: Equatable, Sendable {
    let all: [NowNote]
    var lead: NowNote { all[0] }
    var moreCount: Int { all.count - 1 }
    /// The link to the card, at the end of the rest line's last line. "+N more ›" when others are behind
    /// the lead; "more ›" when the lone note is shown SHORTENED (G-9: the full text is always in the card);
    /// nil for a lone note that rests as its full text.
    var moreLabel: String? {
        if moreCount > 0 { return "+\(moreCount) more ›" }
        return restIsShortened ? "more ›" : nil
    }
    /// Whether the rest line opens a card.
    var hasCard: Bool { moreLabel != nil }
    var cardTitle: String { all.count == 1 ? "The full note" : "All \(all.count) notes, most urgent first" }
    /// The lead as shown at rest.
    var restText: String { NowNotes.restForm(lead) }
    /// True when the resting line says less than the note does (the full text is in the card).
    var restIsShortened: Bool { restText != lead.text }
    /// VoiceOver on the rest line: with others behind it, the WHOLE note and "and N more"; a lone shortened
    /// note reads its rest form then "more" (the card holds the full text); a lone whole note reads itself.
    var accessibilityLabel: String {
        if moreCount > 0 { return "\(lead.text) and \(moreCount) more" }
        return restIsShortened ? "\(restText), more" : lead.text
    }
}

enum NowNotes {
    /// Orders by urgency (stable within a kind, so the caller's order between two `.lastCommand` lines
    /// survives) and drops only blank text — a note with nothing to say is not a note. `nil` when none.
    static func summary(_ notes: [NowNote]) -> NowNotesSummary? {
        let real = notes.enumerated().filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !real.isEmpty else { return nil }
        let ordered = real.sorted { a, b in
            a.element.kind.rawValue != b.element.kind.rawValue
                ? a.element.kind.rawValue < b.element.kind.rawValue
                : a.offset < b.offset
        }
        return NowNotesSummary(all: ordered.map(\.element))
    }

    // MARK: rest forms (G-9)

    /// Characters a resting note may use, so it lays out in TWO lines with the "+N more ›" chip reserved on
    /// the second. Sized from the real render (now-now-worst, 10.5 pt system font, note width ≈ 296 pt):
    /// a line holds ≈ 53–57 characters, the chip and its two leading spaces take 11 on line 2, so
    /// 53 + (53 − 11) = 95. `testEveryRestFormLaysOutInTwoLinesAtTheNoteWidth` checks the real layout.
    static let restBudget = 95

    /// The note as shown at rest, never cut mid-sentence and never a new fact. In order: the full text if it
    /// fits; the hand-written short form; the first sentence if it fits; a per-kind summary that only names
    /// what the note is about (the full text is one hover away).
    static func restForm(_ note: NowNote) -> String {
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= restBudget { return text }
        if let rest = note.rest, !rest.isEmpty, rest.count <= restBudget { return rest }
        let first = firstSentence(text)
        if first.count <= restBudget { return first }
        return fallback(note.kind)
    }

    /// Up to and including the first sentence-ending ". " / "? " / "! " (or the whole text if there is none).
    static func firstSentence(_ text: String) -> String {
        var previous: Character? = nil
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if let p = previous, ch == " ", ".?!".contains(p) { return String(text[..<index]) }
            previous = ch
            index = text.index(after: index)
        }
        return text
    }

    private static func fallback(_ kind: NowNote.Kind) -> String {
        switch kind {
        case .keepAwakeInterruption: return "Your Mac slept while this was on — anything running stopped."
        case .pauseCaveat:           return "Pause caveat — see the full note."
        case .lastCommand:           return "Last charge command — see the full note."
        case .topUp:                 return "Top Up — see the full note."
        case .highPower:             return "High Power — see the full note."
        case .autoEnergy:            return "Auto energy mode — see the full note."
        }
    }

    /// The owner-ruled short form (G-9, "I say F2"): the two sentences of `interruptionNote` reduced to the
    /// two things that matter — it slept, what was running stopped.
    static func interruptionRestForm(count: Int) -> String {
        "Your Mac slept \(count == 1 ? "once" : "\(count) times") while this was on — anything running stopped."
    }

    /// A hand-written short form (source prefix included) for the command outcomes whose full sentence is
    /// too long for two lines with a prefix; nil where the label already fits or its first sentence does.
    /// Each keeps the same claim as the full text and adds none; the full text is the card's first entry.
    static func commandRestForm(status: CommandStatus, prefix: String) -> String? {
        let short: String
        switch status {
        case .confirmInconclusive(.systemInhibit):
            short = "Couldn't confirm — the system paused charging while idle."
        case .confirmInconclusive(.noCleanHoldObserved):
            short = "Charging stopped at the limit, but the app couldn't verify the hold."
        case .confirmInconclusive(.neverReachedLimit):
            short = "Charging never reached the limit — Optimized Battery Charging is likely why."
        case .error(.automationBlocked):
            short = "Couldn't run your shortcut — a permission may be waiting or denied."
        case .error(.limitMismatchAfterSet):
            short = "The limit didn't stick — something else may be controlling it."
        case .error(.getOutputUnparseable):
            short = "Couldn't read the charge limit — the action's output may have changed."
        default:
            return nil
        }
        return prefix + short
    }
}
