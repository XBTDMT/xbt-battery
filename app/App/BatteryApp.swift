import SwiftUI
import AppKit
import AppIntents   // Phase 5 #17: AppDependencyManager registration for the App Intents surface
import Combine
import ServiceManagement
@preconcurrency import Shared   // Phase 2: re-introduced for SMAppService daemon registration (helper UX)

/// SwiftUI shell for the agent app. An `App` must declare a `Scene`; `MenuBarExtra` is forbidden
/// (#15) and a `WindowGroup` would create a stray window, so a (currently unused) `Settings` scene
/// is the no-window choice. All real UI is the AppKit `NSStatusItem` + popover. (SPEC WI-1.4.)
@main
struct BatteryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        // 4.4: the previously-empty Settings scene now hosts the notification preferences (architect
        // ruling on the Settings-access STOP: filling a declared-but-empty scene is not touching the
        // frozen popover/menu). Reachable via the standard ⌘, Settings command; a discoverable in-UI
        // opener is deferred to #29 (which owns popover navigation). Shares the AppDelegate's single
        // model so the toggles and the observer read one store + one notification center.
        // #29 D-4b: an App must declare a Scene, but the REAL Settings is an AppDelegate-managed NSWindow
        // (an accessory/LSUIElement app can't reliably open the SwiftUI Settings scene from the background —
        // see openSettingsChokePoint). This Settings scene is an empty stub, NOT a second SettingsView
        // surface (a dormant duplicate would be a future bug); it's unreachable-by-design (no menu → no ⌘,).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var rightClickMonitor: Any?   // 4.3: global monitor for the secondary (right) click
    /// #29 D-4 (A1/F3): the app-level Settings router — the single source of truth for "open Settings on
    /// tab X". Injected into both the popover (footer gear) and the Settings scene (tab selection).
    let settingsRouter = SettingsRouter()
    /// #29 D-6 shell exception: the ONE AppDelegate↔popover navigation channel (reset-to-root on show +
    /// the show-history deep-link). Applied in popoverWillShow from `pendingPopoverPath`.
    let popoverNavigator = PopoverNavigator()
    private var pendingPopoverPath: [PopoverNavigator.Route] = []
    /// #22 + B-arc B5: the "another app came frontmost" observer, live ONLY while the popover is shown.
    private var frontmostAppObserver: NSObjectProtocol?
    private var settingsOpenCancellable: AnyCancellable?
    private var settingsSelectionCancellable: AnyCancellable?   // #29 D-6 F1: per-tab window resize
    private var uninstallStateCancellable: AnyCancellable?      // #29 D-6 F1: grow window for the uninstall flow
    /// #29 D-4b: the Settings window, hosted directly (not via the SwiftUI Settings scene, which an
    /// accessory app can't reliably open from the background). Created lazily, reused across opens.
    private var settingsWindow: NSWindow?
    /// #29 D-6 (5b): the About window — same AppDelegate-managed NSWindow pattern (lazy, reused,
    /// isReleasedWhenClosed=false) the Settings choke-point uses. See openAbout() for the GATE-0 note.
    private var aboutWindow: NSWindow?
    private let monitor = BatteryMonitor()
    private let helperClient = HelperClient()   // Sprint 3.7: energy-helper client (live, Stage 5)
    // Sprint 3.7 STAGE 3: app-side driver for the privileged setEnergyMode (honest failure; the picker
    // UI that calls setMode is STAGE 5). Wired to the helper client via the EnergyModeSetter seam.
    private lazy var energyModeController = EnergyModeController(setter: helperClient)
    // auto-energy-mode PHASE 1: an OPT-IN (default OFF) policy that drives the EXISTING setEnergyMode op
    // on live conditions (battery-low → Low Power). Adds no privilege — same op the picker uses. Reads
    // SOC / plugged / the active-source mode straight off the live snapshot; the snapshot sink in
    // applicationDidFinishLaunching drives evaluate(). Discloses on success; holds for a manual choice.
    private lazy var autoEnergyRunner = AutoEnergyModeRunner(
        setter: energyModeController,
        conditions: { [weak self] in
            let snap = self?.monitor.snapshot
            // PHASE 2 (sec 11): map the OS SYSTEM thermal state 1:1 to the policy's I/O-free ThermalLevel.
            // An unrecognized future state degrades to .nominal — never force Low on a state we don't know.
            let thermal: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
            case .nominal:    .nominal
            case .fair:       .fair
            case .serious:    .serious
            case .critical:   .critical
            @unknown default: .nominal
            }
            // Phase 4 (sec 13): the INACTIVE source's live mode comes from the per-source custom read in
            // the SAME snapshot (read on the same tick as the active mode). Plugged → active is charger,
            // inactive is battery; on battery → inactive is charger.
            let perSource = snap?.perSourceMode ?? .unavailable
            return AutoEnergyConditions(thermal: thermal, soc: snap?.chargePercent,
                                        plugged: snap?.powerSource == .ac,
                                        highAvailable: self?.energyModeController.highPowerAvailable ?? false,
                                        currentSourceMode: snap?.energyMode ?? .unavailable,
                                        inactiveSourceMode: (snap?.powerSource == .ac) ? perSource.battery : perSource.charger)
        })
    // Sprint 3.7 STAGE 4: sustained per-app energy source (popover-open one-shot; honest unavailable).
    // Wired via the TaskEnergyCollecting seam; the popover view that calls refresh() is STAGE 5.
    private lazy var sustainedEnergySource = SustainedEnergySource(collector: helperClient)
    private let helperHealth = HelperHealthModel(service: LiveDaemonService(plistName: BatteryAppIDs.helperPlistName), launchVerdict: .notRegistered)   // 5.3: honest helper reg-state surface (was the "UI = STAGE 5" gap)
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?
    private var cadenceCancellable: AnyCancellable?
    private var iconRefreshCancellable: AnyCancellable?   // #23: re-render the glyph on flow change
    private var trendVetoCancellable: AnyCancellable?     // #POPOVER-TREND: limit + limit-hold → monitor veto
    private var keepAwakeIconCancellable: AnyCancellable? // #EI-1: re-render the glyph on keep-awake session change
    private var postSetKickCancellable: AnyCancellable?   // #25: double-kick the monitor post-Set
    private var ambiguousHoldLogCancellable: AnyCancellable?   // 4.E: opportunistic flag-value log
    private var topUpEvalCancellable: AnyCancellable?          // 4.F: drive the Top Up watcher
    private var historyRecordCancellable: AnyCancellable?      // 4.G: the ONE history call site
    private var autoEnergyEvalCancellable: AnyCancellable?     // auto-energy-mode: drive the policy on snapshots
    private var highPowerCapabilityCancellable: AnyCancellable?   // A9 rider: the one non-snapshot input
    private var autoEnergyReadGateCancellable: AnyCancellable? // auto-energy Phase 4: gate the per-source custom read to enabled
    private var degradedSignalCancellable: AnyCancellable?     // B1: setupFlow .readyDegraded → engine

    /// #22 popover auto-dismiss: outside-click monitor lifecycle, paired to the popover's own
    /// show/close via NSPopoverDelegate so every close path removes the monitor exactly once.
    private lazy var dismissCoordinator = PopoverDismissCoordinator(
        monitor: LiveGlobalClickMonitor(),
        requestClose: { [weak self] in self?.popover.performClose(nil) })

    // Phase 2 REBUILD (SPEC v4.0): the native charge-limit engine — the PRIMARY path.
    private let shortcutsRunner = ShortcutsRunner()
    private let advisor = OBCAdvisor()
    private lazy var engine = ChargeLimitEngine(runner: shortcutsRunner)
    private lazy var pipeline = ChargeTelemetryPipeline(engine: engine, advisor: advisor)
    private lazy var setupFlow = SetupFlow(runner: shortcutsRunner)
    // 4.C: the autonomous charge scheduler. Setup-ready gate hangs off setupFlow.
    private lazy var scheduleRunner = ScheduleRunner(
        // The schedule only SETS the limit (never a read-back), so degraded mode is operational. Strict
        // == .ready left it paused on macOS 27 (.readyDegraded), so the schedule never ran.
        engine: engine, isSetupReady: { [weak self] in self?.setupFlow.isOperational ?? false })
    // Phase 5 #17 Pass 1: the App Intents surface. Routes a Set through the LIVE engine (source
    // .appIntent); isSetUp reads SetupFlow's already-determined operational state (no fresh shortcuts
    // run). Registered via AppDependencyManager on launch (sec 10).
    // The readiness latch is now an app-level gate (Pass 2 has Top Up await the SAME gate). The app owns
    // and settles it; the bounded timeout matches the launch read characteristics (sec 11): up to two
    // serial shortcuts invocations, each invocationTimeout plus sigkillGrace.
    private let intentReadinessGate =
        IntentReadinessGate(timeout: .seconds(2 * (ShortcutsRunner.invocationTimeout + ShortcutsRunner.sigkillGrace)))
    private lazy var intentSurface = ChargeControlIntentSurface(
        setter: engine,
        isSetUp: { [weak self] in self?.setupFlow.isOperational ?? false },
        readinessGate: intentReadinessGate)
    // 4.E #27: launch-at-login model (seamed SMAppService.mainApp).
    private let loginItem = LoginItemModel()
    // 4.F #8: one-shot Top Up — reads SoC/on-AC from the live snapshot.
    private lazy var topUpController = TopUpController(
        engine: engine,
        reading: { [weak self] in
            TopUpController.Reading(soc: self?.monitor.snapshot.chargePercent,
                                    onAC: self?.monitor.snapshot.powerSource == .ac) })
    // Phase 5 #17 Pass 2: the Top Up App Intents surface. Mirrors intentSurface: routes a one-shot top up
    // through the LIVE TopUpController, isSetUp reads SetupFlow's already-determined state, and it awaits
    // the SAME shared intentReadinessGate (Step A). Registered via AppDependencyManager on launch (sec 10).
    private lazy var topUpIntentSurface = TopUpIntentSurface(
        readinessGate: intentReadinessGate,
        topUp: topUpController,
        isSetUp: { [weak self] in self?.setupFlow.isOperational ?? false })
    // Phase 5 #17 Pass 2: the Energy-Mode App Intents surface. Routes a set through the LIVE
    // EnergyModeController, writing the ACTIVE per-source scope resolved LIVE from the snapshot (the picker's
    // (powerSource == .ac) ? .charger : .battery, so the set lands on the profile in use — the HARD SAFETY
    // constraint). DECOUPLED from the readiness gate (§2): Energy Mode's only precondition is helper
    // reachability, surfaced honestly as .helperUnreachable. Registered via AppDependencyManager on launch
    // (sec 10); no new gate, no new settle call.
    private lazy var energyModeIntentSurface = EnergyModeIntentSurface(
        setter: energyModeController,
        activeSource: { [weak self] in (self?.monitor.snapshot.powerSource == .ac) ? .charger : .battery })
    // 4.G #28: persistent history (Application Support/BatteryApp/history). Local only, S-N6-clean.
    private lazy var historyStore: HistoryStore = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return HistoryStore(root: appSupport.appendingPathComponent("BatteryApp/history", isDirectory: true))
    }()
    private let historyMaintenanceScheduler = LiveOneShotScheduler()   // the ONE daily one-shot (chained)
    // 4.H #12: connected-device batteries — fetched on popover OPEN only (no background polling).
    private let deviceSource = DeviceBatterySource()
    private let phoneSource = PhoneBatterySource()   // #iPhone: Finder sync link + hotspot beacon
    // 4.5 #19: per-app RELATIVE energy impact — fetched on popover OPEN only (a polling energy
    // monitor would be self-defeating). Reuses ProcessProbe; no new subprocess plumbing.
    private let energySource = EnergyImpactSource()
    // spec 31 (G-2): external power — port + system power parsed off the monitor's OWN diagnostics read via
    // its subscriber tap (no second poller, no snapshot field). App-long and UNGATED by ChargeLimitSupport:
    // it reads the battery record, which every supported OS publishes. The Devices page reads its rounded
    // `display` (stage 4); stage 5 wires the HUD (inside the support gate).
    private let portPowerSource = PortPowerSource(
        defaults: .standard, now: { Date() }, clocks: .live,
        // 31 G-7: one IOUSB walk per successful diagnostics read (ms, ~60/h) stamps first-seen leaves.
        usb: LiveUSBLeafEnumerator(), osBuild: { PortPowerSource.liveOSBuild() })
    // #EI-1: in-process keep-awake (IOPMAssertion). No root, no helper, no XPC, no SMC. The release
    // spine (off / timer-expiry / quit / unplug-for-AC) lives in the controller; this app wires the
    // Live seam, the terminate path, and the unplug signal.
    private lazy var keepAwakeController = KeepAwakeController(
        assertion: LiveSleepAssertion(), scheduler: LiveOneShotScheduler(), clock: LiveMonotonicClock())
    // #EI-1a: READ-ONLY "what else is keeping your Mac awake" — read on popover-open (no timer).
    private lazy var keepAwakeInventory = KeepAwakeInventorySource()
    // (1b): graceful terminate seam for the #EI-1a holders. App-side AppKit ONLY (NSRunningApplication) —
    // GUI-apps-only by API, never the privileged helper / XPC. No root, no entitlement, no autonomy.
    private lazy var appTerminator: AppTerminating = LiveAppTerminator()
    // #EI-2: READ-ONLY battery health/longevity (AppleSmartBattery) — read on popover-open (no timer).
    private lazy var batteryLifetimeSource = BatteryLifetimeSource()
    // #EI-3: READ-ONLY adapter wattage ceiling (AppleSmartBattery AdapterDetails) — on popover-open (no timer).
    private lazy var powerAdapterSource = PowerAdapterSource()
    // 3.7 sleep/wake STAGE 2b: the program-once schedule controller (drives the privileged setRepeatingSleepWake;
    // reads the live pmset -g sched on popover-open). HelperClient is its SleepWakeSetter (sealed Stage 2b-i).
    private lazy var sleepWakeController = SleepWakeScheduleController(setter: helperClient)
    // 3.7 power-nap/wake STAGE 2b-ii: app-side controller; HelperClient is its WakeBehaviorSetter (Stage 2b-i).
    private lazy var wakeBehaviorController = WakeBehaviorController(setter: helperClient)
    // 4.4: system notifications. The model owns the prefs store + the single live UN center (auth +
    // post); it is built here (cheap, no prompt) so BatteryApp.body's Settings scene and the observer
    // below share ONE store + ONE center. The coordinator is the one read-only observer call site.
    let notificationSettingsModel = NotificationSettingsModel()
    private lazy var notificationCoordinator = NotificationCoordinator(
        store: notificationSettingsModel.store,
        presenter: notificationSettingsModel.presenter)
    /// #29 D-5: the HUD coordinator — constructed in applicationDidFinishLaunching once the status item +
    /// popover exist (its closures read them lazily at outcome time).
    private var hudCoordinator: HUDCoordinator?
    // #13: menu-bar icon customization. The store is owned here (cheap, no prompt); the settings model
    // rerenders the glyph IMMEDIATELY on change via the cached last snapshot (no relaunch, no new timer).
    let glyphPreferencesStore = GlyphPreferencesStore()
    lazy var glyphSettingsModel = GlyphSettingsModel(store: glyphPreferencesStore,
                                                     onChange: { [weak self] in self?.rerenderGlyph() })
    // 5.5 Cut 2: the ordered uninstall teardown (Settings → Uninstall). Live seams over the EXISTING
    // engines (limit/energy/schedule) + the SAME daemon/login wrappers registerHelperIfNeeded and
    // LoginItemModel use — the teardown composes reviewed request-path surfaces, adds no new privilege.
    lazy var uninstallCoordinator = UninstallCoordinator(
        limit: LiveLimitRestoring(engine: engine),
        energy: LiveEnergyRestoring(controller: energyModeController),
        schedule: LiveScheduleClearing(setter: helperClient),
        primaryDaemon: LiveDaemonService(plistName: BatteryAppIDs.helperPlistName),
        legacyDaemon: LiveDaemonService(plistName: BatteryAppIDs.legacyHelperPlistName),
        loginItem: LiveLoginItemService(),
        residue: LiveAppResidueRemoving())
    private var lastSnapshot: BatterySnapshot?   // #13: last render input, for an immediate settings-driven rerender

    /// ENERGY (audit A2) — the render-input gate. The KEY itself now lives in
    /// `app/Views/GlyphRenderKey.swift` (host-app-free, so the "every render input is keyed"
    /// invariant is unit-assertable); the gate that compares it stays in `updateStatusButton`.
    private var lastGlyphKey: GlyphRenderKey?

    // ── Keep-awake steam drift (owner pick 2026-09-08) ──────────────────────────────────────────
    // The ONE animated cue in the glyph: the espresso badge's two wisps rise and fade on a 2.2 s
    // cycle. (A green charging-bolt pulse was built alongside this and REMOVED at owner request the
    // same day — do not reintroduce it without a fresh ask.) The phase is derived from wall time, not
    // a tick counter, so it cannot drift. The timer exists ONLY while keep-awake is actually on, and
    // is torn down on system sleep and at terminate, so it can never animate into a dark display.
    private var glyphAnimTimer: Timer?
    private var glyphAnimStart: TimeInterval = 0
    private static let glyphAnimTick: TimeInterval = 0.2     // 5 fps — at 14pt this is indistinguishable
    private static let steamDriftPeriod: TimeInterval = 2.2

    private var animElapsed: TimeInterval {
        glyphAnimTimer == nil ? 0 : Date.timeIntervalSinceReferenceDate - glyphAnimStart
    }

    /// Steam phase 0…1, wrapping. 0 renders the original static cup.
    private var steamDriftPhase: CGFloat {
        guard glyphAnimTimer != nil else { return 0 }
        return CGFloat(animElapsed.truncatingRemainder(dividingBy: Self.steamDriftPeriod)
                       / Self.steamDriftPeriod)
    }

    /// Arms the timer iff the steam is actually being drawn; idempotent both ways.
    private func syncGlyphAnimation(active: Bool) {
        guard active else {
            glyphAnimTimer?.invalidate(); glyphAnimTimer = nil
            return
        }
        guard glyphAnimTimer == nil else { return }          // already running — never stack
        glyphAnimStart = Date.timeIntervalSinceReferenceDate
        let t = Timer.scheduledTimer(withTimeInterval: Self.glyphAnimTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rerenderGlyph() }
        }
        t.tolerance = Self.glyphAnimTick * 0.15              // let the kernel coalesce these fires
        glyphAnimTimer = t
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if RenderHarness.runIfRequested() { return }   // #30 R15: `--render-pages <dir>` renders offscreen and exits
        setUpStatusItem()

        // Phase 5 #17 sec 10: log our PID so the on-device gate can confirm in-process intent execution
        // (pairs with SetChargeLimitIntent.perform's PID log — same PID ⇒ same process, single instance).
        IntentLog.log.debug("applicationDidFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        // Register the live intent surface through AppDependencyManager (sec 10 — replaces the cross-process
        // static that read nil out-of-process): a synchronous add of an async @MainActor dependency the
        // framework awaits before perform, so an in-process intent always resolves a live surface.
        let surface = intentSurface
        AppDependencyManager.shared.add(key: ChargeControlIntentSurface.dependencyKey,
                                        dependency: { @MainActor () async -> ChargeControlIntentSurface in surface })
        let topUpSurface = topUpIntentSurface
        AppDependencyManager.shared.add(key: TopUpIntentSurface.dependencyKey,
                                        dependency: { @MainActor () async -> TopUpIntentSurface in topUpSurface })
        let energySurface = energyModeIntentSurface
        AppDependencyManager.shared.add(key: EnergyModeIntentSurface.dependencyKey,
                                        dependency: { @MainActor () async -> EnergyModeIntentSurface in energySurface })
        // #29 D-5: wire the intent→HUD hooks at LAUNCH (not popover-open) so an Energy-Mode / Top Up
        // Shortcut confirms via the HUD even before the popover is ever opened (D10: .appIntent always).
        energyModeIntentSurface.onApplied = { [weak self] name in
            self?.hudCoordinator?.report(origin: .appIntent, event: .energyModeSet(name))
        }
        topUpIntentSurface.onStarted = { [weak self] in
            self?.hudCoordinator?.report(origin: .appIntent, event: .toppingUp)
        }
        if !ChargeLimitSupport.isSupported {
            // Unsupported OS: the engine never taps, so settle the readiness gate now — an intent gets the
            // honest not-set-up immediately instead of waiting out the bounded readiness timeout.
            intentReadinessGate.settle()
        }

        popover.behavior = .transient   // #22: kept (harmless; future macOS may honor it)
        BatteryPopoverView.mainPopover = popover   // page lifetime follows THIS popover only (hover cards are popovers too)
        popover.appearance = NSAppearance(named: .darkAqua)   // #30 R15: the popover is the mock's dark surface
        popover.delegate = self         // #22: drives the dismiss coordinator's monitor pairing
        popover.contentViewController = NSHostingController(rootView: BatteryPopoverView(
            monitor: monitor, engine: engine, confirm: engine.confirm,
            pipeline: pipeline, setupFlow: setupFlow, advisor: advisor, schedule: scheduleRunner,
            loginItem: loginItem, topUp: topUpController, history: historyStore,
            deviceSource: deviceSource, phoneSource: phoneSource, portSource: portPowerSource, energySource: energySource,
            energyMode: energyModeController, autoEnergy: autoEnergyRunner, sustained: sustainedEnergySource,
            keepAwake: keepAwakeController, keepAwakeInventory: keepAwakeInventory,
            batteryLifetime: batteryLifetimeSource, powerAdapter: powerAdapterSource,
            sleepWake: sleepWakeController, wakeBehavior: wakeBehaviorController,
            helperHealth: helperHealth, helperClient: helperClient,
            appTerminator: appTerminator,   // (1b): graceful GUI-app quit seam for the #EI-1a holders
            navigator: popoverNavigator,    // #29 D-6 shell exception: the reset-to-root / deep-link channel
            settingsRouter: settingsRouter))   // #29 D-4: the hoisted app-level Settings router

        // #22: cmd-tab away closes the popover. FLAGGED deviation from the spec's named mechanism
        // (NSApplication.didResignActiveNotification): this is an LSUIElement *accessory* app, so
        // showing the status-item popover never makes us "active" — didResignActive therefore
        // never fires (verified on-device 2026-06-10). We instead watch for ANOTHER app becoming
        // frontmost (fires reliably on cmd-tab regardless of our active state), self-guarded so
        // our own activation doesn't close us. The resulting popoverDidClose removes the monitor.
        // B-arc B5: registered in `popoverDidShow` and removed in `popoverDidClose` rather than for app
        // lifetime — the handler's own first act was `guard self.popover.isShown`, so outside a shown
        // popover every app switch on the machine woke us only to be discarded.

        // #29 D-4: the AppDelegate is the SINGLE observer of the router's open requests (LSUIElement has
        // no persistent scene view to host one). Each open(to:) advances openRequestToken → open Settings.
        settingsOpenCancellable = settingsRouter.$openRequestToken
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.openSettingsChokePoint() } }

        // #29 D-6 F1: resize the Settings window to each tab's measured height on tab switch (animated).
        settingsSelectionCancellable = settingsRouter.$selection
            .dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.resizeSettingsWindowForCurrentTab(animated: true) } }

        // #29 D-6 F1: the uninstall flow's taller states (running / aborted / completed) GROW the Settings
        // window so nothing is ever clipped — the resting measurement is the compact idle state. (Deferred
        // one tick so the re-measure sees the settled new state; a no-op unless the window is on General.)
        uninstallStateCancellable = uninstallCoordinator.$terminal
            .dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self, self.settingsWindow?.isVisible == true, self.settingsRouter.selection == .general else { return }
                DispatchQueue.main.async { self.resizeSettingsWindowForCurrentTab(animated: true) }
            } }

        // Observe the model; deliver on main and bridge to the MainActor (Phase-0 M16 pattern).
        cancellable = monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateStatusButton(snap)
                    // #EI-1: a while-on-AC keep-awake session releases on unplug. Rides the existing
                    // snapshot publisher (no new timer); the controller no-ops every other case.
                    self.keepAwakeController.powerSourceChanged(onAC: snap.powerSource == .ac)
                    // #EI-1 increment: safety floor — auto-release an active session under 5% on battery.
                    self.keepAwakeController.batteryLevelChanged(percent: snap.chargePercent, onAC: snap.powerSource == .ac)
                }
            }

        // #EI-1: re-render the menu-bar glyph PROMPTLY when our keep-awake session changes — enable,
        // disable, timed-expiry, the low-battery auto-release, or the unplug-for-AC release. Toggling
        // keep-awake does NOT change the battery snapshot, so the snapshot sink above wouldn't repaint
        // the pip on its own. Mirrors that sink (.receive(on: .main) + assumeIsolated) and re-renders
        // from the current non-optional snapshot. Rides Combine on the existing @Published session — NO
        // new timer (honours the #EI-1 no-new-timer invariant; $session changes only on those events).
        // UNGATED by ChargeLimitSupport: keep-awake is available at every OS floor, unlike charge control.
        keepAwakeIconCancellable = keepAwakeController.$session
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateStatusButton(self.monitor.snapshot)
                }
            }

        // auto-energy-mode PHASE 1: drive the opt-in policy on every snapshot (soc / plugged / mode).
        // UNGATED by ChargeLimitSupport — it uses pmset (always available), like the Energy Mode picker.
        // Inert while disabled (the default); a cheap no-op then. Mirrors the topUp evaluate() sink pattern.
        autoEnergyEvalCancellable = monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.autoEnergyRunner.evaluate() }
            }

        // A9 rider (adversarial review, N5): the conditions closure reads ONE input that is not a
        // snapshot field — `energyModeController.highPowerAvailable`, a latch-once hardware probe
        // resolved on popover open. It was never a trigger. Before A9 the ~856 publishes/hr corrected
        // a stale evaluation within seconds; now a duplicate snapshot publishes nothing, so in a frozen
        // hold (this machine has 151 recorded hours at SoC 80 / 0 W on AC) the High branch could sit
        // unapplied indefinitely. This is the exact consumer shape the reviewer named and could not
        // disprove: input = (snapshot + something not in the snapshot).
        //
        // Narrow, and never a safety fault: Branch A (thermal / battery-low PROTECTION) rides fields
        // that are all in the snapshot, so it cannot be starved. What was reachable is a missed RAISE
        // to High. No timer and no poll — `$highPowerAvailable` is already `@Published` and changes at
        // most twice per session, so this is a heartbeat placed next to the consumer that needs it,
        // which is what the reviewer prescribed instead of a supervisor tick.
        highPowerCapabilityCancellable = energyModeController.$highPowerAvailable
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.autoEnergyRunner.evaluate() }
            }

        // auto-energy-mode PHASE 4 (sec 13.2 / 16.4): GATE the per-source `pmset -g custom` read to the
        // automation being enabled — no added spawn when off. Mirror the runner's published `enabled` onto
        // the monitor's flag; @Published delivers the current value on subscribe, so the initial state syncs.
        autoEnergyReadGateCancellable = autoEnergyRunner.$enabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated { self?.monitor.readPerSourceModes = on }
            }

        // auto-energy-mode PHASE 2 (sec 11): the SYSTEM thermal level is the second trigger. ProcessInfo
        // posts thermalStateDidChange on an ARBITRARY queue, so deliver on .main and assumeIsolated before
        // touching the @MainActor runner (the same hop the snapshot sink makes). App-lifetime observer.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoEnergyRunner.evaluate() }
        }

        // spec 31 §2.2 (G-2, G-4): the port source rides the monitor's multi-subscriber diagnostics tap —
        // every read, synchronously, `.unread` on a failed read. OUTSIDE the ChargeLimitSupport gate (only
        // the HUD wiring, stage 5, goes inside it, next to HUDCoordinator). Registered before
        // `monitor.start()` so the launch read is its seed.
        monitor.addDiagnosticsSubscriber { [weak self] read in
            self?.portPowerSource.ingest(read)
        }

        // sec 6 OS gate — NOT UI-only: below 26.4 the engine is never tapped, setup detection
        // never runs, and no `shortcuts` process is ever spawned (monitoring-only mode).
        if ChargeLimitSupport.isSupported {
            // Single-poller tap (sec 2): charge telemetry rides the monitor's existing
            // diagnostics read; the 30-min backstop sync piggybacks here (engine rate-gates
            // it), gated on setup-ready so no invocation precedes the explained grant (sec 2).
            monitor.onDiagnosticsProperties = { [weak self] props in
                guard let self else { return }
                pipeline.ingestDiagnostics(props)
                if setupFlow.state == .ready { Task { await self.engine.sync(.backstop) } }
            }
            monitor.onDiagnosticsReadFailure = { [weak self] in
                self?.pipeline.noteDiagnosticsReadFailure()
            }

            // Armed-cadence switching must be EVENT-driven, not next-tick: a Set arms a window
            // NOW and the 10 s cadence must begin now, not up to 60 s later. Every arm/resolve
            // publishes a command status — that's the cadence signal.
            cadenceCancellable = engine.confirm.$status
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.monitor.setPollInterval(self.engine.wantsFastPolling ? 10 : 60)
                    }
                }

            // #25 (4.D): the ONE post-Set kick call site. A command (Set/Pause/Resume, any
            // source — user or schedule) completes when commandInFlight goes true→false; kick the
            // monitor (T+0 + T+3 s) so the glyph/popover race the hardware's reaction instead of
            // the poll grid. Telemetry samples are IOKit reads, not shortcuts — they ride after
            // the serialized command, never a second poll timer.
            postSetKickCancellable = engine.$commandInFlight
                .dropFirst()
                .filter { !$0 }
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.monitor.postSetKick() }
                }

            // B1: mirror the canonical readiness signal (setupFlow.state == .readyDegraded — the same
            // signal the popover keys on) into the engine, so a permanent-degraded Set shows the calm
            // "Limit set to N%" instead of the scary read-back caveat. Reuses SetupFlow's determination,
            // not a new heuristic. Fires on subscribe and on every state change.
            degradedSignalCancellable = setupFlow.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] state in
                    MainActor.assumeIsolated { self?.engine.readBackDegraded = (state == .readyDegraded) }
                }

            // S-N3 wake re-sync + S-N5: waking re-reads the limit the world may have changed
            // (only once setup is ready — the first grant belongs to the explained flow).
            // 4.C: wake also drives schedule catch-up (the machine is never woken to fire).
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleRunner.recompute(.wake)
                    if self.setupFlow.state == .ready { Task { await self.engine.sync(.wake) } }
                }
            }

            // 4.C: DST / timezone hops re-evaluate the wall-clock schedule (sec 2).
            for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRunner.recompute(.clockChange) }
                }
            }

            // 4.G #28: sleep flush seam — persist the buffered history tail before the machine sleeps.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncGlyphAnimation(active: false)   // never animate into a sleeping display
                    self?.historyStore.flush()
                    // #EI-1 honesty (audit B7): the assertions are idle-sleep only, so the Mac can sleep
                    // through a held session. Record it, or the badge and the status line survive the very
                    // event that falsified them.
                    self?.keepAwakeController.systemWillSleep()
                }
            }

            // 4.F #8: drive the Top Up watcher on every snapshot OR limit change (full / unplug /
            // external-change detection). No new timer — sinks on existing publishers; evaluate()
            // is a cheap no-op unless a Top Up is climbing.
            topUpEvalCancellable = monitor.$snapshot.map { _ in () }
                .merge(with: engine.$limit.map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        Task { await self.topUpController.evaluate() }
                    }
                }

            // 4.G #28: the ONE history recording call site — a passive sink on the snapshot, which
            // fires AFTER the pipeline classifies (so telemetryState + the snapshot are both fresh).
            // The store owns the rate-bound (≤1/60 s) + immediate transition rows + buffered flush;
            // classifier inputs are untouched.
            //
            // A9 (`knowledge/11-MEASURE-a5-a9-a13.md` §3.6): `BatteryMonitor.recompose()` now publishes
            // only on a REAL change, so `$snapshot` alone would no longer offer this store a row during
            // a flat stretch. That matters here and NOWHERE ELSE among the five subscribers, because
            // this is the only one whose semantics are liveness rather than value, in two concrete ways:
            //   1. `recordCharge` lands a periodic row whenever `elapsed >= rateBound` (60 s) even when
            //      nothing moved — the heartbeat that makes a flat stretch distinguishable from an app
            //      that was not running.
            //   2. A charge row carries `state` and `limit`, and NEITHER is a `BatterySnapshot` field.
            //      `.limitHold` ↔ `.ambiguousHold` differ only by `NotChargingReason` with the current
            //      near zero on both sides, so a genuine classifier transition CAN occur across a
            //      byte-identical snapshot. Those rows feed `agg-*.json`'s `.limitHold` hours, which
            //      §7.8 of the audit makes load-bearing — dropping one would mis-attribute hours.
            // The DECISION, stated rather than discovered later: history keeps its current row cadence.
            // It gets `pipeline.$telemetryState` as a second trigger, which publishes on every
            // `ingestDiagnostics` (and on `noteDiagnosticsReadFailure`), i.e. once per diagnostics read.
            // So the store is still offered a sample ~132×/hr (60 poll + 72.4 event) against a 60 s rate
            // bound — the same rows as before, from ~856 offers/hr instead. The store's own gate, not
            // this sink, remains the thing that decides what is recorded. `snap` is dropped for
            // `monitor.snapshot` because the merge erases the value (the same idiom as the Top Up sink
            // above and `NotificationCoordinator`'s `reading:` closure).
            historyRecordCancellable = monitor.$snapshot.map { _ in () }
                .merge(with: pipeline.$telemetryState.map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let snap = self.monitor.snapshot
                        self.historyStore.ingest(HistorySample(
                            soc: snap.chargePercent,
                            watts: HistoryFormat.watts(voltageVolts: snap.voltageVolts,
                                                       amperageMilliamps: snap.amperageMilliamps),
                            onAC: snap.powerSource == .ac,
                            state: HistoryFormat.stateString(self.pipeline.telemetryState),
                            limit: self.engine.limit.knownValue,
                            healthPct: snap.healthPercent,
                            cycles: snap.cycleCount,
                            maxCap_mAh: snap.fullChargeCapacity_mAh))
                    }
                }

            scheduleRunner.start()                     // 4.C: subscribe + pace (gated on setup-ready)
            Task {
                await setupFlow.checkNow()             // re-check on every launch (sec 2)
                // Phase 5 #17 sec 11 + launch reconcile: in verified read-back mode reconcile against a
                // live read at launch, the same as the wake path, even when we already hold custody. This
                // reflects a limit changed outside the app while it was off and makes engine.limit live
                // for the schedule and notification logic before the first popover open. This also takes
                // the FIRST known-limit read so a cold-launch intent isn't blind. Degraded stays on
                // custody (the guard is still strict .ready); a failed read falls back to custody in sync.
                if setupFlow.state == .ready {
                    await engine.sync(.wake)
                }
                intentReadinessGate.settle()           // first known-limit read done OR setup-failure taken
                scheduleRunner.recompute(.launch)      // setup state now known → catch-up may fire
                if setupFlow.isOperational {           // 4.F: relaunch-resume a persisted Top Up
                    // Top Up is SET-only and resumeOnLaunch is built for degraded mode (it falls back to
                    // the LastSetTracker custody when the Get can't verify), so degraded is operational.
                    await topUpController.resumeOnLaunch()
                }
            }

            historyStore.runMaintenance()              // 4.G: aggregate-then-delete on launch…
            scheduleHistoryMaintenance()               // …then a chained daily one-shot (no repeating timer)

            // #23: re-render the menu-bar glyph when the TRUTH flow state changes (so the bolt
            // appears/clears on real flow, not only on a %-change snapshot tick). No new timer —
            // a sink on the existing pipeline publisher.
            // #POPOVER-TREND: a % rise is not a charge at/above the limit or in the limit hold. The monitor owns
            // the vetoed verdict so the glyph, the popover, the Day and Energy pages all read ONE answer.
            trendVetoCancellable = engine.$limit.combineLatest(pipeline.$telemetryState)
                .receive(on: RunLoop.main)
                .sink { [weak self] limit, state in
                    MainActor.assumeIsolated {
                        self?.monitor.setTrendVeto(limitPercent: limit.knownValue, limitHold: state == .limitHold)
                    }
                }

            iconRefreshCancellable = pipeline.$telemetryState
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.updateStatusButton(self.monitor.snapshot)
                    }
                }

            // Bolt v2 (4.E sec 2): the NCR=0 ambiguous-hold flag value is UNMEASURED — the veto
            // makes it non-blocking, so measurement is OPPORTUNISTIC. Whenever the classifier
            // ENTERS .ambiguousHold, record the IOPS flag's value so the record fills itself.
            ambiguousHoldLogCancellable = pipeline.$telemetryState
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] state in
                    MainActor.assumeIsolated {
                        // 2.E tier 2 (2026-09-09): `.idleInhibit` joins the census. Tier 2's ENTIRE
                        // benefit rests on `kIOPSIsChargingKey` being TRUE while NCR = 0x80 — the bolt
                        // already reads that flag (`BatterySnapshot.swift:126`); the veto is all that
                        // gates it. If the flag is FALSE at the plug instant, tier 2 is a no-op and the
                        // proposal is dead. Nothing in the repo records it, and the case is unreachable
                        // on battery (NCR = 128 there is the discharging fixture, not the inhibit), so
                        // it can only be caught opportunistically at a real plug. Zero behaviour change:
                        // this sink drives nothing. Analysis after ~2-3 samples/day of plugged use.
                        guard let self, state == .ambiguousHold || state == .idleInhibit else { return }
                        NSLog("battery_app: [4.E flag log] entered %@; IOPS kIOPSIsChargingKey = %@",
                              String(describing: state),
                              String(describing: self.monitor.snapshot.isCharging))
                    }
                }

            // 4.4: the ONE notifications observer call site (SPEC sec 0). Read-only sinks on the
            // existing pipeline/engine/top-up/snapshot publishers; outcomes → pure decision layer →
            // post. Never drives or gates anything (engine ZERO). Gated on support like every other
            // charge-control tap: the event stream it observes IS the 4.D pipeline, so monitoring-only
            // mode (no pipeline) simply has no notifications — consistent with the hidden controls.
            // #29 D-5: the HUD coordinator — observes the charge-limit SET + top-up start and shows the
            // transient pill under the status item per the pure trigger predicate. It rides existing
            // publishers only (never drives anything), exactly like the notifications observer below.
            let hud = HUDCoordinator(
                popoverVisible: { [weak self] in self?.popover.isShown ?? false },
                userActive: { AppDelegate.userIsActive() },
                buttonFrame: { [weak self] in
                    guard let button = self?.statusItem?.button, let window = button.window else { return nil }
                    return window.convertToScreen(button.convert(button.bounds, to: nil))
                })
            hudCoordinator = hud
            hud.start(engine: engine)
            // 31 §2.2 (G-4): the plug-in notice. The port source lives OUTSIDE this gate (the Devices section
            // needs it everywhere); only the HUD wiring is gated, next to the coordinator it reports to. The
            // power source is the same read's ExternalConnected — never a separate IOPS read; nil (unread) is
            // NOT "on battery". The callback fires before `publishDisplay()`, so it never reads `display`.
            portPowerSource.onDeviceNotice = { [weak self, weak hud] notices in
                guard let self, let hud else { return }
                for notice in notices {
                    hud.reportDeviceNotice(notice, onBattery: self.portPowerSource.externalConnected == false,
                                           switchOn: DeviceNoticeSetting.isOn(.standard))
                }
            }

            notificationCoordinator.start(
                pipeline: pipeline, engine: engine, topUp: topUpController,
                snapshots: monitor.$snapshot.eraseToAnyPublisher(),
                reading: { [weak self] in
                    (onAC: self?.monitor.snapshot.powerSource == .ac,
                     soc: self?.monitor.snapshot.chargePercent) },
                // #29 D-5 no-double-surface: the scheduled-applied notification fires exactly when the
                // HUD would NOT (schedule outcome, user away / popover open).
                hudWouldShowSchedule: { [weak hud] in hud?.scheduleWouldShowHUD() ?? false })
        }

        monitor.start()
        // Stage 5 un-gate: register the energy daemon on launch for all users (DEFAULT, FLAGGED for the
        // owner: lazy or consented registration is the alternative). macOS shows the standard approval
        // prompt; the picker and sustained affordances guide approval. Best-effort, never crashes.
        registerHelperIfNeeded()
    }

    /// Sprint 3.7 STAGE 2: migrate away from the retired SMC helper if it still holds a registration
    /// (one-time honest notice + unregister), then register the fresh ENERGY daemon — driving
    /// `.notRegistered → .requiresApproval/.enabled` with the macOS-26 fullPath-nil mitigation — and
    /// surface the honest status. Best-effort; never crashes. (The decision logic is unit-tested via
    /// the `DaemonService` seam; the graphical status row is STAGE 5.)
    private func registerHelperIfNeeded() {
        let new = LiveDaemonService(plistName: BatteryAppIDs.helperPlistName)
        let old = LiveDaemonService(plistName: BatteryAppIDs.legacyHelperPlistName)
        // PREFLIGHT (sec 6): validate the EMBEDDED helper binary satisfies the codified helper DR (the
        // SAME string the app's XPC connection pins) before registering — refuse a mis-signed helper.
        let helperExe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/\(BatteryAppIDs.helper)").path
        let helperDR = BatteryAppIDs.helperRequirement(teamID: BatteryAppIDs.mainBundleTeamID())
        // Security posture (2026-10-15): the helper's client pin refuses an app below
        // minAppShortVersion or carrying a code-injection entitlement (get-task-allow etc.). The
        // refusal happens inside NSXPC before any reply, so on its own it would read only as "the
        // helper isn't responding". Check THIS bundle against the same string once and say why.
        let teamID = BatteryAppIDs.mainBundleTeamID()
        let appDR = BatteryAppIDs.appRequirement(teamID: teamID)
        let selfPath = Bundle.main.bundlePath
        if !BatteryAppIDs.staticCodeSatisfies(path: selfPath, requirement: appDR) {
            // Name the failing part(s): an ad-hoc / wrong-team signature fails "identity", a debuggable
            // build fails "no com.apple.security.get-task-allow" (CODE_SIGN_INJECT_BASE_ENTITLEMENTS
            // must stay NO), an old build fails the version part.
            let failing = BatteryAppIDs.appRequirementParts(teamID: teamID)
                .filter { !BatteryAppIDs.staticCodeSatisfies(path: selfPath, requirement: $0.requirement) }
                .map(\.label)
            NSLog("battery_app: THIS BUILD FAILS THE HELPER'S CLIENT PIN — the energy helper will refuse every call from it. Failing part(s): \(failing.isEmpty ? "unknown (the signature itself may be invalid)" : failing.joined(separator: "; ")). Pin: \(appDR)")
        }
        let state = HelperRegistrar.migrateAndRegister(
            old: old, new: new,
            validateNewBinary: { BatteryAppIDs.staticCodeSatisfies(path: helperExe, requirement: helperDR) },
            onMigrationNotice: { [weak self] in self?.showOneTimeMigrationNotice() },
            logger: { NSLog("battery_app: %@", $0) })
        helperHealth.applyLaunchVerdict(state)
        NSLog("battery_app: energy helper status = \(state) — \(state.guidance)")
        if state.shouldOpenLoginItems { SMAppService.openSystemSettingsLoginItems() }
        // The dev-loop trap, closed: a rebuild orphaned the running daemon's executable, so the peer pin
        // can never validate it again. Recycle it through SMAppService (no sudo) — once per launch —
        // and then prove the new process answers.
        Task { @MainActor [weak self] in
            guard let self,
                  let outcome = await helperHealth.autoRestartIfStale(logger: { NSLog("battery_app: %@", $0) })
            else { return }
            NSLog("battery_app: automatic helper restart → \(outcome)")
            await verifyHelperRestart()
        }
    }

    /// launchd starts the re-registered daemon asynchronously: re-probe the image and ping a moment later
    /// so the surface shows the NEW process and a real round trip, not the pre-restart snapshot.
    func verifyHelperRestart() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        helperHealth.refresh()
        helperClient.ping()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        NSLog("battery_app: helper restart verification — daemon started \(String(describing: helperHealth.daemonImage.daemonStartedAt)) hasResponded=\(helperClient.hasResponded) unreachable=\(helperClient.helperUnreachable) lastPong=\(helperClient.lastPong)")
    }

    /// sec-6b: a once-only honest notice that the privileged helper was replaced with a safer
    /// energy-only version. Deduped via UserDefaults so it fires a single time across launches.
    private func showOneTimeMigrationNotice() {
        let key = "didShowEnergyHelperMigrationNotice"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSLog("battery_app: replaced the privileged helper with a safer energy-only version (one-time migration notice).")
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncGlyphAnimation(active: false)             // stop the shared glyph-animation timer
        keepAwakeController.releaseForTermination()   // #EI-1 MANDATORY: never leave a dangling assertion
        monitor.stop()
        scheduleRunner.stop()
        historyStore.flush()   // 4.G: quit flush seam — persist the buffered tail
    }

    /// 4.G: the chained daily-maintenance one-shot (aggregate-then-delete + retention). Reschedules
    /// itself — a self-renewing one-shot, NOT a repeating Timer (fence: no new repeating timers).
    private func scheduleHistoryMaintenance() {
        historyMaintenanceScheduler.after(24 * 3600) { [weak self] in
            guard let self else { return }
            self.historyStore.runMaintenance()
            self.scheduleHistoryMaintenance()
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = placeholderBatteryImage()  // static placeholder until the first read
            button.imagePosition = .imageTrailing      // % to the LEFT of the glyph (WI-A.1, amends WI-1.4)
            button.title = "…"
            button.target = self
            button.action = #selector(statusItemClicked)   // primary (left) click → popover, unchanged
        }
        statusItem = item

        // 4.3 (SPEC sec 1/5 — the one real AppKit risk): a status-item RIGHT-click is not delivered to
        // the button action or a LOCAL monitor on this macOS — verified on-device 2026-06-13: it
        // surfaces only on a GLOBAL monitor (the system routes it outside our local event stream).
        // Assigning `statusItem.menu` to catch it also hijacks the LEFT click (and by the time
        // menuWillOpen fires, NSApp.currentEvent is an appKitDefined event, so the two clicks can't be
        // told apart). So we keep the button action for the left click (popover) and detect the right
        // click with a global monitor, SCOPED to our status-bar window's frame, then pop the menu
        // manually. The monitor fires on mouse-UP so the menu opens after the click completes: firing on
        // the .rightMouseDown opened it mid-click and the still-pending release landed in the menu's
        // tracking loop and dismissed it (the flash). Mouse-up mirrors the control-click path, which
        // reaches showQuickActionsMenu via the button action on mouse-up. The monitor reads but never
        // consumes events, and ignores anything outside our item, so no other click is stolen.
        rightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseUp]) { [weak self] _ in
            let loc = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, let window = self.statusItem?.button?.window,
                      window.frame.contains(loc) else { return }
                self.showQuickActionsMenu()
            }
        }
    }

    private func updateStatusButton(_ snapshot: BatterySnapshot) {
        guard let button = statusItem?.button else { return }
        lastSnapshot = snapshot   // #13: cache the render input so a settings change can rerender immediately
        if let pct = snapshot.chargePercent {
            let onAC = snapshot.powerSource == .ac
            // #23: the bolt follows the TRUTH pipeline (flow-based .charging) when it exists
            // (OS >= 26.4); monitoring-only mode falls back to the Phase-1 IsCharging flag —
            // which lies during ambiguous holds, so it's used ONLY where there's no pipeline.
            // #26 (4.E): the hold mark is sourced from the truth pipeline (.limitHold only); nil
            // state in monitoring-only mode → no mark.
            let state: TelemetryChargeState? = ChargeLimitSupport.isSupported ? pipeline.telemetryState : nil
            // Bolt v2 (4.E): the IOPS charging flag (snapshot.isCharging IS kIOPSIsChargingKey —
            // already exposed on the sample) drives the bolt for native-instant on, with the
            // classifier veto at lie-prone states. The flag never reaches the audited state machine.
            let chargingDisplay = MenuBarBatteryIcon.boltOn(isChargingFlag: snapshot.isCharging == true, state: state)
            let holdMark = MenuBarBatteryIcon.holdMarkOn(state: state)
            // #BOLT-TREND (owner ruling 2026-09-09 night): bolt the second power is coming in — the flag
            // above for the instant, the % trend for the climb the flag sleeps through; orange when the
            // adapter covers less than the draw (no rise, sampled pack current ≤ −350 mA on AC).
            // #POPOVER-TREND: the verdict is computed in `BatteryMonitor` (limit-vetoed) and rides the snapshot,
            // so the popover's Time / Draw / Limit rows read the very same rise the bolt does.
            let packRising = onAC && snapshot.packRising
            let packDraining = onAC && (snapshot.amperageMilliamps ?? 0) <= -350
            // #21 fully-charged display proxy (BatterySnapshot carries no FullyCharged field —
            // flagged in hand-back): genuinely full on AC.
            let fullyCharged = onAC && pct >= 100
            // #2-glyph: yellow tint in Low Power Mode — LIVE from the Phase-1.8 reader (only .low is
            // yellow; .high/.automatic/.unavailable are not). Never hardcoded false.
            let lowPower = snapshot.energyMode == .low
            // #13: the user's display-mode/style choice (defaults == today's icon+percent, native glyph).
            let prefs = glyphPreferencesStore.prefs
            let plan = GlyphDisplay.menuBarDisplayPlan(pct: pct, isChargingDisplay: chargingDisplay || packRising,
                                                       lowPower: lowPower, mode: prefs.displayMode)

            // Animate iff the keep-awake steam is actually on screen. Deliberately BEFORE the A2 gate:
            // the timer's liveness is not a "rendered pixels" concern, and an early return must never be
            // able to leave the animation armed after the badge has gone (or disarmed while it is up).
            // While it IS animating, `rerenderGlyph()` clears the key every frame, so the gate cannot
            // suppress the steam.
            // #EI-1 HONESTY: an INTERRUPTED session (the Mac slept through it) draws a COLD cup — no
            // wisps — so there is nothing to animate. Disarming here is the same statement as the
            // pixels: the steam is what reads as "actively holding", and the claim has been broken.
            syncGlyphAnimation(active: plan.showImage && keepAwakeController.isOn
                                       && !keepAwakeController.isInterrupted)

            // ENERGY (A2): skip the three AppKit assignments below when nothing visible changed. This sits
            // AFTER `lastSnapshot` is cached (above) on purpose — that cache is #13's rerender input and
            // must stay current even on a skipped frame, or a Settings change would replay a stale value.
            let key = GlyphRenderKey(pct: pct, chargingDisplay: chargingDisplay, holdMark: holdMark,
                                     fullyCharged: fullyCharged, onAC: onAC, lowPower: lowPower,
                                     keepAwake: keepAwakeController.isOn,
                                     keepAwakeInterrupted: keepAwakeController.isInterrupted,
                                     displayMode: prefs.displayMode, style: prefs.style,
                                     packRising: packRising, packDraining: packDraining)
            if key == lastGlyphKey { return }
            lastGlyphKey = key
            // TITLE — flag-5 (4.B) metric (12pt regular) kept. %-only carries the honest tint; icon+percent
            // keeps .labelColor (the glyph carries state color — don't double-signal).
            if let t = plan.title {
                let color: NSColor = { switch plan.tint { case .label: .labelColor; case .critical: .systemRed; case .lowPower: .systemYellow } }()
                button.attributedTitle = NSAttributedString(string: t, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: color])
            } else {
                button.attributedTitle = NSAttributedString(string: "")   // icon-only: clear the title cleanly
            }
            // IMAGE — hidden in %-only; otherwise the 4.B glyph (or the SF family per the style pref).
            // #EI-1: the keep-awake badge reflects OUR OWN sleep assertion (isOn = a live session) AND
            // whether that claim still holds (isInterrupted → a cold, steamless cup). Both are keyed
            // above, so a sleep-through repaints the badge instead of leaving the steam lying.
            button.image = plan.showImage
                ? MenuBarBatteryIcon.image(soc: pct, isChargingDisplay: chargingDisplay, holdMark: holdMark,
                                           fullyCharged: fullyCharged, onAC: onAC, lowPower: lowPower,
                                           keepAwake: keepAwakeController.isOn,
                                           keepAwakeInterrupted: keepAwakeController.isInterrupted,
                                           style: prefs.style,
                                           packRising: packRising, packDraining: packDraining,
                                           steamPhase: steamDriftPhase)
                : nil
            // ACCESSIBILITY — icon-only / %-only must still announce charge honestly.
            button.setAccessibilityLabel("Battery \(pct)%")
        } else {
            syncGlyphAnimation(active: false)          // no charge reading → nothing to animate
            lastGlyphKey = nil                         // A2: the placeholder is not a keyed render
            button.title = "…"
            button.image = placeholderBatteryImage()   // never a misleading empty 0% battery
            button.setAccessibilityLabel("Battery")     // #13 (self-audit): honest unknown — don't leave a stale "N%"
        }
    }

    /// #13: re-render the glyph from the cached last snapshot so a Settings change reflects immediately
    /// (no relaunch, no new timer, no NotificationCenter). No-op until the first real snapshot arrives.
    private func rerenderGlyph() {
        // A2: a Settings change alters the render WITHOUT altering the snapshot, so the gate must be
        // invalidated or the repaint would be skipped as a no-op.
        lastGlyphKey = nil
        if let s = lastSnapshot { updateStatusButton(s) }
    }

    /// Static placeholder glyph shown before the first read / when charge is nil (WI-A.2).
    private func placeholderBatteryImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: "Battery")
        image?.isTemplate = true
        return image
    }

    /// Primary status-item action: a plain left-click toggles the popover (unchanged). A control-click
    /// is a secondary gesture → the quick-actions menu (right-clicks are caught by the global monitor
    /// in setUpStatusItem; control-click arrives here as a left-click carrying the .control modifier).
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showQuickActionsMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    /// Open the popover and run the open-side refreshes (extracted so the quick-actions menu's
    /// "Show History" / "Schedule…" can reuse the exact same open path).
    private func showPopover(openTo route: [PopoverNavigator.Route] = []) {
        guard let button = statusItem?.button else { return }
        // #29 D-6 shell exception: stage the target page; popoverWillShow applies it before the popover
        // renders (reset-to-root by default; Details for the show-history deep-link).
        pendingPopoverPath = route
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // B-arc B4 — THE ROOT OPEN PAYS ONLY FOR THE ROOT. What remains here is what the root page
        // actually renders. Everything else moved to the surface that shows it, so opening the popover
        // and closing it no longer spawns `top`, `system_profiler`, `powermetrics`, two `pmset` reads and
        // the assertion inventory for views nobody looked at. Each relocated source already caches its
        // rows and publishes `isRefreshing`, so its surface renders cached values immediately and updates
        // in place — the same contract the root has always used. Moved, with their new homes:
        //   deviceSource / energySource / sustainedEnergySource / powerAdapterSource
        //                                        → BatteryPopoverView.detailsPage `.task` (Details-only)
        //   keepAwakeInventory                   → the root keep-awake EXPANSION's `.task` (#EI-1a)
        //   sleepWake / wakeBehavior read-backs  → SettingsView.automationTab `.task` — these were read
        //                                          NOWHERE in the popover (verified: zero `sleepWake.` /
        //                                          `wakeBehavior.` uses in BatteryPopoverView), so on the
        //                                          popover path they were two dead `pmset` spawns per open
        //   HighPowerCapabilityReader            → resolved once per launch (a hardware fact)
        monitor.refreshOnDemand()   // refresh diagnostics + Energy Mode so the surface isn't stale
        loginItem.refresh()         // #27: reflect a requiresApproval→enabled change made in Settings
        helperHealth.refresh()      // 5.3: reflect a post-launch helper approval so the surface isn't stale
        batteryLifetimeSource.refresh()  // #EI-2: STAYS — the ROOT battery row reads it (not Details-only)
        // B-arc follow-on: re-test helper reachability, but ONLY while the not-responding latch is set.
        // Before B4 this self-healed by accident — sustained energy's collectTaskEnergy ran on every open
        // and its success cleared the latch. Moving that fetch to Details (correctly) left the banner
        // stuck on a healthy daemon. A conditional ping restores the recovery at zero cost when healthy.
        helperClient.probeReachabilityIfLatched()
        if ChargeLimitSupport.isSupported {
            Task {                  // S-N3: popover open is a limit re-sync trigger
                if setupFlow.state != .ready { await setupFlow.checkNow() }  // self-heal check
                if setupFlow.state == .ready { await engine.sync(.popoverOpen) }
            }
        }
        // Stage 5 live wiring (un-gated): a successful mode-set re-reads the 1.8 display (honest result).
        energyModeController.onSetSucceeded = { [weak self] in self?.monitor.refreshEnergyMode() }
        energyModeController.clearTransientState()   // re-enable the picker if the helper was approved since
        Task { [energyModeController] in
            await energyModeController.resolveHighPowerAvailability(probe: HighPowerCapabilityReader.readDetailed)
        }
    }

    // MARK: - 4.3 quick-actions menu (secondary click)

    /// Snapshot the live state into the pure `QuickActionsState` the builder consumes.
    private func currentQuickActionsState() -> QuickActionsState {
        let st = setupFlow.state
        let lim: Int? = { if case .known(let v) = engine.limit { return v } else { return nil } }()
        return QuickActionsState(
            chargeControlSupported: ChargeLimitSupport.isSupported,
            setupReady: st == .ready || st == .readyDegraded,
            degraded: st == .readyDegraded,
            limit: lim,
            paused: engine.isPaused,
            topUpActive: topUpController.isInProgress,
            commandInFlight: engine.commandInFlight,   // 4.3-fix: mirror the popover's Top Up grey-out
            keepAwakeOn: keepAwakeController.isOn,      // #EI-1: active-preset checkmark + Turn Off item
            keepAwakeActiveDuration: keepAwakeController.session?.duration)
    }

    /// Build the menu fresh from live state and pop it under the status item. Used by both the
    /// right-click (global monitor) and control-click paths.
    private func showQuickActionsMenu() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }   // a menu replaces the popover (native feel)
        let menu = QuickActionsMenu.makeMenu(
            QuickActionsMenu.build(currentQuickActionsState()),
            target: self, action: #selector(performQuickAction(_:)))
        // Defer one runloop tick before the menu starts tracking. Both paths reaching here now fire on
        // mouse-up (the right-click monitor arms on .rightMouseUp, see setUpStatusItem; control-click
        // arrives via the button action), so the click is already over. Deferring keeps popUp off the
        // current event, so a still-pending release cannot land in the menu's tracking loop and flash it
        // shut, which is what a synchronous popUp from the old mouse-DOWN monitor did.
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
        }
    }

    /// The ONE action selector for every quick-actions item. Each case calls an EXISTING audited
    /// entry point — this adds no control logic, only new call sites of audited methods.
    @objc private func performQuickAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? QuickActionsMenu.Action else { return }
        switch action {
        case .setLimit(let v):
            Task { _ = await engine.userSetLimit(v) }                   // popover's Set path, source .user
        case .toggleCharging:
            Task { _ = engine.isPaused ? await engine.resume() : await engine.pause() }
        case .topUp:
            Task { await topUpController.topUp() }
        case .showHistory:
            // #29 D-6 shell exception: the show-history quick-action deep-links straight to Details (where
            // the 24-hour chart lives) via the PopoverNavigator channel. Resolves the D-3 fence STOP that
            // parked this ("the disclosure is @State private with no seam"). The menu closed the popover
            // first (showQuickActionsMenu), so this is always a fresh open.
            showPopover(openTo: [.details])
        case .openSchedule:
            // #29 D-4 (the item-3 fence carve-out): route the quick action through the router → the
            // Automation tab, which now hosts the schedule. The NSStatusItem/NSPopover hosting mechanics
            // are untouched — this is the single sanctioned AppDelegate change for D-4.
            settingsRouter.open(to: .automation)
        case .openBatterySettings:
            NSWorkspace.shared.open(OBCAdvisor.batterySettingsURL)
        case .quit:
            NSApplication.shared.terminate(nil)
        case .keepAwake(let duration):
            // #EI-1: one-tap enable from the menu uses the system-awake scope (the display-on upgrade
            // lives on the popover row). enable() is idempotent — re-picking a preset re-arms cleanly.
            keepAwakeController.enable(scope: .system, duration: duration)
        case .keepAwakeOff:
            keepAwakeController.disable()
        case .about:
            openAbout()
        }
    }

    // MARK: - #29 D-4 Settings (router-driven)

    /// The SINGLE Settings opener choke-point (A1/F3 + the item-3 carve-out). Both entry points — the
    /// popover footer gear and the `open schedule` quick action — route here through the router.
    /// Gate-0 finding (D-4b): the SwiftUI Settings *scene* can't be reliably opened/fronted from an
    /// accessory (LSUIElement) app in the background — `showSettingsWindow:` validates but never
    /// materializes a window. Hardened INSIDE this single choke-point to host `SettingsView` in an
    /// AppDelegate-managed `NSWindow` (per the gate's allowance: ownership + routing, not the verb).
    /// The router's `selection` is already set, so it opens on the requested tab on first present.
    private func openSettingsChokePoint() {
        // Accessory (LSUIElement) apps can't reliably open/front the SwiftUI Settings *scene* from the
        // background — showSettingsWindow: validates but never materializes a window. Host the SettingsView
        // in an AppDelegate-managed NSWindow instead; orderFrontRegardless works for an accessory app, and
        // the router's selection is already set so it opens on the requested tab.
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: makeSettingsView()))
            window.title = "Battery Settings"
            // #29 parity (owner pass): the mockup's settings titlebar carries only the traffic lights + a
            // CENTERED tab strip — no drawn title. macOS 26 promotes the windowed TabView's tab pill into the
            // titlebar band; a visible lead-aligned title steals that band, so the "centered" strip centers in
            // the residual region and reads right-shifted. Hiding the drawn title (as the About window already
            // does) frees the full width to center it. The string stays set for the Window menu / VoiceOver.
            window.titleVisibility = .hidden
            // #29 parity (owner pass): height is user-resizable (System Settings is); the D8 fixed 480pt WIDTH
            // is preserved by pinning min.width == max.width, so only the vertical axis moves. The floor stops
            // a useless sliver; the per-tab auto-fit still runs on open + each tab switch.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: DSMetric.settingsWidth, height: 200)
            window.contentMaxSize = NSSize(width: DSMetric.settingsWidth, height: 100_000)
            window.isReleasedWhenClosed = false
            // #29 D-6 F1: a modest initial size; resizeSettingsWindowForCurrentTab (called on open and on
            // each tab switch) sizes the window to the tab's measured NATURAL height, animated + top-anchored.
            window.setContentSize(NSSize(width: DSMetric.settingsWidth, height: 420))
            settingsWindow = window
        }
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        resizeSettingsWindowForCurrentTab(animated: false)   // #29 D-6 F1: size to the opening tab
    }

    // MARK: - #29 D-6 (5b) About

    /// Opens the About window (quick-actions "About Battery").
    ///
    /// GATE-0 RULE (mockup §Opener): probe `orderFrontStandardAboutPanel(options:)` FIRST — prefer the
    /// standard panel only if it both materializes AND can carry this content. Probed on-device for the
    /// D-6 seam: unlike `showSettingsWindow:`, the standard panel DOES materialize on this LSUIElement
    /// accessory app — but it renders Apple's fixed layout (icon · name · version · copyright) with no
    /// slot for the tagline or the custom 300pt dark card the mockup specifies. So it fails the rule's
    /// "AND can carry this content" clause on content fidelity (not on materialization). Per the rule's
    /// fallback branch, the About content lives in a proven AppDelegate-managed NSWindow +
    /// NSHostingController (lazy, reused, isReleasedWhenClosed=false); the mockup is the visual spec.
    /// Non-resizable / non-miniaturizable, close-only; transparent titlebar, no title text; Cmd-W
    /// (hosted in AboutView) and the red traffic light both close.
    private func openAbout() {
        if aboutWindow == nil {
            let hosting = NSHostingController(rootView: AboutView(onClose: { [weak self] in
                self?.aboutWindow?.performClose(nil)
            }))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]  // no .resizable/.miniaturizable
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            hosting.view.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 300, height: hosting.view.fittingSize.height))
            aboutWindow = window
        }
        aboutWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
        aboutWindow?.orderFrontRegardless()
    }

    /// Build the four-tab Settings window with the (encapsulated) controllers + models injected.
    func makeSettingsView() -> SettingsView {
        SettingsView(
            router: settingsRouter,
            glyphModel: glyphSettingsModel, notificationModel: notificationSettingsModel,
            uninstall: uninstallCoordinator, loginItem: loginItem,
            engine: engine, setupFlow: setupFlow, advisor: advisor,
            helperHealth: helperHealth, helperClient: helperClient,
            onHelperRestarted: { [weak self] in await self?.verifyHelperRestart() },
            monitor: monitor, schedule: scheduleRunner, sleepWake: sleepWakeController,
            wakeBehavior: wakeBehaviorController, autoEnergy: autoEnergyRunner,
            energyMode: energyModeController, keepAwake: keepAwakeController)
    }

    /// #29 D-6 F1: measure a tab's content height OFF-SCREEN — a width-constrained NSHostingView's
    /// fittingSize IS the grouped Form's natural height (outside a TabView it is not hidden, and it does
    /// not center/inflate the way `.fixedSize` on the in-TabView Form did). NEVER `.preferredContentSize`
    /// (it crashes on the Form's ScrollView — crash-log proven).
    private func measureTabHeight(_ tab: SettingsTab) -> CGFloat {
        let content = makeSettingsView().measurementContent(for: tab)
        let hosting = NSHostingView(rootView: content.frame(width: DSMetric.settingsWidth))
        hosting.frame = NSRect(x: 0, y: 0, width: DSMetric.settingsWidth, height: 4000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// #29 D-6 F1 (amended D8): size the Settings window to the CURRENT tab's measured content height —
    /// animated + TOP-anchored (the title bar stays put; the window grows/shrinks downward), Reduce Motion
    /// → direct set. Replaces the fixed-600 interim.
    private func resizeSettingsWindowForCurrentTab(animated: Bool) {
        guard let window = settingsWindow else { return }
        let tabBar: CGFloat = 30                          // the TabView tab-bar strip above the content
        let contentH = measureTabHeight(settingsRouter.selection) + tabBar
        let screen = window.screen ?? NSScreen.main
        let visibleH = screen?.visibleFrame.height ?? 900
        // Cap the FRAME, not the content: frameRect(forContentRect:) adds the title bar back, so the ceiling
        // must subtract it (plus a comfort margin) here. The old min(contentH, screenCap - 20) capped the
        // CONTENT and THEN added the ~28pt title bar, so the frame came out at screenCap + 8 — overflowing the
        // visible frame (the Automation "too big for the screen" bug). A tab taller than this scrolls (grouped Form).
        let margin: CGFloat = 96                          // comfort gap below the menu bar / above the Dock
        let titleBarH = window.frameRect(forContentRect: .zero).height
        let maxContentH = max(200, visibleH - margin - titleBarH)
        let target = min(contentH, maxContentH)
        let frameRect = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: DSMetric.settingsWidth, height: target))
        var frame = window.frame
        guard abs(frame.height - frameRect.height) > 1 else { return }   // no-op when unchanged
        let fixedTop = frame.maxY
        frame.size = frameRect.size
        frame.origin.y = fixedTop - frameRect.height                     // top-anchored (title bar stays put)
        // A top-anchored grow (open centers first) must never push the window bottom below the visible frame.
        if let vf = screen?.visibleFrame, frame.minY < vf.minY { frame.origin.y = vf.minY }
        window.setFrame(frame, display: true,
                        animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// #29 D-5: a coarse "the user is present" signal — system-wide input within `seconds` (default
    /// 2 min). Shortcuts intents ignore it (they always confirm); it only splits an autonomous schedule /
    /// top-up completion between the HUD (user active) and a notification (user away).
    private static func userIsActive(within seconds: Double = 120) -> Bool {
        let anyInput = CGEventType(rawValue: ~UInt32(0)) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < seconds
    }
}

// MARK: - #22 popover dismiss (NSPopoverDelegate → coordinator)

extension AppDelegate: NSPopoverDelegate {
    /// #29 D-6 shell exception: apply the staged navigation target RIGHT BEFORE the popover renders, so a
    /// reopen resets to root (default) and the show-history quick-action opens on Details — with no flash
    /// of the previous page. This is the ONE popoverWillShow hook the D-2 limitation note called for.
    func popoverWillShow(_ notification: Notification) {
        popoverNavigator.path = pendingPopoverPath
        pendingPopoverPath = []
    }
    /// Popover shown (by togglePopover) → arm the outside-click monitor AND the frontmost-app observer.
    func popoverDidShow(_ notification: Notification) {
        dismissCoordinator.didShow()
        armFrontmostAppObserver()
    }
    /// Popover closed by ANY path (outside click, status-item re-click, performClose,
    /// resign-active) → disarm exactly once.
    func popoverDidClose(_ notification: Notification) {
        dismissCoordinator.didClose()
        disarmFrontmostAppObserver()
        // ENERGY (audit A15, reproduced in a standalone harness): `NSPopover.close()` does NOT remove the
        // hosting view from its window — `contentViewController.view.window` is still a live
        // `_NSPopoverWindow` after this fires — so SwiftUI never sends `onDisappear` and never cancels the
        // Details page's `.task`. That task is a 2 s-blocking IOReport sample every ~6 s (≈30.5 CPU-s per
        // leaked hour). Because `path` was only ever reset in `popoverWillShow`, the loop kept running
        // until the NEXT open — and if the user never reopened, forever.
        //
        // Popping to root HERE is what actually cancels it: measured at ~10 ms after this callback.
        // Animations are suppressed so there is no visible pop on a popover that is already gone.
        // It also fixes a second defect: via the show-history deep-link, `popoverWillShow` assigned
        // `[.details]` over an existing `[.details]` — no change, no teardown, no restart — so the page's
        // other `.task` never re-ran and showed permanently stale values. With the path reset on close,
        // that reopen is now a genuine [] → [.details] transition.
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { popoverNavigator.path = [] }
    }

    /// #22: cmd-tab away closes the popover. FLAGGED deviation from the spec's named mechanism
    /// (NSApplication.didResignActiveNotification): this is an LSUIElement *accessory* app, so showing the
    /// status-item popover never makes us "active" — didResignActive therefore never fires (verified
    /// on-device 2026-06-10). We instead watch for ANOTHER app becoming frontmost (fires reliably on
    /// cmd-tab regardless of our active state), self-guarded so our own activation doesn't close us.
    ///
    /// B-arc B5: armed here rather than for app lifetime. Idempotent — `popoverDidShow` can only follow a
    /// `popoverDidClose`, but a double-arm would otherwise leak the first token.
    private func armFrontmostAppObserver() {
        guard frontmostAppObserver == nil else { return }
        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // Extract the Sendable bundle id BEFORE crossing into MainActor isolation (the
            // Notification itself is non-Sendable; the block already runs on the main queue).
            let activatedBundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                if activatedBundleID != Bundle.main.bundleIdentifier {
                    self.dismissCoordinator.resignActive()
                }
            }
        }
    }

    private func disarmFrontmostAppObserver() {
        guard let frontmostAppObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
        self.frontmostAppObserver = nil
    }
}

// MARK: - 5.5 Cut 2: LIVE uninstall seams (app-only glue)
//
// The coordinator + its ordering proofs are host-app-free in UninstallCoordinator.swift; these live
// conformances drive the real @MainActor engines and so are app-only (the LiveDaemonService pattern).

/// Restore the charge limit to 100% via the LIVE engine (source `.user` — the scheduler must not fight it).
@MainActor
final class LiveLimitRestoring: LimitRestoring {
    private let engine: ChargeLimitEngine
    init(engine: ChargeLimitEngine) { self.engine = engine }
    func restoreFullLimit() async -> CommandOutcome { await engine.userSetLimit(100, source: .user) }
    func waitUntilIdle() async {
        // Bounded wait for a concurrent command's `commandInFlight` to clear (the uninstall run is the
        // sole driver, so this rarely spins). 50 ms × 20 = 1 s cap; then the single retry runs regardless.
        var spins = 0
        while engine.commandInFlight && spins < 20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            spins += 1
        }
    }
}

/// Restore Energy Mode to Automatic on ALL sources via the LIVE controller. Validate first (the
/// controller's validate guard is the one path that does NOT fire the completion — a naive continuation
/// would hang), then bridge the completion to an awaitable Bool (the Energy-intent precedent).
@MainActor
final class LiveEnergyRestoring: EnergyRestoring {
    private let controller: EnergyModeController
    init(controller: EnergyModeController) { self.controller = controller }
    func restoreAutomatic() async -> Bool {
        let mode = EnergyModeValue.automatic.rawValue
        let source = EnergySource.all.rawValue
        guard EnergyModeCommand.validate(mode: mode, source: source) != nil else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            controller.setMode(mode, source: source) { result in
                if case .success = result { cont.resume(returning: true) } else { cont.resume(returning: false) }
            }
        }
    }
}

/// Clear the repeating sleep/wake schedule. Bridges the SAME privileged `SleepWakeSetter` the controller's
/// apply path uses, with sleepEnabled:false AND wakeEnabled:false — the helper's validated builder maps
/// that to `pmset repeat cancel` (verified against `SleepWakeCommand.pmsetArguments`). The setter's
/// `@Sendable` completion yields a clean awaitable Result with no `@MainActor`-capture-in-Sendable-closure
/// (which observing the controller's `@Published lastApplyStatus` would incur). The uninstall confirmation
/// already told the user the schedule will be cleared, so no per-cancel authorship confirm is needed here.
@MainActor
final class LiveScheduleClearing: ScheduleClearing {
    private let setter: any SleepWakeSetter
    init(setter: any SleepWakeSetter) { self.setter = setter }
    func clearRepeatingSchedule() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            setter.setRepeatingSleepWake(
                sleepEnabled: false, sleepHour: 0, sleepMinute: 0,
                wakeEnabled: false, wakeHour: 0, wakeMinute: 0, weekdayMask: 0) { result in
                if case .success = result { cont.resume(returning: true) } else { cont.resume(returning: false) }
            }
        }
    }
}

/// Remove the app's OWN residue: its UserDefaults domain and the user-Library dir it created. NEVER the
/// root-owned /Library state dir (that is the residue script's sudo job — see RELEASING.md §9).
@MainActor
final class LiveAppResidueRemoving: AppResidueRemoving {
    func removeAppResidue() {
        UserDefaults.standard.removePersistentDomain(forName: BatteryAppIDs.app)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("BatteryApp", isDirectory: true) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - 5.5 Cut 2: the Uninstall settings surface (app-only SwiftUI)
//
// Minimal styling — #29 restyles Settings later. A confirmation dialog lists exactly what the ordered
// teardown will do BEFORE run(); the per-step progress + the terminal panel then render the coordinator's
// published state (which is proven by UninstallCoordinatorTests).

struct UninstallSettingsView: View {
    @ObservedObject var coordinator: UninstallCoordinator
    @State private var showConfirm = false

    /// The root-owned helper state dir the residue script removes (needs sudo — not the app's to delete).
    private var rootStateDir: String { "/Library/Application Support/\(BatteryAppIDs.app)" }

    // #29 D-6 F1: no inner ScrollView / minHeight — this view is now a Section inside the General Form
    // (D-4b), which owns scrolling + insets; the removed `.frame(minHeight: 320)` was the ~145pt General
    // over-measure. The flow's taller states (running / aborted / completed) grow the window via the
    // AppDelegate's uninstall-state observer (resizeSettingsWindowForCurrentTab) — never clipped.
    var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                // #29 parity (SEAM 2): the ".headline" title + long paragraph are dropped — the Section
                // header "Uninstall" titles the block, and the idle case carries a short caption below the
                // row. VISUAL restyle only: the terminal state machine, run() flow, and the $terminal
                // window-grow observer are untouched.
                if coordinator.terminal != .notStarted {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.steps) { step in
                            HStack(alignment: .top, spacing: 8) {
                                stepIcon(step.status)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.title).font(.callout)
                                    if case .failed(let reason) = step.status {
                                        Text(reason).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                }

                switch coordinator.terminal {
                case .notStarted:
                    // #29 parity (SEAM 2): a single clean destructive-role row (trash + red label), not a
                    // bordered button, with the short explanation as a caption below (mockup idiom).
                    Button(role: .destructive) { showConfirm = true } label: {
                        Label("Uninstall Battery…", systemImage: "trash")
                            .foregroundStyle(DSColor.critical)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text("Removes the helper, restores charging to 100%, and clears the schedule before the app quits.")
                        .font(DSType.caption).foregroundStyle(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .running:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Uninstalling…").font(.callout) }
                case .aborted(_, let reason):
                    abortedPanel(reason)
                case .completed:
                    completedPanel()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .confirmationDialog("Uninstall Battery?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await coordinator.run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Battery will, in order:\n" + coordinator.steps.map { "•  \($0.title)" }.joined(separator: "\n"))
        }
    }

    @ViewBuilder private func stepIcon(_ status: UninstallCoordinator.StepStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func abortedPanel(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Uninstall stopped — Battery is still installed", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.orange).font(.callout.weight(.semibold))
            Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func completedPanel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ready to remove Battery", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green).font(.callout.weight(.semibold))
            Text("A few things are yours to finish by hand:").font(.subheadline)
            VStack(alignment: .leading, spacing: 8) {
                // Item 1 is FIRST because it is the only residue that is both materially altering and
                // effectively invisible: `pmset repeat` has one machine-wide slot and no System Settings
                // page, so a left-behind schedule keeps waking the Mac with nothing to show it. The copy
                // and both commands are pinned as testable constants on UninstallCoordinator rather than
                // living here as untestable literals (audit 2.H).
                VStack(alignment: .leading, spacing: 2) {
                    Text("1.  \(UninstallCoordinator.repeatingScheduleResidueNotice)")
                    Text(UninstallCoordinator.repeatingScheduleRecoveryCommand)
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled).padding(.leading, 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("2.  Remove the helper's state folder (it's owned by root, so it needs your password):")
                    Text("sudo scripts/uninstall-residue.sh")
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled).padding(.leading, 16)
                    Text("— which deletes \(rootStateDir)").padding(.leading, 16)
                }
                Text("3.  Delete the Battery shortcuts you created (five “Set…” + one “Get…”) in the Shortcuts app, if you no longer want them — they're your shortcuts, so Battery never touches your library.")
                Text("4.  Sleep/wake behavior (Power Nap, wake-for-network) keeps its current values — Battery never recorded a baseline to restore. Set it to taste before uninstalling, or afterward in System Settings → Battery (or with pmset).")
                Text("5.  Drag Battery.app to the Trash.")
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Quit Battery") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        }
    }
}

