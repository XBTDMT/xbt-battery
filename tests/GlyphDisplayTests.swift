import XCTest
import AppKit
@testable import Battery

/// Feature #13: the pure display-decision layer + the renderer's `style:` selector. The %-only tint is
/// the honesty guard — with the glyph gone, the title text must carry the same critical/low-power color
/// the glyph would have (same precedence: critical > lowPower > label).
final class GlyphDisplayTests: XCTestCase {

    func testIconAndPercentShowsImageAndLabelTitle() {
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 80, isChargingDisplay: false, lowPower: false, mode: .iconAndPercent)
        XCTAssertTrue(p.showImage); XCTAssertEqual(p.title, "80%"); XCTAssertEqual(p.tint, .label)
    }

    func testIconOnlyClearsTitle() {
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 80, isChargingDisplay: false, lowPower: false, mode: .iconOnly)
        XCTAssertTrue(p.showImage); XCTAssertNil(p.title)
    }

    func testPercentOnlyHidesImageLabelTintAt80Discharging() {
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 80, isChargingDisplay: false, lowPower: false, mode: .percentOnly)
        XCTAssertFalse(p.showImage); XCTAssertEqual(p.title, "80%"); XCTAssertEqual(p.tint, .label)
    }

    func testPercentOnlyCriticalAtLowSocDischarging() {   // %-only honesty guard (RED-first)
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 15, isChargingDisplay: false, lowPower: false, mode: .percentOnly)
        XCTAssertEqual(p.tint, .critical)
    }

    func testPercentOnlyChargingSuppressesCritical() {
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 15, isChargingDisplay: true, lowPower: false, mode: .percentOnly)
        XCTAssertEqual(p.tint, .label)   // charging suppresses critical (mirrors the glyph red rule); non-LPM → label
    }

    func testPercentOnlyLowPowerTint() {
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 60, isChargingDisplay: false, lowPower: true, mode: .percentOnly)
        XCTAssertEqual(p.tint, .lowPower)
    }

    func testCriticalPrecedesLowPower() {
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 15, isChargingDisplay: false, lowPower: true, mode: .percentOnly)
        XCTAssertEqual(p.tint, .critical)   // critical > lowPower
    }

    func testImageStyleSFSymbolsReturnsInjectedSymbol() {
        let sentinel = NSImage(size: NSSize(width: 99, height: 99))
        let img = MenuBarBatteryIcon.image(soc: 80, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                           onAC: false, lowPower: false, style: .sfSymbols, make: { _ in sentinel })
        XCTAssertEqual(img.size.width, 99, accuracy: 0.001, "sfSymbols style renders the SF symbol from make() directly")
    }

    func testImageStyleNativeContinuousStillCustomDraws() {
        let sentinel = NSImage(size: NSSize(width: 99, height: 99))
        let img = MenuBarBatteryIcon.image(soc: 80, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                           onAC: false, lowPower: false, style: .nativeContinuous, make: { _ in sentinel })
        XCTAssertNotEqual(img.size.width, 99, "nativeContinuous (default) still custom-draws — not the SF make()")
    }

    // ── self-audit additions ──
    func testIconAndPercentStaysLabelAtCriticalSoc() {   // (3) no double-signal: glyph carries color, % stays label
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 15, isChargingDisplay: false, lowPower: false, mode: .iconAndPercent)
        XCTAssertTrue(p.showImage); XCTAssertEqual(p.title, "15%"); XCTAssertEqual(p.tint, .label)
    }

    func testPercentOnlyCriticalBoundaryAt20() {   // (2) mirror render's soc<=20 EXACTLY (boundary)
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 20, isChargingDisplay: false, lowPower: false, mode: .percentOnly)
        XCTAssertEqual(p.tint, .critical)
    }

    func testPercentOnlyNotCriticalAt21() {
        let p = GlyphDisplay.menuBarDisplayPlan(pct: 21, isChargingDisplay: false, lowPower: false, mode: .percentOnly)
        XCTAssertEqual(p.tint, .label)
    }

    func testImageStyleSFSymbolsIsTemplate() {
        let img = MenuBarBatteryIcon.image(soc: 80, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                           onAC: false, lowPower: false, style: .sfSymbols,
                                           make: { _ in NSImage(size: NSSize(width: 99, height: 99)) })
        XCTAssertTrue(img.isTemplate, "the SF style renders a monochrome template (dark/light adaptive)")
    }

    func testImageStyleSFSymbolsFallsThroughWhenUnavailable() {   // never blank
        let img = MenuBarBatteryIcon.image(soc: 80, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                           onAC: false, lowPower: false, style: .sfSymbols, make: { _ in nil })
        XCTAssertTrue(img.isValid)
        XCTAssertGreaterThan(img.size.width, 0, "SF unavailable → falls through to the custom glyph, never blank")
    }

    func testSFFidelityFooterMentionsRedAndLowPowerOnlyForSF() {
        XCTAssertNil(GlyphDisplay.sfFidelityFooter(for: .nativeContinuous))
        let note = GlyphDisplay.sfFidelityFooter(for: .sfSymbols)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.localizedCaseInsensitiveContains("red") ?? false, "disclose the lost low-battery red")
        XCTAssertTrue(note?.localizedCaseInsensitiveContains("Low Power") ?? false, "disclose the lost Low Power color")
        XCTAssertTrue(note?.localizedCaseInsensitiveContains("plugged") ?? false, "disclose the lost #21b plug mark")
    }
}

/// ENERGY (audit A2) + #EI-1 honesty: the menu-bar glyph's redraw gate. `updateStatusButton` returns
/// early when the freshly built key equals the last one, so ANY input the glyph draws from must be a
/// key field — otherwise the state change happens and the pixels never follow (the ISSUE-8 class).
final class GlyphRenderKeyTests: XCTestCase {

    private func key(keepAwake: Bool = false, interrupted: Bool = false, pct: Int = 50,
                     displayMode: GlyphDisplayMode = .iconAndPercent,
                     style: GlyphStyle = .nativeContinuous) -> GlyphRenderKey {
        GlyphRenderKey(pct: pct, chargingDisplay: false, holdMark: false, fullyCharged: false,
                       onAC: false, lowPower: false, keepAwake: keepAwake,
                       keepAwakeInterrupted: interrupted, displayMode: displayMode, style: style)
    }

    func testIdenticalInputsGateTheRedraw() {
        XCTAssertEqual(key(keepAwake: true, interrupted: true), key(keepAwake: true, interrupted: true))
        XCTAssertEqual(key(), key(), "nothing moved -> the three AppKit assignments are skipped")
    }

    /// RED-first for the badge defect: a Mac that sleeps through a keep-awake session changes NOTHING
    /// the old key looked at — same charge, same source, same `isOn` — so the gate suppressed the
    /// repaint and the espresso badge went on steaming across the very event that falsified it.
    func testRenderKeyChangesWhenTheKeepAwakeClaimBreaks() {
        XCTAssertNotEqual(key(keepAwake: true, interrupted: false),
                          key(keepAwake: true, interrupted: true),
                          "a broken keep-awake claim MUST invalidate the gate, or the cold cup never draws")
    }

    /// ...and it must change back when the next `enable()` resets the interruption count.
    func testRenderKeyChangesWhenTheClaimIsRenewed() {
        XCTAssertNotEqual(key(keepAwake: true, interrupted: true),
                          key(keepAwake: true, interrupted: false))
    }

    func testEveryOtherRenderInputStillKeys() {
        XCTAssertNotEqual(key(pct: 50), key(pct: 51))
        XCTAssertNotEqual(key(keepAwake: false), key(keepAwake: true))
        XCTAssertNotEqual(key(displayMode: .iconAndPercent), key(displayMode: .percentOnly))
        XCTAssertNotEqual(key(style: .nativeContinuous), key(style: .sfSymbols))
    }
}
