import XCTest
import Combine

private final class DisplayClocks: @unchecked Sendable {
    private let lock = NSLock()
    private var mono: TimeInterval = 1_000
    func advance(_ s: TimeInterval) { lock.lock(); mono += s; lock.unlock() }
    var value: TimeInterval { lock.lock(); defer { lock.unlock() }; return mono }
    var clocks: MonotonicClocks { MonotonicClocks(monotonicRaw: { self.value }, uptimeRaw: { self.value - 100 }) }
}

/// G-2 · the port source publishes only derived, rounded fields: a new frame whose raw values moved but
/// whose display did not publishes NOTHING; a visible change publishes once.
@MainActor
final class PortPowerSourceDisplayTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var time: DisplayClocks!
    private var src: PortPowerSource!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        suite = "PortPowerSourceDisplayTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        time = DisplayClocks()
        let fixedNow = now
        src = PortPowerSource(defaults: defaults, now: { fixedNow }, clocks: time.clocks,
                              usb: SettableUSBLeafEnumerator(), osBuild: { "26B5091g" })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func read(_ ports: [(Int, Int)], step: Int) {
        if step > 0 { time.advance(60) }
        src.ingest(portTestFrame(update: Int(now.timeIntervalSince1970) - 200 + 60 * step, onAC: true, ports: ports, step: step))
    }

    func testRawJitterPublishesNothing() {
        read([], step: 0)
        read([(2, 14_054)], step: 1)
        read([(2, 14_060)], step: 2)
        var emissions = 0
        let sink = src.$display.dropFirst().sink { _ in emissions += 1 }
        read([(2, 14_071)], step: 3)
        XCTAssertEqual(emissions, 0, "new UpdateTime and accumulators, same 14.1 W → nothing published (G-2)")
        XCTAssertEqual(src.display.rows.first?.state, .drawing(tenthsW: 141))
        sink.cancel()
    }

    func testAVisibleChangePublishesOnce() {
        read([], step: 0)
        read([(2, 14_054)], step: 1)
        read([(2, 14_060)], step: 2)
        var emissions = 0
        let sink = src.$display.dropFirst().sink { _ in emissions += 1 }
        read([(2, 14_300)], step: 3)
        XCTAssertEqual(emissions, 1)
        XCTAssertEqual(src.display.rows.first?.state, .drawing(tenthsW: 143))
        sink.cancel()
    }
}
