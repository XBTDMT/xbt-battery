import XCTest
@testable import Battery

/// #29 D5 (Cut D-2) — the concrete exception→banner mapping + arbitration for the popover root.
/// Verifies: silent when healthy; each exception maps to the right (severity, symbol, tint, action);
/// and the D5 single-slot priority (helper attention > power/limit exception > informational).
final class PopoverBannerMapperTests: XCTestCase {

    func testHealthyIsSilent() {
        XCTAssertNil(PopoverBannerMapper.banner(for: PopoverBannerInputs()))
    }

    func testLowPowerMapsToLeafYellowNoAction() {
        var i = PopoverBannerInputs(); i.lowPower = true
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.severity, .exception)
        XCTAssertEqual(b?.symbol, "leaf.fill")
        XCTAssertEqual(b?.tint, .lowPower)
        XCTAssertNil(b?.action)   // informational — no trailing action
        XCTAssertEqual(b?.message, PopoverBannerStrings.lowPowerBatteryLow)
    }

    func testDegradedMapsToNeutralWithOpenGeneral() {
        var i = PopoverBannerInputs(); i.degraded = true
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.severity, .exception)
        XCTAssertEqual(b?.tint, .neutral)
        XCTAssertEqual(b?.action, .openGeneral)   // D5-A3: charge-control family → Settings · General
    }

    func testSetupRequiredIsHelperAttention() {
        var i = PopoverBannerInputs(); i.setupRequired = true
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.severity, .helperAttention)
        XCTAssertEqual(b?.action, .openGeneral)   // D5-A3: setup required → Settings · General
        XCTAssertEqual(b?.actionTitle, PopoverBannerStrings.setupAction)
        XCTAssertEqual(b?.message, PopoverBannerStrings.setupRequired)
    }

    func testHelperAttentionUsesInjectedMessageAndRoutesToGeneral() {
        var i = PopoverBannerInputs(); i.helperAttention = true; i.helperMessage = "Approve the energy helper."
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.severity, .helperAttention)
        XCTAssertEqual(b?.message, "Approve the energy helper.")
        XCTAssertEqual(b?.action, .openGeneral)   // D5-A3: helper attention re-homed to Settings · General
    }

    func testAutoEnergyHoldUsesInjectedNoteAndRoutesToAutomation() {
        var i = PopoverBannerInputs(); i.autoEnergyHold = true; i.autoEnergyNote = "Low Power held (thermal)."
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.severity, .exception)
        XCTAssertEqual(b?.symbol, "lock.fill")
        XCTAssertEqual(b?.message, "Low Power held (thermal).")
        XCTAssertEqual(b?.action, .openAutomation)   // D5-A3: auto-energy → Settings · Automation
    }

    func testAutoEnergyHoldFallsBackToDefaultNote() {
        var i = PopoverBannerInputs(); i.autoEnergyHold = true
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.message, PopoverBannerStrings.autoEnergyHold)
    }

    func testHelperAttentionWinsOverExceptionAndInformational() {
        var i = PopoverBannerInputs()
        i.helperAttention = true; i.helperMessage = "helper"
        i.degraded = true          // exception tier
        i.lowPower = true          // exception tier
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.severity, .helperAttention)   // single slot, highest wins
        XCTAssertEqual(b?.message, "helper")
    }

    func testHelperAttentionBeatsSetupOnTie() {
        var i = PopoverBannerInputs()
        i.helperAttention = true; i.helperMessage = "helper"
        i.setupRequired = true     // also helperAttention severity
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.message, "helper")   // first-of-equal-severity (helper listed before setup)
    }

    func testExceptionBeatsNothingElse() {
        var i = PopoverBannerInputs(); i.degraded = true; i.lowPower = true
        let b = PopoverBannerMapper.banner(for: i)
        XCTAssertEqual(b?.severity, .exception)
        XCTAssertEqual(b?.tint, .neutral)   // degraded (first exception candidate) wins the tie
    }
}
