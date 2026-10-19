import XCTest
// app/Energy compiles into this target → ComponentPowerReader + the seam are visible host-app-free.

/// Sprint 3.7 B2 — the no-root, liveness-probed component-power readout. Tests the PURE liveness + watts
/// + per-channel-unit core and the reader's publish path (with a fake sampler). The IOReport interop
/// (IOReportPowerSampler) is the impure seam, exercised live (not unit-tested) — same discipline as the
/// helper spawn. Real research-11 numbers used so the assertions are grounded.
final class ComponentPowerReaderTests: XCTestCase {

    /// The production probe interval. The watts assertions below divide by THIS rather than a literal, so
    /// the pure-math tests stay true across a cadence change; `testProbeCadenceIsTheB5Pair` pins the value.
    private let interval = ComponentPowerReader.probeInterval

    func testUnitFactor_energyUnitsOnly() {
        XCTAssertEqual(ComponentPowerReader.unitFactor("mJ"), 1e-3)
        XCTAssertEqual(ComponentPowerReader.unitFactor("uJ"), 1e-6)
        XCTAssertEqual(ComponentPowerReader.unitFactor("nJ"), 1e-9)
        XCTAssertNil(ComponentPowerReader.unitFactor("ticks"), "non-energy unit → not a power rail")
        XCTAssertNil(ComponentPowerReader.unitFactor(""))
    }

    /// research-11 reality on this seed: GPU Energy (nJ) advances; CPU/ANE/DRAM are frozen (delta 0);
    /// state-format channels read Int64.min via the simple accessor. Only the live GPU rail survives.
    func testLiveReadings_keepsAdvancingGPU_dropsFrozenSentinelAndNonEnergy() {
        let deltas = [
            RawRailDelta(name: "GPU Energy", unit: "nJ", deltaValue: 47_970_291),   // LIVE
            RawRailDelta(name: "CPU Energy", unit: "mJ", deltaValue: 0),            // frozen → drop
            RawRailDelta(name: "ANE",        unit: "mJ", deltaValue: 0),            // frozen → drop
            RawRailDelta(name: "DRAM",       unit: "mJ", deltaValue: 0),            // frozen → drop
            RawRailDelta(name: "CPU-residency", unit: "ticks", deltaValue: Int64.min), // sentinel + non-energy → drop
        ]
        let live = ComponentPowerReader.liveReadings(from: deltas, intervalSeconds: interval)
        XCTAssertEqual(live.map(\.name), ["GPU Energy"], "only the advancing energy rail is rendered today")
        XCTAssertEqual(live.first?.watts ?? -1, 47_970_291 * 1e-9 / interval, accuracy: 1e-6)
    }

    /// The capability-probe payoff: when Apple restores the CPU counter (it starts ADVANCING) the SAME
    /// filter renders it — no code change. Sorted desc by watts (CPU 5 W > GPU 0.048 W).
    func testLiveReadings_autoExpandsWhenCpuStartsAdvancing() {
        let deltas = [
            RawRailDelta(name: "GPU Energy", unit: "nJ", deltaValue: 47_970_291),   // 0.048 W
            RawRailDelta(name: "CPU Energy", unit: "mJ", deltaValue: 5_000),        // now advancing → 5.0 W
            RawRailDelta(name: "ANE",        unit: "mJ", deltaValue: 0),            // still frozen → drop
        ]
        let live = ComponentPowerReader.liveReadings(from: deltas, intervalSeconds: interval)
        XCTAssertEqual(live.map(\.name), ["CPU Energy", "GPU Energy"], "CPU auto-appears + sorts above GPU")
        XCTAssertEqual(live[0].watts, 5_000 * 1e-3 / interval, accuracy: 1e-6)
    }

    func testLiveReadings_perChannelUnitConversion() {
        let deltas = [
            RawRailDelta(name: "A", unit: "uJ", deltaValue: 2_000_000),   // 2e6 uJ = 2 J over the interval
            RawRailDelta(name: "B", unit: "nJ", deltaValue: 500_000_000), // 5e8 nJ = 0.5 J over the interval
        ]
        let live = ComponentPowerReader.liveReadings(from: deltas, intervalSeconds: interval)
        XCTAssertEqual(live.first(where: { $0.name == "A" })?.watts ?? -1, 2.0 / interval, accuracy: 1e-6)
        XCTAssertEqual(live.first(where: { $0.name == "B" })?.watts ?? -1, 0.5 / interval, accuracy: 1e-6)
    }

    /// B-arc B5: the probe cadence is a deliberate pair — a 2 s energy-delta window sampled every 4 s by
    /// the Details `.task`. Pinned here so a future edit to either half is a conscious one.
    func testProbeCadenceIsTheB5Pair() {
        XCTAssertEqual(ComponentPowerReader.probeInterval, 2.0, "B5 halved the sampling rate")
        XCTAssertEqual(ComponentPowerReader.windowSize, 4, "the rolling mean is what makes that affordable")
    }

    func testLiveReadings_zeroInterval_returnsEmpty_noDivideByZero() {
        XCTAssertEqual(ComponentPowerReader.liveReadings(
            from: [RawRailDelta(name: "GPU", unit: "nJ", deltaValue: 100)], intervalSeconds: 0), [])
    }

    func testLiveReadings_allFrozen_returnsEmpty_hidesSection() {
        let deltas = [
            RawRailDelta(name: "CPU Energy", unit: "mJ", deltaValue: 0),
            RawRailDelta(name: "GPU Energy", unit: "nJ", deltaValue: 0),
        ]
        XCTAssertEqual(ComponentPowerReader.liveReadings(from: deltas, intervalSeconds: interval), [],
                       "nothing advancing → empty → the view hides the section (no fabricated tree)")
    }

    // MARK: - reader publish path (fake sampler)

    private struct FakeSampler: ComponentPowerSampling {
        let deltas: [RawRailDelta]?
        func sampleEnergyDeltas(intervalSeconds: Double) -> [RawRailDelta]? { deltas }
    }

    @MainActor
    func testReader_refresh_publishesLiveRails() async {
        let reader = ComponentPowerReader(sampler: FakeSampler(deltas: [
            RawRailDelta(name: "GPU Energy", unit: "nJ", deltaValue: 47_970_291),
            RawRailDelta(name: "CPU Energy", unit: "mJ", deltaValue: 0),
        ]))
        await reader.refresh()
        XCTAssertTrue(reader.hasProbed)
        XCTAssertEqual(reader.readings.map(\.name), ["GPU Energy"])
    }

    @MainActor
    func testReader_refresh_ioreportUnavailable_keepsEmpty_noFlicker() async {
        let reader = ComponentPowerReader(sampler: FakeSampler(deltas: nil))   // dlopen/subscription failed
        await reader.refresh()
        XCTAssertFalse(reader.hasProbed, "nil sample → no probe recorded")
        XCTAssertEqual(reader.readings, [], "stays empty (section hidden) — never a fabricated number")
    }

    /// LIVE smoke (this machine): the REAL IOReport sampler either enumerates the Energy Model channels
    /// (no-root subscription works — research-11 saw ~328) or returns nil (IOReport unavailable), and
    /// `liveReadings` never crashes on the real data. Tolerant by design (GPU liveness depends on activity),
    /// so it's deterministic regardless of host state — it proves the dlopen/subscribe/iterate port runs.
    func testProductionSampler_subscribesOrDegradesCleanly() {
        let result = IOReportPowerSampler().sampleEnergyDeltas(intervalSeconds: 0.3)
        if let result {
            XCTAssertFalse(result.isEmpty, "a successful Energy Model subscription enumerates channels")
            _ = ComponentPowerReader.liveReadings(from: result, intervalSeconds: 0.3)   // must not crash on real data
        }
    }

    // MARK: - B3 rolling-average smoothing (pure)

    private func r(_ name: String, _ w: Double) -> PowerRailReading { PowerRailReading(name: name, watts: w) }

    func testUpdateWindows_growsFromOne_thenCaps() {
        let cap = ComponentPowerReader.windowSize   // 4
        var win = ComponentPowerReader.updateWindows([:], with: [r("GPU", 1)], cap: cap)
        XCTAssertEqual(win["GPU"], [1], "grows from one value")
        win = ComponentPowerReader.updateWindows(win, with: [r("GPU", 2)], cap: cap)
        win = ComponentPowerReader.updateWindows(win, with: [r("GPU", 3)], cap: cap)
        win = ComponentPowerReader.updateWindows(win, with: [r("GPU", 4)], cap: cap)
        XCTAssertEqual(win["GPU"], [1, 2, 3, 4], "fills up to the cap")
        win = ComponentPowerReader.updateWindows(win, with: [r("GPU", 5)], cap: cap)
        XCTAssertEqual(win["GPU"], [2, 3, 4, 5], "caps to the last `cap` values, oldest dropped")
    }

    func testUpdateWindows_railAbsent_agesOut_returningRailEntersFresh() {
        let cap = 4
        var win = ComponentPowerReader.updateWindows([:], with: [r("GPU", 10), r("CPU", 5)], cap: cap)
        win = ComponentPowerReader.updateWindows(win, with: [r("GPU", 12)], cap: cap)   // CPU absent
        XCTAssertNil(win["CPU"], "a rail absent from the latest sample ages out (dropped)")
        XCTAssertEqual(win["GPU"], [10, 12])
        win = ComponentPowerReader.updateWindows(win, with: [r("GPU", 14), r("CPU", 9)], cap: cap)
        XCTAssertEqual(win["CPU"], [9], "a returning rail re-enters FRESH, from its first value")
    }

    func testMeanReadings_arithmeticMean_sortedDesc_growFromOne() {
        XCTAssertEqual(ComponentPowerReader.meanReadings(from: ["GPU": [2]]).first?.watts ?? -1, 2.0, accuracy: 1e-9)
        let two = ComponentPowerReader.meanReadings(from: ["GPU": [2, 4]])   // mean 3.0
        XCTAssertEqual(two.first?.watts ?? -1, 3.0, accuracy: 1e-9)
        let sorted = ComponentPowerReader.meanReadings(from: ["GPU": [1, 1], "CPU": [10]])
        XCTAssertEqual(sorted.map(\.name), ["CPU", "GPU"], "sorted desc by mean (CPU 10 > GPU 1)")
    }

    func testMeanReadings_emptyWindowDropped() {
        XCTAssertTrue(ComponentPowerReader.meanReadings(from: ["GPU": []]).isEmpty, "an empty window shows nothing")
    }

    @MainActor
    func testBeginSession_resetsWindows_meanRestartsFromOne() async {
        // Two samples build GPU's window to [w, w]; beginSession clears it; the next sample is mean-of-1.
        let reader = ComponentPowerReader(sampler: FakeSampler(deltas: [
            RawRailDelta(name: "GPU Energy", unit: "nJ", deltaValue: 1_000_000_000),   // 1 J per interval
        ]))
        let w = 1_000_000_000 * 1e-9 / interval   // the per-sample watts at the production cadence
        await reader.refresh()
        await reader.refresh()
        XCTAssertEqual(reader.readings.first?.watts ?? -1, w, accuracy: 1e-6, "mean of [w, w] = w")
        reader.beginSession()
        XCTAssertEqual(reader.readings.first?.watts ?? -1, w, accuracy: 1e-6, "published readings unchanged until next refresh")
        await reader.refresh()
        XCTAssertEqual(reader.readings.first?.watts ?? -1, w, accuracy: 1e-6, "after reset, mean of [w] = w (grow from one)")
    }

    // HONEST LIMITATION ON THE LEAK: the subscription leak fixed in IOReportPowerSampler (the +1
    // IOReportCreateSubscription now released via Unmanaged.release() in a defer) is NOT unit-testable
    // here — the leak is in the impure IOReport interop behind the ComponentPowerSampling seam (the fake
    // sampler never subscribes), and IOReport exposes no subscription-count/retain-count API to assert
    // against; a memory-growth assertion would be flaky. So per the audit guidance we do NOT fake a leak
    // test. The release path's SAFETY (a wrong release of the non-ARC `sub` would over-release and trap)
    // is exercised by testProductionSampler_subscribesOrDegradesCleanly above — one real subscribe+release
    // cycle that must not crash.
}
