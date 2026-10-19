import Foundation
import Combine

// Sprint 3.7 B2 (#19 option-2) — a NO-ROOT, data-driven, LIVENESS-PROBED component-power readout via
// IOReport directly (NOT the helper; no privileged op). research-11: on this M4 Max / macOS 27 seed an
// unprivileged IOReport subscription to the "Energy Model" group reads GPU energy only — CPU/ANE/DRAM
// are FROZEN (readable but not advancing). So we never hard-code "GPU only": we PROBE liveness (a rail
// is shown only if its energy counter ADVANCES across a sample interval) and render exactly the live
// rails. The same code AUTO-EXPANDS to CPU/ANE/package the day Apple restores those counters — no
// rebuild (the capability-probe principle).
//
// HONESTY (research-05 + research-11): these are MODELED component estimates, NOT a battery-terminal
// measurement (#20's V×I is the one true terminal wattage); NOT comparable across machines; NEVER
// per-process. A "total" would be a labeled SUM of live component rails — never a measured package
// figure — so with GPU-only today we show the single rail and imply no full tree.

/// One live component rail: a name (e.g. "GPU") and its modeled watts over the probe interval.
public struct PowerRailReading: Identifiable, Equatable, Sendable {
    public let name: String
    public let watts: Double
    public var id: String { name }
    public init(name: String, watts: Double) { self.name = name; self.watts = watts }
}

/// A raw per-channel energy DELTA over the probe interval (the sampler's output, before liveness/units
/// are interpreted). `deltaValue` is the integer the simple accessor returned: `Int64.min` is the
/// state/array-format sentinel (a non-energy channel read with the simple accessor) → filtered out.
public struct RawRailDelta: Equatable, Sendable {
    public let name: String
    public let unit: String       // the channel's own unit label: "mJ" / "uJ" / "nJ" / other
    public let deltaValue: Int64
    public init(name: String, unit: String, deltaValue: Int64) {
        self.name = name; self.unit = unit; self.deltaValue = deltaValue
    }
}

/// Seam over the IOReport sample (production = `IOReportPowerSampler`; a fake in tests). Returns the
/// per-channel energy deltas of the "Energy Model" group over `intervalSeconds`, or nil if IOReport is
/// unavailable (no library / no subscription) — the reader then degrades to showing nothing.
public protocol ComponentPowerSampling: Sendable {
    func sampleEnergyDeltas(intervalSeconds: Double) -> [RawRailDelta]?
}

@MainActor
public final class ComponentPowerReader: ObservableObject {

    /// The LIVE rails only (advancing, energy-unit), as modeled watts, sorted desc. Empty → the view
    /// hides the section (no live rail today besides GPU → honest, no fabricated tree).
    @Published public private(set) var readings: [PowerRailReading] = []
    /// True once at least one sample pair completed (so the view can distinguish "probing" from "none").
    @Published public private(set) var hasProbed = false

    /// The sample interval (two reads spaced this far apart yield the energy delta → watts). Short enough
    /// for a responsive popover, long enough for a stable delta.
    /// B-arc B5: 2.0 s, not 1.0 s (paired with the view's 4 s inter-sample sleep). The DISPLAYED figure is
    /// already a `windowSize`-sample rolling mean, so halving the rate costs smoothness-to-settle, not
    /// accuracy — a longer delta window is if anything a steadier per-sample number.
    nonisolated public static let probeInterval: Double = 2.0

    /// B3: per-rail trailing windows of the last `windowSize` per-sample watt values (keyed by rail name).
    /// The DISPLAYED watt figure is the arithmetic mean of a rail's window, so a noisy per-second reading
    /// reads steadily. Reset per popover open via `beginSession()` (sampling is visible-only).
    nonisolated public static let windowSize = 4

    private let sampler: any ComponentPowerSampling
    private var windows: [String: [Double]] = [:]
    public init(sampler: any ComponentPowerSampling = IOReportPowerSampler()) { self.sampler = sampler }

    /// Reset the rolling windows at the start of a fresh popover session (the `.task` calls this before
    /// its sample loop). We prefer this explicit reset over gap detection since sampling is visible-only.
    public func beginSession() { windows = [:] }

    /// Take ONE sample pair off the main actor (it blocks ~`probeInterval`), then publish the live rails.
    /// On IOReport-unavailable (nil) we KEEP the prior readings (no flicker to empty); a rail that goes
    /// dormant simply drops out of the next `liveReadings`.
    public func refresh() async {
        let sampler = self.sampler
        let interval = Self.probeInterval
        let deltas = await Task.detached(priority: .utility) {
            sampler.sampleEnergyDeltas(intervalSeconds: interval)
        }.value
        guard let deltas else { return }
        // B3: smooth the DISPLAYED figure only. liveReadings is unchanged (liveness/unit/watts); we push
        // each live rail's raw watts into its trailing window and publish the per-rail mean.
        windows = Self.updateWindows(windows, with: Self.liveReadings(from: deltas, intervalSeconds: interval),
                                     cap: Self.windowSize)
        readings = Self.meanReadings(from: windows)
        hasProbed = true
    }

    // MARK: - pure logic (host-app-free testable)

    /// The LIVENESS + watts core: keep only channels that ADVANCED (delta > 0 — live, not frozen/zero),
    /// are an energy unit, and yield a finite non-negative watts; convert per the channel's own unit;
    /// sort desc. `Int64.min` (state/array sentinel) and non-energy units are dropped. This is what makes
    /// the readout auto-expand: any rail that starts advancing passes the same filter, no code change.
    nonisolated public static func liveReadings(from deltas: [RawRailDelta], intervalSeconds: Double) -> [PowerRailReading] {
        guard intervalSeconds > 0 else { return [] }
        return deltas.compactMap { d -> PowerRailReading? in
            guard d.deltaValue != Int64.min, d.deltaValue > 0 else { return nil }   // sentinel / frozen / zero → not live
            guard let factor = unitFactor(d.unit) else { return nil }               // non-energy unit → not a power rail
            let watts = Double(d.deltaValue) * factor / intervalSeconds
            guard watts.isFinite, watts >= 0 else { return nil }
            return PowerRailReading(name: d.name, watts: watts)
        }
        .sorted { $0.watts > $1.watts }
    }

    /// Joules-per-unit for an energy channel; nil for any non-energy unit. Per-channel (the Energy Model
    /// group mixes nJ and mJ — research-11), so the conversion is read at runtime, never assumed.
    nonisolated public static func unitFactor(_ unit: String) -> Double? {
        switch unit {
        case "mJ": return 1e-3
        case "uJ": return 1e-6
        case "nJ": return 1e-9
        default:   return nil
        }
    }

    // MARK: - B3 rolling-average smoothing (pure)

    /// Push each live rail's latest watts into its trailing window (kept to the last `cap` values), keyed
    /// by name. Rails ABSENT from `latest` age out (dropped, not carried) consistent with the liveness
    /// rule; a returning rail re-enters fresh and shows from its first value.
    nonisolated public static func updateWindows(_ windows: [String: [Double]],
                                                 with latest: [PowerRailReading],
                                                 cap: Int) -> [String: [Double]] {
        var next: [String: [Double]] = [:]
        for reading in latest {
            var window = windows[reading.name] ?? []   // carry the rail's prior window if it was present last sample
            window.append(reading.watts)
            if window.count > cap { window.removeFirst(window.count - cap) }
            next[reading.name] = window
        }
        return next   // rails absent from `latest` are not copied → aged out
    }

    /// The per-rail arithmetic MEAN of each window, as the displayed readings, sorted desc by mean. Shows
    /// from the first sample (mean of 1, then 2, and so on), so nothing is blank while a window fills.
    nonisolated public static func meanReadings(from windows: [String: [Double]]) -> [PowerRailReading] {
        windows.compactMap { name, window -> PowerRailReading? in
            guard !window.isEmpty else { return nil }
            return PowerRailReading(name: name, watts: window.reduce(0, +) / Double(window.count))
        }
        .sorted { $0.watts > $1.watts }
    }
}
