import Foundation

/// AUDIT B6 CONVERGENCE — the ONE app-side subprocess spawn.
///
/// WHY THIS EXISTS. B6 proved a mechanism rather than asserting one: a pipe holds ~64 KB, a child
/// that writes past it BLOCKS on the write, so it never exits and never closes stdout — and the
/// parent's `readDataToEndOfFile()` on stdout then blocks FOREVER. Four `pmset` readers were
/// permanently wedgeable that way, and the worst of them forced a destructive-cancel confirmation on
/// every use for the life of the process. `PmsetProbe` was hardened against it; this type is that
/// hardening lifted out so it is not a property of one call site.
///
/// THE CONTRACT, in one place:
///
///  * **stdin is /dev/null.** A read never has anything to say to us, and a child that blocks on a
///    tty read is a wedge with extra steps.
///  * **BOTH pipes are drained concurrently**, each on its own queue, so neither pipe filling can
///    deadlock the child against the parent. A caller that genuinely does not want stderr passes
///    `.discard`, which is `/dev/null` — an fd that can never fill — and NEVER an
///    assigned-but-unread `Pipe()`, which is precisely the B6 bug.
///  * **The wait is bounded**: `timeout` → SIGTERM → `grace` → SIGKILL. Nothing here is open-ended,
///    INCLUDING the drains. EOF on stdout is NOT a bound: a child that backgrounds a grandchild
///    hands it a copy of the pipe's write end, so stdout stays open long after the child we spawned
///    has exited and been reaped — a `readDataToEndOfFile()` on the calling thread then blocks for
///    the GRANDCHILD's lifetime, which nothing bounds. (Measured: a 0.4 s bound took 30.07 s against
///    `sh -c 'trap … TERM; sleep 30 & wait'`.) So the child's own exit is what this waits on, the
///    drains are read in CHUNKS into a snapshot-able sink, and their trailing wait has its own
///    deadline — after which whatever arrived is returned, flagged `outputTruncated`. This is the
///    app-side spelling of the same hazard `EnergyHelperService.spawnAndCapture` calls out by name.
///  * **The outcome is ARBITRATED, not cancelled.** The normal path and the kill watchdog race for a
///    one-shot `HelperCallGate`; the winner owns the verdict. That is what closes the recycled-PID
///    window an unconditional `DispatchWorkItem.cancel()` leaves open — `cancel()` is a no-op once
///    the item has begun executing, so a child that exits microseconds before the deadline can still
///    be signalled after Foundation has reaped it and the kernel has handed its pid to someone else.
///  * **`killed` is a FACT, not an inference.** It means "the watchdog claimed the verdict", i.e. we
///    signalled this child. It is not derived from `terminationReason`, which cannot tell our SIGTERM
///    from the child's own SIGSEGV and reports `.exit` for a child that handles SIGTERM and exits 0.
///
/// SCOPE. This is the APP-side primitive, and it is unprivileged by construction. The privileged
/// helper keeps its own `EnergyHelperService.spawnAndCapture` (posix_spawn + an explicit fd map +
/// waitpid-reap, proven by check (f) of the SMC-DEAD gate); `helper/` and `shared/` are fenced behind
/// an explicit source manifest and this file must never migrate there.
///
/// NON-ADOPTER, deliberately: `LiveShortcutProcess` (app/ChargeControl/ShortcutProcessSeam.swift).
/// It is a read-to-END-free design on purpose — its stderr is a LIVE line stream because a missing
/// shortcut prints its error and then HANGS, so `shortcuts` must be classified WHILE it runs, and its
/// bound belongs to the serialised `ShortcutsRunner` above it, not to one spawn. It already drains
/// both pipes (readability handlers, concurrently) and so was never exposed to the B6 wedge.
/// Converging it onto a read-to-end primitive would delete the eager classification, not unify it.
struct BoundedProcessResult: Sendable {

    /// Raw stdout bytes. NOT decoded here — a caller that treats non-UTF-8 as a failed read
    /// (`PmsetProbe`) and one that decodes lossily (`ProcessProbe`) need different things.
    let stdout: Data
    /// Raw stderr bytes; empty under `.discard`, and empty is the NORMAL case for a healthy read.
    let stderr: Data
    /// The child's `terminationStatus`, or nil when it never launched.
    let exitCode: Int32?
    /// The watchdog claimed the verdict — WE signalled this child. Its stdout is partial and must
    /// never be parsed as a complete read.
    let killed: Bool
    /// The child died on a signal (ours or its own). A superset of `killed`, kept because it is the
    /// only thing that catches a child which crashed on its own.
    let terminatedBySignal: Bool
    /// A drain did not reach EOF inside its grace — almost always a backgrounded GRANDCHILD still
    /// holding a copy of the pipe's write end. The bytes here are whatever had arrived by then, so
    /// they are partial by definition and must never be parsed as a complete read.
    let outputTruncated: Bool
    /// `Process.run()` threw — no child ever existed.
    let launchFailed: Bool
    /// The thrown launch error, for the log. Empty unless `launchFailed`.
    let launchError: String
    /// Wall time from spawn to verdict (the adaptive `system_profiler` demotion guard needs this).
    let duration: TimeInterval

    /// A real child that exited 0, in time, without being signalled, whose output we read in FULL.
    var succeeded: Bool {
        !launchFailed && !killed && !terminatedBySignal && !outputTruncated && exitCode == 0
    }

    /// RECOVERY CLASSIFICATION — "we gave up early", as opposed to "it answered and the answer was no".
    ///
    /// The honest primitive was the first half of the job; this is the seam the second half hangs on.
    /// A caller that wants a recovery needs to know WHICH failure it got, because only one of them is
    /// worth a second attempt:
    ///
    ///  * `killed` — the watchdog claimed the verdict, i.e. WE signalled this child at the bound. The
    ///    command never got to finish, so we do not actually know what it would have said.
    ///  * `outputTruncated` — a drain did not reach EOF inside its grace. Same thing at the pipe: we
    ///    gave up on bytes that were still coming.
    ///
    /// Everything else is deliberately EXCLUDED, and each exclusion is what keeps a recovery from
    /// becoming a spawn storm:
    ///
    ///  * `launchFailed` — the binary is missing or not executable. A second `posix_spawn` of the same
    ///    absolute path fails identically; retrying it buys nothing and costs a spawn.
    ///  * a non-zero `exitCode` with complete output — the command RAN and told us no. That is an
    ///    answer, not a gap; re-asking it is how a wedged-but-responsive binary gets hammered.
    ///  * `terminatedBySignal` without `killed` — the child crashed on its OWN signal. Nothing we did
    ///    bounded it, and a deterministic crash reproduces. Conservative on purpose: the cost of not
    ///    retrying a rare recoverable crash is one stale reading, and the cost of retrying a
    ///    deterministic one is a doubled spawn count forever.
    ///
    /// This is a FACT-derived predicate (it reads `killed`, which the commit above made a fact rather
    /// than an inference from `terminationReason`), which is the only reason it can be trusted to gate
    /// a retry at all.
    var wasCutShort: Bool { killed || outputTruncated }
}

enum BoundedProcess {

    /// Grace between SIGTERM and SIGKILL — the same escalation the privileged helper uses.
    static let graceSeconds: TimeInterval = 1

    /// Longest we will wait for the stderr drain to reach EOF once the child is gone. The child's
    /// copy of the write end dies with it, so this is reached immediately in every real case; the
    /// bound exists so NO path in this function is unbounded.
    static let drainGraceSeconds: TimeInterval = 1

    /// What to do with the child's stderr. There is no `.pipe-and-ignore` case, and there never may
    /// be — that case IS the B6 bug.
    enum StderrPolicy: Sendable {
        /// Drain it concurrently and carry it back (the diagnostic that explains a failed read).
        case capture
        /// Route it to /dev/null. Safe — an fd that cannot fill cannot wedge — but it throws away
        /// the one artifact that says WHY a read failed.
        case discard
    }

    /// Spawn `executable` with a FIXED argv — absolute path, never a shell, never interpolated.
    /// BLOCKS until the child settles or the bound trips; the caller runs it off the main thread.
    static func run(executable: String,
                    arguments: [String],
                    timeout: TimeInterval,
                    stderr policy: StderrPolicy = .capture,
                    grace: TimeInterval = graceSeconds) -> BoundedProcessResult {
        let start = DispatchTime.now()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe: Pipe? = (policy == .capture) ? Pipe() : nil
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return BoundedProcessResult(stdout: Data(), stderr: Data(), exitCode: nil,
                                        killed: false, terminatedBySignal: false,
                                        outputTruncated: false,
                                        launchFailed: true, launchError: "\(error)",
                                        duration: elapsed(since: start))
        }

        // THE FIX FOR B6 HALF ONE. BOTH pipes are drained, each on its OWN queue and concurrently
        // with the other and with the exit wait below. Either pipe filling now simply blocks its own
        // reader for a moment instead of deadlocking the child against the parent.
        //
        // Chunked into a snapshot-able sink rather than `readDataToEndOfFile()`, because EOF is not
        // ours to wait for: a backgrounded grandchild holds its own copy of the write end and keeps
        // the pipe open indefinitely. Reading in chunks means the bytes that DID arrive are
        // recoverable when we give up on the rest.
        let outSink = DataSink()
        let errSink = DataSink()
        let outDrained = DispatchSemaphore(value: 0)
        let errDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            drain(outPipe.fileHandleForReading, into: outSink)
            outDrained.signal()
        }
        if let errPipe {
            DispatchQueue.global(qos: .utility).async {
                drain(errPipe.fileHandleForReading, into: errSink)
                errDrained.signal()
            }
        } else {
            errDrained.signal()
        }

        // THE FIX FOR B6 HALF TWO. A watchdog keyed only on the pid (a `Process` is not Sendable).
        // `HelperCallGate` — first caller wins, everyone else does nothing — ARBITRATES it: the
        // normal path claims the gate before returning, so a watchdog that fires a microsecond later
        // finds it settled and signals NOTHING. `reaped` narrows the remaining window inside the
        // SIGTERM→SIGKILL grace to the same class as a `Process.isRunning` check: once the normal
        // path has reaped the child, the escalation is skipped rather than aimed at a free pid. This
        // is the app-side spelling of the helper's "reap only after EOF" discipline.
        let pid = process.processIdentifier
        let killGate = HelperCallGate()
        let reaped = HelperCallGate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [killGate, reaped] in
            guard killGate.claim() else { return }         // it already finished — do nothing at all
            kill(pid, SIGTERM)
            usleep(useconds_t(max(0, grace) * 1_000_000))
            guard !reaped.isSettled else { return }        // SIGTERM landed and we reaped it — stop
            kill(pid, SIGKILL)                             // its fds close ⇒ both readers reach EOF
        }

        // We wait on the CHILD WE SPAWNED, not on EOF. The watchdog bounds this; a grandchild cannot
        // extend it.
        process.waitUntilExit()
        _ = reaped.claim()
        // If we claim first the watchdog never signals; if we LOSE the claim, the watchdog owns the
        // verdict and this child was killed by us.
        let killed = !killGate.claim()

        // ONE shared deadline for both drains, so the trailing wait is `drainGraceSeconds` TOTAL and
        // not per-pipe. The child is already gone, so its copies of the write ends are closed and
        // both of these return immediately in every real case. A reader still parked past the
        // deadline owns its own fd and its own semaphore; it exits when the pipe finally closes and
        // its late signal is harmless.
        let drainDeadline = DispatchTime.now() + drainGraceSeconds
        let outOK = outDrained.wait(timeout: drainDeadline) == .success
        let errOK = errDrained.wait(timeout: drainDeadline) == .success

        return BoundedProcessResult(stdout: outSink.take(),
                                    stderr: errSink.take(),
                                    exitCode: process.terminationStatus,
                                    killed: killed,
                                    terminatedBySignal: process.terminationReason == .uncaughtSignal,
                                    outputTruncated: !(outOK && errOK),
                                    launchFailed: false,
                                    launchError: "",
                                    duration: elapsed(since: start))
    }

    /// Read a pipe in chunks into a sink that can be snapshotted at any time. `availableData` blocks
    /// until bytes arrive and returns EMPTY at EOF; reading in chunks (rather than to end) is what
    /// makes a partial read recoverable when a grandchild holds the pipe open past our bound.
    private static func drain(_ handle: FileHandle, into sink: DataSink) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }   // EOF
            sink.append(chunk)
        }
    }

    // MARK: - shared diagnostics

    /// PURE. The one-line explanation of a failed spawn, or nil when it succeeded — the half of B6
    /// the discarded stderr pipe was throwing away. Split out so the message is unit-testable
    /// without spawning anything.
    static func failureNote(command: String, result: BoundedProcessResult) -> String? {
        guard !result.succeeded else { return nil }
        let reason: String
        if result.launchFailed {
            reason = "could not launch"
        } else if result.killed {
            reason = "timed out and was killed"
        } else if result.terminatedBySignal {
            reason = "was terminated by a signal"
        } else if result.outputTruncated {
            reason = "left its output pipe open past the drain grace (a backgrounded grandchild?)"
        } else if let code = result.exitCode, code != 0 {
            reason = "exited \(code)"
        } else {
            reason = "failed"
        }
        let detail = firstLine(result.launchFailed
                               ? result.launchError
                               : String(decoding: result.stderr, as: UTF8.self))
        return detail.isEmpty ? "\(command): \(reason)" : "\(command): \(reason) — \(detail)"
    }

    /// PURE. The first non-blank line of a stderr blob, trimmed and capped — a diagnostic, not a dump.
    static func firstLine(_ text: String, limit: Int = 200) -> String {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return String(line.prefix(limit)) }
        }
        return ""
    }

    private static func elapsed(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}

/// Lock-guarded handoff of drained bytes from a drain queue back to the caller. `take()` is a
/// SNAPSHOT, callable while the drain is still running — that is what makes a partial read
/// recoverable when the caller gives up on a pipe a grandchild is holding open.
private final class DataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func append(_ data: Data) { lock.lock(); value.append(data); lock.unlock() }
    func take() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}
