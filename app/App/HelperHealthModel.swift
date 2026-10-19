import Foundation
import Combine
import Shared

// MARK: - B4: what the app can actually know about the running helper

/// The two facts a staleness comparison needs, as plain values so the comparison stays pure.
///
/// `daemonStartedAt` is when the *running* privileged daemon process began; `bundledBuiltAt` is when
/// the helper binary *this app ships* was last written. Either may be nil — no daemon is running, or
/// the binary could not be stat'd — and nil is answered honestly rather than guessed at.
struct HelperDaemonImage: Equatable, Sendable {
    var daemonStartedAt: Date?
    var bundledBuiltAt: Date?
}

/// Seam over the two live reads (a `sysctl` process sweep + one `stat`), so the derivation and the copy
/// are testable without touching the machine.
protocol HelperDaemonProbing: Sendable {
    func read() -> HelperDaemonImage
}

/// The production probe. Deliberately privilege-free and subprocess-free:
///
/// * `KERN_PROC_ALL` is world-readable, so a uid-501 app can see a root daemon's pid and start time.
///   Measured on this machine: **0.1 ms** for a 1,057-process table (first call 0.47 ms cold), which is
///   two orders of magnitude under the `shortcuts list` already on the popover-open path — so this is
///   not a new member of the §2.A spawn-per-open family the audit is about.
/// * The comparison mirrors `scripts/relaunch-app.sh`'s helper check, which is the technique that has
///   caught this failure on-device twice. The script compares against the newest helper anywhere under
///   `build/sym`; the app compares against its OWN embedded copy, which is strictly more correct —
///   that is the binary launchd would exec, and the one whose replacement broke the running process's
///   code-sign pin.
///
/// `p_comm` is truncated by the kernel to 16 characters ("com.example.batt" for our label), so the
/// match is a prefix test with a length floor rather than an equality test — robust to a kernel with a
/// different `MAXCOMLEN`, and far too long to collide with anything else on the machine.
struct LiveHelperDaemonProbe: HelperDaemonProbing {
    /// The daemon's full launchd label / executable name.
    let label: String
    /// The helper binary embedded in this app bundle (`Contents/MacOS/<label>`), or nil if unresolvable.
    let bundledHelperURL: URL?

    init(label: String = BatteryAppIDs.helper,
         bundledHelperURL: URL? = LiveHelperDaemonProbe.embeddedHelperURL(named: BatteryAppIDs.helper)) {
        self.label = label
        self.bundledHelperURL = bundledHelperURL
    }

    /// `…/Battery.app/Contents/MacOS/Battery` → `…/Contents/MacOS/com.example.batteryapp.energyhelper`.
    static func embeddedHelperURL(named name: String) -> URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)
    }

    func read() -> HelperDaemonImage {
        HelperDaemonImage(daemonStartedAt: Self.runningDaemonStart(label: label),
                          bundledBuiltAt: bundledHelperURL.flatMap(Self.modificationDate))
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The EARLIEST start time among matching processes. Earliest, not first: if the machine somehow
    /// holds more than one, the oldest is the one that would be serving stale code, and a staleness
    /// warning that under-reports is the useless direction.
    private static func runningDaemonStart(label: String) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var byteCount = 0
        guard sysctl(&mib, 3, nil, &byteCount, nil, 0) == 0, byteCount > 0 else { return nil }

        // Slack: the process table can grow between the sizing call and the fetch. An exactly-sized
        // buffer makes a busy moment return ENOMEM and the check silently go blind.
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = byteCount / stride + byteCount / (stride * 8) + 8
        let procs = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacity)
        defer { procs.deallocate() }

        var fetched = capacity * stride
        guard sysctl(&mib, 3, procs, &fetched, nil, 0) == 0 else { return nil }

        var earliest: Date?
        for i in 0..<(fetched / stride) {
            var entry = procs[i]
            let commLength = MemoryLayout.size(ofValue: entry.kp_proc.p_comm)
            let comm = withUnsafePointer(to: &entry.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: commLength) { String(cString: $0) }
            }
            // The kernel gives us a truncated name; accept it only when it is long enough to be
            // unambiguous AND is a genuine prefix of the label we are looking for.
            guard comm.count >= 12, label.hasPrefix(comm) else { continue }
            let start = entry.kp_proc.p_un.__p_starttime
            let date = Date(timeIntervalSince1970: TimeInterval(start.tv_sec)
                                                 + TimeInterval(start.tv_usec) / 1_000_000)
            if earliest == nil || date < earliest! { earliest = date }
        }
        return earliest
    }
}

/// B4 — the states the app could not tell apart, now separate.
///
/// The recorded defect: the app held two signals (the SMAppService registration verdict and the XPC
/// reachability latch) and rendered ONE sentence for every failure. "Not approved", "approved but
/// silent" and "answering from an old binary" need three different actions from the owner, and the
/// middle one is this project's most expensive recurring failure — a rebuild re-signs the embedded
/// helper, the still-running daemon's backing file no longer matches the live process, the app's peer
/// code-sign pin refuses it, and the only symptom is "isn't responding".
enum HelperHealthVerdict: Equatable, Sendable {
    /// (1) Not registered / not approved / a signing or packaging problem. SMAppService's own verdict,
    ///     which already carries honest per-case guidance.
    case registrationProblem(HelperUIState)
    /// (2) Registered and approved, silent — and the running daemon predates this app's helper binary,
    ///     which is the whole explanation.
    case unreachableStale
    /// (2b) Registered and approved, silent, and staleness is NOT the explanation.
    case unreachable
    /// (3) The running daemon predates this app's helper binary while the channel still works — a
    ///     daemon registered from a different bundle copy validates its own image happily and serves
    ///     older code to a newer app.
    case stale
    /// Healthy and PROVEN: something completed a round trip in this process.
    case responding
    /// Healthy registration, no evidence either way — nothing has needed the helper yet.
    case notYetContacted
}

/// The rendered line for one verdict: what the state is, and — where there is one — the concrete thing
/// to run. Kept out of the view for the §4 reason and for the sharper one the C1 class taught: a string
/// built inside a `@ViewBuilder` cannot be asserted on.
struct HelperHealthNote: Equatable, Sendable {
    var text: String
    /// A command the owner can copy and run, or nil when the fix is a button rather than a command.
    var remedy: String?
    /// Semantic tint (the view maps it to `DSColor`), shared with the banner vocabulary.
    var tint: BannerTint
    /// True when the in-app "Restart helper" action (an SMAppService re-register, no sudo) applies —
    /// exactly the stale-image verdicts. The `remedy` command stays as the manual fallback.
    var canRestart: Bool = false
}

/// What one in-app restart attempt (`HelperHealthModel.restartDaemon`) found.
///
/// The mechanism (diagnosed on-device 2026-09-09): a rebuild replaces the embedded helper FILE, so the
/// running daemon's executable vnode is orphaned — `proc_pidpath` answers ENOENT and the Security
/// framework cannot even resolve the peer's code (`SecCodeCopyGuestWithAttributes` → 100002), so the
/// app's audit-token pin fails closed and NSXPC invalidates the connection with no log line. The DR
/// string is not involved (it carries no cdhash). The only cure is a new daemon process from the new
/// file. `SMAppService.unregister()` boots the stale process out (launchd SIGTERMs it) and `register()`
/// bootstraps it again from disk, as the app's own user through smd — no sudo, and no re-approval:
/// Background Task Management flips the item's disposition back to enabled on the re-register.
enum HelperRestartOutcome: Equatable, Sendable {
    /// unregister + register succeeded and the registration reads `.enabled`; `attempts` is how many
    /// `register()` calls it took (see `HelperHealthModel.restartDaemon` for why it can be more than one).
    case restarted(attempts: Int)
    /// The re-register came back unapproved — macOS wants the owner to approve the item again.
    case requiresApproval
    /// A step threw, or the registration never came back within the retry budget; the sudo command
    /// is the fallback.
    case failed(String)
}

/// Draft-register copy for the helper-health surface (sentence case, D7).
enum HelperHealthCopy {

    /// The bounce `scripts/relaunch-app.sh` prints. Built from `BatteryAppIDs.machService` so the
    /// command can never drift from the identity it restarts.
    static let kickstartCommand = "sudo launchctl kickstart -k system/\(BatteryAppIDs.machService)"

    static func note(for verdict: HelperHealthVerdict, lastReply: String?) -> HelperHealthNote {
        switch verdict {
        case .registrationProblem(let state):
            // Already honest per case, and already paired with the Open Login Items button.
            return HelperHealthNote(text: state.guidance, remedy: nil, tint: .attention)

        case .unreachableStale:
            return HelperHealthNote(
                text: "Energy helper isn’t responding. The copy that’s running started before this "
                    + "app’s helper was built, so the connection is refused. Restart it:",
                remedy: kickstartCommand, tint: .attention, canRestart: true)

        case .unreachable:
            return HelperHealthNote(
                text: "Energy helper isn’t responding — energy features stay unavailable until it "
                    + "answers. It is registered, approved, and not out of date, so restarting it "
                    + "won’t help. The app re-tests every time you open it.",
                remedy: nil, tint: .attention)

        case .stale:
            return HelperHealthNote(
                text: "The energy helper that’s running started before this app’s helper was built, "
                    + "so it’s serving older code. Restart it:",
                remedy: kickstartCommand, tint: .attention, canRestart: true)

        case .responding:
            // The reply text is the helper's OWN — the only identity check available over a protocol
            // that carries no version field.
            let text = lastReply.map { "Energy helper is responding and up to date — last reply: \($0)." }
                ?? "Energy helper is responding and up to date."
            return HelperHealthNote(text: text, remedy: nil, tint: .neutral)

        case .notYetContacted:
            return HelperHealthNote(
                text: "Energy helper is registered and approved. Nothing has needed it yet, so the app "
                    + "hasn’t contacted it.",
                remedy: nil, tint: .neutral)
        }
    }

    /// What the app OBSERVED, under the verdict — the two timestamps the staleness call was made from,
    /// so the claim is checkable rather than asserted. Nil when there is nothing whole to say: half a
    /// comparison is the kind of line that makes a reader distrust the other half.
    static func daemonDetail(_ image: HelperDaemonImage, formatted: (Date) -> String) -> String? {
        guard let built = image.bundledBuiltAt else { return nil }
        guard let started = image.daemonStartedAt else {
            return "No helper process is running right now — macOS starts it on the next request."
        }
        return "Running helper started \(formatted(started)); this app’s helper was built \(formatted(built))."
    }
}

/// 5.3 (helper-health visibility): surfaces the honest helper REGISTRATION state the app already
/// computes at launch (HelperRegistrar.migrateAndRegister) but never showed — the "UI = STAGE 5" gap.
/// B4 adds the second half: which of the three failure states the app is actually in.
/// Seamed over DaemonService + HelperDaemonProbing so it unit-tests host-app-free.
@MainActor
final class HelperHealthModel: ObservableObject {
    @Published private(set) var registration: HelperUIState

    /// What the app last observed of the running daemon vs the helper binary it ships. Refreshed on
    /// popover open alongside the registration re-read; seeded at launch so a Settings window opened
    /// without ever opening the popover is not blank.
    @Published private(set) var daemonImage: HelperDaemonImage

    private let service: any DaemonService
    private let probe: any HelperDaemonProbing
    /// Seam for the between-attempt wait in `restartDaemon` (tests inject a no-op).
    private let pause: @Sendable (TimeInterval) async -> Void

    /// The probe defaults to the LIVE one because `BatteryApp` constructs this model and cannot pass a
    /// stub; tests inject `HelperDaemonProbing` explicitly.
    init(service: any DaemonService,
         launchVerdict: HelperUIState,
         probe: any HelperDaemonProbing = LiveHelperDaemonProbe(),
         pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.service = service
        self.registration = launchVerdict
        self.probe = probe
        self.pause = pause
        self.daemonImage = probe.read()
    }

    /// Seed the verdict from the launch-time HelperRegistrar result (which may carry a rich verdict a
    /// raw status read can't re-derive, e.g. .signatureMismatch).
    func applyLaunchVerdict(_ verdict: HelperUIState) {
        registration = verdict
    }

    /// Re-read the live registration status on popover-open (mirrors LoginItemModel.refresh()) so a
    /// post-launch approval clears the "approve" nag. A hard, sticky verdict a raw status read cannot
    /// re-derive (.signatureMismatch / .needsManualReset — a signing/stuck problem needing a rebuild or
    /// sfltool + reboot) is preserved.
    func refresh() {
        // The image read happens FIRST and unconditionally: the sticky early-return below guards a
        // REGISTRATION re-read, and letting it also skip the probe would leave a signature-mismatch
        // build permanently blind to the daemon it is talking to.
        daemonImage = probe.read()
        switch registration {
        case .signatureMismatch, .needsManualReset:
            return
        case .enabled, .requiresApproval, .notRegistered, .notFound:
            registration = HelperRegistrar.uiState(for: service.statusValue)
        }
    }

    /// Compose the two live signals with the observed image into the one honest verdict.
    func verdict(unreachable: Bool, hasResponded: Bool) -> HelperHealthVerdict {
        Self.verdict(registration: registration, unreachable: unreachable,
                     hasResponded: hasResponded, image: daemonImage)
    }

    /// Pure derivation. Order is by "which answer sends the owner to the right place":
    /// a registration problem is not a reachability problem and must not be described as one; silence
    /// with a stale image has a known cause and a command; silence without one does not; a stale image
    /// is worth saying even while the channel works; and the healthy state must be EARNED by a reply,
    /// because "nothing has asked" and "everything is fine" produce the same un-latched flag.
    static func verdict(registration: HelperUIState, unreachable: Bool,
                        hasResponded: Bool, image: HelperDaemonImage) -> HelperHealthVerdict {
        guard registration == .enabled else { return .registrationProblem(registration) }
        let stale = isStale(image)
        if unreachable { return stale ? .unreachableStale : .unreachable }
        if stale { return .stale }
        return hasResponded ? .responding : .notYetContacted
    }

    /// Stale = the running daemon started BEFORE the helper binary this app ships was last written, so
    /// it is executing an image that no longer exists on disk. The same comparison
    /// `scripts/relaunch-app.sh` makes. Unknown either way is NOT stale — an honest "no" beats an
    /// invented "maybe", and the cost of a false positive here is the owner running sudo for nothing.
    static func isStale(_ image: HelperDaemonImage) -> Bool {
        guard let started = image.daemonStartedAt, let built = image.bundledBuiltAt else { return false }
        return built > started
    }

    // MARK: - the in-app restart (no sudo)

    /// The last restart attempt's outcome, for the Settings line. Nil until one has run.
    @Published private(set) var lastRestart: HelperRestartOutcome?
    /// True while a restart is in flight (the button disables; launch never starts a second one).
    @Published private(set) var restartInProgress = false
    private var autoRestartAttempted = false

    /// How many `register()` calls a restart may make, one second apart. Measured on-device
    /// (2026-09-09, macOS 27.0): a `register()` issued in the same instant as the `unregister()` is
    /// refused by smd with "Job is not allowed to bootstrap" because Background Task Management is still
    /// writing the unregister (its store saved ~3 s later); a `register()` a few seconds on bootstraps the
    /// daemon and re-enables the item with no prompt. Ten seconds is well past what was observed.
    static let registerAttempts = 10
    static let registerRetryInterval: TimeInterval = 1

    /// Whether launch should try the restart on its own. Bounded to ONE attempt per app launch, and only
    /// for a stale image on an approved registration: any other verdict has a different fix, and a
    /// retry loop against a registration that keeps coming back unapproved would spam the owner.
    static func shouldAutoRestart(registration: HelperUIState, image: HelperDaemonImage,
                                  alreadyAttempted: Bool) -> Bool {
        registration == .enabled && isStale(image) && !alreadyAttempted
    }

    /// Pure: what one `register()` call's resulting status means for the loop.
    enum RegisterStep: Equatable { case done(HelperRestartOutcome), retry }
    static func registerStep(status: DaemonServiceStatus, attempt: Int, maxAttempts: Int) -> RegisterStep {
        switch status {
        case .enabled:          return .done(.restarted(attempts: attempt))
        case .requiresApproval: return .done(.requiresApproval)
        case .notRegistered, .notFound:
            return attempt < maxAttempts ? .retry
                : .done(.failed("registration did not come back after \(attempt) register() calls (status \(status))"))
        }
    }

    /// Launch-time automatic attempt: at most once per launch, only when the running daemon is stale.
    /// Returns nil when nothing was attempted.
    @discardableResult
    func autoRestartIfStale(logger: @escaping @Sendable (String) -> Void = { _ in }) async -> HelperRestartOutcome? {
        guard Self.shouldAutoRestart(registration: registration, image: daemonImage,
                                     alreadyAttempted: autoRestartAttempted) else { return nil }
        autoRestartAttempted = true
        logger("helper image is stale (daemon started \(String(describing: daemonImage.daemonStartedAt)), "
               + "bundled helper built \(String(describing: daemonImage.bundledBuiltAt))) — restarting via SMAppService")
        return await restartDaemon(logger: logger)
    }

    /// Recycle the daemon: `unregister()` boots the stale process out of launchd, then `register()` —
    /// retried up to `registerAttempts` times, `registerRetryInterval` apart — bootstraps it again from
    /// the file on disk NOW. Re-probes the image at the end; the caller should ping to prove the round
    /// trip. A second caller while one is in flight gets `.failed` rather than a second unregister.
    @discardableResult
    func restartDaemon(logger: @escaping @Sendable (String) -> Void = { _ in }) async -> HelperRestartOutcome {
        guard !restartInProgress else { return .failed("a restart is already in progress") }
        restartInProgress = true
        defer { restartInProgress = false }
        let outcome = await recycle(logger: logger)
        lastRestart = outcome
        refresh()
        return outcome
    }

    private func recycle(logger: @Sendable (String) -> Void) async -> HelperRestartOutcome {
        do {
            try service.unregister()
            logger("restart: unregistered (status now \(service.statusValue))")
        } catch {
            logger("restart: unregister FAILED — \(error)")
            return .failed("unregister: \(error)")
        }
        for attempt in 1...Self.registerAttempts {
            await pause(Self.registerRetryInterval)
            do { try service.register() } catch { logger("restart: register() #\(attempt) threw \(error)") }
            let status = service.statusValue
            logger("restart: register() #\(attempt) → status \(status)")
            if case .done(let outcome) = Self.registerStep(status: status, attempt: attempt,
                                                           maxAttempts: Self.registerAttempts) {
                return outcome
            }
        }
        return .failed("no register() attempt ran")   // unreachable: the loop's last step is always .done
    }
}
