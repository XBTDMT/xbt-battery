import Foundation
import Combine
import AppKit       // B1: NSRunningApplication resolves a coalition bundle id → a friendly app name
import Shared

// Sprint 3.7 STAGE 4 (#19-real) — app-side source for SUSTAINED, app-attributed energy via the
// privileged helper's powermetrics tasks plist. Mirrors EnergyImpactSource: injected seam, fetched on
// popover OPEN only (NO background polling — a draining energy monitor is self-defeating; the irony is
// the design spine). HONEST unavailability: an unapproved helper, a powermetrics failure, or an
// unparseable/garbled result HIDES the section — never a fake number. Dev-gated this stage (UI = STAGE 5).

/// Which energy section the popover shows (Stage 5 B2: ONE adaptive section, per the owner ruling). The
/// sustained per-app ranking is PRIMARY when the helper is delivering rows. Otherwise we fall back to the
/// free, no-root "Active now" snapshot (never a wall when the snapshot can show). The approve affordance
/// appears only when the helper is genuinely not delivering, never to nag an already-approved, idle helper.
///   .sustained            the sustained ranking (helper delivering rows).
///   .snapshotWithUpsell   the snapshot rows PLUS a small "approve for a sustained ranking" hint
///                         (helper unavailable: unapproved, unreachable, or failed).
///   .snapshot             the snapshot rows alone, NO upsell (helper approved but idle/empty: do not nag).
///   .sustainedUnavailable the approve affordance alone (helper unavailable and no snapshot to show).
///   .none                 nothing to show (helper approved but idle, and no snapshot either).
///
/// FLAG (owner, the upsell condition): we distinguish "helper not delivering" (`sustainedAvailable == false`,
/// i.e. `SustainedEnergySource.isUnavailable`) from "approved but empty" (available, no entries) and show
/// the upsell only in the former, so an approved user is not nagged. `isUnavailable` also covers the rare
/// "approved but the output failed to parse" case, where the "approve" wording is slightly off but harmless;
/// a cleaner split would need the source to expose unreachable versus parse-failure separately. Confidence
/// this matches the owner's stated intent (no nag of an approved user): high.
public enum EnergySectionChoice: Equatable, Sendable {
    case sustained, snapshotWithUpsell, snapshot, sustainedUnavailable, none
}

/// SWEEP §2.G (knowledge/12-SWEEP-silent-absence.md, hit 4). WHICH unavailability.
///
/// `isUnavailable` was set from BOTH `case .failure` (helper unapproved / unreachable / `powermetrics`
/// failed) AND a nil from `SustainedEnergyParser.parse` (garbled, truncated, or — the case that matters —
/// Apple changed the `coalitions` plist shape). The popover then told an ALREADY-APPROVED user to
/// "Approve the energy helper": an instruction that is wrong and that they cannot act on. The FLAG above
/// named this gap itself ("a cleaner split would need the source to expose unreachable versus
/// parse-failure separately"); this is that split.
///
/// Deliberately ADDITIVE: `isUnavailable` and `energySectionChoice` are byte-unchanged, so the owner's
/// ruled no-nag logic is untouched. Only the SENTENCE now follows the cause.
public enum SustainedUnavailability: Equatable, Sendable {
    /// The helper did not deliver — unapproved, not running, or `powermetrics` failed. Approving helps.
    case helperUnavailable
    /// The helper DID deliver and the output could not be parsed. Approving does not help; this is the
    /// macOS-format-drift signature, and it must not present as a permanent approval nag.
    case outputUnparseable

    /// The copy that matches the cause.
    public var message: String {
        switch self {
        case .helperUnavailable: return "Approve the energy helper to see which apps are using energy."
        case .outputUnparseable: return "The energy report couldn't be read — macOS may have changed its format."
        }
    }
}

public func energySectionChoice(sustainedAvailable: Bool,
                                sustainedHasEntries: Bool,
                                snapshotHasEntries: Bool) -> EnergySectionChoice {
    // Sustained ranking is PRIMARY when the helper is delivering rows.
    if sustainedAvailable && sustainedHasEntries { return .sustained }
    // Not primary. Fall back to the free snapshot when it has rows; add the upsell ONLY when the helper
    // is genuinely not delivering (unavailable). An approved-but-idle helper (available, empty) gets the
    // plain snapshot, no nag.
    if snapshotHasEntries { return sustainedAvailable ? .snapshot : .snapshotWithUpsell }
    // Nothing else to show. The approve wall only when the helper is genuinely unavailable; an
    // approved-but-idle helper with no snapshot shows nothing (no false "approve" wall).
    return sustainedAvailable ? .none : .sustainedUnavailable
}

/// B1: resolve a coalition's responsible-app bundle id → a friendly display name (seam: NSRunningApplication
/// in production, a dictionary in tests). Returns nil when no running app matches (→ pure fallback).
public protocol CoalitionNameResolving: Sendable {
    func localizedName(forBundleID id: String) -> String?
}

/// Production resolver: the localized name of a RUNNING app with this bundle id (untruncated), else nil.
public struct RunningCoalitionNameResolver: CoalitionNameResolving {
    public init() {}
    public func localizedName(forBundleID id: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
    }
}

/// Seam over the privileged collect call (HelperClient conforms in production; a mock in tests). It is
/// `@MainActor`: fetched from the UI; the conformance marshals the helper's background reply to main.
@MainActor
public protocol TaskEnergyCollecting: AnyObject {
    // `completion` is `@Sendable`: the production conformance (HelperClient) invokes it from NSXPC's
    // background reply/error handlers (then hops to the main actor), so it must cross threads safely.
    func collectTaskEnergy(samples: Int, intervalMs: Int,
                           completion: @escaping @Sendable (Result<Data, HelperClientError>) -> Void)
}

@MainActor
public final class SustainedEnergySource: ObservableObject {

    /// The top responsible-app rows (friendly-named, capped to `displayCount`, ranked desc). Empty → the
    /// view hides. NEVER a fabricated value.
    @Published public private(set) var apps: [SustainedEnergyEntry] = []
    @Published public private(set) var isRefreshing = false
    /// Honest hide: helper unapproved / powermetrics failed / output unparseable. The view shows the
    /// sustained section only when `!isUnavailable && !apps.isEmpty`.
    @Published public private(set) var isUnavailable = false
    /// SWEEP §2.G: WHY it is unavailable — nil whenever `isUnavailable` is false. Additive; the hide
    /// decision is unchanged, only the sentence the view renders now follows the actual cause.
    @Published public private(set) var unavailableReason: SustainedUnavailability?
    /// B1: the grand total (all_tasks.energy_impact) — the denominator for each row's share-of-total bar.
    /// nil when absent/invalid → the view falls back to a busiest-row-relative bar.
    @Published public private(set) var total: Double?

    /// How many responsible-app rows the headline shows (the rest are folded into "everything else" by
    /// omission — the bars are a share of the all-activity total, so the top rows reading <100% is honest).
    public static let displayCount = 12   // 2026-09-09: the Energy tab shows the full shared ranking (PowerDrawersModel.cap)

    private let collector: TaskEnergyCollecting
    private let nameResolver: any CoalitionNameResolving
    public init(collector: TaskEnergyCollecting,
                nameResolver: any CoalitionNameResolving = RunningCoalitionNameResolver()) {
        self.collector = collector
        self.nameResolver = nameResolver
    }

    /// B1: a friendly display name for a coalition bundle id, used when the live resolver finds no running
    /// app. PURE + testable; never blank. "com.mitchellh.ghostty" → "Ghostty"; "kernel_coalition" → "System".
    public static func friendlyNameFallback(forCoalition raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return raw }
        switch trimmed {
        case "kernel_coalition", "kernel_task": return "System"
        default: break
        }
        guard trimmed.contains(".") else { return trimmed }   // not reverse-DNS → show as-is
        guard let last = trimmed.split(separator: ".").last.map(String.init), !last.isEmpty else { return trimmed }
        return last.prefix(1).uppercased() + last.dropFirst()   // last component, first letter upper
    }

    /// Fetch on popover OPEN — ONE-SHOT (no background polling). Cached rows remain visible while a
    /// fresh sample runs. Any failure or unparseable/garbled result sets `isUnavailable` (HIDE); a
    /// valid-but-empty result yields `apps == []` (also hidden). Never surfaces partial-as-real.
    public func refresh() {
        isRefreshing = true
        // `completion` is `@Sendable` (the helper calls it from a background XPC handler, then hops to
        // main). It is delivered ON the main actor, so `assumeIsolated` lets us touch our @MainActor state.
        collector.collectTaskEnergy(samples: TaskEnergyCommand.defaultSamples,
                                    intervalMs: TaskEnergyCommand.defaultIntervalMs) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case .failure:
                    // helper unapproved / not running, or powermetrics failed → honest hide (keep any cache)
                    self.isUnavailable = true
                    self.unavailableReason = .helperUnavailable
                case .success(let plistData):
                    guard let entries = SustainedEnergyParser.parse(plistData: plistData) else {
                        // The helper DELIVERED and the output would not parse. Distinct fact, distinct
                        // advice — telling an approved user to approve is the failure mode this fixes.
                        self.isUnavailable = true   // garbled/truncated → hide (never partial-as-real)
                        self.unavailableReason = .outputUnparseable
                        return
                    }
                    self.isUnavailable = false
                    self.unavailableReason = nil    // a good read clears a stale cause
                    // B1: friendly-map each coalition bundle id (live resolver → pure fallback), keep the id
                    // + energy from the parser, then cap to the top displayCount (already ranked desc). []
                    // when there are no attributable tasks → view hides.
                    let named = entries.map { e -> SustainedEnergyEntry in
                        let friendly = self.nameResolver.localizedName(forBundleID: e.name)
                            ?? Self.friendlyNameFallback(forCoalition: e.name)
                        return SustainedEnergyEntry(id: e.id, name: friendly, energyImpact: e.energyImpact)
                    }
                    self.apps = Array(named.prefix(Self.displayCount))
                    self.total = SustainedEnergyParser.parseTotal(plistData: plistData)   // share-of-total denominator
                }
            }
        }
    }
}
