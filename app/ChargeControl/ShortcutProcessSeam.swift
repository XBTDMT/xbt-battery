import Foundation

/// Seam over one spawned `shortcuts` process so the runner's classification/timeout/kill logic is
/// unit-testable with a scripted mock (SPEC WI-N1 "mock Process layer"). Mirrors the
/// `PowerSourceReading` seam pattern from Phase 1.
protocol ShortcutProcessHandle: AnyObject, Sendable {
    /// Spawn the process (throws on spawn failure).
    func launch() throws
    /// Live stderr line stream — the runner classifies fingerprints the moment a line appears
    /// (sec 2 eager classification: a missing shortcut prints its error then HANGS).
    var stderrLines: AsyncStream<String> { get }
    /// Suspends until the process exits; returns the exit code. Safe to call once.
    func awaitExit() async -> Int32
    /// Everything stdout produced so far (read at classification time).
    func collectedStdout() -> String
    /// SIGTERM (the polite half of the timeout path).
    func terminate()
    /// SIGKILL (after the 2 s grace).
    func forceKill()
    /// True once the process has exited (used to skip SIGKILL when SIGTERM landed).
    var hasExited: Bool { get }
}

protocol ShortcutProcessLaunching: Sendable {
    /// A handle for `/usr/bin/shortcuts <arguments>` — NOT yet launched.
    func makeProcess(arguments: [String]) -> ShortcutProcessHandle
    /// Whether `/usr/bin/shortcuts` exists (sec 6 "`shortcuts` binary absent").
    func shortcutsBinaryExists() -> Bool
}

/// Async-sleep seam so timeout logic is test-controlled (no real 15 s waits in tests).
/// `sleep` throws `CancellationError` when the surrounding task is cancelled.
protocol AsyncSleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct LiveSleeper: AsyncSleeping {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Live implementation

/// Real `Process` wrapper. Stderr is consumed line-by-line through a readability handler feeding
/// an `AsyncStream` — a live pipe, NOT a read-to-end (sec 2: the missing-shortcut error must be
/// classifiable while the process hangs).
///
/// AUDIT B6 CONVERGENCE — a DELIBERATE NON-ADOPTER of `BoundedProcess`, and the reason is the whole
/// design of this seam. `BoundedProcess` is a read-to-END primitive: it hands you stdout and stderr
/// once the child has settled. `shortcuts` cannot be run that way — a missing shortcut prints its
/// error and then HANGS FOREVER, so the outcome has to be classified WHILE the process is still
/// alive (sec 2 eager classification). That is why stderr here is a live line stream, why the bound
/// lives one level up in the serialised `ShortcutsRunner` (15 s → SIGTERM → 2 s → SIGKILL) rather
/// than inside one spawn, and why forcing this onto the primitive would DELETE a behaviour rather
/// than unify one.
///
/// It was never exposed to the B6 wedge in the first place: BOTH pipes are drained continuously by
/// their own readability handlers, so neither can fill and deadlock the child. What it did NOT do
/// was the primitive's other two contract items — those are adopted below: stdin comes from
/// /dev/null (an inherited stdin is a wedge with extra steps), and the child is killed by pid only
/// while `Process` still reports it running.
final class LiveShortcutProcess: ShortcutProcessHandle, @unchecked Sendable {

    /// The one and only production executable. A parameter ONLY so the concurrent drain can be
    /// proven against a child that deliberately floods stderr past a pipe's ~64 KB buffer — the same
    /// reason `PmsetProbe.capture` and `BoundedProcess.run` take one. Production goes through
    /// `LiveShortcutProcessFactory`, which never passes it.
    static let executablePath = "/usr/bin/shortcuts"

    private let process = Process()
    private let stderrPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrCarry = Data()         // partial line buffer between reads
    private var exited = false
    private var exitCode: Int32 = -1
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var lineContinuation: AsyncStream<String>.Continuation?

    let stderrLines: AsyncStream<String>

    init(arguments: [String], executable: String = LiveShortcutProcess.executablePath) {
        var continuation: AsyncStream<String>.Continuation!
        stderrLines = AsyncStream { continuation = $0 }
        lineContinuation = continuation

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // B6 contract: a command runner never has anything to say to its child, and an INHERITED
        // stdin is a wedge with extra steps — a child that blocks reading it never exits, never
        // closes its pipes, and the runner rides its 15 s bound for nothing.
        process.standardInput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe
    }

    func launch() throws {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {                      // EOF
                handle.readabilityHandler = nil
                self.flushCarryAndFinishLines()
                return
            }
            self.appendStderr(data)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.lock(); self.stdoutData.append(data); self.lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            self?.noteExit(code: p.terminationStatus)
        }
        try process.run()
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrCarry.append(data)
        var lines: [String] = []
        while let nl = stderrCarry.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stderrCarry.subdata(in: stderrCarry.startIndex..<nl)
            stderrCarry.removeSubrange(stderrCarry.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
        }
        // A hanging process may print its error WITHOUT a trailing newline — surface the partial
        // buffer as a line too, so the eager fingerprint check still sees it (sec 2).
        if !stderrCarry.isEmpty, let partial = String(data: stderrCarry, encoding: .utf8) {
            lines.append(partial)
            stderrCarry.removeAll()
        }
        let continuation = lineContinuation
        lock.unlock()
        for line in lines { continuation?.yield(line) }
    }

    private func flushCarryAndFinishLines() {
        lock.lock()
        let leftover = stderrCarry.isEmpty ? nil : String(data: stderrCarry, encoding: .utf8)
        stderrCarry.removeAll()
        let continuation = lineContinuation
        lineContinuation = nil
        lock.unlock()
        if let leftover { continuation?.yield(leftover) }
        continuation?.finish()
    }

    private func noteExit(code: Int32) {
        lock.lock()
        exited = true
        exitCode = code
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        flushCarryAndFinishLines()
        for w in waiters { w.resume(returning: code) }
    }

    func awaitExit() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if exited {
                let code = exitCode
                lock.unlock()
                c.resume(returning: code)
            } else {
                exitWaiters.append(c)
                lock.unlock()
            }
        }
    }

    func collectedStdout() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    func terminate() { if process.isRunning { process.terminate() } }
    func forceKill() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        return exited
    }
}

struct LiveShortcutProcessFactory: ShortcutProcessLaunching {
    func makeProcess(arguments: [String]) -> ShortcutProcessHandle {
        LiveShortcutProcess(arguments: arguments)
    }
    func shortcutsBinaryExists() -> Bool {
        FileManager.default.isExecutableFile(atPath: LiveShortcutProcess.executablePath)
    }
}
