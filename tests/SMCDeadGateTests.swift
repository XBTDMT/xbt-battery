import XCTest

/// CI/unit complement to the NON-BYPASSABLE build-phase SMC-DEAD gate (SPEC sec 5/8).
///
/// The post-build run-script phase on the helper target is the PRIMARY enforcement — every helper
/// build runs `scripts/smc-dead-gate.sh` on the linked binary and FAILS the build on any SMC content.
/// These tests are the host-app-free regression check that:
///   1. the gate script exists,
///   2. the membership check (a) PASSES on the real project.yml,
///   3. it has TEETH — a synthesized tool target that pulls helper/SMC + a bridging header FAILS (a),
///   4. (when a freshly-built helper binary is reachable) the FULL gate (a)-(d) PASSES on it.
final class SMCDeadGateTests: XCTestCase {

    /// tests/SMCDeadGateTests.swift → repo root is two directories up.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private var gateScript: URL { repoRoot.appendingPathComponent("scripts/smc-dead-gate.sh") }
    private var projectYml: URL { repoRoot.appendingPathComponent("project.yml") }

    private func runGate(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [gateScript.path] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "spawn failed: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testGateScriptExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: gateScript.path),
                      "scripts/smc-dead-gate.sh must exist (the SMC-DEAD gate)")
    }

    func testMembershipGatePassesOnRealProjectYml() {
        let r = runGate(["--membership-only", projectYml.path])
        XCTAssertEqual(r.status, 0, "check (a) must PASS on the real project.yml.\n\(r.output)")
    }

    func testMembershipGateHasTeeth() throws {
        // A synthesized project.yml whose tool target pulls helper/SMC + a bridging header MUST fail (a).
        let bad = """
        targets:
          com.example.batteryapp.energyhelper:
            type: tool
            sources:
              - helper/SMC
              - helper/main.swift
            settings:
              base:
                SWIFT_OBJC_BRIDGING_HEADER: helper/SMC/SMCShim.h
        """
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bad-project-\(UUID().uuidString).yml")
        try bad.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = runGate(["--membership-only", tmp.path])
        XCTAssertNotEqual(r.status, 0, "check (a) must FAIL when the tool target pulls helper/SMC.\n\(r.output)")
    }

    func testFullGatePassesOnBuiltHelperIfPresent() throws {
        // Locate a freshly-built energy-helper binary; if none, skip (the build-phase covers b/c/d).
        let bin = repoRoot.appendingPathComponent("build/sym/Debug/com.example.batteryapp.energyhelper")
        guard FileManager.default.fileExists(atPath: bin.path) else {
            throw XCTSkip("no built energy-helper binary found; the build-phase gate covers (b)-(d)")
        }
        let r = runGate([bin.path, projectYml.path])
        XCTAssertEqual(r.status, 0, "full SMC-DEAD gate must PASS on the built helper.\n\(r.output)")
    }

    /// Binary-level TEETH (the analogue of testMembershipGateHasTeeth for checks b/c/d): compile a
    /// throwaway SMC-bearing tool (references AppleSMC + links IOKit) and assert the full gate FAILs.
    /// Guards against a regression that neuters the symbol/link/dlopen scans (e.g. a broken regex).
    func testFullGateHasTeethOnSmcBearingBinary() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let srcURL = dir.appendingPathComponent("smcfix-\(UUID().uuidString).c")
        let binURL = dir.appendingPathComponent("smcfix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: srcURL); try? FileManager.default.removeItem(at: binURL) }
        try """
        #include <IOKit/IOKitLib.h>
        int main(void){ io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")); return s ? 1 : 0; }
        """.write(to: srcURL, atomically: true, encoding: .utf8)

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["cc", "-framework", "IOKit", "-o", binURL.path, srcURL.path]
        build.standardError = Pipe(); build.standardOutput = Pipe()
        do { try build.run() } catch { throw XCTSkip("cannot spawn cc: \(error)") }
        build.waitUntilExit()
        guard build.terminationStatus == 0, FileManager.default.fileExists(atPath: binURL.path) else {
            throw XCTSkip("could not compile the SMC fixture (no toolchain in test env)")
        }
        let r = runGate([binURL.path, projectYml.path])
        XCTAssertNotEqual(r.status, 0, "full gate must FAIL on an SMC-bearing binary (b/c/d teeth).\n\(r.output)")
    }
}
