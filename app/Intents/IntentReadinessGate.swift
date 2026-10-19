import Foundation

/// App-level readiness latch shared by the App Intent surfaces (sec 11): one fact, the app has finished
/// its first known-limit read or has taken its setup-failure path. The app settles it once; every intent
/// surface awaits it. Holds the per-waiter timeout machinery (the B2 cancel-before-resume fix), so a second
/// surface (Top Up, Pass 2) awaits the SAME gate instead of a duplicated copy of this concurrency code.
@MainActor
final class IntentReadinessGate {

    private let readinessTimeout: Duration
    private var readinessSettled = false
    private var readinessWaiters: [UUID: (cont: CheckedContinuation<Bool, Never>, timeout: Task<Void, Never>)] = [:]

    /// `timeout` is the bounded wait used when not yet settled. The app passes
    /// 2 * (invocationTimeout + sigkillGrace); the gate does not know about ShortcutsRunner.
    init(timeout: Duration) {
        self.readinessTimeout = timeout
    }

    /// The app calls this once the first known-limit read has completed OR the setup-failure path has been
    /// taken (sec 11). Resolves every awaiting `awaitReady`. Idempotent (one-shot latch).
    func settle() {
        guard !readinessSettled else { return }   // one-shot latch (idempotent)
        readinessSettled = true
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        // B2: cancel each waiter's timeout Task so a settled waiter's timer does not sleep out the full
        // timeout. The cancelled Task wakes, finds its id already gone (removeAll above), and does not
        // resume, so the continuation still resumes EXACTLY once.
        for (_, waiter) in waiters {
            waiter.timeout.cancel()
            waiter.cont.resume(returning: true)
        }
    }

    /// Suspend until the latch settles, bounded by `readinessTimeout`. Returns true if it settled in time,
    /// false on timeout (the honest could-not-ready). Leak-free: whichever of settle/timeout wins removes
    /// the waiter id, so the continuation resumes EXACTLY once (all @MainActor-serialized).
    func awaitReady() async -> Bool {
        if readinessSettled { return true }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let id = UUID()
            // B2: create the timeout Task FIRST so its handle exists for the stored pair; it suspends on
            // sleep immediately, so on the @MainActor it cannot run its body before the store below.
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: readinessTimeout)
                if let waiter = readinessWaiters.removeValue(forKey: id) { waiter.cont.resume(returning: false) }
            }
            readinessWaiters[id] = (cont: cont, timeout: timeout)
        }
    }
}
