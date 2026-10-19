import XCTest
import Shared

/// Sprint 3.7 (wake behavior) — the FOURTH privileged op's command core. Security-critical:
/// `pmsetArguments` accepts ONLY a `validate()`-minted request (the structural injection barrier), the
/// pmset keys ("powernap"/"womp") and scope flags ("-b"/"-c") are literals, and each value is a strict
/// "0"/"1" from a Bool. No rejection path (booleans are always valid). Host-app-free; every case routes
/// `validate()` → `pmsetArguments()` — the same minted path the helper uses.
final class WakeBehaviorCommandTests: XCTestCase {

    private let pmset = WakeBehaviorCommand.pmsetPath

    /// Mint via validate(), then build — the exact path the helper takes.
    private func argv(_ pnB: Bool, _ pnAC: Bool, _ wnB: Bool, _ wnAC: Bool) -> [[String]] {
        let r = WakeBehaviorCommand.validate(powerNapBattery: pnB, powerNapAC: pnAC,
                                             wakeOnNetworkBattery: wnB, wakeOnNetworkAC: wnAC)
        return WakeBehaviorCommand.pmsetArguments(r)
    }

    func testPmsetArguments_allFalse() {
        XCTAssertEqual(argv(false, false, false, false), [
            [pmset, "-b", "powernap", "0", "womp", "0"],
            [pmset, "-c", "powernap", "0", "womp", "0"],
        ])
    }

    func testPmsetArguments_allTrue() {
        XCTAssertEqual(argv(true, true, true, true), [
            [pmset, "-b", "powernap", "1", "womp", "1"],
            [pmset, "-c", "powernap", "1", "womp", "1"],
        ])
    }

    func testPmsetArguments_acOnly() {
        // powerNapBattery=false, powerNapAC=true, wakeOnNetworkBattery=false, wakeOnNetworkAC=true
        XCTAssertEqual(argv(false, true, false, true), [
            [pmset, "-b", "powernap", "0", "womp", "0"],
            [pmset, "-c", "powernap", "1", "womp", "1"],
        ])
    }

    func testPmsetArguments_mixed() {
        // powerNapBattery=true, powerNapAC=false, wakeOnNetworkBattery=false, wakeOnNetworkAC=true
        XCTAssertEqual(argv(true, false, false, true), [
            [pmset, "-b", "powernap", "1", "womp", "0"],
            [pmset, "-c", "powernap", "0", "womp", "1"],
        ])
    }

    /// validate() is NON-optional and never rejects; it mints a request whose four fields equal the inputs.
    func testValidate_mintsRequestEqualToInputs() {
        let r = WakeBehaviorCommand.validate(powerNapBattery: true, powerNapAC: false,
                                             wakeOnNetworkBattery: true, wakeOnNetworkAC: false)
        XCTAssertEqual(r.powerNapBattery, true)
        XCTAssertEqual(r.powerNapAC, false)
        XCTAssertEqual(r.wakeOnNetworkBattery, true)
        XCTAssertEqual(r.wakeOnNetworkAC, false)
    }
}
