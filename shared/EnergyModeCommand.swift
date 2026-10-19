import Foundation

// Sprint 3.7 STAGE 3 — the pure, host-app-free command core for the FIRST privileged action
// (setEnergyMode). Validation + FIXED arg-array construction + env sanitization + read-back parsing
// live here so they are exhaustively unit-testable. The actual Process SPAWN is helper-only (the
// privileged side); the app never builds or sends a command — it passes only two validated integers
// over XPC. Injection is structurally impossible: pmsetArguments takes the VALIDATED enums (not raw
// ints) and emits switch-mapped string LITERALS — no interpolation, no shell, no app value on a path.

/// Energy Mode value (R-15a confirmed mapping). Named `EnergyModeValue` to avoid colliding with the
/// app's display enum `BatterySnapshot.EnergyMode` (which also carries `.unavailable`); this is the
/// SET value only. Out-of-set raw ints fail `EnergyModeValue(rawValue:)` → rejected.
public enum EnergyModeValue: Int, CaseIterable, Sendable {
    case automatic = 0
    case low = 1
    case high = 2
}

/// Per-source target for `pmset` (-b battery / -c charger / -a all).
public enum EnergySource: Int, CaseIterable, Sendable {
    case battery = 0
    case charger = 1
    case all = 2
}

public enum EnergyModeCommand {

    /// The ONLY executable this op ever runs (absolute path literal — never resolved via PATH).
    public static let pmsetPath = "/usr/bin/pmset"

    /// The controlled working directory for the spawn (SPEC sec 3).
    public static let workingDirectory = "/var/tmp"

    // Reply token contract (shared by helper + app + tests). Success = the read-back value; failures
    // are these explicit tokens so the app surfaces honest states (never a silent no-op).
    public static let errInvalidMode    = "error:invalid-mode"
    public static let errInvalidSource  = "error:invalid-source"
    public static let errSetFailed      = "error:set-failed"
    public static let errReadbackFailed = "error:readback-failed"

    /// VALIDATE the raw integers to exactly {0,1,2}×{0,1,2}. Returns nil (REJECT) for anything else —
    /// this runs BEFORE any command is constructed. (Leverages the Int-raw-value enums: -1/3/99 → nil.)
    public static func validate(mode: Int, source: Int) -> (EnergyModeValue, EnergySource)? {
        guard let m = EnergyModeValue(rawValue: mode), let s = EnergySource(rawValue: source) else { return nil }
        return (m, s)
    }

    /// Build the FIXED argv for the SET, from already-VALIDATED enums. Every element is a literal: the
    /// absolute path, a switch-mapped source flag, the constant "powermode", and a switch-mapped digit.
    /// No string interpolation; no app-controlled value is ever appended to a path or a flag.
    public static func pmsetArguments(mode: EnergyModeValue, source: EnergySource) -> [String] {
        let sourceFlag: String
        switch source {
        case .battery: sourceFlag = "-b"
        case .charger: sourceFlag = "-c"
        case .all:     sourceFlag = "-a"
        }
        let modeDigit: String
        switch mode {
        case .automatic: modeDigit = "0"
        case .low:       modeDigit = "1"
        case .high:      modeDigit = "2"
        }
        return [pmsetPath, sourceFlag, "powermode", modeDigit]
    }

    /// The FIXED argv for the read-back (`pmset -g` shows the active power settings).
    public static func readbackArguments() -> [String] { [pmsetPath, "-g"] }

    /// The sanitized spawn environment (SPEC sec 3). This dictionary REPLACES the process environment
    /// wholesale, so any inherited DYLD_* / LD_LIBRARY_PATH / PATH from the parent is discarded (not
    /// merged). PATH is CLEARED (empty) — pmset is invoked by absolute path (`/usr/bin/pmset`), so PATH
    /// is never used to locate it, and pmset is a thin powerd client that execs no PATH-resolved
    /// sub-tools. HOME + TMPDIR point at controlled dirs.
    public static func sanitizedEnvironment() -> [String: String] {
        [
            "PATH": "",            // cleared — executable is always invoked by absolute path
            "HOME": "/var/empty",  // controlled, non-writable
            "TMPDIR": "/var/tmp",  // controlled
        ]
    }

    /// Parse the `powermode` value out of `pmset -g` output. Matches the line whose FIRST whitespace
    /// token is exactly "powermode" (a look-alike like "powermodexyz" must not match). Returns nil if
    /// absent. (Mirrors the Phase-1.8 EnergyModeReader's `^ *powermode` read.)
    public static func parsePowermode(fromPmsetG output: String) -> String? {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            if tokens.first == "powermode", tokens.count >= 2 {
                return String(tokens[1])
            }
        }
        return nil
    }
}
