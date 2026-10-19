import XCTest
import Shared

/// Redman sweep item 3: an unreadable stored SLEEP/WAKE config must never be written over.
///
/// THE DEFECT. AUDIT H3 made the read three-state and disclosed it ("Battery couldn't read its own
/// saved schedule settings…"), but `mutate` still saved every edit — so the first tap on a field wrote
/// the defaults-plus-one-edit over the user's stored schedule.
///
/// What the shipped copy promises is kept: "set the times and apply to take it over". Edits work in
/// memory; nothing is saved over the unreadable blob; a SUCCESSFUL apply (the user's explicit act of
/// authoring the live schedule) moves the blob aside — keeping its bytes — and only then saves.
@MainActor
final class SleepWakeConfigUnreadableTests: XCTestCase {

    /// A store that behaves like the real one: unreadable bytes stay unreadable until set aside, and
    /// every save is recorded.
    final class RecordingStore: SleepWakeScheduleStoring {
        var unreadable: Bool
        var saved: SleepWakeScheduleConfig?
        private(set) var saves = 0
        init(unreadable: Bool) { self.unreadable = unreadable }
        func loadConfigDetailed() -> SleepWakeConfigLoad {
            if unreadable { return .unreadable }
            return saved.map { .config($0) } ?? .none
        }
        func loadConfig() -> SleepWakeScheduleConfig { loadConfigDetailed().configOrEmpty }
        func saveConfig(_ c: SleepWakeScheduleConfig) { saves += 1; saved = c }
    }

    private func controller(_ store: RecordingStore,
                            setter: SleepWakeScheduleControllerTests.FakeSetter = .init())
    -> SleepWakeScheduleController {
        SleepWakeScheduleController(setter: setter,
                                    reader: SleepWakeScheduleControllerTests.FakeReader(nil), store: store)
    }

    // MARK: - the next edit must not save over the blob

    func testNoEditIsSavedOverAnUnreadableConfig() {
        let store = RecordingStore(unreadable: true)
        let c = controller(store)
        c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
        c.setWakeEnabled(true); c.setWakeTime(hour: 7, minute: 0)
        c.setWeekdayMask(127); c.toggleWeekday(bit: 6)
        XCTAssertEqual(store.saves, 0, "no edit may be saved over a config the app could not read")
    }

    /// The edits still take effect IN MEMORY — the shipped copy tells the user to set the times and
    /// apply — and the flag stays up until something is applied.
    func testEditsStillWorkInMemoryWhileUnreadable() {
        let store = RecordingStore(unreadable: true)
        let c = controller(store)
        c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
        XCTAssertTrue(c.config.sleepEnabled)
        XCTAssertEqual(c.config.sleepHour, 23)
        XCTAssertTrue(c.configUnreadable)
    }

    /// A FAILED apply wrote nothing to the machine, so it is no licence to replace the stored config.
    func testAFailedApplyDoesNotSaveOverTheUnreadableConfig() {
        let store = RecordingStore(unreadable: true)
        let setter = SleepWakeScheduleControllerTests.FakeSetter()
        setter.cannedResult = .failure(.helperError("error:set-failed"))
        let c = controller(store, setter: setter)
        c.setSleepEnabled(true)
        c.apply(confirmed: true)
        XCTAssertEqual(store.saves, 0)
    }

    // MARK: - the real store, real bytes

    private func withSuite(_ body: (UserDefaults, String) -> Void) {
        let suite = "SleepWakeConfigUnreadableTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        body(d, suite)
    }
    private let key = "sleepWakeSchedule.config.v1"
    private let garbage = Data("{\"sleepEnabled\":tru".utf8)

    func testTheRealStoreRefusesToSaveOverUnreadableBytes() {
        withSuite { d, suite in
            d.set(garbage, forKey: key)
            UserDefaultsSleepWakeStore(suiteName: suite).saveConfig(SleepWakeScheduleConfig(sleepEnabled: true))
            XCTAssertEqual(d.data(forKey: key), garbage)
        }
    }

    /// End to end on real bytes: edits leave the blob alone; a SUCCESSFUL apply moves it aside (its
    /// bytes kept under a dated key) and only then saves what the user applied.
    func testASuccessfulApplySetsTheUnreadableBlobAsideThenSaves() {
        withSuite { d, suite in
            d.set(garbage, forKey: key)
            let store = UserDefaultsSleepWakeStore(suiteName: suite)
            let c = SleepWakeScheduleController(setter: SleepWakeScheduleControllerTests.FakeSetter(),
                                                reader: SleepWakeScheduleControllerTests.FakeReader(nil),
                                                store: store)
            c.setSleepEnabled(true); c.setSleepTime(hour: 23, minute: 30)
            XCTAssertEqual(d.data(forKey: key), garbage, "edits alone never touch the blob")
            c.apply(confirmed: true)
            let aside = d.dictionaryRepresentation().keys.filter { $0.hasPrefix(key + ".unreadable.") }
            XCTAssertEqual(aside.count, 1)
            XCTAssertEqual(aside.first.flatMap { d.data(forKey: $0) }, garbage, "the old bytes are kept")
            XCTAssertEqual(store.loadConfigDetailed().configOrEmpty.sleepHour, 23, "the applied config is saved")
            XCTAssertFalse(c.configUnreadable)
        }
    }

    // MARK: - final review F5: the flag comes from a RE-READ after the set-aside

    /// If the set-aside does not take (this store cannot move anything), a successful apply must NOT save
    /// over the still-unreadable blob, and the flag must stay up — it is set from a re-read, not assumed.
    func testASuccessfulApplyWhoseSetAsideDidNotTakeSavesNothingAndKeepsTheFlag() {
        let store = RecordingStore(unreadable: true)        // inherits the no-op setAsideUnreadableConfig()
        let c = controller(store)
        c.setSleepEnabled(true)
        c.apply(confirmed: true)
        XCTAssertEqual(store.saves, 0, "never saved over a blob that is still unreadable")
        XCTAssertTrue(c.configUnreadable, "set from the re-read: the stored config is still unreadable")
    }

    // MARK: - no regression

    func testAReadableConfigStillSavesEveryEdit() {
        let store = RecordingStore(unreadable: false)
        let c = controller(store)
        c.setSleepEnabled(true)
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(store.saved?.sleepEnabled, true)
    }

    // MARK: - tolerant decoder

    func testAConfigCarryingAnUnknownFieldStillDecodes() {
        let json = #"{"sleepEnabled":true,"sleepHour":23,"sleepMinute":30,"wakeEnabled":false,"wakeHour":7,"wakeMinute":0,"weekdayMask":31,"holidays":[1,2]}"#
        XCTAssertEqual(UserDefaultsSleepWakeStore.decode(Data(json.utf8)),
                       .config(SleepWakeScheduleConfig(sleepEnabled: true, sleepHour: 23, sleepMinute: 30)))
    }

    /// THE TRIPWIRE: frozen bytes as every release since `ea354ca` has written them.
    func testTheFrozenV1SleepWakeBytesStillDecode() {
        let v1 = #"{"sleepEnabled":false,"sleepHour":22,"sleepMinute":15,"wakeEnabled":true,"wakeHour":6,"wakeMinute":45,"weekdayMask":96}"#
        XCTAssertEqual(UserDefaultsSleepWakeStore.decode(Data(v1.utf8)),
                       .config(SleepWakeScheduleConfig(sleepEnabled: false, sleepHour: 22, sleepMinute: 15,
                                                       wakeEnabled: true, wakeHour: 6, wakeMinute: 45,
                                                       weekdayMask: 96)))
    }

    func testEveryEncodedSleepWakeFieldSurvivesARoundTrip() throws {
        let c = SleepWakeScheduleConfig(sleepEnabled: true, sleepHour: 1, sleepMinute: 2, wakeEnabled: true,
                                        wakeHour: 3, wakeMinute: 4, weekdayMask: 5)
        XCTAssertEqual(UserDefaultsSleepWakeStore.decode(try JSONEncoder().encode(c)), .config(c))
    }
}
