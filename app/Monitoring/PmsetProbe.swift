import Foundation

/// AUDIT B6 — the bounded, fully-drained `pmset` read, shared by every app-side `pmset` reader.
///
/// WHAT WAS WRONG. Each reader had hand-rolled the same three lines: `Process()`, `standardOutput =
/// Pipe()`, `standardError = Pipe()` — and then read only stdout. That is two defects, and the first
/// CAUSES the second:
///
///  1. **The unread `standardError` pipe.** A pipe holds ~64 KB. A child that writes more than that
///     BLOCKS on the write; it then never exits and never closes stdout, so the parent's
///     `readDataToEndOfFile()` on stdout blocks FOREVER. The unread pipe is not a cosmetic leak — it
///     is the wedge. It also threw away the one artifact that explains a failure: `pmset`'s own
///     stderr. Every reader mapped every failure to the same silent `nil` / `.unavailable` / `false`.
///
///  2. **No bound.** Nothing gave up. A wedged child parked a global-queue thread for the life of the
///     process and latched the caller's in-flight flag (see `BoundedReadGate`).
///
/// WHAT THIS DOES. One spawn path: stdin from /dev/null, BOTH pipes drained concurrently (so neither
/// can wedge the other), a hard timeout → SIGTERM → grace → SIGKILL, and stderr carried back on the
/// result and logged.
///
/// B6 CONVERGENCE. The spawn itself now lives in `BoundedProcess` — this type is the `pmset`-shaped
/// wrapper over it, and `ProcessProbe` is the device-probe-shaped wrapper over the same primitive.
/// `PmsetOutcome` stays exactly as it was: its readers gate on `succeeded`, which is stricter than
/// the primitive's (a `pmset` read whose stdout is not UTF-8 is a FAILED read here, and that is a
/// pmset-domain judgement, not a spawn-domain one). The privileged helper keeps its own
/// `EnergyHelperService.spawnAndCapture` (posix_spawn + an explicit fd map + waitpid-reap, proven by
/// check (f) of the SMC-DEAD gate) — the lessons are shared, the code is not, because `helper/` is
/// fenced behind an explicit source manifest.
///
/// UNPRIVILEGED. `pmset -g …` is a plain READ — no root, no helper, no XPC, no IOKit. This is
/// APP-side by construction and must stay that way (the SMC-DEAD gate would fail on a helper that
/// grew it).
struct PmsetOutcome: Sendable, Equatable {
    /// Decoded stdout, or nil when the bytes were not UTF-8 (each reader's pre-existing failure case).
    let stdout: String?
    /// Decoded stderr — EMPTY is the normal case for `pmset`, not a signal of anything.
    let stderr: String
    /// The child's `terminationStatus`, or nil when it never launched.
    let exitCode: Int32?
    /// The timeout tripped and the child was killed. Its stdout is partial and MUST NOT be parsed.
    ///
    /// RECOVERY: this is ALSO the `pmset`-domain spelling of `BoundedProcessResult.wasCutShort` — it is
    /// set from `killed || outputTruncated` and from nothing else, so "we gave up early" and
    /// "the command answered no" are already distinct here. That is the whole precondition for a
    /// retry that cannot storm: a non-zero exit and a launch failure both leave this FALSE.
    let timedOut: Bool
    /// `Process.run()` threw — no child ever existed.
    let launchFailed: Bool
    /// How many children this read actually spawned: 1 always, 2 only under `RetryPolicy.onceIfCutShort`
    /// when the first was cut short. There is no path that can make it 3 — see `RetryPolicy`.
    let attempts: Int

    /// Explicit init (NOT memberwise) so `attempts` defaults and every existing construction site —
    /// including the hand-built outcomes in `PmsetBoundedReadTests` — compiles unchanged.
    init(stdout: String?, stderr: String, exitCode: Int32?, timedOut: Bool, launchFailed: Bool,
         attempts: Int = 1) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.launchFailed = launchFailed
        self.attempts = attempts
    }

    /// The single predicate every reader gates on: a real child that exited 0 in time AND produced
    /// output we can actually read. Each reader already treated non-UTF-8 stdout as a failed read; it
    /// belongs in the shared predicate so the failure is LOGGED rather than mapped silently to
    /// `.unavailable` / nil / false.
    var succeeded: Bool { !launchFailed && !timedOut && exitCode == 0 && stdout != nil }
}

enum PmsetProbe {

    /// Fixed argv[0] — absolute, never a shell, never interpolated (the helper's spawn discipline).
    static let executablePath = "/usr/bin/pmset"

    /// Hard cap on ANY app-side `pmset` read. `pmset -g …` is a sub-second operation on a healthy
    /// machine (measured in the tens of milliseconds), so 5 s is two orders of magnitude of headroom
    /// and still fast enough that a wedged child cannot outlive one popover interaction. Deliberately
    /// far BELOW `BoundedReadGate.staleAfterSeconds`, so the spawn always settles itself first and the
    /// caller-side backstop stays invisible in production.
    static let timeoutSeconds: TimeInterval = 5

    /// Grace between SIGTERM and SIGKILL — the same escalation the helper uses. Owned by the shared
    /// primitive now; re-exported because `BoundedReadGate`'s ordering invariant is stated against it.
    static var graceSeconds: TimeInterval { BoundedProcess.graceSeconds }

    /// Longest we will wait for the stderr drain to reach EOF once the child is gone. The child's
    /// copy of the write end dies with it, so this is reached immediately in every real case; the
    /// bound exists so NO path in this function is unbounded.
    static var drainGraceSeconds: TimeInterval { BoundedProcess.drainGraceSeconds }

    // MARK: - recovery

    /// WHAT A CALLER DOES WHEN WE GIVE UP EARLY. The bounded spawn made failure HONEST; this makes it
    /// RECOVERABLE — but only where a second attempt is affordable, which is a per-call-site judgement
    /// and never a blanket one.
    ///
    /// There are exactly two cases and there may never be a third. In particular there is no
    /// `.untilItWorks`, no attempt count, and no backoff — the same discipline as `StderrPolicy`
    /// having no `.pipe-and-ignore`. This app's single largest measured CPU cost is subprocess spawns
    /// fired too often (audit A13: 63.4% of app CPU; A11/A12 were both spawn-count findings), so an
    /// unbounded retry would undo the whole energy arc of that audit. `.onceIfCutShort` can AT MOST
    /// double a failing site's spawn count, and only while the machine is actually killing children.
    enum RetryPolicy: Sendable, Equatable {
        /// One attempt. The recovery is the read the app was ALREADY going to do — the 60 s poll, the
        /// next popover open, the next cache expiry. Free, and correct wherever such a read exists.
        case none
        /// One extra attempt, ONLY when the first was cut short (`timedOut`), with a widened bound.
        /// Never after a launch failure (identical second failure) and never after a non-zero exit
        /// (the command answered). Correct only where a failed read LATCHES — where nothing else was
        /// going to re-read it soon enough to matter.
        case onceIfCutShort
    }

    /// Bound for the second attempt. The first was killed AT `timeoutSeconds`, so re-running it with
    /// the same bound mostly re-buys the same kill; doubling makes attempt 2 a genuinely different
    /// experiment (a machine that was briefly too loaded to finish a 5 s `pmset` usually finishes a
    /// 10 s one) while keeping the total bounded and stated.
    static let retryTimeoutMultiplier: Double = 2

    /// The worst case a caller can be made to wait, in seconds, for a policy: every attempt riding its
    /// full bound plus its SIGTERM→SIGKILL grace. PURE, so the ordering invariant against
    /// `BoundedReadGate.staleAfterSeconds` is a TEST rather than a comment.
    ///
    /// ⚠️ THE ORDERING RULE, and it is why most callers here are `.none`: `BoundedReadGate` presumes a
    /// read still in flight after `staleAfterSeconds` (10) is wedged and lets the NEXT caller take the
    /// gate from it. A `.onceIfCutShort` read worst-cases at 5+1+10+1 = 17 s, which is PAST that — so a
    /// gated caller would reclaim the gate mid-retry and spawn a third child. **A caller behind
    /// `BoundedReadGate` must use `.none`.** The two callers that use `.onceIfCutShort`
    /// (`HighPowerCapabilityReader`, `SleepTimerReader`) are gated by a once-per-launch flag and a
    /// 300 s cache stamp respectively, neither of which can reclaim anything.
    static func worstCaseSeconds(timeout: TimeInterval = timeoutSeconds, retry: RetryPolicy) -> TimeInterval {
        let one = timeout + graceSeconds
        switch retry {
        case .none:           return one
        case .onceIfCutShort: return one + (timeout * retryTimeoutMultiplier) + graceSeconds
        }
    }

    /// Run `pmset` with a fixed argv, bounded and fully drained. Blocks — the CALLER runs this off the
    /// main thread (every existing caller already does). Logs the failure reason, including whatever
    /// `pmset` put on stderr, so a failing read is no longer anonymous.
    ///
    /// `retry` defaults to `.none`: adding a spawn is the expensive direction in this app, so it is
    /// opted INTO at a site that has argued for it, never inherited by a site that did not think
    /// about it.
    static func run(_ arguments: [String],
                    timeout: TimeInterval = timeoutSeconds,
                    retry: RetryPolicy = .none) -> PmsetOutcome {
        run(executable: executablePath, arguments: arguments, timeout: timeout, retry: retry)
    }

    /// The retry-aware read. `executable` is a parameter ONLY so the retry ARITHMETIC can be proven
    /// against a child that deliberately misbehaves — the same reason `capture` takes one; production
    /// has exactly one caller and it passes the fixed `executablePath`.
    ///
    /// STRAIGHT-LINE, not a loop: two `capture` calls and a `guard`. A loop is how an attempt cap turns
    /// into a bug later; there is nothing here for an off-by-one to be wrong about.
    static func run(executable: String, arguments: [String], timeout: TimeInterval,
                    retry: RetryPolicy) -> PmsetOutcome {
        let first = attempt(executable: executable, arguments: arguments, timeout: timeout, number: 1)
        // Retry ONLY the "we gave up early" class. A launch failure and a non-zero exit both leave
        // `timedOut` false and stop here, which is what makes a persistently-refusing `pmset` cost
        // exactly one spawn per read rather than two.
        guard retry == .onceIfCutShort, first.timedOut else { return first }
        return attempt(executable: executable, arguments: arguments,
                       timeout: timeout * retryTimeoutMultiplier, number: 2)
    }

    /// One attempt: capture, stamp the attempt number, log the failure if there was one.
    private static func attempt(executable: String, arguments: [String],
                                timeout: TimeInterval, number: Int) -> PmsetOutcome {
        let captured = capture(executable: executable, arguments: arguments, timeout: timeout)
        let outcome = PmsetOutcome(stdout: captured.stdout, stderr: captured.stderr,
                                   exitCode: captured.exitCode, timedOut: captured.timedOut,
                                   launchFailed: captured.launchFailed, attempts: number)
        if let note = failureNote(arguments: arguments, outcome: outcome) {
            NSLog("battery_app: %@", note)
        }
        return outcome
    }

    /// PURE. The one-line explanation of a failed read, or nil when it succeeded — the half of B6 the
    /// discarded pipe was throwing away. Split out from `run` so the message is unit-testable without
    /// spawning anything.
    static func failureNote(arguments: [String], outcome: PmsetOutcome) -> String? {
        guard !outcome.succeeded else { return nil }
        let command = (["pmset"] + arguments).joined(separator: " ")
        let reason: String
        if outcome.launchFailed {
            reason = "could not launch"
        } else if outcome.timedOut {
            reason = "timed out and was killed"
        } else if let code = outcome.exitCode, code != 0 {
            reason = "exited \(code)"
        } else if outcome.stdout == nil {
            reason = "produced output that is not UTF-8"
        } else {
            reason = "failed"
        }
        let detail = firstLine(outcome.stderr)
        // A retry that ALSO failed has to end somewhere honest, and the log is where. Without this the
        // second failure is indistinguishable from the first and the recovery becomes invisible —
        // which is the "a missing witness counts as an agreeing one" defect class, in the log.
        let attempt = outcome.attempts > 1 ? " (attempt \(outcome.attempts), after a retry)" : ""
        let head = "\(command): \(reason)\(attempt)"
        return detail.isEmpty ? head : "\(head) — \(detail)"
    }

    /// PURE. The first non-blank line of a stderr blob, trimmed and capped — a diagnostic, not a dump.
    static func firstLine(_ text: String, limit: Int = 200) -> String {
        BoundedProcess.firstLine(text, limit: limit)
    }

    // MARK: - the spawn

    /// The bounded spawn, in `pmset` terms. The mechanism — stdin from /dev/null, BOTH pipes drained
    /// concurrently, timeout → SIGTERM → grace → SIGKILL, gate-arbitrated so no recycled pid is ever
    /// signalled — is `BoundedProcess.run`; this maps it onto `PmsetOutcome`.
    ///
    /// `executable` is a parameter ONLY so the bound and the concurrent drain can be proven against a
    /// child that deliberately misbehaves; production has exactly one caller and it passes the fixed
    /// `executablePath`.
    static func capture(executable: String, arguments: [String], timeout: TimeInterval) -> PmsetOutcome {
        let result = BoundedProcess.run(executable: executable, arguments: arguments,
                                        timeout: timeout, stderr: .capture)
        if result.launchFailed {
            return PmsetOutcome(stdout: nil, stderr: result.launchError,
                                exitCode: nil, timedOut: false, launchFailed: true)
        }
        // `String(data:encoding:)` — NOT the lossy `String(decoding:)` — because a `pmset` read whose
        // stdout is not UTF-8 is a FAILED read, and `succeeded` is what every caller gates on.
        return PmsetOutcome(stdout: String(data: result.stdout, encoding: .utf8),
                            stderr: String(decoding: result.stderr, as: UTF8.self),
                            exitCode: result.exitCode,
                            // `outputTruncated` folds into `timedOut` because that is exactly what it
                            // means to a reader: the bound tripped, the stdout here is PARTIAL, do
                            // not parse it. (`pmset` backgrounds nothing, so this is a belt-and-
                            // braces mapping — but the seam must not be able to hand a reader a
                            // half-read `pmset -g sched` and have it pass `succeeded`.)
                            timedOut: result.killed || result.outputTruncated,
                            launchFailed: false)
    }
}

// MARK: - the caller-side latch

/// AUDIT B6 — the single-settle gate for an off-main blocking read. The READ-side sibling of B3's
/// `HelperCallGate`, and the answer to this project's most-repeated defect: a flag that is set on
/// kickoff and cleared only by a completion that a wedged child never delivers.
///
/// The flag itself is not the bug — it is the pile-up guard that keeps rapid popover toggling from
/// stacking `pmset` spawns (audit L2 / A11 / A12), and it must survive. What was missing is a way
/// BACK. Two candidate shapes were considered:
///
///  * a watchdog TIMER per read (B3's shape on XPC) — correct, but it schedules a main-queue wake per
///    read, and `refreshEnergyMode()` runs on the 60 s poll: ~1,440 extra timer wakes/day on a machine
///    whose whole B-arc was spent DELETING wakes. Rejected on cost.
///  * a STALE CLAIM, below: the gate records when the read started, and the next caller past the bound
///    presumes the old read wedged and takes the gate from it. Zero timers, zero wakes, and the way
///    back needs no user action — the next refresh the app was going to do anyway performs it. Same
///    shape as the conditional popover-open self-heal ping restored in `7718e8f`.
///
/// The superseded read is not merely ignored on return: its token no longer matches, so a late
/// completion can never clobber a newer result.
@MainActor
struct BoundedReadGate {

    /// A read still in flight after this long is presumed wedged and is reclaimed by the next caller.
    /// Sits well ABOVE `PmsetProbe.timeoutSeconds` + its kill grace (5 + 1) so the bounded spawn always
    /// settles itself first and this backstop is invisible in production. It exists because the reader
    /// is a SEAM — nothing forces a future conformance to be bounded, which is exactly the argument
    /// `EnergyModeController`'s 25 s B3 backstop is built on.
    static let staleAfterSeconds: TimeInterval = 10

    /// Whether a read is currently claimed (the pile-up guard the call sites used to hold by hand).
    private(set) var inFlight = false
    private var liveToken = 0
    private var startedAt: TimeInterval = 0

    /// Claim the gate for a new read; nil when one is genuinely in flight (coalesce, as before).
    mutating func begin(now: TimeInterval) -> Int? {
        if inFlight && !Self.isStale(startedAt: startedAt, now: now) { return nil }
        inFlight = true
        startedAt = now
        liveToken &+= 1        // &+ : monotonic, wrap-safe (a wrap is astronomically unreachable)
        return liveToken
    }

    /// True for the FIRST arrival on `token` only. A completion from a read that was already reclaimed
    /// gets false and must do nothing.
    mutating func settle(_ token: Int) -> Bool {
        guard inFlight, token == liveToken else { return false }
        inFlight = false
        return true
    }

    /// PURE. Monotonic time only; a zero or backwards delta is never stale.
    static func isStale(startedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - startedAt >= staleAfterSeconds
    }
}
