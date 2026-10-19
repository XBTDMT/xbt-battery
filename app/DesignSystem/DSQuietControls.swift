import SwiftUI

// #30 R10 · the quiet controls (spec §3, §14-B3). The native segmented picker at `.small` is 198 pt
// for five items — wider than its 173 pt slot — and on macOS 26/27 renders as a Liquid Glass capsule,
// so the popover draws its own strip: a `fill.control` well, radius 6, 11 pt labels, the selected
// segment lifted with a slightly stronger fill. Pause / Top up / Add rule are text actions in the
// accent, never filled blocks. Every control here is a real `Button`, so keyboard focus and VoiceOver
// come for free (spec §10).

/// The 20 pt segmented strip. `pairs` are (value, label) in display order.
struct DSStrip<T: Hashable>: View {
    @Binding var selection: T
    let pairs: [(T, String)]
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                let on = pair.0 == selection
                Button { selection = pair.0 } label: {
                    Text(pair.1)
                        .font(.system(size: 11, weight: on ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(on ? DSSurface.text : DSSurface.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(on ? AnyShapeStyle(Color(red: 0xeb/255, green: 0xeb/255, blue: 0xf5/255).opacity(0.22)) : AnyShapeStyle(.clear))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(red: 0xeb/255, green: 0xeb/255, blue: 0xf5/255).opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(!isEnabled)
    }
}

/// A text action in the accent (11.5 pt). `dim` renders it secondary for a de-emphasized action.
struct DSTextAction: View {
    let title: String
    var dim = false
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(role == .destructive ? DSColor.critical : (dim ? DSSurface.text2 : DSColor.accent))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The page header band: 14 pt semibold title on the left, an optional trailing view on the right.
struct DSPageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DSSurface.text)
            Spacer(minLength: DSMetric.space2)
            trailing
        }
        .padding(.top, 2)
        .padding(.bottom, DSMetric.space2)
    }
}

/// A 12 pt label · value row for the #30 pages (tighter than `DSRow`, tabular digits on the value).
struct DSKV: View {
    let key: String
    let value: Text
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 12)).foregroundStyle(DSSurface.text2)
            Spacer(minLength: DSMetric.space2)
            value.font(.system(size: 12).monospacedDigit()).foregroundStyle(DSSurface.text)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }
}

/// The 12 pt section label used inside pages ("Who spent it", "Power now"), with an optional faint caption.
struct DSSectionLabel: View {
    let title: String
    var caption: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DSSurface.text)
            if let caption {
                Text("· \(caption)").font(.system(size: 12)).foregroundStyle(DSSurface.text3)
            }
        }
    }
}

/// The mock's `.kv` block: a left-aligned key · value grid (key column auto-width, medium weight,
/// secondary; value primary, left-aligned beside it; 12.5 pt; 4 pt row gap, 12 pt column gap). Used by
/// Energy (Power now · Keeping the Mac awake) and Devices (Power adapter · Sleep timers).
struct DSKVGrid: View {
    struct Row: Identifiable {
        let id = UUID()
        let key: String
        let value: Text
        var trailing: AnyView? = nil
    }
    let rows: [Row]
    /// Vertical gap between rows. 4 is the original rhythm; the distributed 470 pt pages use the mock's
    /// `.kv` gap of 7 (#30, owner ruling 2026-09-09 evening).
    var rowSpacing: CGFloat = 4

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: rowSpacing) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.key).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DSSurface.text2)
                        .gridColumnAlignment(.leading)
                    HStack(spacing: 6) {
                        row.value.font(.system(size: 12.5).monospacedDigit()).foregroundStyle(DSSurface.text)
                            .lineLimit(1).truncationMode(.tail)
                        if let t = row.trailing { t }
                    }
                    .gridColumnAlignment(.leading)
                }
            }
        }
    }
}
