import Foundation

/// #30 §4.6 · the Devices page's PURE strings and ordering (host-app-free, no SwiftUI). Everything the
/// page prints is decided here so the copy is testable: device rows (lowest charge first, capped at
/// five — §14-B4/U8 as re-measured for R15's 361 pt page), the component text ("L 72 · R 70 · case 91", "54% ⚡︎"), the header's "as of",
/// and the adapter Now / Last / Fit lines. (The sleep-timer lines moved to AutomationPageModel.sleepsAfterText — spec 31 §2.3.) The wireless cap is re-derived beside "Powered by this Mac" and the adapter folds first (spec 31 §2.1, `rowCap(notes:powered:deviceCount:)`).
enum DevicesPageModel {

    /// §14-B4/U8 · R15: at most five device rows, then "+N more" — sized when the page also held Sleep
    /// timers (now on Automation, spec 31 §2.3). Unchanged at spec 31 stage 2; the base of
    /// `rowCap(notes:powered:)` (spec 31 §2.1 "Fit").
    static let rowCap = 5

    /// 31 §2.1 / R15: how many notes share the page, each costing one wireless row — the card's own `.unavailable`
    /// reason, the phone's thin-state note under the card (`PhoneBatteryModel.note`), and a failed adapter read.
    /// Owner ruling 2026-09-29 ("fold the warnings w the pop outs"): when the card note and the phone note are BOTH
    /// present they fold into one short resting line (`wirelessNotes`, about 20 pt against a 37 pt row) that costs
    /// NO row (controller ruling, S4.8 round 5: the owner picked the fold from a drawing with 2 wireless rows).
    /// The adapter warning is not part of the fold (Q2 A: it is always shown under the adapter line).
    static func noteCount(cardNote: String?, phoneNote: String?, adapterUnavailable: Bool) -> Int {
        let wireless = wirelessNotes(cardNote: cardNote, phoneNote: phoneNote)?.lineCost ?? 0
        return wireless + (adapterUnavailable ? 1 : 0)
    }

    // MARK: - the wireless notes fold (owner ruling 2026-09-29)

    /// The card note the page actually PRINTS: only a failed read (`.unavailable`) shows its reason; `.noneConnected`
    /// has a note string but the card says "No devices reporting" instead, so it is not a note on the page.
    static func cardNote(_ state: DeviceReadState) -> String? {
        if case .unavailable = state { return state.note }
        return nil
    }

    /// One note under the wireless card. Declaration order of `Kind` IS seriousness (most serious first).
    struct WirelessNote: Equatable, Sendable {
        enum Kind: Int, CaseIterable, Sendable {
            case deviceRead   // the device list could not be read (orange)
            case phone        // the iPhone's thin-state note (faint)
        }
        let kind: Kind
        /// The FULL text; the card always carries it unshortened.
        let text: String
        /// Its normal colour on the page: the device-read warning is orange, the phone note faint.
        var isAttention: Bool { kind == .deviceRead }
        /// The resting line's short form (`DevicesPageModel.restForm`).
        var restForm: String { DevicesPageModel.restForm(self) }
    }

    /// What the wireless area shows: ONE note as it always did, or (two or more) one resting line —
    /// the lead's short form + "+N more note(s) ›" — whose hover / tap card lists every note in full, lead first.
    struct WirelessNotes: Equatable, Sendable {
        /// Every note, most serious first; never empty.
        let all: [WirelessNote]
        var lead: WirelessNote { all[0] }
        var moreCount: Int { all.count - 1 }
        /// Two or more notes fold; a lone note shows exactly as before.
        var isFolded: Bool { all.count >= 2 }
        /// Wireless rows the notes cost: one per note shown as before; the folded line (one short line, about 20 pt
        /// against a 37 pt row) costs none — measured: `powered-worst-notes` 2 rows at natural 465,
        /// `powered-worst-notes-adapter-ok` 3 rows (S4.8 round 5). The adapter-fold DECISION still counts the folded
        /// line as one row (`adapterFolded(foldedNotesLine:)`, round 6).
        var lineCost: Int { isFolded ? 0 : all.count }
        /// The lead as shown at rest.
        var restText: String { lead.restForm }
        /// "+1 more note ›" / "+2 more notes ›"; nil when not folded.
        var moreLabel: String? {
            guard isFolded else { return nil }
            return "+\(moreCount) more \(moreCount == 1 ? "note" : "notes") ›"
        }
        var cardTitle: String { "All \(all.count) notes, most serious first" }
        /// VoiceOver on the resting line: "Device batteries unavailable, and 1 more note".
        var accessibilityLabel: String {
            guard isFolded else { return lead.text }
            return "\(restText), and \(moreCount) more \(moreCount == 1 ? "note" : "notes")"
        }
        var accessibilityHint: String { isFolded ? "Shows all notes" : "" }
    }

    /// The wireless area's notes, most serious first (device-read failure before the phone note); nil when none.
    /// Blank text is not a note.
    static func wirelessNotes(cardNote: String?, phoneNote: String?) -> WirelessNotes? {
        var all: [WirelessNote] = []
        if let t = cardNote, !isBlank(t) { all.append(WirelessNote(kind: .deviceRead, text: t)) }
        if let t = phoneNote, !isBlank(t) { all.append(WirelessNote(kind: .phone, text: t)) }
        all.sort { $0.kind.rawValue < $1.kind.rawValue }
        return all.isEmpty ? nil : WirelessNotes(all: all)
    }

    /// Characters a short form may use so "<short> +N more notes ›" stays on ONE line at 10.5 pt in the page's
    /// ≈ 296 pt width (≈ 53 characters a line, the label and its two spaces take up to 17).
    static let restBudget = 36

    /// The note's short form, never cut mid-sentence: the part before " — " (both notes are "<what> — <why>",
    /// `DeviceReadState.note` / `PhoneBatteryModel.note`) when it fits; else the whole text when it fits (the
    /// phone's beacon note has no dash); else a hand-written per-kind summary that names only what the note is about.
    static func restForm(_ note: WirelessNote) -> String {
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dash = text.range(of: " — ") {
            let head = String(text[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, head.count <= restBudget { return head }
        } else if text.count <= restBudget {
            return text
        }
        switch note.kind {
        case .deviceRead: return "Device batteries unavailable"
        case .phone:      return "iPhone note"
        }
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The cap with `notes` notes on the page: five, one fewer per note (never below one). One note = 4, as before.
    static func rowCap(notes: Int) -> Int { max(1, rowCap - max(0, notes)) }

    /// 31 §2.1 Fit: "Powered by this Mac" takes height from the wireless card. Its header, first wired row and
    /// cost line take the removed Sleep-timers block's place; each further wired row, the "+N more" line, and
    /// the caption / "as of" line cost one wireless row. Never below one. Weights confirmed against the stage-4
    /// worst-case renders (S4.8) — change them only with a §16 row.
    static func rowCap(notes: Int, powered: PortPowerDisplay) -> Int {
        max(1, unclampedCap(notes: notes, powered: powered))
    }

    /// The cap before the floor of one (it can be zero or negative on a crowded page — the fold's saving is added
    /// to THIS, not to the clamped value).
    private static func unclampedCap(notes: Int, powered: PortPowerDisplay) -> Int {
        let base = rowCap(notes: notes)
        guard powered.visibility == .shown else { return base }
        var cost = max(0, powered.rows.count - 1)
        if powered.overflow > 0 { cost += 1 }
        if powered.oneIsPhoneCaption || powered.staleAsOf != nil { cost += 1 }
        return base - cost
    }

    /// 31 §2.1 Fit (owner ruling Q2 A, 2026-09-29): the Power adapter block folds into its title line
    /// ("Power adapter  — · last 94 W ›", the full Now / Last / Fit grid in a hover / tap card) BEFORE the wireless
    /// list gives up rows, for ANY reason (the powered section's cost or notes): it folds whenever the unfolded cap
    /// would show fewer wireless rows than the page has devices (counting at most five, the list's own limit). A page
    /// whose devices all fit keeps the full block.
    ///
    /// `foldedNotesLine` (S4.8 fix round 6, controller ruling): the folded wireless-notes line is counted as ONE row
    /// for THIS decision (the pre-round-5 rule), then costs zero in the cap once the decision is made. Without it a
    /// page with both notes, one wired row and a working adapter reached cap 5, kept the full Now / Last / Fit grid
    /// and overflowed the frame (≈ 472 pt at 5 devices, ≈ 500 at 6+).
    static func adapterFolded(powered: PortPowerDisplay, notes: Int, deviceCount: Int, foldedNotesLine: Bool = false) -> Bool {
        min(deviceCount, rowCap) > rowCap(notes: notes + (foldedNotesLine ? 1 : 0), powered: powered)
    }

    /// Wireless rows the folded adapter gives back. The Now / Last / Fit grid (three rows and their gaps, about 66 pt
    /// of the adapter block) folds into the title line and the wireless list keeps the difference, measured at the
    /// `powered-worst` render (natural 433 at cap 2) and `powered-worst-notes` (natural 454 at cap 1 in round 2; cap 2
    /// once the card and phone notes fold into one line that costs no row, owner ruling 2026-09-29): two cap units,
    /// because the cap weights above count a wired row or a note as one wireless row (37 pt) while they
    /// measure about 30 pt. Change only with a §16 row.
    static let adapterFoldSaving = 2

    /// The cap the page uses: the unfolded cap plus the fold's saving (never above five, never below one). `notes` is
    /// the cap cost (`noteCount`, the folded notes line costs zero); `foldedNotesLine` only feeds the fold decision.
    static func rowCap(notes: Int, powered: PortPowerDisplay, deviceCount: Int, foldedNotesLine: Bool = false) -> Int {
        guard adapterFolded(powered: powered, notes: notes, deviceCount: deviceCount, foldedNotesLine: foldedNotesLine) else {
            return rowCap(notes: notes, powered: powered)
        }
        return max(1, min(rowCap, unclampedCap(notes: notes, powered: powered) + adapterFoldSaving))
    }

    /// The folded adapter line's value: the Now figure ("65 W" · "not connected" · "—") plus "· last N W" when a last
    /// adapter is known. The full Now / Last / Fit text (`specText`, `lastText`) lives in the card.
    static func foldedAdapterText(state: PowerAdapterReadState, lastWatts: Int?) -> String {
        foldedAdapterParts(state: state, lastWatts: lastWatts, unreadWording: "—").joined(separator: " · ")
    }

    /// The same line for VoiceOver in plain words: the dash is "not read", the separator a pause ("not read, last 94 W").
    static func foldedAdapterSpokenText(state: PowerAdapterReadState, lastWatts: Int?) -> String {
        foldedAdapterParts(state: state, lastWatts: lastWatts, unreadWording: "not read").joined(separator: ", ")
    }

    private static func foldedAdapterParts(state: PowerAdapterReadState, lastWatts: Int?, unreadWording: String) -> [String] {
        var parts: [String]
        switch state {
        case .connected(let a): parts = [specText(watts: a.watts, voltage_mV: nil, current_mA: nil)]
        case .noAdapter: parts = ["not connected"]
        case .unavailable: parts = [unreadWording]
        }
        if let lastWatts { parts.append("last " + specText(watts: lastWatts, voltage_mV: nil, current_mA: nil)) }
        return parts
    }

    /// One rendered device row. `percent` is the figure the bar and the sort use — the lowest
    /// NON-case component (the earbuds are the device; the case only feeds them), else the lowest of all.
    struct Row: Equatable {
        let id: String
        let name: String
        let symbol: String
        let componentText: String
        let percent: Int
        let charging: Bool
        /// R13: yellow under 20 %.
        var isLow: Bool { percent < 20 }
    }

    struct RowSet: Equatable {
        let rows: [Row]
        /// Devices beyond the cap; 0 = all shown.
        let overflow: Int
    }

    /// Lowest charge first (name as the tiebreak so the order is stable), capped at `rowCap`.
    static func rows(_ devices: [DeviceBattery], cap: Int = rowCap) -> RowSet {
        var all: [Row] = []
        for d in devices {
            let isCharging = d.components.contains { $0.charging == true }
            all.append(Row(id: d.id, name: d.name,
                           symbol: DeviceIcon.symbol(for: d.deviceClass, name: d.name),
                           componentText: componentText(d.components),
                           percent: representativePercent(d.components),
                           charging: isCharging))
        }
        // R15: the mock lists devices in the order the reader reports them (AirPods first); no re-sort.
        let shown = Array(all.prefix(cap))
        return RowSet(rows: shown, overflow: max(0, all.count - shown.count))
    }

    /// The bar / sort figure: min over the non-case components, else min over all, else 0.
    static func representativePercent(_ comps: [DeviceBatteryComponent]) -> Int {
        let buds = comps.filter { $0.label?.lowercased() != "case" }
        return (buds.isEmpty ? comps : buds).map(\.percent).min() ?? 0
    }

    /// "L 72 · R 70 · case 91" (the mockup's order: left, right, other parts, case last), "54%" for a
    /// lone battery, with " ⚡︎" appended when any component reports charging.
    static func componentText(_ comps: [DeviceBatteryComponent]) -> String {
        let ordered = comps.enumerated().sorted { a, b in
            let (ra, rb) = (displayRank(a.element.label), displayRank(b.element.label))
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
        let parts: [String]
        if ordered.count == 1, let only = ordered.first, only.label == nil {
            parts = ["\(only.percent)%"]
        } else {
            parts = ordered.map { c in
                guard let l = c.label else { return "\(c.percent)%" }
                return "\(shortLabel(l)) \(c.percent)"
            }
        }
        let text = parts.joined(separator: " · ")
        return ordered.contains { $0.charging == true } ? "\(text) ⚡︎" : text
    }

    /// The row's VoiceOver value — the same facts, spoken: "Left 72 percent, Right 70 percent, case 91 percent, charging".
    static func accessibilityValue(_ comps: [DeviceBatteryComponent]) -> String {
        var parts = comps.map { c -> String in
            guard let l = c.label else { return "\(c.percent) percent" }
            return "\(l) \(c.percent) percent"
        }
        if comps.contains(where: { $0.charging == true }) { parts.append("charging") }
        return parts.joined(separator: ", ")
    }

    private static func displayRank(_ label: String?) -> Int {
        switch label?.lowercased() {
        case "left":  return 0
        case "right": return 1
        case "case":  return 3
        case .none:   return 4
        default:      return 2
        }
    }

    private static func shortLabel(_ label: String) -> String {
        switch label.lowercased() {
        case "left":  return "L"
        case "right": return "R"
        case "case":  return "case"
        default:      return label
        }
    }

    // MARK: - header

    /// "as of 13:20 today", or "as of 13:20 · 8 Sep" when the newest reading is not from the local day.
    /// nil when nothing has been read.
    static func asOfText(asOf: Int?, now: Date, calendar: Calendar = .current) -> String? {
        guard let asOf else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(asOf))
        let hm = DateFormatter()
        hm.calendar = calendar; hm.timeZone = calendar.timeZone; hm.locale = Locale(identifier: "en_US_POSIX")
        hm.dateFormat = "HH:mm"
        if calendar.isDate(date, inSameDayAs: now) { return "as of \(hm.string(from: date)) today" }
        let dm = DateFormatter()
        dm.calendar = calendar; dm.timeZone = calendar.timeZone; dm.locale = Locale(identifier: "en_US_POSIX")
        dm.dateFormat = "d MMM"
        return "as of \(hm.string(from: date)) · \(dm.string(from: date))"
    }

    /// The newest `asOf` across the rows (each read stamps every row alike, so this is the read time).
    static func newestAsOf(_ devices: [DeviceBattery]) -> Int? { devices.map(\.asOf).max() }

    // MARK: - power adapter

    /// "94 W · 20 V × 4.7 A"; "94 W" alone when the rating lacks V or A (the same both-or-neither rule
    /// as `PowerAdapter.specText`). %g trims trailing zeros.
    static func specText(watts: Int, voltage_mV: Int?, current_mA: Int?) -> String {
        guard let mV = voltage_mV, let mA = current_mA else { return "\(watts) W" }
        return "\(watts) W · \(g(Double(mV) / 1000)) V × \(g(Double(mA) / 1000)) A"
    }

    /// The Now row for a connected adapter.
    static func nowText(_ adapter: PowerAdapter) -> String {
        specText(watts: adapter.watts, voltage_mV: adapter.voltage_mV, current_mA: adapter.current_mA)
    }

    /// The Last row: "94 W · 20 V × 4.7 A · PD rung 4 of 5". `UsbHvcHvcIndex` is 0-BASED (verified live
    /// on this Mac: menu indices 0…3, active index 3, and `AdapterVoltage` equals the Index-3 rung's
    /// `MaxVoltage`), so the rung is `activePdIndex + 1`. The record does not keep the ladder, so "of M"
    /// appears only when `ladderCount` (the live adapter's `pdProfiles.count`) is known and ≥ 1.
    static func lastText(_ record: LastAdapterRecord, ladderCount: Int? = nil) -> String {
        var s = specText(watts: record.watts, voltage_mV: record.voltage_mV, current_mA: record.current_mA)
        if let idx = record.activePdIndex, idx >= 0 {
            s += " · PD rung \(idx + 1)"
            if let m = ladderCount ?? record.ladderCount, m >= 1 { s += " of \(m)" }
        }
        return s
    }

    /// The Fit row (§4.6, §14-D2): "drained N Wh while on power this week", and "kept up" when N ≈ 0.
    /// "≈ 0" is defined by the DISPLAY: N prints as `Int(N.rounded())` (half away from zero), so a drain
    /// that would print as "0" — anything under 0.5 Wh — reads "kept up", and 0.5 Wh prints as 1.
    /// nil (not computed yet, or no on-power measurement in the week) is the dash, never "kept up".
    static func fitText(drainedWh: Double?) -> String {
        guard let drainedWh else { return "—" }
        let shown = Int(drainedWh.rounded())
        return shown == 0 ? "kept up" : "drained \(shown) Wh while on power this week"
    }

    private static func g(_ v: Double) -> String { String(format: "%g", v) }
}
