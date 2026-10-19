import SwiftUI

/// Typography tokens — `29-phase1-foundation-tokens.md` §2.
///
/// System font everywhere (SF Pro); SF Pro Rounded for the hero numeral only; monospaced digits on
/// every live-updating number so values don't jitter as they tick. Text styles (Dynamic Type) for
/// everything except the fixed-size hero. Headers/labels are sentence case (§2 / D7).
enum DSType {
    /// the charge % — 40 pt rounded semibold, monospaced digits
    static let heroNumeral = Font.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit()
    /// the "%" beside the numeral — 20 pt rounded medium
    static let heroUnit = Font.system(size: 20, weight: .medium, design: .rounded)
    /// section labels — sentence case ("Charge limit", not "Charge Limit")
    static let sectionHeader = Font.subheadline.weight(.semibold)
    /// label:value rows
    static let rowLabel = Font.callout
    static let rowValue = Font.callout.monospacedDigit()
    /// control labels, descriptions
    static let body = Font.body
    /// footers, captions, read-back lines
    static let caption = Font.caption
    /// paths / commands (the Uninstall panel)
    static let mono = Font.system(.caption2, design: .monospaced)
}
