import Foundation
import Combine
import Shared

// Sprint 3.7 STAGE 3 — app-side controller for the FIRST privileged action. Host-app-free + seamed
// (`EnergyModeSetter`) so the validation + honest-failure mapping are unit-testable without NSXPC.
// Dev-gated this stage (the picker UI is STAGE 5).

/// Honest outcomes of an app→helper energy-mode call. There is NO silent no-op state.
public enum HelperClientError: Error, Equatable {
    case unreachable            // helper not registered / not approved / not running / no reply in time
    case helperError(String)    // the helper replied an `error:*` token (e.g. validation rejection)
}

/// Seam over the privileged set call (HelperClient conforms in production; a mock in tests). It is
/// `@MainActor`: the energy-mode set is a UI-driven action, and the conformance marshals the helper's
/// background-queue reply back to the main actor before calling `completion`, so callers touch UI
/// state directly.
@MainActor
public protocol EnergyModeSetter: AnyObject {
    // `completion` is `@Sendable`: the production conformance (HelperClient) invokes it from NSXPC's
    // background reply/error handlers (then hops to the main actor), so it must cross threads safely.
    func setEnergyMode(mode: Int, source: Int,
                       completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void)
}

@MainActor
public final class EnergyModeController: ObservableObject {

    /// The helper's read-back `powermode` after the last successful set (the honest resulting value).
    @Published public private(set) var lastReadback: String = "—"
    /// An honest, user-facing error from the last attempt (nil when the last attempt succeeded).
    @Published public private(set) var lastError: String?
    @Published public private(set) var isBusy = false
    /// True after an `.unreachable` outcome — the picker DISABLES itself and shows an "approve helper"
    /// affordance (never a silent no-op). Cleared on the next success.
    @Published public private(set) var isHelperUnreachable = false
    /// Whether the hardware supports High Power (STAGE 5: set from `HighPowerCapabilityReader`). Gates
    /// the picker's High Power option. Conservative in BOTH directions: it goes true only on a read
    /// that positively listed the capability, never on a read we could not complete.
    @Published public var highPowerAvailable = false

    /// HAND-OFF #1 (`21ec965`) — the picker's cue when the capability read FAILED rather than answered:
    /// `HighPowerCapability.note`, verbatim. Until now that note had no production reader, which is the
    /// same "the honest value was computed and nothing rendered it" pattern as `BatteryLifetimeSource
    /// .lastFailure`. Rendered by `BatteryPopoverView.energyModeCard`, directly under the segmented
    /// control whose missing third option it explains.
    ///
    /// nil in BOTH healthy states, exactly like `PowerAdapterReadState.note` and
    /// `DeviceReadState.note`: a Mac that has High Power and a Mac that genuinely does not are both
    /// fine and get no sentence. Only "we could not check" speaks.
    @Published public private(set) var highPowerNote: String?

    /// The modes the picker should offer — High Power hidden when the hardware/cap lacks it.
    public var availableModes: [EnergyModeValue] {
        highPowerAvailable ? [.automatic, .low, .high] : [.automatic, .low]
    }

    /// Called after a SUCCESSFUL set so the caller can re-read the Phase-1.8 Energy Mode display (so the
    /// shown value is the honest read-back, never an optimistic UI guess). Not called on failure.
    public var onSetSucceeded: (@MainActor () -> Void)?

    /// auto-energy-mode (sec 0/6): the token the serialization-drop guard reports through the optional
    /// `setMode` completion, so the runner can tell a drop from a helper rejection. NOT a helper error.
    public static let serializedDropToken = "drop:serialized"

    /// The per-call runner-facing completion in flight (sec 0/6). Held (not captured) so the @Sendable
    /// XPC reply closure invokes it via `self`, mirroring `onSetSucceeded`. Cleared before it fires.
    /// One at a time — `isBusy` serializes, so there is never more than one pending.
    private var pendingSetCompletion: (@MainActor (Result<String, HelperClientError>) -> Void)?

    // MARK: - The in-flight backstop (B3)

    /// BACKSTOP BOUND. The seam's contract is "the completion fires exactly once"; nothing ENFORCES it.
    /// `isBusy` is cleared ONLY in the completion, and both surfaces bind `.disabled(… || isBusy)`
    /// (BatteryPopoverView:342, SettingsView:734), so ONE lost completion deadens the Energy Mode picker
    /// for the life of the process — and wedges `AutoEnergyModeRunner.inFlight` while its note still
    /// claims the automation is working.
    ///
    /// 25s, chosen to sit just ABOVE the production conformance's own bound (`HelperClient
    /// .fastCallTimeout` = 20s) so HelperClient always settles a real XPC call first and this backstop
    /// stays invisible in production. It exists because the seam admits OTHER conformances (mocks, the
    /// intent surface, anything added later) and because the failure it prevents is permanent while the
    /// cost of arming it is one timer per set.
    public static let defaultSetTimeout: TimeInterval = 25

    /// How the backstop is armed. Injected so the timeout is testable without burning wall-clock;
    /// production schedules on the main queue — the same actor the seam delivers the completion on.
    /// `@MainActor` because arming and firing both happen there (and so a test double can record the
    /// pending fires in ordinary main-actor state).
    public typealias SetWatchdogScheduler =
        @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    /// Arbitrates reply-vs-backstop. Bumped when a set STARTS and again when the backstop TRIPS, so a
    /// reply that arrives after its deadline is discarded rather than clobbering a newer set's state.
    private var setToken = 0

    private let setTimeout: TimeInterval
    private let scheduleWatchdog: SetWatchdogScheduler

    private let setter: EnergyModeSetter
    public init(setter: EnergyModeSetter,
                setTimeout: TimeInterval = EnergyModeController.defaultSetTimeout,
                scheduleWatchdog: @escaping SetWatchdogScheduler = { delay, fire in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated { fire() }
                    }
                }) {
        self.setter = setter
        self.setTimeout = setTimeout
        self.scheduleWatchdog = scheduleWatchdog
    }

    /// Set the Energy Mode. SERIALIZES against itself (an in-flight set ignores new requests — no
    /// overlapping sets; the op is reversible so no confirm window is needed). App-side PRE-validation
    /// is defense-in-depth (the HELPER re-validates). On an unapproved/unreachable helper we surface an
    /// HONEST error + `isHelperUnreachable` (never a silent no-op). EVERY path settles: the reply, the
    /// serialization drop, the validate rejection, or the backstop watchdog — exactly one of them.
    public func setMode(_ mode: Int, source: Int,
                        completion: (@MainActor (Result<String, HelperClientError>) -> Void)? = nil) {
        guard !isBusy else {
            // serialize: drop overlapping sets while one is in flight. The picker passes no completion
            // (byte-unchanged silent drop); the runner passes one so it LEARNS of the drop and re-evaluates.
            completion?(.failure(.helperError(Self.serializedDropToken)))
            return
        }
        guard EnergyModeCommand.validate(mode: mode, source: source) != nil else {
            // S9 FIX. This was the ONE path that returned without firing `completion`, so a caller that
            // bridges this method into an async value (`withCheckedContinuation`) hung here forever —
            // which is why both LiveEnergyRestoring and EnergyModeIntentSurface pre-validate to route
            // AROUND it. It now settles like every other path, reusing the HELPER's own rejection
            // vocabulary (`error:invalid-mode` / `error:invalid-source`) rather than inventing a token.
            lastError = "Invalid energy mode/source (\(mode), \(source))."
            completion?(.failure(.helperError(EnergyModeValue(rawValue: mode) == nil
                                              ? EnergyModeCommand.errInvalidMode
                                              : EnergyModeCommand.errInvalidSource)))
            return
        }
        isBusy = true
        lastError = nil
        pendingSetCompletion = completion   // fired (once) on the single serialized settle path below
        setToken &+= 1
        let token = setToken
        // Arm the backstop BEFORE issuing the call: a conformance that completes synchronously settles
        // first and the watchdog then finds a stale token / a free controller and does nothing.
        scheduleWatchdog(setTimeout) { [weak self] in
            guard let self, self.setToken == token, self.isBusy else { return }
            self.setToken &+= 1        // a reply arriving after the deadline is now a loser: discarded
            self.finishSet(.failure(.unreachable))
        }
        // `completion` is `@Sendable` (the helper calls it from a background XPC handler, then hops to
        // main). It is delivered ON the main actor, so `assumeIsolated` lets us touch our @MainActor
        // state safely — and matches the helper's marshaling guarantee.
        setter.setEnergyMode(mode: mode, source: source) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.setToken == token else { return }   // lost to the backstop
                self.finishSet(result)
            }
        }
    }

    /// The ONE settle path — reached by the seam's reply OR by the backstop, never both (`setToken`
    /// arbitrates). `isBusy`, the honest state and the runner-facing completion are each resolved
    /// exactly once per set.
    private func finishSet(_ result: Result<String, HelperClientError>) {
        isBusy = false
        switch result {
        case .success(let token):
            lastReadback = token
            lastError = nil
            isHelperUnreachable = false
            onSetSucceeded?()          // trigger the 1.8 re-read (honest resulting value)
        case .failure(.unreachable):
            isHelperUnreachable = true
            lastError = "Energy helper unavailable — approve it in System Settings → Login Items & Extensions."
        case .failure(.helperError(let token)):
            isHelperUnreachable = false
            lastError = "Energy mode change was rejected by the helper (\(token))."
        }
        // auto-energy-mode (sec 0/6): hand the outcome to the runner LAST — after `isBusy` and the honest
        // state are settled — so its re-evaluate sees a free, consistent controller. Cleared first so a
        // re-entrant set (the runner's re-evaluate) installs its own cleanly.
        let done = pendingSetCompletion
        pendingSetCompletion = nil
        done?(result)
    }

    /// Typed convenience for the picker (maps the enums to the validated {0,1,2} ints).
    public func setMode(_ mode: EnergyModeValue, source: EnergySource) {
        setMode(mode.rawValue, source: source.rawValue)
    }

    /// Called on popover-open so a SINCE-APPROVED helper RE-ENABLES the picker. The disabled state is
    /// transient: a set is what clears `isHelperUnreachable`, but the disabled buttons can't initiate
    /// one — so without this, approving the helper (via the affordance) would leave the picker dead.
    /// Clearing here is honest: it just lets the user try again; if the helper is STILL unreachable the
    /// next set re-disables + re-shows the affordance (the set re-validates — never a fake success).
    public func clearTransientState() {
        isHelperUnreachable = false
        lastError = nil
    }

    // MARK: - High Power capability (B-arc B4, corrected by hand-off #1 of `21ec965`)

    /// B-arc B4: High Power support is a HARDWARE fact that cannot change while the process lives, so
    /// it is resolved once and cached rather than costing a `pmset -g cap` spawn on every popover open.
    ///
    /// ⚠️ THE DEFECT THIS SIGNATURE EXISTS TO KEEP FIXED (graded HIGH). The B4 version cached the
    /// ATTEMPT, not the ANSWER — `highPowerResolved = true` ran BEFORE the await — so a single child
    /// killed at the bound at launch deleted the High Power option from the picker for the entire
    /// session, with no cue and no way back short of quitting the app. "This Mac has no High Power
    /// mode" and "we could not find out" were the same latched `false`.
    ///
    /// A `Bool` cannot tell those apart, so this overload cannot either: EVERY Bool is a settled answer
    /// and latches on the first call, byte-identical in behavior to B4. It stays because the production
    /// call site (`BatteryApp`) still passes `HighPowerCapabilityReader.read`, and because a caller that
    /// genuinely has only a Bool is not lying by latching it. **The recovery below is inert until that
    /// call site passes `HighPowerCapabilityReader.readDetailed` instead** — the one-line hand-off.
    public func resolveHighPowerAvailability(probe: @escaping @Sendable () -> Bool) async {
        await resolveHighPowerAvailability(probe: { probe() ? .supported : .unsupported })
    }

    /// THE CAP, and it is the reason un-latching is affordable. Without it, a permanently broken
    /// `pmset -g cap` would cost a probe on EVERY popover open forever — which is finding A11/A12, the
    /// spawn-count class this audit spent a day removing, reintroduced in the name of a fix.
    ///
    /// Two, and there is no third: attempt 1 is the launch read, attempt 2 is one later moment in time
    /// (the next popover open, on a machine that may have calmed down). A third would be a retry LOOP,
    /// and this codebase's rule — `PmsetProbe.RetryPolicy` has exactly two cases, no `.untilItWorks`,
    /// no backoff — is that recovery is bounded and stated, never open-ended.
    ///
    /// WORST-CASE SPAWNS PER LAUNCH: 2 probes × `HighPowerCapabilityReader.maxSpawnsPerRead` (2, under
    /// `.onceIfCutShort`) = **4 children, then zero forever**, and only on a machine that is actually
    /// killing `pmset` at the 5 s bound. A healthy launch spawns exactly one, unchanged.
    static let highPowerProbeLimit = 2

    /// The three-state resolve. `probe` is the seam (production will pass
    /// `HighPowerCapabilityReader.readDetailed`); it runs off the main actor because it blocks on a
    /// child process.
    ///
    /// Internal, not `public`, because `HighPowerCapability` is internal — same module, same visibility.
    func resolveHighPowerAvailability(probe: @escaping @Sendable () -> HighPowerCapability) async {
        // Three separate reasons not to probe, and they are NOT the same reason:
        //   * `highPowerResolved` — we KNOW. A hardware fact; re-reading it can only cost spawns.
        //   * the cap          — we do not know and have stopped asking (see `highPowerProbeLimit`).
        //   * in-flight        — a probe is running right now; a second popover open must not race it
        //                        into a second child. B4 got this for free by latching before the
        //                        await; un-latching means it has to be said explicitly.
        guard !highPowerResolved,
              highPowerProbeCount < Self.highPowerProbeLimit,
              !highPowerProbeInFlight else { return }
        highPowerProbeInFlight = true
        highPowerProbeCount += 1        // counts probes STARTED — that is what bounds the spawns
        let capability = await Task.detached(priority: .utility) { probe() }.value
        highPowerProbeInFlight = false
        switch capability {
        case .supported, .unsupported:
            // An ANSWER — including a proven absence. This, and only this, is what may be cached, and
            // caching it is what keeps the negative case from paying a spawn on every open.
            highPowerResolved = true
            highPowerAvailable = capability.isSupported
            highPowerNote = nil         // a recovered read retires the cue
        case .unknown:
            // We still do not know. The option stays hidden — hiding one we cannot prove exists is the
            // conservative direction and is NOT what changed — but the absence now explains itself, and
            // nothing latches, so the next open (up to the cap) asks again.
            highPowerAvailable = false
            highPowerNote = capability.note
        }
    }

    /// Test-visible so the "a settled answer, and only a settled answer, is cached" contract can be
    /// asserted without reaching into the spawn.
    private(set) var highPowerResolved = false

    /// Probes actually started this launch. Test-visible so the cap is assertable.
    private(set) var highPowerProbeCount = 0

    /// True only WHILE a probe is awaited — the re-entrancy guard B4 used to get for free by latching
    /// before the await.
    private var highPowerProbeInFlight = false
}
