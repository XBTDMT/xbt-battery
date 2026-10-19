import Foundation
import Combine
@preconcurrency import Shared

/// Exactly-once arbitration for ONE XPC call. THREE parties race to settle a call — the helper's reply,
/// the proxy's error handler, and the watchdog — and they arrive on THREE different queues. `claim()`
/// returns true for exactly one of them, forever, so the caller's completion runs once and only once
/// even when a late reply and an expired deadline collide.
///
/// `@unchecked Sendable` over an `NSLock` (not an actor): the reply/error closures NSXPC invokes are
/// `@Sendable` and synchronous — they need a non-async verdict at the TOP of the closure, before any
/// main-actor hop, so a loser can return without touching state at all.
///
/// `internal` (not `private`) for the same reason `reportPong` / `markUnreachable` are: it makes the
/// arbitration unit-testable without standing up an NSXPC connection.
final class HelperCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    /// True for the FIRST caller only. Every later caller — a reply that lost to the watchdog, a
    /// watchdog that lost to the reply, an error handler firing on a connection we already gave up on —
    /// gets false and must do nothing.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }

    var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return settled }
}

/// App-side XPC client for the privileged ENERGY helper (Sprint 3.7; supersedes the Phase-2
/// charge-inhibit client).
///
/// STAGE 1 = a minimal SKELETON: it opens the code-sign-pinned `.privileged` connection, can `ping`
/// it (the channel smoke test), and surfaces a "helper unreachable" state when the connection
/// invalidates/interrupts (helper not registered / not running). NO privileged ops yet — the energy
/// SET/READ calls and the full registration/approval UX land in later stages. All handler callbacks
/// fire on background queues → every UI update is marshaled to the main actor.
@MainActor
final class HelperClient: ObservableObject {

    // REACHABILITY. `helperUnreachable` is LATCHED true by the real setEnergyMode / collectTaskEnergy /
    // setRepeatingSleepWake / setWakeBehavior error handlers (via markUnreachable) and cleared by any of
    // their successful replies — or by a ping pong. It IS read in production: the popover's helper line
    // (BatteryPopoverView:227) and Settings (SettingsView:237).
    //
    // B-arc follow-on (2026-08-08): ping() is NO LONGER unwired. `probeReachabilityIfLatched()` calls it
    // on popover open, but ONLY while latched. Why it had to be wired: before B4, sustained energy ran
    // collectTaskEnergy on every popover open, and that call's success incidentally cleared the latch —
    // so the banner self-healed as a SIDE EFFECT nobody had written down. B4 correctly moved that fetch
    // to the Details page (nothing on the root reads it), which removed the accidental self-heal and left
    // the banner stuck on a healthy daemon until the user opened Details or set a mode. The conditional
    // probe restores the recovery without restoring the cost: healthy opens issue nothing.
    @Published private(set) var helperUnreachable = false
    @Published private(set) var lastPong = "—"

    // B4 — the POSITIVE half of the signal. `helperUnreachable == false` is not health: a client that
    // has never been asked anything reads exactly the same as a working one, so "the helper is fine"
    // and "we have never checked" were the same pixel. This records the fact separately — has ANY call
    // completed a round trip in this process — and it is deliberately HISTORICAL: a later outage
    // latches `helperUnreachable` without un-proving that the helper once answered. Set by every
    // successful reply, not just `ping`, so a working `setEnergyMode` counts as the evidence it is.
    @Published private(set) var hasResponded = false

    private var connection: NSXPCConnection?

    // MARK: - Watchdog bounds (B3)

    // NSXPC guarantees a reply OR an error handler for a live connection — but a helper that is alive and
    // WEDGED (stuck in a spawn, blocked on its serial mutation queue, killed between accept and reply)
    // produces NEITHER, and every caller of this class latches state that only the completion clears.
    // So every call carries a deadline. Two bounds, because the ops are not the same shape:
    //
    // FAST (the three `pmset` writers + `ping`). The helper's own worst case for ONE bounded spawn is
    // TaskEnergyCommand.spawnTimeoutSeconds (30) + two spawnGraceSeconds (2 + 2) = 34s, and setEnergyMode
    // runs TWO spawns (set + read-back) on the shared serial mutation queue. We deliberately bound
    // SHORTER than that ceiling: a `pmset` write is a sub-second operation, so 20s already covers a cold
    // launchd start of the daemon, the code-sign pinning handshake and a contended mutation queue by two
    // orders of magnitude. And preempting the helper's own ceiling costs nothing — a spawn that actually
    // burns 30s returns nil, so the reply we would have waited for is `error:set-failed`, which drives the
    // SAME honest-failure UI as this timeout. 20s is the point where "slow" stops being a useful
    // hypothesis and "the reply is never coming" starts.
    //
    // SAMPLING (collectTaskEnergy). Here the 30s ceiling is a REAL expectation, not a safety net —
    // powermetrics is allowed to run that long — so the bound must sit ABOVE the helper's own, or the
    // watchdog would routinely preempt a case the helper already handles honestly. 45s = the 34s ceiling
    // + ~11s of IPC/queue slack. (Two samples stacked on the serial sampling queue could still exceed it;
    // accepted — a stacked sample is a second user-driven Details open, and "couldn't sample, try again"
    // is the honest answer there.)
    static let fastCallTimeout: TimeInterval = 20
    static let samplingCallTimeout: TimeInterval = 45

    private func ensureConnection() -> NSXPCConnection? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: BatteryAppIDs.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
            // Pin the HELPER's codified DR (sec 6): identical string to the one validated against the
            // SMAppService registration. Audit-token-backed; rejects an impostor helper.
            c.setCodeSigningRequirement(
                BatteryAppIDs.helperRequirement(teamID: BatteryAppIDs.mainBundleTeamID()))
            // These fire on a background queue too → `@Sendable` (nonisolated) so NSXPC can't trap on a
            // main-actor-isolated closure; `markUnreachable` is nonisolated and hops to main itself.
            c.invalidationHandler = { @Sendable [weak self] in self?.markUnreachable(dropConnection: true) }
            c.interruptionHandler = { @Sendable [weak self] in self?.markUnreachable(dropConnection: false) }
            c.resume()
            connection = c
        }
        return connection
    }

    /// Open a BOUNDED call: the pinned proxy plus the gate that arbitrates its outcome, or nil when no
    /// connection/proxy can be made (in which case `fail(.unreachable)` has already run synchronously on
    /// the main actor — byte-identical to the pre-watchdog early returns).
    ///
    /// The error handler is invoked by NSXPC on a BACKGROUND queue. It MUST be `@Sendable`
    /// (nonisolated): a closure written in this @MainActor type is otherwise inferred main-actor-
    /// isolated, and the current toolchain TRAPS (EXC_BREAKPOINT) when NSXPC calls it off-main.
    /// `markUnreachable` is `nonisolated` and hops to the main actor itself.
    ///
    /// The watchdog is armed on the MAIN queue — the same actor every reply marshals back to — and drives
    /// the IDENTICAL failure sequence a real proxy error drives: `markUnreachable` first (so the latch is
    /// set before anyone is told), then `.unreachable` on the main actor. That is what keeps the existing
    /// self-heal intact: a timeout latches the banner exactly like a hard error, and the conditional
    /// popover-open `ping()` probe clears it again the moment the helper answers.
    private func beginCall(timeout: TimeInterval,
                           dropConnectionOnTimeout: Bool = true,
                           fail: @escaping @Sendable (HelperClientError) -> Void)
        -> (proxy: EnergyHelperProtocol, gate: HelperCallGate)? {
        let gate = HelperCallGate()
        guard let conn = ensureConnection() else {
            if gate.claim() { fail(.unreachable) }
            return nil
        }
        let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable [weak self] _ in
            guard gate.claim() else { return }
            self?.markUnreachable(dropConnection: true)
            DispatchQueue.main.async { MainActor.assumeIsolated { fail(.unreachable) } }
        } as? EnergyHelperProtocol
        guard let proxy else {
            if gate.claim() { fail(.unreachable) }
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { @Sendable [weak self] in
            guard gate.claim() else { return }
            self?.markUnreachable(dropConnection: dropConnectionOnTimeout)
            DispatchQueue.main.async { MainActor.assumeIsolated { fail(.unreachable) } }
        }
        return (proxy, gate)
    }

    /// Channel smoke test (STAGE 2 used it to prove the hardened round-trip succeeds and that a
    /// differently-signed client is rejected). Sets `helperUnreachable=false` + `lastPong` on success.
    /// WIRED (B-arc follow-on) by `probeReachabilityIfLatched()`, which the AppDelegate calls on popover
    /// open — see the note on `helperUnreachable`. Cheapest possible reachability question: no arguments,
    /// no privileged work, one round-trip. Still available directly for a future "test helper" affordance.
    ///
    /// Bounded like every other call — `beginCall` SUBSUMES the old private `remote()` helper (same
    /// pinned proxy, same error handler, plus a deadline), which is why that helper is gone. Two
    /// deliberate differences here: ping has no completion — a lost pong simply leaves the latch as it
    /// was, which is already the honest answer — and its timeout does NOT drop the connection. The probe
    /// is only ever issued while ALREADY latched, so re-latching is a no-op, and a smoke test has no
    /// business tearing a shared connection out from under an in-flight privileged op. A real proxy
    /// ERROR still drops it (a connection that errors is definitively broken).
    func ping() {
        guard let (proxy, gate) = beginCall(timeout: Self.fastCallTimeout,
                                            dropConnectionOnTimeout: false,
                                            fail: { _ in }) else { return }
        proxy.ping { @Sendable [weak self, gate] pong in
            guard gate.claim() else { return }
            self?.reportPong(pong)
        }
    }

    /// Whether a popover open should re-test reachability. TRUE only while the latch is set, so a healthy
    /// helper costs nothing and B4's saving is preserved; a latched one is re-tested once per open and
    /// self-heals the moment the helper answers. Separated from the action so the POLICY is testable
    /// without standing up NSXPC (`probeReachabilityIfLatched` is then correct by inspection).
    var needsReachabilityProbe: Bool { helperUnreachable }

    /// Re-test reachability ONCE, and only while latched unreachable. Called from the popover-open path.
    func probeReachabilityIfLatched() {
        guard needsReachabilityProbe else { return }
        ping()
    }

    /// STAGE 3 — drive the privileged `setEnergyMode` over the pinned connection. HONEST failure (no
    /// silent no-op): if the helper is unreachable/unapproved the proxy's error handler fires and we
    /// report `.unreachable`; an `error:*` reply token becomes `.helperError`; a value is `.success`.
    /// A reply that NEVER arrives becomes `.unreachable` at `fastCallTimeout` (B3) — without that bound a
    /// single lost reply deadens the Energy Mode picker on both surfaces for the life of the process.
    /// `completion` is marshaled to the main actor and runs EXACTLY ONCE.
    func setEnergyMode(mode: Int, source: Int,
                       completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
        guard let (proxy, gate) = beginCall(timeout: Self.fastCallTimeout,
                                            fail: { completion(.failure($0)) }) else { return }
        proxy.setEnergyMode(mode: mode, source: source) { @Sendable [weak self, gate] token in
            guard gate.claim() else { return }   // lost to the watchdog → this call is already settled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.noteReplyReceived()
                    completion(token.hasPrefix("error:") ? .failure(.helperError(token)) : .success(token))
                }
            }
        }
    }

    /// STAGE 4 — drive the read-only `collectTaskEnergy` over the pinned connection. HONEST failure:
    /// unreachable/unapproved → `.unreachable`; an `error:*` token → `.helperError`; plist Data →
    /// `.success`; no reply by `samplingCallTimeout` → `.unreachable` (B3). `completion` is marshaled to
    /// the main actor and runs EXACTLY ONCE.
    func collectTaskEnergy(samples: Int, intervalMs: Int,
                           completion: @escaping @Sendable (Result<Data, HelperClientError>) -> Void) {
        guard let (proxy, gate) = beginCall(timeout: Self.samplingCallTimeout,
                                            fail: { completion(.failure($0)) }) else { return }
        proxy.collectTaskEnergy(samples: samples, intervalMs: intervalMs) { @Sendable [weak self, gate] data, token in
            guard gate.claim() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.noteReplyReceived()
                    if let data { completion(.success(data)) }
                    else { completion(.failure(.helperError(token ?? "error:unknown"))) }
                }
            }
        }
    }

    /// SLEEP/WAKE — drive the privileged setRepeatingSleepWake over the pinned connection. HONEST
    /// failure (no silent no-op): unreachable/unapproved -> .unreachable; an `error:*` reply token ->
    /// .helperError; "ok" -> .success; no reply by `fastCallTimeout` -> .unreachable (B3). `completion`
    /// is marshaled to the main actor and runs EXACTLY ONCE — the uninstall run AWAITS this one.
    func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                               wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int,
                               completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
        guard let (proxy, gate) = beginCall(timeout: Self.fastCallTimeout,
                                            fail: { completion(.failure($0)) }) else { return }
        proxy.setRepeatingSleepWake(sleepEnabled: sleepEnabled, sleepHour: sleepHour, sleepMinute: sleepMinute,
                                    wakeEnabled: wakeEnabled, wakeHour: wakeHour, wakeMinute: wakeMinute,
                                    weekdayMask: weekdayMask) { @Sendable [weak self, gate] token in
            guard gate.claim() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.noteReplyReceived()
                    completion(token.hasPrefix("error:") ? .failure(.helperError(token)) : .success(token))
                }
            }
        }
    }

    /// POWER-NAP / WAKE-FOR-NETWORK — drive the privileged setWakeBehavior over the pinned connection.
    /// HONEST failure (no silent no-op): unreachable/unapproved -> .unreachable; an `error:*` reply
    /// token -> .helperError; "ok" -> .success; no reply by `fastCallTimeout` -> .unreachable (B3).
    /// `completion` is marshaled to the main actor and runs EXACTLY ONCE.
    func setWakeBehavior(powerNapBattery: Bool, powerNapAC: Bool,
                         wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool,
                         completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
        guard let (proxy, gate) = beginCall(timeout: Self.fastCallTimeout,
                                            fail: { completion(.failure($0)) }) else { return }
        proxy.setWakeBehavior(powerNapBattery: powerNapBattery, powerNapAC: powerNapAC,
                              wakeOnNetworkBattery: wakeOnNetworkBattery, wakeOnNetworkAC: wakeOnNetworkAC) { @Sendable [weak self, gate] token in
            guard gate.claim() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.noteReplyReceived()
                    completion(token.hasPrefix("error:") ? .failure(.helperError(token)) : .success(token))
                }
            }
        }
    }

    // MARK: - main-thread marshaling

    /// The one place a completed round trip is recorded. Every op's success path routes through here so
    /// the latch and the B4 evidence flag can never disagree — a reply that cleared the banner but left
    /// the surface saying "nothing has contacted it yet" is exactly the class of dishonesty B4 records.
    private func noteReplyReceived() {
        helperUnreachable = false
        hasResponded = true
    }

    /// The ping reply path — clears the latch, which is what makes the conditional probe self-heal.
    /// `internal` (not private) so the reachability state machine can be driven in tests without an XPC
    /// round-trip; there is no other reason to widen it.
    nonisolated func reportPong(_ pong: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                noteReplyReceived()
                lastPong = pong
            }
        }
    }
    /// `internal` for the same reason as `reportPong` — it is the other half of the latch.
    nonisolated func markUnreachable(dropConnection: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                helperUnreachable = true
                if dropConnection { connection = nil }
            }
        }
    }
}

// STAGE 3: HelperClient is the production `EnergyModeSetter` (the seam EnergyModeController drives).
extension HelperClient: EnergyModeSetter {}

// STAGE 4: HelperClient is the production `TaskEnergyCollecting` (the seam SustainedEnergySource drives).
extension HelperClient: TaskEnergyCollecting {}

// STAGE 2b (sleep/wake): HelperClient is the production `SleepWakeSetter` (the seam the schedule
// controller drives). setRepeatingSleepWake already declared above (Stage 2a) — this conformance is empty.
extension HelperClient: SleepWakeSetter {}

// STAGE 2b-i (power-nap / wake-for-network): HelperClient is the production `WakeBehaviorSetter` (the
// seam WakeBehaviorController drives). setWakeBehavior declared above — this conformance is empty.
extension HelperClient: WakeBehaviorSetter {}
