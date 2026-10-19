import Foundation
import IOKit.ps

// 31 stage 4 · the "Powered by this Mac" fixtures, fed THROUGH the monitor's own reader (spec §2.5): a frame
// list served one per diagnostics read (the graph build forces the extra reads with `refreshOnDemand()` before
// the settle), the USB leaves that go with each frame, and a monotonic clock that advances 60 s per frame.
// Never the owner's real USB bus or defaults. Numbers: the 65 W charger (IPDInputPower 65000), SystemPowerIn
// 62.7 W, +5.6 W into the pack on power / −27.8 W on battery; FCC 5435 mAh × 3 banks; 1739 mAh remaining.

final class FixturePortFrames: @unchecked Sendable {
    struct Frame {
        let props: [String: Any]
        let leaves: [USBLeaf]
    }

    private let lock = NSLock()
    private let frames: [Frame]
    private var index = -1

    init(_ frames: [Frame]) { self.frames = frames }

    var count: Int { frames.count }

    /// The next frame (the last one repeats once the list is spent — a repeated frame is what the live record
    /// does between refreshes).
    func next() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        index = min(index + 1, frames.count - 1)
        return frames[index].props
    }

    /// The leaves that go with the frame most recently served.
    func leaves() -> [USBLeaf] {
        lock.lock(); defer { lock.unlock() }
        return index >= 0 ? frames[index].leaves : []
    }

    var monotonic: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return 1_000 + 60 * Double(max(index, 0))
    }
}

final class FixturePortFrameReader: PowerSourceReading {
    private let frames: FixturePortFrames
    private let onAC: Bool
    /// The gated fixtures' 32 % / 38 min; `.showcasePowered` passes the showcase's 64 % / 91 min.
    private let soc: Int
    private let timeToEmpty: Int

    init(frames: FixturePortFrames, onAC: Bool, soc: Int = 32, timeToEmpty: Int = 38) {
        self.frames = frames
        self.onAC = onAC
        self.soc = soc
        self.timeToEmpty = timeToEmpty
    }

    func readLiveDescription() -> [String: Any]? {
        [kIOPSCurrentCapacityKey: soc, kIOPSIsChargingKey: onAC,
         kIOPSPowerSourceStateKey: onAC ? kIOPSACPowerValue : kIOPSBatteryPowerValue, kIOPSTimeToEmptyKey: timeToEmpty]
    }
    func readDiagnosticsProperties() -> [String: Any]? { frames.next() }
    func startLiveUpdates(onChange: @escaping () -> Void) {}
    func stopLiveUpdates() {}
}

struct FixturePortLeafEnumerator: USBLeafEnumerating {
    let frames: FixturePortFrames
    /// The fixtures' walks always succeed (a fixture that needs a failed walk would return nil here).
    func leaves() -> [USBLeaf]? { frames.leaves() }
}

enum RenderPortFrames {
    private static let phone = USBLeaf(registryID: 0x1000_0A01, productName: "iPhone", vendorName: "Apple Inc.", kind: .iphone)
    private static let keyboard = USBLeaf(registryID: 0x1000_0A02, productName: "Magic Keyboard", vendorName: "Apple Inc.", kind: .keyboard)
    private static let drive = USBLeaf(registryID: 0x1000_0A03, productName: "T7 Shield", vendorName: "Samsung", kind: .massStorage)

    /// S4.9 hotfix: the owner's real long timing-match name (screenshot 2026-09-29). Only `powered-notes-single-port` uses it
    /// (unpaired), so the long name, the watts and the "exact" tag prove they share one line without touching the parity pair.
    static let longNameDevice = USBLeaf(registryID: 0x1000_0A04, productName: "AirPods Max USB Audio", vendorName: "Apple Inc.", kind: .other)

    private static let p2Only = (index: 2, mW: 9_200, contract: 15_000)

    /// A FRESH frame list per graph (the cursor is stateful); nil for every non-powered fixture.
    /// On power / on battery (the parity pair, option 1): one device per read so the timing match (G-7)
    /// names each — iPhone 9.2 W (port 2), Magic Keyboard 1.0 W (port 1), T7 Shield 4.5 W (port 3). Worst:
    /// four ports on ONE read (none can be named), an iPhone on USB whose port is therefore unknown, on
    /// battery, a frame 300 s old ("as of"), a two-line cost line. Unread: a good frame, then a malformed
    /// PowerOutDetails ("couldn't read ports").
    static func frames(for fixture: RenderFixture) -> FixturePortFrames? {
        let e = RenderFixtureClock.epoch
        switch fixture {
        case .poweredOnPower, .poweredOnBattery, .showcasePowered:
            // `.showcasePowered` (public images only, never gated): the on-battery frames with the pack at
            // 3,641 mAh — chosen so the cost line's nominal-voltage math lands on Now's 1 h 31 m
            // (3,641 mAh × 11.58 V ÷ 27.8 W ≈ 91 min); it is not 64 % of the 5,435 mAh capacity (≈ 3,480).
            let ac = fixture == .poweredOnPower
            let remaining = fixture == .showcasePowered ? 3_641 : 1_739
            let p2 = (index: 2, mW: 9_200, contract: 15_000)
            let p1 = (index: 1, mW: 1_000, contract: 2_500)
            let p3 = (index: 3, mW: 4_500, contract: 15_000)
            return FixturePortFrames([
                .init(props: props(update: e - 190, onAC: ac, ports: [], step: 0, remaining: remaining), leaves: []),
                .init(props: props(update: e - 130, onAC: ac, ports: [p2], step: 1, remaining: remaining), leaves: [phone]),
                .init(props: props(update: e - 70, onAC: ac, ports: [p2, p1], step: 2, remaining: remaining),
                      leaves: [phone, keyboard]),
                .init(props: props(update: e - 10, onAC: ac, ports: [p2, p1, p3], step: 3, remaining: remaining),
                      leaves: [phone, keyboard, drive]),
            ])
        case .poweredNotesSinglePort:
            // One device on its own read (so the timing match names it), fresh, on battery → a two-line cost line.
            // The device is the long-named AirPods Max (2.9 W): its row must keep "2.9 W" + "exact" whole (S4.9).
            let p3 = (index: 3, mW: 2_900, contract: 15_000)
            return FixturePortFrames([
                .init(props: props(update: e - 70, onAC: false, ports: [], step: 0), leaves: []),
                .init(props: props(update: e - 10, onAC: false, ports: [p3], step: 1), leaves: [longNameDevice]),
            ])
        case .poweredUnread:
            // A good read first (it marks PowerOutDetails as seen on this build), then a PowerOutDetails whose
            // only element has no FilteredPower — present but unreadable (`portsKeyIsMalformed`) → `.unread`.
            var bad = props(update: e - 10, onAC: false, ports: [], step: 1)
            bad["PowerOutDetails"] = [["PortIndex": 2, "Watts": "n/a"]] as [[String: Any]]
            return FixturePortFrames([
                .init(props: props(update: e - 70, onAC: false, ports: [p2Only], step: 0), leaves: [phone]),
                .init(props: bad, leaves: [phone]),
            ])
        case .poweredWorst, .poweredWorstNotes, .poweredWorstNotesAdapterOK:
            let ports = [(index: 1, mW: 6_100, contract: 15_000), (index: 2, mW: 4_200, contract: 15_000),
                         (index: 3, mW: 2_500, contract: 7_500), (index: 4, mW: 900, contract: 4_500)]
            let leaves = [USBLeaf(registryID: 0x1000_0B01, productName: "USB-C Digital AV Multiport", vendorName: "Apple Inc."),
                          USBLeaf(registryID: 0x1000_0B02, productName: "Portable SSD", vendorName: "SanDisk", kind: .massStorage),
                          USBLeaf(registryID: 0x1000_0B03, productName: "Magic Keyboard", vendorName: "Apple Inc.", kind: .keyboard),
                          USBLeaf(registryID: 0x1000_0B04, productName: "USB Receiver", vendorName: "Logitech")]
            return FixturePortFrames([
                .init(props: props(update: e - 400, onAC: false, ports: [], step: 0, drawW: 30_000), leaves: []),
                .init(props: props(update: e - 300, onAC: false, ports: ports, step: 1, drawW: 30_000), leaves: leaves),
            ])
        default:
            return nil
        }
    }

    /// The base AppleSmartBattery fixture plus what the port source reads: UpdateTime, ExternalConnected,
    /// PowerOutDetails, PowerTelemetryData (both accumulator pairs, advancing 60 counts per frame),
    /// PowerDistribution, RemainingCapacity and the folded pack child's BankCount.
    static func props(update: Int, onAC: Bool, ports: [(index: Int, mW: Int, contract: Int)], step: Int,
                      drawW: Int = 27_800, chargeW: Int = 5_600, remaining: Int = 1_739) -> [String: Any] {
        var p = RenderFixtureLifetime.props
        p["UpdateTime"] = update
        p["ExternalConnected"] = onAC
        var battery = (p["BatteryData"] as? [String: Any]) ?? [:]
        battery["RemainingCapacity"] = remaining
        p["BatteryData"] = battery
        p["PowerTelemetryData"] = [
            "SystemPowerIn": onAC ? 62_741 : 0,
            "SystemLoad": onAC ? 62_741 - chargeW : drawW,
            "BatteryPower": onAC ? chargeW : -drawW,
            "AccumulatedBatteryPower": 1_000_000_000 + (onAC ? chargeW * 60 * step : 0),
            "BatteryPowerAccumulatorCount": 40_000 + (onAC ? 60 * step : 0),
            "AccumulatedBatteryDischarge": -1_200_000_000 - (onAC ? 0 : drawW * 60 * step),
            "BatteryDischargeAccumulatorCount": 50_000 + (onAC ? 0 : 60 * step),
        ] as [String: Any]
        p["PowerDistribution"] = ["IPDInputPower": 65_000] as [String: Any]
        p[BatteryTelemetryParser.packPropertiesKey] = ["BankCount": 3] as [String: Any]
        if !ports.isEmpty {
            p["PowerOutDetails"] = ports.map { port -> [String: Any] in
                ["PortIndex": port.index, "PortType": 0, "PowerState": 0, "Watts": port.mW, "FilteredPower": port.mW,
                 "Current": port.mW * 1_000 / 5_190, "AdapterVoltage": 5_190, "PDPowermW": port.contract,
                 "AccumulatedPower": 169_827 + port.mW * step, "AccumulatorCount": 15 + 60 * step,
                 "AccumulatorErrorCount": 0]
            }
        }
        return p
    }
}
