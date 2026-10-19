import XCTest

/// Runs the two script self-tests so the installer's and the purger's safety logic are part of the suite:
///   - `scripts/install-release-selftest.sh` — the real install script driven, without root, by a fake
///     `sudo`/`pgrep` at a scratch destination (refusal paths + the DEST-override guard);
///   - `scripts/purge-old-builds-selftest.sh` — purge-old-builds.sh in TEST MODE (never deletes):
///     proc_pidpath IN-USE detection of a relative-path process, a daemon-only list, a >170 KB list,
///     the --delete refusal on an unresolvable helper, and no refusal for a pid that exited mid-scan.
/// Each harness exits 77 when its fixture is missing (a verified Release build / a team-signed Debug
/// build); that maps to a skip, not a pass.
final class InstallReleaseScriptTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func runHarness(_ relative: String) throws -> String {
        let harness = repoRoot.appendingPathComponent(relative)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: harness.path), "\(relative) missing or not executable")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [harness.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus == 77 { throw XCTSkip("\(relative): fixture missing:\n\(output)") }
        XCTAssertEqual(p.terminationStatus, 0, output)
        return output
    }

    func testInstallerRefusalPaths() throws {
        let output = try runHarness("scripts/install-release-selftest.sh")
        XCTAssertTrue(output.contains("6 passed, 0 failed"), output)
    }

    func testPurgeInUseDetectionAndDeleteRefusal() throws {
        let output = try runHarness("scripts/purge-old-builds-selftest.sh")
        XCTAssertTrue(output.contains("6 passed, 0 failed"), output)
    }
}
