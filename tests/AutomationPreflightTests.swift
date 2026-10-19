import XCTest

/// WI-N1 / sec 8(i): the pure OSStatus→verdict mapping of the advisory pre-flight probe.
/// (The live AE call is on-device territory — WI-N8; nothing here touches TCC.)
final class AutomationPreflightTests: XCTestCase {

    func testStatusMappingCoversAllDocumentedVerdicts() {
        XCTAssertEqual(AutomationPreflight.map(status: noErr), .granted)
        XCTAssertEqual(AutomationPreflight.map(status: OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(AutomationPreflight.map(status: OSStatus(errAEEventWouldRequireUserConsent)),
                       .requiresPrompt)
        XCTAssertEqual(AutomationPreflight.map(status: OSStatus(procNotFound)), .shortcutsNotRunning)
    }

    func testUnknownStatusIsIndeterminateNeverMisclassified() {
        // Anything undocumented must map to .indeterminate — behavior never branches on it.
        XCTAssertEqual(AutomationPreflight.map(status: -50), .indeterminate(-50))
        XCTAssertEqual(AutomationPreflight.map(status: 1), .indeterminate(1))
    }

    // MARK: - #29 orphan-backlog: the advisory diagnostic surface for the recorded verdict

    func testAdvisoryNoteOnlySpeaksForDenied() {
        // sec 8(i): the probe is advisory. Only `.denied` names something the owner can act on; every
        // other verdict (including "not yet determined") must stay silent rather than guess out loud.
        XCTAssertNotNil(AutomationPreflight.advisoryNote(.denied))
        XCTAssertNil(AutomationPreflight.advisoryNote(nil))
        XCTAssertNil(AutomationPreflight.advisoryNote(.granted))
        XCTAssertNil(AutomationPreflight.advisoryNote(.requiresPrompt))
        XCTAssertNil(AutomationPreflight.advisoryNote(.shortcutsNotRunning))
        XCTAssertNil(AutomationPreflight.advisoryNote(.indeterminate(-1)))
    }

    func testAdvisoryNoteIsPhrasedAsAPossibleCauseNotADiagnosis() {
        // The governance line this copy has to hold: it may point somewhere to look, never promise a cause.
        let note = AutomationPreflight.advisoryNote(.denied) ?? ""
        XCTAssertTrue(note.hasPrefix("Diagnostic:"), "it must present itself as a diagnostic, not a verdict")
        XCTAssertTrue(note.contains("If limit changes"), "the claim is conditional")
        XCTAssertTrue(note.contains("Privacy & Security"), "it must say where to look")
    }
}
