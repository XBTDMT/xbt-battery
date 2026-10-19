import XCTest
@testable import Battery

/// Sprint 4.I: the Details-open device fetch is ONE in-process IOPS read plus a CONDITIONAL `ioreg`
/// fallback. These tests drive both seams and pin the three read-states — present / absent-by-design /
/// read-failed — because before the cut an empty list and a failed read were the same value, and a
/// failing source silently erased the Devices card (audit C1; the S6 `spUnavailable` flag it regressed).
@MainActor
final class DeviceBatterySourceTests: XCTestCase {

    /// Scripts the IOPS outcome and counts reads.
    private final class ScriptedReader: AccessoryPowerSourceReading, @unchecked Sendable {
        private let outcome: AccessoryReadOutcome
        private(set) var reads = 0
        init(_ outcome: AccessoryReadOutcome) { self.outcome = outcome }
        func read() -> AccessoryReadOutcome { reads += 1; return outcome }
    }

    /// Scripts the ioreg spawn and counts it; anything else succeeds empty. The script is a QUEUE whose
    /// last entry repeats, so a test can say "cut short once, then answer" — the exact shape the
    /// latch-on-a-transient defect makes unobservable.
    private final class ScriptedProbe: ProcessProbing, @unchecked Sendable {
        enum Outcome {
            /// It ran to completion and exited 0.
            case ok(String)
            /// WE killed it at the bound (`cutShort`) — says nothing about the next attempt.
            case cutShort
            /// It died on its OWN signal. `timedOut` (the tree is not complete) but NOT `cutShort`.
            case selfCrash
            /// `posix_spawn` failed. A second spawn of the same absolute path fails identically.
            case launchFail
            /// It RAN, printed something parseable, and exited non-zero. An ANSWER, and the answer is no.
            case exited(Int32, String)
        }
        private let script: [Outcome]
        private(set) var spawns = 0
        private(set) var ioregSpawns = 0
        init(ioreg: Outcome = .ok("")) { self.script = [ioreg] }
        init(script: [Outcome]) { self.script = script }
        func run(_ launchPath: String, args: [String], timeout: TimeInterval) async -> ProcessProbeResult {
            spawns += 1
            guard launchPath.hasSuffix("ioreg") else {
                return ProcessProbeResult(stdout: "", timedOut: false, launchFailed: false, duration: 0.01)
            }
            ioregSpawns += 1
            switch script[min(ioregSpawns - 1, script.count - 1)] {
            case .ok(let s):
                return ProcessProbeResult(stdout: s, timedOut: false, launchFailed: false,
                                          duration: 0.01, exitCode: 0)
            case .cutShort:
                return ProcessProbeResult(stdout: "", timedOut: true, launchFailed: false,
                                          duration: 5, exitCode: nil, stderr: "", cutShort: true)
            case .selfCrash:
                return ProcessProbeResult(stdout: "", timedOut: true, launchFailed: false,
                                          duration: 0.2, exitCode: nil, stderr: "", cutShort: false)
            case .launchFail:
                return ProcessProbeResult(stdout: "", timedOut: false, launchFailed: true, duration: 0)
            case .exited(let code, let out):
                return ProcessProbeResult(stdout: out, timedOut: false, launchFailed: false,
                                          duration: 0.01, exitCode: code)
            }
        }
    }

    private let airpodsMax = AccessoryPowerSource(
        name: "Alex\u{2019}s AirPods Max", accessoryID: "ACCESSORY-UUID", partID: "Single",
        category: "Headset", percent: 43, isCharging: false, transport: "Bluetooth LE")

    nonisolated fileprivate static let ioregMouseFixture = """
        +-o AppleDeviceManagementHIDEventService  <class IOHIDEventDriver>
          {
            "Product" = "Magic Mouse"
            "BatteryPercent" = 55
            "DeviceAddress" = "aa-bb-cc-dd-ee-04"
          }
        """
    private var ioregMouse: String { Self.ioregMouseFixture }

    // MARK: - state 1: PRESENT

    func testPresentStateYieldsDevicesAndSpawnsNothing() async {
        let reader = ScriptedReader(.read([airpodsMax]))
        let probe = ScriptedProbe()
        let source = DeviceBatterySource(reader: reader, probe: probe, now: { 1_000 })
        await source.fetch()
        XCTAssertEqual(source.devices.count, 1)
        XCTAssertEqual(source.devices[0].id, "ACCESSORY-UUID")
        XCTAssertEqual(source.readState, .devices)
        XCTAssertNil(source.readState.note, "the healthy state shows no degradation cue")
        XCTAssertEqual(probe.spawns, 0, "IOPS answered → ZERO subprocesses on the Details-open path")
        XCTAssertEqual(reader.reads, 1)
    }

    // MARK: - state 2: ABSENT BY DESIGN

    func testNoAccessoriesAndNoHIDIsAbsentByDesignNotAFailure() async {
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])),
                                         probe: ScriptedProbe(ioreg: .ok("")), now: { 1_000 })
        await source.fetch()
        XCTAssertTrue(source.devices.isEmpty)
        XCTAssertEqual(source.readState, .noneConnected, "nothing connected is NOT a failure")
        XCTAssertEqual(source.readState.note, "No connected device reports a battery.",
                       "the card must still say something — an empty card with no cue is the C1 bug")
    }

    // MARK: - state 3: READ FAILED

    func testUnavailableIOPSReadIsReportedNotSilentlyEmpty() async {
        let source = DeviceBatterySource(reader: ScriptedReader(.unavailable("the symbol is gone")),
                                         probe: ScriptedProbe(ioreg: .ok("")), now: { 1_000 })
        await source.fetch()
        XCTAssertTrue(source.devices.isEmpty)
        XCTAssertEqual(source.readState, .unavailable("the symbol is gone"))
        XCTAssertEqual(source.readState.note, "Device batteries unavailable — the symbol is gone.")
    }

    func testFailedIoregFallbackIsAlsoReported() async {
        // Pre-4.I a pmset/ioreg failure dropped rows with NO signal at all. It now names itself.
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])),
                                         probe: ScriptedProbe(ioreg: .cutShort), now: { 1_000 })
        await source.fetch()
        XCTAssertEqual(source.readState, .unavailable("the Bluetooth HID probe did not finish in time"))
    }

    func testAFailedPrimaryReadStaysUnavailableEvenWhenTheFallbackFindsRows() async {
        let source = DeviceBatterySource(reader: ScriptedReader(.unavailable("IOPS is down")),
                                         probe: ScriptedProbe(ioreg: .ok(ioregMouse)), now: { 1_000 })
        await source.fetch()
        XCTAssertEqual(source.devices.count, 1, "the fallback still shows what it found")
        XCTAssertEqual(source.readState, .unavailable("IOPS is down"),
                       "…but the list is incomplete, and the card says so")
    }

    // MARK: - the conditional ioreg fallback

    func testIoregIsAttemptedOnlyWhenIOPSListsNoAccessory() async {
        let probe = ScriptedProbe(ioreg: .ok(ioregMouse))
        let source = DeviceBatterySource(reader: ScriptedReader(.read([airpodsMax])), probe: probe, now: { 1 })
        await source.fetch()
        await source.fetch()
        XCTAssertEqual(probe.spawns, 0, "an accessory was found → the fallback must not run")
    }

    func testIoregFallbackCoversWhatIOPSDoesNotList() async {
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])),
                                         probe: ScriptedProbe(ioreg: .ok(ioregMouse)), now: { 7 })
        await source.fetch()
        XCTAssertEqual(source.devices.count, 1, "a HID battery IOPS never listed still reaches the card")
        XCTAssertEqual(source.devices[0].name, "Magic Mouse")
        XCTAssertEqual(source.devices[0].address, "aa-bb-cc-dd-ee-04")
        XCTAssertEqual(source.readState, .devices)
    }

    func testEmptyIoregIsNotReSpawnedEveryOpenButRefreshReArmsIt() async {
        let probe = ScriptedProbe(ioreg: .ok(""))
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        await source.fetch()   // open 1: IOPS empty → one ioreg spawn, which comes back empty
        await source.fetch()   // open 2: must short-circuit
        await source.fetch()   // open 3: still short-circuited
        XCTAssertEqual(probe.spawns, 1, "an empty ioreg must not be re-spawned on every Details open")
        await source.refresh()
        XCTAssertEqual(probe.spawns, 2, "refresh() re-arms the fallback")
    }

    // MARK: - hand-off #2: the latch must distinguish "we gave up" from "it answered"

    /// RED-FIRST. `ioregExhausted` used to be set on `timedOut || launchFailed`, and `timedOut` folds in
    /// the case where OUR OWN watchdog killed the child. One loaded moment therefore disarmed the only
    /// mechanism that can reach a Bluetooth-HID battery IOPS never lists, for the whole session, with
    /// nothing in the UI to say so and no production caller of `refresh()` to undo it.
    func testACutShortProbeDoesNotDisarmTheFallbackForTheSession() async {
        let probe = ScriptedProbe(script: [.cutShort, .ok(ioregMouse)])
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        await source.fetch()   // open 1: we killed it at the bound — that is NOT an answer
        XCTAssertTrue(source.devices.isEmpty)
        await source.fetch()   // open 2: must ask again
        XCTAssertEqual(probe.ioregSpawns, 2, "a cut-short probe must re-arm — we cut it short, it did not answer")
        XCTAssertEqual(source.devices.count, 1, "…and the second attempt's device reaches the card")
        XCTAssertEqual(source.readState, .devices, "a recovered read is fully healthy again")
    }

    /// The other half: a SETTLED failure still latches on the first attempt, because asking again buys
    /// nothing. `posix_spawn` of the same absolute path fails identically.
    func testALaunchFailureStillLatchesOnTheFirstAttempt() async {
        let probe = ScriptedProbe(ioreg: .launchFail)
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        await source.fetch()
        await source.fetch()
        await source.fetch()
        XCTAssertEqual(probe.ioregSpawns, 1, "a launch failure is settled — one spawn, then never again")
        XCTAssertEqual(source.readState, .unavailable("the Bluetooth HID probe could not be started"))
    }

    /// A child that died on its OWN signal is `timedOut` but NOT `cutShort`: nothing we did bounded it,
    /// and a deterministic crash reproduces. It latches like any other settled failure.
    func testASelfCrashIsSettledAndLatches() async {
        let probe = ScriptedProbe(ioreg: .selfCrash)
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        await source.fetch()
        await source.fetch()
        XCTAssertEqual(probe.ioregSpawns, 1, "we did not bound it — re-asking a self-crash is a doubled spawn")
        XCTAssertEqual(source.readState, .unavailable("the Bluetooth HID probe stopped unexpectedly"))
    }

    /// THE CAP. Un-latching without a bound would re-spawn a wedged `ioreg` on EVERY Details open — the
    /// spawn-count class this audit spent its day deleting. The budget is a SESSION budget, not a rate:
    /// a permanently cut-short probe costs `ioregCutShortBudget` spawns for the life of the process and
    /// then zero, no matter how many times Details is opened.
    func testCutShortRetriesAreCappedForTheSession() async {
        let probe = ScriptedProbe(ioreg: .cutShort)
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        for _ in 0..<20 { await source.fetch() }
        XCTAssertEqual(probe.ioregSpawns, DeviceBatterySource.ioregCutShortBudget,
                       "20 Details opens against a permanently wedged ioreg cost a FIXED, small number of spawns")
        XCTAssertGreaterThan(DeviceBatterySource.ioregCutShortBudget, 1)
        XCTAssertLessThanOrEqual(DeviceBatterySource.ioregCutShortBudget, 3)
    }

    /// The budget counts CONSECUTIVE cut-shorts. A probe that completes refunds it, so a healthy machine
    /// whose ioreg answers cannot be starved by three unlucky moments spread across a long session.
    func testACompletedReadRefundsTheCutShortBudget() async {
        let probe = ScriptedProbe(script: [.cutShort, .cutShort, .ok(ioregMouse), .cutShort, .cutShort, .ok(ioregMouse)])
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        for _ in 0..<6 { await source.fetch() }
        XCTAssertEqual(probe.ioregSpawns, 6, "each completed read restores the budget for the next rough patch")
        XCTAssertEqual(source.devices.count, 1)
    }

    /// Once we have given up, the card must keep saying WHY. Pre-fix the second open reported
    /// `.noneConnected` — "No connected device reports a battery." — which is a claim the app never
    /// established: it never got an answer, it killed the process that was going to give one.
    func testGivingUpKeepsSayingSoInsteadOfClaimingNothingIsConnected() async {
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])),
                                         probe: ScriptedProbe(ioreg: .cutShort), now: { 1 })
        for _ in 0..<5 { await source.fetch() }
        XCTAssertEqual(source.readState, .unavailable("the Bluetooth HID probe did not finish in time"),
                       "a probe we cut short is not a probe that ran and found nothing")
    }

    /// An ioreg that RAN and found nothing is a different thing entirely, and it still says the honest
    /// absence-by-design sentence — the empty-result latch is unchanged.
    func testAnEmptyButCompletedReadStillReportsAbsenceByDesign() async {
        let probe = ScriptedProbe(ioreg: .ok(""))
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        await source.fetch()
        await source.fetch()
        XCTAssertEqual(probe.ioregSpawns, 1)
        XCTAssertEqual(source.readState, .noneConnected)
    }

    /// `refresh()` re-arms BOTH the latch and the budget — an explicit user gesture is allowed to ask
    /// again after we gave up.
    func testRefreshReArmsAfterTheBudgetIsSpent() async {
        let probe = ScriptedProbe(script: [.cutShort, .cutShort, .cutShort, .ok(ioregMouse)])
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        for _ in 0..<9 { await source.fetch() }
        XCTAssertEqual(probe.ioregSpawns, DeviceBatterySource.ioregCutShortBudget)
        await source.refresh()
        XCTAssertEqual(probe.ioregSpawns, DeviceBatterySource.ioregCutShortBudget + 1)
        XCTAssertEqual(source.devices.count, 1)
    }

    // MARK: - hand-off #2b: the child's exit status is no longer ignored

    /// `DeviceBatterySource` used to feed `out.stdout` to the parser whenever the spawn did not time out
    /// or fail to launch — so a program that FAILED but printed something parseable got parsed anyway,
    /// and its partial tree was merged and shown as fact with no cue. `ioreg` exits 0 for "no matches"
    /// (verified on macOS 27.0) and non-zero only for a real error, so gating on it costs nothing.
    func testANonZeroExitIsNotParsedEvenWhenTheOutputLooksFine() async {
        let probe = ScriptedProbe(ioreg: .exited(1, ioregMouse))
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        await source.fetch()
        XCTAssertTrue(source.devices.isEmpty, "a failed read's partial tree must not be merged as if complete")
        XCTAssertEqual(source.readState, .unavailable("the Bluetooth HID probe exited 1"))
    }

    /// …and a non-zero exit is an ANSWER, so it latches: re-asking is how a wedged-but-responsive binary
    /// gets hammered.
    func testANonZeroExitLatches() async {
        let probe = ScriptedProbe(ioreg: .exited(1, ""))
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: probe, now: { 1 })
        for _ in 0..<5 { await source.fetch() }
        XCTAssertEqual(probe.ioregSpawns, 1)
    }

    /// A clean exit 0 is parsed exactly as before — the gate is on a KNOWN non-zero status only, so the
    /// `exitCode == nil` every pre-existing scripted mock produces cannot be mistaken for a failure.
    func testAnUnknownExitCodeIsNotTreatedAsAFailure() async {
        final class LegacyProbe: ProcessProbing, @unchecked Sendable {
            func run(_ launchPath: String, args: [String], timeout: TimeInterval) async -> ProcessProbeResult {
                ProcessProbeResult(stdout: DeviceBatterySourceTests.ioregMouseFixture,
                                   timedOut: false, launchFailed: false, duration: 0.01)
            }
        }
        let source = DeviceBatterySource(reader: ScriptedReader(.read([])), probe: LegacyProbe(), now: { 1 })
        await source.fetch()
        XCTAssertEqual(source.devices.count, 1)
        XCTAssertEqual(source.readState, .devices)
    }

    // MARK: - the failure reasons are pure and distinguish the four cases

    func testProbeFailureReasonNamesEachCauseDistinctly() {
        func result(timedOut: Bool = false, launchFailed: Bool = false,
                    exitCode: Int32? = 0, cutShort: Bool = false) -> ProcessProbeResult {
            ProcessProbeResult(stdout: "", timedOut: timedOut, launchFailed: launchFailed,
                               duration: 0, exitCode: exitCode, stderr: "", cutShort: cutShort)
        }
        XCTAssertNil(DeviceBatterySource.probeFailureReason(result()))
        XCTAssertEqual(DeviceBatterySource.probeFailureReason(result(launchFailed: true)),
                       "the Bluetooth HID probe could not be started")
        XCTAssertEqual(DeviceBatterySource.probeFailureReason(result(timedOut: true, exitCode: nil, cutShort: true)),
                       "the Bluetooth HID probe did not finish in time")
        XCTAssertEqual(DeviceBatterySource.probeFailureReason(result(timedOut: true, exitCode: nil)),
                       "the Bluetooth HID probe stopped unexpectedly")
        XCTAssertEqual(DeviceBatterySource.probeFailureReason(result(exitCode: 74)),
                       "the Bluetooth HID probe exited 74")
    }

    /// Only `cutShort` re-arms. Every other failure is settled — this is the whole ruling in one assert.
    func testOnlyACutShortFailureIsRetryable() {
        func result(timedOut: Bool = false, launchFailed: Bool = false,
                    exitCode: Int32? = 0, cutShort: Bool = false) -> ProcessProbeResult {
            ProcessProbeResult(stdout: "", timedOut: timedOut, launchFailed: launchFailed,
                               duration: 0, exitCode: exitCode, stderr: "", cutShort: cutShort)
        }
        XCTAssertTrue(result(timedOut: true, exitCode: nil, cutShort: true).cutShort)
        XCTAssertFalse(result(launchFailed: true).cutShort)
        XCTAssertFalse(result(timedOut: true, exitCode: nil).cutShort)
        XCTAssertFalse(result(exitCode: 1).cutShort)
    }

    // MARK: - staleness plumbing is unchanged

    func testStalenessNoteFollowsLastFetch() async {
        var clock = 1_000
        let source = DeviceBatterySource(reader: ScriptedReader(.read([airpodsMax])),
                                         probe: ScriptedProbe(), now: { clock })
        XCTAssertNil(source.stalenessNote(), "never fetched → no note")
        await source.fetch()
        XCTAssertNil(source.stalenessNote(), "fresh → no note")
        clock += 120
        XCTAssertEqual(source.stalenessNote(), "as of 2m ago")
    }
}
