import XCTest

/// Sprint 4.3 (SPEC 02-SPEC-phase-43-quick-actions.md sec 4): the PURE menu-builder matrix.
/// Given (chargeControlSupported, setupReady, degraded, limit, paused, topUpActive) the builder must
/// emit the correct item list + enabled/checked flags. The NSMenu glue is assembled from this output
/// and is exercised by the owner's manual check (right-click → menu; left-click still opens popover).
final class QuickActionsMenuTests: XCTestCase {

    typealias Item = QuickActionsMenu.Item
    typealias Action = QuickActionsMenu.Action

    /// A fully-capable baseline: supported, set up, verified mode, no pause/top-up, idle engine.
    private func ready(limit: Int? = 80, degraded: Bool = false,
                       paused: Bool = false, topUpActive: Bool = false,
                       setupReady: Bool = true, supported: Bool = true,
                       commandInFlight: Bool = false,
                       keepAwakeOn: Bool = false,
                       keepAwakeActiveDuration: KeepAwakeController.Duration? = nil) -> QuickActionsState {
        QuickActionsState(chargeControlSupported: supported, setupReady: setupReady,
                          degraded: degraded, limit: limit, paused: paused, topUpActive: topUpActive,
                          commandInFlight: commandInFlight,
                          keepAwakeOn: keepAwakeOn, keepAwakeActiveDuration: keepAwakeActiveDuration)
    }

    private func keepAwakeSubmenu(_ items: [Item]) -> [Item]? {
        items.first { $0.title == "Keep Awake" }?.submenu
    }

    // MARK: - finders

    private func item(_ items: [Item], _ action: Action) -> Item? {
        for it in items {
            if it.action == action { return it }
            if let sub = it.submenu, let hit = item(sub, action) { return hit }
        }
        return nil
    }

    private func limitSubmenu(_ items: [Item]) -> [Item]? {
        items.first { $0.submenu != nil }?.submenu
    }

    // MARK: - checkmarks

    func testEachLimitChecked() {
        for v in [80, 85, 90, 95, 100] {
            let items = QuickActionsMenu.build(ready(limit: v))
            let children = limitSubmenu(items)!
            for child in children {
                guard case .setLimit(let cv)? = child.action else { return XCTFail("non-setLimit child") }
                XCTAssertEqual(child.isChecked, cv == v, "only \(v)% checked; \(cv)% wrong")
            }
        }
    }

    func testNoLimitCheckedWhenLimitUnknown() {
        let children = limitSubmenu(QuickActionsMenu.build(ready(limit: nil)))!
        XCTAssertTrue(children.allSatisfy { !$0.isChecked }, "unknown limit → no checkmark")
    }

    func testDegradedCheckmarkOnCustody() {
        // Degraded mode: the caller passes the custody value as `limit`; the checkmark sits on it,
        // with no separate read implied.
        let children = limitSubmenu(QuickActionsMenu.build(ready(limit: 85, degraded: true)))!
        XCTAssertEqual(children.first { $0.isChecked }.flatMap { $0.action },
                       .some(.setLimit(85)), "degraded checkmark on the custody value (85)")
    }

    // MARK: - pause / resume

    func testRunningShowsPauseCharging() {
        XCTAssertEqual(item(QuickActionsMenu.build(ready(paused: false)), .toggleCharging)?.title,
                       "Pause Charging")
    }

    func testPausedShowsResumeAndDisablesTopUp() {
        let items = QuickActionsMenu.build(ready(paused: true))
        XCTAssertEqual(item(items, .toggleCharging)?.title, "Resume Charging")
        XCTAssertEqual(item(items, .topUp)?.isEnabled, false, "paused → Top Up disabled")
    }

    // MARK: - top up

    func testTopUpEnabledWhenReadyIdleUnpaused() {
        XCTAssertEqual(item(QuickActionsMenu.build(ready()), .topUp)?.isEnabled, true)
    }

    func testTopUpActiveDisablesTopUp() {
        XCTAssertEqual(item(QuickActionsMenu.build(ready(topUpActive: true)), .topUp)?.isEnabled, false)
    }

    func testCommandInFlightDisablesTopUp() {
        // 4.3-fix: a command mid-flight greys Top Up in the popover; the menu must match.
        XCTAssertEqual(item(QuickActionsMenu.build(ready(commandInFlight: true)), .topUp)?.isEnabled, false)
    }

    func testCommandInFlightDisablesLimitSubmenu() {
        // 4.3-fix extension: the popover greys the whole Limit control while a command is in flight.
        let items = QuickActionsMenu.build(ready(commandInFlight: true))
        XCTAssertEqual(items.first { $0.submenu != nil }?.isEnabled, false)
    }

    func testCommandInFlightDisablesPauseResume() {
        // 4.3-fix extension: the popover greys Pause/Resume while a command is in flight.
        XCTAssertEqual(item(QuickActionsMenu.build(ready(commandInFlight: true)), .toggleCharging)?.isEnabled, false)
    }

    // MARK: - setup-ready gating

    func testNotSetupReadyDisablesControlItems() {
        let items = QuickActionsMenu.build(ready(setupReady: false))
        XCTAssertEqual(items.first { $0.submenu != nil }?.isEnabled, false, "Limit submenu disabled")
        XCTAssertTrue(limitSubmenu(items)!.allSatisfy { !$0.isEnabled }, "Limit children disabled")
        XCTAssertEqual(item(items, .toggleCharging)?.isEnabled, false, "Pause/Resume disabled")
        XCTAssertEqual(item(items, .topUp)?.isEnabled, false, "Top Up disabled")
        // Navigation / app items stay enabled — they don't depend on charge-control setup.
        XCTAssertEqual(item(items, .showHistory)?.isEnabled, true)
        XCTAssertEqual(item(items, .openBatterySettings)?.isEnabled, true)
        XCTAssertEqual(item(items, .quit)?.isEnabled, true)
    }

    // MARK: - monitoring-only (macOS < 26.4) hides the charge-control group, mirroring the popover

    func testMonitoringOnlyHidesChargeControlGroup() {
        let items = QuickActionsMenu.build(ready(supported: false))
        XCTAssertNil(items.first { $0.title == "Limit" }, "no Limit submenu")
        XCTAssertNil(item(items, .toggleCharging), "no Pause/Resume")
        XCTAssertNil(item(items, .topUp), "no Top Up")
        XCTAssertNil(item(items, .openSchedule), "no Schedule")
        // Always-available items remain — including Keep Awake (an IOPMAssertion, not a charge control).
        XCTAssertNotNil(items.first { $0.title == "Keep Awake" }, "Keep Awake stays in monitoring-only mode")
        XCTAssertNotNil(item(items, .showHistory))
        XCTAssertNotNil(item(items, .openBatterySettings))
        XCTAssertNotNil(item(items, .quit))
    }

    // MARK: - shape / ordering (SPEC sec 2 curated set, in order)

    func testFullMenuShapeAndOrder() {
        let items = QuickActionsMenu.build(ready())
        // Limit submenu, Pause/Resume, Top Up, Keep Awake submenu, Show History, Schedule…, separator,
        // Settings, About, Quit. (#EI-1 inserts Keep Awake after the charge group, before Show History;
        // #29 D-6 (5b) inserts About Battery in the bottom app-level group, before Quit.)
        XCTAssertNotNil(items[0].submenu, "Limit submenu first")
        XCTAssertEqual(items[0].title, "Limit")
        XCTAssertEqual(items[1].action, .toggleCharging)
        XCTAssertEqual(items[2].action, .topUp)
        XCTAssertEqual(items[3].title, "Keep Awake")
        XCTAssertNotNil(items[3].submenu, "Keep Awake submenu")
        XCTAssertEqual(items[4].action, .showHistory)
        XCTAssertEqual(items[5].action, .openSchedule)
        XCTAssertTrue(items[6].isSeparator, "one separator before Settings/About/Quit")
        XCTAssertEqual(items[7].action, .openBatterySettings)
        XCTAssertEqual(items[8].action, .about)
        XCTAssertEqual(items[8].title, "About Battery")
        XCTAssertEqual(items[9].action, .quit)
        XCTAssertEqual(items.count, 10)
        // Exactly one separator at the top level (SPEC restraint; the Keep Awake submenu's own
        // separator is nested, not top-level).
        XCTAssertEqual(items.filter { $0.isSeparator }.count, 1)
    }

    func testLimitSubmenuValuesMatchSanctionedSet() {
        let children = limitSubmenu(QuickActionsMenu.build(ready()))!
        XCTAssertEqual(children.compactMap { if case .setLimit(let v)? = $0.action { return v } else { return nil } },
                       [80, 85, 90, 95, 100])
    }

    // MARK: - #EI-1 keep-awake submenu

    func testKeepAwakeSubmenuPresentAndAlwaysAvailable() {
        // Independent of charge control: present + enabled whether or not the OS supports charge control.
        for supported in [true, false] {
            let items = QuickActionsMenu.build(ready(supported: supported))
            let parent = items.first { $0.title == "Keep Awake" }
            XCTAssertNotNil(parent, "Keep Awake present (supported=\(supported))")
            XCTAssertEqual(parent?.isEnabled, true, "Keep Awake is not gated on charge-control support/setup")
            XCTAssertNotNil(parent?.submenu)
        }
        // Even when charge control isn't set up, keep-awake stays enabled (it's an IOPMAssertion).
        XCTAssertNotNil(QuickActionsMenu.build(ready(setupReady: false)).first { $0.title == "Keep Awake" })
    }

    func testKeepAwakePresetsMatchControllerDurations() {
        let children = keepAwakeSubmenu(QuickActionsMenu.build(ready()))!
        let presetActions = children.compactMap { item -> KeepAwakeController.Duration? in
            if case .keepAwake(let d)? = item.action { return d } else { return nil }
        }
        XCTAssertEqual(presetActions, KeepAwakeController.menuDurations.map(\.duration),
                       "the preset items match the single source of truth (KeepAwakeController.menuDurations)")
        XCTAssertEqual(children.compactMap { $0.action == nil ? nil : $0.title }.first,
                       KeepAwakeController.menuDurations.first?.title, "titles come from the presets")
    }

    func testKeepAwakeOffShowsNoCheckmarkAndNoTurnOff() {
        let children = keepAwakeSubmenu(QuickActionsMenu.build(ready(keepAwakeOn: false)))!
        XCTAssertTrue(children.allSatisfy { !$0.isChecked }, "off → no preset checked")
        XCTAssertNil(children.first { $0.action == .keepAwakeOff }, "off → no Turn Off item")
    }

    func testKeepAwakeActivePresetCheckedAndTurnOffShown() {
        let active = KeepAwakeController.Duration.timed(3600)
        let items = QuickActionsMenu.build(ready(keepAwakeOn: true, keepAwakeActiveDuration: active))
        let children = keepAwakeSubmenu(items)!
        // Exactly the active preset is checked.
        for child in children where child.action != nil && child.action != .keepAwakeOff {
            guard case .keepAwake(let d)? = child.action else { continue }
            XCTAssertEqual(child.isChecked, d == active, "only the active duration is checked")
        }
        // A Turn Off item appears when on.
        XCTAssertNotNil(children.first { $0.action == .keepAwakeOff }, "on → Turn Off present")
    }

    // MARK: - keep-awake lid caveat (the submenu is the highest-traffic surface and had no caveat)

    func testKeepAwakeSubmenuLeadsWithTheLidCaveat() {
        let sub = keepAwakeSubmenu(QuickActionsMenu.build(ready())) ?? []
        XCTAssertEqual(sub.first?.title, QuickActionsMenu.keepAwakeMenuCaveat,
                       "the caveat must be the FIRST thing in the submenu, above the presets")
        XCTAssertTrue(sub.dropFirst().first?.isSeparator ?? false,
                      "a separator keeps the caveat from reading as a selectable preset")
    }

    func testTheLidCaveatIsNotSelectable() {
        // It must render as a plain disabled line: no action, no submenu, not a separator — the shape
        // `makeItem` already turns into an informational row.
        let sub = keepAwakeSubmenu(QuickActionsMenu.build(ready())) ?? []
        let note = sub.first
        XCTAssertNil(note?.action, "a caveat that can be clicked would fire an action")
        XCTAssertNil(note?.submenu)
        XCTAssertFalse(note?.isSeparator ?? true)
        XCTAssertFalse(note?.isEnabled ?? true)
    }

    func testEveryKeepAwakePresetIsStillOfferedBelowTheCaveat() {
        // The caveat must not cost the user a preset.
        let sub = keepAwakeSubmenu(QuickActionsMenu.build(ready())) ?? []
        let titles = sub.compactMap { $0.action != nil ? $0.title : nil }
        for preset in KeepAwakeController.menuDurations {
            XCTAssertTrue(titles.contains(preset.title), "lost preset: \(preset.title)")
        }
    }
}
