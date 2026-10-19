import Foundation
import Darwin

/// Sprint 4.5 #19 / audit A4 — the per-app energy INSTRUMENT, replacing the `/usr/bin/top -l 2` spawn.
///
/// WHY: the old snapshot cost **2.30 s wall / 1.29 s CPU** per Details open — 25× the next-largest item
/// in the app and more CPU than 18 minutes of the app sitting idle. An energy monitor that burns that
/// much energy to measure energy is the exact self-defeat this feature is built against. This sampler
/// costs **5.2–6.4 ms CPU for the delta PAIR** (measured over 20 pairs, three runs, M4 Max, ~1,090 pids,
/// CLOCK_PROCESS_CPUTIME_ID) — the same answer for roughly 1/220th of the CPU.
///
/// HOW: two `proc_pid_rusage(pid, RUSAGE_INFO_V6, …)` sweeps over `proc_listpids`, separated by a short
/// interval; each process's energy is the DELTA of `ri_energy_nj` across the window. Both calls are
/// PUBLIC API (`<libproc.h>`, `<sys/resource.h>`, 10.9+); `RUSAGE_INFO_CURRENT == RUSAGE_INFO_V6` on this
/// OS, and `ri_energy_nj` is confirmed populated on M4 Max (807–814 of ~1,090 pids non-zero) — the open
/// empirical question left by research-05 line 84, now settled by measurement.
///
/// ⚠️ CALIBRATION: `ri_energy_nj` is documented as nanojoules but is NOT a calibrated meter Apple
/// blesses for cross-process absolute claims (research-05: "don't trust as joules"). It is used here
/// ONLY as a RELATIVE ranking key — the same honest framing as the `top` POWER column it replaces. The
/// app's one true watt figure remains #20's system charge/discharge. Never present these as watts.
///
/// ⚠️ COVERAGE: an unprivileged process may read `proc_pid_rusage` only for processes it owns. On this
/// machine 274 of 1,088 pids return EPERM — including **WindowServer** (uid 88), which ranked #4 by
/// `top`'s POWER column. That gap is REAL and is not papered over: every sweep carries a
/// `ProcessEnergyCoverage` census, and `EnergyImpactSource.coverageNote()` turns it into a caption the
/// UI must show. `ri_penergy_nj` (the apparent P-core split) is deliberately NOT used: its meaning is
/// inferred from behaviour, not documented, and it buys the ranking nothing.

/// One sweep: pid → cumulative `ri_energy_nj`, plus the census of what we were allowed to read.
struct ProcessEnergySample: Sendable, Equatable {
    /// Cumulative process-lifetime energy in nanojoules, for the pids we could read. UInt64 exactly as
    /// the kernel reports it — the delta arithmetic stays integral, no float drift before ranking.
    let energyNanojoules: [Int: UInt64]
    let coverage: ProcessEnergyCoverage

    /// A sweep that read NOTHING is a failure, not an answer (the caller keeps its cached rows).
    var readNothing: Bool { energyNanojoules.isEmpty }

    static let empty = ProcessEnergySample(energyNanojoules: [:], coverage: .none)
}

/// How much of the machine a ranking actually saw. `denied` is EPERM (another uid — the honesty gap);
/// `vanished` is ESRCH (the process exited between the pid listing and the read — not a coverage hole,
/// just a race, so it must NOT inflate the "couldn't read" number the user is shown).
struct ProcessEnergyCoverage: Sendable, Equatable {
    let listed: Int
    let readable: Int
    let denied: Int
    let vanished: Int

    /// True when at least one process was withheld from us by ownership — i.e. the ranking is a view of
    /// the user's own processes, not of the machine. On any normal macOS install this is ALWAYS true.
    var isPartial: Bool { denied > 0 }

    static let none = ProcessEnergyCoverage(listed: 0, readable: 0, denied: 0, vanished: 0)
}

/// The injectable boundary, mirroring `ProcessProbing`: a mock in tests, `LiveProcessEnergySampler` in
/// production. `commandName` is the replacement for `top`'s command column — and it is strictly better,
/// because `proc_pidpath` is NOT truncated to ~15 characters, so helper coalescing finally works on
/// names like "Google Chrome Helper (Renderer)" (the old FLAG in `coalesceKey` is retired).
protocol ProcessEnergySampling: Sendable {
    func sample() async -> ProcessEnergySample
    func commandName(forPID pid: Int) -> String?
}

/// Production boundary adapter. Stateless → trivially `Sendable`.
struct LiveProcessEnergySampler: ProcessEnergySampling {

    /// The sweep is ~2.7 ms of straight-line syscalls; it still runs OFF the main actor so a Details
    /// open never stutters (same discipline as `ProcessProbe`, which parks all its work on a global
    /// queue). Everything crossing back is a value type.
    func sample() async -> ProcessEnergySample {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcessEnergySample, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.sweep())
            }
        }
    }

    func commandName(forPID pid: Int) -> String? { Self.pidPathLastComponent(pid_t(pid)) }

    // MARK: - libproc

    static func sweep() -> ProcessEnergySample {
        let pids = listPIDs()
        var energies: [Int: UInt64] = [:]
        energies.reserveCapacity(pids.count)
        var denied = 0
        var vanished = 0
        for pid in pids {
            switch readEnergyNanojoules(pid) {
            case .read(let nj):  energies[Int(pid)] = nj
            case .denied:        denied += 1
            case .vanished:      vanished += 1
            }
        }
        return ProcessEnergySample(
            energyNanojoules: energies,
            coverage: ProcessEnergyCoverage(listed: pids.count, readable: energies.count,
                                            denied: denied, vanished: vanished))
    }

    private enum PIDEnergyRead {
        case read(UInt64)
        /// EPERM — owned by another uid. THE coverage gap (WindowServer and friends).
        case denied
        /// ESRCH or any other failure — the pid died under us, or an unknown transient. Not a gap.
        case vanished
    }

    private static func readEnergyNanojoules(_ pid: pid_t) -> PIDEnergyRead {
        var info = rusage_info_v6()
        // `rusage_info_t` is `void *`; the documented call shape is a pointer to the flavor's struct
        // reinterpreted as that opaque handle. This is the standard (and only) way to spell it in Swift.
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { handle in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, handle)
            }
        }
        guard rc != 0 else { return .read(info.ri_energy_nj) }
        return errno == EPERM ? .denied : .vanished
    }

    /// Every pid on the machine. Sized from a probing call, then re-read with slack because the process
    /// table can grow between the two calls; a short read is fine (we simply see fewer pids that tick).
    private static func listPIDs() -> [pid_t] {
        let sizingBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard sizingBytes > 0 else { return [] }
        let stride = MemoryLayout<pid_t>.stride
        var buffer = [pid_t](repeating: 0, count: Int(sizingBytes) / stride + 128)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(buffer.count * stride))
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / stride).filter { $0 > 0 }
    }

    /// Executable name for a pid — untruncated, unlike `top`'s command column. nil when the pid is gone
    /// or unreadable (→ the caller's "PID n" never-blank fallback).
    private static func pidPathLastComponent(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a macro (4 * MAXPATHLEN) and so is not imported into Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(written)), as: UTF8.self)
        guard let last = path.split(separator: "/").last.map(String.init), !last.isEmpty else { return nil }
        return last
    }
}

/// PURE delta arithmetic over two sweeps — the whole ranking key, host-app- and syscall-free so every
/// edge case (exit, launch, counter regression) is a unit test rather than a hope.
enum ProcessEnergyDelta {

    /// Energy accrued BETWEEN the two sweeps, in nanojoules, keyed by pid. Zero-delta pids are dropped
    /// (an idle process is not a row). The four cases, all deliberate:
    ///
    /// - **in both, later ≥ earlier** → `later - earlier`. The normal case.
    /// - **in both, later < earlier** → `0`. `ri_energy_nj` is monotonic within one process lifetime, so
    ///   a decrease means the pid was REUSED by a new process (or, theoretically, a UInt64 wrap — which
    ///   at ~1e9 nJ/s would take ~584 years). Either way the difference is meaningless: we contribute
    ///   nothing rather than a negative, an underflow trap, or a fabricated 18-exajoule row.
    /// - **in `later` only** → `later`, in full. It could not have been readable-and-absent from the
    ///   first sweep (ownership does not change), so it started inside the window and all of its energy
    ///   was spent inside the window. This is what catches short-lived spikes `top` also caught.
    /// - **in `earlier` only** → dropped. It exited inside the window; whatever it spent is unattributable
    ///   to a process the user could act on, and inventing a final value would be a guess.
    static func nanojoules(from earlier: ProcessEnergySample,
                           to later: ProcessEnergySample) -> [Int: UInt64] {
        var out: [Int: UInt64] = [:]
        out.reserveCapacity(later.energyNanojoules.count)
        for (pid, now) in later.energyNanojoules {
            let delta: UInt64
            if let before = earlier.energyNanojoules[pid] {
                delta = now >= before ? now - before : 0
            } else {
                delta = now
            }
            if delta > 0 { out[pid] = delta }
        }
        return out
    }

    /// The top `count` pids by delta, descending — pid ascending as the tie-break so the order is
    /// deterministic (dictionary iteration order is not). Millijoules, the unit the rows carry.
    static func ranked(_ deltas: [Int: UInt64], count: Int) -> [(pid: Int, millijoules: Double)] {
        deltas.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(count)
            .map { (pid: $0.key, millijoules: Double($0.value) / 1_000_000) }
    }
}
