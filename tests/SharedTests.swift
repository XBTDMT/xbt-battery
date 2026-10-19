import XCTest
import Security
import Shared

/// Proof that the XCTest harness runs and `Shared` links, plus the codified designated-requirement
/// shape (Sprint 3.7 sec 6). String-shape only — no signing, no XPC, no `Bundle.main` (a literal
/// Team ID keeps it deterministic and host-app-free).
final class SharedTests: XCTestCase {

    func testDesignatedRequirementShape() {
        let req = BatteryAppIDs.designatedRequirement(
            forIdentifier: BatteryAppIDs.helper,
            teamID: "ABCDE12345",
            minShortVersion: "0.1")

        XCTAssertTrue(req.contains("identifier \"\(BatteryAppIDs.helper)\""),
                      "DR should pin the helper identifier")
        XCTAssertTrue(req.contains("anchor apple generic"),
                      "DR should carry the Apple anchor")
        XCTAssertTrue(req.contains("leaf[subject.OU] = \"ABCDE12345\""),
                      "DR should carry the quoted Team-ID OU clause (digit-trap safe)")
        XCTAssertTrue(req.contains("info[CFBundleShortVersionString] >= \"0.1\""),
                      "DR should carry the min-version downgrade-defense clause")
    }

    /// The codified single source: the app's NSXPCConnection pin and the registration validation must
    /// use the IDENTICAL helper-DR string (sec 6 — they cannot drift because both call one builder).
    func testHelperRequirementIsTheSingleSourceString() {
        let team = "ABCDE12345"
        let viaConvenience = BatteryAppIDs.helperRequirement(teamID: team)
        let viaBuilder = BatteryAppIDs.designatedRequirement(forIdentifier: BatteryAppIDs.helper, teamID: team)
        XCTAssertEqual(viaConvenience, viaBuilder, "helperRequirement must equal the codified DR builder output")
        XCTAssertTrue(viaConvenience.contains(BatteryAppIDs.helper))
    }

    func testAppAndHelperRequirementsPinDifferentIdentifiers() {
        let team = "ABCDE12345"
        XCTAssertTrue(BatteryAppIDs.appRequirement(teamID: team).contains("identifier \"\(BatteryAppIDs.app)\""))
        XCTAssertTrue(BatteryAppIDs.helperRequirement(teamID: team).contains("identifier \"\(BatteryAppIDs.helper)\""))
        XCTAssertNotEqual(BatteryAppIDs.appRequirement(teamID: team),
                          BatteryAppIDs.helperRequirement(teamID: team))
    }

    // MARK: - Security posture (2026-10-15): the client pin refuses a debuggable / injectable app

    /// The exact strings that ship. Pinned verbatim so any change to the trust chain is a visible,
    /// reviewed diff here — not a silent drift in a builder.
    func testExactRequirementStrings() {
        let team = "ABCDE12345"
        XCTAssertEqual(
            BatteryAppIDs.appRequirement(teamID: team),
            "identifier \"com.example.batteryapp\" and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"ABCDE12345\""
            + " and info[CFBundleShortVersionString] >= \"1.1\""
            + " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
            + " and !(entitlement[\"com.apple.security.cs.allow-dyld-environment-variables\"] exists)"
            + " and !(entitlement[\"com.apple.security.cs.disable-library-validation\"] exists)")
        XCTAssertEqual(
            BatteryAppIDs.helperRequirement(teamID: team),
            "identifier \"com.example.batteryapp.energyhelper\" and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"ABCDE12345\""
            + " and info[CFBundleShortVersionString] >= \"0.2\"")
    }

    /// The app pin carries the APP floor (not the helper's — the pre-fix bug: "0.1" against an app at
    /// "1.0" excluded nothing) and one exclusion clause per code-injection entitlement.
    func testAppRequirementCarriesClientFloorAndEveryInjectionExclusion() {
        let req = BatteryAppIDs.appRequirement(teamID: "ABCDE12345")
        XCTAssertTrue(req.contains("info[CFBundleShortVersionString] >= \"\(BatteryAppIDs.minAppShortVersion)\""))
        XCTAssertFalse(req.contains(">= \"\(BatteryAppIDs.minHelperShortVersion)\""),
                       "the app pin must not reuse the helper's version floor")
        XCTAssertTrue(BatteryAppIDs.clientCodeInjectionEntitlements.contains("com.apple.security.get-task-allow"))
        for key in BatteryAppIDs.clientCodeInjectionEntitlements {
            XCTAssertTrue(req.contains("!(entitlement[\"\(key)\"] exists)"), "missing exclusion for \(key)")
        }
    }

    /// The helper pin has no entitlement clause: the helper is injected-into only by root, and its own
    /// build keeps Xcode's default entitlements (it would fail such a clause).
    func testHelperRequirementHasNoEntitlementClause() {
        let req = BatteryAppIDs.helperRequirement(teamID: "ABCDE12345")
        XCTAssertFalse(req.contains("entitlement["))
        XCTAssertTrue(req.contains("info[CFBundleShortVersionString] >= \"\(BatteryAppIDs.minHelperShortVersion)\""))
    }

    /// The diagnostic split is the pin, part for part — so the launch log can never blame a clause the
    /// pin does not contain, or miss one it does.
    func testAppRequirementPartsJoinToExactlyTheAppRequirement() {
        for team in ["ABCDE12345", "1BCDE12345"] {
            let parts = BatteryAppIDs.appRequirementParts(teamID: team)
            XCTAssertEqual(parts.map(\.requirement).joined(separator: " and "),
                           BatteryAppIDs.appRequirement(teamID: team))
            XCTAssertTrue(parts[0].label.hasPrefix("identity"))
            XCTAssertTrue(parts[0].label.contains(team), "the identity label names the Team ID")
            XCTAssertEqual(parts.count, 2 + BatteryAppIDs.clientCodeInjectionEntitlements.count)
        }
    }

    func testEntitlementsAbsentClauseShape() {
        XCTAssertEqual(BatteryAppIDs.entitlementsAbsentClause(["a.b"]), "!(entitlement[\"a.b\"] exists)")
        XCTAssertEqual(BatteryAppIDs.entitlementsAbsentClause(["a", "b"]),
                       "!(entitlement[\"a\"] exists) and !(entitlement[\"b\"] exists)")
        XCTAssertEqual(BatteryAppIDs.entitlementsAbsentClause([]), "")
        XCTAssertEqual(BatteryAppIDs.designatedRequirement(forIdentifier: "x", teamID: "T"),
                       BatteryAppIDs.designatedRequirement(forIdentifier: "x", teamID: "T", forbiddenEntitlements: []),
                       "no forbidden entitlements → the pre-existing shape, unchanged")
    }

    /// Both shipped strings must COMPILE — `SecRequirementCreateWithString` is what the XPC pins and the
    /// preflight run, and a syntax error there fails CLOSED (every connection refused). This is the
    /// guard against e.g. `entitlement[...] = true`, which is a syntax error in the requirement language.
    func testShippedRequirementsCompile() {
        for req in [BatteryAppIDs.appRequirement(teamID: "ABCDE12345"),
                    BatteryAppIDs.helperRequirement(teamID: "ABCDE12345"),
                    BatteryAppIDs.appRequirement(teamID: "1BCDE12345")] {   // digit-leading Team ID
            var ref: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(req as CFString, [], &ref), errSecSuccess,
                           "requirement does not compile: \(req)")
            XCTAssertNotNil(ref)
        }
    }
}
