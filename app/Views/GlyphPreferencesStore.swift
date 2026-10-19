import Foundation

/// Feature #13: UserDefaults-backed glyph (menu-bar icon) preferences. Mirrors NotificationPreferencesStore
/// EXACTLY: versioned dot-keys, an injected UserDefaults (testable host-app-free), an explicit per-key
/// fallback sourced from GlyphPrefs.defaults (the single source of truth — object(forKey:)==nil ? default
/// : decode, NOT register(defaults:)). Raw strings are stored and decoded with a safe default so a corrupt
/// value falls back rather than crashing.
@MainActor
final class GlyphPreferencesStore {

    private let defaults: UserDefaults

    private static let displayModeKey = "glyph.displayMode.v1"
    private static let styleKey = "glyph.style.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var displayMode: GlyphDisplayMode {
        get {
            defaults.object(forKey: Self.displayModeKey) == nil
                ? GlyphPrefs.defaults.displayMode
                : (GlyphDisplayMode(rawValue: defaults.string(forKey: Self.displayModeKey) ?? "") ?? .iconAndPercent)
        }
        set { defaults.set(newValue.rawValue, forKey: Self.displayModeKey) }
    }

    var style: GlyphStyle {
        get {
            defaults.object(forKey: Self.styleKey) == nil
                ? GlyphPrefs.defaults.style
                : (GlyphStyle(rawValue: defaults.string(forKey: Self.styleKey) ?? "") ?? .nativeContinuous)
        }
        set { defaults.set(newValue.rawValue, forKey: Self.styleKey) }
    }

    /// The full snapshot the display-decision layer + BatteryApp consume.
    var prefs: GlyphPrefs { GlyphPrefs(displayMode: displayMode, style: style) }
}
