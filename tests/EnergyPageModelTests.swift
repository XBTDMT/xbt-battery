import XCTest
@testable import Battery

/// #30 §4.4: the Energy page's pure presentation logic — shares (§14-D7), the Pack row's "≈ system"
/// rule (§14-D6), the single-live-rail cue, the adapter "last" line, and the holder rows (§14-D8).
final class EnergyPageModelTests: XCTestCase {

    // MARK: shares

    func testSnapshotShareIsOfTheSampleTotal_notOfTheTopRow() {
        let apps = [EnergyImpactRow(pid: 1, name: "Ghostty", energyMillijoules: 380, fraction: 1.0),
                    EnergyImpactRow(pid: 2, name: "Chrome", energyMillijoules: 240, fraction: 0.63)]
        let rows = EnergyPageModel.snapshotRows(apps, totalMillijoules: 1000)
        XCTAssertEqual(rows.map { EnergyPageModel.percentText($0.share) }, ["38%", "24%"])
        XCTAssertEqual(rows.first?.pid, 1)
        XCTAssertNil(rows.first?.bundleID)
    }

    func testSnapshotZeroTotalNeverDividesByZero() {
        let apps = [EnergyImpactRow(pid: 1, name: "A", energyMillijoules: 5, fraction: 1)]
        XCTAssertEqual(EnergyPageModel.snapshotRows(apps, totalMillijoules: 0).first?.share, 0)
        XCTAssertEqual(EnergyPageModel.snapshotRows(apps, totalMillijoules: .nan).first?.share, 0)
    }

    func testSustainedShareUsesHelperTotal_elseSumOfEntries() {
        let apps = [SustainedEnergyEntry(id: "com.a", name: "A", energyImpact: 30),
                    SustainedEnergyEntry(id: "com.b", name: "B", energyImpact: 10)]
        let withTotal = EnergyPageModel.sustainedRows(apps, total: 100)
        XCTAssertEqual(withTotal.map(\.share), [0.3, 0.1])
        XCTAssertEqual(withTotal.first?.bundleID, "com.a")
        XCTAssertNil(withTotal.first?.pid)
        let noTotal = EnergyPageModel.sustainedRows(apps, total: nil)
        XCTAssertEqual(noTotal.map(\.share), [0.75, 0.25])
    }

    // MARK: the shared ranking (PowerDrawersModel — owner ruling 2026-09-09 evening)

    struct NameOnlyResolver: DrawerIdentityResolving {
        func identity(pid: Int?, bundleID: String?, name: String) -> DrawerIdentity {
            let e = ProcessIdentity.daemon(named: name)
            return DrawerIdentity(displayName: e.name, subtitle: pid.map { "pid \($0)" }, icon: .symbol(e.symbol))
        }
    }

    func testDrawersAreSortedByEnergy_top12_sharesOfTheTotal() {
        var rows = (1...15).map { EnergyImpactRow(pid: $0, name: "P\($0)", energyMillijoules: Double($0), fraction: 1) }
        rows.shuffle()
        let d = PowerDrawersModel.drawers(snapshot: rows, totalMillijoules: 100, resolver: NameOnlyResolver())
        XCTAssertEqual(d.count, PowerDrawersModel.cap)
        XCTAssertEqual(d.map(\.id), (4...15).reversed().map { "pid:\($0)" }, "highest energy first, the 3 smallest dropped")
        XCTAssertEqual(d.first?.share ?? 0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(d.first?.displayName, "P15")
        XCTAssertEqual(d.first?.subtitle, "pid 15")
        XCTAssertEqual(d.first?.icon.symbolName, "gearshape")
        XCTAssertEqual(Array(d.prefix(PowerDrawersModel.nowStripCount)).map(\.id), d.prefix(5).map(\.id),
                       "the Now strip is the HEAD of the same list")
    }

    func testSustainedDrawersUseHelperTotal_elseSum_andResolveByName() {
        let apps = [SustainedEnergyEntry(id: "com.b", name: "B", energyImpact: 10),
                    SustainedEnergyEntry(id: "kernel_coalition", name: "kernel_coalition", energyImpact: 30)]
        let withTotal = PowerDrawersModel.drawers(sustained: apps, total: 100, resolver: NameOnlyResolver())
        XCTAssertEqual(withTotal.map(\.id), ["bundle:kernel_coalition", "bundle:com.b"])
        XCTAssertEqual(withTotal.map(\.share), [0.3, 0.1])
        XCTAssertEqual(withTotal.first?.displayName, "Kernel")
        XCTAssertEqual(withTotal.first?.icon.symbolName, "cpu")
        XCTAssertNil(withTotal.first?.subtitle, "no pid → no pid subtitle")
        let noTotal = PowerDrawersModel.drawers(sustained: apps, total: nil, resolver: NameOnlyResolver())
        XCTAssertEqual(noTotal.map(\.share), [0.75, 0.25])
    }

    func testDrawersZeroTotalNeverDividesByZero() {
        let rows = [EnergyImpactRow(pid: 1, name: "A", energyMillijoules: 5, fraction: 1)]
        XCTAssertEqual(PowerDrawersModel.drawers(snapshot: rows, totalMillijoules: 0, resolver: NameOnlyResolver()).first?.share, 0)
    }

    func testSourcePreference_sustainedWhenAvailableWithEntries_userMayFlip() {
        XCTAssertEqual(PowerDrawersModel.preferredSource(sustainedAvailable: true, sustainedHasEntries: true, userChoice: nil), .sustained)
        XCTAssertEqual(PowerDrawersModel.preferredSource(sustainedAvailable: true, sustainedHasEntries: false, userChoice: nil), .snapshot)
        XCTAssertEqual(PowerDrawersModel.preferredSource(sustainedAvailable: false, sustainedHasEntries: true, userChoice: nil), .snapshot)
        XCTAssertEqual(PowerDrawersModel.preferredSource(sustainedAvailable: true, sustainedHasEntries: true, userChoice: .snapshot), .snapshot)
        XCTAssertEqual(PowerDrawersModel.preferredSource(sustainedAvailable: false, sustainedHasEntries: false, userChoice: .sustained), .snapshot,
                       "a Sustained choice with nothing to show falls back honestly")
        XCTAssertEqual(PowerDrawersModel.caption(for: .sustained), EnergyPageModel.sustainedCaption)
        XCTAssertEqual(PowerDrawersModel.caption(for: .snapshot), EnergyPageModel.sampleCaption)
    }

    func testInputsKeyChangesWithSourceAndRowSet() {
        let a = PowerDrawersModel.inputsKey(source: .snapshot, snapshotIDs: [1, 2], sustainedIDs: ["x"])
        let b = PowerDrawersModel.inputsKey(source: .sustained, snapshotIDs: [1, 2], sustainedIDs: ["x"])
        let c = PowerDrawersModel.inputsKey(source: .snapshot, snapshotIDs: [2, 1], sustainedIDs: ["x"])
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(a, c)
        XCTAssertEqual(a, PowerDrawersModel.inputsKey(source: .snapshot, snapshotIDs: [1, 2], sustainedIDs: ["other"]),
                       "the other source's rows do not invalidate")
    }

    func testRowCapIsFive() {
        let apps = (1...7).map { EnergyImpactRow(pid: $0, name: "P\($0)", energyMillijoules: 1, fraction: 1) }
        XCTAssertEqual(EnergyPageModel.snapshotRows(apps, totalMillijoules: 7).count, 5)
    }

    func testPercentTextRoundsAndNeverClaimsZeroForAPositiveShare() {
        XCTAssertEqual(EnergyPageModel.percentText(0.384), "38%")
        XCTAssertEqual(EnergyPageModel.percentText(0.004), "<1%")
        XCTAssertEqual(EnergyPageModel.percentText(0), "0%")
        XCTAssertEqual(EnergyPageModel.percentText(1), "100%")
    }

    // MARK: caption

    func testCaptionAppendsCoverageNote() {
        XCTAssertEqual(EnergyPageModel.caption(sustainedSelected: false, coverageNote: nil),
                       EnergyPageModel.sampleCaption)
        XCTAssertEqual(EnergyPageModel.caption(sustainedSelected: false, coverageNote: "Your apps only"),
                       EnergyPageModel.sampleCaption + " · Your apps only")
        XCTAssertEqual(EnergyPageModel.caption(sustainedSelected: true, coverageNote: "ignored"),
                       EnergyPageModel.sustainedCaption)
    }

    // MARK: Power now

    func testPackRowAppendsApproxSystemOnlyOnBattery() {
        let onBattery = EnergyPageModel.packRow(voltageVolts: 12.1, amperageMilliamps: -2300, onBattery: true)
        XCTAssertEqual(onBattery.value, "27.8 W · 12.1 V × 2.30 A")
        XCTAssertEqual(onBattery.faint, "· ≈ system")
        let onAC = EnergyPageModel.packRow(voltageVolts: 12.1, amperageMilliamps: 2300, onBattery: false)
        XCTAssertEqual(onAC.value, "27.8 W · 12.1 V × 2.30 A")
        XCTAssertNil(onAC.faint)
        XCTAssertEqual(EnergyPageModel.packRow(voltageVolts: nil, amperageMilliamps: 1, onBattery: true).value, "—")
        XCTAssertEqual(EnergyPageModel.packRow(voltageVolts: .nan, amperageMilliamps: 1, onBattery: true).value, "—")
    }

    func testRailRows_singleLiveRailCarriesTheOnlyLiveRailCue() {
        let rows = EnergyPageModel.railRows([PowerRailReading(name: "GPU Energy", watts: 4.21)], hasProbed: true)
        XCTAssertEqual(rows, [EnergyPageModel.KVRow(key: "GPU", value: "4.2 W", faint: "· modeled · only live rail")])
    }

    func testRailRows_severalLiveRailsListEach() {
        let rows = EnergyPageModel.railRows([PowerRailReading(name: "CPU Energy", watts: 5),
                                             PowerRailReading(name: "GPU Energy", watts: 1)], hasProbed: true)
        XCTAssertEqual(rows.map(\.key), ["CPU", "GPU"])
        XCTAssertEqual(Set(rows.map(\.faint)), ["· modeled"])
    }

    func testRailRows_emptySaysWhichEmpty() {
        XCTAssertEqual(EnergyPageModel.railRows([], hasProbed: false).first?.faint, "· measuring…")
        XCTAssertEqual(EnergyPageModel.railRows([], hasProbed: true).first?.faint, "· no live rail")
        XCTAssertEqual(EnergyPageModel.railRows([], hasProbed: true).first?.value, "—")
    }

    func testAdapterRow_threeStates() {
        let live = PowerAdapter(watts: 96, voltage_mV: 20_000, current_mA: 4_800)
        XCTAssertEqual(EnergyPageModel.adapterRow(state: .connected(live), last: nil).value, "96 W (20 V / 4.8 A)")
        let last = LastAdapterRecord(watts: 94, voltage_mV: 20_000, current_mA: 4_700, activePdIndex: 3, ts: 0)
        let off = EnergyPageModel.adapterRow(state: .noAdapter, last: last)
        XCTAssertEqual(off.value, "not connected · last 94 W, 20 V rung")
        XCTAssertTrue(off.valueIsFaint)
        XCTAssertEqual(EnergyPageModel.adapterRow(state: .noAdapter, last: nil).value, "not connected")
        let failed = EnergyPageModel.adapterRow(state: .unavailable("why"), last: last)
        XCTAssertEqual(failed.value, "—")
        XCTAssertEqual(failed.faint, "· why")
    }

    // MARK: Keeping the Mac awake

    private func holder(_ pid: Int, since: Date?) -> KeepAwakeHolder {
        KeepAwakeHolder(pid: pid, processName: "p\(pid)", displayName: "P\(pid)", explanation: "", reasons: [], heldSince: since)
    }

    func testHolderDetailIsPidAndDwell() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let since = now.addingTimeInterval(-(5 * 86_400 + 22 * 3_600 + 30))
        XCTAssertEqual(EnergyPageModel.holderDetail(holder(843, since: since), now: now), "pid 843 · 5 d 22 h")
        XCTAssertEqual(EnergyPageModel.holderDetail(holder(843, since: nil), now: now), "pid 843")
    }

    func testVisibleHoldersCapAtTwoRegardlessOfRails() {
        let holders = (1...5).map { holder($0, since: nil) }
        // Several rails → 2 + "+3 more".
        let multi = EnergyPageModel.visibleHolders(holders, railCount: 2)
        XCTAssertEqual(multi.shown.map(\.pid), [1, 2])
        XCTAssertEqual(multi.more, 3)
        XCTAssertEqual(EnergyPageModel.moreText(multi.more), "+3 more system holders · none from your apps")
        XCTAssertEqual(EnergyPageModel.moreText(multi.more, fromApps: 1), "+3 more · 1 from your apps")
        // A single rail is capped the same way — the 3-holder layout overran the frame on device (2026-09-09).
        let single = EnergyPageModel.visibleHolders(holders, railCount: 1)
        XCTAssertEqual(single.shown.map(\.pid), [1, 2])
        XCTAssertEqual(single.more, 3)
        XCTAssertNil(EnergyPageModel.moreText(EnergyPageModel.visibleHolders(Array(holders.prefix(2)), railCount: 3).more))
        XCTAssertEqual(EnergyPageModel.holderCap(railCount: 0), 2)   // flat: the 3-holder case overran on device
        XCTAssertEqual(EnergyPageModel.holderCap(railCount: 4), 2)
    }

    // MARK: height budget (R15 finding 1)

    /// The mock's content — five apps · Pack / GPU / Adapter · two holders · "+1 more" — fits the 470 pt
    /// frame at its 8 pt rows / 7 pt kv gaps, with the three minimum spacers counted.
    func testMockContentFitsThePageHeight() {
        XCTAssertEqual(EnergyPageModel.Layout.frameHeight, 470)   // == DSMetric.pageHeight (owner ruling 2026-09-09 evening)
        let h = EnergyPageModel.estimatedHeight(rankedRows: 5, powerRows: 3, holderRows: 2, hasMore: true)
        XCTAssertLessThanOrEqual(h, EnergyPageModel.Layout.frameHeight, "Energy page budget \(h) exceeds \(EnergyPageModel.Layout.frameHeight)")
    }

    /// The realistic worst case — five apps · Pack + CPU/GPU/ANE + Adapter (the rails Apple could restore;
    /// rails are uncapped, GPU-only on 27.0) · two holders · "+N more" — still leaves the spacers something
    /// to share (the page must distribute, not clip). A 4th live rail would exceed the frame by 10 pt and
    /// fall to `.clipped()`; cap rails in the model if that day comes.
    func testWorstCaseLeavesSlackForTheSpacers() {
        let h = EnergyPageModel.estimatedHeight(rankedRows: 5, powerRows: 5, holderRows: 2, hasMore: true)
        XCTAssertLessThan(h, EnergyPageModel.Layout.frameHeight, "no slack left for the spacers: \(h)")
    }

    func testEmptyStatesFitThePageHeight() {
        XCTAssertLessThanOrEqual(EnergyPageModel.estimatedHeight(rankedRows: 0, powerRows: 3, holderRows: 1, hasMore: false),
                                 EnergyPageModel.Layout.frameHeight)
    }

    func testSnapshotNeedsFetchWhenEmptyOrStale() {
        XCTAssertTrue(EnergyPageModel.snapshotNeedsFetch(isEmpty: true, stalenessNote: nil))
        XCTAssertTrue(EnergyPageModel.snapshotNeedsFetch(isEmpty: false, stalenessNote: "as of 30s ago"))
        XCTAssertFalse(EnergyPageModel.snapshotNeedsFetch(isEmpty: false, stalenessNote: nil))
    }
}
