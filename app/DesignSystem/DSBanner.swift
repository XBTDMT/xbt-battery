import SwiftUI

/// #29 §4 / D5 `component.banner` — the single unified exception surface. A full-width tinted card:
/// a leading (hierarchical) SF Symbol + one sentence + at most one trailing action. Which exception
/// occupies the one slot is decided by `BannerArbiter` (BannerModel.swift); the winning exception
/// supplies its own `symbol` / `tint` / `message` here. The caller renders this only when a banner
/// is active — it is silent (absent) when healthy.
struct DSBanner: View {
    let symbol: String
    let message: String
    var tint: Color = DSColor.attention
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSMetric.space2) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            Text(message)
                .font(DSType.body)
                .foregroundStyle(DSColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Spacer(minLength: DSMetric.space2)
                Button(actionTitle, action: action)
                    .font(DSType.body)
            }
        }
        .padding(DSMetric.groupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSFill.group, in: RoundedRectangle(cornerRadius: DSMetric.radiusGroup, style: .continuous))
    }
}
