import XCTest
import AppKit

/// #30 R11 / §4.2 / §14-B12: the app-icon choice policy, driven through a dictionary-backed provider
/// (never `NSRunningApplication` — the live provider is a boundary adapter).
final class AppIconResolverTests: XCTestCase {

    final class DictProvider: AppIconProviding {
        var byPID: [Int: NSImage] = [:]
        var byBundle: [String: NSImage] = [:]
        private(set) var pidAsks: [Int] = []
        private(set) var bundleAsks: [String] = []
        func icon(forPID pid: Int) -> NSImage? { pidAsks.append(pid); return byPID[pid] }
        func icon(forBundleID bundleID: String) -> NSImage? { bundleAsks.append(bundleID); return byBundle[bundleID] }
    }

    private func img(_ w: CGFloat) -> NSImage { NSImage(size: NSSize(width: w, height: w)) }

    func testFallbackSymbols() {
        XCTAssertEqual(AppIconPolicy.fallbackSymbol(isDaemon: true), "gearshape")
        XCTAssertEqual(AppIconPolicy.fallbackSymbol(isDaemon: false), "app.dashed")
        for s in ["gearshape", "app.dashed"] {
            XCTAssertNotNil(NSImage(systemSymbolName: s, accessibilityDescription: nil), "\(s) must exist on this OS")
        }
    }

    func testPIDIconWins() {
        let p = DictProvider()
        p.byPID[42] = img(42); p.byBundle["com.x"] = img(7)
        let c = AppIconPolicy.choose(pid: 42, bundleID: "com.x", provider: p)
        XCTAssertTrue(c.isImage)
        if case .image(let i) = c { XCTAssertEqual(i.size.width, 42) }
        XCTAssertEqual(p.bundleAsks, [], "the bundle is not consulted when the pid resolved")
    }

    func testGUIPidWithoutIconFallsToBundleThenImage() {
        let p = DictProvider()
        p.byBundle["com.x"] = img(7)
        let c = AppIconPolicy.choose(pid: 42, bundleID: "com.x", provider: p)
        if case .image(let i) = c { XCTAssertEqual(i.size.width, 7) } else { XCTFail("expected the bundle icon") }
        XCTAssertEqual(p.pidAsks, [42]); XCTAssertEqual(p.bundleAsks, ["com.x"])
    }

    func testNonGUIPidIsADaemon() {
        let p = DictProvider()
        XCTAssertEqual(AppIconPolicy.choose(pid: 99, bundleID: nil, provider: p).symbolName, "gearshape")
        XCTAssertEqual(AppIconPolicy.choose(pid: 99, bundleID: "", provider: p).symbolName, "gearshape")
        XCTAssertEqual(AppIconPolicy.choose(pid: 99, bundleID: "com.nope", provider: p).symbolName, "gearshape",
                       "a pid that resolved to no GUI icon is a non-GUI process even when a bundle id was offered")
    }

    func testSustainedRowWithoutPidResolvesByBundle() {
        // §14-B12: Sustained rows carry no pid.
        let p = DictProvider()
        p.byBundle["com.apple.Safari"] = img(3)
        XCTAssertTrue(AppIconPolicy.choose(pid: nil, bundleID: "com.apple.Safari", provider: p).isImage)
        XCTAssertEqual(p.pidAsks, [])
    }

    func testNothingIdentifiableIsADashedApp() {
        let p = DictProvider()
        XCTAssertEqual(AppIconPolicy.choose(pid: nil, bundleID: nil, provider: p).symbolName, "app.dashed")
        XCTAssertEqual(AppIconPolicy.choose(pid: nil, bundleID: "com.gone", provider: p).symbolName, "app.dashed")
    }

    func testLiveProviderHonoursTheB12RuleForThisTestProcess() {
        // xctest itself: a bundle-less / prohibited-policy process must NOT yield an icon.
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let app = NSRunningApplication(processIdentifier: pid_t(me))
        let expectImage = (app?.bundleURL != nil) && (app?.activationPolicy != .prohibited)
        let got = RunningAppIconProvider().icon(forPID: me)
        XCTAssertEqual(got != nil, expectImage)
        XCTAssertNil(RunningAppIconProvider().icon(forPID: 1_000_000), "a pid that is not running → nil, never a generic icon")
    }
}
