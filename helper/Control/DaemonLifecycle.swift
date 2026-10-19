import Foundation

/// Which way the storm guard fell on this launch.
public enum GuardDecision: Sendable, Equatable {
    case vend     // healthy — start the NSXPCListener (vend the Mach service)
    case gated    // rapid-crash-loop storm guard tripped — DO NOT vend the service this launch
}

/// The outcome of one launch attempt — the testable shape the storm-guard tests assert on.
public struct LaunchOutcome: Sendable, Equatable {
    public let decision: GuardDecision
    public let crashCount: Int
    public var gated: Bool { decision == .gated }
}

/// The crash-loop **storm guard** (S-1).
///
/// Sprint 3.7: DECOUPLED from the retired charge engine — the guard itself is KEPT intact, because it
/// protects ANY root daemon under launchd `KeepAlive {SuccessfulExit=false}` from a rapid respawn
/// storm (a boot fault that exits non-zero would otherwise relaunch in a tight loop). What was REMOVED
/// is purely charge-specific: the `ChargeInhibitEngine` dependency, `reconcileToAllow()`, and the
/// charge `SafetyPolicy` knobs (`reconcileBeforeGuard` / `guardStopSkipsReconcile`) — there is no
/// charge latch to reconcile in the energy helper, so the guard simplifies to "vend or don't."
///
/// Sequence (unchanged): `main` calls `recordLaunchAttempt()` ONCE per launch, BEFORE `launch()` reads
/// the counter, so rapid repeated crashes accumulate toward `guardThreshold`. `launch()` decides
/// whether to vend the Mach service. A helper that survives long enough calls `markHealthyUptime()`
/// to clear the counter, so ONLY rapid crashes (each dying before the healthy reset) accumulate. The
/// counter is PERSISTED across relaunches/reboots. Cut 2: rather than idling permanently once tripped
/// (the old trap), `main` schedules a probationary re-vend after a capped exponential backoff (see
/// `probationDelay` / `beginProbation`); a probation that survives the healthy window calls
/// `markHealthyUptime()` and fully recovers (both counters cleared), and `scripts/reset-storm-guard.sh`
/// clears the gate immediately. `launch()` itself stays a pure read — it never mutates or auto-clears
/// the counter (the tests exercise that in isolation).
///
/// Plain + synchronous so `launch()` is unit-testable without launchd.
public final class DaemonLifecycle: @unchecked Sendable {
    private let store: StormGuardStore
    private let guardThreshold: Int
    private let maxBackoffLevel: Int
    private let probationBase: TimeInterval

    public init(store: StormGuardStore, guardThreshold: Int = 5,
                maxBackoffLevel: Int = 6, probationBase: TimeInterval = 60) {
        self.store = store
        self.guardThreshold = guardThreshold
        self.maxBackoffLevel = maxBackoffLevel
        self.probationBase = probationBase
    }

    /// Crash-counter increment (the storm guard's accumulating half). `main` calls this ONCE per
    /// launch, BEFORE `launch()` reads the counter, so rapid repeated crashes accumulate toward
    /// `guardThreshold` and the respawn-storm mitigation can actually fire.
    public func recordLaunchAttempt() {
        store.increment()   // atomic +1 (single critical section)
    }

    /// Healthy-uptime reset: a helper that survived long enough clears BOTH counters (crashCount AND
    /// backoffLevel — a probation that proved healthy = full recovery), so ONLY rapid repeated crashes
    /// (each dying before this fires) accumulate. `main` schedules this on every vend path (initial AND
    /// probation) after the listener is up; a crash before it fires leaves both counters intact.
    public func markHealthyUptime() { store.reset() }

    // ── Cut 2: probationary re-vend (closes the permanent-gate trap) ──
    // "Storm" = rapid crashes, each death BEFORE the healthy-uptime window elapses. A fault that lets the
    // daemon survive past that window clears the counters and is NOT a storm — a documented, pre-existing
    // boundary (a stricter sliding-window detector is tracked, out of scope for this cut).  [GROK ISSUE 1]

    /// cooldown = probationBase × 2^backoffLevel, clamped to [0, maxBackoffLevel]. The clamp is
    /// load-bearing: a corrupt negative persisted backoffLevel must never reach 1 << negative (NO-TRAP).
    public func probationDelay() -> TimeInterval {
        let level = max(0, min(store.backoffLevel, maxBackoffLevel))
        return probationBase * Double(1 << level)
    }
    /// advance the probation backoff (capped); called when a probation timer fires, before re-vending
    public func beginProbation() { if store.backoffLevel < maxBackoffLevel { store.incrementBackoff() } }

    /// The storm-guard decision for THIS launch: `.gated` once the persisted crash count reaches the
    /// threshold (the caller must then NOT start the listener); `.vend` otherwise.
    public func launch() -> LaunchOutcome {
        let count = store.crashCount
        let decision: GuardDecision = (count >= guardThreshold) ? .gated : .vend
        return LaunchOutcome(decision: decision, crashCount: count)
    }
}
