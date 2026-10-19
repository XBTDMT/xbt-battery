import Foundation

/// Sprint 4.D (#25): scheduling seams for the single monitor loop so the event-driven trigger,
/// the post-Set kick delay, and the debounce clock are all injectable/testable — and the
/// "no second repeating timer" rule is provable.

/// The ONE repeating poll timer (60 s passive / 10 s armed). Exactly one instance is ever active;
/// re-scheduling stops the prior. (The event source and post-Set kick do NOT use this.)
@MainActor protocol RepeatingScheduling: AnyObject {
    func startRepeating(interval: TimeInterval, _ tick: @escaping () -> Void)
    func stopRepeating()
}

@MainActor final class LiveRepeatingScheduler: RepeatingScheduling {
    private var timer: Timer?
    private var tick: (() -> Void)?
    func startRepeating(interval: TimeInterval, _ tick: @escaping () -> Void) {
        timer?.invalidate()
        self.tick = tick
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick?() }
        }
    }
    func stopRepeating() { timer?.invalidate(); timer = nil; tick = nil }
}

/// A bounded ONE-SHOT delay (the post-Set T+3 s kick). NOT a repeating timer — a single fire.
@MainActor protocol OneShotScheduling: AnyObject {
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void)
}

@MainActor final class LiveOneShotScheduler: OneShotScheduling {
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { work() }
        }
    }
}

/// Monotonic time for the 500 ms event debounce (counts through sleep; injectable for tests).
enum MonitorTime {
    static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}
