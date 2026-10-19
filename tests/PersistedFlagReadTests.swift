import XCTest

/// Redman sweep items 7 and 8: the last two two-state reads of persisted state, brought to three states.
@MainActor
final class PersistedFlagReadTests: XCTestCase {

    // MARK: - item 8: adoptExternal during a pause whose capture will not decode

    /// THE DEFECT. `adoptExternal` read the capture with the collapsing `captureStore.load()`, so during
    /// a pause whose capture is CORRUPT (the engine already treats that as paused, restore point lost) a
    /// genuine external limit change was invisible: the "limit was changed outside the app" note — the
    /// one disclosure that change gets — was never set.
    func testAnExternalChangeDuringACorruptPauseIsStillNoted() async {
        let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "90")])
        let captures = MockPauseCaptureStore(corrupt: true)
        let engine = ChargeLimitEngine(runner: mock, captureStore: captures,
                                       custodyStore: MockLastSetCustodyStore(LastSetCustody(value: 80, at: Date())),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        XCTAssertTrue(engine.isPaused, "precondition: a corrupt capture reads as paused (SWEEP H2)")
        XCTAssertEqual(engine.limit, .known(80))
        await engine.sync(.popoverOpen)                 // the world now reads 90
        XCTAssertEqual(engine.engineNote, "limit was changed outside the app")
        XCTAssertEqual(captures.loadDetailed(), .corrupt, "the unreadable capture is never written over")
    }

    /// Same-value re-syncs are not changes — no note, as for a readable capture.
    func testASameValueSyncDuringACorruptPauseAddsNoNote() async {
        let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "80")])
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(corrupt: true),
                                       custodyStore: MockLastSetCustodyStore(LastSetCustody(value: 80, at: Date())),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)
        XCTAssertNil(engine.engineNote)
    }

    /// With nothing held before the first read, a first reading is not a "change" either.
    func testAFirstReadingDuringACorruptPauseWithNoPriorValueAddsNoNote() async {
        let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "90")])
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(corrupt: true),
                                       custodyStore: MockLastSetCustodyStore(nil),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)
        XCTAssertNil(engine.engineNote)
    }

    // MARK: - item 7: SetupFlow's verified-mode record

    private let allInstalled = "Battery Limit Get\nBattery Limit 80\nBattery Limit 85\nBattery Limit 90\nBattery Limit 95\nBattery Limit 100"
    private let noGet = "Battery Limit 80\nBattery Limit 85\nBattery Limit 90\nBattery Limit 95\nBattery Limit 100"
    private let key = "setup.lastVerified.v1"

    /// THE DEFECT. `defaults.object(forKey:) as? Bool` read a stored value of the wrong type as "no
    /// record". It is now its own state (the test-observable flag) and is logged; the decision it gates
    /// is the inert one-time verified→degraded notice, which is not fired on no evidence.
    func testAStoredValueOfTheWrongTypeIsUnreadableNotAbsent() async {
        let suite = "PersistedFlagReadTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("yes", forKey: key)
        let flow = SetupFlow(runner: MockShortcutRunner([.init(.success(stdout: noGet))]), defaults: d)
        await flow.checkNow()
        XCTAssertTrue(flow.lastVerifiedRecordUnreadable)
        XCTAssertFalse(flow.degradedNoticePending, "no transition notice on a record that could not be read")
        XCTAssertEqual(d.object(forKey: key) as? Bool, false,
                       "the record is regenerated from what this check just observed")
    }

    func testANeverWrittenRecordIsNotUnreadable() async {
        let suite = "PersistedFlagReadTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let flow = SetupFlow(runner: MockShortcutRunner([.init(.success(stdout: allInstalled))]), defaults: d)
        await flow.checkNow()
        XCTAssertFalse(flow.lastVerifiedRecordUnreadable)
        XCTAssertEqual(d.object(forKey: key) as? Bool, true)
    }
}
