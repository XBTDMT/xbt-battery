import XCTest
import Shared

/// Sprint 3.7 (wake behavior) STAGE 2a — the pure `pmset -g custom` read-back parse + the three-way
/// UI-scope mapping. Host-app-free. Mirrors SleepWakeReadbackTests: the read-back parse is a separate
/// pure layer from the WakeBehaviorCommand write. The leading spaces before powernap/womp mirror real
/// `pmset -g custom` output.
final class WakeBehaviorReadbackTests: XCTestCase {

    // MARK: - parse

    func testParse_liveDefault() {
        let out = "Battery Power:\n standby              1\n powernap             1\n womp                 0\n tcpkeepalive         1\nAC Power:\n standby              1\n powernap             1\n womp                 1\n tcpkeepalive         1\n"
        XCTAssertEqual(WakeBehaviorReadback.parse(out),
            WakeBehaviorReadback.State(powerNapBattery: true, powerNapAC: true,
                                       wakeOnNetworkBattery: false, wakeOnNetworkAC: true))
    }

    func testParse_liveDefault_CRLF() {
        let out = "Battery Power:\r\n powernap             1\r\n womp                 0\r\nAC Power:\r\n powernap             1\r\n womp                 1\r\n"
        XCTAssertEqual(WakeBehaviorReadback.parse(out),
            WakeBehaviorReadback.State(powerNapBattery: true, powerNapAC: true,
                                       wakeOnNetworkBattery: false, wakeOnNetworkAC: true))
    }

    func testParse_mixed() {
        let out = "Battery Power:\n powernap             0\n womp                 1\nAC Power:\n powernap             1\n womp                 0\n"
        XCTAssertEqual(WakeBehaviorReadback.parse(out),
            WakeBehaviorReadback.State(powerNapBattery: false, powerNapAC: true,
                                       wakeOnNetworkBattery: true, wakeOnNetworkAC: false))
    }

    func testParse_missingACBlock_isNil() {
        let out = "Battery Power:\n powernap             1\n womp                 0\n"
        XCTAssertNil(WakeBehaviorReadback.parse(out), "no AC block → cannot fully trust → nil")
    }

    func testParse_missingWompLine_isNil() {
        let out = "Battery Power:\n powernap             1\n womp                 0\nAC Power:\n powernap             1\n"
        XCTAssertNil(WakeBehaviorReadback.parse(out), "AC block missing the womp line → nil")
    }

    // MARK: - mapping (bools <-> three-way scope)

    func testBoolsForScope() {
        let never = WakeBehaviorReadback.bools(for: .never)
        XCTAssertEqual(never.battery, false); XCTAssertEqual(never.ac, false)
        let adapter = WakeBehaviorReadback.bools(for: .onPowerAdapter)
        XCTAssertEqual(adapter.battery, false); XCTAssertEqual(adapter.ac, true)
        let always = WakeBehaviorReadback.bools(for: .always)
        XCTAssertEqual(always.battery, true); XCTAssertEqual(always.ac, true)
    }

    func testScopeForBools() {
        XCTAssertEqual(WakeBehaviorReadback.scope(battery: false, ac: false), .never)
        XCTAssertEqual(WakeBehaviorReadback.scope(battery: false, ac: true), .onPowerAdapter)
        XCTAssertEqual(WakeBehaviorReadback.scope(battery: true, ac: true), .always)
        XCTAssertEqual(WakeBehaviorReadback.scope(battery: true, ac: false), .always,
                       "the degenerate (battery on, AC off) normalizes to .always")
    }

    func testScopeBoolsRoundTrip() {
        for s in WakeBehaviorReadback.Scope.allCases {
            let b = WakeBehaviorReadback.bools(for: s)
            XCTAssertEqual(WakeBehaviorReadback.scope(battery: b.battery, ac: b.ac), s,
                           "round-trip must hold for \(s)")
        }
    }
}
