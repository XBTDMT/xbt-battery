import XCTest
import Shared

/// Sprint 3.7 STAGE 4 — SustainedEnergySource behavior via the `TaskEnergyCollecting` seam
/// (host-app-free, no NSXPC). Proves the HONEST-unavailable contract: success→parsed+coalesced;
/// garbled→hide; empty→empty(hide); unreachable/helperError→hide. Never a fabricated number.
@MainActor
final class SustainedEnergySourceTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/energy/\(name)")
        return try Data(contentsOf: url)
    }

    @MainActor
    private final class MockCollector: TaskEnergyCollecting {
        var result: Result<Data, HelperClientError> = .success(Data())
        private(set) var callCount = 0
        private(set) var lastSamples: Int?
        func collectTaskEnergy(samples: Int, intervalMs: Int,
                               completion: @escaping (Result<Data, HelperClientError>) -> Void) {
            callCount += 1; lastSamples = samples
            completion(result)
        }
    }

    /// Test resolver: maps the bundle ids we choose to assert; everything else → nil (→ pure fallback).
    private struct MockCoalitionNameResolver: CoalitionNameResolving {
        let map: [String: String]
        func localizedName(forBundleID id: String) -> String? { map[id] }
    }

    // MARK: - B1: friendly names + share-of-total + top-N cap

    func testFriendlyNameFallback_derivesReadableName() {
        XCTAssertEqual(SustainedEnergySource.friendlyNameFallback(forCoalition: "com.mitchellh.ghostty"), "Ghostty")
        XCTAssertEqual(SustainedEnergySource.friendlyNameFallback(forCoalition: "com.apple.WindowServer"), "WindowServer")
        XCTAssertEqual(SustainedEnergySource.friendlyNameFallback(forCoalition: "kernel_coalition"), "System")
        XCTAssertEqual(SustainedEnergySource.friendlyNameFallback(forCoalition: "Finder"), "Finder")
        XCTAssertEqual(SustainedEnergySource.friendlyNameFallback(forCoalition: ""), "")
    }

    func testRefresh_resolvesFriendlyNames_resolverThenFallback() throws {
        let mock = MockCollector(); mock.result = .success(try fixture("powermetrics-coalitions.txt"))
        // resolver knows ghostty (a "running app"); airportd is unmapped → pure fallback "Airportd".
        let src = SustainedEnergySource(collector: mock,
                                        nameResolver: MockCoalitionNameResolver(map: ["com.mitchellh.ghostty": "Ghostty"]))
        src.refresh()
        XCTAssertEqual(src.apps.first?.name, "Ghostty", "live resolver wins")
        XCTAssertEqual(src.apps[1].name, "Airportd", "unmapped bundle id → pure fallback (last component, capitalized)")
        XCTAssertEqual(src.apps.first?.energyImpact ?? -1, 75.0357, accuracy: 0.0001, "energy is preserved from the parser")
    }

    func testRefresh_populatesTotal_fromAllTasks() throws {
        let mock = MockCollector(); mock.result = .success(try fixture("powermetrics-coalitions.txt"))
        let src = SustainedEnergySource(collector: mock)
        src.refresh()
        XCTAssertEqual(src.total ?? -1, 265.761, accuracy: 0.001, "share-of-total denominator = all_tasks.energy_impact")
    }

    func testRefresh_capsToDisplayCount() {
        // 14 coalitions → only the top displayCount (12) are kept for the headline (ranked desc).
        var rows = ""
        for i in 0..<14 { rows += "<dict><key>name</key><string>app\(i)</string><key>energy_impact</key><real>\(100 - i)</real></dict>" }
        let d = Data("<plist version=\"1.0\"><dict><key>coalitions</key><array>\(rows)</array></dict></plist>".utf8)
        let mock = MockCollector(); mock.result = .success(d)
        let src = SustainedEnergySource(collector: mock)
        src.refresh()
        XCTAssertEqual(src.apps.count, SustainedEnergySource.displayCount, "capped to the top displayCount rows")
        XCTAssertEqual(src.apps.first?.name, "app0", "highest energy first; non-dotted token shown as-is")
    }

    func testRefresh_validData_populatesCoalescedApps() throws {
        let mock = MockCollector(); mock.result = .success(try fixture("powermetrics-coalitions.txt"))
        // Empty resolver map → pure fallback, deterministic regardless of what's running on the test host.
        let src = SustainedEnergySource(collector: mock, nameResolver: MockCoalitionNameResolver(map: [:]))
        src.refresh()
        XCTAssertEqual(mock.callCount, 1)
        XCTAssertEqual(mock.lastSamples, TaskEnergyCommand.defaultSamples, "one-shot default (no polling)")
        XCTAssertFalse(src.isUnavailable)
        XCTAssertEqual(src.apps.count, 4, "5 coalition rows (2 Spotlight) fold into 4 responsible-app rows")
        XCTAssertEqual(src.apps.first?.name, "Ghostty", "bundle id friendly-mapped (pure fallback here)")
        XCTAssertFalse(src.isRefreshing)
    }

    func testRefresh_garbled_hidesViaUnavailable_noFakeNumber() throws {
        let mock = MockCollector(); mock.result = .success(try fixture("powermetrics-garbled.txt"))
        let src = SustainedEnergySource(collector: mock)
        src.refresh()
        XCTAssertTrue(src.isUnavailable, "garbled output hides (unavailable), never a fabricated number")
        XCTAssertTrue(src.apps.isEmpty)
    }

    func testRefresh_emptyTasks_appsEmpty_notUnavailable() throws {
        let mock = MockCollector(); mock.result = .success(try fixture("powermetrics-empty-tasks.txt"))
        let src = SustainedEnergySource(collector: mock)
        src.refresh()
        XCTAssertFalse(src.isUnavailable)
        XCTAssertEqual(src.apps, [], "no attributable tasks → empty (view hides), not 'unavailable'")
    }

    func testRefresh_unreachableHelper_hidesViaUnavailable() {
        let mock = MockCollector(); mock.result = .failure(.unreachable)
        let src = SustainedEnergySource(collector: mock)
        src.refresh()
        XCTAssertTrue(src.isUnavailable, "an unapproved/unreachable helper hides (no fake number)")
    }

    func testRefresh_helperErrorToken_hidesViaUnavailable() {
        let mock = MockCollector(); mock.result = .failure(.helperError(TaskEnergyCommand.errCollectFailed))
        let src = SustainedEnergySource(collector: mock)
        src.refresh()
        XCTAssertTrue(src.isUnavailable)
    }

    // MARK: section choice (B2 adaptive: sustained PRIMARY, snapshot+upsell FALLBACK, wall only as last resort)
    // Full matrix over (sustainedAvailable, sustainedHasEntries, snapshotHasEntries). Note
    // sustainedHasEntries implies sustainedAvailable, so (false, true, *) is an impossible-input guard.

    func testEnergySectionChoice_sustainedPrimary_whenAvailableAndHasEntries() {
        // Sustained wins regardless of the snapshot.
        XCTAssertEqual(energySectionChoice(sustainedAvailable: true, sustainedHasEntries: true,
                                           snapshotHasEntries: true), .sustained)
        XCTAssertEqual(energySectionChoice(sustainedAvailable: true, sustainedHasEntries: true,
                                           snapshotHasEntries: false), .sustained)
    }

    func testEnergySectionChoice_snapshotWithUpsell_whenHelperUnavailableButSnapshotHasRows() {
        // Helper not delivering (unapproved/unreachable/failed) + the free snapshot has rows → snapshot
        // PLUS the approve-for-a-sustained-ranking upsell. Never a wall when the snapshot can show.
        XCTAssertEqual(energySectionChoice(sustainedAvailable: false, sustainedHasEntries: false,
                                           snapshotHasEntries: true), .snapshotWithUpsell)
    }

    func testEnergySectionChoice_plainSnapshot_whenApprovedButIdle_noNag() {
        // Helper APPROVED (available) but returning no rows (idle) + snapshot has rows → the snapshot
        // ALONE, no upsell: we do not nag a user to approve something already approved.
        XCTAssertEqual(energySectionChoice(sustainedAvailable: true, sustainedHasEntries: false,
                                           snapshotHasEntries: true), .snapshot)
    }

    func testEnergySectionChoice_wall_onlyWhenUnavailableAndNothingElse() {
        // The approve affordance alone, the wall, only when the helper is genuinely unavailable AND there
        // is no snapshot to show.
        XCTAssertEqual(energySectionChoice(sustainedAvailable: false, sustainedHasEntries: false,
                                           snapshotHasEntries: false), .sustainedUnavailable)
    }

    func testEnergySectionChoice_none_whenApprovedIdleAndNoSnapshot_noFalseWall() {
        // Approved but idle, and no snapshot either → hide. NOT the approve wall (it is already approved).
        XCTAssertEqual(energySectionChoice(sustainedAvailable: true, sustainedHasEntries: false,
                                           snapshotHasEntries: false), .none)
    }

    // MARK: - SWEEP §2.G · which unavailability (12-SWEEP-silent-absence.md, hit 4)

    /// RED-first, the collapse itself. `refresh()` set `isUnavailable = true` from BOTH the helper
    /// failing AND the parser returning nil, so the popover told an already-approved user to
    /// "Approve the energy helper" when the real problem was that Apple changed the plist shape —
    /// an instruction that is wrong and that the user cannot act on. The file flagged this itself:
    /// "a cleaner split would need the source to expose unreachable versus parse-failure separately."
    func testUnavailableReason_helperFailureAndUnparseableOutputAreNoLongerTheSameFact() {
        let helperDown = MockCollector(); helperDown.result = .failure(.unreachable)
        let a = SustainedEnergySource(collector: helperDown)
        a.refresh()

        let garbled = MockCollector(); garbled.result = .success(Data("not a plist".utf8))
        let b = SustainedEnergySource(collector: garbled)
        b.refresh()

        // The ruled `energySectionChoice` input is UNCHANGED — both still hide.
        XCTAssertTrue(a.isUnavailable)
        XCTAssertTrue(b.isUnavailable)
        // …but the two facts are now distinguishable, which they were not.
        XCTAssertEqual(a.unavailableReason, .helperUnavailable)
        XCTAssertEqual(b.unavailableReason, .outputUnparseable)
        XCTAssertNotEqual(a.unavailableReason, b.unavailableReason)
    }

    /// The copy follows the fact. Telling an approved user to approve something is the failure mode.
    func testUnavailableReason_carriesTheSentenceThatMatchesTheCause() {
        XCTAssertEqual(SustainedUnavailability.helperUnavailable.message,
                       "Approve the energy helper to see which apps are using energy.")
        XCTAssertEqual(SustainedUnavailability.outputUnparseable.message,
                       "The energy report couldn't be read — macOS may have changed its format.")
        XCTAssertNotEqual(SustainedUnavailability.helperUnavailable.message,
                          SustainedUnavailability.outputUnparseable.message)
    }

    /// A GOOD read clears the reason — a stale cause must not outlive the failure that set it
    /// (the same rule `BatteryLifetimeSource` follows for `lastFailure`).
    func testUnavailableReason_clearedByASubsequentGoodRead() throws {
        let mock = MockCollector(); mock.result = .failure(.unreachable)
        let src = SustainedEnergySource(collector: mock)
        src.refresh()
        XCTAssertEqual(src.unavailableReason, .helperUnavailable)

        mock.result = .success(try fixture("powermetrics-coalitions.txt"))
        src.refresh()
        XCTAssertFalse(src.isUnavailable)
        XCTAssertNil(src.unavailableReason, "a delivering helper carries no reason")
    }

    /// An APPROVED but IDLE helper (valid output, no attributable rows) is not an unavailability at all.
    /// This is the case the owner ruling exists to protect: no nag, and now no spurious reason either.
    func testUnavailableReason_nilWhenApprovedButIdle() {
        let mock = MockCollector()
        mock.result = .success(Data("<plist version=\"1.0\"><dict><key>coalitions</key><array/></dict></plist>".utf8))
        let src = SustainedEnergySource(collector: mock)
        src.refresh()
        XCTAssertFalse(src.isUnavailable, "parsed fine, just empty")
        XCTAssertNil(src.unavailableReason)
        XCTAssertTrue(src.apps.isEmpty)
    }
}
