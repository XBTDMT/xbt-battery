import XCTest
import AppIntents
import Shared   // EnergyModeValue, EnergySource

/// Phase 5 feature #17 Pass 2 (Energy Mode): the @MainActor Energy-Mode intent surface, mirroring
/// ChargeControlIntentSurfaceTests / TopUpIntentSurfaceTests. The surface validates the request (the hang
/// guard), resolves the ACTIVE per-source scope live, then bridges the controller's additive Int +
/// completion overload into an async result. Host-app-free via a seam mock.
@MainActor
final class EnergyModeIntentSurfaceTests: XCTestCase {

    /// Records the set calls + the (mode, source) args; `result` is the Result the (mock) controller
    /// returns, settable per test to exercise the arm mapping. Fires the completion synchronously, like the
    /// real controller's single serialized reply path.
    final class MockEnergySetter: EnergyModeSetting {
        var result: Result<String, HelperClientError> = .success("0")
        private(set) var calls = 0
        private(set) var lastMode: Int?
        private(set) var lastSource: Int?
        func setMode(_ mode: Int, source: Int,
                     completion: (@MainActor (Result<String, HelperClientError>) -> Void)?) {
            calls += 1; lastMode = mode; lastSource = source
            completion?(result)
        }
    }

    private func makeSurface(setter: MockEnergySetter = MockEnergySetter(),
                             plugged: Bool = true) -> EnergyModeIntentSurface {
        EnergyModeIntentSurface(setter: setter,
                                activeSource: { plugged ? .charger : .battery })
    }

    // MARK: - HANG FIX (RED-first): an invalid request returns .invalidRequest and NEVER reaches the setter

    /// The headline hang guard (spec §2/§5). EnergyModeController.setMode returns WITHOUT firing its
    /// completion when validate(mode:source:) == nil, so a naïve withCheckedContinuation over that path would
    /// hang forever. The surface must validate FIRST and return .invalidRequest without bridging. A naïve
    /// bridge (no guard) would instead call the setter and return its mapped result — this test pins that out.
    func testInvalidModeReturnsInvalidRequestAndDoesNotCallSetter() async {
        let setter = MockEnergySetter()
        let surface = EnergyModeIntentSurface(setter: setter, activeSource: { .charger })
        let r = await surface.setMode(99)   // out of the {0,1,2} set the AppEnum constrains; the surface is the guard
        XCTAssertEqual(r, .invalidRequest)
        XCTAssertEqual(setter.calls, 0, "an invalid request must not reach the setter (no bridge, no hang)")
    }

    // MARK: - arm mappings (valid input)

    func testSuccessMapsToAppliedWithReadbackToken() async {
        let setter = MockEnergySetter(); setter.result = .success("1")
        let r = await makeSurface(setter: setter).setMode(EnergyModeValue.low.rawValue)
        XCTAssertEqual(r, .applied("1"), "success carries the helper read-back token verbatim")
        XCTAssertEqual(setter.calls, 1)
    }

    func testUnreachableMapsToHelperUnreachable() async {
        let setter = MockEnergySetter(); setter.result = .failure(.unreachable)
        let r = await makeSurface(setter: setter).setMode(EnergyModeValue.automatic.rawValue)
        XCTAssertEqual(r, .helperUnreachable)
        XCTAssertEqual(setter.calls, 1)
    }

    func testSerializedDropTokenMapsToBusy() async {
        let setter = MockEnergySetter()
        setter.result = .failure(.helperError(EnergyModeController.serializedDropToken))
        let r = await makeSurface(setter: setter).setMode(EnergyModeValue.low.rawValue)
        XCTAssertEqual(r, .busy, "the serialization-drop token is a busy, not a rejection")
    }

    func testOtherHelperErrorMapsToRejected() async {
        let setter = MockEnergySetter()
        setter.result = .failure(.helperError("error:set-failed"))
        let r = await makeSurface(setter: setter).setMode(EnergyModeValue.high.rawValue)
        XCTAssertEqual(r, .rejected, "a real helper rejection token is a rejection")
    }

    /// The reused-case distinction (spec §2/§5): a drop and a real rejection both arrive as
    /// `.helperError(token)`; ONLY the exact serializedDropToken string is `.busy`, everything else
    /// (including a near-miss) is `.rejected`.
    func testDropTokenMatchIsExactStringNotPrefix() async {
        let setter = MockEnergySetter()
        setter.result = .failure(.helperError(EnergyModeController.serializedDropToken + "x"))
        let r = await makeSurface(setter: setter).setMode(EnergyModeValue.low.rawValue)
        XCTAssertEqual(r, .rejected, "only the exact drop token is busy; a near-miss is a real rejection")
    }

    // MARK: - SCOPE resolution (the HARD SAFETY constraint): the ACTIVE per-source scope, resolved live

    func testPluggedResolvesChargerScope() async {
        let setter = MockEnergySetter()
        _ = await makeSurface(setter: setter, plugged: true).setMode(EnergyModeValue.low.rawValue)
        XCTAssertEqual(setter.lastSource, EnergySource.charger.rawValue, "plugged → the active source is charger")
    }

    func testUnpluggedResolvesBatteryScope() async {
        let setter = MockEnergySetter()
        _ = await makeSurface(setter: setter, plugged: false).setMode(EnergyModeValue.low.rawValue)
        XCTAssertEqual(setter.lastSource, EnergySource.battery.rawValue, "unplugged → the active source is battery")
    }

    func testSetterReceivesTheRequestedMode() async {
        let setter = MockEnergySetter()
        _ = await makeSurface(setter: setter).setMode(EnergyModeValue.high.rawValue)
        XCTAssertEqual(setter.lastMode, EnergyModeValue.high.rawValue, "the requested mode is passed through unchanged")
    }

    // MARK: - AppEnum ↔ EnergyModeValue lockstep (the single source of truth for the set values)

    func testEnergyModeOptionMatchesEnergyModeValue() {
        // Per-case lockstep, not just the value SET: the surface passes mode.rawValue straight to the
        // controller with no name-based remapping, so a name↔value swap (e.g. low=2 / high=1) would
        // silently write the WRONG mode while a sorted-array compare still passed. Pin each named case,
        // plus a count guard so a case added to only one enum fails the lockstep.
        XCTAssertEqual(EnergyModeOption.automatic.rawValue, EnergyModeValue.automatic.rawValue)
        XCTAssertEqual(EnergyModeOption.low.rawValue,       EnergyModeValue.low.rawValue)
        XCTAssertEqual(EnergyModeOption.high.rawValue,      EnergyModeValue.high.rawValue)
        XCTAssertEqual(EnergyModeOption.allCases.count, EnergyModeValue.allCases.count,
                       "a case added to one enum but not the other must fail the lockstep")
    }
}
