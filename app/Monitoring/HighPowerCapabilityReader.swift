import Foundation

/// SWEEP §2.G shape, applied to the High-Power capability read: what the read actually KNOWS, so that
/// "this Mac does not support High Power" and "we could not find out" stop being the same `false`.
///
/// This is the fourth use of the three-state precedent already in the tree
/// (`BatterySnapshot.TemperatureReading`, `BatteryLifetimeReadFailure`, `PowerAdapterReadState`) — not
/// a fifth shape. Same rule as all of them: an ABSENCE that the read positively established is a
/// different value from an absence we inferred from a failure.
enum HighPowerCapability: Equatable, Sendable {
    /// `pmset -g cap` ran and listed `highpowermode`.
    case supported
    /// `pmset -g cap` ran and did NOT list it — this hardware genuinely has no High Power mode.
    case unsupported
    /// The read FAILED, twice (see `RetryPolicy.onceIfCutShort` below). We do not know either way.
    /// Carries the reason so a surface can say it rather than silently hiding a working feature.
    case unknown(String)

    /// The one bit the picker needs. `.unknown` is FALSE — hiding an option we cannot prove exists is
    /// the conservative direction — but it is now a DISTINCT value from `.unsupported`, which is what
    /// lets the caller decide to ask again instead of latching the answer forever.
    var isSupported: Bool { self == .supported }

    /// The cue a surface shows. nil in BOTH healthy states: a Mac without High Power is not a problem
    /// to report, and neither is one with it. Only a failed read gets a sentence.
    var note: String? {
        switch self {
        case .supported, .unsupported: return nil
        case .unknown(let why):        return "High Power availability unknown — \(why)."
        }
    }
}

/// Sprint 3.7 STAGE 5 — no-root reader for High Power availability. `pmset -g cap` (NON-privileged —
/// a read of the current hardware's supported capabilities) lists `highpowermode` only on Macs that
/// support High Power (R-15a: confirmed on this M4 Max). The picker HIDES its High Power option when
/// this returns false. Mirrors EnergyModeReader's seam: the caller runs `read()` off the main thread.
enum HighPowerCapabilityReader {

    /// RECOVERY: this is the site with the WORST failure-to-cost ratio in the whole `pmset` family, and
    /// it is also the cheapest to fix. The read is resolved once per launch and then CACHED
    /// (`EnergyModeController.resolveHighPowerAvailability`), so a child killed at the bound hides a
    /// working hardware feature — there is no 60 s poll here, no "the app was going to look again
    /// anyway" to fall back on.
    ///
    /// So it retries — once, and only when the first attempt was CUT SHORT (we killed it), never after
    /// a launch failure or a non-zero exit. That is `maxSpawnsPerRead` = 2 children per `readDetailed`.
    ///
    /// It is also SAFE to retry here in the one way that matters: this caller is NOT behind
    /// `BoundedReadGate`, so the 17 s worst case cannot be reclaimed mid-retry into a third spawn.
    ///
    /// HAND-OFF #1 of `21ec965` fixed the other half. The retry alone was not enough, because the
    /// controller cached the ATTEMPT rather than the ANSWER: a twice-failed read still latched
    /// "unsupported" for the session. It now caches only `.supported` / `.unsupported`, and an
    /// `.unknown` is re-probed on a later popover open — capped at
    /// `EnergyModeController.highPowerProbeLimit` (2) probes per launch. Composed worst case: **4
    /// children per launch, then zero forever**, against a measured ~8,100 `pmset` spawns/day
    /// (audit A13 §4.5), and only while the machine is actually killing `pmset`. A healthy launch
    /// spawns exactly one, unchanged.
    static let retryPolicy: PmsetProbe.RetryPolicy = .onceIfCutShort

    /// Children ONE `readDetailed()` may spawn, derived from the policy rather than restated: 2 under
    /// `.onceIfCutShort`, 1 under `.none`. Pure, so the launch budget is arithmetic a test can check
    /// (`EnergyModeController.highPowerProbeLimit × this`) instead of a number in a comment that rots.
    static var maxSpawnsPerRead: Int { retryPolicy == .onceIfCutShort ? 2 : 1 }

    /// Spawn `pmset -g cap`, capture stdout, and report whether High Power is supported. Any failure
    /// (spawn error, non-UTF8, non-zero exit) → false (conservatively hide High Power; never crash).
    ///
    /// Kept as the `() -> Bool` shape `EnergyModeController.resolveHighPowerAvailability(probe:)` takes,
    /// so the existing wiring in `BatteryApp` is unchanged and the tree compiles either way.
    ///
    /// ⚠️ THIS IS THE LOSSY ONE. A Bool has no third state, so `.unknown` arrives at the controller as a
    /// settled "no" and LATCHES — the exact defect hand-off #1 fixed. The controller's recovery and the
    /// picker's cue are both inert while this is what `BatteryApp` passes. Prefer `readDetailed`.
    ///
    /// AUDIT B6: bounded + fully drained via `PmsetProbe.run` — the old hand-rolled spawn left
    /// `standardError` unread, and this reader is resolved ONCE per launch, so a wedged child here did
    /// not merely stall: it parked a thread forever AND latched "High Power unsupported" for the whole
    /// session.
    static func read() -> Bool { readDetailed().isSupported }

    /// The three-state read: one bounded `pmset -g cap`, one retry if we cut the first one short, and
    /// an honest `.unknown` if the second is cut short too. A retry that also fails ENDS SOMEWHERE
    /// HONEST rather than laundering itself into `.unsupported`.
    static func readDetailed() -> HighPowerCapability {
        let outcome = PmsetProbe.run(["-g", "cap"], retry: retryPolicy)
        guard outcome.succeeded, let output = outcome.stdout else {
            return .unknown(unknownReason(outcome))
        }
        return parse(output) ? .supported : .unsupported
    }

    /// PURE. Why we do not know — the failure named, in the user's terms, with the retry stated when
    /// there was one so a served answer can never claim a certainty it does not have.
    static func unknownReason(_ outcome: PmsetOutcome) -> String {
        let cause: String
        if outcome.launchFailed {
            cause = "the capability read could not be started"
        } else if outcome.timedOut {
            cause = outcome.attempts > 1
                ? "the capability read did not finish in time, twice"
                : "the capability read did not finish in time"
        } else if let code = outcome.exitCode, code != 0 {
            cause = "the capability read exited \(code)"
        } else {
            cause = "the capability read returned output this app could not decode"
        }
        return cause
    }

    /// High Power is available iff a `highpowermode` capability line is present. Matched specifically —
    /// `lowpowermode` (which contains the substring "powermode") must NOT count as High Power.
    static func parse(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.split(whereSeparator: \.isWhitespace).contains("highpowermode")
        }
    }
}
