import XCTest
@testable import Battery

/// Feature #13: the glyph prefs store. The load-bearing guard is "unwritten keys → GlyphPrefs.defaults"
/// (existing users see NO change), plus a set→get round-trip that persists across instances and a corrupt
/// raw value falling back to the safe default.
@MainActor
final class GlyphPreferencesStoreTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "glyphprefs-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testUnwrittenKeysAreDefaults() {   // the "no change for existing users" guard
        let s = GlyphPreferencesStore(defaults: freshDefaults())
        XCTAssertEqual(s.displayMode, .iconAndPercent)
        XCTAssertEqual(s.style, .nativeContinuous)
        XCTAssertEqual(s.prefs, GlyphPrefs.defaults)
    }

    func testRoundTripPersistsAcrossInstances() {
        let d = freshDefaults()
        let s = GlyphPreferencesStore(defaults: d)
        s.displayMode = .percentOnly
        s.style = .sfSymbols
        let reloaded = GlyphPreferencesStore(defaults: d)   // a fresh store on the same suite
        XCTAssertEqual(reloaded.displayMode, .percentOnly)
        XCTAssertEqual(reloaded.style, .sfSymbols)
    }

    func testCorruptRawStringFallsBackToSafeDefault() {
        let d = freshDefaults()
        d.set("garbage-not-a-mode", forKey: "glyph.displayMode.v1")
        d.set("garbage-not-a-style", forKey: "glyph.style.v1")
        let s = GlyphPreferencesStore(defaults: d)
        XCTAssertEqual(s.displayMode, .iconAndPercent)
        XCTAssertEqual(s.style, .nativeContinuous)
    }
}
