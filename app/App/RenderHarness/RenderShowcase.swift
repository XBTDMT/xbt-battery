import AppKit
import SwiftUI

/// Public-release images. `Battery --render-showcase <dir>` renders, offscreen and with the app's OWN views and
/// drawing code (nothing re-implemented), the pictures `public/images/` is built from:
///   • `tab-<tab>.png` — each rail tab inside the full popover at 2×, through the very `RenderHarness.pass` the
///     clip gate uses (same window, same 1.4 s settle, same `#2a2c31` ground). Now / Day / Energy / Health /
///     Automation / `tab-devices-wireless` use the `.showcase` fixture (the parity state with the verified
///     read-back, so no degraded-mode banner); `tab-devices` uses `.showcasePowered` (that state with the gated
///     on-battery devices on cables, its cost line agreeing with Now) and `tab-devices-on-power` the gated
///     `powered-on-power` fixture ("Powered by this Mac").
///   • `hud-device-notice.png` — the plug-in notice pill (`HUDPillView`) on a transparent ground.
///   • `glyph-<state>-<light|dark>.png` — the menu-bar item at 8×: `MenuBarBatteryIcon.image` and the title
///     exactly as `AppDelegate.updateStatusButton` sets them, laid out by an AppKit `NSButton` with the status
///     button's `.imageTrailing`, on a plain menu-bar-coloured strip in the light and the dark appearance.
/// NOT part of the clip gate: no `variants` entry, no `PageGate.expected` row, exit 0 / 2 (harness error, or
/// `--render-pages` on the same command line) only.
/// Unreachable without the argument — every normal launch returns `false` on the first line.
@MainActor
enum RenderShowcase {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-showcase"), i + 1 < args.count else { return false }
        // The two modes never share a run: a combined command line would skip the clip gate and still exit 0.
        if args.contains("--render-pages") {
            FileHandle.standardError.write(Data("--render-showcase and --render-pages are separate runs; pass one\n".utf8))
            exit(PageGate.harnessErrorExit)
        }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for p in try render(into: dir) { print(p) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render showcase failed: \(error)\n".utf8))
            exit(PageGate.harnessErrorExit)
        }
    }

    static func render(into dir: URL) throws -> [String] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DSMetric.popoverWidth, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        var paths: [String] = []
        let pages: [(fixture: RenderFixture, tab: RailTab, name: String)] = [
            (.showcase, .now, "tab-now"), (.showcase, .day, "tab-day"), (.showcase, .energy, "tab-energy"),
            (.showcase, .health, "tab-health"), (.showcase, .devices, "tab-devices-wireless"),
            (.showcase, .automation, "tab-automation"),
            // On battery, like the Now page, and from the showcase's own reading so the cost line agrees with Now;
            // the on-power page is kept as its own file.
            (.showcasePowered, .devices, "tab-devices"),
            (.poweredOnPower, .devices, "tab-devices-on-power"),
        ]
        for fixture in [RenderFixture.showcase, .showcasePowered, .poweredOnPower] {
            let historyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "battery-render-showcase-\(ProcessInfo.processInfo.processIdentifier)-\(fixture.rawValue)",
                isDirectory: true)
            defer { try? FileManager.default.removeItem(at: historyRoot) }
            let graph = try RenderHarness.awaitGraph(historyRoot: historyRoot, fixture: fixture)
            for page in pages where page.fixture == fixture {
                let png = dir.appendingPathComponent("\(page.name).png")
                let v = RenderHarness.RenderVariant(page: .tab(page.tab), fixture: fixture)
                _ = try RenderHarness.pass(v, graph: graph, channel: .inside, window: window, png: png)
                paths.append(png.path)
            }
        }

        let hud = dir.appendingPathComponent("hud-device-notice.png")
        try RenderHarness.snapshotDeviceNotice(to: hud, fill: false)
        paths.append(hud.path)

        for state in GlyphState.all {
            for dark in [false, true] {
                let png = dir.appendingPathComponent("glyph-\(state.name)-\(dark ? "dark" : "light").png")
                try snapshotMenuBarItem(state, dark: dark, to: png)
                paths.append(png.path)
            }
        }
        return paths
    }

    // MARK: - the menu-bar item

    /// One menu-bar state: the inputs `updateStatusButton` passes to `MenuBarBatteryIcon.image`.
    struct GlyphState {
        let name: String
        let pct: Int
        var chargingDisplay = false
        var holdMark = false
        var fullyCharged = false
        var onAC = false
        var lowPower = false
        var keepAwake = false
        var packDraining = false

        static let all: [GlyphState] = [
            GlyphState(name: "on-battery", pct: 72),
            GlyphState(name: "charging", pct: 64, chargingDisplay: true, onAC: true),
            GlyphState(name: "charged", pct: 100, fullyCharged: true, onAC: true),
            GlyphState(name: "limit-hold", pct: 80, holdMark: true, onAC: true),
            GlyphState(name: "plugged-but-losing", pct: 41, onAC: true, packDraining: true),
            GlyphState(name: "keep-awake", pct: 72, keepAwake: true),
            GlyphState(name: "low", pct: 14),
            GlyphState(name: "low-power-mode", pct: 55, lowPower: true),
        ]
    }

    /// A plain strip in a menu bar's colour; it paints its own ground so `cacheDisplay` captures it.
    final class MenuBarStrip: NSView {
        let ground: NSColor
        init(frame: NSRect, ground: NSColor) { self.ground = ground; super.init(frame: frame) }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) { ground.setFill(); bounds.fill() }
    }

    static let glyphScale: CGFloat = 8
    static let menuBarHeight: CGFloat = 24

    static func snapshotMenuBarItem(_ s: GlyphState, dark: Bool, to url: URL) throws {
        let plan = GlyphDisplay.menuBarDisplayPlan(pct: s.pct, isChargingDisplay: s.chargingDisplay,
                                                   lowPower: s.lowPower, mode: .iconAndPercent)
        let image = MenuBarBatteryIcon.image(soc: s.pct, isChargingDisplay: s.chargingDisplay, holdMark: s.holdMark,
                                             fullyCharged: s.fullyCharged, onAC: s.onAC, lowPower: s.lowPower,
                                             keepAwake: s.keepAwake, keepAwakeInterrupted: false,
                                             style: .nativeContinuous, packRising: false,
                                             packDraining: s.packDraining, steamPhase: 0)
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageTrailing   // as `setUpStatusItem`: the % to the LEFT of the glyph
        button.attributedTitle = NSAttributedString(string: plan.title ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
        button.image = image
        // Off screen the window is never key, and a plain NSButton then draws a template image in its dimmed
        // inactive tint; the status bar draws it in the bar's primary ink, like the title — so tint it with the
        // title's own colour. Non-template states (red / yellow / green / the orange bolt) ignore the tint.
        button.contentTintColor = .labelColor
        button.imageHugsTitle = true   // the status button's tight title-to-glyph gap
        button.sizeToFit()

        let pad: CGFloat = 10
        let ground = dark ? NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x20 / 255, alpha: 1)
                          : NSColor(srgbRed: 0xec / 255, green: 0xec / 255, blue: 0xee / 255, alpha: 1)
        let strip = MenuBarStrip(frame: NSRect(x: 0, y: 0, width: ceil(button.frame.width) + 2 * pad,
                                               height: menuBarHeight), ground: ground)
        strip.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        button.frame.origin = NSPoint(x: pad, y: ((menuBarHeight - button.frame.height) / 2).rounded())
        strip.addSubview(button)

        let window = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = strip.appearance
        window.isReleasedWhenClosed = false
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        RenderHarness.pump(seconds: 0.05)
        try RenderHarness.snapshot(strip, to: url, fill: false, scale: glyphScale)
        window.contentView = nil
    }
}
