import XCTest
import Shared

/// Sprint 3.7 STAGE 4 — the read-only energy query's command core. Security-critical: range-check
/// rejects out-of-range BEFORE construction, and the argv is FIXED (only the two range-checked ints
/// are rendered as digits). Same validate-before-construct pattern as setEnergyMode.
final class TaskEnergyCommandTests: XCTestCase {

    // MARK: range-check rejects out-of-range
    func testValidate_rejectsOutOfRangeSamples() {
        for bad in [0, 4, 99, -1, Int.min, Int.max] {
            XCTAssertNil(TaskEnergyCommand.validate(samples: bad, intervalMs: 200),
                         "samples \(bad) is outside [1,3] and must be rejected")
        }
    }
    func testValidate_rejectsOutOfRangeInterval() {
        for bad in [199, 5001, 0, -1, Int.min, Int.max] {
            XCTAssertNil(TaskEnergyCommand.validate(samples: 1, intervalMs: bad),
                         "interval \(bad) is outside [200,5000] and must be rejected")
        }
    }
    func testValidate_acceptsInRangeBoundaries() {
        XCTAssertNotNil(TaskEnergyCommand.validate(samples: 1, intervalMs: 200))
        XCTAssertNotNil(TaskEnergyCommand.validate(samples: 3, intervalMs: 5000))
        XCTAssertNotNil(TaskEnergyCommand.validate(samples: 2, intervalMs: 1000))
    }

    // MARK: the EXACT fixed argv (only the two validated ints vary)
    func testPowermetricsArguments_exactArray() throws {
        func argv(_ s: Int, _ i: Int) throws -> [String] {
            let req = try XCTUnwrap(TaskEnergyCommand.validate(samples: s, intervalMs: i))
            return TaskEnergyCommand.powermetricsArguments(req)
        }
        let tail = ["--samplers", "tasks", "-f", "plist", "--show-process-energy", "--show-process-coalition"]
        XCTAssertEqual(try argv(1, 200),
                       ["/usr/bin/powermetrics", "-n", "1", "-i", "200"] + tail)
        XCTAssertEqual(try argv(3, 5000),
                       ["/usr/bin/powermetrics", "-n", "3", "-i", "5000"] + tail)
        XCTAssertEqual(try argv(2, 1000),
                       ["/usr/bin/powermetrics", "-n", "2", "-i", "1000"] + tail)
    }

    func testPowermetricsArguments_absolutePathFirst_noShell_oneShotDefault() throws {
        let req = try XCTUnwrap(TaskEnergyCommand.validate(samples: TaskEnergyCommand.defaultSamples, intervalMs: 1000))
        let args = TaskEnergyCommand.powermetricsArguments(req)
        XCTAssertEqual(args.first, "/usr/bin/powermetrics")
        XCTAssertFalse(args.contains("/bin/sh"))
        XCTAssertEqual(TaskEnergyCommand.defaultSamples, 1, "default is ONE-SHOT (energy-irony rule)")
        // argv contains exactly the plist + tasks samplers, nothing app-controlled beyond the two ints
        XCTAssertTrue(args.contains("plist") && args.contains("tasks"))
    }
}
