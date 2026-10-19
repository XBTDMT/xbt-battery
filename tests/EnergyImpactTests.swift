import XCTest

/// Sprint 4.5 (#19) / audit A4: per-app RELATIVE energy impact, now measured with two
/// `proc_pid_rusage(RUSAGE_INFO_V6)` sweeps instead of a 2.3 s `/usr/bin/top -l 2` spawn.
///
/// Covered here: the PURE delta arithmetic (normal case, a pid that exits between samples, a pid that
/// launches between samples, a counter regression / pid reuse, idle pids), the denied-pid coverage
/// census and the honesty caption it drives, ranking + helper coalescing + never-blank naming, the
/// source's fetch wiring against a mock sampler (cache-on-failure, re-open, staleness), the B4 gating
/// clause, and an on-device smoke against the REAL sampler including its measured cost.
/// Host-app-free (the SwiftUI Energy section lives in the app-only popover, like 4.H).
final class EnergyImpactTests: XCTestCase {

    // MARK: - helpers

    private func sample(_ energies: [Int: UInt64],
                        listed: Int? = nil, denied: Int = 0, vanished: Int = 0) -> ProcessEnergySample {
        ProcessEnergySample(
            energyNanojoules: energies,
            coverage: ProcessEnergyCoverage(listed: listed ?? (energies.count + denied + vanished),
                                            readable: energies.count, denied: denied, vanished: vanished))
    }

    private static let mJ: UInt64 = 1_000_000   // nanojoules per millijoule

    // MARK: - PURE delta arithmetic

    func testDeltaIsTheDifferenceBetweenSweeps() {
        let a = sample([100: 10 * Self.mJ, 200: 5 * Self.mJ])
        let b = sample([100: 42 * Self.mJ, 200: 6 * Self.mJ])
        let d = ProcessEnergyDelta.nanojoules(from: a, to: b)
        XCTAssertEqual(d, [100: 32 * Self.mJ, 200: 1 * Self.mJ],
                       "the score is energy accrued IN the window, not lifetime energy")
    }

    func testIdleProcessesAreDroppedNotRankedAtZero() {
        let a = sample([1: 7, 2: 7])
        let b = sample([1: 9, 2: 7])
        XCTAssertEqual(ProcessEnergyDelta.nanojoules(from: a, to: b), [1: 2],
                       "a process that burned nothing is not a row")
    }

    func testPIDThatExitsBetweenSamplesIsDropped() {
        let a = sample([1: 100, 2: 500])          // pid 2 is alive in the first sweep …
        let b = sample([1: 160])                  // … and gone in the second
        let d = ProcessEnergyDelta.nanojoules(from: a, to: b)
        XCTAssertEqual(d, [1: 60])
        XCTAssertNil(d[2], "no invented final value for a process that exited under us")
    }

    func testPIDThatLaunchesBetweenSamplesCountsItsWholeValue() {
        // Ownership cannot change, so a pid readable in the second sweep but absent from the first must
        // have STARTED inside the window — all of its energy was spent inside the window.
        let a = sample([1: 100])
        let b = sample([1: 100, 99: 4 * Self.mJ])
        XCTAssertEqual(ProcessEnergyDelta.nanojoules(from: a, to: b), [99: 4 * Self.mJ])
    }

    func testCounterRegressionFromPIDReuseOrWrapContributesZeroNotGarbage() {
        // ri_energy_nj is monotonic within one process lifetime; a DECREASE means the pid was recycled
        // (or, at ~1e9 nJ/s, a UInt64 wrap ~584 years out). Naive `now - before` would either trap on
        // unsigned underflow or, wrapped, fabricate an ~18-exajoule row that would own the whole bar.
        let a = sample([7: 900 * Self.mJ, 8: 5])
        let b = sample([7: 3 * Self.mJ, 8: 9])
        let d = ProcessEnergyDelta.nanojoules(from: a, to: b)
        XCTAssertNil(d[7], "a regressed counter contributes nothing — never a negative, trap, or wrap")
        XCTAssertEqual(d[8], 4, "and it does not poison the other pids")

        let wrapA = sample([7: UInt64.max - 5])
        let wrapB = sample([7: 3])
        XCTAssertNil(ProcessEnergyDelta.nanojoules(from: wrapA, to: wrapB)[7])
    }

    func testEmptySweepsYieldNoDeltas() {
        XCTAssertTrue(ProcessEnergyDelta.nanojoules(from: sample([:]), to: sample([:])).isEmpty)
        XCTAssertTrue(ProcessEnergyDelta.nanojoules(from: sample([1: 5]), to: sample([:])).isEmpty)
    }

    func testRankedTakesTopNDescendingWithDeterministicTieBreak() {
        let deltas: [Int: UInt64] = [1: 30 * Self.mJ, 2: 10 * Self.mJ, 3: 30 * Self.mJ, 4: 1 * Self.mJ]
        let top = ProcessEnergyDelta.ranked(deltas, count: 3)
        XCTAssertEqual(top.map(\.pid), [1, 3, 2], "desc by energy, pid asc on a tie (dict order is not)")
        XCTAssertEqual(top[0].millijoules, 30, accuracy: 1e-9, "nanojoules → millijoules")
        XCTAssertEqual(ProcessEnergyDelta.ranked(deltas, count: 99).count, 4)
        XCTAssertTrue(ProcessEnergyDelta.ranked([:], count: 5).isEmpty)
    }

    // MARK: - coverage census (the denied-pid gap)

    func testCoverageDistinguishesDeniedFromVanished() {
        // EPERM (another uid — the real gap the user must be told about) vs ESRCH (the pid died between
        // the listing and the read — a race, NOT a coverage hole; it must not inflate the caption).
        let partial = ProcessEnergyCoverage(listed: 100, readable: 70, denied: 28, vanished: 2)
        XCTAssertTrue(partial.isPartial)
        let clean = ProcessEnergyCoverage(listed: 100, readable: 98, denied: 0, vanished: 2)
        XCTAssertFalse(clean.isPartial, "a pid that merely exited is not a process we were refused")
        XCTAssertFalse(ProcessEnergyCoverage.none.isPartial)
    }

    @MainActor
    func testDeniedPIDsAreCountedAndSurfacedNeverSilentlyDropped() async {
        // 274 of 1,088 pids are EPERM on this machine — WindowServer (uid 88) among them, which ranked
        // #4 by the metric this replaced. The ranking is therefore the USER's processes, and says so.
        let sampler = MockEnergySampler([
            sample([10: 0, 11: 0], listed: 1000, denied: 998),
            sample([10: 50 * Self.mJ, 11: 5 * Self.mJ], listed: 1000, denied: 998)])
        let src = EnergyImpactSource(sampler: sampler, nameResolver: DictNameResolver([:]),
                                     intervalMilliseconds: 0, now: { 1 })
        await src.fetch()
        XCTAssertEqual(src.coverage.denied, 998)
        XCTAssertEqual(src.coverage.readable, 2)
        XCTAssertTrue(src.coverage.isPartial)
        XCTAssertEqual(src.coverageNote(),
                       "Your apps only — 998 system processes can't be measured without admin rights",
                       "the UI is handed a caption; the list never implies it saw the whole machine")
        XCTAssertEqual(src.apps.count, 2, "the readable processes still rank normally")
    }

    @MainActor
    func testNoCoverageNoteBeforeFirstFetchOrWhenNothingWasDenied() async {
        let src = EnergyImpactSource(sampler: MockEnergySampler([]), nameResolver: DictNameResolver([:]),
                                     intervalMilliseconds: 0, now: { 1 })
        XCTAssertNil(src.coverageNote(), "no claim at all before the first sample")
        let full = MockEnergySampler([sample([1: 0]), sample([1: 9 * Self.mJ])])
        let clean = EnergyImpactSource(sampler: full, nameResolver: DictNameResolver([:]),
                                       intervalMilliseconds: 0, now: { 1 })
        await clean.fetch()
        XCTAssertNil(clean.coverageNote(), "nothing withheld → nothing to disclose")
    }

    // MARK: - pid → name resolution (never blank)

    func testResolveNameFallbacks() {
        XCTAssertEqual(EnergyImpactRanking.resolveName(pid: 1, command: "Safari", resolver: { _ in nil }),
                       "Safari", "unresolvable pid → the executable name")
        XCTAssertEqual(EnergyImpactRanking.resolveName(pid: 1, command: "Brave Browser Helper",
                                                       resolver: { _ in "Brave Browser" }),
                       "Brave Browser", "the resolver provides the full localized name")
        XCTAssertEqual(EnergyImpactRanking.resolveName(pid: 42, command: "", resolver: { _ in nil }),
                       "PID 42", "no name + no command → never blank")
    }

    // MARK: - normalization + helper coalescing

    func testNormalizationRelativeToTopEntry() {
        let rows = EnergyImpactRanking.rank([(1, "A", 100), (2, "B", 50), (3, "C", 25)])
        XCTAssertEqual(rows.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(rows[0].fraction, 1.0, accuracy: 1e-9, "top entry = full bar")
        XCTAssertEqual(rows[1].fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rows[2].fraction, 0.25, accuracy: 1e-9)
    }

    func testHelperCoalescing() {
        XCTAssertEqual(EnergyImpactRanking.coalesceKey("Google Chrome Helper (Renderer)"), "Google Chrome")
        XCTAssertEqual(EnergyImpactRanking.coalesceKey("WindowServer"), "WindowServer")
        let rows = EnergyImpactRanking.rank([
            (1, "Google Chrome", 10), (2, "Google Chrome Helper (GPU)", 5),
            (3, "Google Chrome Helper (Renderer)", 3), (4, "WindowServer", 20)])
        XCTAssertEqual(rows.count, 2, "the 3 Chrome rows fold into one")
        XCTAssertEqual(rows.first?.name, "WindowServer")
        let chrome = rows.first { $0.name == "Google Chrome" }
        XCTAssertEqual(chrome?.energyMillijoules, 18, "10 + 5 + 3 summed under the parent")
    }

    func testRankCapsAtTopNAndZeroInputHides() {
        let many = (1...8).map { (pid: $0, name: "P\($0)", energyMillijoules: Double(100 - $0)) }
        XCTAssertEqual(EnergyImpactRanking.rank(many, top: 5).count, 5)
        XCTAssertTrue(EnergyImpactRanking.rank([]).isEmpty)
        XCTAssertTrue(EnergyImpactRanking.rank([(1, "A", 0), (2, "B", 0)]).isEmpty,
                      "an all-zero window → no bars → the section hides")
    }

    // MARK: - the source (mock sampler), MainActor

    @MainActor
    func testSourceFetchHappyPath() async {
        let sampler = MockEnergySampler(
            [sample([661: 1 * Self.mJ, 663: 1 * Self.mJ, 900: 0], denied: 40),
             sample([661: 51 * Self.mJ, 663: 11 * Self.mJ, 900: 3 * Self.mJ], denied: 40)],
            commands: [661: "Xcode", 663: "MenuBarAgent", 900: "mdworker_shared"])
        let src = EnergyImpactSource(sampler: sampler,
                                     nameResolver: DictNameResolver([663: "Menu Bar Agent Pro"]),
                                     intervalMilliseconds: 0, now: { 1000 })
        await src.fetch()
        XCTAssertEqual(sampler.sweepCount, 2, "a delta needs exactly two sweeps — no more, no fewer")
        XCTAssertEqual(src.apps.map(\.name), ["Xcode", "Menu Bar Agent Pro", "mdworker_shared"])
        XCTAssertEqual(src.apps[0].energyMillijoules, 50, accuracy: 1e-9)
        XCTAssertEqual(src.apps[0].fraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(src.apps[1].fraction, 10.0 / 50.0, accuracy: 1e-9)
        XCTAssertFalse(src.isRefreshing)
        XCTAssertEqual(src.lastFetch, 1000)
        XCTAssertEqual(sampler.namedPIDs.count, 3,
                       "names are resolved for the ranked few, never for the whole process table")
    }

    @MainActor
    func testSourceFailureKeepsCache() async {
        let sampler = MockEnergySampler([sample([1: 0]), sample([1: 9 * Self.mJ])],
                                        commands: [1: "Safari"])
        let src = EnergyImpactSource(sampler: sampler, nameResolver: DictNameResolver([:]),
                                     intervalMilliseconds: 0, now: { 1 })
        await src.fetch()
        let cached = src.apps
        XCTAssertFalse(cached.isEmpty)

        // A sweep that read NOTHING is a failure, not an answer.
        sampler.script = [sample([:]), sample([:])]
        await src.fetch()
        XCTAssertEqual(src.apps, cached, "a hard failure keeps the last good rows (4.H precedent)")
        XCTAssertFalse(src.isRefreshing)
    }

    @MainActor
    func testSourceEmptyWindowHidesTheSection() async {
        // A successful pair of sweeps in which nothing moved: honest empty, not a kept cache.
        let sampler = MockEnergySampler([sample([1: 7, 2: 7]), sample([1: 7, 2: 7])])
        let src = EnergyImpactSource(sampler: sampler, nameResolver: DictNameResolver([:]),
                                     intervalMilliseconds: 0, now: { 1 })
        await src.fetch()
        XCTAssertTrue(src.apps.isEmpty, "no process burned anything → no section")
        XCTAssertEqual(src.lastFetch, 1, "but it WAS a successful measurement")
    }

    /// B-arc B4: the Details push triggers this fetch, so the surface is entered, left and re-entered.
    /// The re-open must serve the cached rows (no empty-state flash) AND take a fresh sample.
    @MainActor
    func testSourceReFetchOnReOpenServesCacheThenRefreshes() async {
        let sampler = MockEnergySampler([sample([1: 0]), sample([1: 9 * Self.mJ])], commands: [1: "Safari"])
        let src = EnergyImpactSource(sampler: sampler, nameResolver: DictNameResolver([:]),
                                     intervalMilliseconds: 0, now: { 1000 })
        await src.fetch()
        let firstRows = src.apps
        XCTAssertFalse(firstRows.isEmpty)
        XCTAssertFalse(src.isRefreshing, "settled once the first fetch lands")
        XCTAssertEqual(src.apps, firstRows, "closing the page must not clear the rows")

        sampler.script = [sample([1: 9 * Self.mJ]), sample([1: 20 * Self.mJ])]
        await src.fetch()
        XCTAssertFalse(src.apps.isEmpty, "never empties across the refresh")
        XCTAssertEqual(sampler.sweepCount, 4, "a re-open takes a genuinely fresh pair of sweeps")
    }

    @MainActor
    func testSourceStaleness() async {
        var clock = 3000
        let sampler = MockEnergySampler([sample([1: 0]), sample([1: 9 * Self.mJ])])
        let src = EnergyImpactSource(sampler: sampler, nameResolver: DictNameResolver([:]),
                                     intervalMilliseconds: 0, now: { clock })
        await src.fetch()
        clock = 3045
        XCTAssertEqual(src.stalenessNote(), "as of 45s ago")
        clock = 3005
        XCTAssertNil(src.stalenessNote(), "fresh (<10s) → no note")
    }

    // MARK: - B4 Option A: skip the snapshot when sustained is primary

    func testSnapshotIsNeededTruthTable() {
        // energySectionChoice renders the snapshot in every case EXCEPT "sustained delivering rows".
        XCTAssertFalse(EnergyImpactSource.snapshotIsNeeded(sustainedAvailable: true, sustainedHasEntries: true),
                       "sustained is primary → the snapshot would be computed and discarded")
        XCTAssertTrue(EnergyImpactSource.snapshotIsNeeded(sustainedAvailable: true, sustainedHasEntries: false),
                      "approved but idle helper → the snapshot IS the section")
        XCTAssertTrue(EnergyImpactSource.snapshotIsNeeded(sustainedAvailable: false, sustainedHasEntries: false))
        XCTAssertTrue(EnergyImpactSource.snapshotIsNeeded(sustainedAvailable: false, sustainedHasEntries: true),
                      "unavailable helper's stale rows are not rendered → still fetch")
    }

    @MainActor
    func testFetchIfNeededSkipsTheSamplerEntirelyWhenSustainedIsPrimary() async {
        let sampler = MockEnergySampler([sample([1: 0]), sample([1: 9 * Self.mJ])])
        let src = EnergyImpactSource(sampler: sampler, nameResolver: DictNameResolver([:]),
                                     intervalMilliseconds: 0, now: { 1 })
        await src.fetchIfNeeded(sustainedAvailable: true, sustainedHasEntries: true)
        XCTAssertEqual(sampler.sweepCount, 0, "not one syscall for a ranking nobody will see")
        XCTAssertTrue(src.apps.isEmpty)
        XCTAssertNil(src.lastFetch, "and no fake freshness stamp for a measurement never taken")

        await src.fetchIfNeeded(sustainedAvailable: false, sustainedHasEntries: false)
        XCTAssertEqual(sampler.sweepCount, 2)
        XCTAssertFalse(src.apps.isEmpty)
    }

    // MARK: - real on-device sampler

    func testRealSweepReadsProcessesAndCountsWhatItCouldNot() async {
        let s = await LiveProcessEnergySampler().sample()
        XCTAssertGreaterThan(s.coverage.listed, 10, "the machine has processes")
        XCTAssertGreaterThan(s.coverage.readable, 0, "and we can read our own")
        XCTAssertFalse(s.readNothing)
        XCTAssertEqual(s.coverage.readable + s.coverage.denied + s.coverage.vanished, s.coverage.listed,
                       "every listed pid is accounted for in exactly one bucket")
        XCTAssertEqual(s.energyNanojoules.count, s.coverage.readable)
        // Our OWN pid is always readable, and this test burned energy — so it must be non-zero.
        XCTAssertGreaterThan(s.energyNanojoules[Int(ProcessInfo.processInfo.processIdentifier)] ?? 0, 0,
                             "ri_energy_nj is populated on this machine (research-05's open question)")
    }

    @MainActor
    func testRealFetchNormalizesAndNeverCrashes() async {
        let src = EnergyImpactSource()           // real sampler + real NSRunningApplication
        await src.fetch()
        XCTAssertLessThanOrEqual(src.apps.count, EnergyImpactSource.displayCount)
        for a in src.apps {
            XCTAssertGreaterThan(a.fraction, 0)
            XCTAssertLessThanOrEqual(a.fraction, 1.0)
            XCTAssertFalse(a.name.isEmpty, "a name is never blank")
        }
        if let top = src.apps.first { XCTAssertEqual(top.fraction, 1.0, accuracy: 1e-9) }
        XCTAssertNotNil(src.coverageNote(), "an unprivileged sweep is ALWAYS partial — and must say so")
    }

    /// The whole point of A4: the instrument must be cheap. `top -l 2 -n 12 -o power` measured 2.30 s
    /// wall / 1.29 s CPU per Details open; a sweep pair measures ~5.5 ms CPU. The bound is deliberately
    /// loose (100 ms for the pair, ~18× the measured cost) so it fails on a REGRESSION IN KIND — someone
    /// reintroducing a subprocess — and not on a busy CI machine.
    func testRealSweepPairIsMillisecondsNotSeconds() async {
        let sampler = LiveProcessEnergySampler()
        _ = await sampler.sample()                       // warm the process table
        let start = ContinuousClock.now
        _ = await sampler.sample()
        _ = await sampler.sample()
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(100),
                          "two sweeps must stay in milliseconds — never a subprocess spawn again")
    }
}

// MARK: - test doubles

/// Returns scripted sweeps in order (looping on the last one once exhausted), and records which pids the
/// source asked to NAME — the assertion that we do not resolve names for ~800 processes.
/// `ProcessEnergySampling` is Sendable; the tests drive it serially from the MainActor, so @unchecked
/// is safe here (same contract as the old MockEnergyProbe).
private final class MockEnergySampler: ProcessEnergySampling, @unchecked Sendable {
    var script: [ProcessEnergySample]
    private(set) var sweepCount = 0
    private(set) var namedPIDs: [Int] = []
    private let commands: [Int: String]

    init(_ script: [ProcessEnergySample], commands: [Int: String] = [:]) {
        self.script = script
        self.commands = commands
    }

    func sample() async -> ProcessEnergySample {
        defer { sweepCount += 1 }
        guard !script.isEmpty else { return .empty }
        return script[min(sweepCount % max(script.count, 1), script.count - 1)]
    }

    func commandName(forPID pid: Int) -> String? {
        namedPIDs.append(pid)
        return commands[pid]
    }
}

private struct DictNameResolver: AppNameResolving {
    let map: [Int: String]
    init(_ map: [Int: String]) { self.map = map }
    func localizedName(forPID pid: Int) -> String? { map[pid] }
}
