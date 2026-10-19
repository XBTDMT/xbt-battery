import XCTest
// app/Monitoring (BatterySnapshot.EnergyMode) and app/Privileged (EnergyModeController, HelperClientError,
// AutoEnergyMode) compile into THIS host-app-free target → visible without import. (project.yml: the
// BatteryTests source list gains app/Privileged/AutoEnergyMode.swift, the way EnergyModeController.swift
// is already listed.)

/// Sprint auto-energy-mode PHASE 1 — the pure policy + the per-source runner (sec 3–7 of
/// 02-SPEC-auto-energy-mode.md), plus the additive EnergyModeController completion seam (sec 0/6).
/// RED-first: the headline TDD targets are the battery-only `desiredMode` boundaries and the runner's
/// edge/hold/reassert with per-source `last`, success-callback-only advancement, re-evaluate-after-set,
/// and the Grok cross-source + dropped-set sequences.
@MainActor
final class AutoEnergyModeTests: XCTestCase {

    // MARK: - Test doubles

    /// Live, mutable conditions the runner reads through its injected provider (soc / plugged / the
    /// CURRENT source's live mode). A test mutates this to drive evaluations; the mock setter mutates
    /// `mode` on a successful set to model the OS applying the change to the current source.
    @MainActor
    final class ConditionsBox {
        var thermal: ThermalLevel
        var soc: Int?
        var plugged: Bool
        var highAvailable: Bool
        var mode: EnergyMode                 // the ACTIVE source's live mode (currentSourceMode)
        var inactiveSourceMode: EnergyMode   // sec 13: the INACTIVE source's live mode; default does NOT trip the release
        init(thermal: ThermalLevel = .nominal, soc: Int?, plugged: Bool, mode: EnergyMode,
             highAvailable: Bool = false, inactiveSourceMode: EnergyMode = .automatic) {
            self.thermal = thermal; self.soc = soc; self.plugged = plugged
            self.highAvailable = highAvailable; self.mode = mode
            self.inactiveSourceMode = inactiveSourceMode
        }
        var conditions: AutoEnergyConditions {
            AutoEnergyConditions(thermal: thermal, soc: soc, plugged: plugged,
                                 highAvailable: highAvailable, currentSourceMode: mode,
                                 inactiveSourceMode: inactiveSourceMode)
        }
    }

    /// Mock `AutoEnergyModeSetting`: records calls, controllable result, optional manual completion (to
    /// hold a set "in flight"), and — on a SUCCESS — applies the set to the shared `ConditionsBox`,
    /// modelling per-source reality: a set to the ACTIVE source lands in `mode`, a set to the INACTIVE
    /// source lands in `inactiveSourceMode` (so the runner's re-evaluate sees the landed value on the
    /// right source). Active source = charger when plugged (raw 1), else battery (raw 0).
    @MainActor
    final class MockAutoSetter: AutoEnergyModeSetting {
        let box: ConditionsBox
        var result: Result<String, HelperClientError> = .success("ok")
        var autoComplete = true
        private(set) var calls: [(mode: Int, source: Int)] = []
        private var pending: (() -> Void)?
        init(box: ConditionsBox) { self.box = box }

        func setMode(_ mode: Int, source: Int,
                     completion: (@MainActor (Result<String, HelperClientError>) -> Void)?) {
            calls.append((mode: mode, source: source))
            let fire = { [self] in
                if case .success = result {
                    let activeRaw = box.plugged ? 1 : 0   // charger=1 / battery=0
                    if source == activeRaw { box.mode = MockAutoSetter.energyMode(from: mode) }
                    else { box.inactiveSourceMode = MockAutoSetter.energyMode(from: mode) }
                }
                completion?(result)
            }
            if autoComplete { fire() } else { pending = fire }
        }
        func complete() { let p = pending; pending = nil; p?() }

        static func energyMode(from v: Int) -> EnergyMode {
            switch v { case 0: return .automatic; case 1: return .low; case 2: return .high; default: return .unavailable }
        }
    }

    /// Mock for the EXISTING `EnergyModeSetter` seam — used to drive the REAL `EnergyModeController` so
    /// the added completion is exercised on the production path (success / failure / serialization drop).
    @MainActor
    final class SeamMockSetter: EnergyModeSetter {
        var result: Result<String, HelperClientError> = .success("0")
        var autoComplete = true
        private var pending: ((Result<String, HelperClientError>) -> Void)?
        func setEnergyMode(mode: Int, source: Int,
                           completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
            if autoComplete { completion(result) } else { pending = completion }
        }
        func complete() { let p = pending; pending = nil; p?(result) }
    }

    private func makeRunner(box: ConditionsBox, setter: MockAutoSetter) -> AutoEnergyModeRunner {
        let suite = "AutoEnergyModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AutoEnergyModeRunner(setter: setter, conditions: { box.conditions },
                                    defaults: defaults, enabledKey: "auto.energy.enabled")
    }

    // MARK: - Pure policy (battery-only desiredMode) boundaries (sec 3/7)

    func testPolicy_entersLowAtEnterSoc() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 20, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(r.desired, .low); XCTAssertTrue(r.lowEngaged)
    }
    func testPolicy_entersLowBelowEnterSoc() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 19, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(r.desired, .low); XCTAssertTrue(r.lowEngaged)
    }
    func testPolicy_releasesAtExitSocWhenEngaged() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 30, highAllowed: false, lowEngaged: true)
        XCTAssertEqual(r.desired, .automatic); XCTAssertFalse(r.lowEngaged)
    }
    func testPolicy_automaticAboveExitSoc() {
        let engaged = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 31, highAllowed: false, lowEngaged: true)
        XCTAssertEqual(engaged.desired, .automatic); XCTAssertFalse(engaged.lowEngaged)
        let fresh = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 31, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(fresh.desired, .automatic); XCTAssertFalse(fresh.lowEngaged)
    }
    func testPolicy_midBandHoldsLowWhenEngaged() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 25, highAllowed: false, lowEngaged: true)   // hysteresis hold
        XCTAssertEqual(r.desired, .low); XCTAssertTrue(r.lowEngaged)
    }
    func testPolicy_midBandStaysAutomaticWhenNotEngaged() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 25, highAllowed: false, lowEngaged: false)  // the engaged bit decides the band
        XCTAssertEqual(r.desired, .automatic); XCTAssertFalse(r.lowEngaged)
    }
    func testPolicy_nilSocIsAutomaticNoFlag() {
        let a = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: nil, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(a.desired, .automatic); XCTAssertFalse(a.lowEngaged)
        let b = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: nil, highAllowed: false, lowEngaged: true)  // no flag on missing data
        XCTAssertEqual(b.desired, .automatic); XCTAssertFalse(b.lowEngaged)
    }

    // MARK: - Pure policy: thermal overlay + the critical interaction (sec 11)

    func testPolicy_thermalSeriousForcesLowAtHealthySoc_bitStaysFalse() {
        let r = AutoEnergyPolicy.evaluate(thermal: .serious, soc: 50, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(r.desired, .low, "thermal wins over the battery .automatic")
        XCTAssertFalse(r.lowEngaged, "the thermal force NEVER feeds the battery bit")
    }
    func testPolicy_thermalCriticalForcesLow() {
        let r = AutoEnergyPolicy.evaluate(thermal: .critical, soc: 50, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(r.desired, .low); XCTAssertFalse(r.lowEngaged)
    }
    func testPolicy_thermalSeriousAndBatteryLow_bothAgree_bitEngagesOnSoc() {
        let r = AutoEnergyPolicy.evaluate(thermal: .serious, soc: 15, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(r.desired, .low); XCTAssertTrue(r.lowEngaged, "the bit engages on SOC, not thermal")
    }
    func testPolicy_thermalFairDoesNotForce() {
        let r = AutoEnergyPolicy.evaluate(thermal: .fair, soc: 50, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(r.desired, .automatic, "fair is early-warning only — it never forces")
        XCTAssertFalse(r.lowEngaged)
    }
    func testPolicy_thermalNominalDoesNotForce() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 50, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(r.desired, .automatic); XCTAssertFalse(r.lowEngaged)
    }

    /// THE INTERACTION (Grok-validated): a thermal episode at a mid-band SOC must leave NO sticky Low
    /// once it releases — because the thermal force never engaged the battery bit.
    func testPolicy_thermalEpisode_noStickyLowAfterRelease() {
        let hot = AutoEnergyPolicy.evaluate(thermal: .serious, soc: 25, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(hot.desired, .low); XCTAssertFalse(hot.lowEngaged, "thermal Low, bit stays false")
        let cooled = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 25, highAllowed: false, lowEngaged: hot.lowEngaged)
        XCTAssertEqual(cooled.desired, .automatic, "no sticky Low — the bit never engaged")
        XCTAssertFalse(cooled.lowEngaged)
    }

    /// THE CONTRAST: a genuine battery-low (bit true) HOLDS Low through a thermal release — the battery
    /// hysteresis legitimately keeps it (18 is still below the 30 exit), distinct from the episode path.
    func testPolicy_genuineBatteryLow_holdsThroughThermalRelease() {
        let hotLow = AutoEnergyPolicy.evaluate(thermal: .serious, soc: 15, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(hotLow.desired, .low); XCTAssertTrue(hotLow.lowEngaged)
        let cooled = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 18, highAllowed: false, lowEngaged: hotLow.lowEngaged)
        XCTAssertEqual(cooled.desired, .low, "battery hysteresis holds Low (18 < exit 30)")
        XCTAssertTrue(cooled.lowEngaged)
    }

    // MARK: - Runner: edge / hold / success-callback-only advancement (sec 4–7)

    func testRunner_edge_drivesExactlyOneSet_advancesAndDisclosesOnlyOnSuccess() {
        let box = ConditionsBox(soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // on-enable: in sync, seeds last[battery]
        XCTAssertEqual(setter.calls.count, 0, "an in-sync enable drives no set")
        XCTAssertNil(runner.autoNote)
        XCTAssertEqual(runner.lastBattery, .automatic)

        setter.autoComplete = false                         // hold the set in flight
        box.soc = 15                                        // policy edge → .low
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 1, "exactly one set on the edge")
        XCTAssertEqual(setter.calls.first?.mode, 1)         // .low
        XCTAssertEqual(setter.calls.first?.source, 0)       // battery
        XCTAssertEqual(runner.lastBattery, .automatic, "last must NOT advance before success (success-callback-only)")
        XCTAssertTrue(runner.autoNote?.contains("Low Power") ?? false,
                      "Option 3 (sec 15.3): the persistent status shows the protection intent while in flight")

        setter.complete()                                   // success callback
        XCTAssertEqual(setter.calls.count, 1, "no extra set after a clean success")
        XCTAssertEqual(runner.lastBattery, .low, "last advances ONLY on the success callback")
        XCTAssertTrue(runner.autoNote?.contains("Low Power") ?? false, "disclosure publishes on success")
    }

    /// Option 3 BRANCH B (sec 15.1): a manual choice OUTSIDE protection stands — auto does not fight it,
    /// and the persistent status names the standing manual choice.
    func testRunner_manualChange_outsideProtection_standsViaBranchB() {
        let box = ConditionsBox(soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true
        XCTAssertEqual(setter.calls.count, 0)

        box.mode = .high                                    // a manual pick; NO protection (soc 50, nominal)
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 0, "BRANCH B respects the manual choice — no auto set")
        XCTAssertEqual(runner.lastBattery, .automatic, "a manual change NEVER touches last")
        XCTAssertEqual(runner.autoNote, "Manual High Power in effect",
                       "the persistent status names the standing manual choice")
    }

    /// GROK #1 — per-source `last` prevents a charger visit from clobbering a battery manual choice.
    /// FAILS with a single global `last`: the charger's .low set would drag the global baseline to .low,
    /// so the return-to-battery edge (desired .automatic ≠ global .low) would drive battery→.automatic
    /// and clobber the manual .high. Per-source `last[battery]` stays .automatic → no edge → held.
    func testRunner_crossSource_batteryManualHighNotClobberedByChargerVisit() {
        let box = ConditionsBox(soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // seed last[battery] = .automatic

        box.mode = .high                                    // (1) manual .high on battery
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 0)
        XCTAssertEqual(runner.lastBattery, .automatic)

        box.plugged = true; box.soc = 15; box.mode = .automatic   // (2) plug in, drained → charger wants .low
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 1, "the charger source gets its own set")
        XCTAssertEqual(setter.calls.last?.source, 1)        // charger
        XCTAssertEqual(setter.calls.last?.mode, 1)          // .low
        XCTAssertEqual(runner.lastCharger, .low)
        XCTAssertEqual(runner.lastBattery, .automatic, "the charger visit must not touch last[battery]")

        box.plugged = false; box.soc = 50; box.mode = .high       // (3) unplug; battery still manual .high
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 1, "NO battery set — the manual .high is held, not clobbered")
        XCTAssertEqual(box.mode, .high, "the battery manual .high survives the round trip")
        XCTAssertEqual(runner.lastBattery, .automatic)
        XCTAssertNotNil(runner.autoNote)
    }

    /// GROK dropped-set recovery — a set in flight, a newer desired arrives and is deferred; on the
    /// in-flight completion the re-evaluate drives the newer desired (no strand). last advances only on
    /// the success callbacks. (Two-mode realisation: last advances to .low on the first success, which
    /// makes the now-desired .automatic a genuine edge the re-evaluate drives.)
    func testRunner_droppedSet_recoversNewerDesiredOnCompletion() {
        let box = ConditionsBox(soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // last[battery] = .automatic

        setter.autoComplete = false                         // hold the .low set in flight
        box.soc = 15
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 1)
        XCTAssertEqual(setter.calls.last?.mode, 1)          // .low (pending)
        XCTAssertEqual(runner.lastBattery, .automatic, "the in-flight set has not advanced last")

        box.soc = 50                                        // a newer desired (.automatic) WHILE in flight
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 1, "the newer desired is deferred while a set is in flight")
        XCTAssertEqual(runner.lastBattery, .automatic, "a deferred edge does not advance last")

        setter.autoComplete = true                          // let the recovery set complete inline
        setter.complete()                                   // .low lands → re-evaluate drives .automatic
        XCTAssertEqual(setter.calls.count, 2, "the completion re-evaluate drives the newer desired (no strand)")
        XCTAssertEqual(setter.calls.last?.mode, 0)          // .automatic
        XCTAssertEqual(setter.calls.last?.source, 0)        // battery
        XCTAssertEqual(runner.lastBattery, .automatic, "last ends at the newer desired (advanced on successes only)")
        XCTAssertEqual(box.mode, .automatic, "reality recovered to the newer desired")
    }

    func testRunner_onEnableWithMismatch_appliesDisclosesSeeds() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // desired .low ≠ mode .automatic → apply
        XCTAssertEqual(setter.calls.count, 1)
        XCTAssertEqual(setter.calls.last?.mode, 1)          // .low
        XCTAssertEqual(setter.calls.last?.source, 0)        // battery
        XCTAssertEqual(runner.lastBattery, .low, "seeds last on the applied desired (success)")
        XCTAssertEqual(box.mode, .low)
        XCTAssertTrue(runner.autoNote?.contains("Low Power") ?? false, "on-enable apply discloses")
    }

    func testRunner_disabled_isInert() {
        let box = ConditionsBox(soc: 10, plugged: false, mode: .automatic)   // would want .low
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.evaluate(); runner.evaluate()                // never enabled (default OFF)
        XCTAssertEqual(setter.calls.count, 0, "a disabled runner drives nothing, regardless of conditions")
        XCTAssertNil(runner.autoNote)
        XCTAssertNil(runner.lastBattery)
    }

    func testRunner_unreachableSetter_keepsNoteHonest_doesNotAdvanceLast_noLoop() {
        let box = ConditionsBox(soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true
        setter.result = .failure(.unreachable)
        box.soc = 15
        runner.evaluate()                                   // edge → drive .low → unreachable
        XCTAssertEqual(setter.calls.count, 1, "one attempt — no tight retry loop on persistent failure")
        XCTAssertEqual(runner.lastBattery, .automatic, "an honest failure does NOT advance last")
        XCTAssertEqual(box.mode, .automatic, "no fake success — reality is unchanged")
        XCTAssertTrue(runner.autoNote?.localizedCaseInsensitiveContains("helper") ?? false,
                      "the failure note is honest")
    }

    /// Robustness: when the live source mode is unknown (`.unavailable` — pmset not yet read/failed) the
    /// runner cannot compare, so it drives no set and seeds nothing (never a spurious set on an unread mode).
    func testRunner_unavailableCurrentMode_drivesNoSet() {
        let box = ConditionsBox(soc: 10, plugged: false, mode: .unavailable)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 0, "never drive against an unknown live mode")
        XCTAssertNil(runner.lastBattery, "no seeding against an unknown mode")
    }

    // MARK: - Runner: thermal trigger + thermal-aware disclosure (sec 11)

    func testRunner_thermalEdge_drivesLowWithHighTemperatureDisclosure() {
        let box = ConditionsBox(thermal: .nominal, soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // in sync at nominal / soc 50
        XCTAssertEqual(setter.calls.count, 0)
        box.thermal = .serious                              // a thermal edge (nominal → serious)
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 1, "thermal-hot drives exactly one set to Low")
        XCTAssertEqual(setter.calls.last?.mode, 1)          // .low
        XCTAssertEqual(box.mode, .low)
        XCTAssertTrue(runner.autoNote?.localizedCaseInsensitiveContains("high temperature") ?? false,
                      "the disclosure leads with the thermal cause")
    }

    func testRunner_thermalRelease_healthyBattery_drivesBackToAutomatic() {
        let box = ConditionsBox(thermal: .serious, soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // on-enable: thermal-hot → drive Low
        XCTAssertEqual(setter.calls.count, 1)
        XCTAssertEqual(setter.calls.last?.mode, 1)          // .low
        XCTAssertEqual(box.mode, .low)
        box.thermal = .nominal                              // it cools; battery is healthy (soc 50)
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 2, "the thermal release drives back to Automatic")
        XCTAssertEqual(setter.calls.last?.mode, 0)          // .automatic
        XCTAssertEqual(box.mode, .automatic)
    }

    func testRunner_thermalHotAndBatteryLow_disclosureLeadsWithTemperature() {
        let box = ConditionsBox(thermal: .serious, soc: 15, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // both hot AND low → Low; reason leads with temp
        XCTAssertEqual(setter.calls.count, 1)
        XCTAssertEqual(setter.calls.last?.mode, 1)          // .low
        XCTAssertTrue(runner.autoNote?.localizedCaseInsensitiveContains("high temperature") ?? false,
                      "thermal is the higher-priority cause")
        XCTAssertFalse(runner.autoNote?.localizedCaseInsensitiveContains("battery below") ?? false,
                       "the battery cause is suppressed when thermal leads")
    }

    // MARK: - Pure policy: the plugged-High branch + the precedence matrix (sec 12)

    func testPolicy_pluggedHighFiresAtHealthySoc_bitStaysFalse() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 80, highAllowed: true, lowEngaged: false)
        XCTAssertEqual(r.desired, .high, "plugged-High fires at a healthy SOC")
        XCTAssertFalse(r.lowEngaged, "the High overlay NEVER feeds the battery bit")
    }
    func testPolicy_highNotPermitted_staysAutomatic() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 80, highAllowed: false, lowEngaged: false)
        XCTAssertEqual(r.desired, .automatic, "High not permitted (battery / sub-toggle off / unsupported) → never .high")
        XCTAssertFalse(r.lowEngaged)
    }
    func testPolicy_batteryLowBeatsHigh() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 15, highAllowed: true, lowEngaged: false)
        XCTAssertEqual(r.desired, .low, "battery-low beats High (step 2 precedes step 3)")
        XCTAssertTrue(r.lowEngaged, "the bit engages on SOC")
    }
    func testPolicy_thermalBeatsHigh() {
        let r = AutoEnergyPolicy.evaluate(thermal: .serious, soc: 80, highAllowed: true, lowEngaged: false)
        XCTAssertEqual(r.desired, .low, "thermal beats High (step 1 precedes step 3)")
        XCTAssertFalse(r.lowEngaged, "the thermal force never feeds the bit")
    }
    func testPolicy_midBandHoldBeatsHigh() {
        let r = AutoEnergyPolicy.evaluate(thermal: .nominal, soc: 25, highAllowed: true, lowEngaged: true)
        XCTAssertEqual(r.desired, .low, "a mid-band hysteresis hold beats High")
        XCTAssertTrue(r.lowEngaged)
    }

    // MARK: - Runner: the plugged-High gating + the consent transitions (sec 12)

    /// plugged + highAvailable + sub-toggle ON, healthy SOC → exactly one set to .high on the CHARGER
    /// source, with "Auto: High Power (plugged in)" published ONLY on the success callback. The set is
    /// held in flight to prove success-callback-only advancement (no optimistic note / no early `last`).
    func testRunner_pluggedHigh_drivesOneSetToHighOnCharger_disclosesOnSuccessOnly() {
        let box = ConditionsBox(soc: 80, plugged: true, mode: .automatic, highAvailable: true)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // sub-toggle still off → in sync at .automatic
        XCTAssertEqual(setter.calls.count, 0)
        XCTAssertEqual(runner.lastCharger, .automatic)

        setter.autoComplete = false                         // hold the High set in flight
        runner.highWhenPluggedEnabled = true                // consent ON → a High edge on the charger
        XCTAssertEqual(setter.calls.count, 1, "exactly one set on the High edge")
        XCTAssertEqual(setter.calls.first?.mode, 2)         // .high
        XCTAssertEqual(setter.calls.first?.source, 1)       // charger
        XCTAssertEqual(runner.lastCharger, .automatic, "last must NOT advance before success (success-callback-only)")
        XCTAssertTrue(runner.autoNote?.localizedCaseInsensitiveContains("High Power") ?? false,
                      "Option 3 (sec 15.3): the persistent status shows auto's intent while the set is in flight")

        setter.complete()                                   // success callback
        XCTAssertEqual(setter.calls.count, 1, "no extra set after a clean success")
        XCTAssertEqual(runner.lastCharger, .high, "last advances ONLY on the success callback")
        XCTAssertTrue(runner.autoNote?.contains("High Power") ?? false, "disclosure publishes on success")
        XCTAssertTrue(runner.autoNote?.localizedCaseInsensitiveContains("plugged in") ?? false,
                      "the disclosure reads \"Auto: High Power (plugged in)\"")
    }

    /// sub-toggle OFF, else identical → the runner NEVER proposes High.
    func testRunner_subToggleOff_noHighSet() {
        let box = ConditionsBox(soc: 80, plugged: true, mode: .automatic, highAvailable: true)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // consent off → highAllowed false
        XCTAssertFalse(setter.calls.contains { $0.mode == 2 }, "with the sub-toggle off the runner never proposes High")
        XCTAssertEqual(box.mode, .automatic)
    }

    /// on battery (not plugged) + sub-toggle ON → highAllowed is false → no High set.
    func testRunner_onBattery_subToggleOn_noHighSet() {
        let box = ConditionsBox(soc: 80, plugged: false, mode: .automatic, highAvailable: true)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.highWhenPluggedEnabled = true
        runner.enabled = true
        XCTAssertFalse(setter.calls.contains { $0.mode == 2 }, "on battery highAllowed is false → never High")
        XCTAssertEqual(box.mode, .automatic)
    }

    /// highAvailable false (unsupported hardware) + sub-toggle ON + plugged → no High set (the defensive AND).
    func testRunner_highUnavailable_subToggleOn_plugged_noHighSet() {
        let box = ConditionsBox(soc: 80, plugged: true, mode: .automatic, highAvailable: false)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.highWhenPluggedEnabled = true
        runner.enabled = true
        XCTAssertFalse(setter.calls.contains { $0.mode == 2 }, "unsupported hardware → highAllowed false → never High")
        XCTAssertEqual(box.mode, .automatic)
    }

    /// precedence at the runner level: plugged + sub-toggle ON + a LOW battery → drives .low, not .high.
    func testRunner_pluggedHigh_batteryLowWins_drivesLowNotHigh() {
        let box = ConditionsBox(soc: 15, plugged: true, mode: .automatic, highAvailable: true)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.highWhenPluggedEnabled = true
        runner.enabled = true                               // battery-low beats High → Low on the charger
        XCTAssertEqual(setter.calls.count, 1)
        XCTAssertEqual(setter.calls.last?.mode, 1, "battery-low wins → Low, not High")
        XCTAssertEqual(setter.calls.last?.source, 1)        // charger (the current source while plugged)
        XCTAssertEqual(box.mode, .low)
        XCTAssertFalse(setter.calls.contains { $0.mode == 2 }, "High is never set while the battery is low")
    }

    /// unplug while in High → the next evaluation drops the BATTERY source out of High to Automatic.
    func testRunner_unplugWhileInHigh_dropsToAutomaticOnBattery() {
        let box = ConditionsBox(soc: 80, plugged: true, mode: .automatic, highAvailable: true)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.highWhenPluggedEnabled = true
        runner.enabled = true                               // plugged-High → High on the charger
        XCTAssertEqual(setter.calls.last?.mode, 2)
        XCTAssertEqual(setter.calls.last?.source, 1)        // charger
        XCTAssertEqual(box.mode, .high)

        box.plugged = false; box.mode = .high               // unplug; the battery source currently reads High
        runner.evaluate()
        XCTAssertEqual(setter.calls.last?.mode, 0, "unplugged → the battery source drops out of High to Automatic")
        XCTAssertEqual(setter.calls.last?.source, 0)        // battery
        XCTAssertEqual(box.mode, .automatic)
    }

    /// toggling the sub-toggle OFF while plugged-High → the didSet re-evaluation reverts the charger to Automatic.
    func testRunner_subToggleOffWhilePluggedHigh_revertsChargerToAutomatic() {
        let box = ConditionsBox(soc: 80, plugged: true, mode: .automatic, highAvailable: true)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.highWhenPluggedEnabled = true
        runner.enabled = true                               // plugged-High → High on the charger
        XCTAssertEqual(box.mode, .high)
        XCTAssertEqual(runner.lastCharger, .high)

        runner.highWhenPluggedEnabled = false               // withdraw consent → the didSet re-evaluates
        XCTAssertEqual(setter.calls.last?.mode, 0, "the consent withdrawal reverts the charger to Automatic")
        XCTAssertEqual(setter.calls.last?.source, 1)        // charger
        XCTAssertEqual(box.mode, .automatic)
        XCTAssertEqual(runner.lastCharger, .automatic)
    }

    // MARK: - Phase 4 / Option 3: active-source BRANCH A/B/C + the persistent status (sec 15.1 / 16)

    /// BRANCH A (sec 15.1): protection is ABSOLUTE — it overrides a manual High to Low, the status names
    /// the cause, last advances on success; and on release BRANCH C expresses the CURRENT desired, not the
    /// pre-override manual (must-fix 2 — a defeated manual does not resurrect).
    func testRunner_branchA_protectionOverridesManualHigh_releasesToDesiredNotManual() {
        let box = ConditionsBox(soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // in sync at Automatic; lastBattery seeded .automatic
        XCTAssertEqual(setter.calls.count, 0)

        box.mode = .high; box.soc = 15                      // a manual High AND battery-low protection now fires
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 1, "BRANCH A overrides the manual — one set")
        XCTAssertEqual(setter.calls.last?.mode, 1, "drives Low (protection)")          // .low
        XCTAssertEqual(setter.calls.last?.source, 0)                                    // battery
        XCTAssertEqual(box.mode, .low, "the manual High is overridden to Low")
        XCTAssertEqual(runner.lastBattery, .low, "last advances on success")
        XCTAssertEqual(runner.autoNote, "Auto holds Low Power: battery below 20%",
                       "the persistent status names the protection cause")

        box.soc = 50                                        // protection releases
        runner.evaluate()
        XCTAssertEqual(setter.calls.last?.mode, 0, "BRANCH C expresses the current desired (Automatic)")  // .automatic
        XCTAssertEqual(box.mode, .automatic, "the defeated manual High does NOT resurrect (must-fix 2)")
        XCTAssertEqual(runner.autoNote, "Auto: Automatic")
    }

    /// BRANCH B (the headline Option 3 change): a manual choice OUTSIDE protection STANDS even where the old
    /// Phase 1-3 reassert would have clobbered it. Here auto's last is .low (from a just-cleared protection)
    /// and the user has set High; Option 3 respects the High instead of driving to Automatic.
    func testRunner_branchB_manualHighStands_wherePhase3WouldClobber() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // battery-low → BRANCH A sets Low; lastBattery=.low
        XCTAssertEqual(setter.calls.count, 1)
        XCTAssertEqual(box.mode, .low)

        box.soc = 50; box.mode = .high                      // protection clears AND the user manually sets High
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 1, "BRANCH B respects the manual High — NO further set (no clobber)")
        XCTAssertEqual(box.mode, .high, "the manual High stands outside protection")
        XCTAssertEqual(runner.lastBattery, .low, "a respected manual NEVER advances last")
        XCTAssertEqual(runner.autoNote, "Manual High Power in effect")
    }

    /// BRANCH C active-source release (sec 15.2): auto undoes its OWN protective Low on the active source
    /// when the cause clears (live == last == .low, no manual divergence) → drive Automatic.
    func testRunner_branchC_releasesOwnActiveLow_whenProtectionClears() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // battery-low → Low; lastBattery=.low, box.mode=.low
        XCTAssertEqual(box.mode, .low)
        box.soc = 50                                        // protection clears; no manual (live .low == last .low)
        runner.evaluate()
        XCTAssertEqual(setter.calls.last?.mode, 0, "auto releases its own Low to Automatic")   // .automatic
        XCTAssertEqual(setter.calls.last?.source, 0)        // battery
        XCTAssertEqual(box.mode, .automatic)
        XCTAssertEqual(runner.lastBattery, .automatic)
        XCTAssertEqual(runner.autoNote, "Auto: Automatic")
    }

    /// SENTINEL (must-fix 1): a source with a nil baseline (cold start / post-enable reset) must route to
    /// BRANCH A or BRANCH C, NEVER a false BRANCH B — no spurious "Manual ... in effect" on a first visit.
    func testRunner_sentinel_nilBaselineNeverFalseBranchB() {
        let box = ConditionsBox(soc: 50, plugged: false, mode: .high)   // pre-existing High; baseline nil on enable
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // enable resets baselines to nil; first visit
        XCTAssertEqual(setter.calls.count, 1, "BRANCH C asserts on a nil baseline — not a false BRANCH B hold")
        XCTAssertEqual(setter.calls.last?.mode, 0, "drives Automatic (auto's desired), not a manual hold")  // .automatic
        XCTAssertEqual(box.mode, .automatic)
        XCTAssertFalse(runner.autoNote?.localizedCaseInsensitiveContains("Manual") ?? false,
                       "no spurious 'Manual ... in effect' on a first visit")
    }

    /// THE PROTECTION FIGHT (sec 15.5): under sustained protection a repeated manual High is reasserted to
    /// Low each time (BRANCH A, driven by "live != .low" not by an edge), and the recently-failed guard
    /// prevents a tight spin when the set fails.
    func testRunner_protectionFight_reassertsLowAndDoesNotSpinOnFailure() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // protection → Low; lastBattery=.low, box.mode=.low
        XCTAssertEqual(setter.calls.count, 1)

        box.mode = .high                                    // (fight 1) user re-raises to High under protection
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 2, "protection reasserts Low over the manual High")
        XCTAssertEqual(setter.calls.last?.mode, 1)          // .low
        XCTAssertEqual(box.mode, .low)

        box.mode = .high                                    // (fight 2) again
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 3, "protection reasserts again")
        XCTAssertEqual(box.mode, .low)

        setter.result = .failure(.unreachable)              // the no-spin guarantee on a failing override
        box.mode = .high
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, 4, "exactly one attempt on a failing protection override — no spin")
        XCTAssertTrue(runner.autoNote?.localizedCaseInsensitiveContains("helper") ?? false)
    }

    /// OWNER INTEGRATION (sec 14.1 / 15.2): a manual High at 80% while plugged with the High sub-toggle OFF
    /// STANDS (no protection → BRANCH B), named by the persistent status.
    func testRunner_owner_manualHigh80PluggedStands() {
        let box = ConditionsBox(soc: 80, plugged: true, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // sub off → desired Automatic; in sync, lastCharger=.automatic
        box.mode = .high                                    // manual High at 80% plugged, no protection
        runner.evaluate()
        XCTAssertFalse(setter.calls.contains { $0.mode == 0 && $0.source == 1 },
                       "the manual High at 80% stands — auto does not drive Automatic (BRANCH B)")
        XCTAssertEqual(box.mode, .high)
        XCTAssertEqual(runner.autoNote, "Manual High Power in effect")
    }

    /// PROTECTION-BOUNDARY handoff with a manual present (must-fix 6): Low is held through the SOC band
    /// (BRANCH A reasserts at the mid-band too), then on release BRANCH B respects the standing manual
    /// High — no flip-flop at the boundary.
    func testRunner_boundaryHandoff_manualHighRespectedAfterProtectionReleases() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // protection → Low; lastBattery=.low
        box.mode = .high                                    // user sets High under protection (overridden)
        runner.evaluate()
        XCTAssertEqual(box.mode, .low, "protection reasserts Low over the manual High (BRANCH A)")

        box.soc = 25; box.mode = .high                      // mid-band (still engaged) — protection holds
        runner.evaluate()
        XCTAssertEqual(box.mode, .low, "Low held through the hysteresis band (still engaged)")

        let callsBeforeRelease = setter.calls.count
        box.soc = 50; box.mode = .high                      // crosses exit → protection releases; manual stands
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, callsBeforeRelease, "no drive on release — BRANCH B respects the manual High")
        XCTAssertEqual(box.mode, .high, "the manual High stands after protection releases (no flip-flop)")
        XCTAssertEqual(runner.autoNote, "Manual High Power in effect")
    }

    // MARK: - Phase 4 / section 13: the inactive-source release (release-only, Low-only)

    /// RELEASE FIRES (sec 13.5): auto releases the INACTIVE source's transient Low when the Low cause
    /// clears and the inactive live is still the .low auto set (the HARD-LIMIT manual guard passes).
    func testRunner_inactiveRelease_firesWhenCauseClears() {
        let box = ConditionsBox(soc: 15, plugged: true, mode: .automatic, inactiveSourceMode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // plugged + battery-low → charger Low; lastCharger=.low
        XCTAssertEqual(box.mode, .low)
        XCTAssertEqual(runner.lastCharger, .low)

        box.plugged = false; box.soc = 50; box.mode = .automatic; box.inactiveSourceMode = .low  // unplug to healthy
        runner.evaluate()
        XCTAssertTrue(setter.calls.contains { $0.source == 1 && $0.mode == 0 },
                      "the inactive charger's transient Low is released to Automatic")
        XCTAssertEqual(runner.lastCharger, .automatic, "last[charger] advances to Automatic on the release success")
        XCTAssertEqual(box.inactiveSourceMode, .automatic, "reality: the charger profile is now Automatic")
    }

    /// RELEASE IS LOW-ONLY (sec 13.1): a per-source HIGH is a standing preference, never released on unplug.
    func testRunner_inactiveRelease_lowOnly_highPreserved() {
        let box = ConditionsBox(soc: 80, plugged: true, mode: .automatic, highAvailable: true, inactiveSourceMode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.highWhenPluggedEnabled = true
        runner.enabled = true                               // plugged-High → charger .high; lastCharger=.high
        XCTAssertEqual(runner.lastCharger, .high)
        let callsAfterEnable = setter.calls.count

        box.plugged = false; box.soc = 50; box.mode = .automatic; box.inactiveSourceMode = .high  // unplug
        runner.evaluate()
        XCTAssertFalse(setter.calls.dropFirst(callsAfterEnable).contains { $0.source == 1 },
                       "a per-source High is preserved — never released on unplug")
        XCTAssertEqual(runner.lastCharger, .high, "last[charger] stays High")
    }

    /// THE HARD LIMIT (sec 13.4): auto held the inactive source at Low, but the inactive LIVE is now High
    /// (a manual change since) → auto does NOT revert it; the manual choice is protected at release time.
    func testRunner_inactiveRelease_hardLimit_manualNotReverted() {
        let box = ConditionsBox(soc: 15, plugged: true, mode: .automatic, inactiveSourceMode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // plugged + battery-low → charger Low; lastCharger=.low
        XCTAssertEqual(runner.lastCharger, .low)
        let callsBefore = setter.calls.count

        box.plugged = false; box.soc = 50; box.mode = .automatic; box.inactiveSourceMode = .high  // inactive live = manual High
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, callsBefore, "the HARD LIMIT: a manually-changed inactive source is not reverted")
        XCTAssertEqual(box.inactiveSourceMode, .high, "the manual High on the inactive source is left intact")
    }

    /// STILL-WANTS-LOW blocks the release (sec 13.3): while the Low cause still holds (lowEngaged true) the
    /// inactive Low is NOT released.
    func testRunner_inactiveRelease_blockedWhileCauseHolds() {
        let box = ConditionsBox(soc: 15, plugged: true, mode: .automatic, inactiveSourceMode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // charger Low; lastCharger=.low; lowEngaged true
        let callsBefore = setter.calls.count

        box.plugged = false; box.soc = 18; box.mode = .low; box.inactiveSourceMode = .low  // still low (18 < exit 30)
        runner.evaluate()
        XCTAssertFalse(setter.calls.dropFirst(callsBefore).contains { $0.source == 1 && $0.mode == 0 },
                       "no inactive release while the Low cause still holds")
    }

    /// THERMAL-ONLY transient (sec 13.5): auto held the inactive source at Low for THERMAL (lowEngaged
    /// false); when thermal returns below serious the inactive Low is released to Automatic.
    func testRunner_inactiveRelease_thermalTransient_releasesWhenCool() {
        let box = ConditionsBox(thermal: .serious, soc: 80, plugged: true, mode: .automatic, inactiveSourceMode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // thermal → charger Low; lastCharger=.low; lowEngaged false
        XCTAssertEqual(runner.lastCharger, .low)
        XCTAssertFalse(runner.lowEngaged, "thermal Low does not engage the battery bit")

        box.plugged = false; box.thermal = .nominal; box.soc = 80; box.mode = .automatic; box.inactiveSourceMode = .low
        runner.evaluate()
        XCTAssertTrue(setter.calls.contains { $0.source == 1 && $0.mode == 0 },
                      "the thermal-only inactive Low is released when the system cools")
        XCTAssertEqual(runner.lastCharger, .automatic)
    }

    /// SEQUENCING (sec 13.3): a pass needing BOTH an active drive and an inactive release drives the ACTIVE
    /// source FIRST; the inactive release lands on the completion's re-evaluate; never two in flight.
    func testRunner_sequencing_activeDriveFirst_thenInactiveRelease() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic, inactiveSourceMode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // battery .low; lastBattery=.low; lowEngaged true
        box.plugged = true; box.soc = 15; box.mode = .automatic; box.inactiveSourceMode = .low  // plug at low → charger .low
        runner.evaluate()
        XCTAssertEqual(runner.lastCharger, .low)
        XCTAssertEqual(runner.lastBattery, .low)

        setter.autoComplete = false                         // hold the active set in flight
        box.soc = 50; box.mode = .low; box.inactiveSourceMode = .low   // charge past exit (both sources live .low)
        runner.evaluate()
        XCTAssertEqual(setter.calls.last?.source, 1, "the ACTIVE charger is driven FIRST")
        XCTAssertEqual(setter.calls.last?.mode, 0, "active charger → Automatic")
        let countWithOneInFlight = setter.calls.count
        XCTAssertEqual(setter.calls.filter { $0.source == 0 && $0.mode == 0 }.count, 0,
                       "the inactive battery release is NOT yet issued (single-in-flight)")

        setter.autoComplete = true
        setter.complete()                                   // active lands → re-evaluate releases the inactive battery
        XCTAssertGreaterThan(setter.calls.count, countWithOneInFlight, "the inactive release lands on the completion re-evaluate")
        XCTAssertTrue(setter.calls.contains { $0.source == 0 && $0.mode == 0 },
                      "the inactive battery Low is released to Automatic AFTER the active set")
        XCTAssertEqual(runner.lastBattery, .automatic)
    }

    /// THE FIX (sec 13.4) end-to-end: battery-low Low on battery → plug in (charger Low, battery-low wins)
    /// → charge past exit (charger to Automatic, battery RELEASED) → unplug at 80 (battery in sync at
    /// Automatic, NO stale Low). The owner-reported bug the inactive release fixes.
    func testRunner_theFix_batteryLowReleasedAcrossPlugChargeUnplug() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic, inactiveSourceMode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // battery-low → battery .low; lastBattery=.low
        XCTAssertEqual(box.mode, .low)

        box.plugged = true; box.soc = 15; box.mode = .automatic; box.inactiveSourceMode = .low  // plug at low
        runner.evaluate()
        XCTAssertEqual(box.mode, .low, "battery-low WINS while plugged → charger Low")
        XCTAssertEqual(runner.lastCharger, .low)
        XCTAssertEqual(runner.lastBattery, .low)

        box.soc = 50; box.mode = .low; box.inactiveSourceMode = .low   // charge past exit
        runner.evaluate()
        XCTAssertEqual(box.mode, .automatic, "active charger released to Automatic")
        XCTAssertEqual(box.inactiveSourceMode, .automatic, "inactive battery transient Low RELEASED")
        XCTAssertEqual(runner.lastBattery, .automatic)
        XCTAssertEqual(runner.lastCharger, .automatic)

        box.plugged = false; box.soc = 80; box.mode = .automatic; box.inactiveSourceMode = .automatic  // unplug at 80
        let callsBefore = setter.calls.count
        runner.evaluate()
        XCTAssertEqual(setter.calls.count, callsBefore, "unplug at 80 → battery in sync at Automatic, NO stale Low set")
        XCTAssertEqual(box.mode, .automatic)
    }

    // MARK: - isHolding disclosure signal (ISSUE-9, additive — NO policy change)

    func testIsHolding_trueOnBatteryLowProtection() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // battery-low → BRANCH A drives .low
        XCTAssertEqual(box.mode, .low)
        XCTAssertTrue(runner.isHolding, "a battery-low protection hold sets isHolding")
    }

    func testIsHolding_trueOnThermalProtection() {
        let box = ConditionsBox(thermal: .serious, soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // thermal → BRANCH A drives .low
        XCTAssertEqual(box.mode, .low)
        XCTAssertTrue(runner.isHolding, "a thermal protection hold sets isHolding")
    }

    func testIsHolding_falseForManualStand_branchB() {
        let box = ConditionsBox(soc: 50, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // in sync, no protection
        box.mode = .high                                    // a manual choice OUTSIDE protection (BRANCH B)
        runner.evaluate()
        XCTAssertEqual(runner.autoNote, "Manual High Power in effect")
        XCTAssertFalse(runner.isHolding, "a respected manual (BRANCH B) is not a protection hold")
    }

    func testIsHolding_falseForAutoDesired_branchC() {
        let box = ConditionsBox(soc: 80, plugged: true, mode: .automatic, highAvailable: true)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.highWhenPluggedEnabled = true
        runner.enabled = true                               // BRANCH C drives .high (auto's own desired)
        XCTAssertEqual(box.mode, .high)
        XCTAssertFalse(runner.isHolding, "auto expressing its own desired (BRANCH C) is not a hold")
    }

    func testIsHolding_falseWhenDisabled() {
        let box = ConditionsBox(soc: 10, plugged: false, mode: .automatic)   // would want .low if enabled
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.evaluate()                                   // never enabled (default OFF)
        XCTAssertFalse(runner.isHolding)
    }

    /// The completion is the authority after a drive: a hold that RELEASES (the cause clears) drops isHolding.
    func testIsHolding_clearsWhenProtectionReleases() {
        let box = ConditionsBox(soc: 15, plugged: false, mode: .automatic)
        let setter = MockAutoSetter(box: box)
        let runner = makeRunner(box: box, setter: setter)
        runner.enabled = true                               // battery-low → hold
        XCTAssertTrue(runner.isHolding)
        box.soc = 50                                        // protection clears → BRANCH C releases to Automatic
        runner.evaluate()
        XCTAssertEqual(box.mode, .automatic)
        XCTAssertFalse(runner.isHolding, "isHolding drops when the hold releases")
    }

    // MARK: - EnergyModeController additive completion seam (sec 0/6)

    func testController_completion_firesWithTokenOnSuccess() {
        let setter = SeamMockSetter(); setter.result = .success("1")
        let c = EnergyModeController(setter: setter)
        var got: Result<String, HelperClientError>?
        c.setMode(1, source: 0) { got = $0 }
        guard case .success(let token)? = got else { return XCTFail("completion must fire with the success token") }
        XCTAssertEqual(token, "1")
    }

    func testController_completion_firesWithErrorOnFailure() {
        let setter = SeamMockSetter(); setter.result = .failure(.unreachable)
        let c = EnergyModeController(setter: setter)
        var got: Result<String, HelperClientError>?
        c.setMode(1, source: 0) { got = $0 }
        guard case .failure(.unreachable)? = got else { return XCTFail("completion must fire with the honest error") }
    }

    func testController_completion_firesOnSerializationDrop() {
        let setter = SeamMockSetter(); setter.autoComplete = false
        let c = EnergyModeController(setter: setter)
        c.setMode(1, source: 0)                             // first set in flight (picker-style, no completion)
        var dropped: Result<String, HelperClientError>?
        c.setMode(2, source: 0) { dropped = $0 }            // overlapping → dropped; completion MUST fire
        XCTAssertNotNil(dropped, "the serialization-drop guard fires the runner-facing completion")
        if case .success = dropped { XCTFail("a serialization drop is not a success") }
    }

    func testController_pickerCallWithNoCompletion_isUnchanged() {
        let setter = SeamMockSetter(); setter.result = .success("2")
        let c = EnergyModeController(setter: setter)
        c.setMode(2, source: 1)                             // existing picker call shape — byte-unchanged
        XCTAssertEqual(c.lastReadback, "2")
        XCTAssertNil(c.lastError)
    }
}
