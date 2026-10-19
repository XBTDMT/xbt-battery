import XCTest
import Shared
@testable import Battery

/// #29 D-4b — EnergyModePresentation: the single-homed value / currentMode / label / matches mapping
/// shared by the popover root Energy-mode card and the Settings · Automation per-source picker. Pure,
/// host-app-free; extracted from BatteryPopoverView so the two consumers don't duplicate it.
final class EnergyModePresentationTests: XCTestCase {

    func testValueMapsDisplayModes() {
        XCTAssertEqual(EnergyModePresentation.value(from: .automatic), .automatic)
        XCTAssertEqual(EnergyModePresentation.value(from: .low), .low)
        XCTAssertEqual(EnergyModePresentation.value(from: .high), .high)
        XCTAssertNil(EnergyModePresentation.value(from: .unavailable))   // no picker value for unavailable
    }

    func testLabels() {
        XCTAssertEqual(EnergyModePresentation.label(.automatic), "Auto")
        XCTAssertEqual(EnergyModePresentation.label(.low), "Low")
        XCTAssertEqual(EnergyModePresentation.label(.high), "High")
    }

    func testMatches() {
        XCTAssertTrue(EnergyModePresentation.matches(.automatic, .automatic))
        XCTAssertTrue(EnergyModePresentation.matches(.low, .low))
        XCTAssertTrue(EnergyModePresentation.matches(.high, .high))
        XCTAssertFalse(EnergyModePresentation.matches(.low, .high))
        XCTAssertFalse(EnergyModePresentation.matches(.automatic, .unavailable))
    }

    /// With a per-source read present, currentMode returns THAT source's value independent of which
    /// source is active (the A1 fix: an AC-profile set no longer looks inert on battery).
    func testCurrentModeUsesPerSourceWhenPresent() {
        let per = EnergyModeReader.PerSourceEnergyMode(battery: .low, charger: .high)
        XCTAssertEqual(EnergyModePresentation.currentMode(for: .battery, active: .charger,
                                                          activeMode: .automatic, perSource: per), .low)
        XCTAssertEqual(EnergyModePresentation.currentMode(for: .charger, active: .battery,
                                                          activeMode: .automatic, perSource: per), .high)
    }

    /// With NO per-source read yet, the active source reflects activeMode; the other is `.unavailable`
    /// (never marked, so we never bold a guessed value).
    func testCurrentModeFallsBackToActiveWhenNoPerSource() {
        XCTAssertEqual(EnergyModePresentation.currentMode(for: .battery, active: .battery,
                                                          activeMode: .high, perSource: nil), .high)
        XCTAssertEqual(EnergyModePresentation.currentMode(for: .charger, active: .battery,
                                                          activeMode: .high, perSource: nil), .unavailable)
    }
}
