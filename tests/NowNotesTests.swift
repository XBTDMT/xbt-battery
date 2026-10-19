import XCTest
import AppKit
@testable import Battery

/// Spec 31 stage 2 (T12) · G-8 option F — the Now page folds its honesty notes behind ONE line at rest:
/// the most urgent note in full, "+N more ›" when there are others, and a card that lists them all.
/// The ordering / counting is pure so the "most urgent first" and "nothing dropped" claims are pinned here.
final class NowNotesTests: XCTestCase {

    private func note(_ kind: NowNote.Kind, _ text: String? = nil) -> NowNote {
        NowNote(kind: kind, text: text ?? "\(kind)")
    }

    private var everyNote: [NowNote] { NowNote.Kind.allCases.map { note($0) } }

    // MARK: 0 / 1 / many

    func testNoNotesRendersNothing() {
        XCTAssertNil(NowNotes.summary([]))
    }

    func testBlankTextIsNotANote() {
        XCTAssertNil(NowNotes.summary([NowNote(kind: .topUp, text: ""), NowNote(kind: .autoEnergy, text: "  \n ")]))
    }

    func testExactlyOneNoteHasNoMoreChip() {
        let s = NowNotes.summary([note(.highPower, "High Power isn't available")])
        XCTAssertEqual(s?.lead.text, "High Power isn't available")
        XCTAssertEqual(s?.moreCount, 0)
        XCTAssertNil(s?.moreLabel)
        XCTAssertEqual(s?.accessibilityLabel, "High Power isn't available", "no \"and N more\" for a lone note")
        XCTAssertEqual(s?.all.count, 1)
    }

    func testManyNotesCountTheRestAndLabelTheChip() {
        let s = NowNotes.summary(everyNote)
        XCTAssertEqual(s?.all.count, 6)
        XCTAssertEqual(s?.moreCount, 5)
        XCTAssertEqual(s?.moreLabel, "+5 more ›")
        XCTAssertEqual(s?.cardTitle, "All 6 notes, most urgent first")
    }

    func testTwoNotesSayOneMore() {
        let s = NowNotes.summary([note(.autoEnergy), note(.topUp)])
        XCTAssertEqual(s?.moreCount, 1)
        XCTAssertEqual(s?.moreLabel, "+1 more ›")
        XCTAssertEqual(s?.accessibilityLabel, "topUp and 1 more")
    }

    // MARK: order

    func testUrgencyOrderIsInterruptionPauseCommandTopUpHighPowerAuto() {
        XCTAssertEqual(NowNote.Kind.allCases,
                       [.keepAwakeInterruption, .pauseCaveat, .lastCommand, .topUp, .highPower, .autoEnergy])
        // Fed in the reverse order, the card still reads most urgent first.
        let s = NowNotes.summary(everyNote.reversed())
        XCTAssertEqual(s?.all.map(\.kind), NowNote.Kind.allCases)
    }

    func testTheInterruptionNoteWinsWhenPresent() {
        var notes = everyNote.reversed() as [NowNote]
        XCTAssertEqual(NowNotes.summary(notes)?.lead.kind, .keepAwakeInterruption)
        notes.removeAll { $0.kind == .keepAwakeInterruption }
        XCTAssertEqual(NowNotes.summary(notes)?.lead.kind, .pauseCaveat, "the next most urgent leads once it is gone")
    }

    func testSameKindKeepsTheCallersOrder() {
        // The last command's outcome and its transient confirmation are both `.lastCommand`.
        let a = note(.lastCommand, "Top Up: Set the limit to 100"), b = note(.lastCommand, "Limit set to 80%")
        XCTAssertEqual(NowNotes.summary([a, b])?.all.map(\.text), [a.text, b.text])
    }

    // MARK: nothing dropped

    func testTheCardListsEveryNoteExactlyOnce() {
        let input = everyNote + [note(.lastCommand, "a second command line"), note(.topUp, "a second Top Up line")]
        let s = NowNotes.summary(input)!
        XCTAssertEqual(s.all.count, input.count)
        XCTAssertEqual(s.moreCount, input.count - 1)
        for n in input { XCTAssertEqual(s.all.filter { $0 == n }.count, 1, "\(n.text) missing or duplicated") }
    }

    func testLeadIsTheFirstCardRow() {
        let s = NowNotes.summary(everyNote.shuffled())!
        XCTAssertEqual(s.lead, s.all.first)
    }

    // MARK: tints

    func testOnlyTheInterruptionAndHighPowerNotesAreAttentionToned() {
        for kind in NowNote.Kind.allCases {
            XCTAssertEqual(note(kind).isAttention, kind == .keepAwakeInterruption || kind == .highPower, "\(kind)")
        }
    }

    // MARK: G-9 (F2) — every note has a rest form that fits two lines and is never cut mid-sentence

    /// Every command status the Now page can print, with every source prefix.
    private var everyCommandStatus: [CommandStatus] {
        [.confirming, .confirmedStop, .confirmedResume, .limitSetChargingToCap, .requestedNoPromise,
         .requestedNoCapToHold, .confirmInconclusive(.systemInhibit), .confirmInconclusive(.noCleanHoldObserved),
         .confirmInconclusive(.neverReachedLimit), .confirmFailed, .setupRequired,
         .error(.automationBlocked), .error(.shortcutsBinaryAbsent), .error(.nonzeroExit(code: 1)),
         .error(.launchFailed), .error(.getOutputUnparseable), .error(.limitMismatchAfterSet),
         .error(.telemetryReadFailure)]
    }
    private let prefixes: [CommandSource] = [.user, .schedule, .topUp, .appIntent]

    /// Every string a Now note can carry, as the view builds it (kind, full text, explicit rest form).
    private var everyNowNote: [NowNote] {
        var out: [NowNote] = []
        for c in [1, 2, 9, 12, 100] {
            out.append(NowNote(kind: .keepAwakeInterruption, text: KeepAwakeController.interruptionNote(c)!,
                               rest: NowNotes.interruptionRestForm(count: c)))
        }
        for t in [ChargeStatusStrings.pauseFloorCaveat, ChargeStatusStrings.pauseBleedCaveat,
                  ChargeStatusStrings.pauseRestorePointLostCaveat,
                  "battery level unreadable - paused at the 80% floor"] {
            out.append(NowNote(kind: .pauseCaveat, text: t))
        }
        for status in everyCommandStatus {
            guard let label = ChargeStatusStrings.commandLabel(status) else { continue }
            for source in prefixes {
                out.append(NowNote(kind: .lastCommand, text: source.statusPrefix + label,
                                   rest: NowNotes.commandRestForm(status: status, prefix: source.statusPrefix)))
            }
        }
        for t in ["Limit set to 80%", "Limit set to 100%"] { out.append(NowNote(kind: .lastCommand, text: t)) }
        for t in ["Resume charging first", "Top Up needs a known limit — open and let it read first",
                  "Top Up couldn't start", "Top Up ended — the limit was changed.",
                  "Top Up timed out — restoring your limit.", "Top Up ended — unplugged. Limit restored.",
                  "Top Up cancelled. Limit restored.", "Top Up: limit restored to 80%",
                  "Top Up: limit restored to 80% — read-back unavailable, confirmed by behavior",
                  "Top Up: couldn't set your limit back to 80% — set it manually."] {
            out.append(NowNote(kind: .topUp, text: t))
        }
        for why in ["the capability read was cut short", "pmset exited 1", String(repeating: "a very long reason ", count: 6)] {
            out.append(NowNote(kind: .highPower, text: HighPowerCapability.unknown(why).note!))
        }
        for t in ["Auto: High Power (plugged in)", "Auto: Low Power (battery below 20%)",
                  "Auto: Low Power (high temperature)", "Auto holds Low Power: high temperature",
                  "Auto holds Low Power: battery below 20%", "Manual Automatic in effect", "Manual High Power in effect",
                  "Auto couldn\u{2019}t set Low Power \u{2014} approve the energy helper.",
                  "Auto couldn\u{2019}t set High Power; will retry."] {
            out.append(NowNote(kind: .autoEnergy, text: t))
        }
        return out
    }

    func testTheRestBudgetIs95Characters() {
        XCTAssertEqual(NowNotes.restBudget, 95)
    }

    func testEveryNoteHasARestFormWithinTheBudget() {
        for n in everyNowNote {
            let rest = NowNotes.restForm(n)
            XCTAssertLessThanOrEqual(rest.count, NowNotes.restBudget, "\(n.kind): \(rest)")
            XCTAssertFalse(rest.isEmpty)
        }
    }

    func testARestFormIsNeverCutMidSentence() {
        for n in everyNowNote {
            let rest = NowNotes.restForm(n)
            XCTAssertFalse(rest.contains("…") && !n.text.contains("…"), "an ellipsis was added: \(rest)")
            // Either the whole note, or a text that ends like a sentence (a full stop / the note's own last
            // character), or a fixed summary — never a prefix of the note.
            if rest != n.text, n.text.hasPrefix(rest) {
                XCTAssertTrue(rest.hasSuffix(".") || rest.hasSuffix("?") || rest.hasSuffix("!"),
                              "cut mid-sentence: \(rest)")
            }
        }
    }

    func testAShortNoteIsItsOwnRestForm() {
        for n in everyNowNote where n.text.count <= NowNotes.restBudget {
            XCTAssertEqual(NowNotes.restForm(n), n.text)
        }
    }

    func testTheInterruptionRestFormIsTheRuledShortSentence() {
        XCTAssertEqual(NowNotes.interruptionRestForm(count: 1),
                       "Your Mac slept once while this was on — anything running stopped.")
        XCTAssertEqual(NowNotes.interruptionRestForm(count: 3),
                       "Your Mac slept 3 times while this was on — anything running stopped.")
        for c in [1, 2, 5] {
            let n = NowNote(kind: .keepAwakeInterruption, text: KeepAwakeController.interruptionNote(c)!,
                            rest: NowNotes.interruptionRestForm(count: c))
            XCTAssertEqual(NowNotes.restForm(n), NowNotes.interruptionRestForm(count: c))
        }
    }

    func testFirstSentenceStopsAtTheFirstFullStopFollowedBySpace() {
        XCTAssertEqual(NowNotes.firstSentence("One two. Three four."), "One two.")
        XCTAssertEqual(NowNotes.firstSentence("No stop here"), "No stop here")
        XCTAssertEqual(NowNotes.firstSentence("Only one."), "Only one.")
    }

    func testAnUnwritableRestFormFallsBackToAPerKindSummaryNotACut() {
        let long = String(repeating: "word ", count: 60)
        for kind in NowNote.Kind.allCases {
            let rest = NowNotes.restForm(NowNote(kind: kind, text: long))
            XCTAssertLessThanOrEqual(rest.count, NowNotes.restBudget)
            XCTAssertNotEqual(rest, long)
            XCTAssertFalse(long.hasPrefix(String(rest.dropLast())), "\(kind) was cut, not summarised")
        }
    }

    /// The real guarantee behind the character budget: laid out at the Now note width in the note font
    /// with the "+5 more ›" reserve after it, every rest form takes at most two lines.
    @MainActor func testEveryRestFormLaysOutInTwoLinesAtTheNoteWidth() {
        let width = DSMetric.popoverWidth - 2 * DSMetric.popoverInset - DSMetric.railWidth - DSMetric.railGap - 2
        let font = NSFont.systemFont(ofSize: 10.5)
        for n in everyNowNote {
            let text = NowNotes.restForm(n) + "\u{00A0}\u{00A0}+5\u{00A0}more\u{00A0}\u{203A}"
            let storage = NSTextStorage(string: text, attributes: [.font: font])
            let layout = NSLayoutManager(); let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container); storage.addLayoutManager(layout)
            _ = layout.glyphRange(for: container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
            XCTAssertLessThanOrEqual(lines, 2, "\(n.kind): \(NowNotes.restForm(n)) — \(lines) lines at \(width) pt")
        }
    }

    // MARK: G-9 — the card's first entry carries the lead's full text

    func testTheCardsFirstEntryIsTheLeadsFullText() {
        let full = KeepAwakeController.interruptionNote(1)!
        let lead = NowNote(kind: .keepAwakeInterruption, text: full, rest: NowNotes.interruptionRestForm(count: 1))
        let s = NowNotes.summary([note(.autoEnergy, "Auto chose Low"), lead, note(.topUp, "Resume charging first")])!
        XCTAssertEqual(s.lead, lead)
        XCTAssertEqual(s.all.first?.text, full)
        XCTAssertEqual(s.restText, NowNotes.interruptionRestForm(count: 1))
        XCTAssertNotEqual(s.restText, full)
        XCTAssertEqual(s.all.count, 3, "nothing dropped")
    }

    private var loneShortened: NowNote {
        NowNote(kind: .keepAwakeInterruption, text: KeepAwakeController.interruptionNote(1)!,
                rest: NowNotes.interruptionRestForm(count: 1))
    }

    func testLoneShortenedNoteGetsAMoreLinkToItsFullText() {
        let s = NowNotes.summary([loneShortened])!
        XCTAssertEqual(s.moreCount, 0)
        XCTAssertTrue(s.restIsShortened)
        XCTAssertEqual(s.moreLabel, "more ›")
        XCTAssertTrue(s.hasCard)
        XCTAssertEqual(s.cardTitle, "The full note")
        XCTAssertEqual(s.all.map(\.text), [KeepAwakeController.interruptionNote(1)!], "the card lists just the full text")
        XCTAssertEqual(s.accessibilityLabel, NowNotes.interruptionRestForm(count: 1) + ", more")
    }

    func testLoneUnshortenedNoteHasNoLink() {
        let s = NowNotes.summary([note(.topUp, "Resume charging first")])!
        XCTAssertFalse(s.restIsShortened)
        XCTAssertNil(s.moreLabel)
        XCTAssertFalse(s.hasCard)
        XCTAssertEqual(s.accessibilityLabel, "Resume charging first")
    }

    func testEveryLoneNoteHasALinkExactlyWhenItIsShortened() {
        for n in everyNowNote {
            let s = NowNotes.summary([n])!
            XCTAssertEqual(s.hasCard, NowNotes.restForm(n) != n.text, "\(n.kind): \(n.text)")
            XCTAssertEqual(s.moreLabel, s.hasCard ? "more ›" : nil)
        }
    }

    func testManyNotesKeepTheCountLinkWhetherOrNotTheLeadIsShortened() {
        for lead in [loneShortened, note(.topUp, "Resume charging first")] {
            let s = NowNotes.summary([lead, note(.autoEnergy, "Auto chose Low")])!
            XCTAssertEqual(s.moreLabel, "+1 more ›")
            XCTAssertTrue(s.hasCard)
            XCTAssertEqual(s.cardTitle, "All 2 notes, most urgent first")
            XCTAssertEqual(s.accessibilityLabel, lead.text + " and 1 more")
        }
    }

    func testVoiceOverReadsTheFullLeadAndTheCount() {
        let full = KeepAwakeController.interruptionNote(1)!
        let lead = NowNote(kind: .keepAwakeInterruption, text: full, rest: NowNotes.interruptionRestForm(count: 1))
        XCTAssertEqual(NowNotes.summary([lead, note(.topUp, "x")])?.accessibilityLabel, full + " and 1 more")
    }
}
