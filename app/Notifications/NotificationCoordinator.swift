import Foundation
import Combine

/// Sprint 4.4: the ONE observer call site (SPEC sec 0). It subscribes READ-ONLY to the app's already
/// published truth — the 4.D telemetry pipeline, the engine's limit + command source + command
/// status, the monitor's snapshot, and the top-up phase — translates transitions into
/// `NotificationEvent`s (via the pure `NotificationEvents`), runs them through the pure
/// `NotificationDecision.shouldNotify`, and posts survivors. It NEVER drives or gates anything: no
/// writes to the engine, no new timers (it rides existing publishers), no influence on control flow.
///
/// App-only (Combine wiring over live model objects); the judgement it relies on is the pure layers,
/// which are tested host-app-free. Edge detection + the fully-charged / low-battery session latches
/// live here; the cooldowns and the spine live in the pure decision/derivation layers.
@MainActor
final class NotificationCoordinator {

    private let store: NotificationPreferencesStore
    private let dispatcher: NotificationDispatcher
    private let now: () -> Date

    private var cancellables: Set<AnyCancellable> = []

    // Prior values for transition-edge detection.
    private var lastTelemetry: TelemetryChargeState = .unknown
    private var lastLimit: ChargeLimitValue = .unknown
    private var lastTopUpPhase: TopUpController.Phase = .idle
    private var lastStatus: CommandStatus = .idle

    /// #EI-4 / C4: the hot-pack latch + hysteresis band, as a pure value the coordinator merely folds
    /// samples into. It lives here (not in the store) because it is EPISODE state, not a preference —
    /// it is meant to reset on relaunch, exactly like the other edge-detection fields above.
    private var heatAlert = BatteryHeatAlert()

    /// #29 D-5 no-double-surface gate: when the HUD would show a SCHEDULE outcome (user active, popover
    /// closed), the scheduled-applied notification is SUPPRESSED so one outcome never gets both surfaces.
    /// Default `{ false }` preserves the pre-HUD behavior (and keeps every existing test unchanged).
    private var hudWouldShowSchedule: () -> Bool = { false }

    init(store: NotificationPreferencesStore,
         presenter: any NotificationPresenting,
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.dispatcher = NotificationDispatcher(presenter: presenter)
        self.now = now
    }

    /// Wire every read-only subscription. Called exactly once (from the composition root), so this is
    /// the single place notifications attach to the running app.
    func start(pipeline: ChargeTelemetryPipeline,
               engine: ChargeLimitEngine,
               topUp: TopUpController,
               snapshots: AnyPublisher<BatterySnapshot, Never>,
               reading: @escaping () -> (onAC: Bool, soc: Int?),
               hudWouldShowSchedule: @escaping () -> Bool = { false }) {
        self.hudWouldShowSchedule = hudWouldShowSchedule

        // Telemetry-derived events (fully-charged, limit-reached, low-battery) re-evaluate whenever the
        // classifier state OR the snapshot (SoC / power source) changes — both feed the conditions.
        Publishers.Merge(snapshots.map { _ in () }, pipeline.$telemetryState.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let r = reading()
                    self.evaluateTelemetry(state: pipeline.telemetryState, onAC: r.onAC, soc: r.soc, engine: engine)
                }
            }
            .store(in: &cancellables)

        // #EI-4 / C4 hot pack: rides the SAME snapshot publisher the telemetry events above already
        // consume — temperature ALREADY arrives with the snapshot, so this adds no timer, no poll and
        // no extra IOKit read (an audit whose second goal is lowering the app's own draw must not pay
        // for awareness with wakes). Its own subscription rather than the merge above because the heat
        // gate needs the snapshot VALUE, which that merge erases to `()`.
        snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.onSnapshotHeat(snapshot) }
            }
            .store(in: &cancellables)

        // Scheduled-applied: a limit change whose source is .schedule (dropFirst → ignore the seed).
        engine.$limit
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newLimit in
                MainActor.assumeIsolated { self?.onLimit(newLimit, engine: engine) }
            }
            .store(in: &cancellables)

        // Top-up complete: the .reverting → .idle transition, but ONLY when the climb actually reached
        // full (the same revert leg also runs on unplug/TTL/cancel — see onTopUpPhase).
        topUp.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                MainActor.assumeIsolated { self?.onTopUpPhase(phase, engine: engine, reading: reading) }
            }
            .store(in: &cancellables)

        // Setup / automation problem: a broken-control command status.
        engine.confirm.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.onStatus(status) }
            }
            .store(in: &cancellables)
    }

    // MARK: - handlers

    private func evaluateTelemetry(state: TelemetryChargeState, onAC: Bool, soc: Int?, engine: ChargeLimitEngine) {
        // Fully charged — once per charge session: emit on the rising edge, re-arm (clear the ledger)
        // when the full episode ends, so the next session can fire again.
        if let e = NotificationEvents.fullyCharged(onAC: onAC, soc: soc, state: state) {
            emit(e)
        } else {
            rearm(.fullyCharged)
        }

        // Low battery — same session-latch shape (re-armed when no longer low/discharging).
        if let e = NotificationEvents.lowBattery(state: state, soc: soc, threshold: store.prefs.lowBatteryThreshold) {
            emit(e)
        } else {
            rearm(.lowBattery)
        }

        // Limit reached — only on the transition INTO .limitHold (avoids re-pinging every sample while
        // it holds). Cause follows whoever set the limit.
        if state == .limitHold, lastTelemetry != .limitHold {
            emit(NotificationEvents.limitReached(entered: state,
                                                 limit: engine.limit.knownValue,
                                                 source: engine.lastCommandSource))
        }
        lastTelemetry = state
    }

    private func onLimit(_ newLimit: ChargeLimitValue, engine: ChargeLimitEngine) {
        defer { lastLimit = newLimit }
        guard newLimit != lastLimit else { return }
        // #29 D-5 (D10 no-dup): a schedule set that the HUD is showing (user active, popover closed) must
        // NOT also notify. scheduledApplied is nil for non-.schedule sources, so this only gates the
        // schedule case — the HUD and this notification are exactly complementary on the predicate.
        guard !hudWouldShowSchedule() else { return }
        emit(NotificationEvents.scheduledApplied(source: engine.lastCommandSource, limit: newLimit.knownValue))
    }

    private func onTopUpPhase(_ phase: TopUpController.Phase, engine: ChargeLimitEngine,
                              reading: () -> (onAC: Bool, soc: Int?)) {
        defer { lastTopUpPhase = phase }
        guard lastTopUpPhase == .reverting, phase == .idle else { return }
        // The revert leg restores the limit for full/unplug/TTL/cancel alike; only a climb that hit
        // 100% on AC is a true completion. Read it observer-side (TopUpController stays frozen) so we
        // never claim "Topped up to 100%" for an abort (SPEC sec 4 honesty). Matches TopUpController's
        // own full trigger (SoC ≥ 100 on AC).
        let r = reading()
        let reachedFull = r.onAC && (r.soc ?? 0) >= 100
        emit(NotificationEvents.topUpComplete(source: engine.lastCommandSource,
                                              restoredLimit: engine.limit.knownValue,
                                              reachedFull: reachedFull))
    }

    /// Fold one snapshot into the heat gate. Everything conditional is in the pure gate: an
    /// unreadable temperature returns `.silent` and moves nothing, so a macOS that does not publish a
    /// temperature (and a battery not yet read) produces neither an alarm nor a false all-clear.
    /// On `.rearm` the cooldown ledger entry is cleared — the same session-latch shape as
    /// fully-charged / low-battery — so a genuine SECOND heat episode is not swallowed by the hourly
    /// backstop that exists only to bound pathological input.
    private func onSnapshotHeat(_ snapshot: BatterySnapshot) {
        let outcome = heatAlert.evaluate(snapshot.temperatureReading)
        if outcome == .rearm { rearm(.hotBattery) }
        emit(NotificationEvents.hotBattery(outcome: outcome))
    }

    private func onStatus(_ status: CommandStatus) {
        defer { lastStatus = status }
        guard status != lastStatus else { return }
        emit(NotificationEvents.setupProblem(status: status))
    }

    // MARK: - emit / re-arm

    private func emit(_ event: NotificationEvent?) {
        guard let event else { return }
        let n = now()
        guard let plan = NotificationDecision.shouldNotify(
            event: event, prefs: store.prefs, lastNotified: dispatcher.lastNotified, now: n) else { return }
        let key = NotificationDecision.cooldownKey(for: event.kind)
        Task { [dispatcher = self.dispatcher] in await dispatcher.dispatch(plan, key: key, now: n) }
    }

    /// Clear a session latch so the kind can fire again next time its condition rises.
    private func rearm(_ type: NotificationEventType) {
        dispatcher.rearm(type.rawValue)
    }
}
