import XCTest
@testable import Battery

/// #30 §4.6 · the Devices page's pure copy and ordering.
final class DevicesPageModelTests: XCTestCase {

    private func comp(_ label: String?, _ pct: Int, charging: Bool? = nil) -> DeviceBatteryComponent {
        DeviceBatteryComponent(label: label, percent: pct, charging: charging)
    }
    private func device(_ name: String, _ comps: [DeviceBatteryComponent], cls: DeviceClass = .generic, asOf: Int = 0) -> DeviceBattery {
        DeviceBattery(id: name, name: name, deviceClass: cls, components: comps, address: nil, asOf: asOf)
    }

    // component text

    func testComponentTextOrdersLeftRightCaseAndShortensLabels() {
        // The source ranks case first; the page prints the mockup order L · R · case.
        let t = DevicesPageModel.componentText([comp("Case", 91), comp("Left", 72), comp("Right", 70)])
        XCTAssertEqual(t, "L 72 · R 70 · case 91")
    }

    func testComponentTextSingleBatteryWithBolt() {
        XCTAssertEqual(DevicesPageModel.componentText([comp(nil, 54, charging: true)]), "54% ⚡︎")
        XCTAssertEqual(DevicesPageModel.componentText([comp(nil, 88)]), "88%")
    }

    func testComponentTextUnknownLabelPassesThrough() {
        XCTAssertEqual(DevicesPageModel.componentText([comp("Band", 40), comp("Case", 9)]), "Band 40 · case 9")
    }

    // representative percent + rows

    func testRepresentativePercentIgnoresTheCase() {
        XCTAssertEqual(DevicesPageModel.representativePercent([comp("Case", 91), comp("Left", 72), comp("Right", 70)]), 70)
        XCTAssertEqual(DevicesPageModel.representativePercent([comp("Case", 15)]), 15)
        XCTAssertEqual(DevicesPageModel.representativePercent([]), 0)
    }

    func testRowsKeepReaderOrderAndCapAtFive() {
        // R15: the mock lists devices in reader order (AirPods first) — no re-sort; five rows + "+N more".
        let devs = (1...8).map { device("D\($0)", [comp(nil, 100 - $0 * 10)]) }   // 90 … 20
        let set = DevicesPageModel.rows(devs)
        XCTAssertEqual(DevicesPageModel.rowCap, 5)
        XCTAssertEqual(set.rows.count, 5)
        XCTAssertEqual(set.overflow, 3)
        XCTAssertEqual(set.rows.map(\.percent), [90, 80, 70, 60, 50])
        XCTAssertEqual(set.rows.first?.name, "D1")
    }

    func testRowCapDropsToFourWhenANoteSharesTheFrame() {
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0), 5)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1), 4)
        let devs = (1...6).map { device("D\($0)", [comp(nil, 100 - $0 * 10)]) }
        let set = DevicesPageModel.rows(devs, cap: DevicesPageModel.rowCap(notes: 1))
        XCTAssertEqual(set.rows.count, 4)
        XCTAssertEqual(set.overflow, 2)
    }

    func testRowFlagsLowUnderTwenty() {
        let set = DevicesPageModel.rows([device("Mouse", [comp(nil, 18)], cls: .mouse), device("KB", [comp(nil, 20)], cls: .keyboard)])
        XCTAssertTrue(set.rows[0].isLow)
        XCTAssertFalse(set.rows[1].isLow)
        XCTAssertEqual(set.rows[0].symbol, "magicmouse")
        XCTAssertEqual(set.overflow, 0)
    }

    // header

    func testAsOfTodayAndNotToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_757_430_000)          // 2025-09-09 15:00 UTC
        let sameDay = Int(now.timeIntervalSince1970) - 3600           // 14:00
        XCTAssertEqual(DevicesPageModel.asOfText(asOf: sameDay, now: now, calendar: cal), "as of 14:00 today")
        let yesterday = Int(now.timeIntervalSince1970) - 86_400
        XCTAssertEqual(DevicesPageModel.asOfText(asOf: yesterday, now: now, calendar: cal), "as of 15:00 · 8 Sep")
        XCTAssertNil(DevicesPageModel.asOfText(asOf: nil, now: now, calendar: cal))
    }

    func testNewestAsOf() {
        XCTAssertEqual(DevicesPageModel.newestAsOf([device("a", [], asOf: 5), device("b", [], asOf: 9)]), 9)
        XCTAssertNil(DevicesPageModel.newestAsOf([]))
    }

    // adapter

    func testSpecText() {
        XCTAssertEqual(DevicesPageModel.specText(watts: 94, voltage_mV: 20000, current_mA: 4700), "94 W · 20 V × 4.7 A")
        XCTAssertEqual(DevicesPageModel.specText(watts: 94, voltage_mV: nil, current_mA: 4700), "94 W")
    }

    func testLastTextRungIsOneBasedFromTheZeroBasedIndex() {
        let rec = LastAdapterRecord(watts: 100, voltage_mV: 20000, current_mA: 5000, activePdIndex: 3, ts: 0)
        XCTAssertEqual(DevicesPageModel.lastText(rec, ladderCount: 4), "100 W · 20 V × 5 A · PD rung 4 of 4")
        XCTAssertEqual(DevicesPageModel.lastText(rec, ladderCount: nil), "100 W · 20 V × 5 A · PD rung 4")
        let withLadder = LastAdapterRecord(watts: 94, voltage_mV: 20000, current_mA: 4700, activePdIndex: 3, ts: 0, ladderCount: 5)
        XCTAssertEqual(DevicesPageModel.lastText(withLadder), "94 W · 20 V × 4.7 A · PD rung 4 of 5")
        let noRung = LastAdapterRecord(watts: 8, voltage_mV: 5000, current_mA: 1500, activePdIndex: nil, ts: 0)
        XCTAssertEqual(DevicesPageModel.lastText(noRung, ladderCount: 1), "8 W · 5 V × 1.5 A")
    }

    /// Spec §4.6: Fit = "drained N Wh while on power this week"; "kept up" when N ≈ 0. "≈ 0" means
    /// "would DISPLAY as 0": N prints as `Int(N.rounded())` (half away from zero), so everything below
    /// 0.5 Wh reads "kept up" and 0.5 Wh is the first value that prints as 1.
    func testFitTextKeptUpExactlyWhenTheDisplayedFigureIsZero() {
        XCTAssertEqual(DevicesPageModel.fitText(drainedWh: 0), "kept up")
        XCTAssertEqual(DevicesPageModel.fitText(drainedWh: 0.5.nextDown), "kept up",
                       "the largest value that displays as 0")
        XCTAssertEqual(DevicesPageModel.fitText(drainedWh: 0.5), "drained 1 Wh while on power this week",
                       "the smallest value that displays as 1")
        XCTAssertEqual(DevicesPageModel.fitText(drainedWh: 12.4), "drained 12 Wh while on power this week")
    }

    /// Absence is not a fact: an unread / unmeasured drain is a dash, never "kept up".
    func testFitTextUnreadIsADashNeverKeptUp() {
        XCTAssertEqual(DevicesPageModel.fitText(drainedWh: nil), "—")
    }

    // MARK: - 31 §2.1 Fit · the Powered section takes height from the wireless card

    private func powered(rows: Int, overflow: Int = 0, caption: Bool = false, stale: Bool = false,
                         visibility: PortPowerDisplay.Visibility = .shown) -> PortPowerDisplay {
        var d = PortPowerDisplay(visibility: visibility)
        d.rows = (0..<rows).map { PortPowerDisplay.Row(id: "port\($0)", symbol: "cable.connector", name: "USB-C device",
                                                       detail: "· cable", state: .drawing(tenthsW: 10), contractW: nil) }
        d.overflow = overflow
        d.oneIsPhoneCaption = caption
        d.staleAsOf = stale ? "as of 12:55" : nil
        return d
    }

    func testEveryNoteOnThePageCostsAWirelessRow() {
        XCTAssertEqual(DevicesPageModel.noteCount(cardNote: nil, phoneNote: nil, adapterUnavailable: false), 0)
        XCTAssertEqual(DevicesPageModel.noteCount(cardNote: "x", phoneNote: nil, adapterUnavailable: false), 1)
        XCTAssertEqual(DevicesPageModel.noteCount(cardNote: nil, phoneNote: "iPhone unavailable — the phone refused a session",
                                                  adapterUnavailable: false), 1, "the phone's thin-state row shares the page")
        XCTAssertEqual(DevicesPageModel.noteCount(cardNote: nil, phoneNote: nil, adapterUnavailable: true), 1)
        XCTAssertEqual(DevicesPageModel.noteCount(cardNote: "x", phoneNote: "y", adapterUnavailable: true), 1,
                       "the card and phone notes fold into one short line that costs no row (owner ruling 2026-09-29, "
                       + "S4.8 round 5); the adapter warning is its own")
        let phoneNote = PhoneBatteryModel.note(resolved: nil, sync: .unavailable("the phone refused a session"), beaconUnavailable: nil)
        XCTAssertNotNil(phoneNote)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: DevicesPageModel.noteCount(cardNote: nil, phoneNote: phoneNote, adapterUnavailable: false)), 4)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 2), 3)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 9), 1, "never below one")
    }

    // MARK: - Q2 A · the adapter folds first

    func testAnOrdinaryPageKeepsTheFullAdapterBlock() {
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: .hidden, notes: 0, deviceCount: 7), "no powered section: 5 rows as ever")
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: .hidden, notes: 2, deviceCount: 7),
                      "notes alone DO fold it: cap 3 would hide devices (owner rule: the adapter shrinks first, any reason)")
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: .hidden, notes: 2, deviceCount: 3), "3 devices fit a cap of 3")
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: powered(rows: 0, visibility: .unread), notes: 0, deviceCount: 7))
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0, powered: .hidden, deviceCount: 7), 5)
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: powered(rows: 3), notes: 0, deviceCount: 3),
                       "the option-1 pair: 3 wired rows, 3 wireless devices, nothing is hidden")
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: powered(rows: 1), notes: 1, deviceCount: 4))
    }

    func testTheAdapterFoldsExactlyWhenTheUnfoldedCapWouldHideADevice() {
        let crowded = powered(rows: 3, overflow: 1, caption: true, stale: true)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: crowded), 1)
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: crowded, notes: 1, deviceCount: 4))
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: crowded, notes: 1, deviceCount: 1), "one device fits the floor")
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: powered(rows: 3), notes: 0, deviceCount: 4),
                      "cap 3 < 4 devices")
    }

    func testTheFoldGivesRowsBackToTheWirelessList() {
        XCTAssertEqual(DevicesPageModel.adapterFoldSaving, 2)
        // powered-worst: one note (the adapter), 3 wired rows + "+N more" + the note line: 4 - 4 = 0 → 1 unfolded, 0 + 2 folded.
        let worst = powered(rows: 3, overflow: 1, caption: true, stale: true)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: worst), 1)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: worst, deviceCount: 4), 2)
        // powered-worst-notes: the folded card + phone line costs no row, the adapter warning one: 4 - 4 = 0 → 1 unfolded,
        // 0 + 2 = 2 folded (rendered natural 465, ok — the owner's drawing: 2 rows + "+3 more").
        let notesCase = powered(rows: 3, overflow: 1, stale: true)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: notesCase, deviceCount: 5), 2)
        // the fold never lifts the cap above the note-adjusted base, and an unfolded page is unchanged
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0, powered: powered(rows: 2), deviceCount: 5), 5,
                       "unfolded cap 4 hides a device → folds: 4 + 2 = 6, capped at the base 5")
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0, powered: powered(rows: 3), deviceCount: 3), 3, "not folded: unchanged")
    }

    func testAPageWithNoPoweredSectionFoldsForNotesToo() {
        let unread = powered(rows: 0, visibility: .unread)
        // input (1): powered unread, an adapter warning, 5 wireless devices: cap 4 would say "+1 more" → fold, keep all 5
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: unread), 4)
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: unread, notes: 1, deviceCount: 5))
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: unread, deviceCount: 5), 5)
        // input (2): the same plus a phone note: cap 3 → fold, and 3 + 2 saved = 5 rows kept (rendered: natural 430, ok)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 2, powered: unread), 3)
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: unread, notes: 2, deviceCount: 5))
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 2, powered: unread, deviceCount: 5), 5)
        // hidden section, same notes
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 2, powered: .hidden, deviceCount: 5), 5)
        // a device list that fits keeps the full grid, notes or not
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: unread, notes: 1, deviceCount: 4))
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: unread, deviceCount: 4), 4)
        // a bare seven-device page is capped at five by design and never folds
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: .hidden, notes: 0, deviceCount: 7))
        // three note lines on the crowded page: floor of one
        let crowded = powered(rows: 3, overflow: 1, stale: true)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 3, powered: crowded, deviceCount: 5), 1)
    }

    func testTheFoldedAdapterLine() {
        let live = PowerAdapter(watts: 65, voltage_mV: 20_000, current_mA: 3_250)
        XCTAssertEqual(DevicesPageModel.foldedAdapterText(state: .connected(live), lastWatts: 94), "65 W · last 94 W")
        XCTAssertEqual(DevicesPageModel.foldedAdapterText(state: .connected(live), lastWatts: nil), "65 W")
        XCTAssertEqual(DevicesPageModel.foldedAdapterText(state: .noAdapter, lastWatts: 94), "not connected · last 94 W")
        XCTAssertEqual(DevicesPageModel.foldedAdapterText(state: .noAdapter, lastWatts: nil), "not connected")
        XCTAssertEqual(DevicesPageModel.foldedAdapterText(state: .unavailable("why"), lastWatts: 94), "— · last 94 W",
                       "the owner's example")
        XCTAssertEqual(DevicesPageModel.foldedAdapterText(state: .unavailable("why"), lastWatts: nil), "—")
        // VoiceOver: plain words — never a spoken dash
        XCTAssertEqual(DevicesPageModel.foldedAdapterSpokenText(state: .unavailable("why"), lastWatts: 94), "not read, last 94 W")
        XCTAssertEqual(DevicesPageModel.foldedAdapterSpokenText(state: .unavailable("why"), lastWatts: nil), "not read")
        XCTAssertEqual(DevicesPageModel.foldedAdapterSpokenText(state: .noAdapter, lastWatts: 94), "not connected, last 94 W")
        XCTAssertEqual(DevicesPageModel.foldedAdapterSpokenText(state: .connected(live), lastWatts: nil), "65 W")
    }

    func testRowCapWithThePoweredSection() {
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0, powered: .hidden), 5)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: .hidden), 4)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0, powered: powered(rows: 0, visibility: .unread)), 5)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0, powered: powered(rows: 1)), 5, "one wired row replaces the Sleep-timers block")
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0, powered: powered(rows: 3)), 3)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 0, powered: powered(rows: 3, overflow: 2, caption: true, stale: true)), 1)
        XCTAssertEqual(DevicesPageModel.rowCap(notes: 1, powered: powered(rows: 3, overflow: 2, caption: true)), 1, "never below one")
    }

    // MARK: - owner ruling 2026-09-29 · fold the wireless notes behind one line with a pop-out card

    private let cardReason = "Device batteries unavailable — this macOS build does not export IOPSCopyPowerSourcesByType."
    private let phoneReason = "iPhone unavailable — MobileDevice framework not available on this macOS"

    func testOnlyAFailedReadPutsTheCardNoteOnThePage() {
        XCTAssertEqual(DevicesPageModel.cardNote(.unavailable("the sky fell")), "Device batteries unavailable — the sky fell.")
        XCTAssertNil(DevicesPageModel.cardNote(.devices))
        XCTAssertNil(DevicesPageModel.cardNote(.noneConnected), "the card says \"No devices reporting\" instead")
    }

    func testTheNotesAreOrderedMostSeriousFirst() {
        let n = DevicesPageModel.wirelessNotes(cardNote: cardReason, phoneNote: phoneReason)
        XCTAssertEqual(n?.all.map(\.kind), [.deviceRead, .phone])
        XCTAssertEqual(n?.lead.kind, .deviceRead, "the device-read failure leads")
        XCTAssertEqual(n?.all.map(\.text), [cardReason, phoneReason], "every note in FULL for the card")
        XCTAssertEqual(n?.lead.isAttention, true, "orange")
        XCTAssertEqual(n?.all.last?.isAttention, false, "faint")
        XCTAssertNil(DevicesPageModel.wirelessNotes(cardNote: nil, phoneNote: nil))
        XCTAssertNil(DevicesPageModel.wirelessNotes(cardNote: "  ", phoneNote: ""), "blank text is not a note")
    }

    func testOneNoteDoesNotFold() {
        for n in [DevicesPageModel.wirelessNotes(cardNote: cardReason, phoneNote: nil),
                  DevicesPageModel.wirelessNotes(cardNote: nil, phoneNote: phoneReason)] {
            XCTAssertEqual(n?.isFolded, false)
            XCTAssertNil(n?.moreLabel)
            XCTAssertEqual(n?.lineCost, 1, "a lone note costs its row, as before")
            XCTAssertEqual(n?.accessibilityHint, "")
        }
        XCTAssertEqual(DevicesPageModel.wirelessNotes(cardNote: nil, phoneNote: phoneReason)?.accessibilityLabel, phoneReason,
                       "a lone note reads itself")
    }

    func testTwoNotesFoldIntoOneLine() {
        let n = DevicesPageModel.wirelessNotes(cardNote: cardReason, phoneNote: phoneReason)!
        XCTAssertTrue(n.isFolded)
        XCTAssertEqual(n.lineCost, 0, "one short line (about 20 pt against a 37 pt row) costs no row")
        XCTAssertEqual(n.restText, "Device batteries unavailable")
        XCTAssertEqual(n.moreLabel, "+1 more note ›")
        XCTAssertEqual(n.restText + " " + n.moreLabel!, "Device batteries unavailable +1 more note ›", "the owner's example")
        XCTAssertEqual(n.cardTitle, "All 2 notes, most serious first")
    }

    func testTheMoreLabelIsSingularOrPlural() {
        let note = DevicesPageModel.WirelessNote(kind: .deviceRead, text: cardReason)
        let phone = DevicesPageModel.WirelessNote(kind: .phone, text: phoneReason)
        XCTAssertEqual(DevicesPageModel.WirelessNotes(all: [note, phone]).moreLabel, "+1 more note ›")
        XCTAssertEqual(DevicesPageModel.WirelessNotes(all: [note, phone, phone]).moreLabel, "+2 more notes ›")
        XCTAssertEqual(DevicesPageModel.WirelessNotes(all: [note, phone, phone]).accessibilityLabel,
                       "Device batteries unavailable, and 2 more notes")
    }

    func testTheShortFormsNeverCutMidSentence() {
        func rest(_ kind: DevicesPageModel.WirelessNote.Kind, _ text: String) -> String {
            DevicesPageModel.restForm(DevicesPageModel.WirelessNote(kind: kind, text: text))
        }
        XCTAssertEqual(rest(.deviceRead, cardReason), "Device batteries unavailable")
        XCTAssertEqual(rest(.deviceRead, DeviceReadState.unavailable("the symbol is gone").note!), "Device batteries unavailable")
        XCTAssertEqual(rest(.phone, phoneReason), "iPhone unavailable")
        XCTAssertEqual(rest(.phone, PhoneBatteryModel.note(resolved: nil, sync: .unavailable("the phone refused a session"),
                                                          beaconUnavailable: nil)!), "iPhone unavailable")
        // no dash: the whole text when it fits, else a hand-written summary — never a prefix of the sentence
        XCTAssertEqual(rest(.phone, "iPhone note, short"), "iPhone note, short")
        let beacon = "iPhone level from its nearby beacon · approximate"
        XCTAssertGreaterThan(beacon.count, DevicesPageModel.restBudget)
        XCTAssertEqual(rest(.phone, beacon), "iPhone note")
        XCTAssertEqual(rest(.deviceRead, String(repeating: "word ", count: 20) + "— why"), "Device batteries unavailable",
                       "an over-budget head is not cut")
        // every short form is either the text before " — ", the whole text, or a fixed summary
        for (kind, text) in [(DevicesPageModel.WirelessNote.Kind.deviceRead, cardReason), (.phone, phoneReason), (.phone, beacon)] {
            let r = rest(kind, text)
            XCTAssertLessThanOrEqual(r.count, DevicesPageModel.restBudget)
            let head = text.components(separatedBy: " — ").first!
            XCTAssertTrue(r == head || r == text || ["Device batteries unavailable", "iPhone note"].contains(r), r)
        }
    }

    func testTheVoiceOverStrings() {
        let n = DevicesPageModel.wirelessNotes(cardNote: cardReason, phoneNote: phoneReason)!
        XCTAssertEqual(n.accessibilityLabel, "Device batteries unavailable, and 1 more note")
        XCTAssertEqual(n.accessibilityHint, "Shows all notes")
    }

    func testTheCapWithTheFold() {
        // powered-worst-notes: card note + phone note + adapter warning, 3 unnamed wired rows + "+1 more" + "as of", 5 devices.
        let crowded = powered(rows: 3, overflow: 1, stale: true)
        let notes = DevicesPageModel.noteCount(cardNote: cardReason, phoneNote: phoneReason, adapterUnavailable: true)
        XCTAssertEqual(notes, 1, "the folded line costs nothing; the adapter warning one row")
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: crowded, notes: notes, deviceCount: 5, foldedNotesLine: true),
                      "the adapter still folds first")
        XCTAssertEqual(DevicesPageModel.rowCap(notes: notes, powered: crowded, deviceCount: 5, foldedNotesLine: true), 2,
                       "rendered natural 465, ok: 2 rows + \"+3 more\", the owner's drawing")
        // powered-worst-notes-adapter-ok: a connected adapter, no warning → 0 notes; the adapter still folds (cap 1 < 5)
        let okNotes = DevicesPageModel.noteCount(cardNote: cardReason, phoneNote: phoneReason, adapterUnavailable: false)
        XCTAssertEqual(okNotes, 0)
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: crowded, notes: okNotes, deviceCount: 5, foldedNotesLine: true))
        XCTAssertEqual(DevicesPageModel.rowCap(notes: okNotes, powered: crowded, deviceCount: 5, foldedNotesLine: true), 3,
                       "rendered natural 470, ok (0 pt spare): 3 rows + \"+2 more\"")
        // a lone phone note still costs its row; adding the card note folds the pair into one line that costs none
        XCTAssertEqual(DevicesPageModel.noteCount(cardNote: nil, phoneNote: phoneReason, adapterUnavailable: true), 2)
        // no powered section: the folded pair leaves the full five
        XCTAssertEqual(DevicesPageModel.rowCap(notes: DevicesPageModel.noteCount(cardNote: cardReason, phoneNote: phoneReason,
                                                                                  adapterUnavailable: false)), 5)
    }

    // MARK: - S4.8 fix round 6 · the fold DECISION counts the folded notes line as one row

    func testTheAdapterFoldsWheneverFoldedNotesWouldHideADevice() {
        var configs: [PortPowerDisplay] = [.hidden, powered(rows: 0, visibility: .unread)]
        for rows in 1...4 { for overflow in [0, 1] { for caption in [false, true] { for stale in [false, true] {
            configs.append(powered(rows: rows, overflow: overflow, caption: caption, stale: stale))
        } } } }
        for d in configs {
            for adapterUnavailable in [false, true] {
                let notes = DevicesPageModel.noteCount(cardNote: cardReason, phoneNote: phoneReason, adapterUnavailable: adapterUnavailable)
                for devices in 1...7 {
                    // the unfolded cap with the folded notes line counted as one row
                    let unfoldedCap = DevicesPageModel.rowCap(notes: notes + 1, powered: d)
                    let folded = DevicesPageModel.adapterFolded(powered: d, notes: notes, deviceCount: devices, foldedNotesLine: true)
                    XCTAssertEqual(folded, min(devices, 5) > unfoldedCap,
                                   "\(d.visibility) rows \(d.rows.count) +\(d.overflow) adapter-unread \(adapterUnavailable) devices \(devices)")
                    // an unfolded adapter only ever shows beside a list whose devices all fit in that one-row-dearer cap
                    if !folded { XCTAssertLessThanOrEqual(min(devices, 5), unfoldedCap) }
                }
            }
        }
    }

    func testTheReviewersSinglePortInputsFoldTheAdapter() {
        // both notes, adapter read OK, 1 wired row, no overflow or caption (c = 0), on battery (the cost line is not weighed)
        let single = powered(rows: 1)
        let notes = DevicesPageModel.noteCount(cardNote: cardReason, phoneNote: phoneReason, adapterUnavailable: false)
        XCTAssertEqual(notes, 0)
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: single, notes: notes, deviceCount: 5),
                       "round 5's rule (the folded line costs nothing in the decision) kept the full grid: ≈ 472 pt")
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: single, notes: notes, deviceCount: 5, foldedNotesLine: true))
        XCTAssertEqual(DevicesPageModel.rowCap(notes: notes, powered: single, deviceCount: 5, foldedNotesLine: true), 5)
        // powered-notes-single-port: 6 devices → folds, 5 rows + "+1 more" (rendered natural 435, ok; round 5's rule: 500, CLIPPED)
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: single, notes: notes, deviceCount: 6, foldedNotesLine: true))
        XCTAssertEqual(DevicesPageModel.rowCap(notes: notes, powered: single, deviceCount: 6, foldedNotesLine: true), 5)
        // both notes + adapter unavailable + c = 0 + 4 devices (≈ 469.5 pt unfolded): folds now
        let withWarning = DevicesPageModel.noteCount(cardNote: cardReason, phoneNote: phoneReason, adapterUnavailable: true)
        XCTAssertTrue(DevicesPageModel.adapterFolded(powered: single, notes: withWarning, deviceCount: 4, foldedNotesLine: true))
        XCTAssertEqual(DevicesPageModel.rowCap(notes: withWarning, powered: single, deviceCount: 4, foldedNotesLine: true), 5,
                       "all 4 devices shown")
        // a lone note is not a folded line: the flag stays off and nothing changes
        XCTAssertFalse(DevicesPageModel.adapterFolded(powered: single, notes: 1, deviceCount: 4))
    }
}
