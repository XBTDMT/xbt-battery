import Foundation
@preconcurrency import Shared

// Sprint 3.7: the privileged ENERGY helper (repurposed Phase-2 scaffolding; the SMC capability is
// EXCISED and proven absent by the SMC-DEAD gate). NO-TRAP launch path: nothing here fatalErrors or
// force-unwraps, so a boot fault degrades/logs rather than crash-loops under launchd KeepAlive.
//
// STAGE 1/2 = stand up the storm-guarded NSXPCListener vending ONLY `ping` (the channel smoke test).
// The two privileged energy ops (setEnergyMode / collectTaskEnergy) arrive in STAGE 3/4. No SMC, no
// charge engine, no IOKit.

// Persisted storm-guard state — a root-writable path; missing/corrupt → crashCount 0 (fail toward run).
let stateDir = URL(fileURLWithPath: "/Library/Application Support/com.example.batteryapp", isDirectory: true)
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
let store = FileStormGuardStore(url: stateDir.appendingPathComponent("energyhelper-state.json"))

// Crash-loop storm guard: count THIS launch BEFORE reading the counter, then decide whether to vend.
let lifecycle = DaemonLifecycle(store: store)
lifecycle.recordLaunchAttempt()
let outcome = lifecycle.launch()
NSLog("battery_app energyhelper: launch decision=\(outcome.decision) crashCount=\(outcome.crashCount)")

// Built ONCE and reused so the probation re-vend can NEVER vend unpinned. nil ⇒ Team ID unreadable ⇒
// fail CLOSED on every path. (type inferred from appRequirement — do NOT hardcode it)
let appDR = BatteryAppIDs.mainBundleTeamIDOrNil().map { BatteryAppIDs.appRequirement(teamID: $0) }

// Retains the listener+delegate for the process lifetime. A reference type (not top-level vars) so the
// main-dispatched probation vend can populate it without Swift 6 flagging mutable global state captured
// by a @Sendable closure. Written ONLY on the main thread; never read concurrently.
final class VendState: @unchecked Sendable {
    var listener: NSXPCListener?
    var delegate: EnergyHelperListenerDelegate?
}
let vendState = VendState()

// MUST run on the main thread so all NSXPCListener lifecycle is main-runloop-driven (the initial call is
// on the startup main path; the probation call is main-dispatched). Fail-closed if the DR pin is absent.
func vendService() {
    guard let dr = appDR else {
        NSLog("battery_app energyhelper: Team ID unreadable — refusing to vend (fail-closed, no DR pin)"); return
    }
    let delegate = EnergyHelperListenerDelegate(appRequirement: dr)
    let listener = NSXPCListener(machServiceName: BatteryAppIDs.machService)
    listener.delegate = delegate
    // PRIMARY peer authentication (macOS 13+): audit-token DR pin, set BEFORE resume(); NEVER PID.
    listener.setConnectionCodeSigningRequirement(dr)
    listener.resume()
    vendState.delegate = delegate; vendState.listener = listener
    NSLog("battery_app energyhelper: listening on \(BatteryAppIDs.machService) — app DR pinned")
    // Surviving 60 s clears crashCount AND backoffLevel; a crash before then leaves both (closure dies
    // with the process).
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { lifecycle.markHealthyUptime() }
}

if appDR == nil {
    NSLog("battery_app energyhelper: Team ID unreadable — refusing to vend (fail-closed, no DR pin)")
} else if outcome.gated {
    // Storm guard tripped: instead of idling forever (the old trap), schedule a PROBATIONARY re-vend
    // after a capped backoff cooldown (cap-and-probe-forever — never a permanent dead state).
    // scripts/reset-storm-guard.sh clears it immediately.
    let delay = lifecycle.probationDelay()               // reads backoffLevel BEFORE beginProbation advances it
    NSLog("battery_app energyhelper: storm guard tripped (crashCount=\(outcome.crashCount) backoffLevel=\(store.backoffLevel)) — probation re-vend in \(Int(delay))s; run scripts/reset-storm-guard.sh to clear now")
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
        lifecycle.beginProbation()
        DispatchQueue.main.async { vendService() }        // main-thread XPC listener setup (matches the initial path)
    }
} else {
    vendService()                                         // not gated, DR pin present → vend now (startup main path)
}

dispatchMain()
