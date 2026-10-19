import XCTest
@testable import Battery

/// Spec 31 §2.5 · the clip gate's pure half (`PageGate`, app/DesignSystem/DSMetric.swift): the verdicts, the
/// expected-verdict table, the `--render-pages` exit code and the heights.txt lines. The SwiftUI half (the
/// `DSPageFrame` channels, the self-test pages) is verified by the harness run itself.
final class PageGateTests: XCTestCase {

    private func result(_ page: String, _ fixture: String, inside: CGFloat?, natural: CGFloat?,
                        cue: Bool = false) -> PageGateResult {
        PageGateResult(page: page, fixture: fixture, inside: inside, natural: natural, scrollCue: cue)
    }

    // MARK: - verdicts

    func testOkWhenInsideFitsAndNaturalIsWithinTwoPoints() {
        XCTAssertEqual(PageGate.verdict(inside: 470, natural: 472, scrollCue: false), .ok)
        XCTAssertEqual(PageGate.verdict(inside: 391, natural: 391, scrollCue: false), .ok)
        XCTAssertEqual(PageGate.verdict(inside: 470, natural: 430, scrollCue: false), .ok)
    }

    func testClippedWhenInsideExceedsTheFrame() {
        XCTAssertEqual(PageGate.verdict(inside: 487, natural: 487, scrollCue: false), .CLIPPED)
        XCTAssertEqual(PageGate.verdict(inside: 470.6, natural: 470.6, scrollCue: false), .CLIPPED)
    }

    func testSubPointLayoutNoiseIsNotAClip() {
        XCTAssertEqual(PageGate.verdict(inside: 470.4, natural: 470.4, scrollCue: false), .ok)
    }

    func testScrollsOnlyWhenTheCueIsOn() {
        XCTAssertEqual(PageGate.verdict(inside: 540, natural: 540, scrollCue: true), .scrolls)
        XCTAssertEqual(PageGate.verdict(inside: 540, natural: 540, scrollCue: false), .CLIPPED)
    }

    func testTheCueNeverExcusesAPageThatFits() {
        XCTAssertEqual(PageGate.verdict(inside: 470, natural: 470, scrollCue: true), .ok)
    }

    func testTruncatedWhenNaturalExceedsInsideByMoreThanTwoPoints() {
        XCTAssertEqual(PageGate.verdict(inside: 468, natural: 555, scrollCue: false), .TRUNCATED)
        XCTAssertEqual(PageGate.verdict(inside: 400, natural: 402.5, scrollCue: false), .TRUNCATED)
        XCTAssertEqual(PageGate.verdict(inside: 470, natural: 500, scrollCue: true), .TRUNCATED)
    }

    func testClippedOutranksTruncated() {
        XCTAssertEqual(PageGate.verdict(inside: 500, natural: 560, scrollCue: false), .CLIPPED)
    }

    func testAMissingOrEmptyChannelIsUnmeasuredNeverOk() {
        XCTAssertEqual(PageGate.verdict(inside: nil, natural: 400, scrollCue: false), .unmeasured)
        XCTAssertEqual(PageGate.verdict(inside: 400, natural: nil, scrollCue: false), .unmeasured)
        XCTAssertEqual(PageGate.verdict(inside: 0, natural: 0, scrollCue: false), .unmeasured)
        XCTAssertEqual(PageGate.verdict(inside: -1, natural: 300, scrollCue: false), .unmeasured)
        XCTAssertEqual(PageGate.verdict(inside: CGFloat.nan, natural: 300, scrollCue: false), .unmeasured)
        XCTAssertEqual(PageGate.verdict(inside: 300, natural: CGFloat.infinity, scrollCue: false), .unmeasured)
    }

    // MARK: - exit codes (a local table, so the stage-1 table can change without touching these)

    private let table: [ExpectedVerdict] = [
        ExpectedVerdict("a", "parity", .ok, reason: "fits"),
        ExpectedVerdict("b", "parity", .CLIPPED, reason: "known clip", interim: "stage 2"),
        ExpectedVerdict("t", "selftest", .TRUNCATED, reason: "self-test"),
    ]

    private var asExpected: [PageGateResult] {
        [result("a", "parity", inside: 470, natural: 400),
         result("b", "parity", inside: 487, natural: 487),
         result("t", "selftest", inside: 468, natural: 555)]
    }

    func testExitZeroWhenEveryVerdictMatchesUnderAllowInterim() {
        XCTAssertEqual(PageGate.exitCode(asExpected, table: table, allowInterim: true), 0)
    }

    func testAnInterimRowFailsTheFlaglessCloseOutRun() {
        XCTAssertEqual(PageGate.exitCode(asExpected, table: table, allowInterim: false), 1)
    }

    func testExitOneWhenAVerdictDiffers() {
        var r = asExpected
        r[0] = result("a", "parity", inside: 490, natural: 490)   // clipped, expected ok
        XCTAssertEqual(PageGate.exitCode(r, table: table, allowInterim: true), 1)
    }

    func testUnmeasuredIsAMismatchNeverAPass() {
        var r = asExpected
        r[0] = result("a", "parity", inside: nil, natural: 400)
        XCTAssertEqual(r[0].verdict, .unmeasured)
        XCTAssertEqual(PageGate.exitCode(r, table: table, allowInterim: true), 1)
    }

    func testAnInterimRowThatNoLongerReproducesIsAMismatch() {
        var r = asExpected
        r[1] = result("b", "parity", inside: 470, natural: 440)   // fixed — the interim row must now go
        XCTAssertEqual(PageGate.exitCode(r, table: table, allowInterim: true), 1)
    }

    func testExitTwoWhenARenderedVariantHasNoRow() {
        XCTAssertEqual(PageGate.exitCode(asExpected + [result("c", "parity", inside: 470, natural: 400)],
                                         table: table, allowInterim: true), 2)
    }

    func testExitTwoWhenATableRowWasNeverRendered() {
        XCTAssertEqual(PageGate.exitCode(Array(asExpected.prefix(2)), table: table, allowInterim: true), 2)
    }

    func testExitTwoWhenARowIsDuplicated() {
        let doubled = table + [ExpectedVerdict("a", "parity", .ok, reason: "again")]
        XCTAssertEqual(PageGate.exitCode(asExpected, table: doubled, allowInterim: true), 2)
    }

    func testExitTwoWhenNothingRendered() {
        XCTAssertEqual(PageGate.exitCode([], table: table, allowInterim: true), 2)
    }

    // MARK: - heights.txt

    func testLineNamesTheClipDepthAndTheInterimOwner() {
        XCTAssertEqual(PageGate.line(result("b", "parity", inside: 487, natural: 487), table: table),
                       "b\tparity\tinside 487\tnatural 487\tCLIPPED by 17 pt\texpected CLIPPED\tINTERIM — stage 2")
    }

    func testLineForAMatchATruncationAndAMissingRow() {
        XCTAssertEqual(PageGate.line(result("a", "parity", inside: 470, natural: 391.4), table: table),
                       "a\tparity\tinside 470\tnatural 391\tok\texpected ok\tMATCH")
        XCTAssertEqual(PageGate.line(result("t", "selftest", inside: 468.2, natural: 555), table: table),
                       "t\tselftest\tinside 468\tnatural 555\tTRUNCATED by 87 pt\texpected TRUNCATED\tMATCH")
        XCTAssertEqual(PageGate.line(result("z", "parity", inside: nil, natural: nil), table: table),
                       "z\tparity\tinside —\tnatural —\tunmeasured\texpected —\tNO TABLE ROW")
    }

    func testFooterCountsEveryStatusAndTheExitCode() {
        XCTAssertEqual(PageGate.footer(asExpected, table: table, allowInterim: false),
                       "gate\t3 variants · 2 match · 1 interim · 0 mismatch · 0 without a row · 0 rows not rendered → exit 1")
        XCTAssertEqual(PageGate.footer(asExpected, table: table, allowInterim: true),
                       "gate\t3 variants · 2 match · 1 interim · 0 mismatch · 0 without a row · 0 rows not rendered → exit 0 (--allow-interim)")
    }

    // MARK: - the stage-1 table

    func testTableCoversTheStage1VariantAxisExactlyOnce() {
        let pairs = PageGate.expected.map { "\($0.page) × \($0.fixture)" }
        XCTAssertEqual(pairs.count, Set(pairs).count, "a page × fixture pair has two rows")
        XCTAssertEqual(Set(pairs), [
            "now × parity", "day × parity", "energy × parity", "health × parity",
            "devices × parity", "automation × parity",
            "now × now-worst", "now × now-longlead", "automation × automation-worst", "automation × automation-keepawake",
            "devices × powered-on-power", "devices × powered-on-battery", "devices × powered-worst", "devices × powered-worst-notes",
            "devices × powered-worst-notes-adapter-ok", "devices × powered-notes-single-port", "devices × powered-unread",
            "health × history-note",
            "selftest-fixed-520 × selftest", "selftest-max-520 × selftest", "selftest-truncation × selftest",
        ])
    }

    /// Spec 30 §16 "32 · Health · history note": the note's longest copy is a gated variant, and it fits.
    func testTheHealthHistoryNoteVariantIsGatedAsOk() {
        let row = PageGate.expected.first { $0.page == "health" && $0.fixture == "history-note" }
        XCTAssertEqual(row?.verdict, .ok)
        XCTAssertNil(row?.interim)
    }

    func testSelfTestRowsExpectTheFailureEachIsBuiltFor() {
        func row(_ page: String) -> ExpectedVerdict? { PageGate.expected.first { $0.page == page } }
        XCTAssertEqual(row("selftest-fixed-520")?.verdict, .CLIPPED)
        XCTAssertEqual(row("selftest-max-520")?.verdict, .CLIPPED)
        XCTAssertEqual(row("selftest-truncation")?.verdict, .TRUNCATED)
        XCTAssertTrue(PageGate.expected.filter { $0.fixture == "selftest" }.allSatisfy { $0.interim == nil })
    }

    func testInterimRowsRecordFailuresOwedByStage2() {
        for row in PageGate.expected where row.interim != nil {
            XCTAssertNotEqual(row.verdict, .ok, "\(row.page) × \(row.fixture): an interim row records a failure")
            XCTAssertNotEqual(row.fixture, "selftest")
            XCTAssertTrue(row.interim?.contains("stage 2") ?? false, "\(row.page) × \(row.fixture) must name its owner")
        }
    }

    func testIssue12ClosedAndNoInterimRowsRemain() {
        let owed = PageGate.expected.filter { $0.interim != nil }.map { "\($0.page) × \($0.fixture)" }
        XCTAssertTrue(owed.isEmpty, "stage 2 resolves every interim row; still owed: \(owed)")
        let row = PageGate.expected.first { $0.page == "automation" && $0.fixture == "parity" }
        XCTAssertEqual(row?.verdict, .ok)
    }

    func testEveryRowStatesItsReason() {
        XCTAssertTrue(PageGate.expected.allSatisfy { !$0.reason.isEmpty })
    }

    func testAutomationWorstCasesAreFinalAndNoInterimRowsRemain() {
        XCTAssertTrue(PageGate.expected.allSatisfy { $0.interim == nil }, "no interim row survives stage 2")
        let worst = PageGate.expected.first { $0.page == "automation" && $0.fixture == "automation-worst" }
        XCTAssertEqual(worst?.verdict, .scrolls, "O4 (owner ruling, 2026-09-28): may scroll with the Q1 cue")
        let ka = PageGate.expected.first { $0.page == "automation" && $0.fixture == "automation-keepawake" }
        XCTAssertEqual(ka?.verdict, .scrolls)
    }

    func testNowWorstCaseFitsItsFrame() {
        // G-8 option F (owner, 2026-09-28): the worst Now page folds its notes behind one line and fits.
        let row = PageGate.expected.first { $0.page == "now" && $0.fixture == "now-worst" }
        XCTAssertEqual(row?.verdict, .ok, "T12 closed by G-8 option F")
        XCTAssertNil(row?.interim)
    }
}
