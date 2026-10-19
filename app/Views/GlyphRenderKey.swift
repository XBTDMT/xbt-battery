import Foundation

/// ENERGY (audit A2). Everything the menu-bar glyph actually draws from. `updateStatusButton` ran
/// unconditionally on every `$snapshot` publish (3–4 per tick) plus every `$telemetryState` publish,
/// allocating a fresh `NSAttributedString`, a fresh `NSImage` and a fresh a11y string each time —
/// ~5,760 rebuilds/day, of which well under 1% changed a single pixel. Because the status item is
/// `.variableLength`, every assignment also forces it to re-measure and pushes a Core Animation
/// commit into the menu bar, so the real cost was a WindowServer composite, not our CoreGraphics.
///
/// The gate compares THIS, not the snapshot: the snapshot carries voltage, amperage, temperature and
/// timestamps that move constantly and change nothing on screen. Every field below is an actual
/// argument to `GlyphDisplay.menuBarDisplayPlan` or `MenuBarBatteryIcon.image` — if a new one is ever
/// added there, it MUST be added here too, or the glyph will go stale (the ISSUE-8 bug class).
///
/// Lifted out of `AppDelegate` (where it was a private nested struct) so the "every render input is a
/// key field" invariant is assertable host-app-free — `BatteryApp.swift` carries `@main` and cannot
/// compile into the test target. Pure value type; the gate itself still lives in `updateStatusButton`.
struct GlyphRenderKey: Equatable {
    let pct: Int
    let chargingDisplay: Bool
    let holdMark: Bool
    let fullyCharged: Bool
    let onAC: Bool
    let lowPower: Bool
    let keepAwake: Bool
    /// #EI-1 HONESTY: `KeepAwakeController.isInterrupted` — the session is still held but the Mac
    /// slept through it, so the badge draws a COLD cup (no steam). It is a real `MenuBarBatteryIcon
    /// .image` argument, so it MUST be keyed: without it the gate would suppress the redraw that
    /// puts the honest glyph on screen, and the badge would go on steaming across the very event
    /// that falsified it — the ISSUE-8 staleness class, in the surface it was added to fix.
    let keepAwakeInterrupted: Bool
    let displayMode: GlyphDisplayMode
    let style: GlyphStyle
    /// #BOLT-TREND: both are real `MenuBarBatteryIcon.image` arguments, so both are keyed.
    var packRising: Bool = false
    var packDraining: Bool = false
}
