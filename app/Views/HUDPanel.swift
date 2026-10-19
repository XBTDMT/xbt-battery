import AppKit
import SwiftUI

/// #29 D-5 (D10 / D11): the transient HUD pill — a non-activating `.nonactivatingPanel` hosting a SwiftUI
/// pill (leading SF symbol + one line, DS tokens), anchored beneath the status item. Fades in with a
/// 4 pt downward settle (`.smooth`-equivalent 0.2 s), auto-dismisses after the event's duration with a plain
/// fade; Reduce Motion → fades only, no movement. No controls, ignores mouse, never steals focus. VoiceOver
/// receives the text as an announcement; the menu-bar glyph updates regardless (never the sole channel).
/// 31 §2.2 (T4): the device notice uses a two-line variant for 4 s (title = the name alone, subline = "Drawing …"); the four #29 events are unchanged.
@MainActor
final class HUDPanel {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var showGeneration = 0

    /// Show the pill for `event`. `anchorTopLeft(size)` returns the panel's top-left point in GLOBAL
    /// screen coordinates (the caller composes StatusItemAnchor with the live button frame + screen).
    func show(event: HUDEvent, anchorTopLeft: (CGSize) -> CGPoint, reduceMotion: Bool) {
        let hosting = NSHostingView(rootView: HUDPillView(event: event))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Host FIRST, then measure: fittingSize on a not-yet-hosted NSHostingView is a pre-layout width
        // that skews the anchor. In the panel's window it reports the pill's true measured size.
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(anchorTopLeft(size))

        // D11: fade in + a 4 pt downward settle; Reduce Motion → fade only (no movement).
        panel.alphaValue = 0
        let settled = panel.frame.origin
        if !reduceMotion { panel.setFrameOrigin(NSPoint(x: settled.x, y: settled.y + 4)) }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrameOrigin(settled) }
        }

        // Never the sole channel: VoiceOver hears the same words (both lines for the device notice).
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: HUDStrings.announcement(for: event),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])

        // Auto-dismiss after the event's duration. A generation token guards against a stale dismiss — or its
        // fade-out completion — hiding a pill that a rapid re-show has already replaced.
        showGeneration &+= 1
        let generation = showGeneration
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(generation: generation) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HUDStrings.duration(for: event), execute: work)
    }

    private func dismiss(generation: Int) {
        guard generation == showGeneration, let panel else { return }   // a newer show superseded this dismiss
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, generation == self.showGeneration else { return }   // a re-show landed mid-fade
                panel?.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true                                   // D10: no controls, no clicks
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }
}

/// The pill, in DS tokens. One line for the #29 events (unchanged: 14 pt glyph, body text, 14 × 9 padding);
/// two lines for the 31 device notice (mock 6): 26 pt glyph, 13 pt semibold title that truncates on ONE line,
/// 11.5 pt subline, 14 × 12 padding, at most `twoLineMaxWidth` wide. Internal so the render harness can
/// snapshot it.
struct HUDPillView: View {
    static let twoLineMaxWidth: CGFloat = 320

    let symbol: String
    let message: String
    let subline: String?
    let glyphTint: Color

    init(event: HUDEvent) {
        symbol = HUDStrings.symbol(for: event)
        message = HUDStrings.message(for: event)
        subline = HUDStrings.subline(for: event)
        glyphTint = HUDStrings.isChargeGlyph(for: event) ? DSColor.charging : DSColor.textSecondary
    }

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .fixedSize()
            // The pill is decorative confirmation; VoiceOver hears the announcement (posted by the panel).
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if let subline {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(glyphTint)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                    Text(subline)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: Self.twoLineMaxWidth, alignment: .leading)
        } else {
            HStack(spacing: DSMetric.space2) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(glyphTint)
                Text(message)
                    .font(DSType.body)
                    .foregroundStyle(DSColor.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}
