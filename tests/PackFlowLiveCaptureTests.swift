import XCTest
import IOKit.ps

/// #POPOVER-TREND — the REAL capture, replayed. On 2026-09-14 18:09:41–18:35:41 a temporary harness logged this
/// Mac's `AppleSmartBattery` every 10 s (t, CurrentCapacity %, IsCharging, InstantAmperage mA,
/// AppleRawCurrentCapacity mAh, Voltage mV) while it charged 75 → 90 % on the 100 W adapter and then held at
/// the 90 % limit. That live run exercised the FIRST cut of the fix; this test replays the same hardware
/// sequence through the CURRENT monitor, estimator, veto and popover strings, so the revised code is checked
/// against real gauge behaviour, not only synthetic steps.
@MainActor
final class PackFlowLiveCaptureTests: XCTestCase {

    /// (t s, percent, isCharging, amps mA, raw mAh, mV) — verbatim from the capture.
    static let capture: [(t: Int, pct: Int, chg: Bool, amp: Int, mAh: Int, mV: Int)] = [
        (0, 75, false, -1851, 4016, 12177), (10, 75, false, -1851, 4016, 12177), (20, 75, false, -1851, 4016, 12177), (30, 75, false, -1851, 4016, 12177),
        (40, 75, true, 2671, 4050, 12555), (50, 75, true, 2671, 4050, 12555), (60, 75, true, 2671, 4050, 12555), (70, 76, false, -2507, 4081, 12633),
        (80, 76, false, -2507, 4081, 12633), (90, 76, false, -2507, 4081, 12633), (100, 76, false, -2507, 4081, 12633), (110, 76, false, -2507, 4081, 12633),
        (120, 76, false, -2507, 4081, 12213), (131, 76, true, 2809, 4121, 12570), (141, 77, false, -912, 4133, 12622), (151, 77, false, -912, 4133, 12622),
        (161, 77, false, -912, 4133, 12622), (171, 77, false, -912, 4133, 12622), (181, 77, false, -912, 4133, 12269), (191, 77, false, -912, 4133, 12269),
        (201, 77, true, 2889, 4173, 12628), (211, 77, true, 2889, 4173, 12628), (221, 78, true, 3432, 4188, 12680), (231, 78, true, 3432, 4188, 12680),
        (242, 78, true, 3432, 4188, 12680), (252, 78, true, 3432, 4188, 12680), (262, 78, true, 3432, 4188, 12680), (272, 78, true, 3432, 4188, 12680),
        (282, 79, false, -1617, 4243, 12354), (292, 79, false, -1617, 4243, 12354), (302, 79, false, -1617, 4243, 12317), (312, 79, false, -1617, 4243, 12317),
        (322, 79, false, -1617, 4243, 12317), (332, 79, false, -1617, 4243, 12317), (342, 79, true, 3350, 4281, 12710), (353, 79, true, 3350, 4281, 12710),
        (363, 80, false, -2417, 4297, 12393), (373, 80, false, -2417, 4297, 12393), (383, 80, false, -2417, 4297, 12393), (393, 80, false, -2417, 4297, 12393),
        (403, 80, false, -2417, 4297, 12393), (413, 80, false, -2417, 4297, 12393), (423, 80, true, 3568, 4342, 12764), (433, 81, false, -678, 4352, 12771),
        (443, 81, false, -678, 4352, 12771), (454, 81, false, -678, 4352, 12771), (464, 81, false, -678, 4352, 12771), (474, 81, false, -678, 4352, 12771),
        (484, 81, false, -678, 4352, 12469), (494, 82, true, 3760, 4405, 12826), (504, 82, true, 3760, 4405, 12826), (514, 82, true, 3760, 4405, 12826),
        (524, 82, true, 3760, 4405, 12826), (534, 82, true, 3760, 4405, 12826), (544, 82, true, 3760, 4405, 12826), (555, 83, true, 3370, 4460, 12827),
        (565, 83, true, 3370, 4460, 12827), (575, 83, true, 3370, 4460, 12827), (585, 83, true, 3370, 4460, 12827), (595, 83, true, 3370, 4460, 12827),
        (605, 83, true, 3370, 4460, 12827), (615, 84, false, -1579, 4515, 12804), (625, 84, false, -1579, 4515, 12804), (635, 84, false, -1579, 4515, 12804),
        (645, 84, false, -1579, 4515, 12804), (656, 84, false, -1579, 4515, 12804), (666, 84, false, -1579, 4515, 12514), (676, 84, true, 2707, 4558, 12829),
        (686, 85, true, 2689, 4566, 12826), (696, 85, true, 2689, 4566, 12826), (706, 85, true, 2689, 4566, 12826), (716, 85, true, 2689, 4566, 12826),
        (726, 85, true, 2689, 4566, 12826), (736, 85, true, 2689, 4566, 12826), (746, 85, true, 2441, 4608, 12831), (757, 85, true, 2441, 4608, 12831),
        (767, 86, true, 2346, 4620, 12827), (777, 86, true, 2346, 4620, 12827), (787, 86, true, 2346, 4620, 12827), (797, 86, true, 2346, 4620, 12827),
        (807, 86, true, 2346, 4620, 12827), (817, 86, true, 2346, 4620, 12827), (827, 86, true, 2421, 4656, 12827), (837, 86, true, 2421, 4656, 12827),
        (847, 87, true, 2374, 4675, 12856), (857, 87, true, 2374, 4675, 12856), (867, 87, true, 2374, 4675, 12856), (878, 87, true, 2374, 4675, 12856),
        (888, 87, true, 2374, 4675, 12856), (898, 87, true, 2374, 4675, 12856), (908, 87, true, 2257, 4709, 12872), (918, 87, true, 2257, 4709, 12872),
        (928, 87, true, 2257, 4709, 12872), (938, 88, true, 2439, 4729, 12890), (948, 88, true, 2439, 4729, 12890), (958, 88, true, 2439, 4729, 12890),
        (968, 88, true, 2439, 4729, 12890), (978, 88, true, 2439, 4729, 12890), (989, 88, true, 2439, 4729, 12890), (999, 88, true, 2441, 4768, 12916),
        (1009, 88, true, 2441, 4768, 12916), (1019, 89, true, 2390, 4783, 12918), (1029, 89, true, 2390, 4783, 12918), (1039, 89, true, 2390, 4783, 12918),
        (1049, 89, true, 2390, 4783, 12918), (1059, 89, true, 2390, 4783, 12918), (1069, 89, true, 2390, 4783, 12918), (1079, 89, true, 2441, 4822, 12947),
        (1089, 89, true, 2441, 4822, 12947), (1100, 89, true, 2441, 4822, 12947), (1110, 90, true, 2450, 4838, 12956), (1120, 90, true, 2450, 4838, 12956),
        (1130, 90, true, 2450, 4838, 12956), (1140, 90, true, 2450, 4838, 12956), (1150, 90, true, 2450, 4838, 12956), (1160, 90, false, 0, 4838, 12727),
        (1170, 90, false, 0, 4838, 12727), (1180, 90, false, 0, 4838, 12727), (1190, 90, false, 0, 4838, 12727), (1201, 90, false, 0, 4838, 12727),
        (1211, 90, false, 0, 4838, 12727), (1221, 90, false, 0, 4838, 12727), (1231, 90, false, 0, 4838, 12727), (1241, 90, false, 0, 4838, 12727),
        (1251, 90, false, 0, 4838, 12727), (1261, 90, false, 0, 4838, 12713), (1271, 90, false, 0, 4838, 12713), (1281, 90, false, 0, 4838, 12713),
        (1291, 90, false, 0, 4838, 12713), (1302, 90, false, 0, 4838, 12713), (1312, 90, false, 0, 4838, 12713), (1322, 90, false, 0, 4838, 12707),
        (1332, 90, false, 0, 4838, 12707), (1342, 90, false, 0, 4838, 12707), (1352, 90, false, 0, 4838, 12707), (1362, 90, false, 0, 4838, 12707),
        (1372, 90, false, 0, 4838, 12707), (1382, 90, false, 0, 4838, 12702), (1392, 90, false, 0, 4838, 12702), (1402, 90, false, 0, 4838, 12702),
        (1413, 90, false, 0, 4838, 12702), (1423, 90, false, 0, 4838, 12702), (1433, 90, false, 0, 4838, 12702), (1443, 90, false, 0, 4838, 12700),
        (1453, 90, false, 0, 4838, 12700), (1463, 90, false, 0, 4838, 12700), (1473, 90, false, 0, 4838, 12700), (1483, 90, false, 0, 4838, 12700),
        (1493, 90, false, 0, 4838, 12700), (1503, 90, false, 0, 4838, 12697), (1513, 90, false, 0, 4838, 12697), (1524, 90, false, 0, 4837, 12697),
        (1534, 90, false, 0, 4837, 12697), (1544, 90, false, 0, 4837, 12697), (1554, 90, false, 0, 4837, 12697),
    ]

    private final class Clock { var t: TimeInterval = 0 }

    func testTheCapturedChargeReadsChargingThroughTheClimbAndHoldingAtTheLimit() {
        let clock = Clock()
        func live(_ r: (t: Int, pct: Int, chg: Bool, amp: Int, mAh: Int, mV: Int)) -> [String: Any] {
            [kIOPSCurrentCapacityKey: r.pct, kIOPSIsChargingKey: r.chg, kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        }
        func diag(_ r: (t: Int, pct: Int, chg: Bool, amp: Int, mAh: Int, mV: Int)) -> [String: Any] {
            ["AppleRawCurrentCapacity": r.mAh, "AppleRawMaxCapacity": 5435, "DesignCapacity": 6249,
             "CycleCount": 530, "Voltage": r.mV, "InstantAmperage": r.amp]
        }
        let first = Self.capture[0]
        clock.t = TimeInterval(first.t)
        let mock = MockPowerSourceReader(live: live(first), diagnostics: diag(first))
        let monitor = BatteryMonitor(reader: mock, monotonicNow: { clock.t })
        monitor.start(); defer { monitor.stop() }
        monitor.setTrendVeto(limitPercent: 90, limitHold: false)

        var climbRows = 0, inflows: [Int] = []
        var failures: [String] = []
        for r in Self.capture.dropFirst() {
            clock.t = TimeInterval(r.t)
            mock.liveDescription = live(r); mock.diagnosticsProperties = diag(r)
            mock.fireChange()
            let s = monitor.snapshot
            let time = HeroStats.timeText(onAC: true, chargePercent: s.chargePercent, limit: 90,
                                          amperageMilliamps: s.smoothedAmperageMilliamps,
                                          fullChargeCapacity_mAh: s.fullChargeCapacity_mAh,
                                          minutesToEmpty: s.minutesToEmpty, isCharging: s.isCharging,
                                          packRising: s.packRising, packInflowMilliamps: s.packInflowMilliamps)
            let drawMA = HeroStats.drawMilliamps(onAC: true, packRising: s.packRising,
                                                 sampledMilliamps: s.amperageMilliamps,
                                                 packInflowMilliamps: s.packInflowMilliamps)
            let draw = WattageReadout.compact(voltageVolts: s.voltageVolts, amperageMilliamps: drawMA) ?? "—"
            let limit = HeroStats.limitText(limit: 90, chargePercent: s.chargePercent, onAC: true,
                                            isCharging: s.isChargingForDisplay == true, isPaused: false).text
            let row = "t=\(r.t) pct=\(r.pct) amp=\(r.amp) → \(time) | \(draw) | \(limit)"

            if r.t >= 70 && r.pct < 90 {                           // after the first observed step, below the limit
                climbRows += 1
                if time == "Not charging" { failures.append("climb said Not charging: \(row)") }
                if draw.hasPrefix("−") { failures.append("climb showed a negative Draw: \(row)") }
                if let i = s.packInflowMilliamps { inflows.append(i) }
            }
            if r.pct == 90 {
                if s.packRising { failures.append("rise claimed at the limit: \(row)") }
                if r.amp == 0 {
                    if time != "Not charging" { failures.append("held at 0 mA but Time is not 'Not charging': \(row)") }
                    if limit != PopoverHeroStrings.holding(90) { failures.append("held but no Holding: \(row)") }
                    if draw != "0 W" { failures.append("held at 0 mA but Draw is not 0 W: \(row)") }
                }
            }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        XCTAssertGreaterThan(climbRows, 90)
        // Ground truth over the climb: 2309–3045 mA by stretch, 2651 mA overall (raw mAh / time).
        XCTAssertGreaterThan(inflows.count, climbRows / 2, "a rate should be quotable for most of the climb")
        XCTAssertGreaterThanOrEqual(inflows.min() ?? 0, 2000, "inflow never far below the measured rate")
        XCTAssertLessThanOrEqual(inflows.max() ?? .max, 3600, "no alignment spikes (the first cut quoted 4096)")
    }
}
