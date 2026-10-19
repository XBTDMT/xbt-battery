import SwiftUI

/// #30 §11 stage 7 · the Devices tab (spec §4.6, round-2 E; R15 parity pass). Header "Devices" + "as of
/// HH:mm today"; a card of device rows (symbol · name · component text · 60 pt bar, lowest charge first,
/// five then "+N more" — fewer when a note or "Powered by this Mac" shares the page,
/// `DevicesPageModel.rowCap(notes:powered:deviceCount:)`); Power adapter Now / Last / Fit as the mock's `.kv` grid
/// (`DSKVGrid`, 7 pt row gap). One fixed frame, no ScrollView (§3). Spec 31 §2.3 (G-1): the "Sleep timers"
/// block moved to Automation's "Sleeps after" row; the page is header · Connected · Powered by this Mac
/// (spec 31 §2.1: measured watts per port, one cost line, corroborated names; shown only once this OS build
/// has reported PowerOutDetails) · Power adapter. The reads run in the page's `.task`, so they happen only
/// while the popover is shown AND this tab is selected (§8).
struct DevicesPage: View {
    @ObservedObject var deviceSource: DeviceBatterySource
    /// #iPhone (2026-09-10): the phone's two routes (Finder sync link · hotspot beacon), one row.
    @ObservedObject var phoneSource: PhoneBatterySource
    /// 31 §2.1 "Powered by this Mac" — the port source's only observer.
    @ObservedObject var portSource: PortPowerSource
    @ObservedObject var powerAdapter: PowerAdapterSource
    @ObservedObject var history: HistoryStore

    /// §14-D2 adapter fit: Wh drained while on power over the last 7 raw days. nil until computed, and
    /// nil when the week holds no on-power measurement (`HistoryMetrics.drainedOnPowerWh`) — both a dash.
    @State private var drainedWh: Double?
    /// Spec 31 §2.6: the render harness pins the clock; nil in every normal launch.
    @Environment(\.fixtureNow) private var fixtureNow
    /// The folded adapter's card (owner ruling Q2 A): hover opens it, a tap pins it — the Now tab's resting-note pattern.
    @State private var adapterCardHover = false
    @State private var adapterCardPinned = false
    /// The folded wireless notes' card (owner ruling 2026-09-29, "fold the warnings w the pop outs"): the same pattern.
    @State private var notesCardHover = false
    @State private var notesCardPinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSPageHeader(title: "Devices") {
                if let asOf = asOfText {
                    Text(asOf).font(.system(size: 13).monospacedDigit()).foregroundStyle(DSSurface.text2)
                }
            }
            // Owner ruling (sparse-state variant B, 2026-09-09): the device card at the top with one quiet
            // thin-state row when only one device is connected; the adapter section anchored from the BOTTOM
            // up, with a little air beneath it. (The mock's six-child space-between column included "Sleep
            // timers", which moved to Automation — spec 31 §2.3; "Powered by this Mac" sits between the card and
            // the adapter block, 30-spec §16 row 31-4.)
            Color.clear.frame(height: 14)
            VStack(alignment: .leading, spacing: 6) {
                DSSectionLabel(title: "Connected")
                devicesCard
                // Owner ruling 2026-09-29: two or more notes fold into ONE resting line under the card (the card's
                // own reason is then not printed inside it); a lone note shows exactly as before.
                if let notes = wirelessNotes, notes.isFolded { wirelessNotesRestLine(notes) }
                else if let phoneNote = phoneSource.note { thinStateRow(phoneNote) }
                else if allDevices.count == 1 { thinStateRow("No other devices nearby") }
            }
            // 31 §2.1 (option 1): under the wireless card, above the bottom-anchored Power adapter block.
            if portSource.display.visibility != .hidden {
                Color.clear.frame(height: 12)
                poweredSection
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                if adapterFolded { foldedAdapter } else {
                    DSSectionLabel(title: "Power adapter")
                    adapterGrid
                }
            }
            Color.clear.frame(height: 12)
        }
        .dsPageFrame(.maxHeight, alignment: .center)
        .task {
            await deviceSource.fetch()
            portSource.refreshLeaves()   // §3.7: the one IOUSB walk per Devices appearance
            powerAdapter.refresh()
            recomputeFit()
        }
        // #iPhone: the beacon browses only while this page is on screen (§8); the sync read is a
        // one-shot per appearance and takes seconds over Wi-Fi, so it runs after the card is up.
        .task {
            phoneSource.startBeacon()
            await withTaskCancellationHandler {
                await phoneSource.refresh()
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            } onCancel: {
                Task { @MainActor in phoneSource.stopBeacon() }
            }
        }
        // A fold that turns off takes its card with it: a pinned card must not reopen on the next fold.
        .onChange(of: adapterFolded) { _, folded in
            if !folded { adapterCardHover = false; adapterCardPinned = false }
        }
        .onChange(of: notesFolded) { _, folded in
            if !folded { notesCardHover = false; notesCardPinned = false }
        }
        .onReceive(history.$recordingSince) { _ in recomputeFit() }   // a flush republishes the store
        // 31 §1.3 (b): the phone's sync reading (USB + ExternalConnected) corroborates its port.
        .onChange(of: phoneSource.resolved, initial: true) { _, resolved in
            portSource.notePhone(PhoneBatteryModel.link(resolved))
        }
    }

    // MARK: - header

    private var asOfText: String? {
        DevicesPageModel.asOfText(asOf: DevicesPageModel.newestAsOf(deviceSource.devices) ?? deviceSource.lastFetch,
                                  now: fixtureNow ?? Date())
    }

    // MARK: - device rows

    /// R15 finding 1: a note line anywhere on the page (the card's `.unavailable` reason, the phone's thin-state note
    /// under the card, or the adapter's Now-failure line) costs one device row, so the page stays inside the
    /// 470 pt frame (with "Powered by this Mac" shown the cap is `DevicesPageModel.rowCap(notes:powered:deviceCount:)`).
    /// The card reason and the phone note together fold into ONE short line (owner ruling 2026-09-29) that costs no row.
    private var noteCount: Int {
        var adapterUnavailable = false
        if case .unavailable = powerAdapter.readState { adapterUnavailable = true }
        return DevicesPageModel.noteCount(cardNote: DevicesPageModel.cardNote(deviceSource.readState),
                                          phoneNote: phoneSource.note, adapterUnavailable: adapterUnavailable)
    }

    /// The card's reason and the phone note, most serious first (`DevicesPageModel.wirelessNotes`).
    private var wirelessNotes: DevicesPageModel.WirelessNotes? {
        DevicesPageModel.wirelessNotes(cardNote: DevicesPageModel.cardNote(deviceSource.readState), phoneNote: phoneSource.note)
    }

    private var notesFolded: Bool { wirelessNotes?.isFolded ?? false }

    /// Accessories from IOPS plus the phone row when either route has it. 31 §1.3: while the iPhone is listed
    /// under "Powered by this Mac" it is left out here — the phone route's row and any IOPS accessory of the
    /// iPhone class — so it is listed once.
    private var allDevices: [DeviceBattery] {
        let all = deviceSource.devices + (phoneSource.resolved.map { [$0.device] } ?? [])
        guard portSource.display.phoneInPowered else { return all }
        return all.filter { $0.deviceClass != .iphone }
    }

    private var rowSet: DevicesPageModel.RowSet {
        DevicesPageModel.rows(allDevices, cap: DevicesPageModel.rowCap(notes: noteCount, powered: portSource.display,
                                                                       deviceCount: allDevices.count,
                                                                       foldedNotesLine: notesFolded))
    }

    /// Q2 A: the adapter block folds into its title line on a crowded page, before the wireless list gives up rows.
    private var adapterFolded: Bool {
        DevicesPageModel.adapterFolded(powered: portSource.display, notes: noteCount, deviceCount: allDevices.count,
                                       foldedNotesLine: notesFolded)
    }

    @ViewBuilder private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if deviceSource.lastFetch == nil {
                emptyLine("Reading devices…", color: DSSurface.text3)
            } else {
                let set = rowSet
                ForEach(Array(set.rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().overlay(DSSurface.line) }
                    deviceRow(row)
                }
                if set.overflow > 0 {
                    Divider().overlay(DSSurface.line)
                    emptyLine("+\(set.overflow) more", color: DSSurface.text2)
                }
                // §6 / 2.G: a failed read is never an empty list. `.noneConnected` says so plainly; an
                // `.unavailable` read shows the reason (with whatever partial rows it did produce above).
                switch deviceSource.readState {
                case .devices:
                    EmptyView()
                case .noneConnected:
                    emptyLine("No devices reporting", color: DSSurface.text2)
                case .unavailable:
                    if set.rows.isEmpty { emptyLine("No devices reporting", color: DSSurface.text2) }
                    if !notesFolded, let note = deviceSource.readState.note {
                        Text(note)
                            .font(.system(size: 10.5)).foregroundStyle(DSColor.attention)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSSurface.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func emptyLine(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    /// The mock's `.dev` row: 16 pt symbol in an 18 pt frame (secondary at .9) · 13 pt name · component
    /// text (11 pt secondary; `lowPower` when low) · 60 × 6 bar. 9 pt vertical padding (mock `.dev{padding:9px 0}`),
    /// hairline between.
    private func deviceRow(_ row: DevicesPageModel.Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: row.symbol)
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
                .foregroundStyle(DSSurface.text2.opacity(0.9))
                .accessibilityHidden(true)
            // The name wins the width over the spacer (the mock shows "AirPods Pro" whole); the component text and bar
            // never compress (S4.9 hotfix), so a name too long for the row is the one that shrinks, then truncates.
            deviceName(row.name)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(row.componentText)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(row.isLow ? DSColor.lowPower : DSSurface.text2)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            bar(fraction: Double(row.percent) / 100, low: row.isLow)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(accessibilityValue(for: row))
    }

    private func accessibilityValue(for row: DevicesPageModel.Row) -> String {
        guard let device = allDevices.first(where: { $0.id == row.id }) else {
            return "\(row.percent) percent"
        }
        return DevicesPageModel.accessibilityValue(device.components)
    }

    /// The mockup's 60 × 6 bar: `pop3` track, green fill (yellow under 20 % — R13).
    private func bar(fraction: Double, low: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DSSurface.control)
                Capsule().fill(low ? DSColor.lowPower : DSColor.charging)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(width: 52, height: 6)
        .accessibilityHidden(true)
    }

    // MARK: - the folded wireless notes

    private func wirelessNoteTint(_ note: DevicesPageModel.WirelessNote) -> Color {
        note.isAttention ? DSColor.attention : DSSurface.text3
    }

    /// "Device batteries unavailable  +1 more note ›": the lead's short form in its own colour, the accent link inline
    /// after it (non-breaking spaces keep the label whole). Hover opens the card, a tap pins it (VoiceOver: a button).
    /// Like the adapter card and the Now tab's notes card it is a nested `.popover`; the page's `didShow` / `didClose`
    /// listeners take only `BatteryPopoverView.mainPopover` (`isMain`), so closing this card cannot blank the page.
    private func wirelessNotesRestLine(_ notes: DevicesPageModel.WirelessNotes) -> some View {
        let more = (notes.moreLabel ?? "").replacingOccurrences(of: " ", with: "\u{00A0}")
        return (Text(notes.restText).foregroundColor(wirelessNoteTint(notes.lead))
                + Text("\u{00A0}\u{00A0}" + more).foregroundColor(DSColor.accent))
            .font(.system(size: 10.5))
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { notesCardHover = $0 }
            .onTapGesture { notesCardPinned.toggle() }
            .popover(isPresented: Binding(
                get: { notesFolded && (notesCardHover || notesCardPinned) },
                set: { if !$0 { notesCardHover = false; notesCardPinned = false } }),
                     arrowEdge: .top) { wirelessNotesCard(notes) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notes.accessibilityLabel)
            .accessibilityHint(notes.accessibilityHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { notesCardPinned.toggle() }
    }

    /// The hover / tap card: EVERY note in full, the lead first (marked with a 2 pt bar in its tint, as on Now).
    private func wirelessNotesCard(_ notes: DevicesPageModel.WirelessNotes) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(notes.cardTitle).font(.system(size: 10)).textCase(.uppercase).tracking(0.5)
                .foregroundStyle(DSSurface.text3)
            ForEach(Array(notes.all.enumerated()), id: \.offset) { i, note in
                Text(note.text).font(.system(size: 10.5)).foregroundStyle(wirelessNoteTint(note))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, i == 0 ? 6 : 0)
                    .overlay(alignment: .leading) {
                        if i == 0 { Rectangle().fill(wirelessNoteTint(note).opacity(0.6)).frame(width: 2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
    }

    // MARK: - power adapter

    /// The folded block: "Power adapter  — · last 94 W ›" on one line, the orange unavailable warning ALWAYS under it.
    /// Hover opens a card with the full Now / Last / Fit grid and the warning, a tap pins it (VoiceOver: a button).
    /// The card is a nested `.popover` like the Now tab's resting-note card: only `BatteryPopoverView.mainPopover`
    /// closing blanks the page (`isMain` filters both `didShow` / `didClose` listeners), so closing this one cannot.
    @ViewBuilder private var foldedAdapter: some View {
        let text = DevicesPageModel.foldedAdapterText(state: powerAdapter.readState, lastWatts: powerAdapter.lastRecord?.watts)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            DSSectionLabel(title: "Power adapter")
            Text(text).font(.system(size: 12).monospacedDigit()).foregroundStyle(DSSurface.text2)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text("›").font(.system(size: 10.5)).foregroundStyle(DSColor.accent)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        .contentShape(Rectangle())
        .onHover { adapterCardHover = $0 }
        .onTapGesture { adapterCardPinned.toggle() }
        .popover(isPresented: Binding(
            get: { adapterCardHover || adapterCardPinned },
            set: { if !$0 { adapterCardHover = false; adapterCardPinned = false } }),
                 arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                adapterGrid
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: 300)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Power adapter, " + DevicesPageModel.foldedAdapterSpokenText(
            state: powerAdapter.readState, lastWatts: powerAdapter.lastRecord?.watts))
        .accessibilityHint("Shows the adapter details")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { adapterCardPinned.toggle() }
        if case .unavailable(let why) = powerAdapter.readState { adapterWarning(why) }
    }

    /// The mock's `.kv` grid: Now / Last / Fit. `.noAdapter` is not a problem and reads faint; only a
    /// failed read speaks, as a line under the grid.
    @ViewBuilder private var adapterGrid: some View {
        DSKVGrid(rows: [nowRow, lastRow, .init(key: "Fit", value: Text(DevicesPageModel.fitText(drainedWh: drainedWh)))],
                 rowSpacing: 7)
        if case .unavailable(let why) = powerAdapter.readState { adapterWarning(why).padding(.top, 2) }
    }

    private func adapterWarning(_ why: String) -> some View {
        Text(why)
            .font(.system(size: 10.5)).foregroundStyle(DSColor.attention)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nowRow: DSKVGrid.Row {
        switch powerAdapter.readState {
        case .connected(let a):
            return .init(key: "Now", value: Text(DevicesPageModel.nowText(a)))
        case .noAdapter:
            return .init(key: "Now", value: Text("not connected").foregroundStyle(DSSurface.text3))
        case .unavailable:
            return .init(key: "Now", value: Text("—").foregroundStyle(DSSurface.text3))
        }
    }

    /// Last: the persisted `adapter.last.v1` record. The PD ladder (`pdProfileMenuText`, re-homed from
    /// the old Power card) hangs off this row as a trailing Menu whenever the live adapter publishes a
    /// ladder; with no ladder the row is plain text.
    private var lastRow: DSKVGrid.Row {
        guard let record = powerAdapter.lastRecord else {
            return .init(key: "Last", value: Text("no adapter seen yet").foregroundStyle(DSSurface.text3))
        }
        let live = powerAdapter.adapter
        let ladderCount = live.map(\.pdProfiles.count).flatMap { $0 > 0 ? $0 : nil }
        let text = DevicesPageModel.lastText(record, ladderCount: ladderCount)
        guard let live, let menuText = live.pdProfileMenuText else {
            return .init(key: "Last", value: Text(text))
        }
        let menu = Menu {
            ForEach(live.pdProfiles, id: \.index) { p in
                Text(rungLabel(p, active: p.index == live.activePdIndex))
            }
        } label: {
            Image(systemName: "chevron.down.circle")
                .font(.system(size: 11))
                .foregroundStyle(DSSurface.text2)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .help("PD profiles: \(menuText)")
        .accessibilityLabel("PD profiles: \(menuText)")
        return .init(key: "Last", value: Text(text), trailing: AnyView(menu))
    }

    /// One ladder rung, the `pdProfileMenuText` vocabulary: "20V/3.75A (active)".
    private func rungLabel(_ p: PdProfile, active: Bool) -> String {
        let v = String(format: "%g", Double(p.voltage_mV) / 1000)
        let a = String(format: "%g", Double(p.current_mA) / 1000)
        return active ? "\(v)V/\(a)A (active)" : "\(v)V/\(a)A"
    }

    private func recomputeFit() {
        let now = Int((fixtureNow ?? Date()).timeIntervalSince1970)
        let raw = history.series(range: (now - 7 * 86_400)...now)
        drainedWh = HistoryMetrics.drainedOnPowerWh(raw: raw, now: now)
    }

    /// A quiet, true line under a thin section (the sparse-state ruling): 11.5 pt tertiary above a dashed rule.
    private func thinStateRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(DSSurface.line).frame(height: 1).padding(.top, 4)
            Text(text).font(.system(size: 11.5)).foregroundStyle(DSSurface.text3).padding(.top, 6)
        }
    }

    // MARK: - 31 §2.1 · Powered by this Mac

    @ViewBuilder private var poweredSection: some View {
        let d = portSource.display
        VStack(alignment: .leading, spacing: 6) {
            poweredHeader(d)
            VStack(alignment: .leading, spacing: 0) {
                if d.visibility == .unread {
                    emptyLine("couldn't read ports", color: DSSurface.text2)
                } else {
                    ForEach(Array(d.rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().overlay(DSSurface.line) }
                        poweredRow(row)
                    }
                    if d.overflow > 0 {
                        Divider().overlay(DSSurface.line)
                        emptyLine("+\(d.overflow) more", color: DSSurface.text2)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSSurface.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Q3 B: the caption and the "as of" stamp share one line; the cost line follows at the normal gap.
            if let line = PortPowerDisplayModel.noteLine(oneIsPhoneCaption: d.oneIsPhoneCaption, staleAsOf: d.staleAsOf) {
                faintLine(line)
            }
            if let cost = d.costSentence { faintLine(cost) }
        }
    }

    /// "Powered by this Mac" · the exact sum on the right ("14.7 W"; on battery, yellow "14.7 W from battery").
    private func poweredHeader(_ d: PortPowerDisplay) -> some View {
        HStack(alignment: .firstTextBaseline) {
            DSSectionLabel(title: "Powered by this Mac")
            Spacer(minLength: 8)
            if let tenths = d.totalTenthsW {
                Text(PortPowerDisplayModel.headerFigure(totalTenths: tenths, onBattery: d.onBattery))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(d.onBattery ? DSColor.lowPower : DSSurface.text2)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// The mock's `.devrow2`: 18 pt symbol · name · faint "· cable" (+ the iPhone's % and ⚡︎) · measured watts +
    /// "exact" (T7). The PD contract appears only in the hover and VoiceOver ("up to 15 W").
    private func poweredRow(_ row: PortPowerDisplay.Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
                .foregroundStyle(DSSurface.text2.opacity(0.9))
                .accessibilityHidden(true)
            // S4.9 hotfix: the trailing figures (watts, "exact", "connected") never compress or wrap. The name and its
            // faint detail are shown together only when both fit; otherwise the detail drops out entirely (never a
            // fragment like a lone "·") and the name truncates with a tail ellipsis.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    poweredName(row)
                    Text(row.detail)
                        .font(.system(size: 13)).foregroundStyle(DSSurface.text3)
                        .lineLimit(1)
                }
                poweredName(row)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            switch row.state {
            case .drawing(let tenths):
                Text(PortPowerDisplayModel.watts(tenths: tenths))
                    .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(DSSurface.text)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                exactTag
            case .notDrawing:
                Text(PortPowerDisplayModel.notDrawingWording)
                    .font(.system(size: 11)).foregroundStyle(DSSurface.text3)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            case .phonePortUnknown:
                EmptyView()
            }
        }
        .padding(.vertical, 6)
        .helpIfPresent(row.contractW.map { "up to \($0) W" })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name) \(row.detail)")
        .accessibilityValue(PortPowerDisplayModel.spokenValue(row))
    }

    private func poweredName(_ row: PortPowerDisplay.Row) -> some View {
        deviceName(row.name)
    }

    /// D2 C (§16 "32 · Devices · names", ruled by the owner 2026-10-18): a device name renders at FULL size (13 pt)
    /// whenever it fits; only a name that would not fit shrinks (down to 0.85), and past that it truncates with a
    /// tail ellipsis. A bare `.minimumScaleFactor` shrank names that fit (seen in the renders: "AirPods Pro"
    /// smaller than "iPhone"), so sizes were mixed; `ViewThatFits` takes the full-size child at its ideal
    /// width when that fits and the shrink-then-truncate child otherwise. Shared by the Connected and Powered
    /// cards so every device name follows one rule.
    private func deviceName(_ name: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(name)
                .font(.system(size: 13)).foregroundStyle(DSSurface.text)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Text(name)
                .font(.system(size: 13)).foregroundStyle(DSSurface.text)
                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
        }
    }

    /// The mock's `.q.x` tag: 9.5 pt, green text, 40 % green hairline, 6 pt radius.
    private var exactTag: some View {
        Text("exact")
            .font(.system(size: 9.5))
            .foregroundStyle(DSColor.charging)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(DSColor.charging.opacity(0.4), lineWidth: 1))
            .padding(.leading, 4)
            .accessibilityHidden(true)
    }

    /// 10.5 pt tertiary, up to two lines (the on-battery cost line wraps).
    private func faintLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5)).foregroundStyle(DSSurface.text3)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    /// `.help` only when there is something to say (an empty tooltip is not "no tooltip").
    @ViewBuilder func helpIfPresent(_ text: String?) -> some View {
        if let text { self.help(text) } else { self }
    }
}
