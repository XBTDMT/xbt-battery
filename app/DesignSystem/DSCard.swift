import SwiftUI

/// #29 §4 `component.card` — a grouped-inset section container (System-Settings style) that replaces
/// the `Divider()` stack. `fill.group` background, `radius.group` corners, `group.padding` inset;
/// hairline separators survive only *inside* a card between rows. An optional section header sits
/// above the card (sentence case). Not wired into a live view until Cut D-2.
struct DSCard<Content: View>: View {
    private let header: String?
    private let content: Content

    init(_ header: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetric.space2) {
            if let header {
                Text(header)
                    .font(DSType.sectionHeader)
                    .foregroundStyle(DSColor.textPrimary)
            }
            VStack(alignment: .leading, spacing: DSMetric.rowGap) {
                content
            }
            .padding(DSMetric.groupPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSFill.group, in: RoundedRectangle(cornerRadius: DSMetric.radiusGroup, style: .continuous))
        }
    }
}
