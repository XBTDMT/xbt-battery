import SwiftUI

/// #30 §4.7 · the Automation page (A2). Header + the local-day timeline + the rules card (wake · limit
/// rules · sleep, chronological) + the action line (Add rule · Resume schedule · Schedule switch) + the
/// closing card (Energy rule + Edit · Keep-awake presets · Sleeps after · Limit now + provenance). Editing happens IN
/// PLACE: a tapped limit rule expands into `At [time] set limit to [strip]` with Done / Delete; wake and
/// sleep expand as ONE block (Wake · Sleep · Days · Done, "via pmset", its own Off); Add opens a dashed
/// editor under the list. The page is a permanent `ScrollView` (§14-B14: a ScrollView↔VStack swap would
/// reset state) that scrolls only while an editor is open OR the measured content is taller than the
/// frame (R15 F1: closing notes can push the last card past the 470 pt frame); every note is one line at
/// rest. At rest the five blocks distribute down the frame with flexible spacers (owner ruling 2026-09-09).
/// Whenever it can scroll it SAYS so (spec 31 Q1): the scroll bar shows and flashes as the page becomes
/// scrollable, and a soft fade sits on the bottom edge while content is below — without these a scrolling
/// page looked exactly like the ISSUE-12 clip. The clip gate reads that cue (`scrolls`, spec 31 §2.5).
///
/// Save paths are the EXISTING controllers (§8): limit rules → `ScheduleRunner.addRule/updateRule/
/// removeRule` (a `false` shows inline — never a silent no-op); sleep/wake → the controller's setters +
/// `apply(confirmed:)` behind `confirmReason` / `applyMessage`, its Off → `cancel` behind `cancelMessage`.
/// Nothing here fires the HUD: the HUD observes the ENGINE's limit outcomes by `lastCommandSource`, and a
/// schedule edit issues no Set of its own (`ScheduleRunner.mutate` only recomputes).
struct AutomationPage: View {
    @ObservedObject var schedule: ScheduleRunner
    @ObservedObject var sleepWake: SleepWakeScheduleController
    @ObservedObject var autoEnergy: AutoEnergyModeRunner
    @ObservedObject var energyMode: EnergyModeController
    @ObservedObject var keepAwake: KeepAwakeController
    @ObservedObject var engine: ChargeLimitEngine
    @ObservedObject var settingsRouter: SettingsRouter
    /// The live power source (for the keep-awake "what this achieves here" note). The shell passes
    /// `monitor.snapshot.powerSource == .ac`.
    var onAC: Bool = false

    /// Which editor is open. One at a time; Done / Cancel / Delete restore the at-rest page.
    private enum Editing: Equatable { case rule(UUID), sleepWake, add }
    @State private var editing: Editing?
    /// The working copy of the rule being edited / added. Committed only on Done / Add.
    @State private var draft: ChargeRule?
    /// The inline rejection ("that time is taken" / "four rules is the limit") — shown when the config
    /// API refused a commit; cleared on the next field change.
    @State private var ruleMessage: String?
    @State private var confirmApply: SleepWakeScheduleController.ConfirmReason?
    @State private var confirmCancel: SleepWakeScheduleController.ConfirmReason?
    /// The page-local "keep the display on too" opt-in for the presets (mirrors the Now tab's).
    @State private var keepDisplayOn = false
    /// The "now" tick's wall clock — refreshed by the page task every 30 s so the tick moves while open.
    @State private var liveNow = Date()
    /// Spec 31 §2.6: the render harness pins the clock; nil in every normal launch.
    @Environment(\.fixtureNow) private var fixtureNow
    /// The page's "now": the harness's pinned moment, else the live 30 s tick.
    private var now: Date { fixtureNow ?? liveNow }
    /// The measured content height (R15 F1) — scrolling unlocks when it exceeds the page frame.
    @State private var contentHeight: CGFloat = 0
    /// Spec 31 §2.5: the clip gate's sink (nil outside the render harness). Automation is a ScrollView, so
    /// its content height is both channels (inside == natural).
    @Environment(\.pageMeasurement) private var pageMeasurement

    /// Q1: content sits below the visible frame (drives the bottom fade). Written only when it flips, so
    /// scrolling does not re-evaluate the page on every frame.
    @State private var contentBelow = false

    private var isEditing: Bool { editing != nil }
    private var canScroll: Bool {
        AutomationPageModel.canScroll(isEditing: isEditing, contentHeight: contentHeight, viewport: DSMetric.pageHeight)
    }
    /// The clip gate's `scrolls` precondition: scrollable AND the fade cue showing (spec 31 §2.5).
    private var scrollCueOn: Bool { canScroll && contentBelow }

    var body: some View {
        ScrollView(.vertical, showsIndicators: canScroll) {
            VStack(alignment: .leading, spacing: 0) {
                // Owner ruling 2026-09-09 (360 × 470 frame): the blocks DISTRIBUTE down the frame — mock
                // `.pg .page{justify-content:space-between;gap:10px}`. Each `Spacer` below is one flex gap;
                // the `frame(minHeight:)` on the stack hands them the leftover height to share equally, so at
                // rest the closing card sits on the bottom edge and the middle blocks spread. When content
                // outgrows the frame (or an editor is open) each spacer collapses to its minimum length and
                // the ScrollView takes over, with the scroll bar + bottom fade (spec 31 Q1).
                DSPageHeader(title: "Automation") {
                    Text(headerLine).font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(DSSurface.text2).lineLimit(1)
                }
                Spacer(minLength: 4)   // ISSUE-12 lever 2: a 4 pt floor (the default is the ≈ 8 pt system spacing)
                // Owner (walkthrough): "you can't tell each section apart" — quiet 12 pt labels name the
                // sections the mock left bare (with six rules the card named itself; with one it does not).
                VStack(alignment: .leading, spacing: 4) {   // ISSUE-12 lever 3: label gap 6 → 4
                    DSSectionLabel(title: "Today")
                    timeline.padding(.bottom, 6)
                }
                Spacer(minLength: 4)   // ISSUE-12 lever 2: a 4 pt floor (the default is the ≈ 8 pt system spacing)
                DSSectionLabel(title: "Schedule").padding(.bottom, 4)   // ISSUE-12 lever 3: label gap 6 → 4
                rulesSection
                // Sparse-state ruling B: with a single rule, one quiet, true suggestion under the card.
                if schedule.config.rules.count <= 1, editing != .add {
                    thinSuggestionRow
                }
                if editing == .add, let d = Binding($draft) {
                    ruleEditor(d, isNew: true).padding(.top, DSMetric.space2)
                }
                sleepWakeStatusLines
                Spacer(minLength: 4)   // ISSUE-12 lever 2: a 4 pt floor (the default is the ≈ 8 pt system spacing)
                actionLine.padding(.vertical, 8)   // mock: .ctl margin:8px 0
                Spacer(minLength: 4)   // ISSUE-12 lever 2: a 4 pt floor (the default is the ≈ 8 pt system spacing)
                VStack(alignment: .leading, spacing: 4) {   // ISSUE-12 lever 3: label gap 6 → 4
                    DSSectionLabel(title: "Other automations")
                    closingCard
                }
            }
            .frame(minHeight: DSMetric.pageHeight, alignment: .top)
            .background(GeometryReader { geo in
                Color.clear
                    .preference(key: ContentHeightKey.self, value: geo.size.height)
                    .preference(key: ScrollProbeKey.self,
                                value: ScrollProbe(top: geo.frame(in: NamedCoordinateSpace.named(Self.scrollSpace)).minY,
                                                   height: geo.size.height))
            })
        }
        .coordinateSpace(NamedCoordinateSpace.named(Self.scrollSpace))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .onPreferenceChange(ScrollProbeKey.self) { p in
            // macOS 14: `onScrollGeometryChange` is macOS 15 only, so the offset is the content's minY in
            // the scroll view's named coordinate space. Written only on a flip.
            let below = AutomationPageModel.hasContentBelow(contentTop: p.top, contentHeight: p.height,
                                                            viewport: DSMetric.pageHeight)
            if below != contentBelow { contentBelow = below }
        }
        // Spec 31 §2.5: the clip gate's sink (nil outside the harness) gets the content height AND the real
        // scroll cue, re-sent whenever either changes; the harness keeps the last value after its settle.
        .onChange(of: contentHeight, initial: true) { _, height in pageMeasurement?.report(height, scrollCueOn) }
        .onChange(of: scrollCueOn) { _, cue in pageMeasurement?.report(contentHeight, cue) }
        .scrollDisabled(!canScroll)
        .scrollBounceBehavior(.basedOnSize)
        // Q1: flash when the page BECOMES scrollable — `onAppear` would fire while `canScroll` is still
        // false from the zero initial content height (spec 31 §2.4). macOS 14.0.
        .scrollIndicatorsFlash(trigger: canScroll)
        .overlay(alignment: .bottom) { bottomFade }
        .task {
            // §8 per-tab ownership: the Automation page owns the pmset read-back (surface-gated spawn).
            // Cancels on close and on tab switch, so the read never runs on the open path.
            sleepWake.refreshReadback()
            liveNow = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                liveNow = Date()
            }
        }
        .task {
            // Spec 31 §2.3: the Automation page owns the sleep-timer read now (it was the Devices page's
            // `.task`). `refreshSleepTimers()` keeps its 300 s cache, so re-opening the tab does not re-spawn
            // pmset. Side effect, intended: the keep-awake live-effect note on this page fills on first view.
            await keepAwake.refreshSleepTimers()
        }
        .onChange(of: schedule.config) { _, cfg in
            // §9 sync rule: two editors, one store — an open rule editor closes on an external change
            // (e.g. Settings · Automation deleted the rule under it).
            if case .rule(let id) = editing, !cfg.rules.contains(where: { $0.id == id }) { closeEditor() }
        }
    }

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    /// Q1: the content's top in the scroll view's coordinate space + its height, reported together so the
    /// fade decision never mixes a new offset with an old height.
    private struct ScrollProbe: Equatable {
        var top: CGFloat
        var height: CGFloat
    }

    private struct ScrollProbeKey: PreferenceKey {
        static let defaultValue = ScrollProbe(top: 0, height: 0)
        /// Keep the measured probe: a sibling node that contributes nothing hands back the `(0, 0)` default, and
        /// a plain `value = nextValue()` would let that default overwrite the real reading (observed in the
        /// render harness — the cue never turned on). A real probe always has a positive height.
        static func reduce(value: inout ScrollProbe, nextValue: () -> ScrollProbe) {
            let next = nextValue()
            if next.height > 0 { value = next }
        }
    }

    private static let scrollSpace = "automation.scroll"

    /// Q1: a soft 24 pt fade into the popover ground on the bottom edge while content is below. It never
    /// takes a click and is hidden from VoiceOver (the content itself is reachable by scrolling).
    @ViewBuilder private var bottomFade: some View {
        if canScroll && contentBelow {
            LinearGradient(colors: [DSSurface.ground.opacity(0), DSSurface.ground],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - header

    private var headerLine: String {
        let next = ChargeSchedule.upcomingLine(now: now, calendar: .current, config: schedule.config)?.rule
        return AutomationPageModel.headerLine(next: next, ruleCount: schedule.config.rules.count)
    }

    // MARK: - timeline (5 pt track, 44 pt tall: labels 9 pt above/below)

    private var timelineModel: AutomationPageModel.Timeline {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let sw = AutomationPageModel.sleepWakeMinutes(config: sleepWake.config, readback: sleepWake.lastReadback)
        return AutomationPageModel.timeline(nowMinute: (c.hour ?? 0) * 60 + (c.minute ?? 0),
                                            sleep: sw.sleep, wake: sw.wake, rules: schedule.config.rules)
    }

    /// Label half-width: labels are 52 pt wide, centred on their tick and clamped inside the track (the
    /// mock right-aligns "23:30 sleep"). R15 F5: a label is drawn only when it sits ≥ 52 pt from the
    /// previous drawn label on the same side; "now" always draws.
    private static let labelHalf: CGFloat = 26

    private func labelX(_ fraction: Double, width: CGFloat) -> CGFloat {
        min(max(width * fraction, Self.labelHalf), max(Self.labelHalf, width - Self.labelHalf))
    }

    private var timeline: some View {
        let t = timelineModel
        return GeometryReader { geo in
            let w = geo.size.width
            // Label candidates in one list so the culling is decided once per layout pass.
            let labels: [AutomationPageModel.TimelineLabel] =
                t.rules.enumerated().map { i, r in
                    .init(text: r.label, x: labelX(r.fraction, width: w), above: i % 2 == 1, priority: false) }
                + [t.wake.map { .init(text: $0.label, x: labelX($0.fraction, width: w), above: true, priority: false) },
                   t.sleep.map { .init(text: $0.label, x: labelX($0.fraction, width: w), above: false, priority: false) },
                   .init(text: t.now.label, x: labelX(t.now.fraction, width: w), above: true, priority: true)]
                    .compactMap { $0 }
            let drawn = AutomationPageModel.drawnLabels(labels, minGap: 52)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(DSSurface.control).frame(width: w, height: 5).offset(y: 21)
                ForEach(Array(t.spans.enumerated()), id: \.offset) { _, span in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(DSColor.onPower.opacity(0.6))
                        .frame(width: max(2, w * (span.upperBound - span.lowerBound)), height: 5)
                        .offset(x: w * span.lowerBound, y: 21)
                }
                ForEach(Array(t.rules.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(DSColor.charging).frame(width: 2, height: 5)
                        .offset(x: w * r.fraction - 1, y: 21)
                }
                Rectangle().fill(DSSurface.text).frame(width: 2, height: 9)
                    .offset(x: w * t.now.fraction - 1, y: 19)
                ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                    if drawn[i] { timelineLabel(l.text, cx: l.x, above: l.above, primary: l.priority) }
                }
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day timeline, \(t.now.label)")
    }

    /// A 9 pt label at the (already clamped) centre `cx`; secondary, "now" primary.
    private func timelineLabel(_ text: String, cx: CGFloat, above: Bool, primary: Bool) -> some View {
        Text(text)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(primary ? DSSurface.text : DSSurface.text2)
            .lineLimit(1).fixedSize()
            .frame(width: Self.labelHalf * 2)
            .position(x: cx, y: above ? 8 : 38)
    }

    // MARK: - rules card (chronological; an editing row splits the card around its editor)

    private var rows: [AutomationPageModel.Row] {
        AutomationPageModel.rows(config: sleepWake.config, rules: schedule.config.rules)
    }

    private var nextRuleID: UUID? {
        ChargeSchedule.upcomingLine(now: now, calendar: .current, config: schedule.config)?.rule.id
    }

    private enum Segment: Identifiable {
        case card([AutomationPageModel.Row])
        case ruleEditor(ChargeRule)
        case sleepWakeEditor
        var id: String {
            switch self {
            case .card(let rows): "card-" + rows.map(\.id).joined(separator: ",")
            case .ruleEditor(let r): "edit-" + r.id.uuidString
            case .sleepWakeEditor: "edit-sleepwake"
            }
        }
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var pending: [AutomationPageModel.Row] = []
        var sleepWakeEmitted = false
        func flush() { if !pending.isEmpty { out.append(.card(pending)); pending = [] } }
        for row in rows {
            switch row {
            case .limit(let r) where editing == .rule(r.id):
                flush(); out.append(.ruleEditor(r))
            case .wake, .sleep:
                if editing == .sleepWake {
                    if !sleepWakeEmitted { flush(); out.append(.sleepWakeEditor); sleepWakeEmitted = true }
                } else { pending.append(row) }
            default:
                pending.append(row)
            }
        }
        flush()
        return out
    }

    private var sleepWakeOff: Bool { !sleepWake.config.sleepEnabled && !sleepWake.config.wakeEnabled }

    @ViewBuilder private var rulesSection: some View {
        let segs = segments
        VStack(alignment: .leading, spacing: DSMetric.space2) {
            ForEach(segs) { seg in
                switch seg {
                case .card(let rows):
                    card {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { Divider().overlay(DSSurface.line.opacity(0.5)) }
                            ruleRow(row)
                        }
                    }
                case .ruleEditor(let r):
                    if let d = Binding($draft) { ruleEditor(d, isNew: false) } else { ruleRow(.limit(r)) }
                case .sleepWakeEditor:
                    sleepWakeEditor
                }
            }
            // Reachability: with neither side enabled there is no wake/sleep row to tap, so a single
            // "Sleep & wake · off ›" row (or the editor) stands in. Not in the mock; listed deviation.
            if sleepWakeOff {
                if editing == .sleepWake { sleepWakeEditor }
                else {
                    card {
                        rowButton(time: "—", title: "Sleep & wake", caption: "off") { openSleepWake() }
                    }
                }
            }
            if segs.isEmpty && !sleepWakeOff {
                card { Text("No rules").font(.system(size: 12)).foregroundStyle(DSSurface.text3).padding(.vertical, 5) }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 10).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSSurface.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private func ruleRow(_ row: AutomationPageModel.Row) -> some View {
        switch row {
        case .limit(let r):
            let caption = AutomationPageModel.limitCaption(fired: schedule.isFired(r), isNext: nextRuleID == r.id)
            rowButton(time: row.time, title: row.title, caption: caption) { openRule(r) }
        case .wake, .sleep:
            rowButton(time: row.time, title: row.title,
                      caption: AutomationPageModel.daysCaption(weekdayMask: sleepWake.config.weekdayMask)) { openSleepWake() }
        }
    }

    private func rowButton(time: String, title: String, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(time).font(.system(size: 12).monospacedDigit()).foregroundStyle(DSSurface.text)
                    .frame(width: 44, alignment: .leading)
                Text(title).font(.system(size: 12)).foregroundStyle(DSSurface.text)
                Spacer(minLength: 4)
                Text(caption.isEmpty ? "›" : "\(caption) ›")
                    .font(.system(size: 12)).foregroundStyle(DSSurface.text3).lineLimit(1)
            }
            .padding(.vertical, 5)   // mock .rule{padding:7px 0}; 5 pt = ISSUE-12 lever 1 (spec 31 §2.4, 30-spec §16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(time) \(title)\(caption.isEmpty ? "" : ", \(caption)")")
        .accessibilityHint("Edit")
    }

    // MARK: - editors

    private func openRule(_ r: ChargeRule) {
        confirmApply = nil; confirmCancel = nil; ruleMessage = nil
        draft = r; editing = .rule(r.id)
    }

    private func openSleepWake() {
        confirmApply = nil; confirmCancel = nil; ruleMessage = nil
        draft = nil; editing = .sleepWake
    }

    private func closeEditor() {
        editing = nil; draft = nil; ruleMessage = nil; confirmApply = nil; confirmCancel = nil
    }

    /// `.editor` — a hairline box, radius 8, 8×10 padding; dashed for the Add draft.
    private func editorBox<Content: View>(dashed: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DSSurface.line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            )
    }

    /// `.field` — the compact DatePicker in a control-fill chip. Listed deviation (§14-B10): the native
    /// compact picker carries its own bezel and 12-h locale text.
    private func timeField(_ date: Binding<Date>) -> some View {
        DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .datePickerStyle(.compact).labelsHidden().controlSize(.small).fixedSize()
            .padding(.horizontal, 2)
            .background(DSSurface.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func editorKey(_ text: String, width: CGFloat? = 36) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(DSSurface.text2).lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private func editorCaption(_ text: String, tint: Color = DSSurface.text3) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(tint).lineLimit(1)
    }

    // The limit-rule editor: `At [time] set limit to [80|85|90|95|100]` · caption · Done / Delete (or Add / Cancel).
    private func ruleEditor(_ rule: Binding<ChargeRule>, isNew: Bool) -> some View {
        let strip = ChargeShortcuts.validLimitValues.map { ($0, "\($0)") }
        return editorBox(dashed: isNew) {
            HStack(spacing: 8) {
                editorKey("At")
                timeField(ruleTimeBinding(rule))
                editorKey("set limit to", width: nil)
                DSStrip(selection: Binding(get: { rule.wrappedValue.limit },
                                           set: { rule.wrappedValue.limit = $0; ruleMessage = nil }),
                        pairs: strip)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 10) {
                editorKey("")
                if let msg = ruleMessage { editorCaption(msg, tint: DSColor.attention) }
                else { editorCaption(isNew ? "every day" : "every day · max 4 · unique times") }
                Spacer(minLength: 4)
                if isNew {
                    DSTextAction(title: "Add") { commitDraft(isNew: true) }
                    DSTextAction(title: "Cancel", dim: true) { closeEditor() }
                } else {
                    DSTextAction(title: "Done") { commitDraft(isNew: false) }
                    DSTextAction(title: "Delete", role: .destructive) {
                        schedule.removeRule(id: rule.wrappedValue.id); closeEditor()
                    }
                }
            }
        }
    }

    /// The commit: the config API's `false` becomes the inline message (§4.7 — never a silent no-op).
    /// Editing never touches the current limit: `ScheduleRunner.mutate` recomputes against the fired-set,
    /// so the fired occurrence survives and any divergence is offered as Resume on the action line.
    private func commitDraft(isNew: Bool) {
        guard let d = draft else { return }
        let ok = isNew ? schedule.addRule(d) : schedule.updateRule(d)
        if ok { closeEditor() }
        else {
            ruleMessage = AutomationPageModel.rejectionMessage(config: schedule.config, rule: d, isNew: isNew,
                                                               configUnreadable: schedule.configUnreadable)
                ?? "that change wasn’t accepted"
        }
    }

    /// hour:minute ↔ a Date binding (the date part is a fixed dummy day) — ported from Settings.
    private func ruleTimeBinding(_ rule: Binding<ChargeRule>) -> Binding<Date> {
        Binding(
            get: { Self.dummyDate(hour: rule.wrappedValue.hour, minute: rule.wrappedValue.minute) },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                rule.wrappedValue.hour = c.hour ?? rule.wrappedValue.hour
                rule.wrappedValue.minute = c.minute ?? rule.wrappedValue.minute
                ruleMessage = nil
            })
    }

    private static func dummyDate(hour: Int, minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
    }

    // The sleep & wake block: Wake [time] Sleep [time] Done · Days ○○○○○○○ "via pmset" · Off + confirms.
    private var sleepWakeEditor: some View {
        editorBox(dashed: false) {
            HStack(spacing: 6) {
                editorKey("Wake")
                sideToggle(isOn: Binding(get: { sleepWake.config.wakeEnabled }, set: { sleepWake.setWakeEnabled($0) }),
                           label: "Wake enabled")
                timeField(wakeTimeBinding).disabled(!sleepWake.config.wakeEnabled)
                editorKey("Sleep", width: nil)
                sideToggle(isOn: Binding(get: { sleepWake.config.sleepEnabled }, set: { sleepWake.setSleepEnabled($0) }),
                           label: "Sleep enabled")
                timeField(sleepTimeBinding).disabled(!sleepWake.config.sleepEnabled)
                Spacer(minLength: 2)
                DSTextAction(title: "Done") { doneSleepWake() }
                    .disabled(sleepWake.isApplyInFlight || !sleepWake.config.isValid || sleepWake.config.isCancel)
                    .opacity(sleepWake.isApplyInFlight || !sleepWake.config.isValid || sleepWake.config.isCancel ? 0.5 : 1)
            }
            HStack(spacing: 10) {
                editorKey("Days")
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { bit in dayCircle(bit: bit) }
                }
                Spacer(minLength: 4)
                editorCaption("via pmset")
                if !sleepWakeOff || !(sleepWake.lastReadback?.events.isEmpty ?? true) {
                    DSTextAction(title: "Off", dim: true) { offSleepWake() }
                        .disabled(sleepWake.isApplyInFlight)
                }
            }
            if !sleepWake.config.isValid {
                editorCaption("Sleep and wake can’t be the same time.", tint: DSColor.attention)
            }
            if let reason = confirmApply {
                Text(reason.applyMessage).font(.system(size: 10.5)).foregroundStyle(DSColor.attention)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    DSTextAction(title: "Replace and apply") {
                        sleepWake.apply(confirmed: true); confirmApply = nil; closeEditor()
                    }
                    DSTextAction(title: "Cancel", dim: true) { confirmApply = nil }
                }
            }
            if let reason = confirmCancel {
                Text(reason.cancelMessage).font(.system(size: 10.5)).foregroundStyle(DSColor.attention)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    DSTextAction(title: "Remove it", role: .destructive) {
                        sleepWake.cancel(confirmed: true); confirmCancel = nil; closeEditor()
                    }
                    DSTextAction(title: "Keep it", dim: true) { confirmCancel = nil }
                }
            }
            if keepAwake.isOn && sleepWake.config.sleepEnabled {
                editorCaption("Keep awake is on, so a scheduled sleep may not take effect until it ends.",
                              tint: DSSurface.text2)
            }
        }
    }

    /// Done → ONE read of the gating fact (§14-C4): a non-nil `confirmReason` shows `applyMessage` inline
    /// before `apply(confirmed: true)`; nil applies at once.
    private func doneSleepWake() {
        if let reason = sleepWake.confirmReason(for: sleepWake.lastReadback) { confirmApply = reason }
        else { sleepWake.apply(confirmed: true); closeEditor() }
    }

    /// The block's own Off (§14-C5): `pmset repeat cancel` clears the WHOLE repeating schedule, so a
    /// foreign / unverifiable one takes the same gate with `cancelMessage`.
    private func offSleepWake() {
        confirmApply = nil
        if let reason = sleepWake.confirmReason(for: sleepWake.lastReadback) { confirmCancel = reason }
        else { sleepWake.cancel(confirmed: true); closeEditor() }
    }

    private func sideToggle(isOn: Binding<Bool>, label: String) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.checkbox).controlSize(.mini).labelsHidden()
            .accessibilityLabel(label)
    }

    private static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]
    private static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// A custom circle day button bound to `weekdayMask` (§14-B10: no native chips).
    private func dayCircle(bit: Int) -> some View {
        let on = sleepWake.config.weekdayMask & (1 << bit) != 0
        return Button { sleepWake.toggleWeekday(bit: bit) } label: {
            Text(Self.dayLetters[bit])
                .font(.system(size: 10, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : DSSurface.text2)
                .frame(width: 18, height: 18)
                .background(Circle().fill(on ? AnyShapeStyle(DSColor.onPower) : AnyShapeStyle(DSSurface.control)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.dayNames[bit])
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var sleepTimeBinding: Binding<Date> {
        Binding(get: { Self.dummyDate(hour: sleepWake.config.sleepHour, minute: sleepWake.config.sleepMinute) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                       sleepWake.setSleepTime(hour: c.hour ?? 0, minute: c.minute ?? 0) })
    }

    private var wakeTimeBinding: Binding<Date> {
        Binding(get: { Self.dummyDate(hour: sleepWake.config.wakeHour, minute: sleepWake.config.wakeMinute) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                       sleepWake.setWakeTime(hour: c.hour ?? 0, minute: c.minute ?? 0) })
    }

    /// `lastApplyStatus` rendered at rest and while editing (incl. `.appliedUnverified`, §14-C4).
    @ViewBuilder private var sleepWakeStatusLines: some View {
        let line: (String, Color)? = {
            switch sleepWake.lastApplyStatus {
            case .idle, .applied: return nil
            case .applying: return ("Applying the sleep & wake schedule…", DSSurface.text2)
            case .appliedUnverified:
                return ("Applied, but not confirmed — reading the schedule back didn’t work. Reopening this tab reads it again.",
                        DSSurface.text2)
            case .failed(let token): return ("Schedule change failed (\(token)).", DSColor.attention)
            case .unreachable:
                return ("Energy helper unavailable. Approve it in System Settings to set a schedule.", DSColor.attention)
            }
        }()
        // R15 F1: one line at rest (truncated), the full two lines while an editor is open.
        if let (text, tint) = line {
            Text(text).font(.system(size: 10.5)).foregroundStyle(tint).lineLimit(isEditing ? 2 : 1)
                .truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4).padding(.horizontal, 2)
        }
        if sleepWake.configUnreadable {
            Text("Battery couldn’t read its own saved sleep & wake settings; the fields show defaults. Your Mac’s schedule hasn’t been changed.")
                .font(.system(size: 10.5)).foregroundStyle(DSColor.attention).lineLimit(isEditing ? 2 : 1)
                .truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4).padding(.horizontal, 2)
        }
    }

    // MARK: - action line: Add rule · Resume schedule (N% now) + note · Schedule switch (charge schedule only)

    @ViewBuilder private var actionLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                DSTextAction(title: "Add rule") {
                    confirmApply = nil; confirmCancel = nil; ruleMessage = nil
                    draft = AutomationPageModel.defaultNewRule(config: schedule.config); editing = .add
                }
                // 4g Resume + `schedule.note` are SIBLINGS, never else-chained (the N1 rider).
                if let target = schedule.resumeTarget() {
                    // 360 pt: "Resume schedule (N% now)" wrapped beside Add rule + Schedule; the page reads "Resume".
                    DSTextAction(title: "Resume (\(target)% now)") { schedule.resumeNow() }
                }
                Spacer(minLength: 4)
                Text("Schedule").font(.system(size: 12)).foregroundStyle(DSSurface.text2).lineLimit(1)
                Toggle("", isOn: Binding(get: { schedule.config.enabled }, set: { schedule.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("Charge schedule")
            }
            if let note = schedule.note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(DSSurface.text2)
                    .lineLimit(isEditing ? 2 : 1).truncationMode(.tail)   // R15 F1: one line at rest
                    .fixedSize(horizontal: false, vertical: true)
                    .help(note)
            }
        }
    }

    // MARK: - closing card: Energy · Keep awake · Limit now

    private var closingCard: some View {
        card {
            closingRow("Energy") {
                HStack(spacing: 6) {
                    Text(AutomationPageModel.energyRuleText(enabled: autoEnergy.enabled,
                                                            highWhenPlugged: autoEnergy.highWhenPluggedEnabled))
                        .lineLimit(1)
                    DSTextAction(title: "Edit") { settingsRouter.open(to: .automation) }
                }
            }
            if let note = autoEnergy.autoNote {
                closingCaption(note)
            }
            Divider().overlay(DSSurface.line.opacity(0.5))
            // R15 F4: the display-on (sun) opt-in lives in the row's context menu, not in the row —
            // the mock's row is plain text. Listed deviation.
            closingRow("Keep awake") { keepAwakePresets }
                .contextMenu { displayOnToggle }
                .help(keepDisplayOn ? "Presets keep the display on too (right-click to change)"
                                    : "Presets keep the system awake (right-click to keep the display on too)")
            keepAwakeStatus
            Divider().overlay(DSSurface.line.opacity(0.5))
            // Spec 31 §2.3 (G-1, T1): the Devices "Sleep timers" block lives here now, as one row — the
            // EFFECTIVE idle-sleep minutes per power profile; the raw pmset values ride the hover and VoiceOver.
            let sleeps = sleepsAfter
            closingRow("Sleeps after") { Text(sleeps.text).lineLimit(1).truncationMode(.tail) }
                .help(sleeps.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sleeps after")
                .accessibilityValue(sleeps.text == "—" ? sleeps.help : "\(sleeps.text). \(sleeps.help)")
            Divider().overlay(DSSurface.line.opacity(0.5))
            closingRow("Limit now") { Text(limitNowText).lineLimit(1) }
        }
    }

    private func closingRow<Value: View>(_ key: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 12)).foregroundStyle(DSSurface.text2)
            Spacer(minLength: DSMetric.space2)
            value().font(.system(size: 12).monospacedDigit()).foregroundStyle(DSSurface.text)
        }
        .padding(.vertical, 5)   // mock .rowsm{padding:6px 0}; 5 pt = ISSUE-12 lever 4 (spec 31 §2.4, 30-spec §16)
    }

    /// One line at rest (the R15 F1 precedent). `wrap` lets a caption run to its full length — used for the
    /// keep-awake coverage note, whose second half ("Closing the lid sleeps your Mac anyway") is the part
    /// that must never be cut off.
    private func closingCaption(_ text: String, tint: Color = DSSurface.text2, wrap: Bool = false) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(tint)
            .lineLimit(wrap ? nil : 1).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: wrap)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 3)
    }

    /// "30 m · 1 h · 2 h · on power" — plain primary text as in the mock, where each preset is still a
    /// real Button that enables with that duration (scope from the display opt-in); the active preset
    /// is the semibold one. No accent color (R15 F4).
    private var keepAwakePresets: some View {
        HStack(spacing: 4) {
            ForEach(Array(AutomationPageModel.keepAwakePresets.enumerated()), id: \.offset) { i, p in
                if i > 0 { Text("·").foregroundStyle(DSSurface.text3) }
                let active = keepAwake.session?.duration == p.duration
                Button {
                    let scope: KeepAwakeController.Scope = keepDisplayOn ? .systemAndDisplay : .system
                    keepAwake.enable(scope: scope, duration: p.duration)
                    Task { await keepAwake.refreshSleepTimers() }
                } label: {
                    Text(p.label).font(.system(size: 12, weight: active ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(DSSurface.text)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keep awake \(p.label)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    /// The display-on opt-in, re-homed from the row to its context menu (R15 F4 deviation).
    private var displayOnToggle: some View {
        Toggle("Keep the display on too", isOn: Binding(
            get: { keepDisplayOn },
            set: { on in
                keepDisplayOn = on
                if keepAwake.isOn { keepAwake.setScope(on ? .systemAndDisplay : .system) }
            }))
    }

    /// The session status + honesty lines (§14-C8 re-home): "On · 1 hr 5 min left · Off", the partial-hold
    /// / interruption / live-effect notes and the coverage explanation while on; the last-end note when off.
    @ViewBuilder private var keepAwakeStatus: some View {
        if let s = keepAwake.session {
            HStack(spacing: 6) {
                Text(sessionLine(s)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(DSSurface.text2).lineLimit(1)
                DSTextAction(title: "Off", dim: true) { keepAwake.disable() }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 3)
            // Spec 31 stage 2 · T12 (G-8 option F): the coverage explanation lives here now, not on Now.
            // It shows only while a session is on (it is what the session does NOT cover), like the
            // live-effect note below; Automation is allowed to scroll at this state (O4).
            closingCaption(KeepAwakeController.coverageNote, wrap: true)
            if let n = KeepAwakeController.partialHoldNote(requested: s.scope, held: keepAwake.heldKinds) {
                closingCaption("Note: \(n).", tint: DSColor.attention)
            }
            if let n = KeepAwakeController.interruptionNote(s.sleepInterruptions) {
                closingCaption(n, tint: DSColor.attention)
            }
            let timers = keepAwake.sleepTimers?.timers(onAC: onAC)
            if let n = KeepAwakeController.liveEffectNote(scope: s.scope, onAC: onAC, timers: timers) {
                closingCaption(n, tint: KeepAwakeController.isInert(scope: s.scope, timers: timers)
                               ? DSColor.attention : DSSurface.text2)
            }
        } else if let n = KeepAwakeController.lastEndNote(keepAwake.lastEnd) {
            closingCaption(n)
        }
    }

    private func sessionLine(_ s: KeepAwakeController.Session) -> String {
        var parts = ["On"]
        switch s.duration {
        case .timed:
            if let r = keepAwake.remainingSeconds() { parts.append("\(KeepAwakeController.remainingLabel(r)) left") }
        case .whileOnAC: parts.append("while on power")
        case .indefinite: parts.append("until turned off")
        }
        if s.scope == .systemAndDisplay { parts.append("display on") }
        return parts.joined(separator: " · ")
    }

    /// Spec 31 §2.3: "battery 10 min · power never" + the raw settings for the hover / VoiceOver.
    private var sleepsAfter: (text: String, help: String) {
        AutomationPageModel.sleepsAfterText(keepAwake.sleepTimers)
    }

    /// "80% · by schedule at 22:00" (in-session `.schedule` provenance) else "80% · set HH:mm" (custody).
    private var limitNowText: String {
        let operative = ChargeSchedule.operativeOccurrence(now: now, calendar: .current, config: schedule.config)
        return AutomationPageModel.limitNowText(limit: engine.limit.knownValue,
                                                source: engine.lastCommandSource,
                                                operativeTime: operative?.rule.timeLabel,
                                                custodyAt: engine.lastSetCustody?.at)
    }

    /// "Add an evening hold, e.g. 22:00 → 80% · keeps the pack off 100% overnight" — the tappable part
    /// opens the add editor pre-filled; nothing is saved until Add.
    private var thinSuggestionRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(DSSurface.line).frame(height: 1).padding(.top, 6)
            HStack(spacing: 4) {
                Text("Add an evening hold, e.g.").font(.system(size: 11.5)).foregroundStyle(DSSurface.text3)
                DSTextAction(title: "22:00 → 80%") {
                    draft = ChargeRule(hour: 22, minute: 0, limit: 80)
                    editing = .add
                }
                Spacer(minLength: 4)
                Text("keeps the pack off 100% overnight").font(.system(size: 11.5)).foregroundStyle(DSSurface.text3)
                    .lineLimit(1)
            }
            .padding(.top, 6)
        }
    }
}

