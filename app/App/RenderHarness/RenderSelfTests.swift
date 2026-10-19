import SwiftUI

/// Spec 31 §2.5 · the clip gate's self-test pages — harness only (the logic-only test target cannot host a
/// SwiftUI render, and no project.yml membership changes). Each is built to FAIL the gate in one known way,
/// through the same `DSPageFrame` the real pages use: a run that reports any of them as expected proves the
/// SwiftUI half of the gate can see overflow; a run that reports them `ok` proves the gate is blind.
enum SelfTestPage: String, CaseIterable {
    /// 520 pt of content in the fixed frame → CLIPPED.
    case fixed520 = "selftest-fixed-520"
    /// 520 pt of content in the max-height frame → CLIPPED.
    case max520 = "selftest-max-520"
    /// A paragraph squeezed under a 440 pt block: it fits 470 by truncating → TRUNCATED.
    case truncation = "selftest-truncation"

    /// The page column's width in the popover: 360 − 2 × 10 inset − 34 rail − 8 gap.
    static let pageWidth: CGFloat =
        DSMetric.popoverWidth - 2 * DSMetric.popoverInset - DSMetric.railWidth - DSMetric.railGap

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .fixed520:
            Self.block(520).dsPageFrame(.fixed, alignment: .top)
        case .max520:
            Self.block(520).dsPageFrame(.maxHeight, alignment: .center)
        case .truncation:
            VStack(alignment: .leading, spacing: 0) {
                Self.block(440)
                Text(String(repeating: "This sentence exists to be squeezed by the frame. ", count: 12))
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .dsPageFrame(.fixed, alignment: .top)
        }
    }

    @MainActor private static func block(_ height: CGFloat) -> some View {
        Rectangle().fill(Color.gray.opacity(0.4)).frame(maxWidth: .infinity).frame(height: height)
    }
}
