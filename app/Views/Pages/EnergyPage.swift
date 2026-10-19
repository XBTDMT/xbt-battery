import SwiftUI
import AppKit

/// #30 §4.4 · the Energy tab. Header + Now / Sustained strip, the sample caption, the FULL shared
/// "who is drawing power" ranking (`PowerDrawers` — the same list whose first five the Now tab shows as
/// icons; owner ruling 2026-09-09 evening; icon · name + faint helper subtitle · bar · share), "Power now" (Pack · GPU · Adapter) and "Keeping the Mac
/// awake" (≤ 2 holders — 3 with a single rail — + "+N more", the daemon cue, Quit + confirm for GUI
/// apps). Every figure comes from `EnergyPageModel` (pure, tested); this file is layout and the
/// sampling `.task`s only.
///
/// Layout (owner ruling 2026-09-09 evening): the 297 × 470 pt page DISTRIBUTES its four blocks — header +
/// caption · ranked card · Power now · Keeping the Mac awake — down the frame with flexible `Spacer()`s
/// (the mock's `.pg .page{justify-content:space-between;gap:10px}`), instead of a top-pinned stack. Ranked
/// rows carry `.pg .row` padding 8 · `.kv` rows gap 7. The fixed content is budgeted in
/// `EnergyPageModel.Layout` (tested) so the spacers always have height to share; `.clipped()` is the backstop. Bars stay `share` of the sample total (§14-D7 data honesty); the mock draws them ≈ 1.63 ×
/// share relative to the top row — the owner has not ruled, so the honest width stands.
///
/// Sampling (§8, per-tab task ownership): the page's `.task`s run the 0.5 s snapshot (only when empty
/// or stale), the helper's sustained collect, the adapter read, the assertion inventory and the
/// IOReport rail loop (begin → refresh every 4 s → cancelled by the shell on close / tab switch).
/// No polling survives the page.
struct EnergyPage: View {
    @ObservedObject var energySource: EnergyImpactSource
    @ObservedObject var sustained: SustainedEnergySource
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var powerReader: ComponentPowerReader
    @ObservedObject var powerAdapter: PowerAdapterSource
    @ObservedObject var keepAwakeInventory: KeepAwakeInventorySource
    @ObservedObject var keepAwake: KeepAwakeController
    let appTerminator: AppTerminating

    enum Ranking: Hashable { case now, sustained }

    /// nil = follow the shared preference (Sustained whenever the helper delivers, else Now — owner ruling
    /// 2026-09-09 evening); set when the user flips the strip.
    @State private var ranking: Ranking?
    /// The shared ranking (`PowerDrawers.current`), resolved once per input change — never per render
    /// (identity lookups parse plists and fetch icons).
    @State private var drawers: [PowerDrawersModel.Drawer] = []
    /// Terminability resolved once per holder-set change: pid → the GUI app we can quit.
    @State private var quitTargets: [Int: TerminableApp] = [:]
    /// The app awaiting quit confirmation (nil = no alert).
    @State private var pendingQuit: TerminableApp?
    /// Spec 31 §2.6: the render harness pins the clock; nil in every normal launch.
    @Environment(\.fixtureNow) private var fixtureNow

    // MARK: - derived

    private var sustainedSelectable: Bool { !sustained.isUnavailable }
    private var userChoice: PowerDrawersModel.Source? {
        switch ranking { case .now?: return .snapshot; case .sustained?: return .sustained; case nil: return nil }
    }
    private var chosenSource: PowerDrawersModel.Source {
        PowerDrawers.source(energySource: energySource, sustained: sustained, userChoice: userChoice)
    }
    private var showingSustained: Bool { chosenSource == .sustained }

    private var rankingBinding: Binding<Ranking> {
        Binding(get: { showingSustained ? .sustained : .now },
                set: { ranking = ($0 == .sustained && !sustainedSelectable) ? .now : $0 })
    }

    private var unavailabilityText: String? {
        guard sustained.isUnavailable else { return nil }
        return (sustained.unavailableReason ?? .helperUnavailable).message
    }

    // MARK: - body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSPageHeader(title: "Energy") {
                DSStrip(selection: rankingBinding, pairs: [(.now, "Now"), (.sustained, "Sustained")],
                        isEnabled: sustainedSelectable)
                    .frame(width: 120)
                    .help(unavailabilityText ?? "Now: your apps, a half-second sample · Sustained: everything on the Mac, one-second sample")
                    .accessibilityLabel("Ranking")
                    .accessibilityHint(unavailabilityText ?? "")
            }
            // The coverage note (the EPERM census) rides the tooltip; inline it overflowed (stage-8 parity).
            // Mock: `.faint` 10 px, margin -6px 0 4px — tucked up under the header.
            Text(EnergyPageModel.caption(sustainedSelected: showingSustained, coverageNote: nil))
                .font(.system(size: 10)).foregroundStyle(DSSurface.text3)
                .lineLimit(1).truncationMode(.tail)
                .padding(.top, -6).padding(.bottom, 4)
                .help(energySource.coverageNote() ?? "")

            // `.pg .page{justify-content:space-between;gap:10px}` — the leftover height is shared equally by
            // the three flexible spacers; each keeps at least the mock's gap so the blocks never touch.
            Color.clear.frame(height: 14)

            rankedCard
            if let rest = restOfSampleText { thinStateRow(rest) }

            // Owner ruling (sparse-state variant B, 2026-09-09 night): "Power now" and "Keeping the Mac
            // awake" sit at the BOTTOM of the page with a little air, whatever the ranked card holds.
            Spacer(minLength: 24)

            DSSectionLabel(title: "Power now")
                .padding(.bottom, 3)
            powerNow

            Color.clear.frame(height: 20)

            DSSectionLabel(title: "Keeping the Mac awake")
                .padding(.bottom, 3)
            keepingAwake

            Color.clear.frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dsPageFrame(.fixed, alignment: .top)
        // Rail loop — begin, sample, sleep 4 s, repeat; the shell cancels this on close / tab switch.
        // B-arc B5: 4 s between samples, paired with the reader's 2 s probe (a rolling mean).
        .task {
            powerReader.beginSession()
            while !Task.isCancelled {
                await powerReader.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        // One-shot reads on appearance. A separate `.task` from the loop above: that one never returns.
        .task {
            assert(EnergyPageModel.Layout.frameHeight == DSMetric.pageHeight, "Energy height budget drifted from DSMetric.pageHeight")
            sustained.refresh()
            powerAdapter.refresh()
            keepAwakeInventory.refresh()
            if EnergyPageModel.snapshotNeedsFetch(isEmpty: energySource.apps.isEmpty,
                                                  stalenessNote: energySource.stalenessNote()) {
                await energySource.fetch()
            }
        }
        // The shared ranking, once per input change (`AppIconChoice` holds an NSImage → main actor).
        .task(id: PowerDrawers.key(energySource: energySource, sustained: sustained, userChoice: userChoice)) {
            drawers = PowerDrawers.current(energySource: energySource, sustained: sustained, userChoice: userChoice)
        }
        // Terminability: once per holder-set change (plain terminator seam, no XPC).
        .task(id: keepAwakeInventory.holders.map(\.pid)) {
            var targets: [Int: TerminableApp] = [:]
            for holder in keepAwakeInventory.holders {
                if let app = KeepAwakeTerminator.quitTarget(for: holder, via: appTerminator) {
                    targets[holder.pid] = app
                }
            }
            quitTargets = targets
        }
        // Confirm before a graceful quit, surfacing the app AND its keep-awake reason (Cancel default).
        .alert(quitConfirm?.title ?? "",
               isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
               presenting: pendingQuit) { app in
            Button("Quit", role: .destructive) {
                appTerminator.terminate(app)
                keepAwakeInventory.refresh()
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text(quitConfirm?.body ?? "")
        }
    }

    // MARK: - ranked card

    /// The FULL shared list (up to `PowerDrawersModel.cap`). The card keeps the mock's five-row height
    /// budget (`EnergyPageModel.rowCap`) and scrolls for the rest, so the page frame never moves.
    @ViewBuilder private var rankedCard: some View {
        let rowsShown = min(drawers.count, EnergyPageModel.rowCap)
        let listHeight = CGFloat(rowsShown) * EnergyPageModel.Layout.rankedRow
            + CGFloat(max(0, rowsShown - 1)) * EnergyPageModel.Layout.rankedSeparator
        VStack(alignment: .leading, spacing: 0) {
            if drawers.isEmpty {
                Text(emptyRankingText)
                    .font(.system(size: 12)).foregroundStyle(DSSurface.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.vertical, showsIndicators: drawers.count > rowsShown) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(drawers.enumerated()), id: \.element.id) { index, drawer in
                            if index > 0 {
                                // `.row+.row` — 1px popline.
                                Rectangle().fill(DSSurface.line).frame(height: 1)
                            }
                            rankedRow(drawer)
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 10)   // `.card.list` padding 2px 10px
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSSurface.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))   // `.card` radius 10
    }

    /// The thin row under the card: the share of the sample the listed rows do NOT account for.
    private var restOfSampleText: String? {
        guard !drawers.isEmpty else { return nil }
        let rest = max(0, 1 - drawers.reduce(0) { $0 + $1.share })
        guard rest >= 0.02 else { return nil }
        return "\(EnergyPageModel.percentText(rest)) spread across smaller processes"
    }

    /// A quiet one-line state under a hairline (the Devices tab's `thinStateRow`, variant B).
    private func thinStateRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(DSSurface.line).frame(height: 1).padding(.top, 6)
            Text(text).font(.system(size: 11.5)).foregroundStyle(DSSurface.text3).padding(.top, 6)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var emptyRankingText: String {
        if showingSustained {
            return sustained.isRefreshing && sustained.apps.isEmpty ? "Sampling…" : "No app is using significant energy right now."
        }
        return energySource.isRefreshing && energySource.apps.isEmpty ? "Sampling…" : "No app is using significant energy right now."
    }

    /// icon 22 · displayName + faint subtitle · bar · %.
    @ViewBuilder private func rankedRow(_ drawer: PowerDrawersModel.Drawer) -> some View {
        let pct = EnergyPageModel.percentText(drawer.share)
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                rowIcon(drawer.icon)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(drawer.displayName).font(.system(size: 13)).foregroundStyle(DSSurface.text)
                        .lineLimit(1).truncationMode(.tail)
                    if let subtitle = drawer.subtitle {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(DSSurface.text3)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                    }
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                shareBar(drawer.share)
                Text(pct).font(.system(size: 13).monospacedDigit()).foregroundStyle(DSSurface.text2)
                    .frame(width: 34, alignment: .trailing)
            }
            .frame(width: 120)
        }
        .padding(.vertical, 8)   // `.pg .row` padding 8px 0
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(drawer.displayName)\(drawer.subtitle.map { " \($0)" } ?? ""), \(pct) of \(showingSustained ? "all activity" : "readable apps")")
    }

    @ViewBuilder private func rowIcon(_ choice: AppIconChoice) -> some View {
        Group {
            switch choice {
            case .image(let image):
                Image(nsImage: image).resizable().interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 13)).foregroundStyle(DSSurface.text2)
                    .frame(width: 22, height: 22)
                    .background(DSSurface.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func shareBar(_ share: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DSSurface.control)
                Capsule().fill(DSColor.charging).frame(width: max(0, geo.size.width * min(1, share)))
            }
        }
        .frame(height: 6)
    }

    // MARK: - Power now

    private var railRows: [EnergyPageModel.KVRow] {
        EnergyPageModel.railRows(powerReader.readings, hasProbed: powerReader.hasProbed)
    }

    /// The mock's `.kv` grid: Pack · one row per rail · Adapter.
    @ViewBuilder private var powerNow: some View {
        let s = monitor.snapshot
        // #POPOVER-TREND: the same figure as the Now page's Draw row, never the stale macOS 27 sample.
        let packMilliamps = HeroStats.drawMilliamps(onAC: s.powerSource == .ac, packRising: s.packRising,
                                                    sampledMilliamps: s.amperageMilliamps,
                                                    packInflowMilliamps: s.packInflowMilliamps)
        let pack = EnergyPageModel.packRow(voltageVolts: s.voltageVolts, amperageMilliamps: packMilliamps,
                                           onBattery: s.powerSource == .battery,
                                           fromChargeTrend: s.powerSource == .ac && s.packRising
                                               && s.packInflowMilliamps != nil)
        let adapter = EnergyPageModel.adapterRow(state: powerAdapter.readState, last: powerAdapter.lastRecord)
        DSKVGrid(rows: ([pack] + railRows + [adapter]).map { kvRow($0) }, rowSpacing: 7)   // `.kv` gap 7px 12px
            .accessibilityElement(children: .contain)
    }

    private func kvRow(_ row: EnergyPageModel.KVRow) -> DSKVGrid.Row {
        DSKVGrid.Row(key: row.key, value: kvText(row))
    }

    private func kvText(_ row: EnergyPageModel.KVRow) -> Text {
        let value = Text(row.value).foregroundStyle(row.valueIsFaint ? DSSurface.text3 : DSSurface.text)
        guard let faint = row.faint else { return value }
        return value + Text(" \(faint)").foregroundStyle(DSSurface.text3)
    }

    // MARK: - Keeping the Mac awake

    @ViewBuilder private var keepingAwake: some View {
        let split = EnergyPageModel.visibleHolders(keepAwakeInventory.holders, railCount: railRows.count)
        VStack(alignment: .leading, spacing: 0) {
            if !keepAwakeInventory.hasRead {
                Text("Reading…").font(.system(size: 12.5)).foregroundStyle(DSSurface.text3)
            } else if keepAwakeInventory.holders.isEmpty {
                Text(keepAwake.isOn ? "Only this app." : "Nothing is keeping your Mac awake.")
                    .font(.system(size: 12.5)).foregroundStyle(DSSurface.text2)
            } else {
                DSKVGrid(rows: split.shown.map { holderRow($0) }, rowSpacing: 7)
                    .accessibilityElement(children: .contain)
                let fromApps = keepAwakeInventory.holders.dropFirst(split.shown.count).filter { quitTargets[$0.pid] != nil }.count
                if let more = EnergyPageModel.moreText(split.more, fromApps: fromApps) {
                    thinStateRow(more)
                        .accessibilityLabel("\(split.more) more processes keeping the Mac awake")
                }
            }
        }
    }

    /// One `.kv` row: name · "pid 843 · 5 d 22 h" + faint "· system" for a daemon, or a trailing Quit
    /// (the existing confirm flow) for a GUI app we can terminate.
    private func holderRow(_ holder: KeepAwakeHolder) -> DSKVGrid.Row {
        let detail = EnergyPageModel.holderDetail(holder, now: fixtureNow ?? Date())
        let app = quitTargets[holder.pid]
        let value = Text(detail).foregroundStyle(DSSurface.text)
            + Text(app == nil ? " · system" : "").foregroundStyle(DSSurface.text3)
        let trailing: AnyView? = app.map { target in
            AnyView(
                DSTextAction(title: "Quit") { pendingQuit = target }
                    .help(holder.explanation)
                    .accessibilityLabel("Quit \(holder.displayName)")
            )
        }
        return DSKVGrid.Row(key: holder.displayName, value: value, trailing: trailing)
    }

    /// The confirm-alert copy for the pending quit — composed by the PURE `KeepAwakeTerminator` from the
    /// holder that owns the pending app's pid, so the keep-awake reason is always surfaced.
    private var quitConfirm: (title: String, body: String)? {
        guard let app = pendingQuit,
              let holder = keepAwakeInventory.holders.first(where: { $0.pid == app.pid }) else { return nil }
        return KeepAwakeTerminator.confirmMessage(for: holder)
    }
}
