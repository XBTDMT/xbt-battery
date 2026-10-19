import SwiftUI

/// #30 spec §4.1 · the vertical icon rail. Six 30 pt buttons, 6 pt apart, in a 44 pt column with a
/// hairline on its trailing edge; the selected tab is a `DSSurface.control` pill. Icon-only, so every
/// button carries the tab title as its accessibility label and help tag (spec §10).
struct PopoverRail: View {
    @Binding var selected: RailTab

    var body: some View {
        VStack(spacing: DSMetric.railButtonGap) {
            ForEach(RailTab.allCases, id: \.self) { tab in
                Button { selected = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DSSurface.text.opacity(tab == selected ? 1 : 0.55))
                        .frame(width: DSMetric.railWidth - 1, height: DSMetric.railButton)
                        .background(
                            RoundedRectangle(cornerRadius: DSMetric.radiusGroup, style: .continuous)
                                .fill(tab == selected ? AnyShapeStyle(DSSurface.control) : AnyShapeStyle(.clear))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == selected ? .isSelected : [])
                .help(tab.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DSMetric.space1)
        .frame(width: DSMetric.railWidth, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DSSurface.line).frame(width: 1)
        }
    }
}
