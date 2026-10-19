import Foundation

// Sprint 3.7 STAGE 4 — the pure command core for the SECOND privileged op (collectTaskEnergy, a
// read-only energy query via powermetrics). Range-check + FIXED argv construction live here, fully
// unit-testable. The Process SPAWN is helper-only; the app passes only two range-checked integers
// over XPC. Injection is structurally impossible: `powermetricsArguments` accepts only a
// `ValidatedTaskEnergyRequest` (which can ONLY be produced by `validate`), and the two ints are
// rendered as plain digit strings — no shell, no interpolation, no app value on a path.

public enum TaskEnergyCommand {

    /// The ONLY executable this op runs (absolute path literal — never PATH-resolved).
    public static let powermetricsPath = "/usr/bin/powermetrics"

    public static let minSamples = 1, maxSamples = 3
    public static let minIntervalMs = 200, maxIntervalMs = 5000

    /// Default to ONE-SHOT (SPEC sec 5 — the energy-irony rule: no background polling).
    public static let defaultSamples = 1
    public static let defaultIntervalMs = 1000

    // Reply token contract (failures). Success = raw plist Data (parsed app-side); these are the
    // explicit error tokens the app surfaces as an honest "unavailable" (never a fake number).
    public static let errInvalidSamples  = "error:invalid-samples"
    public static let errInvalidInterval = "error:invalid-interval"
    public static let errCollectFailed   = "error:collect-failed"
    /// A3 (Grok MAJOR concurrency): a sample requested within the cooldown of the last START is REJECTED
    /// with this token (a flood can't pile up root powermetrics spawns). App surfaces it as unavailable.
    public static let errCooldown        = "error:cooldown"

    // A3 (Grok hardening) — bounded child lifecycle + sampling concurrency. Shared so the helper and its
    // tests use ONE source of truth; these are plain constants — NOT a protocol change.
    /// Hard cap on ANY helper child: on expiry → SIGTERM, grace, SIGKILL, then waitpid-reap (all paths).
    public static let spawnTimeoutSeconds: TimeInterval = 30
    /// Grace between SIGTERM and SIGKILL during the bounded teardown.
    public static let spawnGraceSeconds: TimeInterval = 2
    /// Reject a new sample that starts within this of the previous sample's START (serial + cooldown).
    public static let sampleCooldownMs = 750

    /// A request whose `samples`/`intervalMs` are PROVEN in range. The initializer is `fileprivate`, so
    /// the ONLY way to obtain one is `validate(...)` — `powermetricsArguments` therefore can never be
    /// handed an out-of-range value (structural injection/abuse defense, mirroring Stage 3's enums).
    public struct ValidatedTaskEnergyRequest: Sendable, Equatable {
        public let samples: Int
        public let intervalMs: Int
        fileprivate init(samples: Int, intervalMs: Int) { self.samples = samples; self.intervalMs = intervalMs }
    }

    /// RANGE-CHECK both integers to samples ∈ [1,3], intervalMs ∈ [200,5000]. Returns nil (REJECT) for
    /// anything else — this runs BEFORE any command is constructed. Rejecting negatives also closes the
    /// dangerous `powermetrics -n -1` (infinite-sampling) path.
    public static func validate(samples: Int, intervalMs: Int) -> ValidatedTaskEnergyRequest? {
        guard (minSamples...maxSamples).contains(samples) else { return nil }
        guard (minIntervalMs...maxIntervalMs).contains(intervalMs) else { return nil }
        return ValidatedTaskEnergyRequest(samples: samples, intervalMs: intervalMs)
    }

    /// Which validation bound a raw (samples,intervalMs) pair violates — for the helper's reject token.
    public static func rejectionToken(samples: Int, intervalMs: Int) -> String {
        !(minSamples...maxSamples).contains(samples) ? errInvalidSamples : errInvalidInterval
    }

    /// Build the FIXED powermetrics argv from a VALIDATED request. Every element is a literal except
    /// the two range-checked integers rendered as digit strings (`String(Int)` of an in-[1,3]/[200,5000]
    /// value is purely digits). No interpolation; no app value reaches a path or a flag.
    public static func powermetricsArguments(_ request: ValidatedTaskEnergyRequest) -> [String] {
        [
            powermetricsPath,
            "-n", String(request.samples),
            "-i", String(request.intervalMs),
            "--samplers", "tasks",
            "-f", "plist",
            "--show-process-energy",
            "--show-process-coalition",
        ]
    }
}
