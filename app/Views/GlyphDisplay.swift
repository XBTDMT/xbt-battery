import Foundation

/// Feature #13 (menu-bar icon customization) — the PURE prefs model + display-decision layer.
/// Host-app-free; the store (GlyphPreferencesStore) and BatteryApp read these from the same module.
/// Two axes, both defaulting to CURRENT behavior (no change unless opted in).

enum GlyphDisplayMode: String, CaseIterable { case iconAndPercent, iconOnly, percentOnly }
enum GlyphStyle: String, CaseIterable { case nativeContinuous, sfSymbols }

struct GlyphPrefs: Equatable {
    var displayMode: GlyphDisplayMode = .iconAndPercent   // <- SINGLE SOURCE OF DEFAULTS
    var style: GlyphStyle = .nativeContinuous
    static let defaults = GlyphPrefs()
}

/// For %-only honesty: the title text carries the state color the (absent) glyph would have.
enum TitleTint: Equatable { case label, critical, lowPower }

struct MenuBarDisplayPlan: Equatable {
    let showImage: Bool
    let title: String?      // nil => clear the title
    let tint: TitleTint
}

/// The app's ONE "red = low battery" threshold: a battery at or below this percentage reads red — the
/// menu-bar glyph and its %-only title (both suppressed while charging), the Now ring, and the Now strip's
/// day's low (§16 "32 · Now · day's low", ruled D1B 2026-10-18). One constant so the surfaces cannot drift.
enum BatteryRedRule {
    static let threshold = 20
    /// `percent <= threshold`. Charging suppression is each caller's own rule, not this one's.
    static func isLow(_ percent: Int) -> Bool { percent <= threshold }
}

enum GlyphDisplay {
    /// PURE, total. `critical` mirrors the glyph's red rule EXACTLY: BatteryRedRule.isLow(soc) && !charging.
    /// Precedence for %-only tint: critical > lowPower > label (mirrors the glyph RED>YELLOW>TEMPLATE).
    static func menuBarDisplayPlan(pct: Int, isChargingDisplay: Bool, lowPower: Bool,
                                   mode: GlyphDisplayMode) -> MenuBarDisplayPlan {
        let critical = BatteryRedRule.isLow(pct) && !isChargingDisplay
        let tint: TitleTint = critical ? .critical : (lowPower ? .lowPower : .label)
        switch mode {
        case .iconAndPercent: return MenuBarDisplayPlan(showImage: true,  title: "\(pct)%", tint: .label)   // % beside glyph → glyph carries color; text stays label
        case .iconOnly:       return MenuBarDisplayPlan(showImage: true,  title: nil,        tint: .label)
        case .percentOnly:    return MenuBarDisplayPlan(showImage: false, title: "\(pct)%",  tint: tint)     // glyph gone → text carries the honest color
        }
    }

    /// #13 (self-audit): the SF-Symbols fidelity disclosure — nil for the native style. Kept here (pure)
    /// so the Settings footer AND a test read one source. SF renders a monochrome template, so it drops
    /// the hold + plugged-in + keep-awake marks AND both non-template colors (the low-battery red and the
    /// Low Power yellow). Apple ships no full-battery-with-plug symbol, so #21b has no SF equivalent.
    static func sfFidelityFooter(for style: GlyphStyle) -> String? {
        style == .sfSymbols
            ? "Apple's battery symbols use a 5-step fill and don't show the hold, plugged-in, or keep-awake marks, the low-battery red, or Low Power color."
            : nil
    }
}
