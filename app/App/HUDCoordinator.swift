import AppKit
import Combine

/// #29 D-5 (D10 / A1 / F4): the app-side HUD coordinator. Observes the outcome publishers (a charge-limit
/// SET, a top-up start) READ-ONLY, evaluates the pure `HUDTrigger` predicate at outcome time, and shows
/// the transient pill via `HUDPanel` anchored under the status item (`StatusItemAnchor`, graceful
/// fallback). Energy-mode intents call `report(...)` from their success hook. It NEVER drives anything;
/// like the notification coordinator it only rides existing publishers.
///
/// No-double-surface: `scheduleWouldShowHUD()` is the gate the notification coordinator consults — the
/// scheduled-applied notification fires exactly when the HUD would NOT, so one schedule outcome gets the
/// HUD XOR the notification, never both. An `.appIntent` set has no competing notification by construction.
@MainActor
final class HUDCoordinator {
    private let panel = HUDPanel()
    private let popoverVisible: () -> Bool
    private let userActive: () -> Bool
    private let buttonFrame: () -> CGRect?
    private let reduceMotion: () -> Bool

    private var cancellables: Set<AnyCancellable> = []
    private var lastLimit: ChargeLimitValue = .unknown

    init(popoverVisible: @escaping () -> Bool,
         userActive: @escaping () -> Bool,
         buttonFrame: @escaping () -> CGRect?,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.popoverVisible = popoverVisible
        self.userActive = userActive
        self.buttonFrame = buttonFrame
        self.reduceMotion = reduceMotion
    }

    /// Subscribe to the outcome publishers. Called once from the composition root. (The "Topping up" HUD is
    /// driven from the Top Up INTENT surface, not a top-up phase observer — a menu / popover Top Up is a
    /// direct in-app action that must NOT show the HUD, and the phase alone can't distinguish it from an
    /// intent-initiated one; the intent surface hook is intent-only, so it's correct by construction.)
    func start(engine: ChargeLimitEngine) {
        lastLimit = engine.limit
        engine.$limit
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] newLimit in
                MainActor.assumeIsolated {
                    guard let self, let engine else { return }
                    defer { self.lastLimit = newLimit }
                    guard newLimit != self.lastLimit, case .known(let n) = newLimit else { return }
                    // The top-up revert leg RESTORES the limit — that's not a "set". .user is suppressed by
                    // the predicate anyway; .appIntent / .schedule are the no-UI SET origins the HUD confirms.
                    let origin = engine.lastCommandSource
                    guard origin != .topUp else { return }
                    self.report(origin: origin, event: .chargeLimitSet(n))
                }
            }
            .store(in: &cancellables)
    }

    /// The single outcome seam: evaluate the predicate and show the HUD if it says so.
    func report(origin: CommandSource, event: HUDEvent) {
        guard HUDTrigger.shouldShow(origin: origin,
                                    popoverVisible: popoverVisible(),
                                    userActive: userActive()) else { return }
        present(event)
    }

    /// 31 §2.2 (T3): the device notice's own seam — it is not a command, so no `CommandSource`. Shown only on
    /// battery, popover closed, user active in the last 120 s, switch on; otherwise dropped.
    func reportDeviceNotice(_ notice: DeviceNotice, onBattery: Bool, switchOn: Bool) {
        guard HUDTrigger.shouldShowDeviceNotice(onBattery: onBattery, popoverVisible: popoverVisible(),
                                                userActive: userActive(), switchOn: switchOn) else { return }
        present(.devicePowerStarted(notice))
    }

    private func present(_ event: HUDEvent) {
        let button = buttonFrame()
        let screen = NSScreen.screens.first { s in button.map { s.frame.intersects($0) } ?? false } ?? NSScreen.main
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.show(event: event,
                   anchorTopLeft: { size in
                       StatusItemAnchor.topLeft(buttonFrame: button, screenFrame: screenFrame, panelSize: size)
                   },
                   reduceMotion: reduceMotion())
    }

    /// The no-double-surface gate (see class note): the scheduled-applied notification fires exactly when
    /// this returns false.
    func scheduleWouldShowHUD() -> Bool {
        HUDTrigger.shouldShow(origin: .schedule, popoverVisible: popoverVisible(), userActive: userActive())
    }
}
