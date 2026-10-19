import Foundation

/// SPEC v4.0 sec 5: the Pause/Resume UX mapping onto the native limit.
enum PauseResumePolicy {

    /// Pause never targets 100 (100 is not a hold — the min-95 cap fixes the high-SoC silent
    /// no-op) and never goes below the native floor 80.
    static let pauseSteps = [80, 85, 90, 95]

    /// Pause = min(95, highest step <= current SoC); below 80 % SoC the floor applies (the UI
    /// surfaces "charge may still rise to 80"). Unknown SoC: 80 — the most conservative hold
    /// (flagged interpretation; spec does not address nil SoC).
    static func pauseTarget(socPercent: Int?) -> Int {
        guard let soc = socPercent else { return 80 }
        return pauseSteps.last { $0 <= soc } ?? 80
    }
}

/// What Pause captured, persisted so Resume survives an app restart (sec 5: capture is
/// persisted with a timestamp).
struct PauseCapture: Codable, Equatable, Sendable {
    /// The absorbed limit at Pause time (S-N3: the value the USER had, not an app preference).
    /// nil = the limit was `.unknown` at Pause (Get-degraded) — Resume defaults to 100.
    var pausedFromLimit: Int?
    /// What Pause set — the pre-Resume Get verifies the world still matches this (Grok SF2).
    var pauseTarget: Int
    var capturedAt: Date
    /// Set when a re-sync during the pause saw an external change (S-N3): Resume restores 100
    /// with the external-change note instead of the stale capture.
    var invalidatedByExternalChange = false
}

/// SWEEP H2 PREREQUISITE — the schema-tolerant decoder. **This must ship BEFORE `.corrupt ⇒ paused`.**
///
/// THE HAZARD. `.corrupt` now suspends the entire scheduler and demands a user Resume, which is only a
/// defensible default while `.corrupt` stays RARE. `PauseCapture` carries no version field, and Swift's
/// SYNTHESIZED `Decodable` throws on a missing key — it does **not** fall back to a property's default
/// value. So the day a later release adds one stored property, every blob the previous release wrote
/// lacks that key, throws, and reads `.corrupt`: **every upgrade looks like a pause**, on every machine,
/// all at once, each one demanding a Resume that then sets 100 on a pack the user never paused. A
/// version-bump landmine wired to the new default.
///
/// THE MECHANISM, and why this one. A hand-written `init(from:)` in an EXTENSION (the extension is
/// load-bearing — an initializer in the struct body would suppress the memberwise init every call site
/// uses) in which every non-essential field is `decodeIfPresent`-with-default:
///
///   * It is the smallest thing that meets the bar, and it needs no supervision — nothing to keep in
///     sync, nothing to migrate, no second store.
///   * It removes the synthesis, so a future author adding a NON-optional field without a default is
///     forced by the compiler into this initializer, where every surrounding line is the tolerant
///     pattern. And one added WITH a default compiles untouched and simply never decodes — a lost
///     field, which is a bug, but never a corrupt storm. **Both branches of forgetting are fail-safe**,
///     which a convention ("remember to make new fields optional") can never be.
///   * Rejected: an explicit `version` field. It is only useful with per-version decode paths — a
///     fleet-shaped mechanism in an app with one user, and one more thing to supervise (constraint:
///     "rather delete a mechanism than add another"). It also would not have helped, because the
///     migration it exists to trigger is exactly the `decodeIfPresent` below.
///   * Rejected: a two-step decode (strict, then a lenient essentials-only retry). Same tolerance, two
///     decode paths that can disagree, and a lenient shape that has to be kept parallel by hand.
///   * The escape hatch for a genuinely BREAKING change already exists and is not this: the key is
///     versioned (`chargeControl.pauseCapture.v1`), so an incompatible schema takes a new key and the
///     old one is cleared. This decoder covers ADDITIVE change, which is the change that actually happens.
///
/// WHAT STAYS REQUIRED. `pauseTarget` and `capturedAt`. Every version that has ever written this key
/// wrote both, so no upgrade can lack them; a blob without them is not a lenient capture, it is
/// unreadable, and `.corrupt` — now meaning "paused, restore point lost" — is the honest answer.
/// Unknown keys are ignored by `JSONDecoder` and are pinned as behaviour by the tests.
///
/// The synthesized `encode(to:)` is deliberately kept (it cannot drift out of sync with the stored
/// properties); the round-trip test is the tripwire for a field that is encoded but not decoded.
extension PauseCapture {
    enum CodingKeys: String, CodingKey {
        case pausedFromLimit, pauseTarget, capturedAt, invalidatedByExternalChange
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — absent means this is not a capture.
        self.pauseTarget = try c.decode(Int.self, forKey: .pauseTarget)
        self.capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        // TOLERANT — every field from here on, and EVERY FIELD ADDED LATER, must be decoded this way.
        self.pausedFromLimit = try c.decodeIfPresent(Int.self, forKey: .pausedFromLimit)
        self.invalidatedByExternalChange =
            try c.decodeIfPresent(Bool.self, forKey: .invalidatedByExternalChange) ?? false
    }
}

/// SWEEP H2 (`knowledge/12-SWEEP-silent-absence.md`): how a stored pause capture READ.
///
/// `PauseCapture?` answered two completely different questions with the same `nil` —
/// *"charging was never paused"* and *"the stored pause will not decode"* — and only the second one
/// loses the user's restore point. `try?` made the second one silently become the first.
///
/// Same three-state posture as the precedents already in the tree: `BatterySnapshot.TemperatureReading`,
/// `BatteryLifetimeReadFailure`, `RawCorroboration` (corroborates / contradicts / **unavailable**) and
/// `PowerAdapterReadState` (.connected / .noAdapter / .unavailable). Absence gets its own name so it
/// can never be read as an answer.
enum PauseCaptureLoad: Equatable, Sendable {
    /// Nothing is stored under the key — the LEGITIMATE empty. Only `pause()` ever writes it, and
    /// `resume()` / an authoritative in-app Set clear it, so this really does mean "not paused".
    case none
    /// A capture that decoded.
    case capture(PauseCapture)
    /// Bytes ARE stored under the key but will not decode (a schema change, a truncated write).
    /// A pause HAPPENED; what it captured is gone.
    case corrupt
}

extension PauseCaptureLoad {
    /// The capture, when there is a decodable one.
    var capture: PauseCapture? { if case .capture(let c) = self { return c } else { return nil } }

    /// Is charging paused? `.corrupt` answers **yes**, and that is the whole point of this type.
    /// Only `pause()` ever writes this key, so undecodable bytes under it are still evidence that a
    /// pause happened — the pack is being held at a pause target right now. Reading them as "never
    /// paused" (the old `try?`) strands the machine at that target with the app showing no pause, no
    /// caveat and no Resume button: a VANISHED latch, the exact mirror of ISSUE-11's stale one.
    var indicatesPaused: Bool {
        switch self {
        case .none: return false
        case .capture, .corrupt: return true
        }
    }

    /// A pause is in force but what it captured is unrecoverable — the caller MUST say so.
    ///
    /// **The decision, deliberately** (SWEEP step 3): a lost restore point does **not block** Resume.
    /// Refusing would leave the machine capped at the pause target with its only exit removed — the
    /// same defect shape as the stalled Top Up climb that had no Cancel (`752086e`). Resume therefore
    /// proceeds, and resolves to 100, which is already what this file documents for an unknown restore
    /// point (`pausedFromLimit == nil` → "Resume defaults to 100"); no second witness survives a
    /// corrupt capture, because the live limit AND the last-set custody both read the *pause* target,
    /// not the pre-pause one.
    ///
    /// What it must never do is that **silently**. 100 is the uncapped, battery-ageing direction and
    /// holding the cap below it is the app's entire purpose, so a restore to 100 taken on no evidence
    /// has to be disclosed as "we lost your previous limit — set it again", never presented as a
    /// restore. Proceed, and warn.
    var restorePointLost: Bool { self == .corrupt }
}

protocol PauseCaptureStoring: Sendable {
    func load() -> PauseCapture?
    /// The three-state read. In-memory doubles (which cannot fail to decode) inherit the default.
    func loadDetailed() -> PauseCaptureLoad
    func save(_ capture: PauseCapture)
    func clear()
}

extension PauseCaptureStoring {
    /// Default for stores that have no decode step: whatever `load()` says, with no `.corrupt` case
    /// reachable. Safe against recursion because `load()` is a protocol REQUIREMENT, not a default.
    func loadDetailed() -> PauseCaptureLoad {
        if let c = load() { return .capture(c) } else { return .none }
    }
}

/// App-container prefs only (S-N6).
struct UserDefaultsPauseCaptureStore: PauseCaptureStoring {
    static let key = "chargeControl.pauseCapture.v1"

    /// Test seam ONLY — a named suite so the REAL decoder can be driven over real bytes (a fake store
    /// can never prove the production `try?` was the defect). `nil` = `UserDefaults.standard`, the
    /// production path. Held as a NAME, not a `UserDefaults`, because this store is `Sendable`.
    private let suiteName: String?
    init(suiteName: String? = nil) { self.suiteName = suiteName }
    private var defaults: UserDefaults {
        guard let suiteName, let d = UserDefaults(suiteName: suiteName) else { return .standard }
        return d
    }

    func loadDetailed() -> PauseCaptureLoad {
        // Final review F6: `data(forKey:)` is nil for an absent key AND for a value of the wrong type.
        // Only the first is "never paused"; anything stored under the key is evidence a pause happened.
        guard let data = defaults.data(forKey: Self.key) else {
            return defaults.object(forKey: Self.key) == nil ? .none : .corrupt
        }
        guard let capture = try? JSONDecoder().decode(PauseCapture.self, from: data) else { return .corrupt }
        return .capture(capture)
    }
    /// Preserved call shape. NOTE the deliberate asymmetry: this still answers `nil` for `.corrupt`,
    /// so every existing caller behaves byte-identically — the honest answer is available only to a
    /// caller that asks for it via `loadDetailed()`.
    func load() -> PauseCapture? { loadDetailed().capture }
    func save(_ capture: PauseCapture) {
        if let data = try? JSONEncoder().encode(capture) {
            defaults.set(data, forKey: Self.key)
        }
    }
    func clear() { defaults.removeObject(forKey: Self.key) }
}
