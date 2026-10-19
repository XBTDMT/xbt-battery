import XCTest

/// Final review F6: a stored value of the WRONG TYPE is not "nothing stored".
///
/// `UserDefaults.data(forKey:)` returns nil both when the key is absent AND when it holds something that
/// is not `Data` (a number, a string — a hand edit, a defaults-write, a foreign build). Three stores fed
/// that nil straight into their "nothing stored" branch, so a present-but-unusable value read as the
/// legitimate empty — the exact collapse the three-state reads exist to prevent. The rule now: when
/// `data(forKey:)` is nil, `object(forKey:) == nil ? .none : .corrupt`.
@MainActor
final class WrongTypeValueReadTests: XCTestCase {

    private var suite: String!
    private var d: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "WrongTypeValueReadTests.\(UUID().uuidString)"
        d = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        d.removePersistentDomain(forName: suite)
        d = nil; suite = nil
        super.tearDown()
    }

    // MARK: - charge schedule (ScheduleRunner's shared decode helper)

    func testAWrongTypeChargeScheduleConfigIsCorruptNotAbsent() {
        d.set(42, forKey: "chargeSchedule.config.v1")
        XCTAssertEqual(UserDefaultsScheduleStore(suiteName: suite).loadConfigDetailed(), .corrupt)
    }

    func testAWrongTypeFiredSetIsCorruptNotAbsent() {
        d.set("fired", forKey: "chargeSchedule.fired.v1")
        XCTAssertEqual(UserDefaultsScheduleStore(suiteName: suite).loadFiredDetailed(), .corrupt)
    }

    /// …and the set-aside can move a value that is not `Data` (it used to require `data(forKey:)`).
    func testAWrongTypeChargeScheduleConfigCanBeSetAside() {
        d.set(42, forKey: "chargeSchedule.config.v1")
        UserDefaultsScheduleStore(suiteName: suite).setAsideUnreadableConfig()
        XCTAssertNil(d.object(forKey: "chargeSchedule.config.v1"))
        let aside = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("chargeSchedule.config.v1.unreadable.") }
        XCTAssertEqual(aside.first.flatMap { d.object(forKey: $0) as? Int }, 42, "kept, same value")
    }

    // MARK: - sleep/wake

    func testAWrongTypeSleepWakeConfigIsUnreadableNotAbsent() {
        d.set("23:00", forKey: "sleepWakeSchedule.config.v1")
        XCTAssertEqual(UserDefaultsSleepWakeStore(suiteName: suite).loadConfigDetailed(), .unreadable)
    }

    func testAWrongTypeSleepWakeConfigIsNotSavedOverAndCanBeSetAside() {
        d.set("23:00", forKey: "sleepWakeSchedule.config.v1")
        let store = UserDefaultsSleepWakeStore(suiteName: suite)
        store.saveConfig(SleepWakeScheduleConfig(sleepEnabled: true))
        XCTAssertEqual(d.string(forKey: "sleepWakeSchedule.config.v1"), "23:00", "not saved over")
        store.setAsideUnreadableConfig()
        XCTAssertNil(d.object(forKey: "sleepWakeSchedule.config.v1"))
        let aside = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("sleepWakeSchedule.config.v1.unreadable.") }
        XCTAssertEqual(aside.first.flatMap { d.string(forKey: $0) }, "23:00")
    }

    // MARK: - pause capture (SWEEP H2: bytes under the key are evidence a pause happened)

    func testAWrongTypePauseCaptureIsCorruptNotAbsent() {
        d.set(80, forKey: UserDefaultsPauseCaptureStore.key)
        let load = UserDefaultsPauseCaptureStore(suiteName: suite).loadDetailed()
        XCTAssertEqual(load, .corrupt)
        XCTAssertTrue(load.indicatesPaused, "something is stored under the pause key, so a pause happened")
    }

    // MARK: - no regression: absent is still absent

    func testAbsentKeysStillReadAsNothingStored() {
        XCTAssertEqual(UserDefaultsScheduleStore(suiteName: suite).loadConfigDetailed(), ScheduleConfigLoad.none)
        XCTAssertEqual(UserDefaultsScheduleStore(suiteName: suite).loadFiredDetailed(), FiredSetLoad.none)
        XCTAssertEqual(UserDefaultsSleepWakeStore(suiteName: suite).loadConfigDetailed(), SleepWakeConfigLoad.none)
        XCTAssertEqual(UserDefaultsPauseCaptureStore(suiteName: suite).loadDetailed(), PauseCaptureLoad.none)
    }
}
