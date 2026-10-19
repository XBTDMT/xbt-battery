import XCTest
@testable import Battery

/// #29 C1 — the re-homed charge-control honesty layer.
///
/// Ten warning conditions lost their only call site in `44cfb79` and were excised as "dead" in
/// `f2f1eaa`; the app could be failing at charge control and say almost nothing (only the degraded
/// banner survived). These assert the PERSISTENT half — the states that now compete for the one
/// arbitrated banner slot — plus the strings the re-homed rows render.
final class ChargeHonestyTests: XCTestCase {

    // MARK: - nothing to confess

    func test_silentWhenHealthy() {
        XCTAssertNil(ChargeHonesty.problem(ChargeHonestyInputs()),
                     "a healthy charge-control layer shows no banner at all")
    }

    // MARK: - priority: a failed READ outranks everything

    func test_syncProblemWins_andCarriesItsOwnRemediation() {
        let msg = ChargeHonesty.problem(ChargeHonestyInputs(
            engineNote: "limit was changed outside the app",
            syncProblem: .automationBlocked,
            unverifiedExternalChange: true,
            telemetryReadFailed: true))
        XCTAssertEqual(msg, ChargeStatusStrings.limitReadProblemLabel(.automationBlocked))
        // The collapsed taxon must keep naming the permission route out (Grok B3) once surfaced.
        XCTAssertTrue(msg?.contains("Automation") ?? false,
                      "the surfaced string still names the Automation permission route")
    }

    func test_everyLimitReadProblemSurfacesItsOwnLabel() {
        for problem: LimitReadProblem in [.missingShortcut, .automationBlocked, .outputUnparseable, .runnerFailure] {
            XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(syncProblem: problem)),
                           ChargeStatusStrings.limitReadProblemLabel(problem),
                           "\(problem) must reach the user, not just the log")
        }
    }

    // MARK: - priority: engineNote, then statusNote

    func test_engineNoteOutranksStatusNote_matchingThePre29Coalesce() {
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            engineNote: "couldn't verify external changes",
            statusNote: "limit was changed outside the app")), "couldn't verify external changes")
    }

    func test_statusNoteSurfacesWhenTheEngineIsQuiet() {
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            statusNote: "limit was changed outside the app")), "limit was changed outside the app")
    }

    func test_notesOutrankTheUnverifiedCaveatAndTelemetry() {
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            engineNote: "limit was changed outside the app",
            unverifiedExternalChange: true,
            telemetryReadFailed: true)), "limit was changed outside the app")
    }

    // MARK: - the tail: unverified change, then telemetry

    func test_unverifiedExternalChange() {
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            unverifiedExternalChange: true, telemetryReadFailed: true)),
            ChargeHonestyStrings.unverifiedExternalChange)
    }

    func test_telemetryReadFailure_isTheLastResort() {
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(telemetryReadFailed: true)),
                       ChargeStatusStrings.errorLabel(.telemetryReadFailure))
    }

    // MARK: - the degraded suppressions (ISSUE-6 + the S-N4 amendment, preserved through the re-home)

    func test_degraded_suppressesTheReadBackComplaints() {
        // In permanent-degraded mode a read-back can NEVER succeed: both of these are the EXPECTED state,
        // not news, and the standing "Read-back is off" banner is the honest disclosure.
        XCTAssertNil(ChargeHonesty.problem(ChargeHonestyInputs(
            syncProblem: .automationBlocked, unverifiedExternalChange: true, readBackDegraded: true)))
    }

    func test_degraded_doesNotSuppressARealEngineNote() {
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            engineNote: "limit was changed outside the app", readBackDegraded: true)),
            "limit was changed outside the app",
            "an external change is news even when read-back is off")
    }

    func test_degraded_doesNotSuppressATelemetryFailure() {
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            telemetryReadFailed: true, readBackDegraded: true)),
            ChargeStatusStrings.errorLabel(.telemetryReadFailure),
            "telemetry is a separate subsystem from limit read-back")
    }

    // MARK: - arbitration into the ONE banner slot

    func test_chargeProblem_takesTheSlotOverTheDegradedNote() {
        var inputs = PopoverBannerInputs()
        inputs.degraded = true
        inputs.chargeProblem = true
        inputs.chargeProblemMessage = "limit was changed outside the app"
        let banner = PopoverBannerMapper.banner(for: inputs)
        XCTAssertEqual(banner?.message, "limit was changed outside the app")
        XCTAssertEqual(banner?.tint, .attention)
        XCTAssertEqual(banner?.action, .openGeneral, "the fix lives in Settings · General · Charge control")
    }

    func test_chargeProblem_takesTheSlotOverLowPowerAndAutoEnergy() {
        var inputs = PopoverBannerInputs()
        inputs.lowPower = true
        inputs.autoEnergyHold = true
        inputs.chargeProblem = true
        inputs.chargeProblemMessage = "Couldn't read the charge limit."
        XCTAssertEqual(PopoverBannerMapper.banner(for: inputs)?.message, "Couldn't read the charge limit.")
    }

    func test_chargeProblem_yieldsToSetupRequired() {
        // When the shortcuts don't exist yet, "set them up" is both more severe and more actionable than
        // "the read failed" — which is a CONSEQUENCE of the missing setup.
        var inputs = PopoverBannerInputs()
        inputs.setupRequired = true
        inputs.chargeProblem = true
        inputs.chargeProblemMessage = "Couldn't read the charge limit."
        XCTAssertEqual(PopoverBannerMapper.banner(for: inputs)?.message, PopoverBannerStrings.setupRequired)
    }

    func test_chargeProblem_yieldsToHelperAttention() {
        var inputs = PopoverBannerInputs()
        inputs.helperAttention = true
        inputs.helperMessage = "Approve the energy helper."
        inputs.chargeProblem = true
        inputs.chargeProblemMessage = "Couldn't read the charge limit."
        XCTAssertEqual(PopoverBannerMapper.banner(for: inputs)?.message, "Approve the energy helper.")
    }

    func test_noChargeProblem_leavesTheExistingArbitrationUntouched() {
        var inputs = PopoverBannerInputs()
        inputs.degraded = true
        XCTAssertEqual(PopoverBannerMapper.banner(for: inputs)?.message, PopoverBannerStrings.degraded)
    }

    // MARK: - the TRANSIENT half stays OFF the banner (it renders inline under the charge card)

    func test_transientStatesAreNotBannerInputs() {
        // A 4-second "Limit set to 80%" must never evict a standing helper warning from the one slot.
        // The honesty resolver has no channel for them at all — that is the design, asserted.
        XCTAssertNil(ChargeHonesty.problem(ChargeHonestyInputs()))
        XCTAssertNil(PopoverBannerMapper.banner(for: PopoverBannerInputs()))
    }

    /// The transient strings themselves must still be produced — they are what renders inline.
    func test_transientCommandLabelIsSourceTagged() {
        let label = ChargeStatusStrings.commandLabel(.confirmedStop)
        XCTAssertEqual(CommandSource.schedule.statusPrefix + (label ?? ""), "Scheduled: Hold confirmed")
        XCTAssertEqual(CommandSource.topUp.statusPrefix + (label ?? ""), "Top Up: Hold confirmed")
        XCTAssertEqual(CommandSource.appIntent.statusPrefix + (label ?? ""), "Shortcut: Hold confirmed")
        XCTAssertEqual(CommandSource.user.statusPrefix + (label ?? ""), "Hold confirmed")
    }

    func test_pauseCaveatsAreTheOnesTheCardRenders() {
        XCTAssertFalse(ChargeStatusStrings.pauseFloorCaveat.isEmpty)
        XCTAssertFalse(ChargeStatusStrings.pauseBleedCaveat.isEmpty)
    }
}

/// AUDIT B2 — the POST-HOC failure surface.
///
/// The quick-actions menu closes the popover before it runs the command (`showQuickActionsMenu`), so
/// `confirm.status` — whose only home is the popover's charge card — has no reader at the moment a
/// quick-action Set fails. `NotificationEvents.setupProblem` deliberately returns nil for
/// `.nonzeroExit` and `.limitMismatchAfterSet` (they are command outcomes, not "charge control is
/// broken"), and neither taxon is age-capped: `commandFailed` skips `scheduleVerdictExpiry`, which
/// every published VERDICT gets. So those two stand indefinitely with the weakest possible treatment.
///
/// The fix does not add a second slot. The missable failures join the same `ChargeHonesty.problem`
/// chain that already collapses the persistent states into ONE arbitrated banner, ranked just under a
/// failed limit READ; and the inline card note stands down only when the banner is carrying that exact
/// sentence, so a failure that loses the slot to a helper/setup banner still renders under the card.
final class ChargeHonestyMissedFailureTests: XCTestCase {

    // MARK: - which outcomes are "missable"

    func test_theTwoTaxaWithNoOtherSurfaceAreMissable() {
        // Neither fires a notification and neither ages out — the popover is their only home.
        XCTAssertEqual(ChargeHonesty.missedCommandFailure(.error(.nonzeroExit(code: 1))),
                       ChargeStatusStrings.commandLabel(.error(.nonzeroExit(code: 1))))
        XCTAssertEqual(ChargeHonesty.missedCommandFailure(.error(.limitMismatchAfterSet)),
                       ChargeStatusStrings.commandLabel(.error(.limitMismatchAfterSet)))
    }

    func test_theTaxaThatAlreadyNotifyAreNotMissable() {
        // `NotificationEvents.setupProblem` fires for all four: the user was told when it happened, and
        // `setupRequired` additionally owns its own banner. Repeating them here would be the stack.
        for status: CommandStatus in [.setupRequired,
                                      .error(.automationBlocked),
                                      .error(.shortcutsBinaryAbsent),
                                      .error(.launchFailed)] {
            XCTAssertNotNil(NotificationEvents.setupProblem(status: status),
                            "\(status) is expected to have its own notification surface")
            XCTAssertNil(ChargeHonesty.missedCommandFailure(status),
                         "\(status) already has a surface — a second one is the stack #29 forbids")
        }
    }

    func test_narrationAndInconclusiveVerdictsAreNotMissable() {
        // Not failures at all, or nothing the user can act on.
        // STALE-COMMENT CORRECTION: this used to read "`.noCleanHoldObserved` is the NORMAL end of a
        // charge to a target of 100". That path was deleted by 3af47ec — a target of 100 no longer arms
        // a window at all — so that taxon now fires only at target < 100, which is exactly where the
        // hold bit IS published. It is therefore a genuine failed verify, not a healthy completion, and
        // its string carries the OBC/stale-hold hint again. It stays OUT of the banner regardless: the
        // full guidance lives on `.neverReachedLimit`, and duplicating it here is the stack #29 forbids.
        for status: CommandStatus in [.idle, .confirming, .confirmedStop, .confirmedResume,
                                      .limitSetChargingToCap, .requestedNoPromise,
                                      .confirmInconclusive(.systemInhibit),
                                      .confirmInconclusive(.noCleanHoldObserved),
                                      .confirmInconclusive(.neverReachedLimit),
                                      .error(.getOutputUnparseable),
                                      .error(.telemetryReadFailure)] {
            XCTAssertNil(ChargeHonesty.missedCommandFailure(status))
        }
    }

    func test_confirmFailedIsNotMissable_becauseItAgesOut() {
        // A published verdict runs through `scheduleVerdictExpiry` (absolute age cap) and is retired on
        // unplug; the two runner failures above have neither. Scope stays on the pair with no exit.
        XCTAssertNil(ChargeHonesty.missedCommandFailure(.confirmFailed))
    }

    // MARK: - provenance: an autonomous failure must not read as something the user just did

    func test_theFailureCarriesItsSourceTag() {
        let bare = ChargeStatusStrings.commandLabel(.error(.nonzeroExit(code: 1))) ?? ""
        XCTAssertEqual(ChargeHonesty.missedCommandFailure(.error(.nonzeroExit(code: 1)),
                                                          prefix: CommandSource.schedule.statusPrefix),
                       "Scheduled: " + bare)
        XCTAssertEqual(ChargeHonesty.missedCommandFailure(.error(.limitMismatchAfterSet),
                                                          prefix: CommandSource.appIntent.statusPrefix),
                       "Shortcut: " + (ChargeStatusStrings.commandLabel(.error(.limitMismatchAfterSet)) ?? ""))
        XCTAssertEqual(ChargeHonesty.missedCommandFailure(.error(.nonzeroExit(code: 1)),
                                                          prefix: CommandSource.user.statusPrefix),
                       bare, "a user's own action takes no tag")
    }

    // MARK: - it enters the SAME single slot, ranked

    func test_theFailureOutranksTheNotesAndTheCaveats() {
        // A resume whose capture was invalidated leaves an engineNote AND then fails to write. "The
        // limit didn't stick" is the headline; the stale-capture context is not.
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            engineNote: "limit was changed outside the app",
            statusNote: "limit was changed outside the app",
            unverifiedExternalChange: true,
            telemetryReadFailed: true,
            lastCommandStatus: .error(.limitMismatchAfterSet))),
            ChargeStatusStrings.commandLabel(.error(.limitMismatchAfterSet)))
    }

    func test_aFailedReadStillOutranksTheFailedWrite() {
        // "We cannot see the limit at all" is the more fundamental fact, and its string names the
        // permission route out. Order preserved from the shipped chain.
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            syncProblem: .automationBlocked,
            lastCommandStatus: .error(.nonzeroExit(code: 1)))),
            ChargeStatusStrings.limitReadProblemLabel(.automationBlocked))
    }

    func test_degradedModeDoesNotSuppressAFailedWrite() {
        // Read-back being off explains a read-back COMPLAINT. It does not explain a shortcut that
        // exited nonzero — that command genuinely did not happen.
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            readBackDegraded: true,
            lastCommandStatus: .error(.nonzeroExit(code: 1)))),
            ChargeStatusStrings.commandLabel(.error(.nonzeroExit(code: 1))))
    }

    func test_aHealthyLastCommandChangesNothing() {
        XCTAssertNil(ChargeHonesty.problem(ChargeHonestyInputs(lastCommandStatus: .confirmedStop)))
        XCTAssertEqual(ChargeHonesty.problem(ChargeHonestyInputs(
            engineNote: "couldn't verify external changes",
            lastCommandStatus: .confirmedStop)), "couldn't verify external changes")
    }

    func test_theFailureCompetesForTheSlot_itDoesNotAddOne() {
        var inputs = PopoverBannerInputs()
        inputs.chargeProblem = true
        inputs.chargeProblemMessage = ChargeStatusStrings.commandLabel(.error(.nonzeroExit(code: 1)))!
        inputs.degraded = true
        inputs.lowPower = true
        XCTAssertEqual(PopoverBannerMapper.banner(for: inputs)?.message,
                       ChargeStatusStrings.commandLabel(.error(.nonzeroExit(code: 1))))
    }

    // MARK: - exactly one home: the inline note stands down ONLY when the banner has it

    func test_inlineNoteStandsDownWhenTheBannerCarriesTheSameSentence() {
        let msg = ChargeHonesty.missedCommandFailure(.error(.nonzeroExit(code: 1)))!
        XCTAssertTrue(ChargeHonesty.bannerAlreadyCarries(
            status: .error(.nonzeroExit(code: 1)), prefix: "", bannerMessage: msg))
    }

    func test_aFailureThatLostTheSlotStillRendersInline() {
        // Helper attention and setup outrank it. If the note also stood down the failure would vanish
        // entirely — the regression this rule exists to prevent.
        XCTAssertFalse(ChargeHonesty.bannerAlreadyCarries(
            status: .error(.nonzeroExit(code: 1)), prefix: "",
            bannerMessage: PopoverBannerStrings.setupRequired))
        XCTAssertFalse(ChargeHonesty.bannerAlreadyCarries(
            status: .error(.limitMismatchAfterSet), prefix: "", bannerMessage: nil))
    }

    func test_theSourceTagIsPartOfTheMatch() {
        // The banner and the card must agree on the tagged sentence, not on the bare one.
        let bare = ChargeStatusStrings.commandLabel(.error(.nonzeroExit(code: 1)))!
        XCTAssertFalse(ChargeHonesty.bannerAlreadyCarries(
            status: .error(.nonzeroExit(code: 1)), prefix: "Scheduled: ", bannerMessage: bare))
        XCTAssertTrue(ChargeHonesty.bannerAlreadyCarries(
            status: .error(.nonzeroExit(code: 1)), prefix: "Scheduled: ",
            bannerMessage: "Scheduled: " + bare))
    }

    func test_narrationIsNeverSuppressed() {
        // "Hold confirmed" / "Charging to the limit" only ever render inline; nothing may take them out.
        for status: CommandStatus in [.confirmedStop, .limitSetChargingToCap, .confirming] {
            XCTAssertFalse(ChargeHonesty.bannerAlreadyCarries(
                status: status, prefix: "", bannerMessage: ChargeStatusStrings.commandLabel(status)))
        }
    }
}

/// #29 C1 — the composed strings the re-homed rows render. A string interpolated inside a
/// `@ViewBuilder` cannot be asserted on, which is precisely how ten of them went dark unnoticed.
final class PopoverDetailStringsTests: XCTestCase {

    func test_topUpProgress_showsTheLiveClimb() {
        XCTAssertEqual(PopoverDetailStrings.topUpProgress(soc: 87), "87% → 100%")
        XCTAssertEqual(PopoverDetailStrings.topUpProgress(soc: 100), "100% → 100%")
    }

    func test_topUpProgress_fallsBackOnlyWhenTheSoCIsUnread() {
        XCTAssertEqual(PopoverDetailStrings.topUpProgress(soc: nil), "Top Up")
    }

    func test_historyEmpty_namesWhenRecordingStarted() {
        let since = Date(timeIntervalSince1970: 1_757_000_000)
        XCTAssertEqual(PopoverDetailStrings.historyEmpty(recordingSince: since) { _ in "4 Sep 2025" },
                       "Not enough history yet — recording since 4 Sep 2025.")
    }

    func test_historyEmpty_degradesWhenRecordingHasNotStarted() {
        XCTAssertEqual(PopoverDetailStrings.historyEmpty(recordingSince: nil) { _ in "unused" },
                       "Not enough history yet — check back soon.")
    }

    func test_theStandingNoticesAreNonEmptyAndActionable() {
        XCTAssertTrue(PopoverDetailStrings.maintenanceStalled.contains("disk"))
        XCTAssertTrue(PopoverDetailStrings.loginItemSuggestion.contains("reboot"))
    }
}
