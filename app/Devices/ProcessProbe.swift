import Foundation

/// Sprint 4.H (#12): a tiny generic subprocess runner with a hard timeout + kill discipline — it
/// NEVER hangs. The ShortcutsRunner's lessons are copied here, NOT its code: that runner is FROZEN
/// and its failure taxonomy is shortcut-domain; entangling them would unfreeze audited code for
/// zero gain. This one only needs: run, capture stdout, give up after `timeout` (SIGTERM → SIGKILL).
///
/// AUDIT B6 CONVERGENCE. The spawn is now `BoundedProcess.run` — the same primitive `PmsetProbe`
/// wraps. Two defects went with the hand-rolled version this replaces:
///
///  1. **The recycled-PID window.** The old shape armed a `DispatchWorkItem` killer and then called
///     `killer.cancel()` after `waitUntilExit()`. `cancel()` is a NO-OP once the item has begun
///     executing, and `waitUntilExit()` returns only after Foundation has REAPED the child — so a
///     child that exits microseconds before the deadline could still be SIGTERMed/SIGKILLed after
///     the kernel had handed its pid to an unrelated process. The primitive arbitrates the verdict
///     through a one-shot gate instead: the normal path claims it before returning, so a watchdog
///     that fires late signals nothing at all.
///
///  2. **`timedOut` was an INFERENCE.** It read `terminationReason == .uncaughtSignal`, which cannot
///     tell our SIGTERM from the child's own SIGSEGV — and, worse, reports `.exit` for a child that
///     HANDLES SIGTERM and exits 0. A killed `ioreg` that flushed a partial tree and exited cleanly
///     therefore came back `timedOut == false`, and `DeviceBatterySource` fed that truncated tree to
///     `DeviceParsers.parseIoreg` as if it were a complete read. It is now a FACT (`killed`: we
///     signalled it) OR-ed with `terminatedBySignal`, so it is a strict SUPERSET of the old value —
///     everything that used to trip it still trips it, plus the case it was silently missing.
///
/// Note the B6 wedge itself never applied here: stderr went to `FileHandle.nullDevice`, not to an
/// assigned-but-unread `Pipe()`. It is now `.capture`d instead — same immunity (both pipes are
/// drained concurrently), but a failed probe finally says WHY in the log rather than vanishing.
struct ProcessProbeResult: Sendable {
    let stdout: String
    let timedOut: Bool
    let launchFailed: Bool
    let duration: TimeInterval   // for the adaptive system_profiler guard (>1 s → demote)
    /// B6: the child's exit status, or nil when it never launched. Additive — surfaced and logged so
    /// a non-zero exit is no longer anonymous. The device-domain call it was waiting on has since been
    /// made: `DeviceBatterySource` now treats a KNOWN non-zero status as a failed read rather than
    /// parsing the partial tree a failing `ioreg` printed on its way out.
    let exitCode: Int32?
    /// B6: the child's stderr — the artifact that explains a failed probe. Empty is the normal case.
    let stderr: String
    /// RECOVERY CLASSIFICATION: `BoundedProcessResult.wasCutShort` carried through — WE gave up on this
    /// child (killed at the bound, or its pipe abandoned past the drain grace), as opposed to the child
    /// crashing on its own or the binary failing to launch. NARROWER than `timedOut`, which also folds
    /// in `terminatedBySignal`.
    ///
    /// CONSUMED by `DeviceBatterySource.probeFailureReason`: `ioregExhausted` used to latch on
    /// `timedOut || launchFailed`, permanently disarming the Bluetooth-HID fallback for the session —
    /// the SAME latch-on-a-transient-failure defect `HighPowerCapabilityReader` had. It now latches only
    /// a SETTLED failure, and a cut-short one costs a token from a session budget instead.
    let cutShort: Bool

    /// Explicit init (NOT memberwise) so the added fields default and every existing construction
    /// site — including the scripted mocks in `DeviceBatterySourceTests` — compiles unchanged.
    init(stdout: String, timedOut: Bool, launchFailed: Bool, duration: TimeInterval,
         exitCode: Int32? = nil, stderr: String = "", cutShort: Bool = false) {
        self.stdout = stdout
        self.timedOut = timedOut
        self.launchFailed = launchFailed
        self.duration = duration
        self.exitCode = exitCode
        self.stderr = stderr
        self.cutShort = cutShort
    }
}

protocol ProcessProbing: Sendable {
    func run(_ launchPath: String, args: [String], timeout: TimeInterval) async -> ProcessProbeResult
}

struct ProcessProbe: ProcessProbing {
    func run(_ launchPath: String, args: [String], timeout: TimeInterval = 5) async -> ProcessProbeResult {
        // Everything touching the non-Sendable Process lives inside ONE background closure, so
        // nothing crosses an isolation boundary (Swift 6 region-isolation clean). The primitive
        // BLOCKS, so it must stay off the main thread — that is what this hop is for.
        await withCheckedContinuation { (cont: CheckedContinuation<ProcessProbeResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = BoundedProcess.run(executable: launchPath, arguments: args,
                                                timeout: timeout, stderr: .capture)
                let command = ([launchPath] + args).joined(separator: " ")
                if let note = BoundedProcess.failureNote(command: command, result: result) {
                    NSLog("battery_app: %@", note)
                }
                cont.resume(returning: ProcessProbeResult(
                    // Lossy decode is correct HERE: these probes are best-effort text scrapes and a
                    // stray non-UTF-8 byte must not blank an otherwise usable tree.
                    stdout: String(decoding: result.stdout, as: UTF8.self),
                    // A strict superset of the old inference — see the type doc. `outputTruncated`
                    // joins it because `DeviceBatterySource` reads this ONE bit to decide whether
                    // the ioreg tree it got is complete enough to parse, and a truncated tree is
                    // not (an `ioreg` that left a grandchild on the pipe would otherwise be merged
                    // as if it were the whole device list).
                    timedOut: result.killed || result.terminatedBySignal || result.outputTruncated,
                    launchFailed: result.launchFailed,
                    duration: result.duration,
                    exitCode: result.exitCode,
                    stderr: String(decoding: result.stderr, as: UTF8.self),
                    // The "we gave up early" half of `timedOut`, kept separate: a caller deciding
                    // whether to LATCH a failure needs to know we cut the child short rather than
                    // that the child answered.
                    cutShort: result.wasCutShort))
            }
        }
    }
}
