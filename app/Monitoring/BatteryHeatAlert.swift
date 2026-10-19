import Foundation

/// #EI-4 / audit item C4 ("real alerts — hot pack"). The PURE, latched alert gate that turns the
/// per-sample thermal reading into the rare edge worth interrupting the user for.
///
/// WHY THIS TYPE EXISTS SEPARATELY FROM `BatteryThermalState`
/// `BatteryThermalState.from(...)` answers "what is it right now" — that is the right shape for a
/// popover row, which is re-read every render and has no memory. An ALERT is the opposite: it is an
/// EDGE, and an edge needs memory. Classifying each sample and notifying on `.hot` would ping on
/// every snapshot for as long as the pack stayed hot, and would ping again on every wobble across
/// 42.0 °C. So the gate keeps exactly one bit of state (`engaged`) and reports transitions.
///
/// THE THRESHOLDS ARE NOT NEW. Both come straight from the EI-4 spec's classifier constants:
///   * fire   at `BatteryThermalState.hotThreshold`  (42.0 °C, inclusive — the spec's `.hot` edge)
///   * re-arm below `BatteryThermalState.warmThreshold` (37.0 °C — the spec's `.normal` edge)
/// The 5 °C gap between them IS the hysteresis band; it is DERIVED from the two spec constants
/// rather than invented, so there is one set of thermal numbers in the app, not two. This is the A6
/// lesson applied to a live signal: A6 found that comparing a wandering value against a single
/// boundary produces endless churn (a 0.1% grid wrote 204 health rows/day), and fixed it with a
/// deadband measured against the last COMMITTED value. Here the "last committed value" is the latch:
/// once engaged, only a genuine return to normal clears it.
///
/// THREE-STATE DISCIPLINE. The input is `BatterySnapshot.TemperatureReading`, deliberately
/// three-state, and absence is handled as its own case: an unreadable temperature NEVER fires, and —
/// just as important — never RE-ARMS. Re-arming on absence would be a "the pack cooled" claim the app
/// cannot support, and would let a single failed read in the middle of one heat episode manufacture a
/// duplicate alarm. Absence preserves the last thing we actually knew.
///
/// NO NEW POLLING. The gate is passive: it is driven by the snapshot stream the app already
/// publishes. It owns no timer, no queue and no I/O.
struct BatteryHeatAlert {

    /// What this sample means, relative to what came before.
    enum Outcome: Equatable {
        /// The pack just crossed INTO hot (rising edge). The associated value is the reading that
        /// fired, so the message can state the number it is talking about.
        case fire(celsius: Double)
        /// The pack fell back to normal (falling edge). Not user-facing on its own — the caller uses
        /// it to clear any de-dupe ledger so a genuine LATER episode is not swallowed by a cooldown.
        case rearm
        /// Nothing to say: still cool, still hot, inside the band, or unreadable.
        case silent
    }

    /// The single bit of memory: true once a hot episode has fired and not yet ended.
    private(set) var isEngaged = false

    init() {}

    /// Fold one reading in and report the edge, if any. Pure apart from the latch it owns.
    mutating func evaluate(_ reading: BatterySnapshot.TemperatureReading) -> Outcome {
        // Absence is its own state: never a fire, never a re-arm, latch untouched.
        guard case .celsius(let c) = reading else { return .silent }

        if c >= BatteryThermalState.hotThreshold {
            guard !isEngaged else { return .silent }   // already alarmed for this episode
            isEngaged = true
            return .fire(celsius: c)
        }
        if c < BatteryThermalState.warmThreshold {
            guard isEngaged else { return .silent }    // `.rearm` is an edge, not a level
            isEngaged = false
            return .rearm
        }
        return .silent                                 // inside the hysteresis band — no churn
    }
}
