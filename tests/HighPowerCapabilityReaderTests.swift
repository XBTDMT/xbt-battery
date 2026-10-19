import XCTest

/// Sprint 3.7 STAGE 5 — the no-root High Power capability reader. Gates the picker's High Power option:
/// `pmset -g cap` lists `highpowermode` only on hardware that supports it (R-15a: this M4 Max does).
final class HighPowerCapabilityReaderTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/energy/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParse_capPresent_highPowerAvailable() throws {
        XCTAssertTrue(HighPowerCapabilityReader.parse(try fixture("pmset-cap-present.txt")),
                      "highpowermode listed → High Power available")
    }

    func testParse_capAbsent_notAvailable_despiteLowPowerMode() throws {
        // The absent fixture still lists `lowpowermode` (contains the substring "powermode") — the
        // reader must match `highpowermode` specifically and NOT false-positive.
        XCTAssertFalse(HighPowerCapabilityReader.parse(try fixture("pmset-cap-absent.txt")),
                       "no highpowermode line → High Power unavailable (lowpowermode must not fool it)")
    }

    func testParse_garbled_notAvailable() throws {
        XCTAssertFalse(HighPowerCapabilityReader.parse(try fixture("pmset-cap-garbled.txt")))
    }

    func testParse_empty_notAvailable() {
        XCTAssertFalse(HighPowerCapabilityReader.parse(""))
    }

    // MARK: - the three-state value itself (hand-off #1: `.note` now has a production reader)

    func testCapability_isSupported_isConservativeForUnknown() {
        // DELIBERATE and NOT to be flipped: `.unknown` is false, because offering an option that may
        // not work is worse than hiding one that might. The whole point of the third state is that the
        // CALLER can now tell it apart from `.unsupported` and ask again — not that the option appears.
        XCTAssertTrue(HighPowerCapability.supported.isSupported)
        XCTAssertFalse(HighPowerCapability.unsupported.isSupported)
        XCTAssertFalse(HighPowerCapability.unknown("anything").isSupported)
    }

    func testCapability_note_isNilInBothHealthyStates_andComposedInTheThird() {
        // Same shape as `PowerAdapterReadState.note`: an absence the read PROVED is not a problem to
        // report, so the surface stays silent. Only the failed read gets a sentence.
        XCTAssertNil(HighPowerCapability.supported.note)
        XCTAssertNil(HighPowerCapability.unsupported.note)
        XCTAssertEqual(HighPowerCapability.unknown("the capability read exited 3").note,
                       "High Power availability unknown — the capability read exited 3.")
    }
}
