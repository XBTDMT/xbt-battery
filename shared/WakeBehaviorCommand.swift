import Foundation

// Sprint 3.7 (wake behavior) — the pure command core for the FOURTH privileged op (setWakeBehavior, a
// pmset write of `powernap` + `womp` per power source from explicit user config). FIXED argv
// construction lives here, fully unit-testable; the Process SPAWN is helper-only. Injection is
// structurally impossible: `pmsetArguments` accepts ONLY a `ValidatedWakeBehaviorRequest` (which ONLY
// `validate` can mint), the pmset keys ("powernap","womp") and scope flags ("-b","-c") are hard-coded
// literals, and each value is a strict "0"/"1" from a Bool. NO rejection path exists: booleans are
// always valid and `validate` never returns nil; the structural mint is what enforces the injection
// barrier, not a value check.
public enum WakeBehaviorCommand {

    /// Reuse the one pmset-path source of truth (absolute, never PATH-resolved).
    public static var pmsetPath: String { EnergyModeCommand.pmsetPath }

    // Reply token contract. Success = "ok" (the app then reads `pmset -g custom` for display).
    public static let ok           = "ok"
    public static let errSetFailed = "error:set-failed"
    /// A submission within the cooldown of the last apply is REJECTED (the shared mutation anti-flood).
    public static let errCooldown  = "error:cooldown"

    /// The four booleans captured for the FIXED argv build. The initializer is `fileprivate`, so the
    /// ONLY way to obtain one is `validate(...)` — `pmsetArguments` can never be handed un-vetted input.
    /// Booleans cannot be out of range, so there is nothing to reject; this type exists purely as the
    /// structural injection barrier (mirrors the other ops' Validated request types).
    public struct ValidatedWakeBehaviorRequest: Sendable, Equatable {
        public let powerNapBattery: Bool
        public let powerNapAC: Bool
        public let wakeOnNetworkBattery: Bool
        public let wakeOnNetworkAC: Bool
        fileprivate init(powerNapBattery: Bool, powerNapAC: Bool,
                         wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool) {
            self.powerNapBattery = powerNapBattery
            self.powerNapAC = powerNapAC
            self.wakeOnNetworkBattery = wakeOnNetworkBattery
            self.wakeOnNetworkAC = wakeOnNetworkAC
        }
    }

    /// Mint a validated request. NON-optional: booleans are always in range, so this never rejects. It
    /// exists so `pmsetArguments` is reachable only through a minted request (the injection barrier).
    public static func validate(powerNapBattery: Bool, powerNapAC: Bool,
                                wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool)
        -> ValidatedWakeBehaviorRequest {
        ValidatedWakeBehaviorRequest(powerNapBattery: powerNapBattery, powerNapAC: powerNapAC,
                                     wakeOnNetworkBattery: wakeOnNetworkBattery,
                                     wakeOnNetworkAC: wakeOnNetworkAC)
    }

    /// Build the TWO FIXED `pmset` argvs (battery first, then AC) from a VALIDATED request. The keys
    /// "powernap"/"womp" and the scope flags "-b"/"-c" are LITERALS; only each value varies, and only
    /// between "0" and "1". pmset takes one scope flag per invocation, so per-source values need two calls.
    public static func pmsetArguments(_ r: ValidatedWakeBehaviorRequest) -> [[String]] {
        func bit(_ b: Bool) -> String { b ? "1" : "0" }
        return [
            [pmsetPath, "-b", "powernap", bit(r.powerNapBattery), "womp", bit(r.wakeOnNetworkBattery)],
            [pmsetPath, "-c", "powernap", bit(r.powerNapAC), "womp", bit(r.wakeOnNetworkAC)],
        ]
    }
}
