import Foundation
import Darwin            // A3: posix_spawn + file actions + signals/waitpid for the hardened child spawn
@preconcurrency import Shared

/// Per-connection exported XPC object for the Sprint 3.7 ENERGY helper. Vends `ping` + `setEnergyMode`
/// (op 1) + `collectTaskEnergy` (op 2). No engine, no charge surface. A3 (Grok hardening) makes every
/// child spawn BOUNDED (hard timeout → SIGTERM → grace → SIGKILL → waitpid-reap, all paths) and ISOLATED
/// (posix_spawn with POSIX_SPAWN_CLOEXEC_DEFAULT, stdin/stderr → /dev/null, stdout → a single pipe,
/// controlled cwd, REPLACED env, fixed argv, no shell), and serializes sampling ops behind ONE queue.
final class EnergyHelperService: NSObject, EnergyHelperProtocol {

    // A3 (Grok MAJOR concurrency): ALL sampling spawns run on ONE serial queue (max concurrency 1), and
    // a submission cooldown rejects a flood so root powermetrics spawns can't pile up. STATIC so the one
    // queue + one clock are shared across every per-connection service instance.
    private static let samplingQueue = DispatchQueue(label: "com.example.batteryapp.energyhelper.sampling")
    private static let cooldownLock = NSLock()
    // Guarded solely by `cooldownLock` (every read/write is inside `beginSampleIfAllowed`), so the manual
    // synchronization is sound; `nonisolated(unsafe)` tells Swift 6 we own it (same pattern as the glyph).
    nonisolated(unsafe) private static var lastSampleStartNs: UInt64 = 0

    // The shared serial MUTATION queue (max concurrency 1) — DISTINCT from samplingQueue so a write
    // never blocks on a long powermetrics sample. Serializes BOTH setEnergyMode AND setRepeatingSleepWake:
    // no concurrent root pmset spawns, and any write race is deterministic (last submission wins).
    private static let mutationQueue = DispatchQueue(label: "com.example.batteryapp.energyhelper.mutation")
    private static let applyLock = NSLock()
    nonisolated(unsafe) private static var lastApplyStartNs: UInt64 = 0

    func ping(reply: @escaping (String) -> Void) { reply("pong") }

    /// STAGE 3 — the FIRST privileged action. VALIDATE the two integers to {0,1,2}×{0,1,2} and REJECT
    /// out-of-set BEFORE building any command; then build the FIXED `pmset` argv (shared pure builder),
    /// spawn it with an EXHAUSTIVELY sanitized environment, read back `pmset -g powermode`, and reply
    /// the resulting value (or an `error:*` token). Never traps; never uses a shell or string
    /// interpolation; no app-controlled value ever reaches a path.
    func setEnergyMode(mode: Int, source: Int, reply: @escaping (String) -> Void) {
        guard let (modeValue, sourceValue) = EnergyModeCommand.validate(mode: mode, source: source) else {
            let token = EnergyModeValue(rawValue: mode) == nil
                ? EnergyModeCommand.errInvalidMode : EnergyModeCommand.errInvalidSource
            NSLog("battery_app energyhelper: setEnergyMode REJECTED out-of-set (mode=\(mode) source=\(source)) → \(token)")
            reply(token)
            return
        }
        // On the serial MUTATION queue (off the connection queue; the spawn briefly blocks on pmset).
        // Serializing here removes the previously-uncapped concurrent spawn for setEnergyMode too.
        Self.mutationQueue.async {
            let setArgv = EnergyModeCommand.pmsetArguments(mode: modeValue, source: sourceValue)
            NSLog("battery_app energyhelper: setEnergyMode SET \(setArgv)")
            guard Self.runFixedCommand(setArgv) != nil else { reply(EnergyModeCommand.errSetFailed); return }

            guard let readbackData = Self.runFixedCommand(EnergyModeCommand.readbackArguments()),
                  let readback = String(data: readbackData, encoding: .utf8),
                  let value = EnergyModeCommand.parsePowermode(fromPmsetG: readback) else {
                reply(EnergyModeCommand.errReadbackFailed)
                return
            }
            NSLog("battery_app energyhelper: setEnergyMode read-back powermode=\(value)")
            reply(value)
        }
    }

    /// STAGE 4 — the SECOND privileged op (read-only). RANGE-CHECK both integers and REJECT
    /// out-of-range with an error token BEFORE building anything; then build the FIXED `powermetrics`
    /// argv, spawn it (sanitized env, controlled cwd, stderr→/dev/null), and reply the RAW `-f plist`
    /// Data (parsed app-side) or an `error:*` token. Never traps. Defaults are one-shot (energy-irony).
    func collectTaskEnergy(samples: Int, intervalMs: Int, reply: @escaping (Data?, String?) -> Void) {
        guard let request = TaskEnergyCommand.validate(samples: samples, intervalMs: intervalMs) else {
            let token = TaskEnergyCommand.rejectionToken(samples: samples, intervalMs: intervalMs)
            NSLog("battery_app energyhelper: collectTaskEnergy REJECTED out-of-range (samples=\(samples) intervalMs=\(intervalMs)) → \(token)")
            reply(nil, token)
            return
        }
        // A3 (b): cooldown gate at SUBMISSION — reject a flood fast instead of queueing root spawns.
        guard Self.beginSampleIfAllowed() else {
            NSLog("battery_app energyhelper: collectTaskEnergy REJECTED (cooldown < \(TaskEnergyCommand.sampleCooldownMs)ms since last sample)")
            reply(nil, TaskEnergyCommand.errCooldown)
            return
        }
        // A3 (b): serialize on the ONE sampling queue (max concurrency 1) so two samples never overlap.
        Self.samplingQueue.async {
            let argv = TaskEnergyCommand.powermetricsArguments(request)
            NSLog("battery_app energyhelper: collectTaskEnergy \(argv)")
            // A3 (a): bounded — runFixedCommand caps powermetrics at spawnTimeoutSeconds then kills+reaps.
            guard let plist = Self.runFixedCommand(argv), !plist.isEmpty else {
                reply(nil, TaskEnergyCommand.errCollectFailed)
                return
            }
            reply(plist, nil)
        }
    }

    /// SLEEP/WAKE — the THIRD privileged op. VALIDATE the seven primitives (neither-enabled = cancel) and
    /// REJECT out-of-range with an error token BEFORE building anything; gate a flood at submission; then
    /// serialize on the mutation queue, build the FIXED `pmset repeat` argv (hard-coded event types), run
    /// it through the bounded+isolated spawn, and reply "ok" (exit 0) or an `error:*` token. Never traps.
    func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                               wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int,
                               weekdayMask: Int, reply: @escaping (String) -> Void) {
        guard let request = SleepWakeCommand.validate(
            sleepEnabled: sleepEnabled, sleepHour: sleepHour, sleepMinute: sleepMinute,
            wakeEnabled: wakeEnabled, wakeHour: wakeHour, wakeMinute: wakeMinute, weekdayMask: weekdayMask)
        else {
            let token = SleepWakeCommand.rejectionToken(
                sleepEnabled: sleepEnabled, sleepHour: sleepHour, sleepMinute: sleepMinute,
                wakeEnabled: wakeEnabled, wakeHour: wakeHour, wakeMinute: wakeMinute, weekdayMask: weekdayMask)
            NSLog("battery_app energyhelper: setRepeatingSleepWake REJECTED out-of-range → \(token)")
            reply(token)
            return
        }
        guard Self.beginApplyIfAllowed() else {
            NSLog("battery_app energyhelper: setRepeatingSleepWake REJECTED (cooldown < \(SleepWakeCommand.applyCooldownMs)ms)")
            reply(SleepWakeCommand.errCooldown)
            return
        }
        Self.mutationQueue.async {
            let argv = SleepWakeCommand.pmsetArguments(request)
            NSLog("battery_app energyhelper: setRepeatingSleepWake \(argv)")
            guard Self.runFixedCommand(argv) != nil else { reply(SleepWakeCommand.errSetFailed); return }
            reply(SleepWakeCommand.ok)
        }
    }

    /// WAKE BEHAVIOR — the FOURTH privileged op. Writes `powernap` + `womp` per power source via two
    /// FIXED `pmset` argvs (battery then AC). NO rejection branch: the four inputs are booleans and a
    /// boolean cannot be out of range; the structural mint (ValidatedWakeBehaviorRequest, fileprivate
    /// init) still enforces the injection barrier, so `pmsetArguments` is never reached with raw input.
    /// Gates a flood at submission, serializes on the shared mutation queue, runs BOTH writes, and
    /// replies "ok" only if both succeed (else an `error:*` token). Never traps; no shell; no
    /// app-controlled value ever reaches a key, scope, or path.
    func setWakeBehavior(powerNapBattery: Bool, powerNapAC: Bool,
                         wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool,
                         reply: @escaping (String) -> Void) {
        let request = WakeBehaviorCommand.validate(
            powerNapBattery: powerNapBattery, powerNapAC: powerNapAC,
            wakeOnNetworkBattery: wakeOnNetworkBattery, wakeOnNetworkAC: wakeOnNetworkAC)
        guard Self.beginApplyIfAllowed() else {
            NSLog("battery_app energyhelper: setWakeBehavior REJECTED (cooldown < \(SleepWakeCommand.applyCooldownMs)ms)")
            reply(WakeBehaviorCommand.errCooldown)
            return
        }
        Self.mutationQueue.async {
            for argv in WakeBehaviorCommand.pmsetArguments(request) {
                NSLog("battery_app energyhelper: setWakeBehavior \(argv)")
                guard Self.runFixedCommand(argv) != nil else {
                    reply(WakeBehaviorCommand.errSetFailed)
                    return
                }
            }
            reply(WakeBehaviorCommand.ok)
        }
    }

    /// A3 (b): record a sample start iff outside the cooldown — atomically (the check + the timestamp
    /// update under one lock). Returns false (caller rejects) when a previous sample started too recently.
    private static func beginSampleIfAllowed() -> Bool {
        cooldownLock.lock(); defer { cooldownLock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let cooldownNs = UInt64(TaskEnergyCommand.sampleCooldownMs) * 1_000_000
        if sampleThrottled(nowNs: now, lastStartNs: lastSampleStartNs, cooldownNs: cooldownNs) { return false }
        lastSampleStartNs = now
        return true
    }

    /// Record a schedule-apply start iff outside the cooldown — atomically (check + timestamp under one
    /// lock). Returns false (caller rejects) when a previous apply started too recently. Reuses the pure
    /// `sampleThrottled` decision with a SEPARATE apply clock so it never throttles sampling, or vice versa.
    private static func beginApplyIfAllowed() -> Bool {
        applyLock.lock(); defer { applyLock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let cooldownNs = UInt64(SleepWakeCommand.applyCooldownMs) * 1_000_000
        if sampleThrottled(nowNs: now, lastStartNs: lastApplyStartNs, cooldownNs: cooldownNs) { return false }
        lastApplyStartNs = now
        return true
    }

    /// Pure cooldown decision (host-app-free testable): a new sample is throttled iff a previous sample
    /// has started (`lastStartNs != 0`) AND less than `cooldownNs` has elapsed since. `&-` is wrap-safe.
    static func sampleThrottled(nowNs: UInt64, lastStartNs: UInt64, cooldownNs: UInt64) -> Bool {
        lastStartNs != 0 && (nowNs &- lastStartNs) < cooldownNs
    }

    /// Run a FIXED argv (argv[0] absolute) and return captured stdout DATA on a clean exit 0, else nil.
    /// Thin wrapper over the hardened `spawnAndCapture` (A3). Used by BOTH ops (pmset + powermetrics);
    /// the timeout caps any hang. Raw Data so the powermetrics `-f plist` bytes survive intact; the pmset
    /// read-back decodes it as UTF-8.
    static func runFixedCommand(_ argv: [String],
                                timeout: TimeInterval = TaskEnergyCommand.spawnTimeoutSeconds) -> Data? {
        spawnAndCapture(argv, timeout: timeout).data
    }

    /// A3 (Grok BLOCKER bounded-lifecycle + MAJOR spawn-isolation): spawn a FIXED argv via `posix_spawn`
    /// — NEVER a shell, never interpolation, argv[0] absolute. ISOLATION: POSIX_SPAWN_CLOEXEC_DEFAULT
    /// closes EVERY inherited fd in the child except the three we set (stdin ← /dev/null, stdout ← one
    /// pipe, stderr ← /dev/null); the cwd is the controlled dir; the environment is REPLACED wholesale
    /// with the sanitized allow-list (no inherited DYLD_*/PATH). BOUNDED LIFECYCLE: a watchdog enforces
    /// `timeout` (SIGTERM → grace → SIGKILL), and the child is ALWAYS waitpid-reaped (success, non-zero,
    /// or timeout) — no orphan, no zombie, no unbounded block of the XPC handler. Returns
    /// (stdout-on-clean-exit-0 else nil, the child pid, whether the timeout tripped). Never traps.
    static func spawnAndCapture(_ argv: [String],
                                timeout: TimeInterval) -> (data: Data?, pid: pid_t, timedOut: Bool) {
        guard let exePath = argv.first else { return (nil, -1, false) }

        var outFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0 else { return (nil, -1, false) }
        let readFD = outFDs[0], writeFD = outFDs[1]
        let devnull = open("/dev/null", O_RDWR)
        guard devnull >= 0 else { close(readFD); close(writeFD); return (nil, -1, false) }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, devnull, 0)   // stdin  ← /dev/null
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 1)   // stdout ← pipe write end
        posix_spawn_file_actions_adddup2(&fileActions, devnull, 2)   // stderr ← /dev/null
        // Controlled cwd (addchdir_np: available since 10.15; the non-_np form needs macOS 26 > our 14.0
        // deployment target — the deprecation note is benign, no warnings-as-errors).
        posix_spawn_file_actions_addchdir_np(&fileActions, EnergyModeCommand.workingDirectory)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        // CLOEXEC_DEFAULT: every fd NOT explicitly dup2'd above is closed in the child — no stray helper
        // fd (XPC, pipes, log handles) can leak into the root child.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        argvC.append(nil)
        var envC: [UnsafeMutablePointer<CChar>?] = EnergyModeCommand.sanitizedEnvironment()
            .map { strdup("\($0.key)=\($0.value)") }   // env REPLACED wholesale (not merged with the parent's)
        envC.append(nil)
        defer {
            argvC.forEach { if let p = $0 { free(p) } }
            envC.forEach { if let p = $0 { free(p) } }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attrs)
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exePath, &fileActions, &attrs, argvC, envC)
        close(writeFD)   // the parent never writes; the child holds its own dup'd copy
        close(devnull)   // the child holds its own dup'd copies
        guard rc == 0 else {
            NSLog("battery_app energyhelper: posix_spawn failed for \(exePath): \(rc)")
            close(readFD)
            return (nil, -1, false)
        }

        // Reader thread drains stdout to EOF. EOF = the child closed fd 1 = it is exiting / was killed.
        let sem = DispatchSemaphore(value: 0)
        let sink = NSMutableData()
        let reader = Thread {
            let chunk = 65536
            var tmp = [UInt8](repeating: 0, count: chunk)
            while true {
                let n = tmp.withUnsafeMutableBytes { read(readFD, $0.baseAddress, chunk) }
                if n > 0 { sink.append(tmp, length: n) } else { break }   // 0 = EOF, <0 = error
            }
            close(readFD)
            sem.signal()
        }
        reader.stackSize = 1 << 20
        reader.start()

        // Bounded wait. We reap ONLY after EOF (the child is exiting / a zombie, and a not-yet-reaped pid
        // is never recycled), so the kill() escalation can never hit a recycled PID.
        var timedOut = false
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(pid, SIGTERM)
            if sem.wait(timeout: .now() + TaskEnergyCommand.spawnGraceSeconds) == .timedOut {
                kill(pid, SIGKILL)
                // BOUND this wait too. A SIGKILLed child closes fd 1 promptly, but if it had spawned a
                // backgrounding grandchild that inherited the stdout pipe, the reader could block past the
                // kill — never let that wedge the sampling queue. We reap the DIRECT child regardless
                // below; the reader owns readFD and exits when the pipe finally closes, and its per-call
                // semaphore makes any late signal harmless. So the helper stays bounded in EVERY path.
                _ = sem.wait(timeout: .now() + TaskEnergyCommand.spawnGraceSeconds)
            }
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)   // reap EXACTLY once, in EVERY path (success / non-zero / timeout)

        if timedOut {
            NSLog("battery_app energyhelper: \(exePath) timed out after \(timeout)s — killed + reaped")
            return (nil, pid, true)
        }
        let exitedNormally = (status & 0x7f) == 0
        let exitCode = (status >> 8) & 0xff
        guard exitedNormally, exitCode == 0 else {
            NSLog("battery_app energyhelper: \(exePath) exited status=\(status)")
            return (nil, pid, false)
        }
        return (Data(referencing: sink), pid, false)
    }
}

/// Helper-side `NSXPCListener` delegate — STAGE 2 hardened.
///
/// PEER AUTHENTICATION (research-09: NEVER trust the PID — the PID-reuse TOCTOU CVE canon):
/// the PRIMARY check is the listener's `setConnectionCodeSigningRequirement(appDR)` (set in main.swift
/// BEFORE `resume()`). That is an AUDIT-TOKEN-BACKED pin (the macOS-13+ NSXPC equivalent of the new
/// Swift-XPC `senderSatisfies`/`xpc_listener_set_peer_code_signing_requirement`): it auto-REJECTS any
/// peer not matching the app's codified DR BEFORE this delegate is ever consulted. So this delegate
/// runs ONLY for already-authenticated peers; it adds per-connection defense-in-depth + auditability.
///
/// NSXPCConnection exposes no PUBLIC `audit_token` (only `auditSessionIdentifier` + the forbidden
/// `processIdentifier`); reading the token via private KVC throws if absent, which we will not risk in
/// a root daemon. So we rely on the listener's audit-token pin for validation and log the peer by its
/// audit SESSION id (never the PID). `BatteryAppIDs.peerSatisfies(auditToken:requirement:)` is the same
/// SecCode audit-token check the pin performs, unit-proven (accept + reject) on a real audit token.
final class EnergyHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let appRequirement: String
    private var nextConnID: ConnID = 0

    init(appRequirement: String) { self.appRequirement = appRequirement }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let connID = nextConnID
        nextConnID += 1
        // Defense-in-depth: pin THIS connection too (the listener pin already rejected non-matching
        // peers before we got here; this also guards the per-message path). Set BEFORE resume().
        newConnection.setCodeSigningRequirement(appRequirement)
        // Auditability: log the accepted peer by audit SESSION id (NEVER the PID). The peer is already
        // proven to satisfy the codified app DR by the listener's audit-token pin.
        NSLog("battery_app energyhelper: accepted connection \(connID) auditSession=\(newConnection.auditSessionIdentifier) — peer satisfied the pinned app DR")
        newConnection.invalidationHandler = { NSLog("battery_app energyhelper: connection \(connID) invalidated") }
        newConnection.interruptionHandler = { NSLog("battery_app energyhelper: connection \(connID) interrupted") }
        newConnection.exportedInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
        newConnection.exportedObject = EnergyHelperService()
        newConnection.resume()
        return true
    }
}
