import SwiftUI

// #30 · time axes under the popover's day-shaped marks. Both are decorative: hidden from VoiceOver (the rows and
// the chart carry their own values).
//
// `DSHourAxis` — the Now tab's Today strip: one 14 pt band of faint 9 pt labels, 0:00 · 6:00 · 12:00 · 18:00 · 24:00,
// at 0, ¼, ½, ¾ and the full width; the end labels are pulled 12 pt inward so they never overhang the strip (the
// strip draws its own quarter ticks).
//
// `DSRuler` — the Day tab's chart and 7-day table (owner 2026-09-11, layout round
// `knowledge/30-day-layout-mockup.html`, frame C): a hairline base with a tick at every interval, taller ticks at
// the two ends, the end labels under the end ticks, an optional middle label, and "now" in semibold.

/// The quarter-day labels under a bar that spans one local day.
struct DSHourAxis: View {
    static let height: CGFloat = 14

    /// "0:00" · "6:00" · "12:00" · "18:00" · "24:00"
    static func label(_ hour: Int) -> String { "\(hour):00" }

    var body: some View {
        GeometryReader { g in
            ForEach(0..<5, id: \.self) { q in
                let x = g.size.width * CGFloat(q) / 4
                Text(Self.label(q * 6))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(DSSurface.text3)
                    .fixedSize()
                    .position(x: min(max(x, 12), g.size.width - 12), y: 8)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

/// Mock `.ruler`: 3 pt above; a 6 pt tick band (hairline base at y 5, inner ticks 4 pt tall, end ticks 6 pt);
/// 1 pt; then one line of 9 pt labels — `leading` under the first tick, `trailing` under the last, `center`
/// (if any) centred.
struct DSRuler: View {
    let leading: String
    var center: String? = nil
    let trailing: String
    /// "now" reads semibold in the secondary colour, like the reference's bold "now".
    var trailingEmphasis: Bool = false
    /// Equal intervals between ticks: 4 → a tick every quarter.
    var intervals: Int = 4

    var body: some View {
        VStack(spacing: 1) {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(x: 0, y: 5, width: size.width, height: 1)), with: .color(DSSurface.line))
                let n = max(1, intervals)
                for i in 0...n {
                    let end = i == 0 || i == n
                    let x = i == n ? size.width - 1 : (size.width * CGFloat(i) / CGFloat(n)).rounded(.down)
                    ctx.fill(Path(CGRect(x: x, y: end ? 0 : 1, width: 1, height: end ? 6 : 4)),
                             with: .color(DSSurface.text3))
                }
            }
            .frame(height: 6)
            ZStack {
                HStack(spacing: 0) {
                    Text(leading)
                    Spacer(minLength: 4)
                    Text(trailing)
                        .fontWeight(trailingEmphasis ? .semibold : .regular)
                        .foregroundStyle(trailingEmphasis ? DSSurface.text2 : DSSurface.text3)
                }
                if let center { Text(center) }
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(DSSurface.text3)
            .lineLimit(1)
        }
        .padding(.top, 3)
        .accessibilityHidden(true)
    }
}
