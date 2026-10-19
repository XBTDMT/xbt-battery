import SwiftUI
import AppKit

/// #29 D-6 (5b) — the About window content. The R5 addendum mockup (knowledge/29-phase2-mockup-about.html)
/// is the visual spec.
///
/// App-side SwiftUI (like BatteryPopoverView), hosted in the AppDelegate-managed About NSWindow. Text
/// uses semantic DSColor tokens (so the panel still reads in light appearance — the D11 audit item);
/// the icon is the fixed-mark app icon (the R5 ring identity) shown decoratively. Version + copyright
/// are read LIVE from the bundle via AboutStrings (never hard-coded). Content flows on the 4pt grid:
/// icon · 16 · name · 4 · version · 12 · tagline · 16 · copyright. VoiceOver reads name → version →
/// tagline → copyright in order (each its own element); the icon + the Cmd-W helper are AX-hidden.
struct AboutView: View {
    /// Closes the window (the traffic-light close and Cmd-W both route here). Injected by the opener.
    var onClose: () -> Void = {}

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: "AppIcon") ?? NSImage()
    }
    private var versionText: String {
        AboutStrings.versionLine(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
    private var copyrightText: String {
        AboutStrings.copyright(
            humanReadable: Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)                 // decorative (mockup: icon hidden from AX)
                .padding(.bottom, DSMetric.space4)          // 16

            Text("Battery")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DSColor.textPrimary)
                .padding(.bottom, DSMetric.space1)          // 4

            Text(versionText)
                .font(.system(size: 11).monospacedDigit())  // tabular numerals (mockup)
                .foregroundStyle(DSColor.textSecondary)
                .padding(.bottom, DSMetric.space3)          // 12

            Text(AboutStrings.tagline)
                .font(.system(size: 11))
                .foregroundStyle(DSColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, DSMetric.space4)          // 16

            Text(copyrightText)
                .font(.system(size: 10))
                .foregroundStyle(DSColor.textTertiary)
        }
        .padding(.top, DSMetric.space5)                     // content inset 20 (top)
        .padding(.horizontal, DSMetric.space6)              // 24
        .padding(.bottom, DSMetric.space6)                  // 24
        .frame(width: 300)                                  // fixed width; height hugs content
        .fixedSize(horizontal: false, vertical: true)
        // Cmd-W closes (accessory apps carry no menu to host the equivalent) — an invisible, AX-hidden
        // button holds the key equivalent and routes to the same close as the traffic light.
        .background(
            Button("", action: onClose)
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }
}
