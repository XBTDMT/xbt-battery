import XCTest

/// Redman sweep item 1: an unreadable stored CHARGE-SCHEDULE config must never be written over.
///
/// THE DEFECT. SWEEP H4 made the read three-state (`ScheduleConfigLoad.corrupt`) but the runner still
/// fell back to `.empty` and let the next edit save over the blob. `.empty` has no rules and
/// `presetOffered == false`, so Settings shows the first-run offer — and one tap on "Use suggested" or
/// "Set up manually" replaced the user's stored rules for good, with nothing on screen saying so.
///
/// These tests drive the REAL `UserDefaultsScheduleStore` over REAL bytes in a named suite, through
/// the runner's public edit API — the entry points the Settings buttons call.
@MainActor
final class ScheduleConfigUnreadableTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!
    private let configKey = "chargeSchedule.config.v1"
    private let garbage = Data("{\"enabled\":true,\"rules\":[{\"id\":".utf8)

    override func setUp() {
        super.setUp()
        suite = "ScheduleConfigUnreadableTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil; suite = nil
        super.tearDown()
    }

    private let A = ChargeRule(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!, hour: 22, minute: 0, limit: 80)

    private func makeRunner() async -> (ScheduleRunner, MockShortcutRunner, UserDefaultsScheduleStore) {
        let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "100")])
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)
        let store = UserDefaultsScheduleStore(suiteName: suite)
        let runner = ScheduleRunner(engine: engine, store: store,
                                    clock: FixedClock(Date(timeIntervalSince1970: 1_781_150_000)),
                                    pacer: NullPacer(), isSetupReady: { true })
        return (runner, mock, store)
    }

    final class FixedClock: ScheduleClock, Sendable { let d: Date; init(_ d: Date) { self.d = d }; func now() -> Date { d } }
    final class NullPacer: SchedulePacing {
        func start(interval: TimeInterval, onTick: @escaping () -> Void) {}
        func stop() {}
    }

    // MARK: - the two first-run buttons: a deliberate tap sets the blob ASIDE, then proceeds
    //
    // Owner/controller decision (2026-10-16): no dead buttons. The first-run offer is on screen whenever
    // the config is unreadable (the fallback `.empty` has no rules and `presetOffered == false`), so a
    // tap on "Use suggested" / "Set up manually" is the user's explicit act of starting over. It first
    // moves the unreadable bytes aside — kept, byte-identical, under a dated key — and then proceeds.
    // (Replaces the first cut's `testUseSuggestedDoesNotOverwrite…` / `testSetUpManuallyDoesNot…`, which
    // pinned the refusal this decision reverses. The bytes are still never written over.)

    private func asideKeys() -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(configKey + ".unreadable.") }.sorted()
    }

    func testUseSuggestedSetsTheUnreadableConfigAsideThenSavesThePreset() async {
        defaults.set(garbage, forKey: configKey)
        let (runner, _, store) = await makeRunner()
        runner.applyStarterPreset()
        XCTAssertEqual(asideKeys().count, 1, "the unreadable bytes were moved to exactly one side key")
        XCTAssertEqual(asideKeys().first.flatMap { defaults.data(forKey: $0) }, garbage, "byte-identical")
        XCTAssertEqual(store.loadConfigDetailed().config?.rules.count, 2, "the starter preset saved")
        XCTAssertEqual(store.loadConfigDetailed().config?.enabled, true)
        XCTAssertFalse(runner.configUnreadable)
    }

    func testSetUpManuallySetsTheUnreadableConfigAsideThenSaves() async {
        defaults.set(garbage, forKey: configKey)
        let (runner, _, store) = await makeRunner()
        runner.markPresetOffered()
        XCTAssertEqual(asideKeys().first.flatMap { defaults.data(forKey: $0) }, garbage, "byte-identical")
        XCTAssertEqual(store.loadConfigDetailed().config,
                       ChargeScheduleConfig(enabled: false, rules: [], presetOffered: true))
        XCTAssertFalse(runner.configUnreadable)
    }

    // MARK: - F1 (final review): the enable toggle and Add/Save are deliberate too
    //
    // The first cut only routed the two first-run buttons through the set-aside — but those buttons are
    // rendered only `if schedule.config.enabled`, and an unreadable config loads as `.empty` (disabled).
    // The toggle that would reveal them called `setEnabled`, which `mutate` refused, so every schedule
    // control was dead. These tests drive the exact methods the views' bindings and buttons call
    // (`SettingsView` / `AutomationPage`: `schedule.setEnabled($0)`, `schedule.addRule(d)`), so a dead UI
    // path fails here.

    func testTheEnableToggleSetsTheUnreadableConfigAsideThenEnables() async {
        defaults.set(garbage, forKey: configKey)
        let (runner, _, store) = await makeRunner()
        runner.setEnabled(true)                      // the toggle's binding setter, both views
        XCTAssertEqual(asideKeys().first.flatMap { defaults.data(forKey: $0) }, garbage, "byte-identical side copy")
        XCTAssertTrue(runner.config.enabled, "the toggle took effect — it does not snap back")
        XCTAssertEqual(store.loadConfigDetailed().config?.enabled, true, "and it saved")
        XCTAssertFalse(runner.configUnreadable)
    }

    func testTheAutomationPageAddSetsTheUnreadableConfigAsideThenAddsTheRule() async {
        defaults.set(garbage, forKey: configKey)
        let (runner, _, store) = await makeRunner()
        XCTAssertTrue(runner.addRule(A), "AutomationPage.commitDraft's Add is accepted")
        XCTAssertEqual(asideKeys().first.flatMap { defaults.data(forKey: $0) }, garbage)
        XCTAssertEqual(store.loadConfigDetailed().config?.rules, [A])
    }

    /// If anything is still refused (the set-aside did not take), the Automation page says why in plain
    /// words rather than the generic "that change wasn't accepted".
    func testARefusalOnAnUnreadableConfigHasItsOwnPlainMessage() {
        XCTAssertEqual(AutomationPageModel.rejectionMessage(config: .empty, rule: A, isNew: true, configUnreadable: true),
                       "your saved schedule couldn’t be read, so this wasn’t saved")
        XCTAssertNil(AutomationPageModel.rejectionMessage(config: .empty, rule: A, isNew: true),
                     "a readable config with room still accepts the rule")
    }

    /// The background paths stay blocked: starting the runner and recomputing never set the blob aside,
    /// never present a schedule, and never run an autonomous Set from a config that was not read.
    func testNoBackgroundPathSetsTheBlobAsideOrRunsAnything() async {
        defaults.set(garbage, forKey: configKey)
        let (runner, mock, _) = await makeRunner()
        runner.start()
        for _ in 0..<50 { await Task.yield() }
        runner.stop()
        XCTAssertEqual(asideKeys(), [], "nothing but a deliberate user action moves the blob")
        XCTAssertEqual(defaults.data(forKey: configKey), garbage)
        XCTAssertTrue(runner.configUnreadable)
        XCTAssertEqual(runner.config, .empty)
        XCTAssertFalse(mock.invocationNames.contains { $0.hasPrefix("Battery Limit") && $0 != "Battery Limit Get" },
                       "no autonomous Set from a config that was never read")
    }

    /// Defence in depth at the store: whatever a caller does, `saveConfig` will not replace bytes that
    /// are present but will not decode.
    func testTheStoreItselfRefusesToSaveOverUnreadableBytes() {
        defaults.set(garbage, forKey: configKey)
        let store = UserDefaultsScheduleStore(suiteName: suite)
        store.saveConfig(ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true))
        XCTAssertEqual(defaults.data(forKey: configKey), garbage)
    }

    // MARK: - the way out keeps the bytes

    /// The explicit recovery (no screen calls it yet — that is an owner visual decision): the bytes are
    /// MOVED aside under a dated key, never deleted, and only then do edits save again.
    func testSettingTheUnreadableConfigAsideKeepsItsBytesAndUnblocksEdits() async {
        defaults.set(garbage, forKey: configKey)
        let (runner, _, store) = await makeRunner()
        runner.setAsideUnreadableConfig()
        XCTAssertFalse(runner.configUnreadable)
        let asideKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(configKey + ".unreadable.") }
        XCTAssertEqual(asideKeys.count, 1, "the bytes were moved to exactly one set-aside key")
        XCTAssertEqual(asideKeys.first.flatMap { defaults.data(forKey: $0) }, garbage)
        runner.applyStarterPreset()
        XCTAssertEqual(store.loadConfigDetailed().config?.rules.count, 2, "edits save again once set aside")
    }

    // MARK: - no regression: a genuine first run still saves

    func testAFirstRunStillSavesTheStarterPreset() async {
        let (runner, _, store) = await makeRunner()
        XCTAssertFalse(runner.configUnreadable)
        runner.applyStarterPreset()
        XCTAssertEqual(store.loadConfigDetailed().config?.rules.count, 2)
        XCTAssertEqual(store.loadConfigDetailed().config?.enabled, true)
    }

    // MARK: - tolerant decoder (the upgrade landmine)

    /// Bytes from a LATER release carry keys this build does not know — on the config AND on a rule.
    func testAConfigCarryingUnknownFieldsStillDecodes() {
        let json = #"{"enabled":true,"presetOffered":true,"skipHolidays":true,"rules":[{"id":"AAAAAAAA-0000-0000-0000-000000000000","hour":22,"minute":0,"limit":80,"label":"Night"}]}"#
        defaults.set(Data(json.utf8), forKey: configKey)
        let store = UserDefaultsScheduleStore(suiteName: suite)
        XCTAssertEqual(store.loadConfigDetailed(), .config(ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true)))
    }

    /// THE TRIPWIRE: frozen bytes as every release since 4.C (`8daab05`) has written them. Never edit
    /// this fixture to make it pass — decode a new field with `decodeIfPresent`.
    func testTheFrozenV1ConfigBytesStillDecode() throws {
        let v1 = #"{"enabled":false,"rules":[{"id":"AAAAAAAA-0000-0000-0000-000000000000","hour":22,"minute":0,"limit":80}],"presetOffered":true}"#
        XCTAssertEqual(try JSONDecoder().decode(ChargeScheduleConfig.self, from: Data(v1.utf8)),
                       ChargeScheduleConfig(enabled: false, rules: [A], presetOffered: true))
    }

    /// The boundary: a rule missing a field every version has written is not a lenient rule. The whole
    /// config is unreadable — and therefore PRESERVED — rather than silently losing that one rule.
    func testARuleMissingAnAlwaysWrittenFieldMakesTheConfigUnreadableNotShorter() {
        let json = #"{"enabled":true,"presetOffered":true,"rules":[{"id":"AAAAAAAA-0000-0000-0000-000000000000","hour":22,"minute":0}]}"#
        defaults.set(Data(json.utf8), forKey: configKey)
        XCTAssertEqual(UserDefaultsScheduleStore(suiteName: suite).loadConfigDetailed(), .corrupt)
    }

    func testEveryEncodedConfigFieldSurvivesARoundTrip() throws {
        let c = ChargeScheduleConfig(enabled: true, rules: [A], presetOffered: true)
        XCTAssertEqual(try JSONDecoder().decode(ChargeScheduleConfig.self, from: JSONEncoder().encode(c)), c)
    }
}

/// Redman sweep item 2: one undecodable element must not lose the whole fired-set.
///
/// THE DEFECT. The fired-set (`chargeSchedule.fired.v1`) is decoded as ONE `Set<FiredOccurrence>`, so a
/// single bad element made the whole record `.corrupt`; the runner then rebuilt it from nothing (plus the
/// presumed-fired operative occurrence) and saved — every readable record was discarded with the bad one.
@MainActor
final class ScheduleFiredSetTolerantTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!
    private let firedKey = "chargeSchedule.fired.v1"

    override func setUp() {
        super.setUp()
        suite = "ScheduleFiredSetTolerantTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil; suite = nil
        super.tearDown()
    }

    private let A = ChargeRule(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!, hour: 22, minute: 0, limit: 80)
    private let B = ChargeRule(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!, hour: 7, minute: 30, limit: 100)
    private func chicago() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }

    /// One good element (B fired today at 07:30) and one with no `dayKey`.
    private var mixed: Data {
        Data(#"[{"ruleID":"BBBBBBBB-0000-0000-0000-000000000000","dayKey":"2026-06-10"},{"ruleID":"AAAAAAAA-0000-0000-0000-000000000000"}]"#.utf8)
    }

    func testTheStoreKeepsTheReadableElementsOfAPartlyUndecodableFiredSet() {
        defaults.set(mixed, forKey: firedKey)
        let store = UserDefaultsScheduleStore(suiteName: suite)
        XCTAssertEqual(store.loadFiredDetailed().fired,
                       [FiredOccurrence(ruleID: B.id, dayKey: "2026-06-10")],
                       "the readable record survives the bad one")
    }

    /// Through the runner: B's record is kept, AND the operative occurrence (A, tonight) is still
    /// presumed fired — the H4 human-primacy guard is unchanged, because the element that did not decode
    /// could have been exactly that record.
    func testTheRunnerKeepsReadableRecordsAndStillPresumesTheOperativeFired() async {
        defaults.set(mixed, forKey: firedKey)
        let store = UserDefaultsScheduleStore(suiteName: suite)
        store.saveConfig(ChargeScheduleConfig(enabled: true, rules: [A, B], presetOffered: true))
        let mock = MockShortcutRunner([.init(.success(stdout: ""), file: "90")])
        let engine = ChargeLimitEngine(runner: mock, captureStore: MockPauseCaptureStore(),
                                       custodyStore: MockLastSetCustodyStore(),
                                       clock: MockMonotonicClock(box: MockClockBox(0)))
        await engine.sync(.popoverOpen)
        let now = chicago().date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 22, minute: 1))!
        let cal = chicago()
        let runner = ScheduleRunner(engine: engine, store: store,
                                    clock: ScheduleConfigUnreadableTests.FixedClock(now),
                                    pacer: ScheduleConfigUnreadableTests.NullPacer(), isSetupReady: { true },
                                    calendarProvider: { cal })
        XCTAssertTrue(runner.isFired(B), "B's readable record was not thrown away with the bad element")
        XCTAssertTrue(runner.isFired(A), "the operative occurrence is still presumed fired (H4)")
    }

    /// A fired-set whose TOP LEVEL will not decode is still `.corrupt` — tolerance is per element only.
    func testATopLevelThatIsNotAnArrayIsStillCorrupt() {
        defaults.set(Data("{\"ruleID\":".utf8), forKey: firedKey)
        XCTAssertEqual(UserDefaultsScheduleStore(suiteName: suite).loadFiredDetailed(), .corrupt)
    }

    func testTheFrozenV1FiredBytesStillDecode() {
        defaults.set(Data(#"[{"ruleID":"AAAAAAAA-0000-0000-0000-000000000000","dayKey":"2026-06-09"}]"#.utf8), forKey: firedKey)
        XCTAssertEqual(UserDefaultsScheduleStore(suiteName: suite).loadFiredDetailed().fired,
                       [FiredOccurrence(ruleID: A.id, dayKey: "2026-06-09")])
    }

    func testAFiredElementCarryingAnUnknownFieldStillDecodes() {
        defaults.set(Data(#"[{"ruleID":"AAAAAAAA-0000-0000-0000-000000000000","dayKey":"2026-06-09","firedAt":1}]"#.utf8), forKey: firedKey)
        XCTAssertEqual(UserDefaultsScheduleStore(suiteName: suite).loadFiredDetailed().fired,
                       [FiredOccurrence(ruleID: A.id, dayKey: "2026-06-09")])
    }
}
