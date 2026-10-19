import Foundation
import Combine
import AppKit

/// Sprint 4.5 (#19): per-app RELATIVE energy impact, fetched on the Details page only (NO background
/// polling: a draining energy monitor is self-defeating, the irony is the whole point). Cached rows
/// render instantly while a fresh sample runs (`isRefreshing`); the section HIDES when nothing ranks.
///
/// AUDIT A4 (this rewrite): the instrument is no longer `/usr/bin/top -l 2` (2.30 s wall / 1.29 s CPU
/// per open — the single most expensive operation in the app) but two `proc_pid_rusage` sweeps
/// (~5.5 ms CPU for the pair). See `ProcessEnergySampler.swift` for the mechanism, the calibration
/// caveat, and the coverage gap. The `top` parser is DELETED, not kept as a fallback: its POWER column
/// is an undocumented unitless composite of questionable meaning on Apple Silicon, and its parser failed
/// SILENTLY on any format change (a missing header returned [] — the section just vanished with no
/// signal). A fallback whose failure mode is invisible is not a safety net.

/// Production pid → name: NSRunningApplication gives the full, untruncated localized app name when the
/// pid belongs to a real app (helpers/daemons usually don't resolve → executable-name fallback).
struct RunningAppNameResolver: AppNameResolving {
    func localizedName(forPID pid: Int) -> String? {
        NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }
}

/// pid → friendly app name seam (NSRunningApplication in production, a dictionary in tests).
protocol AppNameResolving {
    func localizedName(forPID pid: Int) -> String?
}

/// One display row: a friendly `name` + a `fraction` in (0, 1] relative to the top entry in this
/// snapshot. `energyMillijoules` is retained for tests/debug only — the VIEW shows the relative bar or
/// percentage, NEVER an absolute energy number (see the calibration caveat in ProcessEnergySampler).
struct EnergyImpactRow: Equatable, Identifiable {
    let pid: Int
    let name: String
    let energyMillijoules: Double
    let fraction: Double
    var id: Int { pid }
}

/// PURE naming + ranking pipeline (was `EnergyImpactParser`, whose `parse` died with the `top` path).
enum EnergyImpactRanking {

    /// Friendly name for a row: the OS-resolved app name (full, untruncated) when available, else the
    /// executable name, else "PID <n>" — NEVER blank (spec sec 2).
    static func resolveName(pid: Int, command: String, resolver: (Int) -> String?) -> String {
        if let n = resolver(pid)?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        let c = command.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? "PID \(pid)" : c
    }

    /// Helper-coalesce key: "<App> Helper (Renderer)" → "<App>", so an app's helper processes fold under
    /// it (mirrors Activity Monitor's per-APP energy view). Under `top` this was unreliable because the
    /// command column truncated to ~15 chars ("Brave Browser He") and carried no " Helper" substring;
    /// `proc_pidpath` is untruncated, so coalescing now works on unresolved helpers too.
    static func coalesceKey(_ name: String) -> String {
        if let r = name.range(of: " Helper") { return String(name[..<r.lowerBound]) }
        return name
    }

    /// Coalesce helpers into their parent (summing energy — an app's footprint = app + its helpers),
    /// take the top `top` by summed energy, and normalize to the top entry → relative fractions in
    /// (0, 1]. All-zero or empty input → [] (the section then hides). The representative pid is the
    /// highest-energy member (a stable Identifiable id).
    static func rank(_ named: [(pid: Int, name: String, energyMillijoules: Double)],
                     top: Int = 5) -> [EnergyImpactRow] {
        var summed: [String: (pid: Int, name: String, energy: Double)] = [:]
        for item in named {
            let key = coalesceKey(item.name)
            if let cur = summed[key] {
                summed[key] = (pid: item.energyMillijoules > cur.energy ? item.pid : cur.pid,
                               name: key, energy: cur.energy + item.energyMillijoules)
            } else {
                summed[key] = (pid: item.pid, name: key, energy: item.energyMillijoules)
            }
        }
        // Sort by energy desc, then name for a stable order on ties (dictionary order is undefined).
        let ordered = summed.values.sorted { $0.energy != $1.energy ? $0.energy > $1.energy : $0.name < $1.name }
            .prefix(top)
        guard let maxEnergy = ordered.first?.energy, maxEnergy > 0 else { return [] }
        return ordered.map { EnergyImpactRow(pid: $0.pid, name: $0.name, energyMillijoules: $0.energy,
                                             fraction: $0.energy / maxEnergy) }
    }
}

@MainActor
final class EnergyImpactSource: ObservableObject {
    @Published private(set) var apps: [EnergyImpactRow] = []
    /// #30 Now "Who spent it": the wider ranking (top `fetchCount`) so the strip can show the top GUI APPS —
    /// the ones with real icons — while daemons stay in the remainder. Same sample, same shares.
    @Published private(set) var candidates: [EnergyImpactRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastFetch: Int?
    /// #30 §14-D7: Σ of every readable process's delta in the last sample (millijoules), so a row's
    /// SHARE can be stated honestly — `row.energyMillijoules / totalMillijoules` — instead of the
    /// top-relative `fraction`. 0 until the first successful sweep.
    @Published private(set) var totalMillijoules: Double = 0
    /// Audit A4 honesty surface: how much of the machine the last successful ranking actually saw. An
    /// unprivileged `proc_pid_rusage` cannot read another uid's processes, so this is ALWAYS partial on
    /// a real machine — see `coverageNote()`.
    @Published private(set) var coverage: ProcessEnergyCoverage = .none

    private let sampler: any ProcessEnergySampling
    private let nameResolver: any AppNameResolving
    private let intervalMilliseconds: Int
    private let now: () -> Int

    static let displayCount = 5      // top-N apps shown
    static let fetchCount = 12       // a few more than displayCount → coalescing headroom
    /// The window the delta is measured over. `top -l 2` imposed ~2 s of wall time for one usable
    /// sample; here the window is a free parameter, so it is set by what makes a stable ranking rather
    /// than by what the tool costs. 500 ms is long enough to separate a busy app from an idle one and
    /// short enough that the Details page settles in half a second instead of two and a half.
    static let defaultIntervalMilliseconds = 500

    init(sampler: any ProcessEnergySampling = LiveProcessEnergySampler(),
         nameResolver: any AppNameResolving = RunningAppNameResolver(),
         intervalMilliseconds: Int = EnergyImpactSource.defaultIntervalMilliseconds,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.sampler = sampler
        self.nameResolver = nameResolver
        self.intervalMilliseconds = intervalMilliseconds
        self.now = now
    }

    /// Two sweeps separated by `intervalMilliseconds`; each process's score is its `ri_energy_nj` delta.
    /// Cached rows stay visible (`isRefreshing = true`) while it runs. A sweep that read NOTHING is a
    /// hard failure → keep the last good list (4.H precedent: a best-effort feature never flickers to
    /// broken). A successful sweep with no moving process clears to [] → the section hides.
    ///
    /// NOTE — the instrument is no longer excluded from its own measurement. The old code dropped every
    /// process named "top" because the measurement spawned one (it ranked 5th in the captured fixture),
    /// which also hid a user's own interactive `top`. There is no child process now: the cost lands on
    /// THIS app's pid, which is a real, user-visible process and stays in the ranking. Showing our own
    /// footprint is the honest option and, at ~5 ms, it will never rank.
    func fetch() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let t = now()

        let first = await sampler.sample()
        try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
        let second = await sampler.sample()
        guard !first.readNothing, !second.readNothing else { return }   // keep cached rows on failure

        let deltas = ProcessEnergyDelta.nanojoules(from: first, to: second)
        // Names are resolved for the top `fetchCount` only — never for the ~800 pids we sampled.
        let resolver = nameResolver
        let commands = sampler
        let named = ProcessEnergyDelta.ranked(deltas, count: Self.fetchCount).map { entry in
            (pid: entry.pid,
             name: EnergyImpactRanking.resolveName(
                pid: entry.pid,
                command: commands.commandName(forPID: entry.pid) ?? "",
                resolver: { resolver.localizedName(forPID: $0) }),
             energyMillijoules: entry.millijoules)
        }
        apps = EnergyImpactRanking.rank(named, top: Self.displayCount)
        candidates = EnergyImpactRanking.rank(named, top: Self.fetchCount)
        totalMillijoules = deltas.values.reduce(0.0) { $0 + Double($1) / 1_000_000 }
        coverage = second.coverage
        lastFetch = t
    }

    /// B-arc B4 Option A, the unbuilt clause. `energySectionChoice` makes the helper's SUSTAINED ranking
    /// primary whenever it delivers, so on a helper-approved machine this snapshot is computed and then
    /// thrown away. Skip it in exactly that case.
    ///
    /// The inputs are the sustained source's state as of the moment Details appears — i.e. its PREVIOUS
    /// delivery, because `SustainedEnergySource.refresh()` returns before its XPC reply lands. That is
    /// the correct read: it is also the state the first frame renders from. The residual risk is narrow
    /// and stated plainly — if sustained was delivering last time and FAILS this time, the snapshot rows
    /// on screen are the cached ones rather than fresh (or, on a cold first-ever Details open after a
    /// helper failure, absent). At ~5 ms a sweep this saving is small; it is taken because the ratified
    /// decision says the discarded work should not run, not because the cost is now material.
    nonisolated static func snapshotIsNeeded(sustainedAvailable: Bool, sustainedHasEntries: Bool) -> Bool {
        !(sustainedAvailable && sustainedHasEntries)
    }

    func fetchIfNeeded(sustainedAvailable: Bool, sustainedHasEntries: Bool) async {
        guard Self.snapshotIsNeeded(sustainedAvailable: sustainedAvailable,
                                    sustainedHasEntries: sustainedHasEntries) else { return }
        await fetch()
    }

    /// "as of N s/m ago" for a kept-cached snapshot (mirrors 4.H DeviceStaleness); nil when fresh
    /// (< 10 s) — honest when a failed refresh leaves older rows on screen.
    func stalenessNote() -> String? {
        guard let last = lastFetch else { return nil }
        let age = now() - last
        if age < 10 { return nil }
        if age < 60 { return "as of \(age)s ago" }
        if age < 3600 { return "as of \(age / 60)m ago" }
        return "as of \(age / 3600)h ago"
    }

    /// Audit A4 — the degraded-honesty caption for the coverage gap. `proc_pid_rusage` is refused
    /// (EPERM) for processes owned by another uid, so this ranking covers the USER's processes, not the
    /// machine's: WindowServer (uid 88) alone ranked #4 by the metric this replaced and is now invisible.
    /// The UI MUST render this whenever it is non-nil — a ranking that omits the window server while
    /// looking like a complete list is precisely the silent over-claim the project forbids. nil only in
    /// the theoretical case where every listed process was readable, and before the first fetch.
    func coverageNote() -> String? {
        guard coverage.isPartial else { return nil }
        return "Your apps only — \(coverage.denied) system processes can't be measured without admin rights"
    }
}
