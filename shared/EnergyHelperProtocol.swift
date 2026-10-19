import Foundation

/// The XPC interface vended by the privileged ENERGY helper (Sprint 3.7; supersedes the Phase-2
/// charge-inhibit `HelperProtocol`).
///
/// STAGE 4 surface = `ping` + `setEnergyMode` + `collectTaskEnergy` (the full Sprint 3.7 surface).
/// Replies carry only NSXPC-safe primitives (a `String` token, or plist `Data`). No charge/SMC surface.
@objc public protocol EnergyHelperProtocol {
    /// Replies with `"pong"`. Carries no parameters and touches no hardware — the channel smoke test.
    func ping(reply: @escaping (String) -> Void)

    /// STAGE 3 — the FIRST privileged action: set the Energy Mode for a power source.
    /// `mode` is VALIDATED to exactly {0=Automatic, 1=Low Power, 2=High Power} and `source` to exactly
    /// {0=battery, 1=charger, 2=all}; the HELPER rejects anything else BEFORE constructing any command,
    /// then builds the FIXED `pmset` argv itself (the app passes only these two integers — NO command
    /// string). `reply` = the read-back token (the resulting `powermode` value) or an `error:*` token.
    func setEnergyMode(mode: Int, source: Int, reply: @escaping (String) -> Void)

    /// STAGE 4 — the SECOND privileged op: a READ-ONLY energy query via `powermetrics`.
    /// `samples` is RANGE-CHECKED to [1,3] and `intervalMs` to [200,5000]; the HELPER rejects anything
    /// else BEFORE constructing any command, then builds the FIXED `powermetrics … -f plist` argv itself
    /// (the app passes only these two range-checked integers). `reply` = (plistData, nil) on success
    /// (the raw `-f plist` bytes, parsed app-side) or (nil, "error:*") on rejection/failure.
    func collectTaskEnergy(samples: Int, intervalMs: Int, reply: @escaping (Data?, String?) -> Void)

    /// SLEEP/WAKE — the THIRD privileged op: program macOS's native RECURRING power scheduler via
    /// `pmset repeat` from explicit user config. All seven values are VALIDATED primitives (hour [0,23],
    /// minute [0,59], weekdayMask a 7-bit field [1,127]); neither-enabled = cancel. The HELPER rejects
    /// out-of-range BEFORE building any command, then builds the FIXED `pmset repeat` argv itself using
    /// only the hard-coded event types "sleep"/"wakeorpoweron" (NEVER shutdown/restart/bare-poweron).
    /// `reply` = "ok" on success or an `error:*` token. The app reads `pmset -g sched` for display.
    func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                               wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int,
                               weekdayMask: Int, reply: @escaping (String) -> Void)

    /// WAKE BEHAVIOR — the FOURTH privileged op: write macOS's `powernap` (Power Nap) and `womp` (Wake
    /// for network access) per power source. All four inputs are booleans (inherently in range, so there
    /// is NO rejection token); the HELPER builds two FIXED `pmset` argvs itself (battery `-b`, AC `-c`)
    /// using only the hard-coded keys "powernap"/"womp" and "0"/"1" values. The app passes only the four
    /// booleans, never a key, scope, or value string. `reply` = "ok" on success or an `error:*` token.
    /// The app reads `pmset -g custom` for display.
    func setWakeBehavior(powerNapBattery: Bool, powerNapAC: Bool,
                         wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool,
                         reply: @escaping (String) -> Void)
}
