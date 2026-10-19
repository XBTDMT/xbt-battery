import XCTest

/// Sprint 3.7 fix A2: the powermetrics tasks-sampler plist parser, corrected to the REAL structure.
/// The Stage 4/5 parser assumed a top-level `tasks` array that does NOT exist. The real output keys the
/// per-responsible-app rows under a top-level `coalitions` LIST (each row already grouped: name = bundle
/// id, energy_impact = the unitless composite, id, tasks = members), with `all_tasks` (a DICT, pid -2
/// "ALL_TASKS") as the grand total. The owner audits SAFE DEGRADATION (garbled/truncated/empty → never
/// crash, never partial-as-real) and same-name coalition folding.
final class SustainedEnergyParserTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/energy/\(name)")
        return try Data(contentsOf: url)
    }

    /// REAL trimmed capture (from /tmp/pm.plist): 5 coalition rows, two of them com.apple.Spotlight,
    /// fold to 4 entries ranked by energy_impact desc. Values are the actual captured numbers.
    func testParse_realCoalitionsFixture_rankedDesc_foldsSameName() throws {
        let entries = try XCTUnwrap(SustainedEnergyParser.parse(plistData: try fixture("powermetrics-coalitions.txt")))
        XCTAssertEqual(entries.count, 4, "5 coalition rows (2 Spotlight) fold into 4 responsible-app rows")
        XCTAssertEqual(entries.map(\.name),
                       ["com.mitchellh.ghostty", "com.apple.airportd", "com.apple.WindowServer", "com.apple.Spotlight"])
        XCTAssertEqual(entries[0].energyImpact, 75.0357, accuracy: 0.0001)
        XCTAssertEqual(entries[1].energyImpact, 32.3446, accuracy: 0.0001)
        XCTAssertEqual(entries[2].energyImpact, 24.1374, accuracy: 0.0001)
        XCTAssertEqual(entries[3].energyImpact, 0.09636, accuracy: 0.00001,
                       "the two com.apple.Spotlight coalitions sum into ONE row")
        XCTAssertEqual(entries.map(\.energyImpact), entries.map(\.energyImpact).sorted(by: >), "sorted desc")
    }

    /// all_tasks.energy_impact = the grand total (the denominator B1 may use). Real value 265.761.
    func testParseTotal_realFixture_returnsAllTasksEnergyImpact() throws {
        let total = try XCTUnwrap(SustainedEnergyParser.parseTotal(plistData: try fixture("powermetrics-coalitions.txt")))
        XCTAssertEqual(total, 265.761, accuracy: 0.001)
    }

    /// Same-name coalitions fold (the real plist has two com.apple.Spotlight); a focused inline case.
    func testParse_duplicateCoalitionName_foldsAndSums() {
        let d = Data("""
        <plist version="1.0"><dict><key>coalitions</key><array>
        <dict><key>name</key><string>com.x.app</string><key>id</key><integer>10</integer><key>energy_impact</key><real>4.0</real></dict>
        <dict><key>name</key><string>com.x.app</string><key>id</key><integer>11</integer><key>energy_impact</key><real>6.0</real></dict>
        </array></dict></plist>
        """.utf8)
        let entries = SustainedEnergyParser.parse(plistData: d)
        XCTAssertEqual(entries?.count, 1, "two coalitions with the same name fold into one")
        XCTAssertEqual(entries?.first?.name, "com.x.app")
        XCTAssertEqual(entries?.first?.energyImpact ?? -1, 10.0, accuracy: 0.001, "4 + 6")
    }

    // MARK: - safe degradation (never crash, never partial-as-real)

    func testParse_garbled_returnsNil_noCrash() throws {
        XCTAssertNil(SustainedEnergyParser.parse(plistData: try fixture("powermetrics-garbled.txt")),
                     "garbled bytes degrade to nil (hide), never crash")
    }
    func testParse_truncated_returnsNil_noCrash() throws {
        XCTAssertNil(SustainedEnergyParser.parse(plistData: try fixture("powermetrics-truncated.txt")),
                     "a truncated plist degrades to nil (hide), never crash, never partial-as-real")
    }
    func testParse_emptyCoalitions_returnsEmpty_noCrash() throws {
        XCTAssertEqual(SustainedEnergyParser.parse(plistData: try fixture("powermetrics-empty-tasks.txt")), [],
                       "a valid plist with an empty coalitions list → [] (hide), not nil/crash")
    }
    func testParse_emptyData_returnsNil() {
        XCTAssertNil(SustainedEnergyParser.parse(plistData: Data()))
    }
    func testParse_validPlistButNoCoalitionsKey_returnsNil() {
        let d = Data("<plist version=\"1.0\"><dict><key>other</key><string>x</string></dict></plist>".utf8)
        XCTAssertNil(SustainedEnergyParser.parse(plistData: d), "unexpected shape (no coalitions key) → nil")
    }

    func testParse_rejectsNonFiniteAndWrongTypeEnergy_neverSurfacedAsReal() {
        // NaN, ±inf, a boolean (<true/> bridges to NSNumber → invented 1.0), and a negative value must
        // all be SKIPPED — never surfaced as a measurement. Only the finite non-negative coalition survives.
        let d = Data("""
        <plist version="1.0"><dict><key>coalitions</key><array>
        <dict><key>name</key><string>good</string><key>energy_impact</key><real>10</real></dict>
        <dict><key>name</key><string>nan</string><key>energy_impact</key><real>nan</real></dict>
        <dict><key>name</key><string>inf</string><key>energy_impact</key><real>inf</real></dict>
        <dict><key>name</key><string>boolish</string><key>energy_impact</key><true/></dict>
        <dict><key>name</key><string>neg</string><key>energy_impact</key><real>-5.0</real></dict>
        </array></dict></plist>
        """.utf8)
        let entries = SustainedEnergyParser.parse(plistData: d)
        XCTAssertEqual(entries?.count, 1, "only the finite, non-negative numeric coalition survives")
        XCTAssertEqual(entries?.first?.name, "good")
        XCTAssertEqual(entries?.first?.energyImpact ?? -1, 10, accuracy: 0.001)
    }

    func testParse_nanMemberOfFoldedNameDoesNotPoisonSum() {
        // Two same-name coalitions: a valid 10 and a NaN. The NaN is skipped, so the folded total is a
        // clean 10 — never a poisoned `nan`.
        let d = Data("""
        <plist version="1.0"><dict><key>coalitions</key><array>
        <dict><key>name</key><string>shared</string><key>energy_impact</key><real>10</real></dict>
        <dict><key>name</key><string>shared</string><key>energy_impact</key><real>nan</real></dict>
        </array></dict></plist>
        """.utf8)
        let entries = SustainedEnergyParser.parse(plistData: d)
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?.energyImpact ?? .nan, 10, accuracy: 0.001, "the NaN is skipped, never poisons the sum")
        XCTAssertTrue((entries?.first?.energyImpact ?? .nan).isFinite, "the folded total stays finite")
    }

    func testParse_allZeroEnergy_hidesNotEmptyBars() {
        // Every surviving coalition at energy 0 → no real activity; HIDE ([]) rather than named rows with
        // collapsed empty bars (parity with EnergyImpactParser's >0 guard).
        let d = Data("""
        <plist version="1.0"><dict><key>coalitions</key><array>
        <dict><key>name</key><string>a</string><key>energy_impact</key><real>0.0</real></dict>
        <dict><key>name</key><string>b</string><key>energy_impact</key><integer>0</integer></dict>
        </array></dict></plist>
        """.utf8)
        XCTAssertEqual(SustainedEnergyParser.parse(plistData: d), [], "all-zero → [] (hide), not empty-bar rows")
    }

    func testParse_skipsCoalitionMissingEnergy_neverPartialAsReal() {
        let d = Data("""
        <plist version="1.0"><dict><key>coalitions</key><array>
        <dict><key>name</key><string>A</string><key>energy_impact</key><real>10</real></dict>
        <dict><key>name</key><string>B</string></dict>
        </array></dict></plist>
        """.utf8)
        let entries = SustainedEnergyParser.parse(plistData: d)
        XCTAssertEqual(entries?.count, 1, "a coalition with no energy_impact is SKIPPED, never fabricated as 0/real")
        XCTAssertEqual(entries?.first?.name, "A")
    }

    func testParse_integerEnergyImpactParsed() {
        let d = Data("""
        <plist version="1.0"><dict><key>coalitions</key><array>
        <dict><key>name</key><string>intco</string><key>energy_impact</key><integer>5</integer></dict>
        </array></dict></plist>
        """.utf8)
        XCTAssertEqual(SustainedEnergyParser.parse(plistData: d)?.first?.energyImpact ?? -1, 5.0, accuracy: 0.001)
    }

    func testParseTotal_missingOrInvalid_returnsNil() {
        XCTAssertNil(SustainedEnergyParser.parseTotal(plistData: Data()), "empty → nil")
        let noAll = Data("<plist version=\"1.0\"><dict><key>coalitions</key><array/></dict></plist>".utf8)
        XCTAssertNil(SustainedEnergyParser.parseTotal(plistData: noAll), "no all_tasks → nil")
        let nanTotal = Data("""
        <plist version="1.0"><dict><key>all_tasks</key>
        <dict><key>name</key><string>ALL_TASKS</string><key>energy_impact</key><real>nan</real></dict></dict></plist>
        """.utf8)
        XCTAssertNil(SustainedEnergyParser.parseTotal(plistData: nanTotal), "non-finite total → nil")
    }
}
