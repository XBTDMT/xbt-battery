import Foundation

/// Seam over the Energy Mode read (mirrors `PowerSourceReading`/`RepeatingScheduling`): production
/// spawns `pmset`, tests inject a fake. This lets BatteryMonitor's LPM-tint behavior — which already
/// regressed once as "sticky yellow" — be pinned by DETERMINISTIC tests, not only a visual check.
protocol EnergyModeReading {
    func readEnergyMode() -> EnergyMode
}

/// Production reader — wraps the existing `pmset`-spawning `EnergyModeReader.read()` (no behavior change).
struct LiveEnergyModeReader: EnergyModeReading {
    func readEnergyMode() -> EnergyMode { EnergyModeReader.read() }
}

/// Read-only Energy Mode display via `pmset -g` (decision #9; Sprint 0.4 / R-13). DISPLAY ONLY —
/// no `pmset` write / Energy-Mode control here (that is Phase 3.7). The CALLER runs `read()` on a
/// background queue (SPEC WI-1.3 `refreshEnergyMode()`); this never touches the main thread itself.
enum EnergyModeReader {

    /// Synchronously spawn `pmset -g`, capture stdout, and parse the `powermode` integer
    /// (0 → automatic, 1 → low, 2 → high). Any failure / missing key → `.unavailable` (never crash).
    ///
    /// AUDIT B6: the spawn is `PmsetProbe.run` — bounded (timeout → SIGTERM → SIGKILL) with BOTH pipes
    /// drained, replacing the hand-rolled `Process` whose unread `standardError` could wedge the child
    /// and, through it, this reader's in-flight flag forever. The success predicate is now the shared
    /// `succeeded` (a real child, exit 0, in time): the old guard checked only UTF-8 decodability, so a
    /// KILLED child's PARTIAL stdout would have been parsed as if it were a complete reading.
    /// RECOVERY — **deliberately none, at both reads in this file**, and this is the decision recorded
    /// at the site so a future reader does not "helpfully" add one.
    ///
    /// These are the two HIGHEST-FREQUENCY spawns in the app. `read()` rides the 60 s poll and every
    /// popover open; `readCustom()` rides the same poll plus the A13 notification path, which measured
    /// 72.4 fires/hr each running THREE samples — together ~8,100 `pmset` spawns/day (audit
    /// `knowledge/11-MEASURE-a5-a9-a13.md` §4.5). A retry here is the retry storm: it would add up to
    /// ~8,100 more on a machine whose whole energy arc was spent deleting spawns.
    ///
    /// And it would buy nothing, because the recovery ALREADY EXISTS and is free — a deferred re-read
    /// the app was going to do anyway, at most 60 s away. What a failed read costs in that window is
    /// bounded and known:
    ///   * the glyph's Low-Power tint drops for up to one poll (cosmetic, self-correcting);
    ///   * `AutoEnergyMode` guards `activeLive != .unavailable` and simply SKIPS the evaluation — a
    ///     transient unavailable is a no-op there, not a wrong decision.
    ///
    /// There is also a hard structural bar: both callers sit behind `BoundedReadGate`, whose
    /// `staleAfterSeconds` (10) is BELOW `.onceIfCutShort`'s 17 s worst case. A gated caller would
    /// reclaim its own read mid-retry and spawn a third child — the pile-up the gate exists to prevent.
    /// `PmsetProbeRetryTests` pins that arithmetic.
    static let retryPolicy: PmsetProbe.RetryPolicy = .none

    static func read() -> EnergyMode {
        let outcome = PmsetProbe.run(["-g"], retry: retryPolicy)
        guard outcome.succeeded, let output = outcome.stdout else { return .unavailable }
        return parsePowermode(output)
    }

    // MARK: - A1: per-source read-back (pmset -g custom)

    /// Both profiles' Energy Mode, keyed by profile header — NOT by the active source. `pmset -g`
    /// (the active read used for the glyph/LPM tint) reflects only the current source, so an AC-profile
    /// set looked inert in the picker while on battery. The picker reads THIS instead.
    struct PerSourceEnergyMode: Equatable {
        let battery: EnergyMode
        let charger: EnergyMode
        static let unavailable = PerSourceEnergyMode(battery: .unavailable, charger: .unavailable)
    }

    /// Spawn `pmset -g custom` (prints BOTH profiles), parse per-profile. Any failure → `.unavailable`
    /// for the affected profile (never crash). Caller runs this off the main thread (it blocks on the
    /// child). Mirrors `read()`; the active `read()`/glyph path is unchanged.
    /// AUDIT B6: bounded + fully drained via `PmsetProbe.run` (see `read()`), and gated on the shared
    /// `succeeded` predicate so a killed child's partial output is never parsed per-profile.
    static func readCustom() -> PerSourceEnergyMode {
        // `retryPolicy` is `.none` — see the reasoning on `read()`. This is the spawn the A13
        // notification path fires three times per notification; it is the last one in the app that
        // may ever grow a retry.
        let outcome = PmsetProbe.run(["-g", "custom"], retry: retryPolicy)
        guard outcome.succeeded, let output = outcome.stdout else { return .unavailable }
        return parseCustomPerSource(output)
    }

    /// Pure parse of `pmset -g custom`: walk lines, track the current profile section header
    /// ("Battery Power:" / "AC Power:"), and read the `powermode` integer under each into that profile.
    /// First `powermode` per profile wins; a profile with no/garbled/out-of-range value stays
    /// `.unavailable` (never borrows the other profile's value).
    static func parseCustomPerSource(_ output: String) -> PerSourceEnergyMode {
        enum Profile { case none, battery, charger }
        var current: Profile = .none
        var battery: EnergyMode?
        var charger: EnergyMode?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Battery Power") { current = .battery; continue }
            if line.hasPrefix("AC Power")      { current = .charger; continue }
            guard line.hasPrefix("powermode") else { continue }   // not "lowpowermode", not other keys
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let last = tokens.last, let value = Int(last) else { continue }
            let mode = self.mode(fromValue: value)
            switch current {
            case .battery: if battery == nil { battery = mode }
            case .charger: if charger == nil { charger = mode }
            case .none:    break   // a powermode before any header → ignore
            }
        }
        return PerSourceEnergyMode(battery: battery ?? .unavailable, charger: charger ?? .unavailable)
    }

    /// Single source of truth for the powermode integer → display mode mapping (shared by the active
    /// `parsePowermode` and the per-source `parseCustomPerSource`). Out-of-range → `.unavailable`.
    private static func mode(fromValue value: Int) -> EnergyMode {
        switch value {
        case 0:  return .automatic
        case 1:  return .low
        case 2:  return .high
        default: return .unavailable
        }
    }

    /// Defensive parse: find the `powermode` line, read the trailing integer; else `.unavailable`.
    /// (On this M4 Max / Tahoe, `pmset -g` reports `powermode 2` (High) — WI-1.8.)
    static func parsePowermode(_ output: String) -> EnergyMode {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("powermode") else { continue }   // not "lowpowermode"
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let last = tokens.last, let value = Int(last) else { return .unavailable }
            return mode(fromValue: value)
        }
        return .unavailable
    }
}
