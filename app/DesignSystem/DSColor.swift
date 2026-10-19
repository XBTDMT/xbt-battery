import SwiftUI

/// Semantic color tokens — `29-phase1-foundation-tokens.md` §1.
///
/// Hex is banned app-wide. Every value is a system `NSColor` bridged to SwiftUI, which buys dark
/// mode, Increase Contrast, and vibrancy-correctness for free. Rule: **never color alone** — each
/// status color is paired with an SF Symbol + text at the call site. `holding` is deliberately
/// neutral (secondary label, not orange): a limit hold is the app working *as configured*, not a
/// warning. Accent is the user's system accent [D2], never a brand color; green stays status-only.
enum DSColor {
    // status.* — always paired with an SF Symbol + text (§1: never color alone)
    static let charging  = Color(nsColor: .systemGreen)          // status.charging
    static let lowPower  = Color(nsColor: .systemYellow)         // status.lowPower
    static let critical  = Color(nsColor: .systemRed)            // status.critical
    static let holding   = Color(nsColor: .secondaryLabelColor)  // status.holding — calm/neutral
    static let attention = Color(nsColor: .systemOrange)         // status.attention
    static let healthy   = Color(nsColor: .systemGreen)          // status.healthy — good battery condition

    // text.* — label hierarchy
    static let textPrimary   = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary  = Color(nsColor: .tertiaryLabelColor)

    // accent.interactive — the user's system accent [D2]
    static let accent = Color(nsColor: .controlAccentColor)
    /// #30 R13 "blue = on power": a fixed system blue for the on-power role (strips, AC spans, heatmap
    /// cells, sleep→wake spans) so the rule holds under any accent color; `accent` stays for selection.
    static let onPower = Color(nsColor: .systemBlue)

    // hairline separators — used sparingly, only inside a card between rows (§4)
    static let separator = Color(nsColor: .separatorColor)
}

/// Grouped-inset / control fills — `29-phase1-foundation-tokens.md` §1 (SwiftUI hierarchical fills).
/// Kept as `ShapeStyle` (not `Color`) so they render as the system's semantic fills.
enum DSFill {
    /// grouped-inset card background (fill.group → SwiftUI `.quaternary`)
    static var group: some ShapeStyle { .quaternary }
    /// inline chips / wells (fill.control → `.quinary`, macOS 14+)
    static var control: some ShapeStyle { .quinary }
}

/// #30 R15 · the popover's OWN surfaces — the mockup's palette, verbatim (owner 2026-09-09: "our mockups look
/// great but this just doesn't look good"; the difference was the surface: NSPopover's translucent material
/// under `.quaternary` fills halved the contrast the mock has). The popover is a committed dark-only surface
/// like the mock (`--pop`, `--pop2`, `--pop3`, `--ptext2`, `--ptext3`); the Settings window and About keep
/// the semantic system colors above. Hex is otherwise banned app-wide (#29 tokens §1) — this is the one
/// sanctioned exception, and it is confined to the popover.
enum DSSurface {
    static let ground  = Color(red: 0x2a/255, green: 0x2c/255, blue: 0x31/255)          // --pop
    static let card    = Color(red: 0x35/255, green: 0x38/255, blue: 0x3e/255)          // --pop2
    static let control = Color(red: 0x42/255, green: 0x45/255, blue: 0x4c/255)          // --pop3
    static let text    = Color(red: 0xf2/255, green: 0xf2/255, blue: 0xf5/255)          // --ptext
    static let text2   = Color(red: 0xeb/255, green: 0xeb/255, blue: 0xf5/255).opacity(0.62)   // --ptext2
    static let text3   = Color(red: 0xeb/255, green: 0xeb/255, blue: 0xf5/255).opacity(0.34)   // --ptext3
    static let line    = Color(red: 0xeb/255, green: 0xeb/255, blue: 0xf5/255).opacity(0.14)   // --popline
}
