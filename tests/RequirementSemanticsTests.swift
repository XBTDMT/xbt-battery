import XCTest
import Foundation
import Security
import Shared

/// Security posture (2026-10-15): the code-signing requirement language is evaluated HERE on real signed
/// code — not just string-matched — through the production `BatteryAppIDs.staticCodeSatisfies`.
///
/// The fixtures are ad-hoc signed copies of `/bin/ls` (and minimal `.app` bundles around it) in a temp
/// directory, so the team / anchor clauses cannot be exercised here (ad-hoc code has no Apple anchor);
/// each test evaluates the ONE clause it is about. The team-signed end of the proof is the live-build
/// test at the bottom, plus the `codesign -v -R` evidence recorded with the change.
///
/// What is pinned, each measured first with `codesign -v -R` on macOS 27.2:
///   - `!(entitlement["k"] exists)` refuses code carrying k = true and accepts code without k or with
///     k = false (`exists` is truthy for a boolean entitlement);
///   - `info[CFBundleShortVersionString] >= "x"` compares NUMERICALLY (0.10 > 0.9), not lexicographically;
///   - the shipped Info.plist versions sit on/above their floors, and the pre-fix versions sit below them;
///   - project.yml never lets Xcode inject get-task-allow into the app.
final class RequirementSemanticsTests: XCTestCase {

    /// tests/RequirementSemanticsTests.swift → repo root is two directories up.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("battery-req-semantics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    // MARK: - fixtures

    private func run(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "spawn failed: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func adHocSign(_ path: String, entitlements: URL? = nil) throws {
        var args = ["-f", "-s", "-"]
        if let entitlements { args += ["--entitlements", entitlements.path] }
        let r = run("/usr/bin/codesign", args + [path])
        guard r.status == 0 else { throw XCTSkip("ad-hoc codesign unavailable here (\(r.status)): \(r.output)") }
    }

    /// An ad-hoc signed copy of /bin/ls, optionally carrying ONE entitlement with the given value.
    private func binary(_ name: String, entitlement: (key: String, value: Bool)? = nil) throws -> String {
        let dst = work.appendingPathComponent(name)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: dst.path)
        var ents: URL?
        if let entitlement {
            ents = work.appendingPathComponent("\(name).entitlements")
            try writePlist([entitlement.key: entitlement.value], to: ents!)
        }
        try adHocSign(dst.path, entitlements: ents)
        return dst.path
    }

    /// An ad-hoc signed minimal `.app` bundle whose Info.plist carries `shortVersion`.
    private func bundle(shortVersion: String) throws -> String {
        let app = work.appendingPathComponent("v\(shortVersion)-\(UUID().uuidString.prefix(6)).app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: macos.appendingPathComponent("probe").path)
        try writePlist(["CFBundleExecutable": "probe",
                        "CFBundleIdentifier": "test.requirement.probe",
                        "CFBundleShortVersionString": shortVersion],
                       to: app.appendingPathComponent("Contents/Info.plist"))
        try adHocSign(app.path)
        return app.path
    }

    private func floorClause(_ floor: String) -> String { "info[CFBundleShortVersionString] >= \"\(floor)\"" }

    private func shortVersion(ofPlistAt relative: String) throws -> String {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relative))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return try XCTUnwrap(plist?["CFBundleShortVersionString"] as? String, "\(relative) has no short version")
    }

    // MARK: - the injection-entitlement exclusion

    func testExclusionClauseAcceptsCodeWithoutTheEntitlements() throws {
        let clause = BatteryAppIDs.entitlementsAbsentClause(BatteryAppIDs.clientCodeInjectionEntitlements)
        let plain = try binary("plain")
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: plain, requirement: clause),
                      "code with none of the entitlements must satisfy: \(clause)")
    }

    func testExclusionClauseRefusesEachInjectionEntitlement() throws {
        let clause = BatteryAppIDs.entitlementsAbsentClause(BatteryAppIDs.clientCodeInjectionEntitlements)
        for (i, key) in BatteryAppIDs.clientCodeInjectionEntitlements.enumerated() {
            let path = try binary("with-\(i)", entitlement: (key, true))
            XCTAssertFalse(BatteryAppIDs.staticCodeSatisfies(path: path, requirement: clause),
                           "code carrying \(key) = true must be REFUSED by the client pin")
        }
    }

    /// `exists` is TRUTHY for a boolean entitlement: an explicit `get-task-allow = false` does not
    /// "exist", so the clause accepts it — correctly, since false means "not debuggable" to the kernel.
    /// Pinned (measured with `codesign -v -R` first) so nobody swaps in `absent`, which REFUSES an
    /// explicit false, or a value test: `= true` is a syntax error, and a pin that does not compile
    /// fails closed (refuses everything).
    func testExclusionClauseAcceptsAnExplicitFalseAndValueEqualityIsNotValidSyntax() throws {
        let clause = BatteryAppIDs.entitlementsAbsentClause(["com.apple.security.get-task-allow"])
        let gtaFalse = try binary("gta-false", entitlement: ("com.apple.security.get-task-allow", false))
        let gtaTrue = try binary("gta-true", entitlement: ("com.apple.security.get-task-allow", true))
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: gtaFalse, requirement: clause),
                      "get-task-allow = false is not debuggable → accepted")
        XCTAssertFalse(BatteryAppIDs.staticCodeSatisfies(path: gtaTrue, requirement: clause))
        XCTAssertFalse(BatteryAppIDs.staticCodeSatisfies(
            path: gtaFalse, requirement: "entitlement[\"com.apple.security.get-task-allow\"] absent"),
            "`absent` refuses an explicit false — the reason the clause is written as !(… exists)")
        var ref: SecRequirement?
        XCTAssertNotEqual(SecRequirementCreateWithString(
            "entitlement[\"com.apple.security.get-task-allow\"] = true" as CFString, [], &ref), errSecSuccess,
            "value equality on a boolean entitlement is a syntax error in the requirement language")
    }

    // MARK: - the version floors

    /// The requirement language compares versions NUMERICALLY: 0.9 → 0.10 is a safe bump.
    func testVersionFloorComparesNumerically() throws {
        let v0_1 = try bundle(shortVersion: "0.1"), v0_2 = try bundle(shortVersion: "0.2")
        let v0_9 = try bundle(shortVersion: "0.9"), v0_10 = try bundle(shortVersion: "0.10")
        let v1_0 = try bundle(shortVersion: "1.0")
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: v0_10, requirement: floorClause("0.2")),
                      "0.10 >= 0.2 numerically (it would FAIL lexicographically)")
        XCTAssertFalse(BatteryAppIDs.staticCodeSatisfies(path: v0_9, requirement: floorClause("0.10")),
                       "0.9 < 0.10 numerically (it would PASS lexicographically)")
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: v0_10, requirement: floorClause("0.10")))
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: v1_0, requirement: floorClause("0.10")))
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: v0_2, requirement: floorClause("0.2")))
        XCTAssertFalse(BatteryAppIDs.staticCodeSatisfies(path: v0_1, requirement: floorClause("0.2")))
    }

    /// The versions that SHIP must satisfy their own floors (else the helper refuses the very app it
    /// ships with, or the app refuses its own helper), and the pre-fix versions must not (else the
    /// floor bump excluded nothing — the original finding).
    func testShippedVersionsSitOnTheirFloorsAndPreFixVersionsDoNot() throws {
        let appVersion = try shortVersion(ofPlistAt: "app/Info.plist")
        let helperVersion = try shortVersion(ofPlistAt: "helper/Info.plist")
        let app = try bundle(shortVersion: appVersion)
        let helper = try bundle(shortVersion: helperVersion)
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: app, requirement: floorClause(BatteryAppIDs.minAppShortVersion)),
                      "app/Info.plist \(appVersion) is below minAppShortVersion \(BatteryAppIDs.minAppShortVersion)")
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: helper, requirement: floorClause(BatteryAppIDs.minHelperShortVersion)),
                      "helper/Info.plist \(helperVersion) is below minHelperShortVersion \(BatteryAppIDs.minHelperShortVersion)")
        let preFixApp = try bundle(shortVersion: "1.0"), preFixHelper = try bundle(shortVersion: "0.1")
        XCTAssertFalse(BatteryAppIDs.staticCodeSatisfies(path: preFixApp, requirement: floorClause(BatteryAppIDs.minAppShortVersion)),
                       "every pre-fix app (1.0, signed with get-task-allow) must sit below the client floor")
        XCTAssertFalse(BatteryAppIDs.staticCodeSatisfies(path: preFixHelper, requirement: floorClause(BatteryAppIDs.minHelperShortVersion)),
                       "every pre-fix helper (0.1, accepts a debuggable client) must sit below the helper floor")
    }

    // MARK: - the build setting that keeps get-task-allow out of the app

    /// Xcode injects get-task-allow for Apple Development signing in Debug AND Release (measured), so the
    /// app target must opt out explicitly — and the client pin now depends on it.
    func testProjectYmlNeverInjectsBaseEntitlementsIntoTheApp() throws {
        let yml = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let start = try XCTUnwrap(yml.range(of: "\n  Battery:\n"), "Battery target block not found")
        let end = try XCTUnwrap(yml.range(of: "\n  BatteryTests:\n", range: start.upperBound..<yml.endIndex),
                                "BatteryTests block not found after Battery")
        let appBlock = yml[start.upperBound..<end.lowerBound]
        let active = appBlock.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        XCTAssertTrue(active.contains { $0.trimmingCharacters(in: .whitespaces) == "CODE_SIGN_INJECT_BASE_ENTITLEMENTS: \"NO\"" },
                      "the Battery target must set CODE_SIGN_INJECT_BASE_ENTITLEMENTS: \"NO\"")
    }

    // MARK: - the live build (team-signed), when this source's build is on disk

    /// When the Debug app built FROM THIS SOURCE is reachable (the build-then-test gate leaves it at
    /// build/sym), prove the real team-signed bundle satisfies the exact app pin the helper enforces, and
    /// its embedded helper satisfies the exact helper pin the app enforces. Skips on a stale or absent
    /// build rather than judging a binary this source did not produce.
    func testLiveDebugBuildSatisfiesBothPins() throws {
        let app = repoRoot.appendingPathComponent("build/sym/Debug/Battery.app")
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw XCTSkip("no Debug build at \(app.path)")
        }
        let sourceVersion = try shortVersion(ofPlistAt: "app/Info.plist")
        guard info["CFBundleShortVersionString"] as? String == sourceVersion,
              let team = info["TeamID"] as? String, !team.isEmpty else {
            throw XCTSkip("build/sym is not this source's build (version \(info["CFBundleShortVersionString"] ?? "?") vs \(sourceVersion))")
        }
        // Only a TEAM-signed build can be judged against the pins: an ad-hoc build (or a placeholder
        // TeamID) fails the identity part, and the assertion below would then blame get-task-allow.
        let identity = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard BatteryAppIDs.staticCodeSatisfies(path: app.path, requirement: identity) else {
            throw XCTSkip("build/sym is not signed by an Apple-issued certificate for team \(team) (ad-hoc build?)")
        }
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: app.path, requirement: BatteryAppIDs.appRequirement(teamID: team)),
                      "the built app fails the helper's client pin — is it signed with get-task-allow?")
        let helper = app.appendingPathComponent("Contents/MacOS/\(BatteryAppIDs.helper)").path
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: helper, requirement: BatteryAppIDs.helperRequirement(teamID: team)),
                      "the embedded helper fails the app's helper pin")
    }
}
