import AppKit

/// Sprint 4.3 (SPEC 02-SPEC-phase-43-quick-actions.md): the secondary-click quick-actions menu.
///
/// Two layers, deliberately split so the logic is testable and the AppKit glue is thin:
///   1. `build(_:)` — a PURE function `(state) -> [Item]` with enabled/checked flags. Fully tested.
///   2. `makeMenu(_:target:action:)` — thin AppKit glue that assembles an `NSMenu` from that output.
///
/// EVERY action routes to an EXISTING audited entry point (the AppDelegate's single action selector
/// switches on `Action`). This file adds ZERO control logic — it only SURFACES audited capabilities.
enum QuickActionsMenu {

    /// What a menu item does. The glue stashes this in the item's `representedObject`; the
    /// AppDelegate's one action selector switches on it to call the audited entry point.
    enum Action: Equatable {
        case setLimit(Int)        // -> engine.userSetLimit(v)            (source .user, the popover's path)
        case toggleCharging       // -> engine.pause()/resume()          (label carries which)
        case topUp                // -> TopUpController.topUp()
        case showHistory          // -> open the popover (see FLAG in BatteryApp: can't auto-expand)
        case openSchedule         // -> open the popover (see FLAG: can't scroll-to-section)
        case openBatterySettings  // -> NSWorkspace.open(OBCAdvisor.batterySettingsURL)
        case quit                 // -> NSApplication.shared.terminate(nil)
        case keepAwake(KeepAwakeController.Duration)  // #EI-1 -> keepAwake.enable(.system, duration)
        case keepAwakeOff         // #EI-1 -> keepAwake.disable()
        case about                // #29 D-6 (5b) -> AppDelegate.openAbout() (the R5 About window)
    }

    /// A pure, AppKit-free description of one menu entry (leaf, submenu parent, or separator).
    struct Item: Equatable {
        var title: String
        var action: Action?       // nil for a submenu parent or a separator
        var isEnabled: Bool
        var isChecked: Bool
        var submenu: [Item]?      // non-nil ONLY for the Limit submenu parent
        var isSeparator: Bool

        static func leaf(_ title: String, _ action: Action,
                         enabled: Bool = true, checked: Bool = false) -> Item {
            Item(title: title, action: action, isEnabled: enabled, isChecked: checked,
                 submenu: nil, isSeparator: false)
        }
        static func parent(_ title: String, enabled: Bool, submenu: [Item]) -> Item {
            Item(title: title, action: nil, isEnabled: enabled, isChecked: false,
                 submenu: submenu, isSeparator: false)
        }
        static let separator = Item(title: "", action: nil, isEnabled: false,
                                    isChecked: false, submenu: nil, isSeparator: true)

        /// A non-actionable informational row. `makeItem` already renders exactly this shape — no
        /// action, no submenu, not a separator — as a plain disabled line, so this needs no AppKit
        /// change. Used to carry a caveat INTO the submenu that makes the promise.
        static func note(_ title: String) -> Item {
            Item(title: title, action: nil, isEnabled: false, isChecked: false,
                 submenu: nil, isSeparator: false)
        }
    }

    /// The PURE menu-builder (SPEC sec 4): state -> item list + enabled/checked flags.
    ///
    /// Honesty carries (SPEC sec 3): below macOS 26.4 the charge-control feature is HIDDEN in the
    /// popover, so the menu hides the same group (not shown ≠ silently hidden — the popover doesn't
    /// show it either). When supported-but-not-setup-ready the control items are present-but-DISABLED
    /// (the capability exists; setup is pending) rather than vanishing.
    /// The one-line lid caveat carried into the Keep Awake submenu. Deliberately leads with the
    /// GUARANTEE, like `KeepAwakeController.coverageNote` does — the true half is the useful half —
    /// and is short enough to sit in an NSMenu without wrapping.
    static let keepAwakeMenuCaveat = "Lid open only — closing it sleeps your Mac anyway"

    static func build(_ s: QuickActionsState) -> [Item] {
        var items: [Item] = []

        if s.chargeControlSupported {
            // Limit submenu — checkmark on the current value. In DEGRADED mode that value IS the
            // persisted-custody '· as set' value (the caller passes engine.limit, which is seeded
            // from custody in degraded mode) — no separate read is performed or implied.
            let children = ChargeShortcuts.validLimitValues.map { v in
                Item.leaf("\(v)%", .setLimit(v), enabled: s.setupReady, checked: v == s.limit)
            }
            items.append(.parent("Limit", enabled: s.setupReady && !s.commandInFlight, submenu: children))

            // Pause / Resume — a single item; the label reflects the current state.
            items.append(.leaf(s.paused ? "Resume Charging" : "Pause Charging",
                               .toggleCharging, enabled: s.setupReady && !s.commandInFlight))

            // Top Up — disabled while Paused, already topping up, OR a command is in flight (mirrors
            // the popover's `.disabled(engine.isPaused || engine.commandInFlight)`), and only when
            // setup-ready. (4.3-fix: commandInFlight added so the menu greys Top Up exactly when the
            // popover does.)
            items.append(.leaf("Top Up to 100%", .topUp,
                               enabled: s.setupReady && !s.paused && !s.topUpActive && !s.commandInFlight))
        }

        // #EI-1 keep-awake — ALWAYS available (an in-process IOPMAssertion, independent of charge-control
        // support/setup). One-tap duration presets from the single source of truth; the active preset is
        // checked; a "Turn Off" item appears only when on. Scope defaults to system (display-on lives on
        // the popover row).
        // Honesty carry (keep-awake lid limit): this submenu is the app's highest-traffic keep-awake
        // surface — five one-tap presets, and until now not one word of caveat. The popover says it at
        // the switch; a user who never opens the popover deserves the same fact where they actually
        // tap. Closed-lid operation is not merely unbuilt, it is measured impossible (audit §2.D.0):
        // PreventSystemSleep never enters the system aggregate on battery, AppliesToLimitedPower is
        // refused, and both remaining levers are rejected. Kept to one line because it is a menu.
        var keepAwakeItems: [Item] = [.note(Self.keepAwakeMenuCaveat), .separator]
        keepAwakeItems += KeepAwakeController.menuDurations.map { preset in
            .leaf(preset.title, .keepAwake(preset.duration),
                  checked: s.keepAwakeOn && s.keepAwakeActiveDuration == preset.duration)
        }
        if s.keepAwakeOn {
            keepAwakeItems.append(.separator)
            keepAwakeItems.append(.leaf("Turn Off Keep Awake", .keepAwakeOff))
        }
        items.append(.parent("Keep Awake", enabled: true, submenu: keepAwakeItems))

        // Show History — always available (history needs no charge-control setup).
        items.append(.leaf("Show History", .showHistory))

        // Schedule… — opens the popover's Schedule section (only meaningful when supported; the
        // popover gates its Schedule section on the same support flag). NOT a rebuilt editor.
        if s.chargeControlSupported {
            items.append(.leaf("Schedule…", .openSchedule))
        }

        items.append(.separator)
        items.append(.leaf("Open Battery Settings", .openBatterySettings))
        items.append(.leaf(AboutStrings.menuItem, .about))   // #29 D-6 (5b): the R5 About window
        items.append(.leaf("Quit", .quit))

        return items
    }

    /// AppKit glue: assemble an `NSMenu` from pure items.
    ///
    /// `autoenablesItems = false` is REQUIRED so the builder's explicit `isEnabled` flags stick —
    /// the default would re-derive enablement from the responder chain and ignore our flags.
    @MainActor
    static func makeMenu(_ items: [Item], target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        populate(menu, items: items, target: target, action: action)
        return menu
    }

    /// Refill an EXISTING menu (used by the status item's persistent menu, rebuilt on each open).
    @MainActor
    static func populate(_ menu: NSMenu, items: [Item], target: AnyObject, action: Selector) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for item in items { menu.addItem(makeItem(item, target: target, action: action)) }
    }

    @MainActor
    private static func makeItem(_ item: Item, target: AnyObject, action: Selector) -> NSMenuItem {
        if item.isSeparator { return .separator() }
        let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        mi.isEnabled = item.isEnabled
        mi.state = item.isChecked ? .on : .off
        if let children = item.submenu {
            let sub = NSMenu()
            sub.autoenablesItems = false
            for c in children { sub.addItem(makeItem(c, target: target, action: action)) }
            mi.submenu = sub
        } else if let a = item.action {
            mi.target = target
            mi.action = action
            mi.representedObject = a
        }
        return mi
    }
}

/// A pure snapshot of everything the quick-actions menu needs — no live objects, so `build(_:)`
/// stays a total, testable function. The AppDelegate fills this from the live engine/setup/top-up
/// state at the moment the menu is raised.
///
/// NOTE on the SPEC's `(state, limit, degraded, setupReady, paused, topUpActive)` input list: the
/// single `state` is split here into two orthogonal booleans — `chargeControlSupported` (the macOS
/// ≥ 26.4 gate that decides HIDE vs show) and `setupReady` (shortcuts present → controls can issue,
/// decides DISABLE vs enable). The popover gates on both independently, so the menu must too.
struct QuickActionsState: Equatable {
    /// false below macOS 26.4 (monitoring-only): the whole charge-control group is hidden, exactly
    /// as the popover hides its Charge Limit + Schedule sections.
    var chargeControlSupported: Bool
    /// true only in `.ready` / `.readyDegraded` — controls can actually issue. Mirrors the popover
    /// gate (those two states show controls; `.missing` / `.listUnavailable` / `.unknown` do not).
    var setupReady: Bool
    /// true in `.readyDegraded` — the limit value is custody ('· as set'), no read-back. Carried for
    /// fidelity/provenance; the checkmark lands on `limit`, which the caller sources from custody in
    /// this mode (so the checkmark sits on the custody value without a separate read).
    var degraded: Bool
    /// the current limit (engine.limit when `.known`; nil when `.unknown`).
    var limit: Int?
    var paused: Bool
    var topUpActive: Bool
    /// a command (Set / Pause / Resume / Top Up) is mid-flight. The popover greys ALL THREE controls
    /// while this is true — the Limit+Pause HStack (`.disabled(engine.commandInFlight)`) and Top Up
    /// (`.disabled(engine.isPaused || engine.commandInFlight)`). The menu mirrors it so the two
    /// surfaces gate identically (4.3-fix + extension, architect ruling f15b8f6).
    var commandInFlight: Bool
    /// #EI-1 keep-awake is on — drives the active-preset checkmark + the "Turn Off" item. Independent
    /// of charge-control support/setup (keep-awake is an IOPMAssertion, not a charge control).
    var keepAwakeOn: Bool = false
    /// the active session's duration when on (for the checkmark); nil when off.
    var keepAwakeActiveDuration: KeepAwakeController.Duration? = nil
}
