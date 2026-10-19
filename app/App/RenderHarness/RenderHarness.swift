import AppKit
import SwiftUI

/// #30 R15 parity harness + spec 31 §2.5 clip gate. `Battery --render-pages <dir> [--allow-interim]` renders
/// every VARIANT (page × fixture, `variants`) offscreen in the dark appearance: a rail tab inside the FULL
/// popover (`BatteryPopoverView` with the same injected objects the AppDelegate wires, fed by the fixtures in
/// `RenderFixtures.swift`), or a self-test page. Two passes per variant, each read after the 1.4 s settle:
/// pass 1 lays the page out in its REAL frame → `<dir>/<variant>.png` and the page's INSIDE height; pass 2
/// lays it out at its `.fixedSize` NATURAL height. Both arrive through `DSPageFrame`'s environment sink
/// (Automation: its ContentHeightKey). `PageGate` turns them into verdicts, checks them against the expected
/// table, writes `<dir>/heights.txt`, and the process exits 0 (every verdict as expected), 1 (a verdict
/// differs, or an interim row without --allow-interim) or 2 (harness error). Nothing is ordered on screen.
/// Unreachable without the argument — every normal launch returns `false` on the first line.
@MainActor
enum RenderHarness {
    static let tabs: [RailTab] = [.now, .day, .energy, .health, .devices, .automation]
    static let scale: CGFloat = 2
    /// Settle time per pass: pages compute in `.task`s (the 0.5 s energy sample, the detached IOReport
    /// probe, the sleep-schedule read-back hop); the rail reader publishes after its first refresh.
    static let settle: TimeInterval = 1.4

    /// A page the harness can render: a rail tab inside the full popover, or a self-test page.
    enum RenderPage: Hashable {
        case tab(RailTab)
        case selfTest(SelfTestPage)

        /// The page column of the expected table and heights.txt ("now" … "automation", "selftest-…").
        var id: String {
            switch self {
            case .tab(let tab): "\(tab)"
            case .selfTest(let page): page.rawValue
            }
        }
    }

    struct RenderVariant: Hashable {
        let page: RenderPage
        let fixture: RenderFixture

        /// Parity and self-test renders keep their bare page name (`now.png` is what parity.sh pairs);
        /// every other fixture is suffixed and stays unpaired.
        var pngName: String {
            switch fixture {
            case .parity, .selfTest: "\(page.id).png"
            default: "\(page.id)-\(fixture.rawValue).png"
            }
        }
    }

    /// The variant axis (spec 31 §2.5). Every entry needs exactly one `PageGate.expected` row — a gap either
    /// way is a harness error (exit 2).
    static let variants: [RenderVariant] =
        tabs.map { RenderVariant(page: .tab($0), fixture: .parity) }
        + [RenderVariant(page: .tab(.now), fixture: .nowWorst),
           RenderVariant(page: .tab(.now), fixture: .nowLongLead),
           RenderVariant(page: .tab(.automation), fixture: .automationWorst),
           RenderVariant(page: .tab(.automation), fixture: .automationKeepAwake)]
        + [RenderVariant(page: .tab(.devices), fixture: .poweredOnPower),
           RenderVariant(page: .tab(.devices), fixture: .poweredOnBattery),
           RenderVariant(page: .tab(.devices), fixture: .poweredWorst),
           RenderVariant(page: .tab(.devices), fixture: .poweredWorstNotes),
           RenderVariant(page: .tab(.devices), fixture: .poweredWorstNotesAdapterOK),
           RenderVariant(page: .tab(.devices), fixture: .poweredNotesSinglePort),
           RenderVariant(page: .tab(.devices), fixture: .poweredUnread)]
        + [RenderVariant(page: .tab(.health), fixture: .healthHistoryNote)]
        + SelfTestPage.allCases.map { RenderVariant(page: .selfTest($0), fixture: .selfTest) }

    static func runIfRequested() -> Bool {
        if RenderShowcase.runIfRequested() { return true }   // `--render-showcase <dir>`: public images, no gate
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-pages"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let allowInterim = args.contains("--allow-interim")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let run = try render(into: dir, allowInterim: allowInterim)
            for p in run.paths { print(p) }
            if run.exitCode != PageGate.passExit {
                FileHandle.standardError.write(Data("clip gate: exit \(run.exitCode) — see \(dir.path)/heights.txt\n".utf8))
            }
            exit(run.exitCode)
        } catch {
            FileHandle.standardError.write(Data("render harness failed: \(error)\n".utf8))
            exit(PageGate.harnessErrorExit)
        }
    }

    // MARK: - the fixture object graph (mirrors AppDelegate's wiring, seams swapped for fixtures)

    struct Graph {
        let monitor: BatteryMonitor
        let engine: ChargeLimitEngine
        let pipeline: ChargeTelemetryPipeline
        let setupFlow: SetupFlow
        let advisor: OBCAdvisor
        let schedule: ScheduleRunner
        let loginItem: LoginItemModel
        let topUp: TopUpController
        let history: HistoryStore
        let deviceSource: DeviceBatterySource
        let phoneSource: PhoneBatterySource
        let portSource: PortPowerSource
        let energySource: EnergyImpactSource
        let energyMode: EnergyModeController
        let autoEnergy: AutoEnergyModeRunner
        let sustained: SustainedEnergySource
        let keepAwake: KeepAwakeController
        let keepAwakeInventory: KeepAwakeInventorySource
        let batteryLifetime: BatteryLifetimeSource
        let powerAdapter: PowerAdapterSource
        let sleepWake: SleepWakeScheduleController
        let wakeBehavior: WakeBehaviorController
        let helperHealth: HelperHealthModel
        let helperClient: HelperClient
        let appTerminator: FixtureAppTerminator
        let navigator: PopoverNavigator
        let settingsRouter: SettingsRouter

        func view(tab: RailTab) -> BatteryPopoverView {
            BatteryPopoverView(
                monitor: monitor, engine: engine, confirm: engine.confirm,
                pipeline: pipeline, setupFlow: setupFlow, advisor: advisor, schedule: schedule,
                loginItem: loginItem, topUp: topUp, history: history,
                deviceSource: deviceSource, phoneSource: phoneSource, portSource: portSource, energySource: energySource,
                energyMode: energyMode, autoEnergy: autoEnergy, sustained: sustained,
                keepAwake: keepAwake, keepAwakeInventory: keepAwakeInventory,
                batteryLifetime: batteryLifetime, powerAdapter: powerAdapter,
                sleepWake: sleepWake, wakeBehavior: wakeBehavior,
                helperHealth: helperHealth, helperClient: helperClient,
                appTerminator: appTerminator,
                navigator: navigator,
                settingsRouter: settingsRouter,
                renderTab: tab)
        }
    }

    static func buildGraph(historyRoot: URL, fixture: RenderFixture) async throws -> Graph {
        // An isolated defaults suite: the keyed records the pages read (adapter.last.v1, the keep-awake
        // preset, the auto-energy opt-ins) live here, never in the app's real domain.
        let suiteName = "com.example.batteryapp.render-harness"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let now = RenderFixtureClock.now
        let nowEpoch = { RenderFixtureClock.epoch }

        // `.showcase` / `.showcasePowered` (never gated) read their own calmer day ending on 64 %; every gated
        // fixture keeps 32 %.
        let showcase = fixture.isShowcase
        let soc = showcase ? RenderFixtureHistory.showcaseSoC : 32
        try RenderFixtureHistory.write(root: historyRoot, showcase: showcase)
        if fixture == .healthHistoryNote { try RenderFixtureHistory.writeUnreadableMonths(root: historyRoot) }

        // 31 §2.5: a powered fixture replaces the reader, so PowerOutDetails arrives THROUGH the monitor.
        let portFrames = RenderPortFrames.frames(for: fixture)
        let reader: PowerSourceReading = portFrames.map {
            showcase ? FixturePortFrameReader(frames: $0, onAC: false, soc: soc,
                                              timeToEmpty: RenderFixtureHistory.showcaseTimeToEmpty)
                     : FixturePortFrameReader(frames: $0, onAC: fixture == .poweredOnPower)
        }
            ?? (showcase ? FixturePowerSourceReader(soc: soc, timeToEmpty: RenderFixtureHistory.showcaseTimeToEmpty)
                         : FixturePowerSourceReader())
        let monitor = BatteryMonitor(reader: reader, energyModeReader: FixtureEnergyModeReader())
        let runner = FixtureShortcutRunner(readBack: showcase)
        let engine = ChargeLimitEngine(runner: runner, captureStore: FixturePauseCaptureStore(),
                                       custodyStore: FixtureCustodyStore())
        let advisor = OBCAdvisor()
        let pipeline = ChargeTelemetryPipeline(engine: engine, advisor: advisor)
        let setupFlow = SetupFlow(runner: runner, preflightProbe: { .granted }, defaults: defaults)
        let schedule = ScheduleRunner(engine: engine, store: FixtureScheduleStore(), clock: FixtureScheduleClock(),
                                      pacer: FixtureSchedulePacer(), isSetupReady: { true })
        let topUp = TopUpController(engine: engine,
                                    reading: { TopUpController.Reading(soc: soc, onAC: false) },
                                    store: FixtureTopUpStore(), now: { now })
        let history = HistoryStore(root: historyRoot, now: nowEpoch)
        // The notes worst case also has the wireless card's OWN note: a failed IOPS read (the longest real reason) whose
        // ioreg fallback still produced rows (the fixture probe, never the real `ioreg`).
        let deviceSource = DeviceBatterySource(
            reader: FixtureAccessoryReader(
                wiredScenario: fixture == .poweredOnPower || fixture == .poweredOnBattery || fixture == .showcasePowered,
                unavailableReason: fixture.hasWirelessNotes ? "this macOS build does not export IOPSCopyPowerSourcesByType" : nil),
            probe: FixtureIoregProbe(sixDevices: fixture == .poweredNotesSinglePort),
            // "as of 13:20" on the gated pages; the showcase reads "as of 13:21", the moment every other page shows.
            now: { RenderFixtureClock.epoch - (showcase ? 0 : 60) })
        let energySource = EnergyImpactSource(sampler: FixtureEnergySampler(), nameResolver: FixtureNameResolver(),
                                              intervalMilliseconds: 20, now: nowEpoch)
        let energyMode = EnergyModeController(setter: FixtureEnergyModeSetter())
        defaults.set(true, forKey: "autoEnergyModeEnabled")
        defaults.set(true, forKey: "autoEnergyHighWhenPluggedEnabled")
        // The worst cases need an energy auto-note: plugged + consented + High available → auto drives High
        // and says so (a failed drive says so too). Parity keeps the mockup's quiet state.
        let plugged = fixture.isWorstCase
        let autoEnergy = AutoEnergyModeRunner(
            setter: energyMode,
            conditions: {
                AutoEnergyConditions(thermal: .nominal, soc: soc, plugged: plugged, highAvailable: plugged,
                                     currentSourceMode: .automatic, inactiveSourceMode: .unavailable)
            },
            defaults: defaults)
        let sustained = SustainedEnergySource(collector: FixtureTaskEnergyCollector())
        let presetStore = KeepAwakePresetStore(defaults: defaults)
        presetStore.save(KeepAwakePreset(duration: .timed(3600), scope: .system))
        let keepAwake = KeepAwakeController(assertion: FixtureSleepAssertion(), scheduler: LiveOneShotScheduler(),
                                            clock: LiveMonotonicClock(), sleepTimerReader: FixtureSleepTimerReader(),
                                            presetStore: presetStore)
        let keepAwakeInventory = KeepAwakeInventorySource(inventory: FixtureAssertionInventory())
        let batteryLifetime = BatteryLifetimeSource(reader: FixtureLifetimeReader())
        let adapterStore = AdapterLastStore(defaults: defaults)
        adapterStore.save(LastAdapterRecord(watts: 94, voltage_mV: 20_000, current_mA: 4_700, activePdIndex: 3,
                                            ts: RenderFixtureClock.epoch - 3 * 86_400, ladderCount: 5))
        let adapterState: PowerAdapterReadState = switch fixture {
        case .poweredOnPower, .poweredWorstNotesAdapterOK, .poweredNotesSinglePort: .connected(PowerAdapter(watts: 65, voltage_mV: 20_000, current_mA: 3_250))
        case .poweredWorst: .unavailable("the adapter details could not be read")   // the page's note (worst case)
        // The LONGEST real reason (PowerAdapter.resolve, 93 characters): two lines at the page's 10.5 pt note.
        case .poweredWorstNotes:
            .unavailable("neither the adapter wattage nor the external-power flag resolved at any layout this app knows")
        default: .noAdapter
        }
        let powerAdapter = PowerAdapterSource(reader: FixtureAdapterReader(state: adapterState), lastStore: adapterStore,
                                              now: { now })
        let sleepWake = SleepWakeScheduleController(
            setter: FixtureSleepWakeSetter(result: fixture.isAutomationWorstCase ? .failure(.unreachable) : .success("ok")),
            reader: FixtureSleepScheduleReader(), store: FixtureSleepWakeStore())
        let wakeBehavior = WakeBehaviorController(setter: FixtureWakeBehaviorSetter(), reader: FixtureWakeBehaviorReader())
        // Now's worst case: the longest helper guidance (a sticky verdict `refresh()` preserves) → a 2-line banner.
        let helperHealth = HelperHealthModel(service: FixtureDaemonService(),
                                             launchVerdict: (fixture == .nowWorst || fixture == .nowLongLead) ? .signatureMismatch : .enabled,
                                             probe: FixtureDaemonProbe())
        let helperClient = HelperClient()
        let loginItem = LoginItemModel(service: FixtureLoginItemService(), defaults: defaults)

        // Bring the graph to the state a shown popover sees: the monitor's first read, the setup check
        // (five Set shortcuts, no Get → .readyDegraded → the "· as set" custody tag), the lifetime read.
        // 31 §2.5: the port source is fed THROUGH the monitor's own reader, like the app (the base fixture
        // carries no PowerOutDetails, so the section stays hidden and the parity pages are unchanged). ONE
        // fixed clock pair serves the port source AND the phone source: `PhoneLink.readAt` (the phone source's
        // clock) is compared with the port source's stamps, so the two must read the same clock.
        let clocks = MonotonicClocks(monotonicRaw: { portFrames?.monotonic ?? 1_000 },
                                     uptimeRaw: { (portFrames?.monotonic ?? 1_000) - 100 })
        let usb: any USBLeafEnumerating = portFrames.map { FixturePortLeafEnumerator(frames: $0) } ?? EmptyUSBLeafEnumerator()
        let portSource = PortPowerSource(defaults: defaults, now: { RenderFixtureClock.now },
                                         clocks: clocks, usb: usb, osBuild: { "render-harness" })
        monitor.addDiagnosticsSubscriber { read in portSource.ingest(read) }
        monitor.start()
        // Serve the remaining frames before the settle: the pack average and the timing match both need a
        // previous read.
        if let portFrames { for _ in 1..<portFrames.count { monitor.refreshOnDemand() } }
        await setupFlow.checkNow()
        // The showcase is `.ready`: the popover-open read-back the AppDelegate runs in that state.
        if showcase, setupFlow.state == .ready { await engine.sync(.popoverOpen) }
        batteryLifetime.refresh()

        // Icon + rail seams on the views themselves (the static hooks the harness is allowed to set).
        PowerDrawers.identityResolver = LiveDrawerIdentityResolver(icons: FixtureAppIconProvider(),
                                                                   paths: FixtureProcessPathProvider())
        BatteryPopoverView.componentPowerSampler = FixtureComponentPowerSampler()

        return Graph(monitor: monitor, engine: engine, pipeline: pipeline, setupFlow: setupFlow, advisor: advisor,
                     schedule: schedule, loginItem: loginItem, topUp: topUp, history: history,
                     deviceSource: deviceSource,
                     // #iPhone: the mock has no phone row — a fixture that finds nothing keeps parity byte-stable.
                     // Per fixture, see `phoneResult(for:)`.
                     phoneSource: PhoneBatterySource(
                         sync: FixedPhoneSyncReader(result: phoneResult(for: fixture)),
                         beacon: FixedPhoneBeaconBrowser(), now: nowEpoch, clocks: clocks),
                     portSource: portSource,
                     energySource: energySource, energyMode: energyMode,
                     autoEnergy: autoEnergy, sustained: sustained, keepAwake: keepAwake,
                     keepAwakeInventory: keepAwakeInventory, batteryLifetime: batteryLifetime,
                     powerAdapter: powerAdapter, sleepWake: sleepWake, wakeBehavior: wakeBehavior,
                     helperHealth: helperHealth, helperClient: helperClient, appTerminator: FixtureAppTerminator(),
                     navigator: PopoverNavigator(), settingsRouter: SettingsRouter())
    }

    /// The phone's sync answer per fixture. The powered fixtures put the iPhone on a USB cable; the unread one has none
    /// (its page is about the port read failing); the notes worst case has a FAILED read — the only state in which
    /// the page shows a phone note (`PhoneBatteryModel.note`: a sync reading always wins over a note, so a phone row
    /// under "Powered by this Mac" and a phone note never appear together in production).
    static func phoneResult(for fixture: RenderFixture) -> PhoneSyncResult {
        switch fixture {
        case .poweredOnPower, .poweredOnBattery, .poweredWorst, .showcasePowered:
            .reading(PhoneSyncReading(name: "iPhone", productType: "iPhone18,2",
                                      percent: fixture == .poweredWorst ? 33 : 88, charging: true,
                                      externalConnected: true, viaWiFi: false, viaUSB: true))
        case .poweredWorstNotes, .poweredWorstNotesAdapterOK, .poweredNotesSinglePort:
            .unavailable("MobileDevice framework not available on this macOS")   // the longest real sync reason
        default:
            .noDevice
        }
    }

    /// Build a fixture graph on the main actor, drive it into its worst case, and pump the run loop until it
    /// lands. A build that throws, times out, or fails a worst-case promise is a harness error.
    static func awaitGraph(historyRoot: URL, fixture: RenderFixture) throws -> Graph {
        var graph: Graph?
        var buildError: Error?
        let build = Task { @MainActor in
            do {
                let g = try await buildGraph(historyRoot: historyRoot, fixture: fixture)
                try await applyWorstCase(fixture, g)
                graph = g
            } catch { buildError = error }
        }
        pump(until: { build.isCancelled || graph != nil || buildError != nil }, limit: 30)
        if let buildError { throw buildError }
        guard let graph else { throw HarnessError.timeout("fixture graph \(fixture.rawValue)") }
        return graph
    }

    /// Spec 31 §2.5 worst cases: drive the graph's REAL controllers (no view-side fakes) into the states the
    /// fixture promises, then check every promise. A worst case that silently renders the parity state would
    /// make the gate measure the wrong page, so a broken promise fails the run (exit 2).
    static func applyWorstCase(_ fixture: RenderFixture, _ g: Graph) async throws {
        switch fixture {
        case .parity, .selfTest:
            return
        case .showcase, .showcasePowered:
            try promise(fixture, "verified read-back (no degraded banner)",
                        g.setupFlow.state == .ready && g.engine.syncProblem == nil)
        case .nowWorst:
            g.keepAwake.enable(scope: .system, duration: .timed(3600))
            await g.keepAwake.refreshSleepTimers()
            g.keepAwake.systemWillSleep()                  // → the interruption note
            _ = await g.engine.pause()                     // → the pause caveat (SoC 32 < 80: the floor caveat)
            if g.engine.isPaused { _ = await g.topUp.topUp() }   // refused while paused → the Top Up note
            await g.energyMode.resolveHighPowerAvailability(probe: { .unknown("the capability read was cut short") })
            g.autoEnergy.evaluate()
            try promise(fixture, "keep-awake session", g.keepAwake.isOn)
            try promise(fixture, "keep-awake interruption", (g.keepAwake.session?.sleepInterruptions ?? 0) > 0)
            try promise(fixture, "sleep timers read (live-effect note)", g.keepAwake.sleepTimers != nil)
            try promise(fixture, "two-line banner", g.helperHealth.registration == .signatureMismatch)
            try promise(fixture, "pause caveat or Top Up note", g.engine.pauseCaveat != nil || g.topUp.note != nil)
            try promise(fixture, "High Power note", g.energyMode.highPowerNote != nil)
            try promise(fixture, "auto note (not a hold)", g.autoEnergy.autoNote != nil && !g.autoEnergy.isHolding)
        case .nowLongLead:
            // G-9: the lead is a LONG command outcome — the one lead the interruption-led worst case never
            // shows. A scheduled Set whose verify never saw the limit reached: the longest command sentence
            // (`neverReachedLimit`) plus the "Scheduled: " prefix. No interruption, no pause caveat.
            g.keepAwake.enable(scope: .system, duration: .timed(3600))
            await g.keepAwake.refreshSleepTimers()
            _ = await g.engine.userSetLimit(80, source: .schedule)
            g.engine.confirm.commandFailed(.confirmInconclusive(.neverReachedLimit), at: 0)
            await g.energyMode.resolveHighPowerAvailability(probe: { .unknown("the capability read was cut short") })
            g.autoEnergy.evaluate()
            try promise(fixture, "keep-awake session, uninterrupted",
                        g.keepAwake.isOn && (g.keepAwake.session?.sleepInterruptions ?? 0) == 0)
            try promise(fixture, "no pause caveat", g.engine.pauseCaveat == nil)
            try promise(fixture, "scheduled long command outcome",
                        g.engine.lastCommandSource == .schedule
                            && g.engine.confirm.status == .confirmInconclusive(.neverReachedLimit))
            try promise(fixture, "two-line banner", g.helperHealth.registration == .signatureMismatch)
            try promise(fixture, "High Power note", g.energyMode.highPowerNote != nil)
            try promise(fixture, "auto note (not a hold)", g.autoEnergy.autoNote != nil && !g.autoEnergy.isHolding)
        case .poweredOnPower, .poweredOnBattery:
            try promise(fixture, "three named wired rows",
                        g.portSource.display.rows.map(\.name) == ["iPhone", "T7 Shield", "Magic Keyboard"])
            try promise(fixture, "a cost line", g.portSource.display.costSentence != nil)
        case .poweredWorst, .poweredWorstNotes, .poweredWorstNotesAdapterOK:
            try promise(fixture, "four unnamed ports → 3 rows + 1 more (the iPhone row joins on the page)",
                        g.portSource.display.rows.count == 3 && g.portSource.display.overflow == 1)
            try promise(fixture, "a stale frame", g.portSource.display.staleAsOf != nil)
        case .poweredNotesSinglePort:
            try promise(fixture, "one named wired row, no overflow, no caption, fresh, on battery with a cost line",
                        g.portSource.display.rows.map(\.name) == ["AirPods Max USB Audio"] && g.portSource.display.overflow == 0
                            && !g.portSource.display.oneIsPhoneCaption && g.portSource.display.staleAsOf == nil
                            && g.portSource.display.onBattery && g.portSource.display.costSentence != nil)
        case .poweredUnread:
            try promise(fixture, "an unread port read", g.portSource.display.visibility == .unread)
        case .healthHistoryNote:
            // The app's own launch step: maintenance reads the history and names what will not read.
            g.history.runMaintenance()
            try promise(fixture, "two unreadable months named, nothing else wrong",
                        g.history.unreadableAggregateMonths == Set(RenderFixtureHistory.unreadableMonths)
                            && g.history.unreadableRawDays.isEmpty && !g.history.aggregateWriteFailed)
        case .automationWorst, .automationKeepAwake:
            g.sleepWake.apply(confirmed: true)             // the fixture setter answers .unreachable → status line
            g.autoEnergy.evaluate()
            if fixture == .automationKeepAwake {
                g.keepAwake.enable(scope: .system, duration: .timed(3600))
                await g.keepAwake.refreshSleepTimers()
                g.keepAwake.systemWillSleep()
                try promise(fixture, "keep-awake session", g.keepAwake.isOn)
                try promise(fixture, "sleep timers read (live-effect note)", g.keepAwake.sleepTimers != nil)
            }
            try promise(fixture, "full schedule",
                        g.schedule.config.rules.count == ChargeScheduleConfig.maxRules
                            && g.sleepWake.config.sleepEnabled && g.sleepWake.config.wakeEnabled)
            try promise(fixture, "sleep/wake status line", g.sleepWake.lastApplyStatus == .unreachable)
            try promise(fixture, "energy auto-note", g.autoEnergy.autoNote != nil)
        }
    }

    static func promise(_ fixture: RenderFixture, _ what: String, _ holds: Bool) throws {
        if !holds { throw HarnessError.fixture("\(fixture.rawValue): \(what) not produced") }
    }

    // MARK: - rendering

    struct Run {
        let paths: [String]
        let exitCode: Int32
    }

    static func render(into dir: URL, allowInterim: Bool) throws -> Run {
        // A window that is NEVER ordered on screen: SwiftUI attaches (`onAppear` / `.task` fire) once the
        // hosting view is in a window, and `cacheDisplay` draws into our own 2× bitmap regardless.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DSMetric.popoverWidth, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        var paths: [String] = []
        var results: [PageGateResult] = []
        var shells: [CGFloat] = []
        for fixture in RenderFixture.allCases {
            let mine = variants.filter { $0.fixture == fixture }
            if mine.isEmpty { continue }
            let historyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "battery-render-harness-\(ProcessInfo.processInfo.processIdentifier)-\(fixture.rawValue)",
                isDirectory: true)
            defer { try? FileManager.default.removeItem(at: historyRoot) }
            // A fresh graph per fixture: worst cases mutate their controllers, parity must not see that.
            let graph: Graph? = fixture == .selfTest ? nil : try awaitGraph(historyRoot: historyRoot, fixture: fixture)
            for v in mine {
                let png = dir.appendingPathComponent(v.pngName)
                let inside = try pass(v, graph: graph, channel: .inside, window: window, png: png)
                let natural = try pass(v, graph: graph, channel: .natural, window: window, png: nil)
                paths.append(png.path)
                results.append(PageGateResult(page: v.page.id, fixture: fixture.rawValue,
                                              inside: inside.height, natural: natural.height,
                                              scrollCue: inside.scrollCue))
                shells.append(inside.shell)
            }
        }

        // 31 §2.2 (S5.4): the device notice's pill — a short name (the mock) and a long real one (the title
        // truncates on one line inside 320 pt).
        let hud = dir.appendingPathComponent("hud-device-notice.png")
        try snapshotDeviceNotice(to: hud)
        paths.append(hud.path)
        let hudLong = dir.appendingPathComponent("hud-device-notice-long.png")
        try snapshotDeviceNotice(to: hudLong, name: "AirPods Max USB Audio", kind: .other)
        paths.append(hudLong.path)

        let code = PageGate.exitCode(results, table: PageGate.expected, allowInterim: allowInterim)
        var lines = ["pageHeight \(Int(DSMetric.pageHeight))"]
        for (r, shell) in zip(results, shells) {
            lines.append(PageGate.line(r, table: PageGate.expected) + "\tshell \(Int(shell.rounded()))")
        }
        lines.append(PageGate.footer(results, table: PageGate.expected, allowInterim: allowInterim))
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("heights.txt"),
                                                         atomically: true, encoding: .utf8)
        return Run(paths: paths, exitCode: code)
    }

    /// The harness's end of the `DSPageFrame` channel: the page's LAST report, read after the settle.
    @MainActor final class PageMeasurementLog {
        var height: CGFloat?
        var scrollCue = false
    }

    struct PassReading {
        let height: CGFloat?
        let scrollCue: Bool
        let shell: CGFloat
    }

    /// One pass over one variant. Pass 1 (`.inside`) sizes the host to the popover as shown and writes the
    /// PNG; pass 2 (`.natural`) gives the fixed-size layout room to grow. A fresh log per pass, so a value
    /// can never leak from one variant or pass into the next.
    static func pass(_ v: RenderVariant, graph: Graph?, channel: PageMeasureChannel, window: NSWindow,
                     png: URL?) throws -> PassReading {
        let log = PageMeasurementLog()
        let sink = PageMeasurementSink(channel: channel) { height, scrollCue in
            log.height = height
            log.scrollCue = scrollCue
        }
        let root = try rootView(v, graph: graph, sink: sink)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        let startHeight: CGFloat = channel == .natural ? 900 : host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: DSMetric.popoverWidth, height: startHeight)
        host.layoutSubtreeIfNeeded()
        pump(seconds: settle)
        var shell = host.frame.height
        if let png {
            let fit = host.fittingSize
            host.frame = NSRect(x: 0, y: 0, width: DSMetric.popoverWidth, height: fit.height)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            pump(seconds: 0.2)
            try snapshot(host, to: png)
            shell = fit.height
        }
        // Read ONLY here, after the settle (and, for the PNG pass, the re-layout): `log` holds the LAST value
        // the page reported, never the first. Automation's first report is `contentHeight` 0 (its @State
        // default, before its first ContentHeightKey value) and its height is floored at 470 by
        // `.frame(minHeight:)`; a 0 — or a page that never reports — reaches `PageGate` as ≤ 0 / nil →
        // `.unmeasured` (a mismatch), so an early read can never become a false `ok`.
        let reading = PassReading(height: log.height, scrollCue: log.scrollCue, shell: shell)
        window.contentView = nil
        return reading
    }

    static func rootView(_ v: RenderVariant, graph: Graph?, sink: PageMeasurementSink) throws -> AnyView {
        switch v.page {
        case .tab(let tab):
            guard let graph else {
                throw HarnessError.fixture("\(v.page.id) × \(v.fixture.rawValue): no fixture graph")
            }
            return AnyView(graph.view(tab: tab)
                .environment(\.fixtureNow, RenderFixtureClock.now)
                .environment(\.pageMeasurement, sink))
        case .selfTest(let page):
            return AnyView(page.view
                .frame(width: SelfTestPage.pageWidth)
                .environment(\.pageMeasurement, sink))
        }
    }

    /// 31 §2.2 · the device notice's pill, rendered offscreen (the HUD panel is never ordered on screen here).
    static func snapshotDeviceNotice(to url: URL, name: String = "iPhone", kind: USBLeafKind = .iphone,
                                     fill: Bool = true) throws {
        guard let notice = DeviceNoticeComposer.compose(
            [DeviceNoticePort(name: name, kind: kind, filteredPower_mW: 9_200)], percentPerHour: 15) else {
            throw HarnessError.fixture("device notice: the composer returned nil for a one-port fixture")
        }
        let host = NSHostingView(rootView: HUDPillView(event: .devicePowerStarted(notice)))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        pump(seconds: 0.2)
        try snapshot(host, to: url, fill: fill)
        window.contentView = nil
    }

    /// Draw the hosting view into a 2× bitmap of our own (the window is never on a screen, so its backing
    /// scale is not the one we want) and write it as PNG.
    /// `fill: false` (the showcase only) leaves the ground transparent so a shaped view keeps its own outline;
    /// `scale` (the showcase's menu-bar glyphs only) renders above 2×. Both defaults are the gate's render.
    static func snapshot(_ view: NSView, to url: URL, fill: Bool = true, scale: CGFloat = RenderHarness.scale) throws {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw HarnessError.bitmap
        }
        rep.size = size
        // The popover's material background is NSPopover's, not the view's: paint the mockup's `--pop`
        // (#2a2c31) under the page so light label text is legible and the two halves share a ground.
        if fill, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor(srgbRed: 0x2a / 255, green: 0x2c / 255, blue: 0x31 / 255, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw HarnessError.bitmap }
        try data.write(to: url)
    }

    /// Run the main run loop (which also drains the main-actor task queue) for `seconds`.
    static func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    static func pump(until done: () -> Bool, limit: TimeInterval) {
        let end = Date().addingTimeInterval(limit)
        while !done() && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    enum HarnessError: Error { case bitmap, timeout(String), fixture(String) }
}
