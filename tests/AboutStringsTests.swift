import XCTest
@testable import Battery

/// #29 D-6 (5b) — the About window's pure string table. The version/copyright are sourced LIVE from
/// the bundle at runtime; here we pin the wording + the assembly format (host-app-free, over injected
/// values — the same discipline as ChargeStatusStrings).
final class AboutStringsTests: XCTestCase {

    func testFixedCopyIsRegisterVoice() {
        XCTAssertEqual(AboutStrings.menuItem, "About Battery")
        // §4 voice: states a fact, present tense, no exclamation.
        XCTAssertEqual(AboutStrings.tagline, "Keeps your battery at the limit you choose.")
        XCTAssertFalse(AboutStrings.tagline.contains("!"))
    }

    func testVersionLineAssemblesShortAndBuild() {
        XCTAssertEqual(AboutStrings.versionLine(short: "1.0", build: "29"), "Version 1.0 (29)")
    }

    func testVersionLineOmitsEmptyOrMissingBuild() {
        XCTAssertEqual(AboutStrings.versionLine(short: "1.0", build: nil), "Version 1.0")
        XCTAssertEqual(AboutStrings.versionLine(short: "1.0", build: ""), "Version 1.0")
    }

    func testVersionLineFallsBackWhenShortMissing() {
        XCTAssertEqual(AboutStrings.versionLine(short: nil, build: "29"), "Version — (29)")
        XCTAssertEqual(AboutStrings.versionLine(short: "", build: nil), "Version —")
    }

    func testCopyrightPrefersBundleHumanReadable() {
        XCTAssertEqual(AboutStrings.copyright(humanReadable: "© 2026 XBTDMT"), "© 2026 XBTDMT")
    }

    func testCopyrightFallsBackWhenAbsent() {
        XCTAssertEqual(AboutStrings.copyright(humanReadable: nil), "© XBTDMT")
        XCTAssertEqual(AboutStrings.copyright(humanReadable: ""), "© XBTDMT")
    }
}
