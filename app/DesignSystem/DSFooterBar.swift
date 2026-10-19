import SwiftUI

/// #29 §4 `component.footerBar` — the pinned popover footer: gear (Settings — the owed opener) and
/// Quit. Icon buttons, `text.secondary`, sitting outside the scroll. Actions are injected by the host
/// (the gear routes through `SettingsRouter.open(to:)`).
/// #30 §2: the history button is gone — history is the rail's Day tab.
struct DSFooterBar: View {
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        HStack(spacing: DSMetric.space4) {
            footerButton("gearshape", label: "Settings", action: onSettings)
            Spacer()
            footerButton("power", label: "Quit", action: onQuit)
        }
        .font(.system(size: 12))
        .foregroundStyle(DSSurface.text2)
        .padding(.horizontal, DSMetric.popoverInset)
        // Owner pick D (2026-10-15, `knowledge/30-footer-icon-options.html`): each glyph's ink sits as far from
        // the popover's bottom edge as from its side edge (11 pt measured on the render); the footer grows 8 pt.
        .padding(.top, 10).padding(.bottom, 10)
    }

    private func footerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .accessibilityLabel(label)
        }
        .buttonStyle(.plain)
    }
}
