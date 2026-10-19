import XCTest

/// WI-N5: the defensive Get parse (Grok SF3) and the reader's outcome routing.
final class LimitReaderTests: XCTestCase {

    // MARK: - parser table

    func testParserAcceptsPlainAndWrappedIntegers() {
        XCTAssertEqual(LimitOutputParser.parse("80"), 80)
        XCTAssertEqual(LimitOutputParser.parse("  85\n"), 85)
        XCTAssertEqual(LimitOutputParser.parse("Charge Limit: 90"), 90)
        XCTAssertEqual(LimitOutputParser.parse("limit is 95 percent"), 95)
        XCTAssertEqual(LimitOutputParser.parse("Battery Limit is 80%"), 80)
        XCTAssertEqual(LimitOutputParser.parse("100"), 100)
    }

    func testParserTakesFirstINRANGEIntegerNotFirstInteger() {
        // "extract the first integer token, sanity-range 80..100" + "only an output with NO
        // extractable in-range integer is a parse failure": out-of-range tokens are skipped.
        XCTAssertEqual(LimitOutputParser.parse("2026: limit 85"), 85)
        XCTAssertEqual(LimitOutputParser.parse("level 62, limit 80"), 80)
    }

    func testParserRejectsOutOfRangeAndGarbage() {
        XCTAssertNil(LimitOutputParser.parse("62"))     // the misbuilt-shortcut value (battery level)
        XCTAssertNil(LimitOutputParser.parse("79"))
        XCTAssertNil(LimitOutputParser.parse("101"))
        XCTAssertNil(LimitOutputParser.parse("180"))    // NOT "1 in 80…100 then 80"
        XCTAssertNil(LimitOutputParser.parse(""))
        XCTAssertNil(LimitOutputParser.parse("no numbers here"))
        XCTAssertNil(LimitOutputParser.parse("8 0"))
    }

    // MARK: - reader routing

    func testReadParsesOutputFile() async {
        let runner = MockShortcutRunner([.init(.success(stdout: ""), file: "80")])
        let result = await LimitReader(runner: runner).read()
        XCTAssertEqual(result, .value(80))
        XCTAssertEqual(runner.invocations.first?.name, "Battery Limit Get")
        XCTAssertNotNil(runner.invocations.first?.outputPath, "the Get must use -o")
    }

    func testReadFallsBackToStdoutWhenFileEmpty() async {
        let runner = MockShortcutRunner([.init(.success(stdout: "90"))])   // no file written
        let result = await LimitReader(runner: runner).read()
        XCTAssertEqual(result, .value(90))
    }

    func testUnparseableOutputIsUnavailableNotError() async {
        // The real failure observed live: a misbuilt Get returning the battery LEVEL (62).
        let runner = MockShortcutRunner([.init(.success(stdout: ""), file: "62")])
        let result = await LimitReader(runner: runner).read()
        XCTAssertEqual(result, .unavailable(.outputUnparseable))
    }

    func testRunnerTaxonsRouteToUnavailableReasons() async {
        let cases: [(ShortcutRunOutcome, LimitReadProblem)] = [
            (.missingShortcut, .missingShortcut),
            (.automationBlocked(stderrTail: ""), .automationBlocked),
            (.failed(exitCode: 1, stderrTail: "x"), .runnerFailure),
            (.shortcutsBinaryAbsent, .runnerFailure),
            (.launchFailed(message: "m"), .runnerFailure),
        ]
        for (outcome, problem) in cases {
            let runner = MockShortcutRunner([.init(outcome)])
            let result = await LimitReader(runner: runner).read()
            XCTAssertEqual(result, .unavailable(problem), "for \(outcome)")
        }
    }

    func testReadLimitMapsToFirstClassUnknown() async {
        let ok = MockShortcutRunner([.init(.success(stdout: ""), file: "85")])
        let okValue = await LimitReader(runner: ok).readLimit()
        XCTAssertEqual(okValue, .known(85))

        let broken = MockShortcutRunner([.init(.missingShortcut)])
        let unknown = await LimitReader(runner: broken).readLimit()
        XCTAssertEqual(unknown, .unknown)
    }

    // MARK: - canonical names (sec 3, exact strings)

    func testCanonicalShortcutNames() {
        XCTAssertEqual(ChargeShortcuts.setName(for: 80), "Battery Limit 80")
        XCTAssertEqual(ChargeShortcuts.get, "Battery Limit Get")
        XCTAssertEqual(ChargeShortcuts.allRequiredNames,
                       ["Battery Limit 80", "Battery Limit 85", "Battery Limit 90",
                        "Battery Limit 95", "Battery Limit 100", "Battery Limit Get"])
    }
}

/// WI-N5: the sec-5 Pause mapping table.
final class PauseResumePolicyTests: XCTestCase {

    func testPauseTargetMapping() {
        // min(95, highest step <= SoC), floor 80 — the spec's own examples first.
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 87), 85)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 79), 80)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 97), 95)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 100), 95)
        // Boundaries.
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 80), 80)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 84), 80)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 85), 85)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 90), 90)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 94), 90)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 95), 95)
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: 50), 80)   // floor
        // Unknown SoC → the conservative floor (flagged interpretation).
        XCTAssertEqual(PauseResumePolicy.pauseTarget(socPercent: nil), 80)
    }
}
