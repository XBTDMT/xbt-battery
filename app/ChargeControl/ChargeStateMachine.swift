import Foundation

/// The published TELEMETRY STATE — layer 1 of the two-layer status model (SPEC v4.0 sec 2).
/// Composed with (never merged into) the LAST-COMMAND STATUS from BehaviorConfirm.
enum TelemetryChargeState: Equatable, Sendable {
    case charging
    /// NCR carries the 0x01000000 limit bit (pure hold or the 0x01002080 stop transient —
    /// the transient decays to the pure hold; both ARE the limit hold, S-N1).
    case limitHold
    /// NCR = 0x80 while plugged: the idle/sleep charge inhibit (run-02 nap state).
    case idleInhibit
    /// The OBC/stale fingerprint: plugged, at-or-below the limit, armed-but-not-flowing,
    /// NCR=0, SUSTAINED. From here the engine reports — it never promises (S-N2).
    case ambiguousHold
    /// On battery, or plugged with load exceeding the adapter (run-02 CPU-load rows).
    case discharging
    case unknown
}

/// The configured limit as last read (WI-N5 LimitReader feeds this). `.unknown` is a
/// first-class state (Get-degraded mode), not an error trap.
enum ChargeLimitValue: Equatable, Sendable {
    case known(Int)
    case unknown
}

/// Audit C2 (00-AUDIT Part 2 item 5), forwarder-now: the WRITE-side type — one of the five settable
/// steps (sec 3). Makes "only these five can be SET" a type, not a runtime `contains` check; it is the
/// single source of truth `ChargeShortcuts.validLimitValues` now derives from. The READ type
/// (`ChargeLimitValue`) stays permissive on purpose — S-N3 "adopt, never fight" requires tolerating an
/// off-grid externally-set value (83/92), so the Get parser is NOT narrowed. The gap between them is the
/// named, queryable `asStep` accessor below.
enum ChargeLimitStep: Int, CaseIterable, Equatable, Sendable {
    case s80 = 80, s85 = 85, s90 = 90, s95 = 95, s100 = 100

    /// Smart constructor: nil for any non-settable integer (the basis for `CommandOutcome.invalidTarget`).
    init?(_ raw: Int) { self.init(rawValue: raw) }

    var percent: Int { rawValue }
    var shortcutName: String { "Battery Limit \(rawValue)" }
}

extension ChargeLimitValue {
    /// The observed value re-expressed as a settable step, or nil if it is off-grid (observed but not
    /// re-settable — externally set to a non-sanctioned value). Lets the UI distinguish "85% (set
    /// outside the app)" from a value the engine can re-issue, instead of silently offering a rejected
    /// Set. Added + tested now; the popover that consumes it is a separate (FROZEN-view) change.
    var asStep: ChargeLimitStep? {
        if case .known(let v) = self { return ChargeLimitStep(v) }
        return nil
    }
}

/// WI-N3: PURE classification — (snapshot history, limit, tunables) → state. No side effects,
/// no clocks (time arrives ON the samples), host-app-free testable.
///
/// **Classification PRECEDENCE (normative, Grok B2):**
///   (1) NCR limit bit (0x01000000 / decaying 0x01002080) → `.limitHold`
///   (2) NCR 0x80                                          → `.idleInhibit`
///   (3) flow-based on InstantAmperage sign                → `.charging` / `.discharging`
///   (4) the ambiguous fingerprint, evaluated LAST         → `.ambiguousHold`
///   else                                                  → `.unknown` (the only hole-filler)
///
/// **On-AC gate (flagged spec interpretation):** hold taxons (1)(2)(4) additionally require
/// `ExternalConnected == true`. Observed live (raw fixture `dischargingOnBattery`): NCR reads
/// 0x80 while UNPLUGGED — without the gate, an on-battery machine would display "Not charging —
/// system idle", which is nonsense. The spec's "(on-AC, flow, NCR) combination" wording puts
/// on-AC first; this reading is asserted in the matrix tests and flagged in the hand-back.
enum ChargeStateMachine {

    struct Tunables: Sendable {
        /// |InstantAmperage| at or above this is REAL flow; below is "not flowing"
        /// (sec 8d: 350 mA is a characterization-derived engineering guess — tunable).
        var flowThreshold_mA = 350
        /// The armed-not-flowing fingerprint must persist this long before `.ambiguousHold`
        /// (pre-sustained reads `.unknown` — a transient must not classify as a hold).
        var ambiguousSustain_s: TimeInterval = 30
        /// Max gap between consecutive samples inside the sustain window. Sized to tolerate
        /// the 60 s passive cadence (sec 2 polling) + jitter; a sleep gap breaks "sustained".
        var maxSampleGap_s: TimeInterval = 90
        /// Limit-unknown fallback: ambiguity is only considered when LIVE SoC < this
        /// (sec 2: conservative, cannot misfire at the cap).
        var limitUnknownSocCeiling = 95

        init() {}
    }

    /// `history` is oldest→newest; classification reads the NEWEST sample, with history
    /// consulted only for the sustained-fingerprint requirement.
    static func classify(history: [ChargeTelemetrySnapshot],
                         limit: ChargeLimitValue,
                         tunables: Tunables = Tunables()) -> TelemetryChargeState {
        guard let latest = history.last else { return .unknown }
        let onAC = latest.externalConnected == true

        // (1) the limit hold — EXACTLY 0x01000000 or the 0x01002080 stop transient.
        if onAC, latest.isLimitHoldNCR { return .limitHold }

        // (2) idle/sleep inhibit.
        if onAC, latest.notChargingReason == ChargeNCR.idleInhibit { return .idleInhibit }

        // (3) flow — physics outranks every remaining flag.
        if let amps = latest.instantAmperage_mA, abs(amps) >= tunables.flowThreshold_mA {
            return amps > 0 ? .charging : .discharging
        }

        // No real flow. Off AC, a battery-powered machine is discharging by definition.
        if !onAC { return latest.externalConnected == false ? .discharging : .unknown }

        // (4) the ambiguous fingerprint — LAST, and only when SUSTAINED.
        if isAmbiguousSustained(history: history, limit: limit, tunables: tunables) {
            return .ambiguousHold
        }

        return .unknown
    }

    // MARK: - ambiguous fingerprint

    /// One sample matches the fingerprint: on-AC, armed (IsCharging=true), not flowing
    /// (|InstAmp| < threshold), NCR=0, and SoC at-or-below the limit (Grok B2 widening; an
    /// NCR=0 hold AT the cap previously had no home). Limit `.unknown` → satisfied iff the
    /// sample's LIVE SoC < ceiling (never a cached value — the comparison re-evaluates on
    /// every sample).
    private static func matchesAmbiguousFingerprint(_ s: ChargeTelemetrySnapshot,
                                                    limit: ChargeLimitValue,
                                                    tunables: Tunables) -> Bool {
        guard s.externalConnected == true,
              s.isChargingFlag == true,
              s.notChargingReason == ChargeNCR.none,
              let amps = s.instantAmperage_mA, abs(amps) < tunables.flowThreshold_mA,
              let soc = s.socPercent else { return false }
        switch limit {
        case .known(let value): return soc <= value
        case .unknown:          return soc < tunables.limitUnknownSocCeiling
        }
    }

    /// The contiguous run of fingerprint-matching samples ending at the newest must SPAN the
    /// sustain window, with no inter-sample gap exceeding `maxSampleGap_s` (a nap inside the
    /// window de-sustains it — stale pre-sleep samples must not certify a hold, S-N5 spirit).
    private static func isAmbiguousSustained(history: [ChargeTelemetrySnapshot],
                                             limit: ChargeLimitValue,
                                             tunables: Tunables) -> Bool {
        guard let latest = history.last,
              matchesAmbiguousFingerprint(latest, limit: limit, tunables: tunables) else {
            return false
        }
        var spanStart = latest.timestamp
        var previous = latest
        for sample in history.dropLast().reversed() {
            guard matchesAmbiguousFingerprint(sample, limit: limit, tunables: tunables),
                  previous.timestamp - sample.timestamp <= tunables.maxSampleGap_s else { break }
            spanStart = sample.timestamp
            previous = sample
        }
        return latest.timestamp - spanStart >= tunables.ambiguousSustain_s
    }
}
