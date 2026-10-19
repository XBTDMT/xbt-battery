import XCTest
import Shared

/// Sprint 3.7 STAGE 3 — the FIRST privileged action's command core. These are the security-critical
/// assertions the owner audits: validation rejects out-of-set, the arg array is FIXED + literal-mapped
/// (no injection path), the spawn env is sanitized, and the read-back parse is correct.
final class EnergyModeCommandTests: XCTestCase {

    // MARK: validation rejects out-of-set {0,1,2}
    func testValidate_rejectsOutOfSetMode() {
        for bad in [-1, 3, 4, 99, Int.min, Int.max] {
            XCTAssertNil(EnergyModeCommand.validate(mode: bad, source: 0),
                         "mode \(bad) is out of {0,1,2} and must be rejected")
        }
    }
    func testValidate_rejectsOutOfSetSource() {
        for bad in [-1, 3, 4, 99, Int.min, Int.max] {
            XCTAssertNil(EnergyModeCommand.validate(mode: 0, source: bad),
                         "source \(bad) is out of {0,1,2} and must be rejected")
        }
    }
    func testValidate_acceptsInSet() {
        for m in 0...2 { for s in 0...2 {
            XCTAssertNotNil(EnergyModeCommand.validate(mode: m, source: s), "(\(m),\(s)) must validate")
        }}
    }

    // MARK: the EXACT fixed arg array per (mode, source) — pmset -b|-c|-a powermode 0|1|2
    func testPmsetArguments_exactArrayForEveryCombination() {
        let srcFlag: [EnergySource: String] = [.battery: "-b", .charger: "-c", .all: "-a"]
        let modeDigit: [EnergyModeValue: String] = [.automatic: "0", .low: "1", .high: "2"]
        for source in EnergySource.allCases {
            for mode in EnergyModeValue.allCases {
                let args = EnergyModeCommand.pmsetArguments(mode: mode, source: source)
                XCTAssertEqual(args, ["/usr/bin/pmset", srcFlag[source]!, "powermode", modeDigit[mode]!],
                               "exact argv for mode=\(mode) source=\(source)")
            }
        }
    }

    /// Spot-check the three canonical examples from the spec verbatim.
    func testPmsetArguments_spotChecks() {
        XCTAssertEqual(EnergyModeCommand.pmsetArguments(mode: .low, source: .battery),
                       ["/usr/bin/pmset", "-b", "powermode", "1"])
        XCTAssertEqual(EnergyModeCommand.pmsetArguments(mode: .high, source: .charger),
                       ["/usr/bin/pmset", "-c", "powermode", "2"])
        XCTAssertEqual(EnergyModeCommand.pmsetArguments(mode: .automatic, source: .all),
                       ["/usr/bin/pmset", "-a", "powermode", "0"])
    }

    /// The argv[0] is the absolute path literal; nothing is interpolated and no shell is used.
    func testPmsetArguments_absolutePathFirst_noShell() {
        let args = EnergyModeCommand.pmsetArguments(mode: .low, source: .all)
        XCTAssertEqual(args.first, "/usr/bin/pmset")
        XCTAssertFalse(args.contains { $0.contains("/bin/sh") || $0.contains("-c") && $0 != "-c" })
        XCTAssertEqual(args.count, 4, "exactly 4 argv elements, no extras")
    }

    // MARK: env sanitization
    func testSanitizedEnvironment_dropsInjectionVars_setsControlled() {
        let env = EnergyModeCommand.sanitizedEnvironment()
        for forbidden in ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "LD_LIBRARY_PATH"] {
            XCTAssertNil(env[forbidden], "\(forbidden) must NOT be present in the spawn environment")
        }
        XCTAssertNotNil(env["HOME"], "HOME must be set to a controlled dir")
        XCTAssertNotNil(env["TMPDIR"], "TMPDIR must be set to a controlled dir")
        XCTAssertEqual(env["PATH"], "", "PATH must be CLEARED (executable invoked by absolute path)")
        // No DYLD_* key may leak in under any name.
        XCTAssertTrue(env.keys.allSatisfy { !$0.hasPrefix("DYLD_") }, "no DYLD_* key may be present")
    }

    func testReadbackArguments_isPmsetG() {
        XCTAssertEqual(EnergyModeCommand.readbackArguments(), ["/usr/bin/pmset", "-g"])
    }

    // MARK: read-back parse (pmset -g powermode line)
    func testParsePowermode_extractsValue() {
        let sample = """
        System-wide power settings:
        Currently in use:
         standbydelaylow      10800
         powermode            1
         hibernatemode        3
        """
        XCTAssertEqual(EnergyModeCommand.parsePowermode(fromPmsetG: sample), "1")
    }
    func testParsePowermode_absent_returnsNil() {
        XCTAssertNil(EnergyModeCommand.parsePowermode(fromPmsetG: "Currently in use:\n hibernatemode 3\n"))
    }
    func testParsePowermode_doesNotMatchPrefixLookalike() {
        // a token that merely starts with "powermode" must not match
        XCTAssertNil(EnergyModeCommand.parsePowermode(fromPmsetG: " powermodexyz   9\n"))
    }
}
