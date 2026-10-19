import Foundation

/// Canonical shortcut names (SPEC v4.0 sec 3, exact strings). Per-value no-input shortcuts run
/// silently post-grant; a parameterized shortcut would prompt under CLI (research-07).
enum ChargeShortcuts {
    /// C2 forwarder-now: derived from `ChargeLimitStep` (the single source of truth for the settable
    /// steps) so the list and the step type can never drift. Same values, byte-identical to the prior
    /// literal — SetupFlow/ChargeSchedule/QuickActions/popover call sites are untouched.
    static let validLimitValues = ChargeLimitStep.allCases.map(\.rawValue)
    static let get = "Battery Limit Get"
    static func setName(for value: Int) -> String { "Battery Limit \(value)" }
    /// Everything SetupFlow must find installed.
    static var allRequiredNames: [String] {
        validLimitValues.map(setName(for:)) + [get]
    }
}

/// Seam over the ShortcutsRunner so reader/engine logic is testable with scripted outcomes
/// (the live runner spawns real processes). ShortcutsRunner conforms.
protocol ShortcutRunning: Sendable {
    func run(name: String, outputPath: String?) async -> ShortcutRunOutcome
    func list() async -> ShortcutRunOutcome
}

extension ShortcutsRunner: ShortcutRunning {}

/// Result of one Get read. `.unavailable` makes limit-unknown a FIRST-CLASS state (sec 2) —
/// the reason routes the right taxon (sec 6) without blocking anything.
enum LimitReadResult: Equatable, Sendable {
    case value(Int)
    case unavailable(LimitReadProblem)
}

enum LimitReadProblem: Equatable, Sendable {
    case missingShortcut          // → .setupRequired surface
    case automationBlocked        // → the collapsed taxon
    /// Output produced, but no extractable in-range integer — "Apple may have changed the
    /// action's output format" (sec 6), NOT a generic parse error.
    case outputUnparseable
    case runnerFailure
}

/// Defensive Get-output parse (Grok SF3): scan integer tokens, take the FIRST one inside
/// 80…100; tolerate wrapping text/formatting changes across OS releases. Only an output with
/// NO extractable in-range integer fails.
enum LimitOutputParser {
    static func parse(_ output: String) -> Int? {
        var current = ""
        var found: [Int] = []
        for ch in output {
            if ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                if let n = Int(current) { found.append(n) }
                current = ""
            }
        }
        if !current.isEmpty, let n = Int(current) { found.append(n) }
        return found.first { (80...100).contains($0) }
    }
}

/// WI-N5: LimitReader — `shortcuts run "Battery Limit Get" -o <tempfile>` → parsed limit.
/// VERIFIED end-to-end on 27.0 (plain integer, exit 0, <2 s, sec 2). PRIMARY as designed;
/// a missing/broken Get degrades to `.unavailable` and must never block Sets.
struct LimitReader: LimitReading {

    let runner: any ShortcutRunning

    func read() async -> LimitReadResult {
        let path = NSTemporaryDirectory() + "battery-limit-get-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let outcome = await runner.run(name: ChargeShortcuts.get, outputPath: path)
        switch outcome {
        case .success(let stdout):
            // `-o` writes the file; stdout is the defensive fallback channel.
            let fileText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let text = fileText.isEmpty ? stdout : fileText
            if let value = LimitOutputParser.parse(text) { return .value(value) }
            return .unavailable(.outputUnparseable)
        case .missingShortcut:
            return .unavailable(.missingShortcut)
        case .automationBlocked:
            return .unavailable(.automationBlocked)
        case .shortcutsBinaryAbsent, .failed, .launchFailed:
            return .unavailable(.runnerFailure)
        }
    }

    /// BehaviorConfirm's seam (mid-window/at-resolution checks).
    func readLimit() async -> ChargeLimitValue {
        switch await read() {
        case .value(let v):    return .known(v)
        case .unavailable:     return .unknown
        }
    }
}
