import XCTest

/// #30 §4.6: the adapter "last" record (`adapter.last.v1`) — round trip, tolerant decode, and the
/// source writing it on every successful `.connected` read (and only then).
@MainActor
final class AdapterLastStoreTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "AdapterLastStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    final class MockReader: PowerAdapterReading {
        var state: PowerAdapterReadState
        init(_ state: PowerAdapterReadState) { self.state = state }
        func readDetailed() -> PowerAdapterReadState { state }
    }

    private let sample = LastAdapterRecord(watts: 94, voltage_mV: 20000, current_mA: 4700, activePdIndex: 3, ts: 1_757_000_000)

    func testEmptyIsNil() {
        XCTAssertNil(AdapterLastStore(defaults: defaults).load())
    }

    func testRoundTrip() {
        let store = AdapterLastStore(defaults: defaults)
        store.save(sample)
        XCTAssertEqual(store.load(), sample)
        XCTAssertNotNil(defaults.data(forKey: "adapter.last.v1"), "stored under the versioned key")
        store.clear()
        XCTAssertNil(store.load())
    }

    func testOptionalFieldsSurviveAsNil() {
        let store = AdapterLastStore(defaults: defaults)
        let bare = LastAdapterRecord(watts: 30, voltage_mV: nil, current_mA: nil, activePdIndex: nil, ts: 1)
        store.save(bare)
        XCTAssertEqual(store.load(), bare)
        XCTAssertNil(bare.rungVoltageText)
        XCTAssertEqual(sample.rungVoltageText, "20 V rung")
    }

    func testCorruptBlobIsNilNotACrash() {
        let store = AdapterLastStore(defaults: defaults)
        defaults.set(Data("not json".utf8), forKey: "adapter.last.v1")
        XCTAssertNil(store.load())
        defaults.set(Data("{\"watts\":\"ninety\"}".utf8), forKey: "adapter.last.v1")
        XCTAssertNil(store.load(), "wrong field type → nil")
        defaults.set(Data("{\"voltage_mV\":20000}".utf8), forKey: "adapter.last.v1")
        XCTAssertNil(store.load(), "missing required fields → nil")
        defaults.set("a string, not data", forKey: "adapter.last.v1")
        XCTAssertNil(store.load(), "wrong storage type → nil")
    }

    func testFutureFieldsAreIgnored() {
        let store = AdapterLastStore(defaults: defaults)
        defaults.set(Data("{\"watts\":94,\"ts\":5,\"newField\":true}".utf8), forKey: "adapter.last.v1")
        XCTAssertEqual(store.load(), LastAdapterRecord(watts: 94, voltage_mV: nil, current_mA: nil, activePdIndex: nil, ts: 5))
    }

    // MARK: - the source writes on every successful connected read

    func testSourceSavesOnConnectedRead() {
        let adapter = PowerAdapter(watts: 94, voltage_mV: 20000, current_mA: 4700, pdProfiles: [], activePdIndex: 3)
        let reader = MockReader(.connected(adapter))
        let store = AdapterLastStore(defaults: defaults)
        let source = PowerAdapterSource(reader: reader, lastStore: store, now: { Date(timeIntervalSince1970: 1_757_000_000) })
        XCTAssertNil(source.lastRecord, "nothing stored yet")
        source.refresh()
        XCTAssertEqual(source.lastRecord, sample)
        XCTAssertEqual(store.load(), sample)
    }

    func testSourceDoesNotOverwriteOnNoAdapterOrFailure() {
        let store = AdapterLastStore(defaults: defaults)
        store.save(sample)
        let reader = MockReader(.noAdapter)
        let source = PowerAdapterSource(reader: reader, lastStore: store, now: { Date(timeIntervalSince1970: 9) })
        XCTAssertEqual(source.lastRecord, sample, "loaded at init")
        source.refresh()
        XCTAssertEqual(store.load(), sample)
        reader.state = .unavailable("relocated")
        source.refresh()
        XCTAssertEqual(store.load(), sample)
        XCTAssertEqual(source.lastRecord, sample)
    }

    func testSourceUpdatesTimestampOnEachConnectedRead() {
        var t = 100
        let reader = MockReader(.connected(PowerAdapter(watts: 70, voltage_mV: nil, current_mA: nil)))
        let source = PowerAdapterSource(reader: reader, lastStore: AdapterLastStore(defaults: defaults),
                                        now: { Date(timeIntervalSince1970: TimeInterval(t)) })
        source.refresh(); XCTAssertEqual(source.lastRecord?.ts, 100)
        t = 200
        source.refresh(); XCTAssertEqual(source.lastRecord?.ts, 200)
        XCTAssertEqual(source.lastRecord?.watts, 70)
    }
}
