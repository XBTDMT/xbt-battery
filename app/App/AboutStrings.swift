import Foundation

/// #29 D-6 (5b) — the About window's user-strings + display formatters.
///
/// §4 voice: sentence case, states a fact, present tense, no jargon, no exclamation points. Copy is
/// draft-register (trued against the shipped bundle at build time) and lives in a table, never inline
/// in the view (the ChargeStatusStrings sibling rule). The version + copyright are sourced LIVE from
/// the bundle — this table owns only the fixed marketing copy and the pure assembly format, so the
/// formatters are host-app-free testable (they take injected bundle values, not Bundle.main).
enum AboutStrings {

    /// The quick-actions menu item that opens the About window.
    static let menuItem = "About Battery"

    /// One-line tagline under the version (§4 voice: states a fact, present tense).
    static let tagline = "Keeps your battery at the limit you choose."

    /// "Version <short> (<build>)" — assembled from CFBundleShortVersionString + CFBundleVersion,
    /// never hard-coded (mockup renders it in tabular numerals). Pure over injected values so the
    /// wording is host-app-free testable; the view passes Bundle.main's live values.
    static func versionLine(short: String?, build: String?) -> String {
        let shortText = (short?.isEmpty == false) ? short! : "—"
        if let build, !build.isEmpty { return "Version \(shortText) (\(build))" }
        return "Version \(shortText)"
    }

    /// The copyright line — assembled from the bundle's `NSHumanReadableCopyright` when present
    /// (mockup: "© 2026 XBTDMT"); a bare fallback keeps the line honest if the key is absent.
    static func copyright(humanReadable: String?) -> String {
        if let humanReadable, !humanReadable.isEmpty { return humanReadable }
        return "© XBTDMT"
    }
}
