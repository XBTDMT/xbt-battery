import XCTest
import Security
import Shared

/// Sprint 3.7 STAGE 2 — UNIT half of the PROOF GATE rejection deliverable.
///
/// Drives the codified audit-token validator (`BatteryAppIDs.peerSatisfies`) with the REAL audit token
/// of the running test process + the REAL Security framework, and proves it REJECTS a non-matching
/// identity and ACCEPTS the process's own designated requirement. This is the same SecCode audit-token
/// check that `NSXPCListener.setConnectionCodeSigningRequirement` performs internally to gate peers —
/// exercised here directly, never via the PID.
final class PeerValidationTests: XCTestCase {

    func testPeerSatisfies_REJECTS_nonMatchingIdentity() throws {
        guard let token = currentTaskAuditToken() else { throw XCTSkip("audit token unavailable in this env") }
        // A requirement the test process cannot possibly satisfy → MUST be rejected. (The deliverable.)
        let bogus = "identifier \"com.bogus.nomatch.\(UUID().uuidString)\" and anchor apple generic"
        XCTAssertFalse(BatteryAppIDs.peerSatisfies(auditToken: token, requirement: bogus),
                       "audit-token validation MUST reject a non-matching identity")
    }

    func testPeerSatisfies_REJECTS_malformedRequirement() throws {
        guard let token = currentTaskAuditToken() else { throw XCTSkip("audit token unavailable in this env") }
        // A malformed requirement must fail CLOSED (never accept on a broken pin).
        XCTAssertFalse(BatteryAppIDs.peerSatisfies(auditToken: token, requirement: "this is not a valid requirement ((("),
                       "a malformed requirement must fail closed (reject)")
    }

    func testPeerSatisfies_ACCEPTS_ownDesignatedRequirement() throws {
        guard let token = currentTaskAuditToken() else { throw XCTSkip("audit token unavailable in this env") }
        let selfDR = try selfDesignatedRequirement()
        XCTAssertTrue(BatteryAppIDs.peerSatisfies(auditToken: token, requirement: selfDR),
                      "audit-token validation MUST accept the process's own designated requirement")
    }

    func testPeerSignatureSummary_includesIdentifierAndTeam() throws {
        guard let token = currentTaskAuditToken() else { throw XCTSkip("audit token unavailable in this env") }
        let summary = BatteryAppIDs.peerSignatureSummary(auditToken: token)
        XCTAssertTrue(summary.contains("identifier=") && summary.contains("team="),
                      "the auditability summary should carry the peer identifier + team (got: \(summary))")
    }
}
