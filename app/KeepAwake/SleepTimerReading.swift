import Foundation

/// #EI-1 keep-awake, "does this toggle actually do anything?" — the machine's REAL idle-sleep timers.
///
/// WHY THIS EXISTS (audit 2026-09 §2.D, owner finding). The keep-awake feature holds
/// `PreventUserIdleSystemSleep` / `PreventUserIdleDisplaySleep`, which prevent IDLE sleep and nothing
/// else. Whether idle sleep was ever going to happen is a **user setting**, not a constant: on this
/// machine `pmset -g custom` reports AC `sleep 0` (never idle-sleeps) against battery `sleep 1`, and
/// those values live in `/Library/Preferences/com.apple.PowerManagement.plist` as explicit overrides.
/// The app had NO read of them, so it made the same promise on both power sources — and on power the
/// system half of that promise was preventing something that was never going to happen.
///
/// So the timers are the missing input. With them the popover can say what the toggle achieves *on
/// this power source, right now* instead of a source-blind slogan.
struct SleepTimers: Equatable, Sendable {
    /// pmset `sleep` — minutes of user-idle before the SYSTEM sleeps. `0` is macOS's own encoding for
    /// "never". nil = the value could not be read (never guess one).
    let systemMinutes: Int?
    /// pmset `displaysleep` — minutes of user-idle before the DISPLAY switches off. `0` = never.
    let displayMinutes: Int?

    static let unknown = SleepTimers(systemMinutes: nil, displayMinutes: nil)

    /// The minutes of user-idle before the machine ACTUALLY idle-sleeps — which is NOT the raw `sleep`
    /// value when `displaysleep` is longer.
    ///
    /// MEASURED, live in `pmset -g assertions` on this machine: powerd itself holds
    /// `PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"` — the very
    /// assertion this codebase already knows about and filters out
    /// (`WhatsKeepingAwake.circularOwner` / `.circularName`). While the display is on, the system
    /// cannot idle-sleep. So the system sleeps at `max(sleep, displaysleep)`, and this machine's
    /// battery profile (`sleep 1`, `displaysleep 10`) idle-sleeps at ~10 minutes, not at 1. Quoting
    /// the raw `1` at the user would have been flatly wrong — the whole point of this file is to stop
    /// the app asserting things it has not established.
    ///
    /// nil = the machine does not idle-sleep on this profile at all, either because `sleep 0`, or
    /// because `displaysleep 0` keeps powerd's assertion up forever.
    var effectiveSystemSleepMinutes: Int? {
        guard let system = systemMinutes, system > 0 else { return nil }
        guard let display = displayMinutes else { return system }   // display unknown → the raw setting
        if display == 0 { return nil }                              // display never off ⇒ never idle-sleeps
        return max(system, display)
    }
}

/// Both power profiles' timers, keyed by the `pmset -g custom` profile header — NOT by the active
/// source. Same reason `EnergyModeReader.PerSourceEnergyMode` exists: the active-source read cannot
/// answer "what would happen if you unplugged".
struct SleepTimerSettings: Equatable, Sendable {
    let battery: SleepTimers
    let charger: SleepTimers

    static let unknown = SleepTimerSettings(battery: .unknown, charger: .unknown)

    func timers(onAC: Bool) -> SleepTimers { onAC ? charger : battery }
}

/// Seam over the sleep-timer read, mirroring `EnergyModeReading` / `PowerSourceReading` exactly:
/// a protocol, a live implementation that spawns `pmset`, and a fake in tests. `Sendable` because the
/// controller hands it to a detached task (the child blocks; it must never run on the main thread).
///
/// UNPRIVILEGED. `pmset -g custom` is a plain READ — no root, no helper, no XPC, no IOKit. It is
/// APP-side by construction and must stay that way (the SMC-DEAD gate would fail on a helper that
/// grew this).
protocol SleepTimerReading: Sendable {
    func readSleepTimers() -> SleepTimerSettings
}

/// Production reader — wraps the `pmset`-spawning `SleepTimerReader.read()` (no behavior change).
struct LiveSleepTimerReader: SleepTimerReading {
    func readSleepTimers() -> SleepTimerSettings { SleepTimerReader.read() }
}

/// READ-ONLY `pmset -g custom` parse for the idle-sleep timers. No write path here of any kind.
///
/// COST DISCIPLINE (audit A11 / A12 — a subprocess spawn per popover open has already been a finding
/// twice): this spawns a child, so it is called from `KeepAwakeController.refreshSleepTimers()` ONLY,
/// which is cached and user-gated. It is never on a timer and never on the popover-open path.
enum SleepTimerReader {

    /// Read `pmset -g custom` (prints BOTH profiles), parse per profile. Any failure → `.unknown` for
    /// the affected profile (never crash, never guess). The CALLER runs this off the main thread.
    ///
    /// B6: this used to spawn its own `Process` with `standardError = Pipe()` and never read that pipe.
    /// A pipe holds ~64 KB; a child that writes past it blocks on the stderr write, never exits, never
    /// closes stdout, and `readDataToEndOfFile()` then blocks forever — parking this detached task for
    /// the life of the process. Unlike the four readers B6 fixed, this one could not LATCH (its caller's
    /// 300 s stamp is taken before the suspension point), but it would have re-spawned a fresh wedged
    /// child every five minutes thereafter. It now goes through the one bounded, fully-drained spawn
    /// path: both pipes read concurrently, 5 s timeout → SIGTERM → grace → SIGKILL, and `succeeded`
    /// requires exit 0 AND in-time AND decodable, so a killed child's PARTIAL output can never be
    /// parsed as a complete reading — which for this reader would mean inventing a sleep timer.
    /// RECOVERY: retry ONCE if the first attempt was cut short, and stay `.unknown` if the second is
    /// too. The reasoning is the caller's cache, not this reader's taste:
    /// `KeepAwakeController.refreshSleepTimers()` stamps `sleepTimersReadAt` BEFORE the read and stamps
    /// it on FAILURE as well, deliberately ("a machine where `pmset` cannot run must not be re-probed
    /// on every interaction"). So one child killed at the bound costs the user the entire explanation
    /// of what the keep-awake toggle achieves — the whole point of this file — for a full 5 minutes,
    /// and no timer, no poll and no popover-open path is going to fill that gap.
    ///
    /// WORST-CASE SPAWNS: the 300 s stamp is the ceiling and it is unchanged, so the ceiling is
    /// **12 reads/hr × 2 = 24 spawns/hr**, and only while `pmset` is genuinely being killed at the
    /// bound; the steady state is 0–12/hr and today it is ~0 (the read is user-gated: the keep-awake
    /// disclosure opening, or the toggle being flipped, never a timer and never popover-open). Against
    /// the ~8,100 `pmset` spawns/day the poll and the A13 notification path already produce (audit
    /// §4.5), a ceiling of 24/hr on a failing machine is inside the noise.
    ///
    /// SAFE TO RETRY HERE for the structural reason: this caller is gated by a monotonic 300 s stamp,
    /// not by `BoundedReadGate`, so nothing can reclaim the read mid-retry and start a third child.
    ///
    /// NO STALE-SERVE, deliberately. Serving the previous timers would need an age on screen to be
    /// honest, and `SleepTimers`'s failure state is ALREADY honest without one: a `.unknown` reading
    /// makes `sleepTimerClause` return nil and `isInert` return false, so the popover says NOTHING
    /// rather than making a claim. Trading a silent-but-correct gap for a stale number the surface
    /// could not label would be the exact defect this audit keeps finding.
    static let retryPolicy: PmsetProbe.RetryPolicy = .onceIfCutShort

    static func read() -> SleepTimerSettings {
        let outcome = PmsetProbe.run(["-g", "custom"], retry: retryPolicy)
        guard outcome.succeeded, let output = outcome.stdout else { return .unknown }
        return parse(output)
    }

    /// Pure parse: walk the lines, track the current profile header ("Battery Power:" / "AC Power:"),
    /// and read the `sleep` / `displaysleep` integers under each into that profile.
    ///
    /// Keys are matched on the WHOLE first token, case-sensitively, not by prefix — `pmset` prints
    /// `disksleep`, `displaysleep`, `ttyskeepawake` and `Sleep On Power Button` in the same block, and
    /// a `hasPrefix("sleep")` test would be wrong for three of them. First value per profile wins; a
    /// profile with no/garbled value stays nil and NEVER borrows the other profile's number.
    static func parse(_ output: String) -> SleepTimerSettings {
        enum Profile { case none, battery, charger }
        var current: Profile = .none
        var systemMinutes: [Profile: Int] = [:]
        var displayMinutes: [Profile: Int] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Battery Power") { current = .battery; continue }
            if line.hasPrefix("AC Power")      { current = .charger; continue }
            guard current != .none else { continue }        // a key before any header → ignore
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.count >= 2, let value = Int(tokens[tokens.count - 1]), value >= 0
            else { continue }
            switch tokens[0] {
            case "sleep":        if systemMinutes[current]  == nil { systemMinutes[current]  = value }
            case "displaysleep": if displayMinutes[current] == nil { displayMinutes[current] = value }
            default: break
            }
        }

        func timers(_ p: Profile) -> SleepTimers {
            SleepTimers(systemMinutes: systemMinutes[p], displayMinutes: displayMinutes[p])
        }
        return SleepTimerSettings(battery: timers(.battery), charger: timers(.charger))
    }
}
