import SwiftUI
import Shared             // #29 D-4b: EnergyModeValue / EnergySource / WakeBehaviorReadback for the Automation picker
import ServiceManagement // #29 D-4b: the "approve helper" affordance opens Login Items

/// #29 D-4: the app's Settings window — four toolbar tabs (General · Appearance · Notifications ·
/// Automation) at `DSMetric.settingsWidth`, grouped-Form style, fixed width with per-tab content
/// height (D8-as-amended-A1: System-Settings behavior; the window animates between tab heights on
/// switch, `.smooth`; Reduce Motion → direct set). The tab selection is the app-level `SettingsRouter`
/// (A1/F3), so a deep-link (footer gear → General; `open schedule` quick action → Automation) lands on
/// the right tab on first presentation. Every control binds 1:1 to an existing controller — zero new
/// features (D9); this cut only relocates the popover's config sections here and re-skins them to Form.
struct SettingsView: View {
    @ObservedObject var router: SettingsRouter

    // Appearance / Notifications reuse the existing views as-is.
    @ObservedObject var glyphModel: GlyphSettingsModel
    @ObservedObject var notificationModel: NotificationSettingsModel

    // General
    @ObservedObject var uninstall: UninstallCoordinator
    @ObservedObject var loginItem: LoginItemModel
    @ObservedObject var engine: ChargeLimitEngine
    @ObservedObject var setupFlow: SetupFlow
    @ObservedObject var advisor: OBCAdvisor
    @ObservedObject var helperHealth: HelperHealthModel
    @ObservedObject var helperClient: HelperClient
    /// After a manual "Restart helper": re-probe + ping so the line shows the NEW daemon answering.
    var onHelperRestarted: @MainActor () async -> Void = {}

    // Automation
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var schedule: ScheduleRunner
    @ObservedObject var sleepWake: SleepWakeScheduleController
    @ObservedObject var wakeBehavior: WakeBehaviorController
    @ObservedObject var autoEnergy: AutoEnergyModeRunner
    @ObservedObject var energyMode: EnergyModeController
    @ObservedObject var keepAwake: KeepAwakeController

    // #29 D-4b: Automation-tab local edit state, moved verbatim from BatteryPopoverView with the
    // sections that own them (the popover no longer hosts these controls).
    @State private var draftRule: ChargeRule?
    @State private var editingRule: ChargeRule?
    // AUDIT hand-off 4: these were Bools, so the confirm could say only ONE of the two reasons it
    // fires for — and it said the wrong one on a failed read. Holding the REASON instead makes the
    // dialog state the fact that actually gated the action. Captured at TAP time, not at render time:
    // the read-back can go nil between the two, and the sentence must match the branch that produced it.
    @State private var confirmingSleepWakeApply: SleepWakeScheduleController.ConfirmReason?
    @State private var confirmingSleepWakeCancel: SleepWakeScheduleController.ConfirmReason?
    @State private var perSourceModes: EnergyModeReader.PerSourceEnergyMode?
    @State private var pickerHoldNote: String?

    // #29 D-6 item6 (W10): no SwiftUI animation lives in this view — the only tab-switch motion is the
    // AppKit window resize, which honors Reduce Motion in BatteryApp.resizeSettingsWindowForCurrentTab
    // (…&& !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion). So no @Environment reduceMotion here.

    var body: some View {
        TabView(selection: Binding(get: { router.selection }, set: { router.select($0) })) {
            // #29 owner refinement (item 5): text-only tab labels — the native TabView pill sizes to the
            // text and centers on it (icons in the Label left the pill sized to include a hidden icon slot).
            generalTab
                .tabItem { Text("General") }
                .tag(SettingsTab.general)
            GlyphSettingsView(model: glyphModel)
                .formStyle(.grouped)
                .tabItem { Text("Appearance") }
                .tag(SettingsTab.appearance)
            NotificationSettingsView(model: notificationModel)
                .formStyle(.grouped)
                .tabItem { Text("Notifications") }
                .tag(SettingsTab.notifications)
            automationTab
                // B-arc B4: the sleep/wake + power-nap read-backs (`pmset -g sched` / `pmset -g custom`)
                // fire when THIS tab appears. They used to run on every popover open, where nothing read
                // them — these two sections are their only readers, and they live here. Attached at the
                // TabView call site rather than on `automationTab` itself so the off-screen
                // `measurementContent` hosting view (D-6 F1 per-tab sizing) can't trigger the spawns.
                .task {
                    sleepWake.refreshReadback()
                    wakeBehavior.refreshReadback()
                }
                .tabItem { Text("Automation") }
                .tag(SettingsTab.automation)
        }
        .frame(width: DSMetric.settingsWidth)
    }

    /// #29 D-6 F1: the AppDelegate measures each tab's content height OFF-SCREEN (a width-constrained
    /// hosting view's `fittingSize`) to size its window per-tab. This returns a tab's content standalone
    /// for that measurement — the grouped Form here is NOT inside a TabView, so its `fittingSize` is the
    /// content's natural height (the TabView is what hid it, reporting only the tab-bar height in D-4a).
    @ViewBuilder func measurementContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:       generalTab
        case .appearance:    GlyphSettingsView(model: glyphModel).formStyle(.grouped)
        case .notifications: NotificationSettingsView(model: notificationModel).formStyle(.grouped)
        case .automation:    automationTab
        }
    }

    // MARK: - General (D9): launch-at-login · charge control group (A3) · uninstall

    private var generalTab: some View {
        Form {
            // #29 parity: the mockup's General leads with a header-less Launch-at-login group (a "Startup"
            // header over one self-describing toggle is redundant); the caption below it is per the mockup.
            Section {
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isOn },
                                                        set: { loginItem.setEnabled($0) }))
                Text("Battery starts automatically and keeps your charge limit active.")
                    .font(DSType.caption).foregroundStyle(DSColor.textSecondary)
                if loginItem.needsApproval {
                    Text("Needs approval in System Settings → General → Login Items.")
                        .font(DSType.caption).foregroundStyle(DSColor.attention)
                    Button("Open Login Items") { Self.openLoginItems() }
                } else if let err = loginItem.lastError {
                    Text(err).font(DSType.caption).foregroundStyle(DSColor.attention)
                }
                // #29 C1 re-home: the one-time nudge. `LoginItem.suggestionShown` / `markSuggestionShown()`
                // lost their only reader when the popover's settings section was relocated here — the model
                // kept persisting a flag nothing ever set or read. Shown only while launch-at-login is
                // genuinely OFF, and only once ever: the whole point of the seen-flag is that this is a
                // suggestion, not a nag. The caption above states the behavior; this states the CONSEQUENCE
                // of leaving it off, which is the part a user can't infer.
                if !loginItem.isOn && !loginItem.suggestionShown {
                    Text(PopoverDetailStrings.loginItemSuggestion)
                        .font(DSType.caption).foregroundStyle(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .onAppear { loginItem.markSuggestionShown() }
                }
            }

            chargeControlSection   // A3: the capability's single health-and-setup home

            Section("Uninstall") {
                // The existing Cut-2 flow (confirmation dialog, ordered teardown, completed panel) is
                // unchanged — only the entry point moved here from its own Settings tab (D9).
                UninstallSettingsView(coordinator: uninstall)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Automation (D9): schedule · sleep/wake · while sleeping · auto-energy · per-source mode

    private var automationTab: some View {
        Form {
            Section("Charge schedule") { scheduleSection }
            Section("Sleep & wake") { sleepWakeSection }
            Section("While sleeping") { wakeBehaviorSection }
            Section("Energy mode") {
                autoEnergyModeSection
                energyModePickerSection(active: monitor.snapshot)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - A3 charge-control group (the capability's single health-and-setup home)

    /// #29 A3: status row (always present, 3-state) → state detail (guided setup walkthrough / degraded
    /// provenance) → helper attention/remediation → OBC advisor caption. Health-and-setup ONLY — the
    /// interactive Set / Pause / Top Up stay on the popover root card (D4), so no new controllers were
    /// needed here (setupFlow / advisor / helperHealth / helperClient were already injected for the window).
    @ViewBuilder private var chargeControlSection: some View {
        Section("Charge control") {
            chargeControlStatusRow

            switch setupFlow.state {
            case .missing(let names):
                chargeControlSetupWalkthrough(missing: names)
            case .listUnavailable:
                Text("Can’t detect your shortcuts (the shortcuts tool is unavailable or blocked).")
                    .font(DSType.caption).foregroundStyle(DSColor.attention)
                    .fixedSize(horizontal: false, vertical: true)
            case .readyDegraded:
                chargeControlDegradedDetail
            case .ready, .unknown:
                EmptyView()
            }

            chargeControlHelperRemediation

            // OBC advisor caption (persistent ambiguous-hold guidance + the verified Battery-pane link).
            if let guidance = advisor.guidance {
                Text(guidance).font(DSType.caption).foregroundStyle(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Battery Settings") {
                    NSWorkspace.shared.open(OBCAdvisor.batterySettingsURL)
                }
            }
        }
    }

    /// Pure state→(word, detail, tint) mapping for the status row (kept out of the @ViewBuilder so its
    /// switch stays a value expression, not a view branch). Strings draft-registered per §4.
    private var chargeControlStatus: (word: String, detail: String, tint: Color) {
        switch setupFlow.state {
        case .ready:
            return (ChargeControlStatusStrings.active, ChargeControlStatusStrings.activeDetail, DSColor.textPrimary)
        case .readyDegraded:
            return (ChargeControlStatusStrings.readbackOff, ChargeControlStatusStrings.readbackOffDetail, DSColor.textSecondary)
        case .missing, .listUnavailable:
            return (ChargeControlStatusStrings.needsSetup, ChargeControlStatusStrings.needsSetupDetail, DSColor.attention)
        case .unknown:
            return (ChargeControlStatusStrings.checking, "", DSColor.textSecondary)
        }
    }

    /// The always-present 3-state status row (Active / Needs setup / Read-back off; `.unknown` is the
    /// transient "Checking…").
    @ViewBuilder private var chargeControlStatusRow: some View {
        let s = chargeControlStatus
        LabeledContent("Status") { Text(s.word).foregroundStyle(s.tint) }
        if !s.detail.isEmpty {
            Text(s.detail).font(DSType.caption).foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The guided setup walkthrough (needs-setup state): per-missing-shortcut build steps + the Get
    /// recommendation, the grant explanation, the trust-boundary notice, and Open Shortcuts.
    @ViewBuilder private func chargeControlSetupWalkthrough(missing names: [String]) -> some View {
        Text("Create these shortcuts to enable charge control:").font(DSType.caption).bold()
        ForEach(SetupWalkthrough.steps.filter { names.contains($0.shortcutName) }, id: \.shortcutName) { step in
            Text("• \(step.instruction)").font(DSType.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("• \(SetupWalkthrough.getRecommendation)").font(DSType.caption).foregroundStyle(DSColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(SetupWalkthrough.grantExplanation).font(DSType.caption).foregroundStyle(DSColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(SetupWalkthrough.trustBoundaryNotice).font(DSType.caption).foregroundStyle(DSColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Button("Open Shortcuts") { Self.openShortcuts() }
    }

    /// The degraded provenance detail (read-back off): the custody explanation + a one-tap path back to
    /// Shortcuts (create the Get shortcut to restore read-back).
    @ViewBuilder private var chargeControlDegradedDetail: some View {
        Text(SetupWalkthrough.degradedNote).font(DSType.caption).foregroundStyle(DSColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Button("Open Shortcuts") { Self.openShortcuts() }
    }

    /// Helper attention / remediation, re-homed here from the popover (A3).
    ///
    /// B4: this used to render ONE sentence — "isn't responding right now" — for three different
    /// problems, and the app held the signals to tell them apart the whole time. It now asks
    /// `HelperHealthModel` for the verdict (registration + reachability + the observed daemon image),
    /// renders that state's own sentence, and where the fix is a command rather than a button, prints
    /// the command. Nothing is composed here: every string is a pure function with a test.
    @ViewBuilder private var chargeControlHelperRemediation: some View {
        let verdict = helperHealth.verdict(unreachable: helperClient.helperUnreachable,
                                           hasResponded: helperClient.hasResponded)
        let note = HelperHealthCopy.note(for: verdict,
                                         lastReply: helperClient.lastPong == "—" ? nil : helperClient.lastPong)

        Text(note.text)
            .font(DSType.caption).foregroundStyle(Self.tintColor(note.tint))
            .fixedSize(horizontal: false, vertical: true)

        if let remedy = note.remedy {
            // Selectable, because the whole value of this line is that it can be copied into Terminal.
            Text(remedy)
                .font(DSType.mono).foregroundStyle(DSColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        if note.canRestart {
            // The no-sudo fix: recycle the daemon through SMAppService, then re-probe + ping.
            Button(helperHealth.restartInProgress ? "Restarting…" : "Restart helper") {
                Task { @MainActor in
                    await helperHealth.restartDaemon(logger: { NSLog("battery_app: %@", $0) })
                    await onHelperRestarted()
                }
            }
            .disabled(helperHealth.restartInProgress)
        }
        if let outcome = helperHealth.lastRestart, case .failed(let why) = outcome {
            Text("Restart failed: \(why). Use the command above.")
                .font(DSType.caption).foregroundStyle(Self.tintColor(.attention))
                .fixedSize(horizontal: false, vertical: true)
        }

        if helperHealth.registration.shouldOpenLoginItems {
            Button("Open Login Items") { Self.openLoginItems() }
        }

        // The two timestamps the staleness call was made from, so the claim above is checkable rather
        // than asserted — and so a wrong verdict is diagnosable instead of merely wrong.
        if let observed = HelperHealthCopy.daemonDetail(helperHealth.daemonImage,
                                                       formatted: Self.helperTimestamp) {
            Text(observed)
                .font(DSType.caption).foregroundStyle(DSColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // #29 orphan-backlog: the AE pre-flight verdict was recorded "for diagnostics" and had no
        // diagnostics surface. Advisory only — the copy names a possible cause and an place to look,
        // and no behaviour branches on it (sec 8(i)).
        if let advisory = AutomationPreflight.advisoryNote(setupFlow.automationPreflight) {
            Text(advisory)
                .font(DSType.caption).foregroundStyle(DSColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Automation · charge schedule (4.C, SPEC sec 5) — relocated verbatim from BatteryPopoverView

    @ViewBuilder
    private var scheduleSection: some View {
        Toggle("Enabled", isOn: Binding(get: { schedule.config.enabled },
                                        set: { schedule.setEnabled($0) }))
            .toggleStyle(.switch).controlSize(.mini)
        if schedule.config.enabled {
            // 4.I: degraded mode widens the S-N3 blindness window — say so, once, quietly.
            if setupFlow.state == .readyDegraded {
                Text("Limit changes made in System Settings can't be detected in this mode.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            // Starter preset — offered ONCE (sec 1).
            if schedule.config.rules.isEmpty && !schedule.config.presetOffered {
                Text("Suggested: 22:00 → 80%, 07:30 → 100%")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Use suggested") { schedule.applyStarterPreset() }.font(.caption)
                    Button("Set up manually") { schedule.markPresetOffered() }.font(.caption)
                }
            }

            // Committed rules read as settled sentences; editing is an explicit mode.
            ForEach(schedule.config.rules) { rule in
                if editingRule?.id == rule.id, let editing = Binding($editingRule) {
                    ruleEditor(editing, commit: "Save") { schedule.updateRule($0) }
                } else {
                    HStack {
                        Text("By \(rule.timeLabel), set limit to \(rule.limit)%").font(.caption)
                        Spacer()
                        Button("Edit") { draftRule = nil; editingRule = rule }.font(.caption)
                        Button { schedule.removeRule(id: rule.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete rule, by \(rule.timeLabel)")   // #29 D-6 item6 (W11): name the destructive icon-only action
                    }
                }
            }

            // Add a new rule through the SAME editor (explicit Add / Cancel).
            if let draft = Binding($draftRule) {
                ruleEditor(draft, commit: "Add") { schedule.addRule($0) }
            } else if editingRule == nil && schedule.config.rules.count < ChargeScheduleConfig.maxRules {
                Button("Add rule…") { draftRule = defaultNewRule() }.font(.caption)
            }

            if let next = schedule.upcomingLine() {
                Text(next).font(.caption2).foregroundStyle(.secondary)
            }

            // 4g thermostat-hold: the "Next:" line above is the standing reassertion disclosure. When
            // the live limit diverges from the schedule's current dictate, offer Resume (apply that
            // dictate now), labeled with the value. Else show any note (setup-required / pause).
            // N1 rider: these were `if / else if`, which made `schedule.note` STRUCTURALLY UNREACHABLE
            // for its most important value. `resumeTarget()` returns non-nil exactly when
            // `engine.limit.knownValue != operative.rule.limit` (:566-570), and `ChargeSchedule.nextAction`
            // returns `.none` unless that SAME divergence holds (:147) — so any path that sets a note about
            // a skipped or deferred occurrence guarantees the Button branch wins the slot. The note is also
            // non-sticky, cleared on the next `.none` tick ~30 s later. Nobody has ever read
            // "Scheduled change skipped — the app was busy."
            //
            // They are now siblings, not alternatives: the button offers the fix and the note says why it
            // is being offered. The note keeps its quieter role for the cases where no Resume applies.
            if let target = schedule.resumeTarget() {
                Button("Resume schedule (\(target)% now)") { schedule.resumeNow() }.font(.caption)
            }
            if let note = schedule.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The unified Add/Edit editor: "By [time], set limit to [N]%" + Save/Add + Cancel, with a
    /// live duplicate-time guard (the conflict logic the model already enforces, surfaced).
    @ViewBuilder
    private func ruleEditor(_ rule: Binding<ChargeRule>, commit: String,
                            onCommit: @escaping (ChargeRule) -> Bool) -> some View {
        let conflict = schedule.config.rules.contains {
            $0.id != rule.wrappedValue.id && $0.minuteOfDay == rule.wrappedValue.minuteOfDay
        }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("By").font(.caption)
                DatePicker("", selection: ruleTimeBinding(rule), displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
                Text("set limit to").font(.caption)
                Menu("\(rule.wrappedValue.limit)%") {
                    ForEach(ChargeShortcuts.validLimitValues, id: \.self) { v in
                        Button("\(v)%") { rule.wrappedValue.limit = v }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                Button(commit) {
                    if onCommit(rule.wrappedValue) { draftRule = nil; editingRule = nil }
                }
                .disabled(conflict)
                Button("Cancel") { draftRule = nil; editingRule = nil }.buttonStyle(.borderless)
                if conflict {
                    Text("that time is already used").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    /// hour:minute ↔ a Date binding for a bound rule (date part is a fixed dummy day).
    private func ruleTimeBinding(_ rule: Binding<ChargeRule>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1,
                    hour: rule.wrappedValue.hour, minute: rule.wrappedValue.minute)) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                rule.wrappedValue.hour = c.hour ?? rule.wrappedValue.hour
                rule.wrappedValue.minute = c.minute ?? rule.wrappedValue.minute
            })
    }

    /// A new rule at the first free common time (addRule rejects duplicates, so avoid a no-op).
    private func defaultNewRule() -> ChargeRule {
        let used = Set(schedule.config.rules.map { $0.minuteOfDay })
        for h in [22, 7, 8, 12, 0, 18] where !used.contains(h * 60) {
            return ChargeRule(hour: h, minute: 0, limit: h >= 6 && h < 18 ? 100 : 80)
        }
        for m in stride(from: 0, to: 24 * 60, by: 30) where !used.contains(m) {
            return ChargeRule(hour: m / 60, minute: m % 60, limit: 80)
        }
        return ChargeRule(hour: 23, minute: 0, limit: 80)
    }

    // MARK: - Automation · sleep & wake schedule (3.7 sleep/wake STAGE 2b) — relocated verbatim

    /// The app-side sleep/wake schedule UI. Two side toggles (sleep, wake) with dummy-day time pickers,
    /// seven weekday chips, the should-fix-5-gated Apply (an inline confirm when the live schedule is
    /// foreign or unverifiable), and a read-back line showing the live pmset schedule with a Turn-off.
    @ViewBuilder
    private var sleepWakeSection: some View {
        // AUDIT H3. The stored config would not decode, so the fields below are DEFAULTS, not the
        // user's settings. Said out loud because the old behaviour was to present them as his — and
        // then to call his own live schedule foreign. The second sentence is the one that matters:
        // nothing here has touched `pmset`, so the machine's actual schedule is still whatever it was.
        if sleepWake.configUnreadable {
            Text("Battery couldn't read its own saved schedule settings, so these fields started from "
                 + "the defaults and it can't tell what's set on your Mac. Your Mac's actual schedule "
                 + "hasn't been changed — set the times and apply to take it over.")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Toggle("Sleep at", isOn: Binding(
                get: { sleepWake.config.sleepEnabled },
                set: { sleepWake.setSleepEnabled($0) }))
                .toggleStyle(.checkbox).font(.caption)
            if sleepWake.config.sleepEnabled {
                DatePicker("", selection: sleepTimeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
            }
            Spacer()
        }

        HStack {
            Toggle("Wake at", isOn: Binding(
                get: { sleepWake.config.wakeEnabled },
                set: { sleepWake.setWakeEnabled($0) }))
                .toggleStyle(.checkbox).font(.caption)
            if sleepWake.config.wakeEnabled {
                DatePicker("", selection: wakeTimeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
            }
            Spacer()
        }

        if sleepWake.config.sleepEnabled || sleepWake.config.wakeEnabled {
            HStack(spacing: 3) {
                sleepWakeDayChip("M", bit: 0)
                sleepWakeDayChip("T", bit: 1)
                sleepWakeDayChip("W", bit: 2)
                sleepWakeDayChip("T", bit: 3)
                sleepWakeDayChip("F", bit: 4)
                sleepWakeDayChip("S", bit: 5)
                sleepWakeDayChip("S", bit: 6)
                Spacer()
            }

            if !sleepWake.config.isValid {
                Text("Sleep and wake can't be set to the same time.")
                    .font(.caption2).foregroundStyle(.orange)
            }

            // SF3: the recurring-local-time / DST disclosure (canonical copy).
            Text(SleepWakeReadback.dstDisclosure)
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // SF4: a scheduled sleep may not fire while a keep-awake assertion is held.
            if keepAwake.isOn && sleepWake.config.sleepEnabled {
                Text("Keep awake is on, so a scheduled sleep may not take effect until it ends.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // SF5: apply, with an inline confirm when the live schedule is foreign or unverifiable.
            // AUDIT hand-off 4: the confirm now NAMES which of those two it is. The bias is unchanged.
            if let reason = confirmingSleepWakeApply {
                Text(reason.applyMessage)
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Replace and apply") {
                        sleepWake.apply(confirmed: true)
                        confirmingSleepWakeApply = nil
                    }.font(.caption)
                    Button("Cancel") { confirmingSleepWakeApply = nil }
                        .buttonStyle(.borderless).font(.caption)
                }
            } else {
                Button("Apply") {
                    // ONE read of the gating fact, so the branch and the sentence cannot disagree.
                    if let reason = sleepWake.confirmReason(for: sleepWake.lastReadback) {
                        confirmingSleepWakeApply = reason
                    } else {
                        sleepWake.apply(confirmed: true)
                    }
                }
                .font(.caption)
                .disabled(!sleepWake.config.isValid)
            }
        }

        sleepWakeReadbackLine

        if case .failed(let token) = sleepWake.lastApplyStatus {
            Text("Schedule change failed (\(token)).")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if sleepWake.lastApplyStatus == .unreachable {
            Text("Energy helper unavailable. Approve it in System Settings to set a schedule.")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if sleepWake.lastApplyStatus == .appliedUnverified {
            // The e498c86 sibling. The change went through and nothing has confirmed it — a caveat,
            // not a failure, so it is secondary rather than orange like the two real failures above.
            // Not a retry prompt either: reopening the tab is the read the app was already going to
            // take, and it lifts this line for free.
            Text("Applied, but not confirmed — reading the schedule back didn't work. Reopening this "
                 + "tab reads it again.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The live pmset schedule, with a Turn-off (the should-fix-5 cancel gate). A nil read-back (not
    /// yet read or a failed read) renders nothing; the open-side refreshReadback populates it.
    @ViewBuilder
    private var sleepWakeReadbackLine: some View {
        if let readback = sleepWake.lastReadback {
            if readback.events.isEmpty {
                Text("No repeating sleep or wake schedule is set.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                // AUDIT 2.H: a schedule the app did NOT author is worth saying out loud. isAuthored
                // already computes this correctly, but its only caller was the Apply path — and when
                // the feature is off that block is not even rendered, so a foreign schedule sat behind
                // a grey line that read like our own. Display-only over an already-computed predicate:
                // no new read, no autonomous action. It can say "foreign", never "whose" — pmset repeat
                // records no provenance.
                // AUDIT H3: read this off the SAME predicate the confirm uses, so the line and the
                // dialog cannot disagree — and so an unreadable config produces "we can't tell"
                // rather than the unsupportable "this app didn't set this schedule".
                let reason = sleepWake.confirmReason(for: readback)
                Text("Currently scheduled: \(sleepWakeReadbackSummary(readback))")
                    .font(.caption2).foregroundStyle(reason == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if confirmingSleepWakeCancel == nil {
                    if reason == .foreignSchedule {
                        Text("This app didn't set this schedule, and its own settings say the feature is off.")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if reason == .configUnreadable {
                        Text("Battery can't tell whether it set this schedule — its own saved settings "
                             + "couldn't be read.")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let reason = confirmingSleepWakeCancel {
                    Text(reason.cancelMessage)
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Remove it") {
                            sleepWake.cancel(confirmed: true)
                            confirmingSleepWakeCancel = nil
                        }.font(.caption)
                        Button("Keep it") { confirmingSleepWakeCancel = nil }
                            .buttonStyle(.borderless).font(.caption)
                    }
                } else {
                    Button("Turn off schedule") {
                        // The read-back can go nil between this row rendering and the tap — that race
                        // is exactly what the safe bias is for, and `.scheduleUnreadable` is the
                        // sentence it needs. Reading the reason at tap time is what makes it reachable.
                        if let reason = sleepWake.confirmReason(for: sleepWake.lastReadback) {
                            confirmingSleepWakeCancel = reason
                        } else {
                            sleepWake.cancel(confirmed: true)
                        }
                    }.font(.caption)
                }
            }
        }
    }

    // A dummy-day Date binding for the sleep time (mirrors the scheduleSection time binding).
    private var sleepTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(
                    year: 2000, month: 1, day: 1,
                    hour: sleepWake.config.sleepHour, minute: sleepWake.config.sleepMinute)) ?? Date()
            },
            set: { newValue in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                sleepWake.setSleepTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
            })
    }

    private var wakeTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(
                    year: 2000, month: 1, day: 1,
                    hour: sleepWake.config.wakeHour, minute: sleepWake.config.wakeMinute)) ?? Date()
            },
            set: { newValue in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                sleepWake.setWakeTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
            })
    }

    // A single weekday chip (bit0=Mon..bit6=Sun); tapping toggles that bit via the controller.
    private static let weekdayFullNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    @ViewBuilder
    private func sleepWakeDayChip(_ label: String, bit: Int) -> some View {
        let on = (sleepWake.config.weekdayMask & (1 << bit)) != 0
        Button(action: { sleepWake.toggleWeekday(bit: bit) }) {
            Text(label)
                .font(.caption2)
                .frame(minWidth: 16)
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        // #29 D-6 item6 (W9): full weekday name (the visible chip is a 1-2 letter abbreviation) + selected
        // trait (selection was background-color-only). Bit index maps 0=Mon…6=Sun.
        .accessibilityLabel(Self.weekdayFullNames.indices.contains(bit) ? Self.weekdayFullNames[bit] : label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // Render minutes-since-midnight as a locale clock time (reuses the section's formatter).
    private func sleepWakeClock(_ minuteOfDay: Int) -> String {
        let d = Calendar.current.date(from: DateComponents(
            hour: minuteOfDay / 60, minute: minuteOfDay % 60)) ?? Date()
        return Self.clockTimeFormatter.string(from: d)
    }

    // A short sentence describing the live repeating schedule (kind + time + day-of-week phrase).
    private func sleepWakeReadbackSummary(_ schedule: RepeatingSchedule) -> String {
        schedule.events.map { ev -> String in
            let kind: String
            switch ev.kind {
            case .sleep: kind = "sleep"
            case .wake:  kind = "wake"
            case .other(let s): kind = s
            }
            let time = ev.minuteOfDay.map { sleepWakeClock($0) } ?? "unknown time"
            let phrase = sleepWakeDayPhrase(ev.weekdayMask)
            return phrase.isEmpty ? "\(kind) at \(time)" : "\(kind) at \(time) \(phrase)"
        }.joined(separator: ", ")
    }

    // The day-of-week phrase for a read-back event's weekday mask (the inverse of parseDaySpec).
    private func sleepWakeDayPhrase(_ mask: Int?) -> String {
        guard let mask else { return "" }
        switch mask {
        case 0b0011111: return "on weekdays"
        case 0b1100000: return "on weekends"
        case 0b1111111: return "every day"
        default:
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let days = (0...6).filter { (mask & (1 << $0)) != 0 }.map { names[$0] }
            return days.isEmpty ? "" : "on " + days.joined(separator: ", ")
        }
    }

    // MARK: - Automation · while sleeping (Power Nap / wake-for-network) — relocated verbatim

    /// Power Nap + Wake for network: two three-way segmented controls (Never / On adapter / Always), the
    /// battery-impact notes, an Apply (no confirm; the values are plain booleans), and a read-back line
    /// showing the live per-source truth.
    @ViewBuilder
    private var wakeBehaviorSection: some View {
        Text("Power Nap").font(DSType.rowLabel).foregroundStyle(DSColor.textPrimary)   // #29 parity: standard row-label tier (was demoted caption)
        Picker("", selection: Binding(
            get: { wakeBehavior.powerNap },
            set: { wakeBehavior.setPowerNap($0) })) {
            Text("Never").tag(WakeBehaviorReadback.Scope.never)
            Text("On adapter").tag(WakeBehaviorReadback.Scope.onPowerAdapter)
            Text("Always").tag(WakeBehaviorReadback.Scope.always)
        }
        .labelsHidden().pickerStyle(.segmented)
        .accessibilityLabel("Power Nap")   // #29 D-6 item6 (W6): the visible caption is a detached sibling Text

        Text("Power Nap may have a reduced effect on Apple Silicon Macs, which already perform some background work during sleep.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        Text("Wake for network").font(DSType.rowLabel).foregroundStyle(DSColor.textPrimary)   // #29 parity: standard row-label tier (was demoted caption)
        Picker("", selection: Binding(
            get: { wakeBehavior.wakeOnNetwork },
            set: { wakeBehavior.setWakeOnNetwork($0) })) {
            Text("Never").tag(WakeBehaviorReadback.Scope.never)
            Text("On adapter").tag(WakeBehaviorReadback.Scope.onPowerAdapter)
            Text("Always").tag(WakeBehaviorReadback.Scope.always)
        }
        .labelsHidden().pickerStyle(.segmented)
        .accessibilityLabel("Wake for network")   // #29 D-6 item6 (W7): the visible caption is a detached sibling Text

        Text("Waking for network on battery lets the Mac wake from sleep on incoming network activity (a magic packet over Ethernet, or the equivalent on Wi-Fi). It uses extra battery and can increase how often the Mac wakes.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        Button("Apply") { wakeBehavior.apply() }
            .font(.caption)
            .disabled(wakeBehavior.lastApplyStatus == .applying)

        wakeBehaviorReadbackLine

        if case .failed(let token) = wakeBehavior.lastApplyStatus {
            Text("Couldn't change these settings (\(token)).")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if wakeBehavior.lastApplyStatus == .unreachable {
            Text("Energy helper unavailable. Approve it in System Settings to change these.")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if wakeBehavior.lastApplyStatus == .appliedUnverified {
            // AUDIT hand-off 3. The change went through and nothing has confirmed it, which is a
            // caveat and not a failure — so it is secondary, the way the devices-card read-state note
            // and BehaviorConfirm's "confirmed from charge flow only" note are, not orange like the
            // two real failures above. Not a retry prompt either: reopening the tab is the read the
            // app was already going to take.
            Text("Applied, but not confirmed — reading these settings back didn't work. Reopening this tab reads them again.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The live per-source truth from the last `pmset -g custom` read. A nil read renders nothing.
    @ViewBuilder
    private var wakeBehaviorReadbackLine: some View {
        if let rb = wakeBehavior.lastReadback {
            Text("Currently: \(wakeBehaviorReadbackSummary(rb))")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Render the four per-source booleans as the literal live truth (so the degenerate battery-on/
    /// AC-off case reads honestly, independent of the picker's normalization).
    private func wakeBehaviorReadbackSummary(_ s: WakeBehaviorReadback.State) -> String {
        func phrase(_ battery: Bool, _ ac: Bool) -> String {
            switch (battery, ac) {
            case (false, false): return "off"
            case (true, true):   return "on (battery and power adapter)"
            case (false, true):  return "on (power adapter only)"
            case (true, false):  return "on (battery only)"
            }
        }
        return "Power Nap \(phrase(s.powerNapBattery, s.powerNapAC)); Wake for network \(phrase(s.wakeOnNetworkBattery, s.wakeOnNetworkAC))"
    }

    // MARK: - Automation · energy mode (auto opt-in + per-source picker) — relocated verbatim

    /// auto-energy-mode: the opt-in toggle (persisted, default OFF), the nested plugged-High consent, and
    /// the runner's PERSISTENT status line. The status states what auto is doing and why. The manual
    /// picker keeps working with auto on — it is the override BRANCH B respects, while protection stays
    /// non-overridable.
    @ViewBuilder private var autoEnergyModeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Auto energy mode", isOn: $autoEnergy.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            if autoEnergy.enabled && energyMode.highPowerAvailable {
                VStack(alignment: .leading, spacing: 1) {
                    Toggle("Use High Power when plugged in", isOn: $autoEnergy.highWhenPluggedEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption)
                    Text("Lets the fans run faster to sustain peak performance longer during heavy work. It doesn’t raise the maximum speed, and expect louder fans. Off by default; supported models only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 16)
            }
            if let note = autoEnergy.autoNote {
                if autoEnergy.isHolding {
                    // ISSUE-9: an ACTIVE protection hold reads as ENFORCED, not a passing footnote.
                    Label(note, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The per-source manual picker (battery + charger profiles), bolded per source from
    /// `pmset -g custom` (`perSourceModes`). Uses the single-homed `EnergyModePresentation` helpers.
    @ViewBuilder private func energyModePickerSection(active s: BatterySnapshot) -> some View {
        let activeSource: EnergySource = (s.powerSource == .ac) ? .charger : .battery
        VStack(alignment: .leading, spacing: 4) {
            ForEach([EnergySource.battery, EnergySource.charger], id: \.self) { source in
                HStack(spacing: 8) {
                    Text(source == .battery ? "Battery" : "Charger")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    let current = EnergyModePresentation.currentMode(
                        for: source, active: activeSource, activeMode: s.energyMode, perSource: perSourceModes)
                    ForEach(energyMode.availableModes, id: \.self) { mode in
                        let isCurrent = EnergyModePresentation.matches(mode, current)
                        Button(EnergyModePresentation.label(mode)) {
                            // ISSUE-9 PROACTIVE affordance: if a BRANCH-A hold forbids this tap on the
                            // ACTIVE source (fires for High AND Automatic; Low is the forced mode), explain
                            // WHERE the user tapped — immediately. The set itself is UNCHANGED.
                            if autoEnergy.isHolding, source == activeSource, !EnergyModePresentation.matches(mode, .low) {
                                pickerHoldNote = autoEnergy.autoNote ?? "Low Power held while battery is low"
                            }
                            energyMode.setMode(mode, source: source)
                        }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .fontWeight(isCurrent ? .bold : .regular)
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                            .accessibilityAddTraits(isCurrent ? [.isSelected] : [])   // #29 D-6 item6 (W8): current mode was bold-only (visual)
                            .disabled(energyMode.isHelperUnreachable || energyMode.isBusy)
                    }
                    Spacer()
                }
            }
            // HAND-OFF #1 (`760a638`) gave the POPOVER's energy card this cue; this picker renders the
            // same two-of-three options from the same `availableModes` and still omitted High Power in
            // silence — the identical defect, one screen over. Same model property, verbatim, no copy of
            // its own: nil in both healthy states (a Mac without High Power grows no furniture here),
            // and it is NOT part of the error chain below — it explains a MISSING OPTION, not a failed
            // set, so a helper error must not suppress it.
            if let note = energyMode.highPowerNote {
                Text(note).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if energyMode.isHelperUnreachable {
                Button("Approve energy helper…") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.borderless).font(.caption2)
            } else if let err = energyMode.lastError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }
            // ISSUE-9: the transient picker-local "why" for a hold-forbidden tap (salient, ~4s).
            if let hold = pickerHoldNote {
                Label(hold, systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A1: read BOTH profiles off-main on open and after each successful set (lastReadback changes).
        .task(id: energyMode.lastReadback) {
            let modes = await Task.detached(priority: .utility) { EnergyModeReader.readCustom() }.value
            perSourceModes = modes
        }
        // ISSUE-9: auto-dismiss the transient picker hold note ~4s after it appears (id-change cancels prior).
        .task(id: pickerHoldNote) {
            guard pickerHoldNote != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { pickerHoldNote = nil }
        }
    }

    // MARK: - helpers

    /// Locale-aware short time-of-day formatter for the sleep/wake read-back ("3:45 PM" / "15:45").
    /// A local copy of BatteryPopoverView's identical formatter — that one stays there (its keep-awake
    /// status line still uses it), so the two files each own a trivial DateFormatter factory.
    private static let clockTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// B4: date + time-of-day for the observed-daemon line. Both timestamps can be days apart (a daemon
    /// that has outlived several builds is the whole failure mode), so the date is not optional here.
    private static let helperTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func helperTimestamp(_ date: Date) -> String {
        helperTimestampFormatter.string(from: date)
    }

    /// The banner tint vocabulary → `DSColor`, so the pure copy layer stays SwiftUI-free (the same
    /// split `PopoverBanner` uses).
    private static func tintColor(_ tint: BannerTint) -> Color {
        switch tint {
        case .attention: DSColor.attention
        case .lowPower:  DSColor.lowPower
        case .neutral:   DSColor.textTertiary
        }
    }

    static func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openShortcuts() {
        if let url = URL(string: "shortcuts://") { NSWorkspace.shared.open(url) }
    }
}
