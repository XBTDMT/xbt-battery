import Foundation
import Combine

/// Sprint 4.C (2), 4g: the autonomous scheduler runtime. Owns the persisted config, the fired-set,
/// the recompute loop, and human primacy. Pure trigger math lives in `ChargeSchedule`; this file is
/// the plumbing — time/wake/clock/persistence are SEAMS so the firing/deference behaviors are
/// testable without real timers or wall-clock waits.
///
/// 4g thermostat-hold: there is no manual-override skip. A user change holds via the fired-set until
/// the next trigger reasserts; Resume applies the schedule's current dictate immediately.
///
/// **Never wakes the machine** (sec 2): the pacer is an ordinary timer that only ticks while
/// awake; catch-up on wake/launch covers anything missed during sleep.

// MARK: - seams

protocol ScheduleClock: Sendable { func now() -> Date }
struct LiveScheduleClock: ScheduleClock { func now() -> Date { Date() } }

/// Periodic recompute pacer. Live = a Timer; tests drive ticks manually.
@MainActor protocol SchedulePacing: AnyObject {
    func start(interval: TimeInterval, onTick: @escaping () -> Void)
    func stop()
}

@MainActor final class LiveSchedulePacer: SchedulePacing {
    private var timer: Timer?
    private var onTick: (() -> Void)?
    func start(interval: TimeInterval, onTick: @escaping () -> Void) {
        timer?.invalidate()
        self.onTick = onTick
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; onTick = nil }
}

/// SWEEP H4 (`knowledge/12-SWEEP-silent-absence.md`): how the two persisted schedule blobs READ.
///
/// The generic `try?` decoder answered "nothing was ever stored" and "the stored bytes will not
/// decode" identically, and for BOTH keys the collapse-value is the one that means something
/// specific: `.empty` means *the user has no schedule*, and `[]` means *nothing has fired today*.
/// Three-state, per the tree's precedents (`PowerAdapterReadState`, `RawCorroboration`).
enum ScheduleConfigLoad: Equatable {
    /// Nothing stored — a genuine first run. The LEGITIMATE empty.
    case none
    case config(ChargeScheduleConfig)
    /// Bytes are stored but will not decode. NOT the same as "no schedule": `.empty` carries
    /// `enabled == false` and `presetOffered == false`, i.e. it asserts the user never set one up.
    case corrupt

    var config: ChargeScheduleConfig? { if case .config(let c) = self { return c } else { return nil } }
}

enum FiredSetLoad: Equatable {
    /// Nothing stored — nothing has ever fired. The LEGITIMATE empty.
    case none
    case fired(Set<FiredOccurrence>)
    /// Redman sweep item 2: the set decoded element by element and `undecodable` record(s) would not.
    /// The readable ones are kept. Treated like `.corrupt` for the H4 guard — a lost record may be the
    /// operative occurrence's, so the runner still presumes that one fired.
    case partial(Set<FiredOccurrence>, undecodable: Int)
    /// Bytes are stored but will not decode. NOT the same as "nothing has fired": the fired-set IS
    /// the 4g human-primacy mechanism, so reading it as empty un-protects a manual change.
    case corrupt

    var fired: Set<FiredOccurrence>? {
        switch self {
        case .fired(let f), .partial(let f, _): return f
        case .none, .corrupt: return nil
        }
    }
    /// At least one stored record could not be read (the whole set, or some elements of it).
    var lostRecords: Bool {
        switch self {
        case .corrupt, .partial: return true
        case .none, .fired: return false
        }
    }
}

/// Persistence (UserDefaults — app container, S-N6-clean).
protocol ScheduleStoring: Sendable {
    func loadConfig() -> ChargeScheduleConfig
    func saveConfig(_ c: ChargeScheduleConfig)
    func loadFired() -> Set<FiredOccurrence>
    func saveFired(_ f: Set<FiredOccurrence>)
    /// The three-state reads. In-memory doubles (which cannot fail to decode) inherit the defaults.
    func loadConfigDetailed() -> ScheduleConfigLoad
    func loadFiredDetailed() -> FiredSetLoad
    /// Redman sweep item 1: MOVE an unreadable stored config aside (never delete it), so edits can save
    /// again. A no-op when the stored config is readable or absent.
    func setAsideUnreadableConfig()
}

extension ScheduleStoring {
    /// Defaults for stores with no decode step — `.corrupt` is unreachable for them. Safe against
    /// recursion because `loadConfig()`/`loadFired()` are protocol REQUIREMENTS, not defaults.
    func loadConfigDetailed() -> ScheduleConfigLoad { .config(loadConfig()) }
    func loadFiredDetailed() -> FiredSetLoad { .fired(loadFired()) }
    /// No decode step, so nothing can be unreadable — nothing to set aside.
    func setAsideUnreadableConfig() {}
}

struct UserDefaultsScheduleStore: ScheduleStoring {
    private static let configKey = "chargeSchedule.config.v1"
    private static let firedKey = "chargeSchedule.fired.v1"

    /// Test seam ONLY — a named suite so the REAL decoder can be driven over real bytes (a fake store
    /// can never prove the production `try?` was the defect). `nil` = `UserDefaults.standard`, the
    /// production path. Held as a NAME, not a `UserDefaults`, because this store is `Sendable`.
    private let suiteName: String?
    private var defaults: UserDefaults {
        guard let suiteName, let d = UserDefaults(suiteName: suiteName) else { return .standard }
        return d
    }

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
        // 4g hygiene: clear any skip persisted by prior builds — the key is now inert. Idempotent.
        defaults.removeObject(forKey: "chargeSchedule.skip.v1")
    }

    func loadConfigDetailed() -> ScheduleConfigLoad {
        let r: (value: ChargeScheduleConfig?, corrupt: Bool) = Self.decode(Self.configKey, defaults)
        if r.corrupt { return .corrupt }
        if let v = r.value { return .config(v) }
        return .none
    }
    /// Redman sweep item 2: decoded ELEMENT BY ELEMENT. A `Set` encodes as a JSON array; decoding it as
    /// one `Set<FiredOccurrence>` let a single bad record throw away every readable one. Only a top level
    /// that is not an array of something is `.corrupt` now.
    func loadFiredDetailed() -> FiredSetLoad {
        guard let data = defaults.data(forKey: Self.firedKey) else {
            return defaults.object(forKey: Self.firedKey) == nil ? .none : .corrupt
        }
        guard let elements = try? JSONDecoder().decode([LossyFiredOccurrence].self, from: data) else { return .corrupt }
        let good = Set(elements.compactMap(\.value))
        let bad = elements.count - elements.compactMap(\.value).count
        if bad > 0 {
            NSLog("battery_app: charge schedule fired-set — %d record(s) would not decode; %d kept.", bad, good.count)
            return .partial(good, undecodable: bad)
        }
        return .fired(good)
    }
    /// One array element that may or may not decode — never throws, so the array decode continues.
    private struct LossyFiredOccurrence: Decodable {
        let value: FiredOccurrence?
        init(from decoder: any Decoder) throws { value = try? FiredOccurrence(from: decoder) }
    }
    /// Preserved call shapes. The deliberate asymmetry, as in `PauseResume`: these still collapse
    /// `.corrupt` into the legitimate empty, so every existing caller behaves byte-identically — the
    /// honest answer is available only to a caller that asks for it.
    func loadConfig() -> ChargeScheduleConfig { loadConfigDetailed().config ?? .empty }
    func loadFired() -> Set<FiredOccurrence> { loadFiredDetailed().fired ?? [] }
    /// Redman sweep item 1 — defence in depth: this store will not replace bytes that are present but
    /// will not decode, whoever asks. The runner already refuses the edit; this makes the guarantee
    /// hold at the one place that can actually destroy the blob.
    func saveConfig(_ c: ChargeScheduleConfig) {
        if loadConfigDetailed() == .corrupt {
            NSLog("battery_app: charge schedule save REFUSED — the stored config (%@) will not decode and "
                  + "is not overwritten.", Self.configKey)
            return
        }
        Self.encode(c, Self.configKey, defaults)
    }
    /// Copy the unreadable bytes to a dated key, then remove the original — the bytes are kept, not lost.
    func setAsideUnreadableConfig() {
        // F6: moves whatever is stored (bytes, or a value of the wrong type), not only `Data`.
        guard loadConfigDetailed() == .corrupt, let stored = defaults.object(forKey: Self.configKey) else { return }
        let asideKey = "\(Self.configKey).unreadable.\(Int(Date().timeIntervalSince1970))"
        defaults.set(stored, forKey: asideKey)
        guard let kept = defaults.object(forKey: asideKey) as? NSObject, kept.isEqual(stored) else { return }   // never remove what was not kept
        defaults.removeObject(forKey: Self.configKey)
        NSLog("battery_app: unreadable charge schedule config set aside under %@ (value kept as-is).", asideKey)
    }
    func saveFired(_ f: Set<FiredOccurrence>) { Self.encode(f, Self.firedKey, defaults) }

    /// Three-state decode: `(nil, false)` nothing stored · `(v, false)` decoded · `(nil, true)` corrupt.
    private static func decode<T: Decodable>(_ key: String, _ d: UserDefaults) -> (value: T?, corrupt: Bool) {
        // Final review F6: `data(forKey:)` is nil for an absent key AND for a value of the wrong type —
        // only the first is "nothing stored".
        guard let data = d.data(forKey: key) else { return (nil, d.object(forKey: key) != nil) }
        guard let v = try? JSONDecoder().decode(T.self, from: data) else { return (nil, true) }
        return (v, false)
    }
    private static func encode<T: Encodable>(_ v: T, _ key: String, _ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }
}

// MARK: - the runner

@MainActor
final class ScheduleRunner: ObservableObject {

    enum RecomputeReason { case timer, wake, launch, clockChange, ruleEdit, resumeNow }

    /// Pacer cadence — frequent enough that a trigger fires within ~½ min of its time, and the
    /// retry granularity for in-flight deference. Not a machine wake.
    static let tickInterval: TimeInterval = 30
    static let maxDeferral: TimeInterval = 300   // sec 3: defer ≤5 min, then skip-with-note

    @Published private(set) var config: ChargeScheduleConfig
    /// The one visible schedule note (pause-suspension, setup-required, deferral-skip). The UI offers
    /// the Resume affordance whenever the live limit diverges from the schedule (see `resumeTarget()`).
    @Published private(set) var note: String?

    private let engine: ChargeLimitEngine
    private let store: any ScheduleStoring
    private let clock: any ScheduleClock
    private let pacer: any SchedulePacing
    private let calendarProvider: () -> Calendar
    private let isSetupReady: () -> Bool

    private var fired: Set<FiredOccurrence>
    private var lastSeenLimit: ChargeLimitValue
    private var deferring: (occurrence: FiredOccurrence, since: Date)?
    private var cancellable: AnyCancellable?
    private var started = false
    /// Whether the pacer timer is currently running — `syncPacer` is edge-triggered off this.
    private var pacing = false

    /// audit A3/A4: per-occurrence consecutive scheduled-Set failure count (in-memory; pruned with the
    /// fired-set). Test-observable (read-only).
    private(set) var scheduleSetMisses: [FiredOccurrence: Int] = [:]
    /// initial attempt + 2 retries, ~30 s apart (the pacer cadence).
    static let maxScheduleSetAttempts = 3
    /// The scheduled-Set give-up note is the ONLY sticky note; every other `note` assignment resets this
    /// (via `setTransientNote`) so a stale transient note never outlives the condition that set it, and
    /// recompute's `.none` branch clears the note ONLY when it is false.
    private var noteIsSticky = false

    /// SWEEP H4. The stored config would not decode, so `config` is the fabricated `.empty` rather
    /// than anything the user authored. Behaviour is already the safe one — `.empty` is `enabled ==
    /// false`, and an unreadable schedule must certainly not run autonomous Sets — but the *claim* is
    /// wrong: the Automation tab presents an unreadable config as "you never set up a schedule", down
    /// to re-offering the starter preset. Test-observable, and the honest screen for it is OWED (see
    /// the note on `init`): `schedule.note` cannot carry it, because `SettingsView.scheduleSection`
    /// renders the note only INSIDE `if schedule.config.enabled`, which a corrupt config is not.
    /// Deliberately NOT `@Published` until that screen exists — a published state with no screen is
    /// the exact thing `scripts/ui-orphan-gate.sh` was built to catch.
    /// Redman sweep item 1: while this is true every edit is REFUSED (`mutate`) and the store will not
    /// save over the blob; only `setAsideUnreadableConfig()` clears it, and it keeps the bytes.
    private(set) var configUnreadable = false
    /// SWEEP H4. The stored fired-set would not decode; `adoptUnreadableFiredRecord` has run.
    private(set) var firedRecordUnreadable = false

    init(engine: ChargeLimitEngine,
         store: any ScheduleStoring = UserDefaultsScheduleStore(),
         clock: any ScheduleClock = LiveScheduleClock(),
         pacer: any SchedulePacing = LiveSchedulePacer(),
         isSetupReady: @escaping () -> Bool,
         calendarProvider: @escaping () -> Calendar = { var c = Calendar.current; c.timeZone = .current; return c }) {
        self.engine = engine
        self.store = store
        self.clock = clock
        self.pacer = pacer
        self.isSetupReady = isSetupReady
        self.calendarProvider = calendarProvider
        // SWEEP H4: read both blobs three-state. A corrupt read still FALLS BACK to the same value it
        // used to collapse into — we have nothing else to run on — but it no longer does so silently.
        let configLoad = store.loadConfigDetailed()
        let firedLoad = store.loadFiredDetailed()
        self.config = configLoad.config ?? .empty
        self.configUnreadable = (configLoad == .corrupt)
        self.fired = firedLoad.fired ?? []
        self.firedRecordUnreadable = firedLoad.lostRecords
        self.lastSeenLimit = engine.limit
        // Redman sweep item 2: a PARTIAL read takes the same H4 path as a corrupt one — the readable
        // records are kept (`fired` above), and the operative occurrence is still presumed fired,
        // because the record that would not decode may have been exactly that one.
        if firedLoad.lostRecords { adoptUnreadableFiredRecord() }
    }

    /// SWEEP H4 — what an unreadable fired-set DOES.
    ///
    /// A fired-set that will not decode is not an empty fired-set. Read as empty, every occurrence
    /// looks un-fired; the one that would then re-fire is the OPERATIVE occurrence, and `nextAction`
    /// only acts on it when the live limit DIVERGES from the schedule's dictate. Under the 4g
    /// thermostat-hold that divergence is precisely the shape of a deliberate manual change — the
    /// fired-set IS the mechanism that protects it ("a user change holds via the fired-set until the
    /// next trigger reasserts"). So the blast radius is not "one duplicate Set": it is an autonomous
    /// Set silently clobbering an explicit human decision, and the value it clobbers to may be 100.
    ///
    /// **Unknown therefore biases toward NOT firing.** Firing is autonomous and physical; not firing
    /// is inert. The two causes of divergence (a manual change vs a genuinely missed fire) are
    /// indistinguishable once the record is gone, and only the first is unrecoverable by the app —
    /// the second self-heals at the next occurrence (≤24 h, ~9.5 h on the starter preset) and is
    /// already offered back one tap sooner (see below).
    ///
    /// The mechanism is 4g-native rather than a new suppression concept (4g deliberately deleted the
    /// manual-override skip): mark the operative occurrence PRESUMED-FIRED and persist that. This
    /// (a) withholds exactly the one reassertion whose record was lost, (b) replaces the undecodable
    /// blob with a decodable one, so it is a one-shot that self-heals, and (c) leaves every LATER
    /// occurrence completely untouched.
    ///
    /// **The user is not stranded, and needs no new screen.** The suppression is exactly
    /// co-extensive with `resumeTarget()` — both key off `engine.limit != operative.rule.limit` —
    /// so whenever this actually withholds a reassertion, the "Resume schedule (N% now)" affordance
    /// is on screen offering it in one tap; and whenever that affordance is absent, nothing was
    /// going to fire. (Proven by `testCorruptFiredRecordAlwaysLeavesTheResumeAffordanceOnScreen`.)
    private func adoptUnreadableFiredRecord() {
        let cal = calendarProvider()
        if let operative = ChargeSchedule.operativeOccurrence(now: clock.now(), calendar: cal, config: config) {
            fired.insert(FiredOccurrence(ruleID: operative.rule.id,
                                         dayKey: ChargeSchedule.dayKey(for: operative.date, calendar: cal)))
        }
        // Replace the undecodable blob either way. Redman sweep item 2 re-examined this overwrite and keeps
        // it: unlike the CONFIG (user-authored, never written over — sweep item 1) the fired-set is a
        // ~2-day idempotence record the runner itself writes and prunes, and the only fact an unreadable
        // record can carry is "this occurrence fired". Only the OPERATIVE occurrence can still fire
        // (`nextAction` acts on nothing else), and it is presumed fired just above — so the write loses
        // no decision the record could have made, while every readable record (now kept per element)
        // is carried into it.
        store.saveFired(fired)
    }

    // MARK: - lifecycle

    func start() {
        guard !started else { return }
        started = true
        lastSeenLimit = engine.limit
        // Human-primacy: observe genuine limit changes the runner did NOT cause.
        cancellable = engine.$limit
            .dropFirst()
            .sink { [weak self] newLimit in
                MainActor.assumeIsolated { self?.handleLimitChange(newLimit) }
            }
        syncPacer()
        recompute(.launch)
    }

    func stop() {
        pacer.stop()
        pacing = false
        cancellable = nil
        started = false
    }

    /// B-arc B3: the pacer only runs when it can actually do something — an enabled schedule holding at
    /// least one rule. With the feature off (the default) the 30 s timer previously ticked ~2,880 times a
    /// day only to hit `recompute`'s `guard config.enabled` and return.
    ///
    /// Safe because the pacer is a PRECISION aid, not the correctness mechanism: every state that can make
    /// a trigger due already forces its own recompute — wake, launch, clock/timezone change, and rule edit
    /// (`.wake` / `.launch` / `.clockChange` / `.ruleEdit`). The pacer only narrows a due trigger to within
    /// ~½ min of its time, and it is stopped precisely in the states where `recompute` early-returns anyway.
    private var pacerShouldRun: Bool { config.enabled && !config.rules.isEmpty }

    /// Bring the pacer in line with `pacerShouldRun`. EDGE-triggered on `pacing`: `LiveSchedulePacer.start`
    /// invalidates and re-creates its timer, so calling it on an already-running pacer would reset the
    /// interval — and a burst of rule edits could then starve the tick indefinitely.
    private func syncPacer() {
        guard started else { return }
        if pacerShouldRun {
            guard !pacing else { return }
            pacing = true
            pacer.start(interval: Self.tickInterval) { [weak self] in self?.recompute(.timer) }
        } else if pacing {
            pacing = false
            pacer.stop()
        }
    }

    // MARK: - config editing (UI) — each edit triggers a recompute

    /// The schedule toggle (SettingsView / AutomationPage bindings). A DELIBERATE act — see
    /// `setAsideForDeliberateFirstRunTap`; without it the toggle snapped back on an unreadable config and
    /// the first-run buttons it reveals were unreachable (final review F1).
    func setEnabled(_ on: Bool) {
        setAsideForDeliberateFirstRunTap("Schedule toggle")
        mutate { $0.enabled = on }
    }
    /// AutomationPage / SettingsView "Add". A DELIBERATE act (F1).
    @discardableResult func addRule(_ r: ChargeRule) -> Bool {
        setAsideForDeliberateFirstRunTap("Add rule")
        var ok = false; mutate { ok = $0.addRule(r) }; return ok
    }
    /// AutomationPage "Done" / SettingsView "Save". A DELIBERATE act (F1).
    @discardableResult func updateRule(_ r: ChargeRule) -> Bool {
        setAsideForDeliberateFirstRunTap("Save rule")
        var ok = false; mutate { ok = $0.updateRule(r) }; return ok
    }
    func removeRule(id: UUID) { mutate { $0.removeRule(id: id) } }
    /// Settings' first-run "Use suggested". A DELIBERATE tap — see `setAsideForDeliberateFirstRunTap`.
    func applyStarterPreset() {
        setAsideForDeliberateFirstRunTap("Use suggested")
        mutate {
            for r in ChargeScheduleConfig.starterPreset() { _ = $0.addRule(r) }
            $0.presetOffered = true
            $0.enabled = true
        }
    }
    /// Settings' first-run "Set up manually". A DELIBERATE tap — see `setAsideForDeliberateFirstRunTap`.
    func markPresetOffered() {
        setAsideForDeliberateFirstRunTap("Set up manually")
        mutate { $0.presetOffered = true }
    }

    /// Owner/controller decision (2026-10-16), widened by the final review (F1): no dead controls. Every
    /// schedule edit method is called ONLY from a view, on a user action — the toggle, Add, Save/Done,
    /// and the two first-run buttons (there is no background caller; recompute and the pacer never edit
    /// the config). Each of those is the user's explicit act of starting over, so it moves the unreadable
    /// bytes aside FIRST (kept, byte-identical, under `chargeSchedule.config.v1.unreadable.<epoch>` — the
    /// store logs the key and verifies the copy before removing the original), and then proceeds.
    /// `removeRule` is not routed here: an unreadable config presents no rules, so there is nothing to
    /// remove. If the set-aside does not take, `mutate` still refuses and the store still won't save.
    private func setAsideForDeliberateFirstRunTap(_ button: String) {
        guard configUnreadable else { return }
        NSLog("battery_app: \"%@\" tapped while the charge schedule config is unreadable — setting it aside "
              + "before saving the new one.", button)
        setAsideUnreadableConfig()
    }

    /// Redman sweep item 1: the ONE way out of an unreadable stored config, and it keeps the bytes —
    /// they are moved aside under a dated key (`chargeSchedule.config.v1.unreadable.<epoch>`), never
    /// deleted. After it the config is the honest empty and edits save again. Called by the two
    /// Settings first-run buttons on a deliberate tap (`setAsideForDeliberateFirstRunTap`); no other
    /// path calls it — `mutate` keeps refusing everything else while the config is unreadable.
    func setAsideUnreadableConfig() {
        guard configUnreadable else { return }
        store.setAsideUnreadableConfig()
        configUnreadable = (store.loadConfigDetailed() == .corrupt)   // only clear what was actually moved
    }

    private func mutate(_ change: (inout ChargeScheduleConfig) -> Void) {
        // Redman sweep item 1: REFUSE every edit while the stored config is unreadable. SWEEP H4 let the
        // edit proceed and save, on the reasoning that "a blob that will not decode holds no rules this
        // app can ever read back". That was wrong: the blob is the user's rules, and a build with a
        // tolerant decoder (or a person) CAN read an additive-schema blob back. Saving over it destroyed
        // them on one tap of the first-run offer, which `.empty` puts on screen. The edit is refused in
        // memory too, not only on disk: the in-memory config drives autonomous Sets every 30 s, so an
        // unsaved schedule would run this session and silently vanish at the next launch.
        guard !configUnreadable else {
            NSLog("battery_app: charge schedule edit REFUSED — the stored config will not decode and is "
                  + "kept as-is (setAsideUnreadableConfig() moves it aside).")
            return
        }
        var c = config
        change(&c)
        config = c
        store.saveConfig(c)
        syncPacer()             // B-arc B3: enabling/adding starts the pacer, disabling/emptying stops it
        setTransientNote(nil)   // audit A3/A4: a config edit drops any lingering scheduled-failure note
        recompute(.ruleEdit)
    }

    /// #30 §4.7 / §14-C11: READ-ONLY — whether `rule`'s most recent occurrence (today's or yesterday's
    /// HH:mm, whichever is at or before now) is in the fired-set. Drives the Automation tab's "fired ›"
    /// row caption and nothing else; it never mutates the set, never recomputes, never fires.
    func isFired(_ rule: ChargeRule) -> Bool {
        let cal = calendarProvider()
        guard let occ = ChargeSchedule.mostRecentOccurrence(of: rule, atOrBefore: clock.now(), calendar: cal)
        else { return false }
        return fired.contains(FiredOccurrence(ruleID: rule.id, dayKey: ChargeSchedule.dayKey(for: occ, calendar: cal)))
    }

    // MARK: - human primacy

    /// Resume-program (4g): apply the schedule's CURRENT dictate now (the thermostat resume). No-op
    /// when there's no operative occurrence. audit A3/A4: rather than issue its own Set (a second
    /// concurrent-Set / double-issue window), UN-HANDLE the operative occurrence and let the single
    /// `fire()` path re-assert it — with all the machinery and the `commandInFlight` guard.
    func resumeNow() {
        let cal = calendarProvider()
        guard let operative = ChargeSchedule.operativeOccurrence(now: clock.now(), calendar: cal, config: config)
        else { return }
        let occ = FiredOccurrence(ruleID: operative.rule.id,
                                  dayKey: ChargeSchedule.dayKey(for: operative.date, calendar: cal))
        fired.remove(occ); store.saveFired(fired)
        scheduleSetMisses[occ] = nil
        setTransientNote(nil)
        recompute(.resumeNow)
    }

    private func handleLimitChange(_ newLimit: ChargeLimitValue) {
        defer { lastSeenLimit = newLimit }
        // Only a genuine value→value change counts (not the baseline .unknown→known read).
        guard case .known = newLimit, case .known = lastSeenLimit, newLimit != lastSeenLimit else { return }
        // Our OWN scheduled Set is not a manual override; this guard is user/external/intent only
        // (Phase 5 #17: an App Intent set is an explicit instruction the schedule must not fight either).
        guard engine.lastCommandSource.isExplicitUserOrIntent else { return }
        guard config.enabled, !config.rules.isEmpty else { return }

        // Human primacy (4g): a user change ABANDONS any DEFERRED scheduled action and consumes that
        // occurrence — a queued trigger must never clobber a fresh manual change. The change then HOLDS
        // via the fired-set until the NEXT trigger reasserts; there is no separate skip.
        if let d = deferring {
            fired.insert(d.occurrence)
            scheduleSetMisses[d.occurrence] = nil
            deferring = nil
        }
        // audit A3/A4: ALSO consume the OPERATIVE occurrence so a manual change MID-RETRY stops the
        // retry and is not clobbered — mark it fired, clear its miss, and drop any lingering failure note.
        let cal = calendarProvider()
        if let operative = ChargeSchedule.operativeOccurrence(now: clock.now(), calendar: cal, config: config) {
            let occ = FiredOccurrence(ruleID: operative.rule.id,
                                      dayKey: ChargeSchedule.dayKey(for: operative.date, calendar: cal))
            fired.insert(occ)
            scheduleSetMisses[occ] = nil
        }
        clearFailureNote()   // audit obs 1: clear ONLY the sticky failure note — a valid setup/pause
                             // note must survive (handleLimitChange has no immediate recompute to restore it)
        store.saveFired(fired)
    }

    // MARK: - the recompute core

    func recompute(_ reason: RecomputeReason) {
        guard config.enabled else { setTransientNote(nil); return }
        guard isSetupReady() else { setTransientNote("Schedule paused — setup required"); return }   // sec 4
        // Pause is an explicit user intent — triggers suspend with a note (sec 3).
        //
        // SWEEP H2 amendment 2: EXCEPT when it was not an explicit user intent. `engine.isPaused` is
        // now also true for a pause the app INFERRED from a capture that will not decode, and the two
        // cases shared one sentence — so an inferred pause told the user they had paused charging.
        // They had not, and that sentence is what stops them from suspecting the app. The suspend is
        // identical (`.corrupt` still stops the scheduler); only the claim changes.
        if engine.isPaused {
            setTransientNote(engine.pauseRestorePointLost
                             ? ChargeStatusStrings.schedulePausedRestorePointLostNote
                             : "Schedule paused — charging is paused")
            return
        }
        pruneFired()

        let cal = calendarProvider()
        let now = clock.now()
        let action = ChargeSchedule.nextAction(now: now, calendar: cal, config: config,
                                               fired: fired,
                                               currentLimit: engine.limit.knownValue)
        switch action {
        case .none:
            deferring = nil
            if !noteIsSticky { note = nil }   // 4g: no skip to keep a note alive — but a sticky
                                              // scheduled-failure note survives a do-nothing tick.
        case .fire(let rule, let dayKey):
            fire(rule: rule, dayKey: dayKey, now: now)
        }
    }

    /// Set the visible note as a NON-sticky note (cleared by the next do-nothing tick / config edit /
    /// human change). Every assignment EXCEPT the scheduled-Set give-up note routes through here.
    private func setTransientNote(_ text: String?) {
        note = text
        noteIsSticky = false
    }

    /// Clear ONLY the sticky scheduled-failure note (audit obs 1). Unlike `setTransientNote(nil)`, this
    /// leaves a valid non-sticky note (setup-required / charging-paused / busy-skip) untouched — used by
    /// `handleLimitChange`, which (unlike resumeNow / mutate) does not recompute immediately afterward.
    private func clearFailureNote() {
        if noteIsSticky { note = nil; noteIsSticky = false }
    }

    private func fire(rule: ChargeRule, dayKey: String, now: Date) {
        let occurrence = FiredOccurrence(ruleID: rule.id, dayKey: dayKey)

        // In-flight deference: NEVER supersede a user action (sec 3). This is NOT a permanent skip —
        // the next tick simply falls through to fire once the app stops being busy (the deferral only
        // re-attempts); only the 5-min cap converts it to a skip-with-note.
        //
        // "BUSY" IS `commandInFlight` AND NOTHING ELSE (Grok N1, asked across three review rounds).
        // This condition used to read `commandInFlight || engine.confirm.isWindowArmed`. An armed
        // `BehaviorConfirm` window is OBSERVATION AFTER a successful Set, not a command in flight:
        // `.chargingToCap` may legitimately stand for `capMaxWindow_s` (2 h of sampled time) while
        // the pack climbs. Because `maxDeferral` is 300 s, the ceiling could never rescue the
        // colliding occurrence — the deferral consumed it first, and a daily rule that happened to
        // land inside a climb lost that day's fire ("the app was busy", for an app that was merely
        // watching). `commandInFlight`, by contrast, is one XPC round trip: deferring across it is
        // the real concurrent-Set guard and stays.
        //
        // ACCEPTED CONSEQUENCE, ruled by the reviewer: a scheduled Set may now fire while a climb is
        // being watched, and `BehaviorConfirm.commandIssued` supersedes that window (it publishes no
        // verdict). A 22:00 rule can therefore clobber a 21:30 manual Set still in `.chargingToCap`.
        // That is the schedule working. Do NOT add a manual-override concept here to compensate —
        // 4g deliberately deleted the skip, and "manual Set owns the evening" is a scheduler policy,
        // not a two-hour observation lock.
        if engine.commandInFlight {
            if let d = deferring, d.occurrence == occurrence {
                if now.timeIntervalSince(d.since) >= Self.maxDeferral {
                    fired.insert(occurrence); store.saveFired(fired)   // consumed
                    deferring = nil
                    // HONESTY SURFACE — READ BEFORE TRUSTING THIS STRING. It is set, but it is not
                    // seen. `SettingsView.scheduleSection` renders `schedule.note` only in the ELSE
                    // branch of `if let target = schedule.resumeTarget()`, and reaching this line
                    // GUARANTEES `resumeTarget()` is non-nil: `ChargeSchedule.nextAction` only
                    // returns `.fire` when `currentLimit != rule.limit`, which is exactly
                    // `resumeTarget()`'s divergence test. So the Resume button always wins the slot,
                    // and the next `.none` tick (~30 s) clears this non-sticky note unseen. Removing
                    // the armed-window half of the guard above shrinks the path further — it now
                    // needs a command lock held across ten consecutive ticks. Fixing the reachability
                    // is a `SettingsView` change and is NOT owned here; recorded so the next reader
                    // does not mistake this copy for something a user has ever read.
                    setTransientNote("Scheduled change skipped — the app was busy")
                }
                // else: keep deferring; the next tick retries.
            } else {
                deferring = (occurrence, now)   // start the ≤5-min deferral clock
            }
            return
        }

        // Fire. Mark fired FIRST (the double-fire guard), then issue identically to a user Set — but
        // AWAIT the verified outcome and route it to the shared completion (audit A3/A4: bounded
        // retry-then-give-up, replacing the fire-and-forget that silently skipped the day on failure).
        deferring = nil
        fired.insert(occurrence)
        store.saveFired(fired)
        let target = rule.limit
        Task { @MainActor in
            let outcome = await engine.userSetLimit(target, source: .schedule)
            finishScheduledSet(occurrence: occurrence, target: target, outcome: outcome)
        }
    }

    /// audit A3/A4: route a scheduled Set's verified `CommandOutcome`. A degraded write counts as
    /// success; an adopted external value is not fought; a retriable failure un-fires for a bounded
    /// re-fire and then gives up for the day with a sticky note — but only while the scheduled Set
    /// still owns the command lock.
    private func finishScheduledSet(occurrence: FiredOccurrence, target: Int, outcome: CommandOutcome) {
        switch outcome {
        case .applied, .appliedUnconfirmed:
            // SUCCESS. `appliedUnconfirmed` is the NORMAL degraded result (write landed, read-back
            // unavailable) and MUST count as success — else a degraded schedule would retry forever and
            // give up every day. Occurrence stays fired.
            scheduleSetMisses[occurrence] = nil
            setTransientNote(nil)

        case .mismatch:
            // SUPERSEDED: the engine adopted an external value (adopt-don't-fight). Leave fired, no
            // retry, no failure note — re-firing would clobber the external change.
            scheduleSetMisses[occurrence] = nil

        case .issueFailed, .busy:
            // RETRIABLE — but only while the scheduled Set is still the operative command. If a user /
            // intent / top-up command took the lock (e.g. won a lock race so this came back `.busy`),
            // adopt it: leave fired, no retry, no note. Do not fight the intervening command.
            guard engine.lastCommandSource == .schedule else {
                scheduleSetMisses[occurrence] = nil
                return
            }
            let n = (scheduleSetMisses[occurrence] ?? 0) + 1
            scheduleSetMisses[occurrence] = n
            if n < Self.maxScheduleSetAttempts {
                fired.remove(occurrence); store.saveFired(fired)   // un-fire so the next tick re-fires
            } else {
                scheduleSetMisses[occurrence] = nil                // give up for the day; stays fired
                setScheduleFailureNote(target: target)
            }

        case .invalidTarget:
            // Defensive permanent give-up (a sanctioned-step rule should never produce this).
            scheduleSetMisses[occurrence] = nil
            setScheduleFailureNote(target: target)
        }
    }

    /// The ONE sticky note: a scheduled change failed. Names the target percent and the attempt time
    /// in the runner's local calendar/timezone, so a note that lingers reads as a PAST event rather
    /// than an ongoing claim. Owner-tunable copy.
    private func setScheduleFailureNote(target: Int) {
        let cal = calendarProvider()
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        note = "Scheduled change to \(target)% failed at \(f.string(from: clock.now()))"
        noteIsSticky = true
    }

    /// Drop fired records older than ~2 days (yyyy-MM-dd sorts chronologically).
    private func pruneFired() {
        let cal = calendarProvider()
        guard let threshold = cal.date(byAdding: .day, value: -2, to: clock.now()) else { return }
        let cutoff = ChargeSchedule.dayKey(for: threshold, calendar: cal)
        let kept = fired.filter { $0.dayKey >= cutoff }
        if kept.count != fired.count { fired = kept; store.saveFired(fired) }
        // audit A3/A4: the miss map keys un-fired/superseded occurrences the fired-prune above does NOT
        // touch, so it would otherwise leak — drop stale miss entries on the same horizon.
        scheduleSetMisses = scheduleSetMisses.filter { $0.key.dayKey >= cutoff }
    }

    // MARK: - UI helpers

    /// "Next: HH:mm → N%" — nil when disabled / no rules.
    func upcomingLine() -> String? {
        guard let next = ChargeSchedule.upcomingLine(now: clock.now(), calendar: calendarProvider(), config: config)
        else { return nil }
        return "Next: \(next.rule.timeLabel) → \(next.rule.limit)%"
    }

    /// 4g: the schedule's current dictate when the live limit DIVERGES from it (off-schedule) — drives
    /// the Resume affordance + its value label. nil when on-schedule / disabled / no operative occurrence.
    func resumeTarget() -> Int? {
        guard config.enabled,
              let operative = ChargeSchedule.operativeOccurrence(now: clock.now(),
                                                                 calendar: calendarProvider(), config: config),
              engine.limit.knownValue != operative.rule.limit
        else { return nil }
        return operative.rule.limit
    }
}

extension ChargeLimitValue {
    /// The Int value if known, else nil (the schedule's currentLimit comparison).
    var knownValue: Int? { if case .known(let v) = self { return v }; return nil }
}
