import XCTest

/// Redman sweep item 4: an unreadable stored keep-awake preset must not silently become `.default`
/// AND be saved back.
///
/// THE DEFECT. `KeepAwakePresetStore.load()` turned an undecodable `keepAwake.lastPreset.v1` into
/// `.default` (indefinite / system) with no third state. The Now tab's mini switch does
/// `let p = keepAwake.lastPreset; keepAwake.enable(scope: p.scope, duration: p.duration)` and `enable`
/// saves the preset on every call — so one tap used the default AND wrote it over the user's preset.
///
/// Real `UserDefaults` bytes in a throwaway suite, through the controller's public `enable` (the call
/// every surface makes; the Now switch's exact two lines are reproduced verbatim).
@MainActor
final class KeepAwakePresetUnreadableTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!
    private let key = "keepAwake.lastPreset.v1"
    private let garbage = Data("{\"duration\":{\"timed\":{\"_0\":36".utf8)

    override func setUp() {
        super.setUp()
        suite = "KeepAwakePresetUnreadableTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil; suite = nil
        super.tearDown()
    }

    private func controller() -> KeepAwakeController {
        KeepAwakeController(assertion: KeepAwakeTests.MockSleepAssertion(),
                            scheduler: KeepAwakeTests.MockOneShot(),
                            clock: MockMonotonicClock(box: MockClockBox(0)),
                            presetStore: KeepAwakePresetStore(defaults: defaults))
    }

    /// The Now tab's mini switch, verbatim (BatteryPopoverView: `keepAwake.enableLastPreset()` — final
    /// review F2; before it the view inlined `let p = keepAwake.lastPreset; keepAwake.enable(...)`).
    private func tapNowSwitch(_ c: KeepAwakeController) {
        c.enableLastPreset()
    }

    /// F2: the Now switch is the ONE surface that stays session-only — it never moves the bytes aside.
    func testTheNowSwitchNeverSetsTheUnreadablePresetAside() {
        defaults.set(garbage, forKey: key)
        let c = controller()
        tapNowSwitch(c)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(key + ".unreadable.") }, [])
        XCTAssertTrue(c.lastPresetUnreadable)
    }

    // MARK: - nothing is saved over the unreadable bytes

    func testTheNowSwitchDoesNotSaveTheDefaultOverAnUnreadablePreset() {
        defaults.set(garbage, forKey: key)
        let c = controller()
        tapNowSwitch(c)
        XCTAssertEqual(defaults.data(forKey: key), garbage, "the default must not be written back over the blob")
    }

    /// Final review F2 (was `testAnExplicitPresetPickDoesNotOverwriteAnUnreadablePresetEither`): a
    /// deliberate pick on the Automation page (`keepAwake.enable(scope:duration:)`, AutomationPage) is the
    /// user choosing a new preset — exactly what the key records. It moves the unreadable bytes aside
    /// (kept, byte-identical, dated key), then saves. Only the Now switch stays session-only.
    func testAnAutomationPagePickSetsTheUnreadablePresetAsideThenSaves() {
        defaults.set(garbage, forKey: key)
        let c = controller()
        c.enable(scope: .system, duration: .timed(3600))
        let aside = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(key + ".unreadable.") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(aside.first.flatMap { defaults.data(forKey: $0) }, garbage, "byte-identical side copy")
        XCTAssertEqual(KeepAwakePresetStore(defaults: defaults).loadDetailed(),
                       .preset(KeepAwakePreset(duration: .timed(3600), scope: .system)), "then saved")
        XCTAssertFalse(c.lastPresetUnreadable)
    }

    func testTheStoreItselfRefusesToSaveOverUnreadableBytes() {
        defaults.set(garbage, forKey: key)
        KeepAwakePresetStore(defaults: defaults).save(KeepAwakePreset(duration: .whileOnAC, scope: .system))
        XCTAssertEqual(defaults.data(forKey: key), garbage)
    }

    // MARK: - what the switch DOES meanwhile

    /// The switch still works: it runs the DOCUMENTED default (indefinite, system scope) for this
    /// session — the same preset its label already names — rather than being a dead control.
    func testTheNowSwitchRunsTheDocumentedDefaultForThisSession() {
        defaults.set(garbage, forKey: key)
        let c = controller()
        tapNowSwitch(c)
        XCTAssertTrue(c.isOn)
        XCTAssertEqual(c.session?.duration, .indefinite)
        XCTAssertEqual(c.session?.scope, .system)
    }

    /// An explicit pick is remembered for the rest of the SESSION (in memory), so the Now switch then
    /// re-arms what the user last chose — it is only the disk write that is withheld.
    func testAnExplicitPickIsRememberedInMemoryForTheSession() {
        defaults.set(garbage, forKey: key)
        let c = controller()
        c.enable(scope: .systemAndDisplay, duration: .timed(1800))
        XCTAssertEqual(c.lastPreset, KeepAwakePreset(duration: .timed(1800), scope: .systemAndDisplay))
    }

    // MARK: - the three states and the way out (added with the fix — new API)

    func testTheStoreNamesAllThreeStates() {
        let store = KeepAwakePresetStore(defaults: defaults)
        XCTAssertEqual(store.loadDetailed(), .none)
        store.save(KeepAwakePreset(duration: .whileOnAC, scope: .system))
        XCTAssertEqual(store.loadDetailed(), .preset(KeepAwakePreset(duration: .whileOnAC, scope: .system)))
        defaults.set(garbage, forKey: key)
        XCTAssertEqual(store.loadDetailed(), .unreadable)
        defaults.set(42, forKey: key)
        XCTAssertEqual(store.loadDetailed(), .unreadable, "a value of the wrong TYPE is not 'nothing saved'")
    }

    func testTheControllerKnowsThePresetWasUnreadable() {
        defaults.set(garbage, forKey: key)
        XCTAssertTrue(controller().lastPresetUnreadable)
        defaults.removeObject(forKey: key)
        XCTAssertFalse(controller().lastPresetUnreadable, "nothing saved is the legitimate empty")
    }

    func testSettingTheUnreadablePresetAsideKeepsItsBytesAndResumesSaving() {
        defaults.set(garbage, forKey: key)
        let c = controller()
        c.setAsideUnreadablePreset()
        XCTAssertFalse(c.lastPresetUnreadable)
        let aside = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(key + ".unreadable.") }
        XCTAssertEqual(aside.first.flatMap { defaults.data(forKey: $0) }, garbage, "the bytes are kept")
        c.enable(scope: .system, duration: .timed(3600))
        XCTAssertEqual(KeepAwakePresetStore(defaults: defaults).loadDetailed(),
                       .preset(KeepAwakePreset(duration: .timed(3600), scope: .system)))
    }

    // MARK: - no regression

    func testAReadablePresetIsStillSavedOnEveryEnable() {
        let c = controller()
        c.enable(scope: .system, duration: .whileOnAC)
        XCTAssertEqual(KeepAwakePresetStore(defaults: defaults).load(), KeepAwakePreset(duration: .whileOnAC, scope: .system))
    }

    // MARK: - tolerant decoder

    /// THE TRIPWIRE: the bytes every release since `56942f8` has written (synthesized enum coding).
    func testTheFrozenV1PresetBytesStillDecode() throws {
        let v1 = #"{"duration":{"timed":{"_0":3600}},"scope":{"systemAndDisplay":{}}}"#
        XCTAssertEqual(try JSONDecoder().decode(KeepAwakePreset.self, from: Data(v1.utf8)),
                       KeepAwakePreset(duration: .timed(3600), scope: .systemAndDisplay))
    }

    func testAPresetCarryingAnUnknownFieldStillDecodes() throws {
        let json = #"{"duration":{"whileOnAC":{}},"scope":{"system":{}},"display":"dim"}"#
        XCTAssertEqual(try JSONDecoder().decode(KeepAwakePreset.self, from: Data(json.utf8)),
                       KeepAwakePreset(duration: .whileOnAC, scope: .system))
    }
}
