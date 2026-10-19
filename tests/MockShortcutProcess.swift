import Foundation

/// Scripted stand-in for one `shortcuts` process (SPEC WI-N1 mock Process layer). The test drives
/// it: emit stderr lines, exit with a code, or hang forever; it records terminate/forceKill.
/// SIGKILL always produces an exit (as in reality) unless a test opts out — that also keeps the
/// runner's task group from hanging on `awaitExit`.
final class MockShortcutProcess: ShortcutProcessHandle, @unchecked Sendable {

    private let lock = NSLock()
    private var exited = false
    private var exitCode: Int32 = -1
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var stderrContinuation: AsyncStream<String>.Continuation?

    let stderrLines: AsyncStream<String>

    // Test scripting knobs
    var launchError: Error?
    /// Whether SIGTERM makes the process exit (code 15). False models a TERM-resistant hang.
    var exitsOnTerminate = true
    /// Whether SIGKILL makes the process exit (code 9). Reality: always. Leave true.
    var exitsOnForceKill = true
    var stdoutText = ""

    // Recorded interactions (asserted by tests)
    private(set) var launched = false
    private(set) var terminated = false
    private(set) var forceKilled = false

    init() {
        var c: AsyncStream<String>.Continuation!
        stderrLines = AsyncStream { c = $0 }
        stderrContinuation = c
    }

    // MARK: - test controls

    func emitStderr(_ line: String) { stderrContinuation?.yield(line) }

    func exit(code: Int32) {
        lock.lock()
        guard !exited else { lock.unlock(); return }
        exited = true
        exitCode = code
        let waiters = exitWaiters
        exitWaiters.removeAll()
        let c = stderrContinuation
        stderrContinuation = nil
        lock.unlock()
        c?.finish()
        for w in waiters { w.resume(returning: code) }
    }

    // MARK: - ShortcutProcessHandle

    func launch() throws {
        if let launchError { throw launchError }
        launched = true
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

    func collectedStdout() -> String { stdoutText }

    func terminate() {
        terminated = true
        if exitsOnTerminate { exit(code: 15) }
    }

    func forceKill() {
        forceKilled = true
        if exitsOnForceKill { exit(code: 9) }
    }

    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        return exited
    }
}

/// Factory handing out pre-scripted mock processes in order; records how many were made.
final class MockShortcutProcessFactory: ShortcutProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [MockShortcutProcess]
    private(set) var made: [MockShortcutProcess] = []
    var binaryExists = true

    init(_ processes: [MockShortcutProcess]) { self.queue = processes }

    func makeProcess(arguments: [String]) -> ShortcutProcessHandle {
        lock.lock(); defer { lock.unlock() }
        let p = queue.isEmpty ? MockShortcutProcess() : queue.removeFirst()
        made.append(p)
        return p
    }
    func shortcutsBinaryExists() -> Bool { binaryExists }
}

/// Test-controlled sleeper: every `sleep` parks on a continuation the test fires (or task
/// cancellation throws it out — required, or the runner's task group could never finish).
actor MockSleeper: AsyncSleeping {

    struct Request { let id: Int; let seconds: TimeInterval }

    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var requestWaiters: [CheckedContinuation<Request, Never>] = []
    private var unclaimedRequests: [Request] = []

    func sleep(seconds: TimeInterval) async throws {
        let id = nextID
        nextID += 1
        let request = Request(id: id, seconds: seconds)
        if let waiter = requestWaiters.first {
            requestWaiters.removeFirst()
            waiter.resume(returning: request)
        } else {
            unclaimedRequests.append(request)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    pending[id] = c
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// Test side: wait until the runner requests a sleep (FIFO).
    func nextRequest() async -> Request {
        if !unclaimedRequests.isEmpty { return unclaimedRequests.removeFirst() }
        return await withCheckedContinuation { requestWaiters.append($0) }
    }

    /// Test side: make a parked sleep return normally (the "time elapsed" signal).
    func fire(_ request: Request) {
        pending.removeValue(forKey: request.id)?.resume()
    }

    private func cancel(id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
