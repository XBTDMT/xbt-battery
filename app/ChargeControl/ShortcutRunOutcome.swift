import Foundation

/// Classified result of one `shortcuts run` invocation (SPEC v4.0 sec 2 ShortcutsRunner + sec 6
/// taxonomy). The runner classifies; the engine maps these onto published command status.
enum ShortcutRunOutcome: Equatable, Sendable {

    /// Exit 0. `stdout` is whatever the process printed (usually empty for Sets; LimitReader
    /// reads its value via `-o <tempfile>`, not stdout).
    case success(stdout: String)

    /// VERIFIED fingerprint (sec 2): stderr `Couldn't find shortcut` — classified EAGERLY off the
    /// live pipe (the process then hangs and never exits). Maps to `.setupRequired`.
    case missingShortcut

    /// The collapsed taxon (Grok B3): explicit TCC Deny, silent TCC block, mid-session revoke,
    /// and a waiting first-run prompt are all the same observable — empty-stderr hang → 15 s
    /// timeout. Indistinguishable with current fingerprints; the user string names BOTH
    /// hypotheses and both recovery routes.
    case automationBlocked(stderrTail: String)

    /// `/usr/bin/shortcuts` does not exist (sec 6 "`shortcuts` binary absent").
    case shortcutsBinaryAbsent

    /// Nonzero exit with no known fingerprint (sec 6 "nonzero exit").
    case failed(exitCode: Int32, stderrTail: String)

    /// `Process.run()` threw — spawn-level failure, surfaced via `.error(cause)` (S-N4).
    case launchFailed(message: String)
}

/// Stderr fingerprints with verified classifications (SPEC sec 2). Kept in one place so future
/// fingerprint captures (sec 8g explicit-Deny) extend a single table, not scattered string checks.
enum ShortcutStderrFingerprint {
    /// VERIFIED on-device 2026-06-09: missing shortcut prints this then HANGS without exiting.
    static let missingShortcut = "Couldn't find shortcut"

    /// Returns the eager classification for a stderr line, or nil if the line is not a known
    /// fingerprint. (The 8g Deny fingerprint is uncaptured — when/if captured it gets a row here.)
    static func classify(line: String) -> ShortcutRunOutcome? {
        if line.contains(missingShortcut) { return .missingShortcut }
        return nil
    }
}
