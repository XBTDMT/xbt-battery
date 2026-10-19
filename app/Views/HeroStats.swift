import Foundation

/// #29 hero v2 (ring-left + stat column): pure, host-app-free strings for the hero's three stat rows
/// (Time · Source · Limit). The Limit row reuses `PopoverHeroStrings` for the "holding / paused" phrasing
/// absorbed from the old under-ring status line — relocated, not duplicated.
enum HeroStats {
    /// A minute count as "2h 15m" / "1h 30m" / "45m" / "2h" — a zero component is dropped.
    static func hm(_ minutes: Int) -> String {
        let total = max(0, minutes)
        let h = total / 60, m = total % 60
        // #30 mockup wording: "2 h 15 m", "1 h", "38 min" (was "2h 15m" / "1h" / "38m").
        if h > 0 && m > 0 { return "\(h) h \(m) m" }
        if h > 0 { return "\(h) h" }
        return "\(m) min"
    }

    /// The adaptive Time row — a PROJECTED time, not a flag word. macOS gives no time estimate while a
    /// charge limit is active (the power-source layer reports "no estimate"), so charging is projected
    /// from live current + capacity: "Xh Ym to N%" toward the limit, "Xh Ym to full" at 100. Discharging
    /// prefers the OS's own (smoothed) time-to-empty and falls back to the same current/capacity math when
    /// it's still calculating: "Xh Ym left". `amperageMilliamps` is the SMOOTHED signed current (+ into the
    /// pack / − out). When there's genuinely no signal to project from, the honest state word remains
    /// ("Charging" / "Not charging" / "Not plugged in"). Never "—".
    ///
    /// SWEEP §2.G (knowledge/12-SWEEP-silent-absence.md, hit 3). This opened with
    /// `let amp = amperageMilliamps ?? 0`, which meant an UNREAD current on the adapter failed the
    /// `amp > 0` test and the row asserted **"Not charging"** — a positive claim manufactured out of no
    /// reading, on the most-read line in the app, while `isCharging` (the OS's own IOPS flag, on the same
    /// snapshot, one line away) went unconsulted. Same trap as decoding a failed `pmset` read as `sleep 0`:
    /// zero is a MEANINGFUL value here, so absence must not borrow it. A measured 0 mA still says
    /// "Not charging"; an unread current now falls to the second witness, and if that is unread too it
    /// says "Unknown" — the word `BatteryLifetime.condition` already uses for a key we could not read.
    static func timeText(onAC: Bool, chargePercent: Int?, limit: Int?,
                         amperageMilliamps: Int?, fullChargeCapacity_mAh: Int?,
                         minutesToEmpty: Int?, isCharging: Bool? = nil,
                         packRising: Bool = false, packInflowMilliamps: Int? = nil) -> String {
        if !onAC {
            // Discharging → time until empty: prefer the OS estimate, else project from charge + draw.
            // "Not plugged in" restates `onAC == false`, which we DID read — a fact, not a fallback.
            if let m = minutesToEmpty, m > 0 { return "\(hm(m)) left" }
            if let amp = amperageMilliamps,
               let m = minutesToDrain(percent: chargePercent, fcc: fullChargeCapacity_mAh, milliamps: amp), m > 0 {
                return "\(hm(m)) left"
            }
            return "Not plugged in"
        }
        // On the adapter, charging → time to the limit (or "to full" at 100), from smoothed draw + capacity.
        let target = limit ?? 100
        // #POPOVER-TREND (2026-09-14): on macOS 27 the flag and the sampled current read "draining" for ~98 %
        // of a real climb (see `PackTrend`), and this row said "Not charging" while the bolt was lit. A measured
        // rise (already vetoed at the limit by the monitor) IS the charge — project from the rate the pack is
        // actually gaining, or say "Charging" until enough gauge steps give a rate.
        // The step-aligned inflow is preferred over any single sample — the ~1 s "+3.7 A" frame
        // the gauge publishes at each step would otherwise make the row jump every minute (red-team #6).
        if packRising {
            if let inflow = packInflowMilliamps {
                if let pct = chargePercent, pct < target,
                   let m = minutesToCharge(from: pct, to: target, fcc: fullChargeCapacity_mAh, milliamps: inflow), m > 0 {
                    return target >= 100 ? "\(hm(m)) to full" : "\(hm(m)) to \(target)%"
                }
                return "Charging"
            }
            if (amperageMilliamps ?? 0) <= 0 { return "Charging" }
            // no rate yet but a live positive sample → the measured projection below
        }
        guard let amp = amperageMilliamps else {
            // The current was never read. Do NOT infer flow from its absence — ask the second witness.
            switch isCharging {
            case .some(true):  return "Charging"
            case .some(false): return "Not charging"
            case .none:        return "Unknown"
            }
        }
        if amp > 0 {
            if let pct = chargePercent, pct < target,
               let m = minutesToCharge(from: pct, to: target, fcc: fullChargeCapacity_mAh, milliamps: amp), m > 0 {
                return target >= 100 ? "\(hm(m)) to full" : "\(hm(m)) to \(target)%"
            }
            return "Charging"   // charging but nothing to project from yet (missing capacity / at target)
        }
        return "Not charging"   // MEASURED: on the adapter, no inflow — held at the limit / idle-inhibit
    }

    /// #POPOVER-TREND: the current the Draw row (and the Energy page Pack row) should show. On AC while the %
    /// is rising, the pack's step-aligned inflow; with no rate yet, a live positive sample; otherwise nil
    /// (the row renders "—") — a rise is never shown as the stale negative macOS 27 frame. Everywhere else
    /// the sample stands: with no rise on AC, a negative figure is the real shortfall the orange bolt reports.
    static func drawMilliamps(onAC: Bool, packRising: Bool, sampledMilliamps: Int?, packInflowMilliamps: Int?) -> Int? {
        guard onAC, packRising else { return sampledMilliamps }
        if let inflow = packInflowMilliamps { return inflow }
        if let s = sampledMilliamps, s > 0 { return s }
        return nil
    }

    /// Minutes to charge from `from`% to `to`% at `milliamps` INTO the pack (positive), given the pack's
    /// full-charge capacity. A CC-phase "at this rate" estimate — nil if there's nothing to project from.
    static func minutesToCharge(from: Int, to: Int, fcc: Int?, milliamps: Int) -> Int? {
        guard let fcc, fcc > 0, milliamps > 0, to > from else { return nil }
        let remaining_mAh = Double(to - from) / 100.0 * Double(fcc)
        return Int((remaining_mAh / Double(milliamps) * 60.0).rounded())
    }

    /// Minutes to drain from `percent`% to empty at `milliamps` OUT of the pack (negative). nil unless
    /// genuinely discharging with a capacity to project from.
    static func minutesToDrain(percent: Int?, fcc: Int?, milliamps: Int) -> Int? {
        guard let percent, let fcc, fcc > 0, milliamps < 0 else { return nil }
        let remaining_mAh = Double(percent) / 100.0 * Double(fcc)
        return Int((remaining_mAh / Double(-milliamps) * 60.0).rounded())
    }

    /// The Limit row: the engine limit phrased by state. A manual pause holds regardless of level →
    /// "Paused at N%"; the adapter is genuinely parked AT the limit (not charging, charge ≥ limit) →
    /// "Holding at N%" (holding == true → green); everything else (charging, below the limit, or on
    /// battery) → the plain "N%". A nil limit renders "—". Gating "Holding" on the actual at-limit
    /// condition (not merely `!isCharging`) avoids a false green during a transient below-limit idle-inhibit.
    static func limitText(limit: Int?, chargePercent: Int?, onAC: Bool, isCharging: Bool, isPaused: Bool) -> (text: String, holding: Bool) {
        guard let v = limit else { return ("—", false) }
        if onAC && isPaused { return (PopoverHeroStrings.paused(v), false) }
        if onAC && !isCharging, let pct = chargePercent, pct >= v {
            return (PopoverHeroStrings.holding(v), true)
        }
        return ("\(v)%", false)
    }

    /// #29 C1 re-home: the hero Limit row WITH `ChargeStatusStrings.limitProvenanceTag` appended.
    ///
    /// The tag exists to disclose CUSTODY: with read-back off, the number on screen is the value the app
    /// last wrote, never a value it read. So it rides the row ONLY in the degraded state — in verified
    /// mode the figure IS a read and a "· as set" suffix would be a lie of emphasis. Its third value,
    /// "· Overridden Externally", is the one that matters most: the native "Charge to 100% Now" has
    /// suspended the cap and the pack is charging past the limit the row is showing.
    ///
    /// "· holding" is dropped when the row already reads "Holding at N%" — the same fact twice in a
    /// 320-pt row. That redundancy is only possible in this one combination, so the suppression is exact.
    static func limitRowText(limit: Int?, chargePercent: Int?, onAC: Bool, isCharging: Bool,
                             isPaused: Bool, readBackDegraded: Bool,
                             telemetryState: TelemetryChargeState) -> (text: String, holding: Bool) {
        let base = limitText(limit: limit, chargePercent: chargePercent, onAC: onAC,
                             isCharging: isCharging, isPaused: isPaused)
        guard readBackDegraded, let v = limit else { return base }
        if base.holding, telemetryState == .limitHold, !isPaused { return base }
        let tag = ChargeStatusStrings.limitProvenanceTag(
            telemetryState: telemetryState, isPaused: isPaused,
            limit: .known(v), socPercent: chargePercent)
        return ("\(base.text) \(tag)", base.holding)
    }

    /// #29 C1: how the Details Battery card should PAINT `BatteryLifetime.condition`.
    ///
    /// The old rule was `condition == "Normal" ? healthy : attention`. That predates macOS 27, which
    /// removed `PermanentFailureStatus` with no replacement — so `condition` now legitimately reads
    /// "Unknown" on this machine, and the old rule painted an unreadable key in the same orange as a pack
    /// that needs service. Unknown is an ABSENCE, not a warning: it gets the neutral treatment, and only a
    /// condition we actually read and that is actually bad gets attention.
    static func healthTone(_ condition: String) -> HealthConditionTone {
        switch condition {
        case "Normal":  return .healthy
        case "Unknown": return .neutral
        default:        return .attention
        }
    }

    /// D1 B (§16 "32 · Now · day's low", ruled by the owner 2026-10-18): the Now strip's "low N% at HH:mm" is red
    /// only when N is at or below the app's red threshold (`BatteryRedRule`, the menu-bar glyph's rule), and
    /// secondary text otherwise — always-red at 41% read as an alarm. A day's low is a past minimum, so the
    /// glyph's charging suppression does not apply. An unread low makes no tint claim: nil (the view then
    /// draws no low at all).
    static func dayLowTone(soc: Int?) -> DayLowTone? {
        guard let soc else { return nil }
        return BatteryRedRule.isLow(soc) ? .critical : .secondary
    }
}

/// Tone for the Now strip's day's low — mapped to `DSColor.critical` / `DSSurface.text2` by the view.
enum DayLowTone: Equatable, Sendable {
    case critical   // at or below BatteryRedRule.threshold
    case secondary  // above it — the same secondary text as the row's other captions
}

/// Semantic tone for `BatteryLifetime.condition` — mapped to `DSColor` by the view (keeps this pure file
/// host-app-free, the same split `BannerTint` uses).
enum HealthConditionTone: Equatable, Sendable {
    case healthy    // read, and good      → DSColor.healthy
    case neutral    // not readable at all → DSColor.textSecondary
    case attention  // read, and not good  → DSColor.attention
}
