import SwiftUI
import AppKit
import Shared             // Sprint 3.7 STAGE 5: EnergyModeValue / EnergySource for the per-source picker
import ServiceManagement // Sprint 3.7 STAGE 5: the "approve helper" affordance opens Login Items

/// Minimal telemetry popover (SPEC WI-1.5) + the Phase-2 REBUILD charge-limit surface (SPEC
/// v4.0 WI-N7). NOT the Phase 4.2 polished surface — no graphs, no customization. Nil fields
/// render as "—".
struct BatteryPopoverView: View {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var engine: ChargeLimitEngine
    @ObservedObject var confirm: BehaviorConfirm    // engine.confirm (nested objects don't republish)
    @ObservedObject var pipeline: ChargeTelemetryPipeline
    @ObservedObject var setupFlow: SetupFlow
    @ObservedObject var advisor: OBCAdvisor
    @ObservedObject var schedule: ScheduleRunner   // 4.C
    @ObservedObject var loginItem: LoginItemModel  // 4.E #27
    @ObservedObject var topUp: TopUpController      // 4.F #8
    @ObservedObject var history: HistoryStore       // 4.G #28
    @ObservedObject var deviceSource: DeviceBatterySource   // 4.H #12
    @ObservedObject var phoneSource: PhoneBatterySource     // #iPhone (2026-09-10)
    /// 31 §2.1: passed through to the Devices page ONLY. A plain `let` — the root never observes it (spec §3
    /// rule 7), so a port frame never re-renders the other pages.
    let portSource: PortPowerSource
    @ObservedObject var energySource: EnergyImpactSource    // 4.5 #19
    @ObservedObject var energyMode: EnergyModeController    // 3.7 STAGE 5: per-source mode picker
    @ObservedObject var autoEnergy: AutoEnergyModeRunner   // auto-energy-mode: opt-in policy + disclosure
    @ObservedObject var sustained: SustainedEnergySource   // 3.7 STAGE 5: sustained per-app energy
    @ObservedObject var keepAwake: KeepAwakeController      // #EI-1: in-process keep-awake
    @ObservedObject var keepAwakeInventory: KeepAwakeInventorySource  // #EI-1a: what else keeps the Mac awake
    @ObservedObject var batteryLifetime: BatteryLifetimeSource        // #EI-2: battery health / longevity
    @ObservedObject var powerAdapter: PowerAdapterSource              // #EI-3: adapter wattage ceiling
    @ObservedObject var sleepWake: SleepWakeScheduleController        // 3.7 sleep/wake STAGE 2b
    @ObservedObject var wakeBehavior: WakeBehaviorController          // 3.7 power-nap/wake STAGE 2b-ii
    @ObservedObject var helperHealth: HelperHealthModel              // 5.3: honest energy-helper registration state
    @ObservedObject var helperClient: HelperClient                  // 5.3: runtime "helper not responding" signal
    /// (1b) keep-awake terminator — a PLAIN seam (no published state). The view reads it to offer a
    /// per-holder Quit on user GUI apps. App-side AppKit ONLY — it NEVER routes through the helper / XPC.
    let appTerminator: AppTerminating

    // #29 D-4b: draftRule / editingRule / confirmingSleepWakeApply / confirmingSleepWakeCancel moved to
    // SettingsView with the schedule + sleep/wake sections they own (now on the Automation tab).
    // #29 D-4b-β2: showLimitProvenance removed — its only user (chargeLimitSection) relocated to the
    // Settings · General Charge control group (the degraded provenance detail lives there now).
    // #30 stage 10: `keepDisplayOn` / `showKeepAwakeExpansion` went with the root Keep-awake row. The Now
    // toggle enables the last-used PRESET (scope included), so the off-state live-effect preview reads
    // `keepAwake.lastPreset.scope` instead of a popover-local flag.
    // #29 D-4b: perSourceModes / pickerHoldNote moved to SettingsView with the per-source energy-mode
    // picker they own (now on the Automation tab). The Now energy-mode strip passes perSource: nil.
    /// 3.7 B2 (#19 option-2): NO-ROOT, liveness-probed component power (GPU-only today, auto-expands).
    /// View-owned so it samples only while the popover is visible (cheap; the readout is popover-only).
    @StateObject private var powerReader = ComponentPowerReader(sampler: BatteryPopoverView.componentPowerSampler ?? IOReportPowerSampler())
    /// R15 render harness seam for the view-owned rail reader (nil = the live IOReport sampler).
    static var componentPowerSampler: (any ComponentPowerSampling)? = nil

    /// sec 6: below macOS 26.4 the feature is HIDDEN — monitoring-only mode. Same gate the
    /// AppDelegate uses to keep the engine/setup/Shortcuts wiring entirely off.
    private var chargeLimitSupported: Bool { ChargeLimitSupport.isSupported }

    // MARK: - navigator + settings router (the AppDelegate-owned channels this shell reads)

    /// #29 D-6 shell exception: the navigation path is owned by the app-level PopoverNavigator so the
    /// AppDelegate can reset it to root on every popover-show (fixing the D-2 reopen-lands-on-last-page
    /// limitation) and deep-link to Details for the show-history quick-action. The view still writes it
    /// for in-view pushes/pops; nothing else does (the channel's contract lives on PopoverNavigator).
    @ObservedObject var navigator: PopoverNavigator
    /// A1/F3: the app-level Settings router (hoisted to the AppDelegate in D-4). The footer gear calls
    /// open(to: .general); the AppDelegate observes the router and opens/fronts the Settings window.
    @ObservedObject var settingsRouter: SettingsRouter
    /// D11: Reduce Motion → fades only, no movement.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - #30 · the rail shell (spec §3, §4.1, §8)

    /// The selected rail tab. View-local by ruling (red-team C3): every normal show lands on Now, so the
    /// banner slot is always seen; only the `[.details]` deep link lands on Day. Derived from the
    /// navigator path through `RailSelection` — the view never writes the path for tab changes.
    @State private var selectedTab: RailTab = .now
    /// #30 §8 page-lifetime rule (red-team B1/C2). With a rail nothing is pushed, so the AppDelegate's
    /// `path = []` on close no longer removes any view — and `NSPopover.close()` leaves the hosting view
    /// alive, so `onDisappear` never fires (the A15 leak, 30.5 CPU-s per leaked hour). Pages therefore
    /// render only while this is true; flipping it to false tears every page `.task` down at ~the same
    /// ~10 ms the old pop-to-root did. Driven by the NSPopover notifications (this app has exactly one
    /// NSPopover — the HUD is an NSPanel — so no object filter is needed) plus `onAppear` for the first
    /// show, when this view's subscriptions may not yet exist. No hosting touch, no navigator consumer.
    @State private var popoverShown = false
    /// The ONE popover whose show/close drives page lifetime. The comment above used to say "this app has
    /// exactly one NSPopover — so no object filter is needed"; since 2026-09-09 the Now tab's hover cards are
    /// SwiftUI `.popover`s (their own NSPopovers), and an unfiltered `didClose` from one of them blanked the
    /// page (owner, 2026-09-10: "look at it for a sec or two — it goes blank"). `BatteryApp` sets this; nil
    /// (tests, the render harness) accepts every popover as before.
    @MainActor static weak var mainPopover: NSPopover?
    private static func isMain(_ n: Notification) -> Bool {
        guard let main = mainPopover else { return true }
        return (n.object as? NSPopover) === main
    }

    // #30 R15 render harness (app/App/RenderHarness, argument-gated `--render-pages`): when non-nil the
    // shell treats itself as shown and pins this tab, so an offscreen NSHostingView renders a page
    // without an NSPopover. nil (the default, every normal launch) leaves the shell byte-for-byte as before.
    // Measurement is not the shell's job: each page reports through `DSPageFrame` (spec 31 §2.5).
    var renderTab: RailTab? = nil

    /// Spec 31 §2.6: the render harness pins the clock (`RenderFixtureClock.now`); nil in every normal launch.
    @Environment(\.fixtureNow) private var fixtureNow
    private var clockNow: Date { fixtureNow ?? Date() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DSMetric.railGap) {
                PopoverRail(selected: $selectedTab)
                Group {
                    if popoverShown { page(for: selectedTab) } else { Color.clear }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(height: DSMetric.pageHeight)
            .padding(DSMetric.popoverInset)
            Divider().padding(.horizontal, DSMetric.popoverInset).padding(.top, -2)
            DSFooterBar(
                onSettings: { settingsRouter.open(to: .general) },
                onQuit: { NSApplication.shared.terminate(nil) })
        }
        .frame(width: DSMetric.popoverWidth)
        .onAppear { popoverShown = true; selectedTab = renderTab ?? RailSelection.tab(for: navigator.path) }
        .onChange(of: navigator.path) { _, path in selectedTab = RailSelection.tab(for: path) }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { n in
            guard Self.isMain(n) else { return }
            popoverShown = true
            selectedTab = RailSelection.tab(for: navigator.path)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { n in
            guard Self.isMain(n) else { return }
            popoverShown = false
        }
    }

    // MARK: - #30 · Now page (spec §4.2, round-4 N2b) — stage 3

    /// Today's account (spec §5), computed from the store's rows when the page appears and again when
    /// the store flushes; pure `HistoryMetrics`, ~1,500 raw rows, sub-millisecond — run on the main
    /// actor because the store is. `nil` until the first computation (renders "—", never a fabricated 0).
    @State private var nowToday: HistoryMetrics.TodayAccount?
    /// "at a limit N awake h since <first aggregate>" — stitched over every aggregate month + the raw days.
    @State private var nowLimitHoldHours: Int?
    /// The Now page's app icons, resolved once per energy sample (never per render).
    /// The shared "who is drawing power" ranking (`PowerDrawers.current` — the SAME list the Energy tab
    /// shows in full; owner ruling 2026-09-09 evening). Resolved once per input change, never per render.
    @State private var nowDrawers: [PowerDrawersModel.Drawer] = []
    /// The strip icon under the pointer (owner, 2026-09-09 night: "when I hover over an app show the name").
    /// Drives a floating hover card — `.help` tooltips take a second and are unreliable in a popover.
    @State private var hoveredNowDrawer: PowerDrawersModel.Drawer?
    /// The folded notes' card (G-8 option F): open while the pointer is on the rest line, or after a tap
    /// until it is dismissed. Two flags so a hover-out does not close a card the user pinned by tapping.
    @State private var nowNotesHover = false
    @State private var nowNotesPinned = false

    private func recomputeNowMetrics() {
        // The store read lives in `NowHistoryFigures` (app/History) so the suite can run it on a real store.
        let m = NowHistoryFigures.compute(history: history, clock: clockNow, calendar: .current)
        nowToday = m.today
        nowLimitHoldHours = m.limitHoldHours
    }

    /// The first five of the shared ranking — no "real image only" filter: a helper process shows its
    /// parent app's icon and a daemon its category symbol, so the strip and the Energy tab always agree.
    private var nowStripRows: [PowerDrawersModel.Drawer] {
        Array(nowDrawers.prefix(PowerDrawersModel.nowStripCount))
    }

    private var nowDrawersSource: PowerDrawersModel.Source {
        PowerDrawers.source(energySource: energySource, sustained: sustained)
    }

    @ViewBuilder private var nowPage: some View {
        let s = monitor.snapshot
        let banner = activeBanner
        // Owner ruling 2026-09-09 evening ("everything feels compacted to the top"): the page is 297 × 470 and
        // DISTRIBUTES its blocks down the frame — flexible Spacers between blocks share the leftover height,
        // like the mock's space-between column; never one trailing spacer with dead space under it.
        // The mock's Now page is a space-between column of EIGHT flex children — hero · today label · strip ·
        // Wh row · "Who spent it" · app strip · controls card · closing line — with seven EQUAL gaps. Owner,
        // 2026-09-09 22:19, side by side: "the spacing for everything … look nothing alike" against the
        // fixed-gap build. So: one flexible Spacer between every child, nothing else.
        VStack(alignment: .leading, spacing: 0) {
            if let banner {
                rootBanner(banner).lineLimit(2)
                Spacer()
            }
            nowHero(s)
            Spacer()
            nowTodayLabelRow
            Spacer()
            nowStrip
            Spacer()
            nowWhRow
            Spacer()
            DSSectionLabel(title: "Who spent it", caption: whoSpentItCaption)
            Spacer()
            nowAppsStrip
            Spacer()
            nowControlsCard
            nowHonestyLines
            Spacer()
            // §14-U3: the frame never moves, so when a banner is present the lowest-value line yields.
            if banner == nil { nowClosingLine }
        }
        .dsPageFrame(.maxHeight, alignment: .center)
        .task {
            // Page lifetime: this task runs only while the popover is shown and Now is selected (§8).
            recomputeNowMetrics()
            sustained.refresh()   // the shared ranking prefers the helper's coalition list when it delivers
            if energySource.apps.isEmpty { await energySource.fetch() }
        }
        .task(id: PowerDrawers.key(energySource: energySource, sustained: sustained)) {
            nowDrawers = PowerDrawers.current(energySource: energySource, sustained: sustained)
        }
        .onReceive(history.$recordingSince) { _ in recomputeNowMetrics() }   // a flush republishes the store
    }

    // hero: 70 pt ring, numeral 20 pt inside; Time · Draw · Limit rows at 12 pt

    @ViewBuilder private func nowHero(_ s: BatterySnapshot) -> some View {
        let fraction = min(max(CGFloat(s.chargePercent ?? 0) / 100, 0), 1)
        let limit = heroLimit(s)
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().stroke(DSSurface.line, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(heroColor(s), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: fraction)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(s.chargePercent.map(String.init) ?? "—")
                        .font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundStyle(DSSurface.text)
                        .contentTransition(.numericText())
                    Text("%").font(.system(size: 12, weight: .medium)).foregroundStyle(DSSurface.text2)
                }
                .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: 60)
            }
            .padding(.leading, 3)              // the stroke is centred on the circle; without this inset the
            .frame(width: 85, height: 82)      // left edge was clipped by the page (owner, 2026-09-09)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(s.chargePercent.map { "\($0) percent" } ?? "Charge unknown")
            VStack(spacing: 0) {
                nowStatRow("Time", HeroStats.timeText(onAC: s.powerSource == .ac, chargePercent: s.chargePercent,
                                                       limit: heroLimitValue, amperageMilliamps: s.smoothedAmperageMilliamps,
                                                       fullChargeCapacity_mAh: s.fullChargeCapacity_mAh,
                                                       minutesToEmpty: s.minutesToEmpty, isCharging: s.isCharging,
                                                       packRising: s.packRising, packInflowMilliamps: s.packInflowMilliamps))
                Divider()
                nowStatRow("Draw", nowDrawText(s))
                Divider()
                nowStatRow("Limit", nowLimitText(limit.text), tint: limit.holding ? DSColor.charging : nil)
            }
        }
    }

    private func nowStatRow(_ key: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 12)).foregroundStyle(DSSurface.text2)
            Spacer(minLength: DSMetric.space2)
            Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(tint ?? DSSurface.text)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    /// "−27.8 W · battery" / "+45.2 W · power": the pack figure, signed, plus the source word (the pack
    /// ≈ the system only while on battery — §14-D6).
    private func nowDrawText(_ s: BatterySnapshot) -> String {
        // #POPOVER-TREND: through a stale macOS 27 "draining" frame while the pack climbs, the pack's
        // measured inflow — never the stale negative figure (see `HeroStats.drawMilliamps`).
        let mA = HeroStats.drawMilliamps(onAC: s.powerSource == .ac, packRising: s.packRising,
                                         sampledMilliamps: s.amperageMilliamps,
                                         packInflowMilliamps: s.packInflowMilliamps)
        let w = WattageReadout.compact(voltageVolts: s.voltageVolts, amperageMilliamps: mA) ?? "—"
        switch s.powerSource {
        case .ac: return "\(w) · power"
        case .battery: return "\(w) · battery"
        case .unknown: return w
        }
    }

    /// The Limit row + schedule provenance (C5): "80% · as set · next 07:30→100". Overflow order (§14-U13):
    /// the provenance is dropped first (the row is single-line, tail-truncated), custody second.
    private func nowLimitText(_ base: String) -> String {
        guard let next = ChargeSchedule.upcomingLine(now: clockNow, calendar: .current, config: schedule.config) else { return base }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "\(base) · next \(f.string(from: next.date))→\(next.rule.limit)"
    }

    // today strip (§4.2): awake hours on each source, the day as runs, Wh out / in, the day's low

    /// "Today · while awake" | "4 h 36 m on battery · 4 h 40 m on power" (mock .rowsm padding 0 0 3px, 11 px).
    private var nowTodayLabelRow: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text("Today").foregroundStyle(DSSurface.text2) + Text(" · while awake").foregroundStyle(DSSurface.text3))
                .font(.system(size: 11))
            Spacer(minLength: 4)
            Text(nowToday.map { "\(Self.hm($0.awakeOnBattery_s)) on battery · \(Self.hm($0.awakeOnPower_s)) on power" } ?? "—")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(DSSurface.text2).lineLimit(1)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// "108 Wh out · 83 Wh in" | "low 1% at 06:52" (mock .rowsm padding 3px 0 10px, 11 px).
    private var nowWhRow: some View {
        HStack(alignment: .firstTextBaseline) {
            if let t = nowToday {
                (Text("\(Int(t.whOut.rounded())) Wh").fontWeight(.semibold).foregroundStyle(DSSurface.text)
                 + Text(" out   ").foregroundStyle(DSSurface.text2)
                 + Text("\(Int(t.whIn.rounded())) Wh").fontWeight(.semibold).foregroundStyle(DSSurface.text)
                 + Text(" in").foregroundStyle(DSSurface.text2))
                    .font(.system(size: 11).monospacedDigit())
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(DSSurface.text2)
            }
            Spacer(minLength: 4)
            if let low = nowToday?.lowest, let tone = HeroStats.dayLowTone(soc: low.soc) {
                let f = DateFormatter(); let _ = f.dateFormat = "HH:mm"
                Text("low \(low.soc)% at \(f.string(from: low.ts))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(tone == .critical ? DSColor.critical : DSSurface.text2)   // D1B: red only at ≤ 20 %
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The local day as proportional runs: blue on power, green on battery, hatched-neutral asleep,
    /// faint for the hours still to come (§14-D5: asleep is a third state, never "on battery").
    private var nowStrip: some View {
        GeometryReader { g in
            let runs = nowToday?.strip ?? []
            let total = max(1.0, runs.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) })
            HStack(spacing: 1) {
                if runs.isEmpty {
                    Rectangle().fill(DSSurface.control)
                } else {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, r in
                        let w = max(0, g.size.width * r.end.timeIntervalSince(r.start) / total)
                        Rectangle().fill(nowStripStyle(r.state)).frame(width: w)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            // Owner, 2026-09-10: "add like 4 equal hours — I want to know timing on that line chart".
            // The strip is the local day (midnight → midnight), so quarter ticks are 6 h apart.
            .overlay {
                ForEach(1..<4, id: \.self) { q in
                    Rectangle().fill(DSSurface.ground.opacity(0.9)).frame(width: 1)
                        .position(x: g.size.width * CGFloat(q) / 4, y: 4)
                }
            }
        }
        .frame(height: 8)
        .overlay(alignment: .bottom) {
            DSHourAxis().offset(y: DSHourAxis.height)
        }
        .padding(.bottom, DSHourAxis.height)   // room for the hour labels
    }

    private func nowStripStyle(_ st: HistoryMetrics.StripState) -> AnyShapeStyle {
        switch st {
        case .battery: AnyShapeStyle(DSColor.charging)
        case .power:   AnyShapeStyle(DSColor.onPower.opacity(0.6))
        case .asleep:  AnyShapeStyle(DSColor.holding.opacity(0.35))
        case .future:  AnyShapeStyle(DSSurface.control)
        }
    }

    /// "4 h 36 m" / "12 m" / "0 m"
    private static func hm(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h) h \(m) m" : "\(m) m"
    }

    // who spent it: five real app icons + a share strip (share = energy / Σ readable, §14-D7)

    private var whoSpentItCaption: String {
        PowerDrawersModel.caption(for: nowDrawersSource)
    }

    /// The hover card (owner, 2026-09-09 night: "can a window hover occur?" — a floating card, not an
    /// inline caption swap): icon · name · helper subtitle · share, anchored above the icon.
    @ViewBuilder private func nowHoverCard(_ d: PowerDrawersModel.Drawer) -> some View {
        HStack(spacing: 8) {
            nowAppIcon(d.icon).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.displayName).font(.system(size: 12, weight: .semibold))
                if let sub = d.subtitle {
                    Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Text(EnergyPageModel.percentText(d.share)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    @ViewBuilder private var nowAppsStrip: some View {
        let rows = nowStripRows
        // Owner, 2026-09-09 night: the share bar sits UNDER the icons, full width, with its legend —
        // the icons are the "who", the bar the "how much", stacked left→right in the same order.
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if rows.isEmpty {
                    Text(energySource.isRefreshing || sustained.isRefreshing ? "Sampling…" : "No apps drew measurable power in the sample")
                        .font(.system(size: 11)).foregroundStyle(DSSurface.text3)
                }
                ForEach(rows) { row in
                    nowAppIcon(row.icon)
                        .frame(width: 28, height: 28)
                        .help(row.subtitle.map { "\(row.displayName) · \($0)" } ?? row.displayName)
                        .accessibilityLabel("\(row.displayName), \(EnergyPageModel.percentText(row.share))")
                        .onHover { inside in hoveredNowDrawer = inside ? row : (hoveredNowDrawer?.id == row.id ? nil : hoveredNowDrawer) }
                        .popover(isPresented: Binding(get: { hoveredNowDrawer?.id == row.id },
                                                      set: { if !$0, hoveredNowDrawer?.id == row.id { hoveredNowDrawer = nil } }),
                                 arrowEdge: .top) { nowHoverCard(row) }
                }
            }
            .frame(height: 28)
            if !rows.isEmpty {
                let top = min(1, rows.reduce(0) { $0 + $1.share })
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { g in
                        HStack(spacing: 1) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                                Rectangle().fill(DSColor.charging.opacity([1, 0.9, 0.78, 0.62, 0.45][min(i, 4)]))
                                    .frame(width: max(0, g.size.width * row.share))
                            }
                            Rectangle().fill(DSSurface.text.opacity(0.2))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .frame(height: 8)
                    HStack {
                        Text("these \(rows.count) · \(EnergyPageModel.percentText(top))")
                            .foregroundStyle(DSColor.charging.opacity(0.9))
                        Spacer(minLength: 4)
                        Text("everything else · \(EnergyPageModel.percentText(max(0, 1 - top)))")
                            .foregroundStyle(DSSurface.text3)
                    }
                    .font(.system(size: 9.5).monospacedDigit())
                    .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("These \(rows.count) apps used \(EnergyPageModel.percentText(top)) of the sample")
            }
        }
    }

    @ViewBuilder private func nowAppIcon(_ choice: AppIconChoice) -> some View {
        switch choice {
        case .image(let img):
            Image(nsImage: img).resizable().interpolation(.high).frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .symbol(let name):
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DSSurface.control)
                .overlay(Image(systemName: name).font(.system(size: 13)).foregroundStyle(DSSurface.text2))
        }
    }

    // controls card (R10 + §14-C9): limit strip · Pause · Top up   /   energy strip · Keep awake · switch

    @ViewBuilder private var nowControlsCard: some View {
        let s = monitor.snapshot
        let source: EnergySource = (s.powerSource == .ac) ? .charger : .battery
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                DSStrip(selection: limitSelectionBinding,
                        pairs: ChargeShortcuts.validLimitValues.map { ($0, "\($0)") },
                        isEnabled: chargeLimitSupported && !engine.commandInFlight)
                DSTextAction(title: engine.isPaused ? "Resume" : "Pause") {
                    Task { _ = engine.isPaused ? await engine.resume() : await engine.pause() }
                }
                .fixedSize()
                if topUp.isInProgress {
                    // the climb pill: live SoC → 100, plus its only exit (C9)
                    HStack(spacing: 3) {
                        ProgressView().controlSize(.mini)
                        Text(PopoverDetailStrings.topUpProgress(soc: topUp.soc))
                            .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(DSColor.accent)
                    }
                    if topUp.canCancel { DSTextAction(title: "Cancel", dim: true) { Task { await topUp.cancel() } } }
                } else {
                    DSTextAction(title: "Top up") { Task { await topUp.topUp() } }
                        .fixedSize()
                        .disabled(engine.isPaused)
                }
            }
            .disabled(engine.commandInFlight)
            HStack(spacing: 10) {
                DSStrip(selection: energyModeCardBinding(source: source, activeMode: s.energyMode),
                        pairs: energyMode.availableModes.map { ($0, EnergyModePresentation.label($0)) },
                        isEnabled: !(energyMode.isHelperUnreachable || energyMode.isBusy))
                    .frame(width: 120)
                Spacer(minLength: 4)
                Text("Keep awake")
                    .font(.system(size: 12)).foregroundStyle(DSSurface.text2).lineLimit(1)
                    .help("Turns on the last-used preset: \(nowPresetLabel)")
                Toggle("", isOn: Binding(
                    get: { keepAwake.isOn },
                    set: { on in
                        if on {
                            // Final review F2: the session-only re-arm (never sets aside / saves an
                            // unreadable stored preset; see KeepAwakeController.enableLastPreset).
                            keepAwake.enableLastPreset()
                            Task { await keepAwake.refreshSleepTimers() }
                        } else { keepAwake.disable() }
                    }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("Keep awake, \(nowPresetLabel)")
            }
        }
        .padding(12)
        .background(DSSurface.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// "1 h" / "30 m" / "on power" / "always" (+ "· display" when the preset keeps the display on).
    private var nowPresetLabel: String {
        let p = keepAwake.lastPreset
        let d: String
        switch p.duration {
        case .indefinite: d = "always"
        case .whileOnAC: d = "on power"
        case .timed(let t): d = t >= 3600 ? "\(Int(t / 3600)) h" : "\(Int(t / 60)) m"
        }
        return p.scope == .systemAndDisplay ? "\(d) · display" : d
    }

    /// The transient honesty notes under the controls (C9/C12/C8), folded (spec 31 stage 2 · T12 · G-8 option
    /// F, ruled by the owner 2026-09-28: "i think F. agree?"). Eight stacked two-line notes cost 610 pt at the
    /// worst case, so they now sit behind ONE line at rest: the most urgent note, in full on up to two lines,
    /// with "+N more ›" at the end of its last line when others exist; hover or tap opens a card listing every
    /// one, most urgent first (`NowNotes`). Nothing is dropped — the two keep-awake EXPLANATIONS (coverage,
    /// live effect) moved to Automation's Keep awake row instead. Renders nothing when there are no notes.
    @ViewBuilder private var nowHonestyLines: some View {
        if let summary = NowNotes.summary(nowNoteItems) {
            nowNotesRestLine(summary).padding(.top, 4)
        }
    }

    /// Every note in play, in no particular order — `NowNotes.summary` ranks them.
    private var nowNoteItems: [NowNote] {
        var items: [NowNote] = []
        // 1. Keep-awake interruption: reports work the owner has already lost — orange.
        let interruptions = keepAwake.session?.sleepInterruptions ?? 0
        if let note = KeepAwakeController.interruptionNote(interruptions) {
            items.append(NowNote(kind: .keepAwakeInterruption, text: note,
                                 rest: NowNotes.interruptionRestForm(count: interruptions)))   // G-9 (F2)
        }
        // 2. The Pause envelope — the honest limits of the sanctioned native mechanism, shown while it applies.
        //
        // SWEEP H2 amendment 2 rides this same slot, by design: when the pause was INFERRED from a
        // capture that will not decode, `engine.pauseCaveat` carries
        // `ChargeStatusStrings.pauseRestorePointLostCaveat` from launch — "Pause data unreadable — the
        // pack may still be held. Resume will set the limit to 100%." The disclosure is what the user needs
        // in order to decide whether to press Resume, so it stays in the list (and, when it is the most
        // urgent note, at rest) — never dropped by the fold.
        if let caveat = engine.pauseCaveat { items.append(NowNote(kind: .pauseCaveat, text: caveat)) }
        // 3. The last command's outcome, source-tagged ("Scheduled: " / "Top Up: " / "Shortcut: ") by the pure
        // CommandSource.statusPrefix — so an autonomous change never reads as something the user did.
        //
        // AUDIT B2: the two missable failures may have just taken the banner slot instead. Stand down
        // ONLY in that case, matched on the composed sentence — a failure that lost the slot to a helper
        // or setup banner still renders here, so the promotion can never make one disappear.
        if !ChargeHonesty.bannerAlreadyCarries(status: confirm.status,
                                               prefix: engine.lastCommandSource.statusPrefix,
                                               bannerMessage: activeBanner?.message),
           let command = ChargeStatusStrings.commandLabel(confirm.status) {
            let prefix = engine.lastCommandSource.statusPrefix
            items.append(NowNote(kind: .lastCommand, text: prefix + command,
                                 rest: NowNotes.commandRestForm(status: confirm.status, prefix: prefix)))
        }
        // B1: the calm 4-second confirmation after a permanent-degraded Set (auto-clears in BehaviorConfirm;
        // the standing truth is the "· as set" provenance tag on the hero Limit row).
        if let confirmation = confirm.transientConfirmation {
            items.append(NowNote(kind: .lastCommand, text: confirmation))
        }
        // 4. #8: the Top Up controller's own narration (why it stopped, what it reverted to) — its ONE home.
        if let note = topUp.note { items.append(NowNote(kind: .topUp, text: note)) }
        // 5. High Power availability (orange).
        if let note = energyMode.highPowerNote { items.append(NowNote(kind: .highPower, text: note)) }
        // 6. The auto-energy note, when the banner does not already carry it.
        if !autoEnergy.isHolding, let note = autoEnergy.autoNote { items.append(NowNote(kind: .autoEnergy, text: note)) }
        return items
    }

    private func nowNoteTint(_ note: NowNote) -> Color { note.isAttention ? DSColor.attention : DSSurface.text2 }

    /// The rest line: the lead note's SHORT form (G-9, "I say F2" — `NowNotes.restForm`: fits two lines,
    /// never cut mid-sentence) with the "+N more ›" chip right-aligned on its LAST line. Hover or tap opens
    /// the card, whose first entry is the lead's full text. The card is a nested `.popover` like the
    /// strip's hover cards — the page's `didClose` listener is filtered to `mainPopover`, so closing it
    /// cannot blank the page.
    ///
    /// The text flows the FULL width and reserves the chip's room only at its tail (an invisible copy of the
    /// chip inline after the last word), then the real chip is laid over that spot at the trailing edge —
    /// an `HStack` beside the text would narrow every line. The two-line clamp is a backstop only: every
    /// rest form is within `NowNotes.restBudget`, which the layout test proves fits two lines.
    private func nowNotesRestLine(_ summary: NowNotesSummary) -> some View {
        let lead = Text(summary.restText).font(.system(size: 10.5)).foregroundColor(nowNoteTint(summary.lead))
        let chipFont = Font.system(size: 10.5)
        let reserved = summary.moreLabel.map {
            Text("\u{00A0}\u{00A0}" + $0.replacingOccurrences(of: " ", with: "\u{00A0}")).font(chipFont).foregroundColor(.clear)
        }
        return ZStack(alignment: .bottomTrailing) {
            (reserved.map { lead + $0 } ?? lead)
                .lineLimit(2).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let more = summary.moreLabel {
                Text(more).font(chipFont).foregroundStyle(DSColor.accent).lineLimit(1).fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onHover { nowNotesHover = $0 }
        .onTapGesture { if summary.hasCard { nowNotesPinned.toggle() } }
        .popover(isPresented: Binding(
            get: { summary.hasCard && (nowNotesHover || nowNotesPinned) },
            set: { if !$0 { nowNotesHover = false; nowNotesPinned = false } }),
                 arrowEdge: .top) { nowNotesCard(summary) }
        // VoiceOver: the whole note and how many more (a lone shortened note: its rest form, then \"more\"); the action opens the card.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint(summary.hasCard ? (summary.moreCount > 0 ? "Shows all notes" : "Shows the full note") : "")
        .accessibilityAddTraits(summary.hasCard ? .isButton : [])
        .accessibilityAction { if summary.hasCard { nowNotesPinned.toggle() } }
    }

    /// The hover / tap card: EVERY note, most urgent first, each in full.
    private func nowNotesCard(_ summary: NowNotesSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(summary.cardTitle).font(.system(size: 10)).textCase(.uppercase).tracking(0.5)
                .foregroundStyle(DSSurface.text3)
            ForEach(Array(summary.all.enumerated()), id: \.offset) { i, note in
                // The first entry is the resting line's note in FULL (G-9), marked with a 2 pt bar in its tint.
                Text(note.text).font(.system(size: 10.5)).foregroundStyle(nowNoteTint(note))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, i == 0 ? 6 : 0)
                    .overlay(alignment: .leading) {
                        if i == 0 { Rectangle().fill(nowNoteTint(note).opacity(0.6)).frame(width: 2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
    }

    /// "Health 87% · 525 cycles" | "at a limit 151 awake h since Jun 11". Hidden halves render nothing
    /// rather than a fabricated figure; the hold half hides when the limit is 100 (there is no limit to
    /// hold at — §14-U10).
    @ViewBuilder private var nowClosingLine: some View {
        HStack(alignment: .firstTextBaseline) {
            if let l = batteryLifetime.lifetime, let pct = l.maxCapacityPercent {
                Text("Health \(pct)% · \(l.cycleCount) cycles")
            }
            Spacer(minLength: 4)
            if let h = nowLimitHoldHours, heroLimitValue.map({ $0 < 100 }) ?? false || h > 0,
               let since = history.recordingSince {
                let f = DateFormatter(); let _ = f.dateFormat = "MMM d"
                Text("\(h) h at a limit since \(f.string(from: since))")
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(.system(size: 11).monospacedDigit()).foregroundStyle(DSSurface.text2)
        .padding(.top, 6).padding(.horizontal, 2)
        .lineLimit(2)
    }

    /// #30 stage 10: every tab is a page. The pre-#30 `rootPage` / `detailsPage` (and the `d6*` cards)
    /// are gone; what survives below the Now page are the helpers Now still reads (hero color/limit, the
    /// arbitrated banner, the limit / energy-mode bindings, and the charge + keep-awake honesty lines).
    @ViewBuilder private func page(for tab: RailTab) -> some View {
        switch tab {
        case .now: nowPage
        case .day: DayPage(history: history, monitor: monitor, engine: engine, reduceMotion: reduceMotion)
        case .energy: EnergyPage(energySource: energySource, sustained: sustained, monitor: monitor,
                                 powerReader: powerReader, powerAdapter: powerAdapter,
                                 keepAwakeInventory: keepAwakeInventory, keepAwake: keepAwake,
                                 appTerminator: appTerminator)
        case .health: HealthPage(batteryLifetime: batteryLifetime, history: history, engine: engine)
        case .devices: DevicesPage(deviceSource: deviceSource, phoneSource: phoneSource, portSource: portSource,
                                   powerAdapter: powerAdapter, history: history)
        case .automation: AutomationPage(schedule: schedule, sleepWake: sleepWake, autoEnergy: autoEnergy,
                                         energyMode: energyMode, keepAwake: keepAwake, engine: engine,
                                         settingsRouter: settingsRouter,
                                         onAC: monitor.snapshot.powerSource == .ac)
        }
    }

    // MARK: hero helpers — read by `nowHero` / `nowClosingLine` (the pre-#30 heroRow itself is excised)

    /// #29 owner refinement: the ring color is snapshot-driven (the arc sweep stays proportional — the
    /// color is the only thing this decides). Red at ≤20% off the charger; yellow when Low Power Mode is on;
    /// green otherwise (charging, holding-at-limit, normal discharge). Precedence: critical > low-power > green.
    private func heroColor(_ s: BatterySnapshot) -> Color {
        if let pct = s.chargePercent, BatteryRedRule.isLow(pct), s.isChargingForDisplay != true { return DSColor.critical }
        if s.energyMode == .low { return DSColor.lowPower }
        return DSColor.charging
    }

    /// The engine's charge limit as a raw Int (nil when unknown) — shared by the Time projection and the Limit row.
    private var heroLimitValue: Int? {
        if case .known(let v) = engine.limit { return v } else { return nil }
    }

    /// #29 C1 re-home: the Limit row now carries `ChargeStatusStrings.limitProvenanceTag` in degraded mode
    /// (the tag lost its home when the pre-#29 limit row was deleted). `HeroStats.limitRowText` owns the
    /// whole rule — including dropping "· holding" when the row already says "Holding at N%".
    private func heroLimit(_ s: BatterySnapshot) -> (text: String, holding: Bool) {
        HeroStats.limitRowText(limit: heroLimitValue, chargePercent: s.chargePercent,
                               onAC: s.powerSource == .ac, isCharging: s.isChargingForDisplay == true,
                               isPaused: engine.isPaused,
                               readBackDegraded: setupFlow.state == .readyDegraded,
                               telemetryState: pipeline.telemetryState)
    }

    // MARK: banner (D5 go-live) — the one Now-page slot, arbitrated; action routes to Settings.

    private var activeBanner: PopoverBannerContent? {
        var inputs = PopoverBannerInputs()
        if helperHealth.registration != .enabled {
            inputs.helperAttention = true
            inputs.helperMessage = helperHealth.registration.guidance
        } else if helperClient.helperUnreachable {
            inputs.helperAttention = true
            // B4: was a flat "Energy helper isn't responding right now." for three different failures.
            // Reuses the SAME tested verdict + copy the Settings surface renders, so the banner and the
            // place its "Open settings" action lands can never tell the user two different stories —
            // and a STALE helper now names itself here rather than only after a click.
            inputs.helperMessage = HelperHealthCopy.note(
                for: helperHealth.verdict(unreachable: true,
                                          hasResponded: helperClient.hasResponded),
                lastReply: nil).text
        }
        switch setupFlow.state {
        case .missing, .listUnavailable: inputs.setupRequired = true
        case .readyDegraded:             inputs.degraded = true
        case .ready, .unknown:           break
        }
        // #29 C1 re-home: the charge-control honesty layer's PERSISTENT problem states. The pre-#29
        // status-notes block stacked up to five of these at once; #29's one arbitrated slot cannot, so
        // `ChargeHonesty` collapses them to the single most important sentence, which then competes here
        // like any other exception instead of shouting over the helper/setup banners.
        //
        // NOT re-homed: `SetupFlow.degradedNoticePending` / `dismissDegradedNotice()`. That one-time
        // TRANSITION notice existed because 4.I ruled out a persistent degraded banner. #29 reversed that
        // ruling — `inputs.degraded` above IS a standing banner, permanently visible for exactly the state
        // the notice announced, and its "Open settings" action lands on the Charge control group, whose
        // degraded detail is the notice's own text (`SetupWalkthrough.degradedNote`) plus Open Shortcuts.
        // Re-homing it would put the same sentence on screen twice at the same moment — the stack the
        // arbitrated slot exists to prevent. The omission is deliberate; the model-side edge detection
        // stays because SetupFlow is out of this cut's scope, and it is inert by design, not by accident.
        if let problem = ChargeHonesty.problem(ChargeHonestyInputs(
            engineNote: engine.engineNote,
            statusNote: confirm.statusNote,
            syncProblem: engine.syncProblem,
            unverifiedExternalChange: confirm.verdictWasDegraded,
            telemetryReadFailed: pipeline.telemetryReadFailed,
            readBackDegraded: setupFlow.state == .readyDegraded,
            // AUDIT B2: the post-hoc surface. A quick-action Set runs with the popover already closed
            // (the menu dismisses it first), so a `.nonzeroExit` / `.limitMismatchAfterSet` failure had
            // no reader at the moment it happened, no notification, and no age cap. Only those two taxa
            // are promoted; `missedCommandFailure` holds the whole rule.
            lastCommandStatus: confirm.status,
            lastCommandPrefix: engine.lastCommandSource.statusPrefix)) {
            inputs.chargeProblem = true
            inputs.chargeProblemMessage = problem
        }
        if autoEnergy.isHolding {
            inputs.autoEnergyHold = true
            inputs.autoEnergyNote = autoEnergy.autoNote
        }
        if case .low = monitor.snapshot.energyMode { inputs.lowPower = true }
        return PopoverBannerMapper.banner(for: inputs)
    }

    private func bannerTint(_ t: BannerTint) -> Color {
        switch t {
        case .attention: return DSColor.attention
        case .lowPower:  return DSColor.lowPower
        case .neutral:   return DSColor.holding
        }
    }

    @ViewBuilder private func rootBanner(_ c: PopoverBannerContent) -> some View {
        DSBanner(symbol: c.symbol, message: c.message, tint: bannerTint(c.tint),
                 actionTitle: c.actionTitle,
                 action: bannerAction(c.action))
    }

    /// D5-A3: map the banner's routed action to the app-level SettingsRouter (charge-control family →
    /// General, auto-energy → Automation); action-less banners (low power) pass nil through.
    private func bannerAction(_ a: PopoverBannerAction?) -> (() -> Void)? {
        switch a {
        case .openGeneral:    return { settingsRouter.open(to: .general) }
        case .openAutomation: return { settingsRouter.open(to: .automation) }
        case .none:           return nil
        }
    }

    // MARK: charge-limit binding — read by `nowControlsCard`

    private var limitSelectionBinding: Binding<Int> {
        Binding(
            get: { if case .known(let v) = engine.limit { return v } else { return -1 } },
            set: { v in if v >= 0 { Task { _ = await engine.userSetLimit(v) } } })
    }

    // MARK: energy-mode binding — sets the ACTIVE source's mode (the Now controls strip); full picker in Settings

    private func energyModeCardBinding(source: EnergySource, activeMode: EnergyMode) -> Binding<EnergyModeValue> {
        // #29 D-4b: value/label/current-mode mapping single-homed in EnergyModePresentation (shared with
        // the Settings · Automation per-source picker). The Now strip shows the ACTIVE source, so it
        // passes perSource: nil — activeMode is already correct for the active source.
        Binding(
            get: { EnergyModePresentation.value(from: EnergyModePresentation.currentMode(
                for: source, active: source, activeMode: activeMode, perSource: nil)) ?? .automatic },
            set: { v in energyMode.setMode(v, source: source) })
    }

}
