import XCTest

/// Redman sweep items 6 and 5: an unreadable relaunch witness must not silently abandon a Top Up.
///
/// THE DEFECT (item 6). On relaunch `resumeOnLaunch` decides whether the climb is intact from
/// `engine.limit.knownValue ?? engine.lastSetCustody?.value`. In degraded mode (no Get) with a custody
/// that will not decode, `try?` made the custody `nil`, the expression `nil`, and `nil != 100` took the
/// "the limit was changed" branch: `finish()` → `store.clear()` deleted a VALID Top Up record and no
/// restore was attempted — the pack stays at 100 under a note that says the user changed it.
@MainActor
final class TopUpRelaunchUnreadableTests: XCTestCase {

    final class MemTopUpStore: TopUpStoring, @unchecked Sendable {
        private let lock = NSLock(); private var s: TopUpState?
        private(set) var clears = 0
        init(_ s: TopUpState? = nil) { self.s = s }
        func load() -> TopUpState? { lock.lock(); defer { lock.unlock() }; return s }
        func save(_ x: TopUpState) { lock.lock(); s = x; lock.unlock() }
        func clear() { lock.lock(); s = nil; clears += 1; lock.unlock() }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let getFails = MockShortcutRunner.Scripted(.missingShortcut)
    private let setOK = MockShortcutRunner.Scripted(.success(stdout: ""))

    private func controller(engine: ChargeLimitEngine, store: any TopUpStoring) -> TopUpController {
        let start = base
        return TopUpController(engine: engine,
                               reading: { TopUpController.Reading(soc: 95, onAC: true) },
                               store: store, now: { start })
    }

    // MARK: - item 6: no readable limit and no custody → restore, never abandon

    /// The Get is unavailable and there is no usable custody, so nothing says whether the climb is
    /// intact. The old code read that as "the limit was changed" and deleted the record. The safe
    /// answer is the pre-verified RESTORE to the captured limit: it is the user's own value, and leaving
    /// the pack at 100 is the battery-ageing direction this app exists to prevent.
    func testRelaunchWithNoReadableLimitRestoresTheCapturedLimitInsteadOfAbandoningIt() async {
        let mock = MockShortcutRunner([getFails,          // resumeOnLaunch: sync(.verify)
                                       getFails,          // revert: pre-revert sync(.verify)
                                       setOK, getFails])  // restore Set 80, its read-verify
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(nil),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        let store = MemTopUpStore(TopUpState(capturedLimit: 80, startedAt: base.addingTimeInterval(-3600)))
        let c = controller(engine: engine, store: store)
        await c.resumeOnLaunch()
        XCTAssertTrue(mock.invocationNames.contains("Battery Limit 80"),
                      "the captured limit must be restored, not abandoned at 100")
        XCTAssertNotEqual(c.note, "Top Up ended — the limit was changed.",
                          "nothing showed the limit was changed — the note must not say it was")
        XCTAssertEqual(c.phase, .idle)
    }

    // MARK: - no regression: a READABLE witness still decides

    func testRelaunchWithCustodyAt100StillResumesTheClimb() async {
        let mock = MockShortcutRunner([getFails])
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(LastSetCustody(value: 100, at: base)),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        let store = MemTopUpStore(TopUpState(capturedLimit: 80, startedAt: base.addingTimeInterval(-3600)))
        let c = controller(engine: engine, store: store)
        await c.resumeOnLaunch()
        XCTAssertEqual(c.phase, .climbing)
        XCTAssertEqual(store.clears, 0)
    }

    func testRelaunchWithADivergedReadableCustodyStillCancelsWithoutRestore() async {
        let mock = MockShortcutRunner([getFails])
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(LastSetCustody(value: 90, at: base)),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        let c = controller(engine: engine,
                           store: MemTopUpStore(TopUpState(capturedLimit: 80, startedAt: base.addingTimeInterval(-3600))))
        await c.resumeOnLaunch()
        XCTAssertEqual(c.note, "Top Up ended — the limit was changed.", "a READ value of 90 is evidence of a change")
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 80"))
    }

    // MARK: - item 5: an unreadable Top Up record is not "no Top Up"
    //
    // THE DEFECT. `UserDefaultsTopUpStore.load()` was `try? decode`, so undecodable bytes under
    // `topUp.active.v1` read as `nil` and `resumeOnLaunch` returned at its first guard: the limit (raised
    // to 100 when the climb began) is never reverted, the 12 h TTL never fires, and nothing is said.
    //
    // These run the PRODUCTION store over `UserDefaults.standard` — inside the xctest process that is
    // xctest's own preferences domain, never the app's — and restore the key afterwards.

    private let topUpKey = "topUp.active.v1"
    private let topUpGarbage = Data("{\"capturedLimit\":8".utf8)

    private func withStandardTopUpKey(_ body: () async -> Void) async {
        let saved = UserDefaults.standard.object(forKey: topUpKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: topUpKey) }
            else { UserDefaults.standard.removeObject(forKey: topUpKey) }
            // F3: the relaunch now sets the record aside — remove any side keys this test created.
            for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(topUpKey + ".unreadable.") {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
        await body()
    }
    private func asideKeys(_ d: UserDefaults) -> [String] {
        d.dictionaryRepresentation().keys.filter { $0.hasPrefix(topUpKey + ".unreadable.") }.sorted()
    }

    /// The relaunch must not be silent: there is no witness anywhere of the limit before the Top Up
    /// (the custody is the climb's own 100), so it is said out loud on the Top Up note. The unreadable
    /// record is KEPT — final review F3: moved aside (byte-identical), not left in place to re-post.
    func testAnUnreadableTopUpRecordIsDisclosedOnRelaunchAndKept() async {
        await withStandardTopUpKey {
            UserDefaults.standard.set(topUpGarbage, forKey: topUpKey)
            let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "100")])
            let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                           custodyStore: MockLastSetCustodyStore(nil),
                                           clock: MockMonotonicClock(box: MockClockBox(0)))
            let c = controller(engine: engine, store: UserDefaultsTopUpStore())
            await c.resumeOnLaunch()
            XCTAssertNotNil(c.note, "an interrupted Top Up whose record will not decode must not pass in silence")
            XCTAssertEqual(asideKeys(.standard).first.flatMap { UserDefaults.standard.data(forKey: $0) }, topUpGarbage,
                           "the record is kept (set aside, byte-identical), not cleared")
            XCTAssertFalse(mock.invocationNames.contains { $0.hasPrefix("Battery Limit") && $0 != "Battery Limit Get" },
                           "no Set on a guess: the pre-Top-Up limit is unknown")
        }
    }

    // MARK: - item 5, added with the fix (new API: suite seam, three-state read)

    private func withSuite(_ body: (UserDefaults, String) async -> Void) async {
        let suite = "TopUpRelaunchUnreadableTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        await body(d, suite)
    }

    func testTheRealTopUpStoreNamesAllThreeStatesAndWillNotDestroyUnreadableBytes() async {
        await withSuite { d, suite in
            let store = UserDefaultsTopUpStore(suiteName: suite)
            XCTAssertEqual(store.loadDetailed(), .none)
            let s = TopUpState(capturedLimit: 80, startedAt: base)
            store.save(s)
            XCTAssertEqual(store.loadDetailed(), .state(s))
            d.set(topUpGarbage, forKey: topUpKey)
            XCTAssertEqual(store.loadDetailed(), .unreadable)
            store.save(TopUpState(capturedLimit: 90, startedAt: base))
            store.clear()
            XCTAssertEqual(d.data(forKey: topUpKey), topUpGarbage, "neither save nor clear destroys unreadable bytes")
        }
    }

    /// When the limit reads something other than 100 the climb is over anyway — nothing is stranded,
    /// so no note (it would be false), only the log line.
    func testAnUnreadableRecordWithTheLimitAlreadyBelow100AddsNoNote() async {
        await withSuite { d, suite in
            d.set(topUpGarbage, forKey: topUpKey)
            let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "80")])
            let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                           custodyStore: MockLastSetCustodyStore(nil),
                                           clock: MockMonotonicClock(box: MockClockBox(0)))
            let c = controller(engine: engine, store: UserDefaultsTopUpStore(suiteName: suite))
            await c.resumeOnLaunch()
            XCTAssertNil(c.note)
            XCTAssertTrue(c.recordUnreadable)
            XCTAssertEqual(c.phase, .idle)
        }
    }

    // MARK: - final review F3: once per record, then aside; cleared by the next user Set

    private func engineReading(_ v: String?) -> ChargeLimitEngine {
        let first: MockShortcutRunner.Scripted = v.map { .init(.success(stdout: ""), file: $0) } ?? getFails
        return ChargeLimitEngine(runner: MockShortcutRunner([first]), captureStore: MockPauseCaptureStore(),
                                 custodyStore: MockLastSetCustodyStore(nil),
                                 clock: MockMonotonicClock(box: MockClockBox(0)))
    }

    /// A KNOWN limit other than 100: the climb is over, the record has nothing left to do — it is moved
    /// aside (kept, byte-identical), and no note is posted.
    func testAKnownLimitBelow100SetsTheUnreadableRecordAside() async {
        await withSuite { d, suite in
            d.set(topUpGarbage, forKey: topUpKey)
            let c = controller(engine: engineReading("80"), store: UserDefaultsTopUpStore(suiteName: suite))
            await c.resumeOnLaunch()
            XCTAssertNil(d.object(forKey: topUpKey), "the unreadable record no longer sits on the live key")
            XCTAssertEqual(asideKeys(d).first.flatMap { d.data(forKey: $0) }, topUpGarbage, "kept, byte-identical")
            XCTAssertNil(c.note)
        }
    }

    /// For a user who keeps 100%, the note must not re-post at every launch: it is shown ONCE for this
    /// record, and the record is then set aside, so the next launch finds nothing.
    func testTheNoteIsShownOncePerRecordNotEveryLaunch() async {
        await withSuite { d, suite in
            d.set(topUpGarbage, forKey: topUpKey)
            let first = controller(engine: engineReading("100"), store: UserDefaultsTopUpStore(suiteName: suite))
            await first.resumeOnLaunch()
            XCTAssertNotNil(first.note, "shown once")
            XCTAssertEqual(asideKeys(d).first.flatMap { d.data(forKey: $0) }, topUpGarbage, "then set aside")
            let second = controller(engine: engineReading("100"), store: UserDefaultsTopUpStore(suiteName: suite))
            await second.resumeOnLaunch()
            XCTAssertNil(second.note, "the next launch does not post it again")
        }
    }

    /// The note is cleared by the next successful user Set — the user has now set a limit.
    func testTheNoteIsClearedByTheNextSuccessfulUserSet() async {
        await withSuite { d, suite in
            d.set(topUpGarbage, forKey: topUpKey)
            let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "100"),            // relaunch read
                                           setOK, .init(.success(stdout: ""), file: "85")])    // user Set 85
            let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                           custodyStore: MockLastSetCustodyStore(nil),
                                           clock: MockMonotonicClock(box: MockClockBox(0)))
            let c = controller(engine: engine, store: UserDefaultsTopUpStore(suiteName: suite))
            await c.resumeOnLaunch()
            XCTAssertNotNil(c.note)
            _ = await engine.userSetLimit(85)
            XCTAssertNil(c.note, "the user has set a limit — the note has done its job")
        }
    }

    /// Only a USER Set answers the note. A SCHEDULE Set lands a custody too, but the schedule is not
    /// the user responding to "set your limit" — the note stays until the user's own Set.
    func testAScheduleSetDoesNotClearTheNoteButTheNextUserSetDoes() async {
        await withSuite { d, suite in
            d.set(topUpGarbage, forKey: topUpKey)
            let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "100"),            // relaunch read
                                           setOK, .init(.success(stdout: ""), file: "85"),     // schedule Set 85
                                           setOK, .init(.success(stdout: ""), file: "80")])    // user Set 80
            let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                           custodyStore: MockLastSetCustodyStore(nil),
                                           clock: MockMonotonicClock(box: MockClockBox(0)))
            let c = controller(engine: engine, store: UserDefaultsTopUpStore(suiteName: suite))
            await c.resumeOnLaunch()
            let posted = c.note
            XCTAssertNotNil(posted)
            let scheduled = await engine.userSetLimit(85, source: .schedule)
            XCTAssertTrue(scheduled.didWrite, "fixture: the schedule Set landed")
            XCTAssertEqual(engine.lastSetCustody?.value, 85, "fixture: and wrote a custody")
            XCTAssertEqual(c.note, posted, "a schedule Set is not the user answering the note")
            let user = await engine.userSetLimit(80)
            XCTAssertTrue(user.didWrite)
            XCTAssertNil(c.note, "the next user Set clears it")
        }
    }

    // MARK: - final review F7: persist-before-Set holds even when the set-aside fails

    /// A store whose record is unreadable and whose set-aside cannot take (it inherits the protocol's
    /// no-op) — and which, like the real store, will not save over the unreadable record.
    final class StuckUnreadableTopUpStore: TopUpStoring, @unchecked Sendable {
        private(set) var saves = 0
        func load() -> TopUpState? { nil }
        func loadDetailed() -> TopUpStateLoad { .unreadable }
        func save(_ s: TopUpState) { saves += 1 }
        func clear() {}
    }

    /// If the old record is STILL unreadable after the set-aside, the new record cannot be written, so
    /// the Set 100 must not happen — a climb with no persisted record could never be reverted after a
    /// relaunch (persist-before-Set). Abort with a note instead.
    func testANewTopUpAbortsWithoutRaisingTheLimitWhenTheOldRecordCannotBeSetAside() async {
        let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "80")])
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(nil),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)
        let store = StuckUnreadableTopUpStore()
        let c = controller(engine: engine, store: store)
        let outcome = await c.topUp()
        XCTAssertEqual(outcome, .couldNotStart)
        XCTAssertFalse(mock.invocationNames.contains("Battery Limit 100"), "the limit is not raised")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNotNil(c.note, "the refusal is said, not silent")
        XCTAssertEqual(store.saves, 0, "nothing is written over the unreadable record")
    }

    /// With no readable limit at all the note says "may", never "is".
    func testAnUnreadableRecordWithNoReadableLimitSaysMayNotIs() async {
        await withSuite { d, suite in
            d.set(topUpGarbage, forKey: topUpKey)
            let engine = ChargeLimitEngine(runner: MockShortcutRunner([getFails]), captureStore: MockPauseCaptureStore(),
                                           custodyStore: MockLastSetCustodyStore(nil),
                                           clock: MockMonotonicClock(box: MockClockBox(0)))
            let c = controller(engine: engine, store: UserDefaultsTopUpStore(suiteName: suite))
            await c.resumeOnLaunch()
            XCTAssertTrue(c.note?.contains("may still be 100%") ?? false, c.note ?? "nil")
        }
    }

    /// A NEW Top Up is the one moment the unreadable record is replaced — its bytes moved aside first.
    func testANewTopUpSetsTheUnreadableRecordAsideBeforeSaving() async {
        await withSuite { d, suite in
            d.set(topUpGarbage, forKey: topUpKey)
            let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "80"),   // engine.sync
                                           setOK, .init(.success(stdout: ""), file: "100")])  // Set 100 + verify
            let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                           custodyStore: MockLastSetCustodyStore(nil),
                                           clock: MockMonotonicClock(box: MockClockBox(0)))
            await engine.sync(.popoverOpen)
            let store = UserDefaultsTopUpStore(suiteName: suite)
            let c = controller(engine: engine, store: store)
            _ = await c.topUp()
            let aside = d.dictionaryRepresentation().keys.filter { $0.hasPrefix(topUpKey + ".unreadable.") }
            XCTAssertEqual(aside.first.flatMap { d.data(forKey: $0) }, topUpGarbage, "the old bytes are kept")
            XCTAssertEqual(store.loadDetailed().state?.capturedLimit, 80, "the new record is saved")
        }
    }

    func testTheFrozenV1TopUpBytesStillDecode() throws {
        let v1 = #"{"capturedLimit":85,"startedAt":700000000}"#
        XCTAssertEqual(try JSONDecoder().decode(TopUpState.self, from: Data(v1.utf8)),
                       TopUpState(capturedLimit: 85, startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000)))
    }

    // MARK: - item 6: the real custody store over real bytes (added with the fix — new suite seam)

    func testTheRealCustodyStoreNamesAllThreeStates() {
        let suite = "TopUpRelaunchUnreadableTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = UserDefaultsLastSetCustodyStore(suiteName: suite)
        XCTAssertEqual(store.loadDetailed(), .none)
        store.save(LastSetCustody(value: 85, at: base))
        XCTAssertEqual(store.loadDetailed(), .custody(LastSetCustody(value: 85, at: base)))
        d.set(Data("{\"value\":".utf8), forKey: "chargeLimit.lastSetCustody.v1")
        XCTAssertEqual(store.loadDetailed(), .unreadable)
        XCTAssertNil(store.load(), "the two-state shape still has no value to offer")
    }

    /// The engine knows the difference, and a fresh Set retires the unreadable witness.
    func testTheEngineFlagsAnUnreadableCustodyAndAFreshSetClearsIt() async {
        let suite = "TopUpRelaunchUnreadableTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(Data("{\"value\":".utf8), forKey: "chargeLimit.lastSetCustody.v1")
        let mock = MockShortcutRunner([setOK, .init(.success(stdout: ""), file: "85")])
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: UserDefaultsLastSetCustodyStore(suiteName: suite),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        XCTAssertTrue(engine.custodyUnreadable)
        XCTAssertNil(engine.lastSetCustody)
        _ = await engine.userSetLimit(85)
        XCTAssertFalse(engine.custodyUnreadable)
        XCTAssertEqual(engine.lastSetCustody?.value, 85)
    }

    // MARK: - item 6: the custody decoder

    /// THE TRIPWIRE: bytes as every release since `21c2927` has written them (`Date` as seconds since
    /// 2001, `JSONEncoder`'s default).
    func testTheFrozenV1CustodyBytesStillDecode() throws {
        let v1 = #"{"value":100,"at":700000000}"#
        XCTAssertEqual(try JSONDecoder().decode(LastSetCustody.self, from: Data(v1.utf8)),
                       LastSetCustody(value: 100, at: Date(timeIntervalSinceReferenceDate: 700_000_000)))
    }

    func testACustodyCarryingAnUnknownFieldStillDecodes() throws {
        let json = #"{"value":85,"at":700000000,"source":"schedule"}"#
        XCTAssertEqual(try JSONDecoder().decode(LastSetCustody.self, from: Data(json.utf8)).value, 85)
    }
}
