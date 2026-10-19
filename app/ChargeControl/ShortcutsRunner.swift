import Foundation

/// Executes `shortcuts run "<name>"` and classifies the outcome (SPEC v4.0 sec 2 ShortcutsRunner).
///
/// Behavior contract (normative):
/// - **Serialized**: ONE invocation at a time — no process starts while one is in flight (sec 2
///   command serialization). Callers queue FIFO; `isBusy` lets the UI disable/debounce controls.
/// - **Eager stderr classification**: stderr is a LIVE pipe; the moment a known fingerprint
///   appears the process is killed and classified (a missing shortcut prints its error then
///   hangs forever — waiting out the timeout would misclassify it as `.automationBlocked`).
/// - **15 s hard timeout**: SIGTERM → 2 s grace → SIGKILL. Timeout classifies as
///   `.automationBlocked` (the collapsed taxon — prompt-waiting and silent-TCC-denied are the
///   same observable). Never auto-retried (the prompt, if any, needs the human).
/// - **No retry here**: S-N4's "max 1 automatic retry" is an engine policy for specific cases
///   (read-back mismatch), not a runner behavior.
actor ShortcutsRunner {

    static let invocationTimeout: TimeInterval = 15
    static let sigkillGrace: TimeInterval = 2

    private let factory: ShortcutProcessLaunching
    private let sleeper: AsyncSleeping
    private var inFlight = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Observable busy flag for UI debounce (sec 2: controls disabled while a run is pending).
    private(set) var isBusy = false

    init(factory: ShortcutProcessLaunching = LiveShortcutProcessFactory(),
         sleeper: AsyncSleeping = LiveSleeper()) {
        self.factory = factory
        self.sleeper = sleeper
    }

    /// Run a shortcut by exact name. `outputPath` adds `-o <path>` (LimitReader's read channel).
    func run(name: String, outputPath: String? = nil) async -> ShortcutRunOutcome {
        await acquireSlot()
        defer { releaseSlot() }
        var arguments = ["run", name]
        if let outputPath { arguments += ["-o", outputPath] }
        return await executeOnce(arguments: arguments)
    }

    /// Run `shortcuts list` (SetupFlow detection). Same serialization + classification rules.
    func list() async -> ShortcutRunOutcome {
        await acquireSlot()
        defer { releaseSlot() }
        return await executeOnce(arguments: ["list"])
    }

    // MARK: - FIFO serialization

    private func acquireSlot() async {
        if !inFlight {
            inFlight = true
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Woken by releaseSlot with the slot transferred to us (inFlight stays true).
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            inFlight = false
            isBusy = false
        } else {
            waiters.removeFirst().resume()   // hand the slot to the next queued caller
        }
    }

    // MARK: - one invocation

    private func executeOnce(arguments: [String]) async -> ShortcutRunOutcome {
        guard factory.shortcutsBinaryExists() else { return .shortcutsBinaryAbsent }
        let process = factory.makeProcess(arguments: arguments)
        do {
            try process.launch()
        } catch {
            return .launchFailed(message: String(describing: error))
        }

        // Three racers: process exit, eager fingerprint classification, hard timeout.
        // First definitive answer wins; the losers are cancelled.
        let stderrBox = StderrAccumulator()
        return await withTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                let code = await process.awaitExit()
                // An exit can race the stderr consumer: classification must not run until the
                // consumer has drained the pipe, or a fingerprint that arrived WITH the exit
                // would be missed (caught by testMissingShortcutFingerprintOnRealExitStillClassifies).
                await stderrBox.waitUntilConsumptionSettled()
                return .exited(code)
            }
            group.addTask {
                defer { stderrBox.markConsumptionSettled() }   // stream ended OR fingerprint hit
                for await line in process.stderrLines {
                    stderrBox.append(line)
                    if let classified = ShortcutStderrFingerprint.classify(line: line) {
                        return .fingerprint(classified)
                    }
                }
                return .stderrEnded   // never definitive on its own
            }
            group.addTask { [sleeper] in
                do {
                    try await sleeper.sleep(seconds: Self.invocationTimeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            var verdict: ShortcutRunOutcome?
            while let result = await group.next() {
                switch result {
                case .exited(let code):
                    let tail = stderrBox.joined()
                    if code == 0 {
                        verdict = .success(stdout: process.collectedStdout())
                    } else if let classified = ShortcutStderrFingerprint.classify(line: tail) {
                        verdict = classified   // fingerprint that arrived with a real exit
                    } else {
                        verdict = .failed(exitCode: code, stderrTail: tail)
                    }
                case .fingerprint(let outcome):
                    // Classify-and-kill the moment the fingerprint appears (sec 2) — the
                    // missing-shortcut process never exits on its own.
                    process.forceKill()
                    verdict = outcome
                case .timedOut:
                    // SIGTERM → grace → SIGKILL, then classify by what stderr held.
                    process.terminate()
                    try? await sleeper.sleep(seconds: Self.sigkillGrace)
                    if !process.hasExited { process.forceKill() }
                    let tail = stderrBox.joined()
                    if let classified = ShortcutStderrFingerprint.classify(line: tail) {
                        verdict = classified
                    } else {
                        verdict = .automationBlocked(stderrTail: tail)
                    }
                case .stderrEnded, .cancelled:
                    continue   // not definitive — keep racing
                }
                if verdict != nil { break }
            }
            group.cancelAll()
            return verdict ?? .failed(exitCode: -1, stderrTail: "")
        }
    }

    private enum RaceResult: Sendable {
        case exited(Int32)
        case fingerprint(ShortcutRunOutcome)
        case timedOut
        case stderrEnded
        case cancelled
    }
}

/// Accumulates stderr lines across the racing tasks, and tracks when consumption has SETTLED
/// (the consumer reached stream-end or returned on a fingerprint) so exit classification never
/// reads a half-drained tail. Lock-based so `markConsumptionSettled` is callable from `defer`.
private final class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var settled = false
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func joined() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func markConsumptionSettled() {
        lock.lock()
        settled = true
        let waiters = settleWaiters
        settleWaiters.removeAll()
        lock.unlock()
        for w in waiters { w.resume() }
    }

    func waitUntilConsumptionSettled() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if settled {
                lock.unlock()
                c.resume()
            } else {
                settleWaiters.append(c)
                lock.unlock()
            }
        }
    }
}
