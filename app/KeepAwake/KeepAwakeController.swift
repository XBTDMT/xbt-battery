import Foundation
import Combine

/// #EI-1 keep-awake (SPEC 02-SPEC-ei1-keep-awake.md): prevents idle sleep via an in-process
/// IOPMAssertion while on; optionally keeps the display on too. This is the PURE state machine plus
/// the release spine (off / timer-expiry / app-quit / unplug-for-AC), driven through the
/// `SleepAssertion` seam so it is fully tested without a real assertion. No root, no helper, no XPC.
@MainActor
final class KeepAwakeController: ObservableObject {

    /// Which sleep the session prevents. System-awake is the default; display-on is the opt-in (the
    /// spec: the display assertion ADDS to the system one). Maps to the SleepAssertionKind set.
    enum Scope: Equatable, Sendable, Codable {
        case system            // PreventUserIdleSystemSleep only (the display may still sleep)
        case systemAndDisplay  // + PreventUserIdleDisplaySleep (the display stays on too)

        var kinds: [SleepAssertionKind] {
            switch self {
            case .system:           return [.systemIdle]
            case .systemAndDisplay: return [.systemIdle, .displayIdle]
            }
        }
    }

    /// How long the session lasts.
    enum Duration: Equatable, Sendable, Codable {
        case indefinite           // until toggled off / app quit
        case timed(TimeInterval)  // a per-session Timer releases at expiry
        case whileOnAC            // releases on unplug
    }

    /// #30 §4.2 / §14-C7: the last-used preset — what the Now tab's mini switch re-arms and labels
    /// ("Keep awake · 1 h"). Persisted as `keepAwake.lastPreset.v1 {duration, scope}` on EVERY
    /// `enable()` from any surface. Default indefinite / system.
    struct Preset: Equatable, Sendable, Codable {
        var duration: Duration
        var scope: Scope
        static let `default` = Preset(duration: .indefinite, scope: .system)
    }

    /// The active session (nil = off).
    struct Session: Equatable {
        var scope: Scope
        var duration: Duration
        /// Monotonic deadline for a `.timed` session (drives the remaining-time display); nil otherwise.
        var deadline: TimeInterval?
        /// How many times the machine SLEPT while this session was held. The assertions we hold are
        /// IDLE-sleep only — IOPMLib.h:286: the system "may still sleep for lid close, Apple menu,
        /// low battery, or other sleep reasons". A session that survived a sleep did NOT do what it
        /// promised, so it must not go on presenting as an unbroken "On" across the very event that
        /// falsified the claim. Recorded by `systemWillSleep()`; reset by the next `enable()`.
        var sleepInterruptions: Int = 0
        /// The honest post-wake state: still on, but its claim was broken at least once.
        var wasInterrupted: Bool { sleepInterruptions > 0 }
    }

    /// Why the session is not running (or no longer is) — the honest counterpart to `isOn == false`.
    /// Every automatic teardown is otherwise SILENT (audit): timed expiry, the `.whileOnAC` unplug and
    /// the low-battery floor all tear down with no user-visible signal, and an activation that created
    /// nothing used to light the badge anyway. `HUDTrigger.keepAwake(Bool)` is the intended disclosure
    /// home for the automatic cases (wiring reported, not built here — the HUD files are out of scope).
    enum EndReason: Equatable, Sendable {
        case activationFailed   // enable/setScope created NOTHING — the request never took effect
        case expired            // a `.timed` session reached its deadline
        case unplugged          // a `.whileOnAC` session lost AC
        case lowBattery         // the safety floor fired
        case user               // an explicit toggle-off (self-evident — needs no disclosure)
        case terminating        // app quit
    }

    /// The legible assertion name — shows in `pmset -g assertions` and the Energy tab (cost legibility).
    static let assertionName = "Battery: keep awake"

    /// v1 one-tap presets offered in the quick-actions menu (owner-tunable wording/values, flagged).
    /// Scope defaults to `.system`; the display-on upgrade lives on the popover row. `nonisolated` so
    /// the pure (nonisolated) menu-builder and the tests can read this immutable, Sendable constant.
    nonisolated static let menuDurations: [(title: String, duration: Duration)] = [
        ("Indefinite", .indefinite),
        ("30 minutes", .timed(1800)),
        ("1 hour", .timed(3600)),
        ("2 hours", .timed(7200)),
        ("While on power", .whileOnAC),
    ]

    /// The safety floor (percent). A keep-awake session auto-releases below this on battery so it
    /// cannot drain the machine to empty. "Under 5%" means percent < 5 (fires at 4%, stays on at 5%).
    /// `nonisolated` for the same reason as `menuDurations`: an immutable Sendable constant that the
    /// pure caption builders (and the tests) read from a nonisolated context.
    nonisolated static let lowBatteryFloorPercent = 5

    @Published private(set) var session: Session?
    /// ON means a session exists AND at least one assertion is actually held for it — the two are kept
    /// in lockstep, so `isOn` can never claim a capability the machine isn't under (audit B7).
    var isOn: Bool { session != nil }
    /// The kinds we ACTUALLY hold right now (not the ones that were requested). Empty when off. A
    /// partial create failure shows up here: a `.systemAndDisplay` request that only got the system
    /// kind holds `[.systemIdle]`, so a surface can say the display is not being held awake.
    @Published private(set) var heldKinds: [SleepAssertionKind] = []
    /// Why the last session ended or failed to start. Cleared when a session starts successfully.
    @Published private(set) var lastEnd: EndReason?
    /// True while a held session has been broken by a real sleep (see `Session.sleepInterruptions`).
    var isInterrupted: Bool { session?.wasInterrupted ?? false }

    /// The machine's real AC/battery idle-sleep timers, once something has asked for them. nil = never
    /// read (the app spawns nothing at launch). Read by the popover's keep-awake section to say what
    /// the toggle achieves ON THE CURRENT POWER SOURCE — see `liveEffectNote`.
    @Published private(set) var sleepTimers: SleepTimerSettings?

    /// #30 §14-C7: the last preset any surface enabled with (persisted; survives relaunch). Read by
    /// the Now tab's mini switch, written by `enable(scope:duration:)`.
    @Published private(set) var lastPreset: KeepAwakePreset

    /// Redman sweep item 4: the stored preset is present but will not decode, so `lastPreset` started
    /// as the documented `.default` rather than the user's. Nothing ever saves over the unreadable bytes:
    /// the Now switch (`enableLastPreset`) runs that default for this session only, and a deliberate pick
    /// (`enable(scope:duration:)`) first moves the bytes aside (`setAsideUnreadablePreset`, kept under a
    /// dated key), which ends this state, then saves (final review F2).
    /// NOT `@Published`: no screen shows it yet (an owner visual decision); NSLog is the surface today.
    private(set) var lastPresetUnreadable: Bool

    private let assertion: SleepAssertion
    private let presetStore: KeepAwakePresetStore
    private let scheduler: OneShotScheduling
    private let clock: MonotonicClock
    private let sleepTimerReader: SleepTimerReading
    /// Monotonic stamp of the last `pmset -g custom` spawn (nil = never). The cache key.
    private var sleepTimersReadAt: TimeInterval?

    /// The live assertion ids we hold — released on EVERY exit path so nothing dangles. Empty when off.
    private var heldIDs: [UInt32] = []
    /// Bumped on every state transition so a stale `.timed` expiry callback (which still fires even
    /// after the session changed) can be recognised and ignored — it must never tear down a later session.
    private var generation = 0

    /// `sleepTimerReader` is defaulted so the app's existing wiring is unchanged — it is a READ-ONLY,
    /// unprivileged seam and nothing is read until `refreshSleepTimers()` is called.
    init(assertion: SleepAssertion, scheduler: OneShotScheduling, clock: MonotonicClock,
         sleepTimerReader: SleepTimerReading = LiveSleepTimerReader(),
         presetStore: KeepAwakePresetStore = KeepAwakePresetStore()) {
        self.assertion = assertion
        self.scheduler = scheduler
        self.clock = clock
        self.sleepTimerReader = sleepTimerReader
        self.presetStore = presetStore
        let loaded = presetStore.loadDetailed()
        self.lastPreset = loaded.presetOrDefault
        self.lastPresetUnreadable = (loaded == .unreadable)
        if lastPresetUnreadable {
            NSLog("battery_app: the saved keep-awake preset (%@) will not decode — using the default "
                  + "(indefinite, system) this session; the saved bytes are not overwritten.", KeepAwakePresetStore.key)
        }
    }

    /// Redman sweep item 4: the one way out of an unreadable stored preset, and it keeps the bytes —
    /// moved aside under a dated key, never deleted. No screen calls it yet (owner visual decision).
    func setAsideUnreadablePreset() {
        guard lastPresetUnreadable else { return }
        presetStore.setAsideUnreadable()
        lastPresetUnreadable = (presetStore.loadDetailed() == .unreadable)
    }

    /// How long a sleep-timer reading stays fresh. These are System Settings values a user changes
    /// once in a blue moon, so the read is CACHED for five minutes.
    ///
    /// COST DISCIPLINE (audit A11 / A12): `readSleepTimers()` spawns `pmset`, and "a subprocess per
    /// popover open" is a finding this audit has already fixed twice. This must not be the third, so:
    /// the read is user-gated (the keep-awake disclosure opening, or the toggle being flipped), never
    /// on a timer, never on the popover-open path, and never from `powerSourceChanged` — which rides
    /// every telemetry snapshot.
    nonisolated static let sleepTimerCacheSeconds: TimeInterval = 300

    /// Read the machine's real idle-sleep timers, at most once per `sleepTimerCacheSeconds`.
    ///
    /// The child blocks, so the spawn runs on a detached utility task and only the assignment comes
    /// back to the MainActor. The stamp is taken BEFORE the suspension point, so two overlapping
    /// callers (the disclosure's `.task` and the toggle) cannot both spawn. A failed read still stamps:
    /// a machine where `pmset` cannot run must not be re-probed on every interaction.
    func refreshSleepTimers() async {
        let now = clock.now()
        if let last = sleepTimersReadAt, now - last < Self.sleepTimerCacheSeconds { return }
        sleepTimersReadAt = now
        let reader = sleepTimerReader
        sleepTimers = await Task.detached(priority: .utility) { reader.readSleepTimers() }.value
    }

    /// Enable (or re-arm) keep-awake. Idempotent — any prior session is released FIRST so the
    /// assertions never stack or leak. Creates exactly the scope's kind(s), each with the legible name.
    ///
    /// This is the DELIBERATE pick (the Automation page presets, the status-item menu): the user is
    /// choosing a preset, which is exactly what `keepAwake.lastPreset.v1` records. Final review F2: when
    /// the stored preset is unreadable, its bytes are moved aside FIRST (kept, byte-identical, dated
    /// key), then the pick is saved. The Now switch does NOT come through here — see `enableLastPreset`.
    func enable(scope: Scope, duration: Duration) {
        if lastPresetUnreadable {
            NSLog("battery_app: keep-awake preset picked while the saved one is unreadable — setting it aside "
                  + "before saving the new one.")
            setAsideUnreadablePreset()
        }
        enable(scope: scope, duration: duration, persist: true)
    }

    /// The Now tab's mini switch: re-arm the LAST preset. Final review F2: this one stays SESSION-ONLY when
    /// the stored preset is unreadable — `lastPreset` is then the documented `.default` (indefinite,
    /// system; what the switch's label already names), and re-arming it is not the user choosing a preset,
    /// so it neither sets the unreadable bytes aside nor saves anything. A readable preset re-arms and
    /// saves as before.
    func enableLastPreset() {
        let p = lastPreset
        enable(scope: p.scope, duration: p.duration, persist: !lastPresetUnreadable)
    }

    private func enable(scope: Scope, duration: Duration, persist: Bool) {
        // #30 §14-C7: the preset is what was ASKED for, recorded before the outcome — a failed
        // activation still tells the next surface what the user last wanted.
        let preset = KeepAwakePreset(duration: duration, scope: scope)
        // Redman sweep item 4: never save over an unreadable stored preset (the store refuses too). The
        // session still runs (a dead switch would be its own silent failure) and the preset is
        // remembered in memory for this session.
        if persist && !lastPresetUnreadable { presetStore.save(preset) }
        lastPreset = preset

        releaseHeld()                       // no stacking: drop any prior session's assertions first
        generation += 1                     // invalidate any prior pending expiry callback
        let gen = generation

        createHeld(for: scope)

        // HONESTY (audit B7): if NOT ONE assertion was created, nothing is preventing sleep. Setting a
        // session here would make `isOn` true — lighting the menu-bar espresso badge and checking the
        // menu preset — while the Mac idle-sleeps normally. That is an active lie, not a silent no-op,
        // so we stay OFF and record WHY, which is the signal a failure surface can render.
        // Partial success DOES still count as on: either idle assertion alone prevents idle sleep, so
        // the headline claim holds; `heldKinds` carries exactly what is held for a precise surface.
        guard !heldIDs.isEmpty else {
            session = nil
            lastEnd = .activationFailed
            return
        }

        var deadline: TimeInterval?
        if case .timed(let seconds) = duration {
            deadline = clock.now() + seconds
            scheduler.after(seconds) { [weak self] in self?.expire(generation: gen) }
        }
        lastEnd = nil
        session = Session(scope: scope, duration: duration, deadline: deadline)
    }

    /// Change the ACTIVE session's scope (e.g., add/remove display-on) WITHOUT disturbing its duration,
    /// deadline, or the pending expiry timer — a scope change is orthogonal to timing. Swaps the held
    /// assertions (release-then-create, no stacking) and keeps the generation, so a `.timed` session's
    /// original Timer still fires at the original deadline. No-op when off. (The popover's "Keep the
    /// display on too" toggle uses this so flipping it mid-session never resets a running timer.)
    func setScope(_ scope: Scope) {
        guard let current = session else { return }
        releaseHeld()
        createHeld(for: scope)

        // The same honesty rule as `enable`: the swap released the old set and created nothing, so
        // there is nothing left to stand behind — end the session rather than present an empty one.
        // The generation bump neuters the pending expiry callback so it can never hit a later session.
        guard !heldIDs.isEmpty else {
            generation += 1
            session = nil
            lastEnd = .activationFailed
            return
        }
        // A scope swap is not a fresh claim: an interruption already recorded against this session
        // carries over (only a new `enable()` starts a clean one).
        session = Session(scope: scope, duration: current.duration, deadline: current.deadline,
                          sleepInterruptions: current.sleepInterruptions)
    }

    /// Toggle off — release immediately (idempotent; a no-op when already off).
    func disable() { end(.user) }

    /// The single teardown path: release the held assertions, drop the session, and RECORD WHY. Every
    /// caller (off / expiry / unplug / floor / quit) goes through here, so the release spine stays one
    /// generation-guarded piece of code and no exit is invisible to a disclosure surface.
    private func end(_ reason: EndReason) {
        generation += 1                     // invalidate any pending timed-expiry callback
        releaseHeld()
        if session != nil { lastEnd = reason }   // nothing ended if we were already off
        session = nil
    }

    /// Called by the per-session expiry Timer. Releases only if this is STILL the session it armed —
    /// a stale timer from a finished/replaced session is ignored.
    private func expire(generation: Int) {
        guard generation == self.generation, session != nil else { return }
        end(.expired)
    }

    /// Power-source change: a `.whileOnAC` session releases on unplug; other sessions are unaffected.
    func powerSourceChanged(onAC: Bool) {
        guard !onAC, session?.duration == .whileOnAC else { return }
        end(.unplugged)
    }

    /// Safety floor: an active session auto-releases when the battery falls below
    /// lowBatteryFloorPercent while on battery. A no-op on AC (nothing to guard), when off, at or
    /// above the floor, or on a nil reading (a missing reading must never silently drop the session).
    /// Reuses the shared `end()` teardown, so it is the same generation-guarded release as a manual
    /// off — and it names itself (`.lowBattery`) instead of ending the session anonymously.
    /// (Audit note: macOS 27 has already nulled other AppleSmartBattery fields once, so a nil percent
    /// is not hypothetical — failing OPEN on nil is deliberate and stays.)
    func batteryLevelChanged(percent: Int?, onAC: Bool) {
        guard !onAC, let p = percent, p < Self.lowBatteryFloorPercent, session != nil else { return }
        end(.lowBattery)
    }

    /// MANDATORY on app termination — never leave a dangling assertion (SPEC #EI-1 safety spine).
    /// The assertion also dies with the process as a backstop, but we release explicitly here.
    func releaseForTermination() {
        end(.terminating)
    }

    /// The machine is going to sleep WHILE a session is held — call this from the app's existing
    /// `NSWorkspace.willSleepNotification` observer. One call, no wake-side bookkeeping needed.
    ///
    /// Our assertions are IDLE-sleep only: IOPMLib.h:286 says the system "may still sleep for lid close,
    /// Apple menu, low battery, or other sleep reasons". So the Mac can sleep straight through a live
    /// session, and nothing reconciled that — on wake the espresso badge was still steaming and the
    /// popover still read "On — your Mac won't idle-sleep" across the very event that falsified the
    /// claim, while the user's long job was dead. We do NOT tear the session down: the assertions are
    /// still held and still effective from here on, and silently dropping the user's session would be
    /// its own surprise. We mark it INTERRUPTED, which is a distinct, honest state the surfaces can
    /// report. A no-op when off, so an ordinary sleep with keep-awake off records nothing.
    func systemWillSleep() {
        guard var current = session else { return }
        current.sleepInterruptions += 1
        session = current
    }

    /// Remaining whole seconds for a `.timed` session (from the injected clock; nil otherwise). Clamped
    /// at 0. Read by the view on render — no polling timer drives it (the existing republish cadence does).
    func remainingSeconds() -> Int? {
        guard let deadline = session?.deadline else { return nil }
        return max(0, Int((deadline - clock.now()).rounded()))
    }

    /// Friendly RELATIVE remaining label for the popover status line ("2 hr", "1 hr 5 min", "30 min").
    /// Pure + nonisolated so it's unit-testable; the absolute wall-clock end-time is composed view-side
    /// (locale-aware). Floors at "1 min" so a live session never reads "0 min" before the final second.
    nonisolated static func remainingLabel(_ seconds: Int) -> String {
        let mins = max(0, seconds) / 60
        let hrs = mins / 60
        let remMins = mins % 60
        if hrs > 0 && remMins > 0 { return "\(hrs) hr \(remMins) min" }
        if hrs > 0 { return "\(hrs) hr" }
        return "\(max(1, mins)) min"
    }

    /// #29 orphan-backlog: the honest clause for a PARTIAL hold. `heldKinds` is what we actually got,
    /// so a `.systemAndDisplay` request that only obtained `.systemIdle` must not let the caption imply
    /// the display is being held. Returns nil when the hold matches the request (nothing to disclose).
    /// Pure and `nonisolated` so the caption logic is testable without a view or a live session.
    nonisolated static func partialHoldNote(requested: Scope, held: [SleepAssertionKind]) -> String? {
        let missing = requested.kinds.filter { !held.contains($0) }
        guard !missing.isEmpty else { return nil }
        if missing.contains(.displayIdle) && !missing.contains(.systemIdle) {
            return "the display is not being held on"
        }
        return "not everything you asked for is being held"
    }

    /// #29 orphan-backlog: why the LAST session ended, for the off-state caption. `.user` and
    /// `.terminating` return nil — you turned it off, or you quit the app; saying so is noise. The
    /// remaining four are things that happened TO the session and the owner would otherwise never learn.
    nonisolated static func lastEndNote(_ reason: EndReason?) -> String? {
        switch reason {
        case .none, .user, .terminating:
            return nil
        case .activationFailed:
            return "Last time, keep-awake could not start — macOS refused the request."
        case .expired:
            return "Last session ended when its timer ran out."
        case .unplugged:
            return "Last session ended when you unplugged."
        case .lowBattery:
            return "Last session ended at the \(Self.lowBatteryFloorPercent)% battery floor."
        }
    }

    /// What this toggle actually covers — the caption shown AT THE POINT OF USE (the popover's keep-awake
    /// row), not buried in settings. Leads with the guarantee, because the guarantee is real and useful:
    /// the two `PreventUserIdle*` assertions genuinely hold the Mac through user-idle and through a
    /// locked screen (locking never stopped background work — that was never the gap).
    ///
    /// The second sentence is the honesty fix. MEASURED, audit 2026-09 §2.D / §2.D.1: our assertions are
    /// IDLE-sleep only (IOPMLib.h:286 — the system "may still sleep for lid close"); `PreventSystemSleep`
    /// is granted to the process but never enters the system aggregate on battery; and the documented
    /// escape hatch that would make an assertion count on battery, `AppliesToLimitedPower`, is refused
    /// with `kIOReturnBadArgument` on macOS 27 both in `CreateWithProperties` and via
    /// `IOPMAssertionSetProperty`. The two mechanisms that remain are rejected (`pmset disablesleep` is a
    /// global kill switch over the kernel's whole software-sleep path, thermal and low-battery emergency
    /// sleep included — knowledge/05-SAFETY-pmset-disablesleep.md; IOKit selector 12 is raced by powerd
    /// on Apple Silicon). So closing the lid ends the work, permanently and by design, and an owner who
    /// ticks this and shuts the lid on a download loses it with no idea why. The app knows. It says so.
    nonisolated static let coverageNote =
        "Keeps running with the lid open, even when the screen locks. Closing the lid sleeps your Mac "
        + "anyway: macOS won't let an app hold it awake with the lid shut, so a download or build "
        + "stops there."

    // MARK: - what this toggle achieves ON THIS POWER SOURCE, right now (owner finding, 2026-09-08)

    /// `coverageNote` above is source-blind, and that is the defect the owner found. Our two assertions
    /// prevent IDLE sleep and nothing else — and whether idle sleep was ever going to happen is a
    /// **setting**, not a constant. On this machine `pmset -g custom` reports AC `sleep 0`: plugged in,
    /// the Mac never idle-sleeps, so `PreventUserIdleSystemSleep` prevents an event that was never
    /// coming. Turning the toggle on while on power did LITERALLY NOTHING and the app said otherwise.
    ///
    /// True when the requested scope prevents nothing that was going to happen. nil / unreadable timers
    /// are NEVER called inert — we do not accuse the feature on a reading we do not have.
    nonisolated static func isInert(scope: Scope, timers: SleepTimers?) -> Bool {
        // `systemMinutes != nil` is load-bearing, not belt-and-braces: `effectiveSystemSleepMinutes` is
        // also nil for a FAILED read, and "we could not read the setting" must never be presented as
        // "your Mac never idle-sleeps, so this does nothing".
        guard let timers, timers.systemMinutes != nil,
              timers.effectiveSystemSleepMinutes == nil else { return false }
        switch scope {
        case .system:
            return true                              // the display is not held; nothing else was coming
        case .systemAndDisplay:
            return timers.displayMinutes == 0        // inert only if the display never switches off either
        }
    }

    /// What the toggle DOES, in this machine's real numbers, on the power source it is plugged into.
    /// nil when the timers have not been read (say nothing rather than guess).
    ///
    /// The finding did NOT survive contact with `displaysleep`, and this is where that shows. AC
    /// `sleep 0` makes the system half inert, but AC `displaysleep` is a **separate, non-zero timer**
    /// (20 min here) — so the "Keep the display on too" half still does real work on power. The honest
    /// statement is therefore much narrower than "does nothing on power", and an inert system-only
    /// session gets pointed straight at the one-tap thing that isn't inert.
    ///
    /// Named `…Clause`, not `…Note`: it is a fragment of `liveEffectNote`, which is what renders.
    nonisolated static func sleepTimerClause(scope: Scope, onAC: Bool, timers: SleepTimers?) -> String? {
        guard let timers, timers.systemMinutes != nil else { return nil }
        let here = onAC ? "Right now, on power," : "Right now, on battery,"
        let display = timers.displayMinutes
        let holdsDisplay = (scope == .systemAndDisplay)

        guard let sleepsAfter = timers.effectiveSystemSleepMinutes else {
            // The system half is inert on this source. Say so, then say what (if anything) still works.
            if let d = display, d > 0 {
                return holdsDisplay
                    ? "\(here) your Mac never idle-sleeps, so that half of this changes nothing — what it "
                      + "does do is keep the display on, which would otherwise switch off after \(minutesLabel(d))."
                    : "\(here) your Mac never idle-sleeps, so this isn't changing anything. Tick “Keep the "
                      + "display on too” and it will — the display still switches off after \(minutesLabel(d))."
            }
            return "\(here) your Mac never idle-sleeps and the display never switches off on its own, "
                 + "so there is nothing here for this to prevent."
        }

        if holdsDisplay, let d = display, d > 0 {
            return "\(here) your Mac idle-sleeps after \(minutesLabel(sleepsAfter)) and the display "
                 + "switches off after \(minutesLabel(d)) — this stops both."
        }
        var line = "\(here) your Mac idle-sleeps after \(minutesLabel(sleepsAfter)) — this stops that."
        if let d = display, d > 0 {
            line += " The display still switches off after \(minutesLabel(d))."
        }
        return line
    }

    /// What it COSTS. MEASURED on this machine (knowledge/09-MEASURE-keepawake-cost.md): asleep
    /// 0.42 %/h over 44.9 h; awake-and-idle 5.8–8.7 %/h over 27 h, agreed run-by-run to within 7% by
    /// two independent estimators. Marginal cost ≈ 6.6 %/h — a 15–21× multiplier over sleeping.
    ///
    /// Stated as a **floor**, because that is what the evidence supports: the band is tight but the
    /// upper end is open (an actually-working Mac is several times more). The old copy said only
    /// "(an energy cost)", which cannot tell 2% overnight from 50% and is therefore actively
    /// misleading; a LIVE estimate was rejected because macOS 27 exposes no system-draw telemetry on
    /// AC at all, and on battery the instantaneous figure jitters 19–105 %/h.
    ///
    /// NO NUMBER IS EVER ATTACHED TO THE DISPLAY SCOPE. The measurement could not price it — this Mac
    /// has been awake with its screen off for four minutes in fourteen days — so the only defensible
    /// statement is that the dominant cost is not sleeping. On AC the cost is contingent, not current:
    /// mains power costs no battery, but the session survives an unplug, which is the actual trap.
    nonisolated static func energyCostClause(onAC: Bool) -> String? {
        onAC
            ? "If you unplug, staying awake costs at least ~6% of the battery an hour — about half of it "
              + "overnight, against ~3% if your Mac had slept."
            : "Staying awake costs at least ~6% of the battery an hour — about half of it overnight, "
              + "against ~3% if your Mac had slept. A download or build costs several times more."
    }

    /// The composed paragraph the popover renders: what it does here + what it costs. The two are
    /// independent facts, so a failed timer read still leaves the cost disclosure standing.
    nonisolated static func liveEffectNote(scope: Scope, onAC: Bool, timers: SleepTimers?) -> String? {
        let parts = [sleepTimerClause(scope: scope, onAC: onAC, timers: timers),
                     energyCostClause(onAC: onAC)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "10 min" / "1 hr" / "1 hr 30 min" for a pmset minute count. Reuses `remainingLabel`, the one
    /// duration formatter this feature already has (it takes seconds and floors at "1 min", which is
    /// exactly right here — pmset never reports a fractional minute).
    nonisolated static func minutesLabel(_ minutes: Int) -> String {
        remainingLabel(max(0, minutes) * 60)
    }

    /// The reader for `Session.sleepInterruptions` / `wasInterrupted` / `isInterrupted`. Those recorded
    /// "the machine slept anyway, so the claim was broken" from the day they were written and NOTHING
    /// rendered them — the same silent-failure class as `lastFailure`, `heldKinds` and `lastEnd` before
    /// them. Without this the espresso badge and "On — your Mac won't idle-sleep" survive the very event
    /// that falsified them: the owner shuts the lid, the job dies, the Mac wakes, and the app is still
    /// cheerfully claiming an unbroken hold. nil below 1 — an unbroken session says nothing (not a nag).
    nonisolated static func interruptionNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let times = count == 1 ? "once" : "\(count) times"
        return "Your Mac slept \(times) while this was on — a closed lid or a Sleep command sleeps it "
            + "regardless. Anything that was running stopped there."
    }

    /// Create the scope's kinds, recording BOTH the ids we hold and which kinds they were. `compactMap`
    /// keeps the spine intact: a kind whose `create()` returns nil is simply absent, so we never try to
    /// release an id we don't hold — and `heldKinds` never claims a kind we failed to get.
    private func createHeld(for scope: Scope) {
        let created: [(kind: SleepAssertionKind, id: UInt32)] = scope.kinds.compactMap { kind in
            assertion.create(kind, name: Self.assertionName).map { (kind: kind, id: $0) }
        }
        heldIDs = created.map(\.id)
        heldKinds = created.map(\.kind)
    }

    private func releaseHeld() {
        for id in heldIDs { assertion.release(id) }
        heldIDs = []
        heldKinds = []
    }
}

/// #30 §14-C7 spelling used across the app: the controller's nested `Preset`.
typealias KeepAwakePreset = KeepAwakeController.Preset

/// Redman sweep item 4 — the schema-tolerant decoder (the SWEEP H2 pattern, `PauseCapture`). Both
/// fields are required: `Preset` became `Codable` in `56942f8` with exactly these two and is unchanged
/// since, and the synthesized `encode` always wrote both. EVERY FIELD ADDED LATER must use
/// `decodeIfPresent` with a default, or one new field makes every stored preset unreadable. Unknown keys
/// are ignored. (`Duration` / `Scope` keep their synthesized enum coding; a case added later is a
/// DOWNGRADE problem only — an older build reading a newer case — and reads as `.unreadable`, which is
/// now safe.)
extension KeepAwakeController.Preset {
    enum CodingKeys: String, CodingKey { case duration, scope }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version.
        self.duration = try c.decode(KeepAwakeController.Duration.self, forKey: .duration)
        self.scope = try c.decode(KeepAwakeController.Scope.self, forKey: .scope)
        // TOLERANT — EVERY FIELD ADDED LATER must be decoded with `decodeIfPresent` and a default.
    }
}

/// Redman sweep item 4: how the stored preset READ. `load()` used to collapse "nothing saved" and
/// "saved bytes that will not decode" into the same `.default`.
enum KeepAwakePresetLoad: Equatable, Sendable {
    case none
    case preset(KeepAwakePreset)
    case unreadable

    /// The preset to USE: the documented default when nothing readable is stored.
    var presetOrDefault: KeepAwakePreset {
        if case .preset(let p) = self { return p }
        return .default
    }
}

/// UserDefaults-backed store for the last keep-awake preset (`keepAwake.lastPreset.v1`). Injected
/// `UserDefaults`. `load()` still never crashes and yields the default for a missing or unreadable
/// blob; `loadDetailed()` says which, and `save` will not write over unreadable bytes.
struct KeepAwakePresetStore {
    static let key = "keepAwake.lastPreset.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadDetailed() -> KeepAwakePresetLoad {
        guard let stored = defaults.object(forKey: Self.key) else { return .none }
        guard let data = stored as? Data,
              let preset = try? JSONDecoder().decode(KeepAwakePreset.self, from: data) else { return .unreadable }
        return .preset(preset)
    }

    func load() -> KeepAwakePreset { loadDetailed().presetOrDefault }

    /// Defence in depth: never replace a stored value that is present but will not decode.
    func save(_ preset: KeepAwakePreset) {
        if loadDetailed() == .unreadable {
            NSLog("battery_app: keep-awake preset save REFUSED — the stored value (%@) will not decode and "
                  + "is not overwritten.", Self.key)
            return
        }
        guard let data = try? JSONEncoder().encode(preset) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Copy the unreadable stored value to a dated key, verify the copy, then remove the original.
    func setAsideUnreadable() {
        guard loadDetailed() == .unreadable, let stored = defaults.object(forKey: Self.key) else { return }
        let asideKey = "\(Self.key).unreadable.\(Int(Date().timeIntervalSince1970))"
        defaults.set(stored, forKey: asideKey)
        guard defaults.object(forKey: asideKey) != nil else { return }   // never remove what was not kept
        defaults.removeObject(forKey: Self.key)
        NSLog("battery_app: unreadable keep-awake preset set aside under %@.", asideKey)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}
