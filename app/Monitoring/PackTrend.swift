import Foundation

/// #BOLT-TREND (owner ruling 2026-09-09 night): "the bolt goes on the second power is coming in; if power
/// in is less than the draw it gets the orange bolt; if more, the natural build we have."
///
/// WHY A TREND. On macOS 27.0 the AppleSmartBattery record refreshes only at each %-step (~50 s). Each
/// refresh publishes a ~1 s frame (IsCharging=Yes, +3.7 A, NCR=0) and then a frame (IsCharging=No,
/// −2 A, NCR=0x2000) that sits unchanged until the next step — while the pack is genuinely gaining
/// ~1 %/min (measured 2026-09-09 22:48–22:50: RemainingCapacity 1421 → 1643 mAh in 3 min; the app's own
/// history shows 21 one-second "charging" bursts per hour; re-measured 2026-09-14: 62 → 63 %, 3323 →
/// 3375 mAh in a minute with `Amperage` −619 / −1559 mA). So the flag and the sampled current say
/// "draining" for ~98 % of a climb. The percentage (and raw mAh) trend is the honest "power in > draw"
/// signal; the sampled current is honest only for "power in < draw" once the trend says NOT rising.
///
/// #POPOVER-TREND (2026-09-14) — HOW THE VERDICT HOLDS. Pure and tested; `push` one (time, percent) per
/// READ (the monitor feeds every live read). A STEP is a percent change seen with the previous read no
/// more than `window` old — a change across a longer gap (sleep, a stalled loop) was not observed as it
/// happened and makes no claim. The verdict is the direction of the last step, held for a time that
/// scales with the charge rate: 1.5 × the interval between the last two up-steps, clamped to
/// [`window`, `maxHold`], or `firstStepHold` before a second up-step gives an interval. The first version
/// held from the last LOWER READ instead, which dropped the verdict between steps for any climb slower
/// than ~1 %/min (red-team 2026-09-14: 36 flips/h at 90 s steps) and put "Not charging" back on screen.
struct PackTrend: Equatable, Sendable {
    enum Verdict: Equatable, Sendable { case rising, falling, flat }

    /// Owner pick 2026-09-09: 90 s catches a 1 %/min climb within one step. Also the longest read gap a
    /// step may span, and the shortest hold.
    static let defaultWindow: TimeInterval = 90
    /// Hold after a first up-step, before the charge rate is known — covers a 1 %/100 s climb.
    static let firstStepHold: TimeInterval = 150
    /// Ceiling on any hold: the longest a rise can stay claimed after the steps stop.
    static let maxHold: TimeInterval = 300

    let window: TimeInterval
    private var lastRead: Read?
    private var lastStep: Step?
    private var upStepInterval: TimeInterval?

    private struct Read: Equatable, Sendable { let t: TimeInterval; let pct: Int }
    private struct Step: Equatable, Sendable { let t: TimeInterval; let up: Bool }

    init(window: TimeInterval = PackTrend.defaultWindow) { self.window = window }

    mutating func push(percent: Int, at t: TimeInterval) {
        defer { lastRead = Read(t: t, pct: percent) }
        guard let prev = lastRead else { return }
        guard t >= prev.t else { reset(); return }                        // clock went backwards → start over
        guard percent != prev.pct else { return }
        guard t - prev.t <= window else { lastStep = nil; upStepInterval = nil; return }  // unobserved change
        let up = percent > prev.pct
        if up, let s = lastStep, s.up { upStepInterval = t - s.t } else { upStepInterval = nil }
        lastStep = Step(t: t, up: up)
    }

    /// Forget everything — call on a power-source change so a battery-side fall never reads as "not
    /// rising on AC" for the first window after plugging in.
    mutating func reset() { lastRead = nil; lastStep = nil; upStepInterval = nil }

    func verdict(at t: TimeInterval) -> Verdict {
        guard let s = lastStep else { return .flat }
        let hold = s.up
            ? upStepInterval.map { min(max(window, 1.5 * $0), Self.maxHold) } ?? Self.firstStepHold
            : window
        guard t - s.t <= hold else { return .flat }
        return s.up ? .rising : .falling
    }
}

/// #POPOVER-TREND (2026-09-14): the rate the pack is actually GAINING, for the popover's Time and Draw rows
/// while the sampled current is stale (see `PackTrend`).
///
/// The gauge publishes a new mAh value only at each %-step, so the rate is the least-squares slope through
/// the times each NEW value was first seen — step-aligned — never through arbitrary reads (a read 50 s
/// after a step would otherwise stretch the interval and understate the rate). Only a CONTIGUOUS RISING RUN
/// counts, because any break makes a time unalignable or mixes two different regimes (red-team 2026-09-14
/// measured 18720 mA quoted after a wake, 600 mA after a drain-then-charge, true rate 3120):
///   - a read more than `maxReadGap` after the previous one (sleep, a stalled loop) → that value is a new
///     baseline, not a step: when it appeared is unknown;
///   - a fall → the run ends; the fallen value is the baseline for the next run;
///   - a step more than `maxStepGap` after the previous step (a hold, then Top Up) → the run restarts there.
/// A rate needs ≥ 3 steps spanning ≥ `minSpan`, and anything above `maxMilliamps` (beyond what the adapter
/// can physically push) is refused. Net pack inflow, signed like the snapshot's current (+ into the pack).
struct PackInflowEstimator: Equatable, Sendable {
    /// Five steps at 1 %/min: smooth enough to quote, short enough to follow a change of rate.
    static let defaultWindow: TimeInterval = 300
    /// Just over the 60 s passive poll: a longer silence means a step may have gone unobserved.
    static let maxReadGap: TimeInterval = 90
    static let maxStepGap: TimeInterval = 240
    static let minSpan: TimeInterval = 100
    static let minSteps = 3
    /// ~100 W into an ~11 V pack. Above this the "rate" is an alignment artefact, not a charge.
    static let maxMilliamps = 10_000

    let window: TimeInterval
    private var lastRead: Read?
    private var steps: [Read] = []

    private struct Read: Equatable, Sendable { let t: TimeInterval; let mAh: Int }

    init(window: TimeInterval = PackInflowEstimator.defaultWindow) { self.window = window }

    mutating func push(mAh: Int, at t: TimeInterval) {
        defer { lastRead = Read(t: t, mAh: mAh) }
        guard let prev = lastRead, t >= prev.t, t - prev.t <= Self.maxReadGap else { steps.removeAll(); return }
        guard mAh != prev.mAh else { return }                             // unchanged value: not a step
        guard mAh > prev.mAh else { steps.removeAll(); return }           // a fall ends the rising run
        if let last = steps.last, t - last.t > Self.maxStepGap { steps.removeAll() }
        steps.append(Read(t: t, mAh: mAh))
        steps.removeAll { $0.t < t - window }
    }

    mutating func reset() { lastRead = nil; steps.removeAll() }

    func milliamps(at t: TimeInterval) -> Int? {
        let live = steps.filter { $0.t >= t - window }
        guard live.count >= Self.minSteps, let first = live.first, let last = live.last,
              last.t - first.t >= Self.minSpan, t - last.t <= Self.maxStepGap else { return nil }
        let n = Double(live.count)
        let mt = live.reduce(0) { $0 + $1.t } / n
        let my = live.reduce(0) { $0 + Double($1.mAh) } / n
        let sxy = live.reduce(0) { $0 + ($1.t - mt) * (Double($1.mAh) - my) }
        let sxx = live.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) }
        guard sxx > 0 else { return nil }
        let mA = Int((sxy / sxx * 3600).rounded())
        return mA > 0 && mA <= Self.maxMilliamps ? mA : nil
    }
}
