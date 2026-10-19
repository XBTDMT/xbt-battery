import CoreGraphics

/// Spacing & geometry tokens — `29-phase1-foundation-tokens.md` §3. One grid, base unit 4 pt.
enum DSMetric {
    // 4-pt grid
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24

    static let popoverWidth: CGFloat = 360      // #30 R3, owner ruling 2026-09-09 evening: back to 360 (400 read too wide); #29 D1 was 320
    static let popoverPadding: CGFloat = 16     // outer content inset
    static let groupPadding: CGFloat = 12       // inside a grouped card
    static let groupGap: CGFloat = 10           // between cards
    static let rowGap: CGFloat = 6              // between rows inside a card
    static let rowMinHeight: CGFloat = 22       // component.row min height (§4)
    static let radiusGroup: CGFloat = 8         // grouped-inset cards
    static let radiusHUD: CGFloat = 12          // the HUD panel
    static let settingsWidth: CGFloat = 480     // ALL Settings tabs (D8)

    // #30 · the rail shell (spec §3). One fixed frame for every tab.
    static let popoverInset: CGFloat = 10       // outer inset of the rail + page block (the old root used popoverPadding 16)
    static let railWidth: CGFloat = 34          // the rail column (its trailing hairline included) — owner ruling: narrower rail, same icons
    static let railGap: CGFloat = 8             // rail → page
    static let railButton: CGFloat = 30         // rail button height
    static let railButtonGap: CGFloat = 6
    /// PINNED (#30, owner ruling 2026-09-09 evening): 470 — portrait; each page distributes its blocks down
    /// the frame with flexible spacers (the 361 top-pinned frame read "compacted to the top").
    static let pageHeight: CGFloat = 470

    /// popover.maxContentHeight — the D6 / A1 (Grok F2) content-height cap. NSPopover has no intrinsic
    /// height limit, so Details' ScrollView is bounded by this from the Cut D-2 transitional host
    /// onward; that keeps the popover size bounded and the anchor arrow stable through push/pop.
    ///
    /// 560 pt fits the smallest supported laptop class (a 13-inch built-in display, ~800 pt tall in
    /// points) with room for the menu bar and the popover's anchor-arrow clearance above/below.
    /// TUNABLE — revisit at the D-2 / D-3 screenshot review once real content is in the frame.
    static let popoverMaxContentHeight: CGFloat = 560
}

// MARK: - the clip gate (spec 31 §2.5 — G-3, T11, T12)
//
// Pure, CoreGraphics-only, and in THIS file on purpose: DSMetric.swift is the one design-system file the
// logic-only test target compiles (project.yml lists it individually), and the gate judges a page against
// `pageHeight`, which lives here. The render harness (app-only) measures; this decides.

/// What the clip gate saw on one rendered variant.
enum PageVerdict: String, Sendable {
    /// inside ≤ 470 and natural ≤ inside + 2 pt.
    case ok
    /// The content laid out in the real frame is taller than the frame.
    case CLIPPED
    /// Text was compressed instead of growing: the `.fixedSize` natural height exceeds the inside height.
    case TRUNCATED
    /// Automation only: taller than the frame WITH the page's scroll flag and bottom-fade cue on.
    case scrolls
    /// A channel never reported, or reported a non-positive / non-finite height.
    case unmeasured
}

/// One row of the expected-verdict table: page × fixture → verdict, and why.
struct ExpectedVerdict: Equatable, Sendable {
    let page: String
    let fixture: String
    let verdict: PageVerdict
    let reason: String
    /// Non-nil marks a KNOWN failure a later stage owes (ISSUE-12 until stage 2). It matches only under
    /// `--allow-interim`; the close-out command runs without it, so an interim row can never pass a close-out.
    let interim: String?

    init(_ page: String, _ fixture: String, _ verdict: PageVerdict, reason: String, interim: String? = nil) {
        self.page = page
        self.fixture = fixture
        self.verdict = verdict
        self.reason = reason
        self.interim = interim
    }
}

/// One variant's two channels, as the harness read them after its settle.
struct PageGateResult: Equatable, Sendable {
    let page: String
    let fixture: String
    let inside: CGFloat?
    let natural: CGFloat?
    let scrollCue: Bool

    var verdict: PageVerdict { PageGate.verdict(inside: inside, natural: natural, scrollCue: scrollCue) }
}

enum PageGate {
    /// Sub-point layout noise (fractional pixel rounding) is not a clip.
    static let clipTolerance: CGFloat = 0.5
    /// natural may exceed inside by this much before the page counts as truncated.
    static let truncationSlack: CGFloat = 2

    static let passExit: Int32 = 0
    static let mismatchExit: Int32 = 1
    static let harnessErrorExit: Int32 = 2

    enum RowStatus: Equatable, Sendable { case match, interim, mismatch, noRow }

    static func verdict(inside: CGFloat?, natural: CGFloat?, scrollCue: Bool,
                        frame: CGFloat = DSMetric.pageHeight) -> PageVerdict {
        guard let inside, let natural, inside.isFinite, natural.isFinite, inside > 0, natural > 0 else {
            return .unmeasured
        }
        if inside > frame + clipTolerance { return scrollCue ? .scrolls : .CLIPPED }
        if natural > inside + truncationSlack { return .TRUNCATED }
        return .ok
    }

    static func rows(page: String, fixture: String, in table: [ExpectedVerdict]) -> [ExpectedVerdict] {
        table.filter { $0.page == page && $0.fixture == fixture }
    }

    /// A variant with no row — or two — is `.noRow`: the harness is misconfigured, never a pass.
    static func status(_ r: PageGateResult, in table: [ExpectedVerdict]) -> RowStatus {
        let matching = rows(page: r.page, fixture: r.fixture, in: table)
        guard matching.count == 1, let row = matching.first else { return .noRow }
        if r.verdict != row.verdict { return .mismatch }
        return row.interim == nil ? .match : .interim
    }

    /// `--render-pages` exit code: 2 = harness error (nothing rendered, a variant without exactly one row,
    /// a row never rendered); 1 = a verdict differs from its row, or an interim row without
    /// `--allow-interim`; 0 = every verdict as expected.
    static func exitCode(_ results: [PageGateResult], table: [ExpectedVerdict], allowInterim: Bool) -> Int32 {
        guard !results.isEmpty else { return harnessErrorExit }
        let statuses = results.map { status($0, in: table) }
        if statuses.contains(.noRow) { return harnessErrorExit }
        let rendered = Set(results.map { key($0.page, $0.fixture) })
        if table.contains(where: { !rendered.contains(key($0.page, $0.fixture)) }) { return harnessErrorExit }
        if statuses.contains(.mismatch) { return mismatchExit }
        if !allowInterim && statuses.contains(.interim) { return mismatchExit }
        return passExit
    }

    /// One heights.txt line: page · fixture · inside · natural · what was seen · expected · status.
    static func line(_ r: PageGateResult, table: [ExpectedVerdict], frame: CGFloat = DSMetric.pageHeight) -> String {
        func pt(_ h: CGFloat?) -> String {
            guard let h, h.isFinite else { return "—" }
            return String(Int(h.rounded()))
        }
        let verdict = r.verdict
        let seen: String
        switch verdict {
        case .CLIPPED, .scrolls:
            seen = "\(verdict.rawValue) by \(Int(((r.inside ?? frame) - frame).rounded(.up))) pt"
        case .TRUNCATED:
            seen = "TRUNCATED by \(Int(((r.natural ?? 0) - (r.inside ?? 0)).rounded(.up))) pt"
        case .ok, .unmeasured:
            seen = verdict.rawValue
        }
        let matching = rows(page: r.page, fixture: r.fixture, in: table)
        let expected = matching.count == 1 ? matching[0].verdict.rawValue : "—"
        let tail: String
        switch status(r, in: table) {
        case .match:    tail = "MATCH"
        case .mismatch: tail = "MISMATCH"
        case .interim:  tail = "INTERIM — \(matching[0].interim ?? "")"
        case .noRow:    tail = matching.isEmpty ? "NO TABLE ROW" : "DUPLICATE TABLE ROWS"
        }
        return "\(r.page)\t\(r.fixture)\tinside \(pt(r.inside))\tnatural \(pt(r.natural))\t\(seen)\texpected \(expected)\t\(tail)"
    }

    /// The last heights.txt line: the tally and the exit code this run returns.
    static func footer(_ results: [PageGateResult], table: [ExpectedVerdict], allowInterim: Bool) -> String {
        let statuses = results.map { status($0, in: table) }
        func count(_ s: RowStatus) -> Int { statuses.filter { $0 == s }.count }
        let rendered = Set(results.map { key($0.page, $0.fixture) })
        let unrendered = table.filter { !rendered.contains(key($0.page, $0.fixture)) }.count
        let code = exitCode(results, table: table, allowInterim: allowInterim)
        return "gate\t\(results.count) variants · \(count(.match)) match · \(count(.interim)) interim · "
            + "\(count(.mismatch)) mismatch · \(count(.noRow)) without a row · \(unrendered) rows not rendered"
            + " → exit \(code)" + (allowInterim ? " (--allow-interim)" : "")
    }

    private static func key(_ page: String, _ fixture: String) -> String { page + "\t" + fixture }

    /// The expected-verdict table (spec 31 §2.5): exactly one row per rendered variant. A change to a row's
    /// FINAL verdict is a 30-spec §16 row with the owner's ruling — the table is never edited to make a
    /// failing page pass. An `interim` row records a failure a later stage owes; it matches only under
    /// `--allow-interim`, so the flagless close-out run cannot pass while one remains.
    static let expected: [ExpectedVerdict] = [
        ExpectedVerdict("now", "parity", .ok, reason: "the FINAL mockup's state"),
        ExpectedVerdict("day", "parity", .ok, reason: "bounded by fixed caps: 7 table rows, a 150–190 pt chart"),
        ExpectedVerdict("energy", "parity", .ok,
                        reason: "bounded by fixed caps: the 5-row ranked card, ≤ 2 holders + \"+N more\""),
        ExpectedVerdict("health", "parity", .ok,
                        reason: "bounded by fixed caps: 6 figures, 5 lifetime rows, a 78 pt chart"),
        ExpectedVerdict("health", "history-note", .ok,
                        reason: "spec 30 §16 row 32: the parity page + the history note at its longest copy "
                            + "(two named months, two lines) under the figures"),
        ExpectedVerdict("devices", "parity", .ok,
                        reason: "the base fixture: no PowerOutDetails, section hidden (unpaired since stage 4): "
                            + "7 accessories → 5 rows + \"+2 more\""),
        ExpectedVerdict("devices", "powered-on-power", .ok,
                        reason: "31 option 1 on power: 3 wireless + 3 named wired rows + the band line"),
        ExpectedVerdict("devices", "powered-on-battery", .ok,
                        reason: "31 option 1 on battery: 3 wireless + 3 named wired rows + the two-line cost line"),
        ExpectedVerdict("devices", "powered-worst", .ok,
                        reason: "31 §2.5 Devices worst case: 4 wireless devices (the iPhone moved to Powered) at the "
                            + "re-derived cap (2 rows, the adapter folded) + \"+N more\" + an adapter note, the iPhone row + "
                            + "2 unnamed wired rows + \"+N more\", header, two-line cost line, caption, \"as of\""),
        ExpectedVerdict("devices", "powered-worst-notes", .ok,
                        reason: "31 §2.5 the worst case + the longest real adapter reason (two lines) + the card's own note (a "
                            + "failed IOPS read) + a phone note + 3 unnamed wired rows + \"+1 more\" (a failed phone read leaves no "
                            + "phone row or caption): the adapter folds into its title line (owner Q2 A), the card and phone notes "
                            + "fold into one resting line with a pop-out card (owner ruling 2026-09-29, the line costs no row), the "
                            + "wireless card keeps 2 rows + \"+3 more\" (the owner's drawing)"),
        ExpectedVerdict("devices", "powered-worst-notes-adapter-ok", .ok,
                        reason: "powered-worst-notes with a CONNECTED adapter (no adapter warning): the folded notes line costs "
                            + "no row, the adapter still folds (the list would lose a row), so the wireless card keeps 3 rows — "
                            + "the most rows any crowded notes page reaches"),
        ExpectedVerdict("devices", "powered-notes-single-port", .ok,
                        reason: "S4.8 fix round 6: both wireless notes (folded), a CONNECTED adapter, ONE named wired row on "
                            + "battery (two-line cost line) and 6 wireless devices: the fold decision counts the notes line as "
                            + "one row, so the adapter folds and the list keeps 5 rows + \"+1 more\""),
        ExpectedVerdict("devices", "powered-unread", .ok,
                        reason: "31 §3 rule 1: a failed port read after a good one — the section says \"couldn't read ports\", "
                            + "never stale rows"),
        ExpectedVerdict("automation", "parity", .ok,
                        reason: "the full schedule: 4 rules + wake + sleep + \"Sleeps after\" — fits after the "
                            + "ISSUE-12 levers (30-spec §16, rows 31·2)"),
        ExpectedVerdict("now", "now-worst", .ok,
                        reason: "banner up + keep-awake on, the interruption, pause caveat, Top Up, High Power and auto notes all in play; "
                            + "G-8 option F folds them behind one line + \"+N more\", the two "
                            + "keep-awake explanations live on Automation"),
        ExpectedVerdict("now", "now-longlead", .ok,
                        reason: "banner up + keep-awake on, the LONGEST command outcome as the lead (\"Scheduled: \" + "
                            + "neverReachedLimit) with the High Power and auto notes — G-9: the lead rests in its "
                            + "short form (two lines, never cut), the full text is the card's first entry"),
        ExpectedVerdict("automation", "automation-worst", .scrolls,
                        reason: "the full schedule + \"Sleeps after\" + the energy auto-note + one sleep/wake "
                            + "status line — O4 (owner, 2026-09-28): may scroll with the Q1 cue (30-spec §16)"),
        ExpectedVerdict("automation", "automation-keepawake", .scrolls,
                        reason: "the worst case above + a keep-awake session and its notes — T5: may scroll; "
                            + "Q1: scroll bar + flash + bottom fade (30-spec §16, rows 31·2)"),
        ExpectedVerdict("selftest-fixed-520", "selftest", .CLIPPED,
                        reason: "self-test: 520 pt of content in the fixed frame"),
        ExpectedVerdict("selftest-max-520", "selftest", .CLIPPED,
                        reason: "self-test: 520 pt of content in the max-height frame"),
        ExpectedVerdict("selftest-truncation", "selftest", .TRUNCATED,
                        reason: "self-test: a paragraph squeezed under a 440 pt block"),
    ]
}
