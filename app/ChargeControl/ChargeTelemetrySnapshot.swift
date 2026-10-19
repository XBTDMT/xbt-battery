import Foundation

/// The charge-control subset of one `AppleSmartBattery` read, stamped with a MONOTONIC time
/// (SPEC WI-N2; S-N5). This is the only shape the ChargeStateMachine and BehaviorConfirm see.
///
/// Deliberately ABSENT: `ChargerData.ChargerPower/ChargerIBUS/ChargerVBUS` — validated
/// unpopulated on 27.0 (0 across ~45 samples spanning +2.9 A charging, stops, and holds;
/// run-03 raw log). The spec says "never reads … for logic (may log)"; excluding them from this
/// struct makes "never for logic" structural rather than disciplinary.
struct ChargeTelemetrySnapshot: Equatable, Sendable {

    /// Monotonic seconds (advances THROUGH sleep — `CLOCK_MONOTONIC`), so a nap shows up as a
    /// gap between consecutive samples and S-N5 invalidation can see it.
    var timestamp: TimeInterval

    /// `CurrentCapacity` — displayed SoC %, smoothed by the OS and ~30–60 s laggy (run-02).
    var socPercent: Int?
    /// `AppleRawCurrentCapacity` mAh — the fine-grained truth trend (run-03 signal model).
    var rawCapacity_mAh: Int?
    /// `InstantAmperage` mA, signed: + into the pack, − out. THE flow signal (run-03).
    var instantAmperage_mA: Int?
    /// `ChargerData.NotChargingReason`. 0x01000000 limit hold; 0x01002080 stop transient;
    /// 0x80 idle/sleep inhibit; 0 charging-or-ambiguous (run-03 state decoder).
    var notChargingReason: UInt32?
    /// `IsCharging` — an ARMED flag that lies at sub-limit holds (run-03 "discredited signals").
    /// Used ONLY inside the ambiguous-hold fingerprint, never as evidence of flow.
    var isChargingFlag: Bool?
    /// `ExternalConnected` — the on-AC gate for hold classification.
    var externalConnected: Bool?
    /// `ChargerData.ChargingCurrent` mA — armed/configured, not flowing; display+fingerprint only.
    var chargingCurrent_mA: Int?

    /// Convenience for the NCR limit-hold test — EXACT-value match against the two enumerated
    /// codes (spec sec 2: "NCR=0x01000000 or decaying 0x01002080"). Deliberately NOT a bit
    /// mask: an unknown future NCR that happens to carry the 0x01000000 bit must not be
    /// claimed as a verified hold (S-N1 — never display a held state telemetry doesn't support).
    var isLimitHoldNCR: Bool { ChargeNCR.isLimitHold(notChargingReason) }
}

/// Named NCR constants from the run-03 characterization (exact observed values).
enum ChargeNCR {
    static let none: UInt32 = 0x0000_0000
    static let limitHoldPure: UInt32 = 0x0100_0000
    static let stopTransient: UInt32 = 0x0100_2080     // decays to limitHoldPure within ~1 sample
    static let idleInhibit: UInt32 = 0x0000_0080

    /// The two — and only the two — codes the spec enumerates as the limit hold.
    static func isLimitHold(_ ncr: UInt32?) -> Bool {
        ncr == limitHoldPure || ncr == stopTransient
    }
}

/// Monotonic clock seam (S-N5). The live implementation uses `CLOCK_MONOTONIC`, which KEEPS
/// COUNTING through sleep — required so a nap appears as a sample-timestamp gap. (The tempting
/// alternatives — `ProcessInfo.systemUptime` / `mach_absolute_time` — PAUSE during sleep and
/// would hide exactly the gaps S-N5 exists to catch.)
protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
}

struct LiveMonotonicClock: MonotonicClock {
    func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}
