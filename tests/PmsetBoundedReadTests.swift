import XCTest
import Shared

/// AUDIT B6 — the blocking `pmset` readers.
///
/// Two defects, and the first CAUSES the second:
///
/// 1. **The unread `standardError` pipe.** Every reader wired `process.standardError = Pipe()` and
///    then never read it. A pipe holds ~64 KB; a child that writes more than that BLOCKS on the
///    write, never exits, and never closes stdout — so the parent's `readDataToEndOfFile()` on
///    stdout blocks FOREVER. The unread pipe is not a cosmetic leak, it is the wedge.
///
/// 2. **The in-flight latch.** `readInFlight` / `energyModeReadInFlight` / `perSourceReadInFlight`
///    are set at kickoff and cleared ONLY in the completion that a wedged child never delivers. One
///    wedged spawn therefore disables that reader for the LIFE OF THE PROCESS, with no user-
///    accessible way back — the same shape B3 fixed on XPC, the same shape `helperUnreachable` had
///    before `7718e8f`.
///
/// These tests pin both halves. The latch tests use a reader that WEDGES on demand, which is exactly
/// what a real wedged child looks like from the controller's side.
@MainActor
final class PmsetBoundedReadTests: XCTestCase {

    // MARK: - a reader seam that wedges on demand (a wedged child, from the caller's side)

    /// Blocks inside `readEnergyMode()` until the test releases it — the off-main read never returns,
    /// so the completion that clears the in-flight flag never runs.
    final class WedgingEnergyModeReader: EnergyModeReading, @unchecked Sendable {
        private let release = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _wedge = true
        private var _mode: EnergyMode = .automatic

        var wedge: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _wedge }
            set { lock.lock(); _wedge = newValue; lock.unlock() }
        }
        var mode: EnergyMode {
            get { lock.lock(); defer { lock.unlock() }; return _mode }
            set { lock.lock(); _mode = newValue; lock.unlock() }
        }

        func readEnergyMode() -> EnergyMode {
            if wedge { entered.signal(); release.wait() }
            return mode
        }

        /// Block the calling test until the wedged read has actually started.
        func waitUntilWedged() { entered.wait() }
        /// Let the wedged read finish (test cleanup — never leave a thread parked).
        func unwedge() { release.signal() }
    }

    /// Poll the main actor until `check` passes or the budget runs out (the reads settle through a
    /// `Task { @MainActor }` hop, so there is nothing synchronous to await).
    private func waitUntil(_ budget: TimeInterval = 2, _ check: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if check() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - B6 latch 1: BatteryMonitor.energyModeReadInFlight

    /// RED before the fix: one wedged `pmset -g` permanently deadens the Energy-Mode read, so the
    /// glyph's Low-Power tint can never update again for the life of the process. GREEN after: the
    /// next read past the stale bound reclaims the gate and the value updates — with no user action.
    func testWedgedEnergyModeRead_doesNotLatchTheReaderForever() async {
        var clock: TimeInterval = 1000
        let reader = WedgingEnergyModeReader()
        let monitor = BatteryMonitor(reader: MockPowerSourceReader(live: [:]),
                                     energyModeReader: reader,
                                     monotonicNow: { clock })
        defer { reader.unwedge() }

        monitor.refreshEnergyMode()          // wedges off-main and never returns
        reader.waitUntilWedged()

        // The machine's Energy Mode changes while the reader is wedged.
        reader.wedge = false
        reader.mode = .low

        // Time passes well past any sane bound for a `pmset` read.
        clock += 60
        monitor.refreshEnergyMode()

        await waitUntil { monitor.snapshot.energyMode == .low }
        XCTAssertEqual(monitor.snapshot.energyMode, .low,
                       "a single wedged pmset read latched energyModeReadInFlight forever")
    }

    /// The pile-up guard must SURVIVE the fix: two reads back-to-back inside the bound still spawn
    /// only once (that guard is why the flag exists at all — audit L2 / A11).
    func testInFlightGuardStillCoalescesRapidReads() async {
        var clock: TimeInterval = 1000
        let reader = WedgingEnergyModeReader()
        let monitor = BatteryMonitor(reader: MockPowerSourceReader(live: [:]),
                                     energyModeReader: reader,
                                     monotonicNow: { clock })
        defer { reader.unwedge() }

        monitor.refreshEnergyMode()
        reader.waitUntilWedged()

        reader.wedge = false
        reader.mode = .low
        clock += 1                            // still well inside the bound
        monitor.refreshEnergyMode()           // must be coalesced away

        await waitUntil(0.3) { monitor.snapshot.energyMode == .low }
        XCTAssertEqual(monitor.snapshot.energyMode, .unavailable,
                       "the pile-up guard must still coalesce a second read inside the bound")
    }
}

// MARK: - B6 latch 2: WakeBehaviorController.readInFlight

@MainActor
final class PmsetBoundedReadWakeBehaviorTests: XCTestCase {

    /// Blocks inside `readCurrent()` until released — a wedged `pmset -g custom` from the caller's side.
    final class WedgingWakeReader: WakeBehaviorReading, @unchecked Sendable {
        private let release = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _wedge = true
        private var _state: WakeBehaviorReadback.State?

        var wedge: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _wedge }
            set { lock.lock(); _wedge = newValue; lock.unlock() }
        }
        var state: WakeBehaviorReadback.State? {
            get { lock.lock(); defer { lock.unlock() }; return _state }
            set { lock.lock(); _state = newValue; lock.unlock() }
        }

        func readCurrent() -> WakeBehaviorReadback.State? {
            if wedge { entered.signal(); release.wait() }
            return state
        }
        func waitUntilWedged() { entered.wait() }
        func unwedge() { release.signal() }
    }

    @MainActor
    final class NoopSetter: WakeBehaviorSetter {
        func setWakeBehavior(powerNapBattery: Bool, powerNapAC: Bool,
                             wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool,
                             completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {}
    }

    private func waitUntil(_ budget: TimeInterval = 2, _ check: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if check() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static let live = WakeBehaviorReadback.State(powerNapBattery: false, powerNapAC: true,
                                                         wakeOnNetworkBattery: false, wakeOnNetworkAC: true)

    /// RED before the fix: one wedged read froze the wake-behavior read-back — and the pickers with it,
    /// since `adopt` is the only thing that snaps them to live truth.
    func testWedgedRead_doesNotLatchTheReadbackForever() async {
        var clock: TimeInterval = 500
        let reader = WedgingWakeReader()
        let c = WakeBehaviorController(setter: NoopSetter(), reader: reader, monotonicNow: { clock })
        defer { reader.unwedge() }

        c.refreshReadback()
        reader.waitUntilWedged()

        reader.wedge = false
        reader.state = Self.live
        clock += BoundedReadGate.staleAfterSeconds + 1
        c.refreshReadback()

        await waitUntil { c.lastReadback != nil }
        XCTAssertEqual(c.lastReadback, Self.live,
                       "a single wedged pmset read latched readInFlight forever")
    }

    /// The pile-up guard must survive: a second read inside the bound is still coalesced away.
    func testReadInsideTheBoundIsStillCoalesced() async {
        var clock: TimeInterval = 500
        let reader = WedgingWakeReader()
        let c = WakeBehaviorController(setter: NoopSetter(), reader: reader, monotonicNow: { clock })
        defer { reader.unwedge() }

        c.refreshReadback()
        reader.waitUntilWedged()

        reader.wedge = false
        reader.state = Self.live
        clock += 1
        c.refreshReadback()

        await waitUntil(0.3) { c.lastReadback != nil }
        XCTAssertNil(c.lastReadback, "the pile-up guard must still coalesce a read inside the bound")
    }

    /// A reclaimed read that finally returns must NOT clobber the newer read that replaced it.
    /// A completion that does not hold the live token settles nothing — that is what keeps a wedged
    /// read, when it finally returns, from clobbering the read that replaced it.
    func testACompletionWithoutTheLiveTokenSettlesNothing() {
        let reader = WedgingWakeReader()
        let c = WakeBehaviorController(setter: NoopSetter(), reader: reader, monotonicNow: { 0 })
        defer { reader.unwedge() }

        c.refreshReadback()            // claims token 1 and wedges
        reader.waitUntilWedged()
        c.settleReadback(token: 99, state: Self.live, readGeneration: 0)
        XCTAssertNil(c.lastReadback, "only the read holding the live token may settle")
    }
}

// MARK: - B6 latch 3: SleepWakeScheduleController.readInFlight

@MainActor
final class PmsetBoundedReadSleepWakeTests: XCTestCase {

    final class WedgingScheduleReader: SleepScheduleReading, @unchecked Sendable {
        private let release = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _wedge = true
        private var _result: RepeatingSchedule?
        private var _wedgedResult: RepeatingSchedule?

        var wedge: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _wedge }
            set { lock.lock(); _wedge = newValue; lock.unlock() }
        }
        var result: RepeatingSchedule? {
            get { lock.lock(); defer { lock.unlock() }; return _result }
            set { lock.lock(); _result = newValue; lock.unlock() }
        }
        /// What the WEDGED read returns once released — deliberately distinct from `result`, so a late
        /// completion is visible if it ever lands.
        var wedgedResult: RepeatingSchedule? {
            get { lock.lock(); defer { lock.unlock() }; return _wedgedResult }
            set { lock.lock(); _wedgedResult = newValue; lock.unlock() }
        }

        func readRepeatingSchedule() -> RepeatingSchedule? {
            if wedge { entered.signal(); release.wait(); return wedgedResult }
            return result
        }
        func waitUntilWedged() { entered.wait() }
        func unwedge() { release.signal() }
    }

    @MainActor
    final class NoopSetter: SleepWakeSetter {
        func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                                   wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int,
                                   completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {}
    }

    final class FakeStore: SleepWakeScheduleStoring {
        var saved: SleepWakeScheduleConfig = .empty
        func loadConfig() -> SleepWakeScheduleConfig { saved }
        func saveConfig(_ c: SleepWakeScheduleConfig) { saved = c }
    }

    private func waitUntil(_ budget: TimeInterval = 2, _ check: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if check() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// RED before the fix. This latch is the most consequential of the three: `lastReadback == nil`
    /// makes `applyDecision`/`cancelNeedsConfirm` report "cannot verify authorship", so a single wedged
    /// `pmset -g sched` forces the destructive-cancel confirm on EVERY apply and cancel, forever.
    func testWedgedRead_doesNotLatchTheScheduleReadbackForever() async {
        var clock: TimeInterval = 900
        let reader = WedgingScheduleReader()
        let c = SleepWakeScheduleController(setter: NoopSetter(), reader: reader, store: FakeStore(),
                                            monotonicNow: { clock })
        defer { reader.unwedge() }

        c.refreshReadback()
        reader.waitUntilWedged()

        reader.wedge = false
        reader.result = RepeatingSchedule.none   // an empty schedule reads as vacuously ours
                                                 // (spelled in full: bare `.none` on an Optional is nil)
        clock += BoundedReadGate.staleAfterSeconds + 1
        c.refreshReadback()

        await waitUntil { c.lastReadback != nil }
        XCTAssertEqual(c.lastReadback, RepeatingSchedule.none,
                       "a single wedged pmset read latched readInFlight forever")
        XCTAssertFalse(c.cancelNeedsConfirm(for: c.lastReadback),
                       "and with it forced the destructive-cancel confirm on every cancel")
    }

    func testReadInsideTheBoundIsStillCoalesced() async {
        var clock: TimeInterval = 900
        let reader = WedgingScheduleReader()
        let c = SleepWakeScheduleController(setter: NoopSetter(), reader: reader, store: FakeStore(),
                                            monotonicNow: { clock })
        defer { reader.unwedge() }

        c.refreshReadback()
        reader.waitUntilWedged()

        reader.wedge = false
        reader.result = RepeatingSchedule.none
        clock += 1
        c.refreshReadback()

        await waitUntil(0.3) { c.lastReadback != nil }
        XCTAssertNil(c.lastReadback, "the pile-up guard must still coalesce a read inside the bound")
    }

    /// The full race, end to end: read 1 wedges and is reclaimed, read 2 lands, and read 1 THEN
    /// returns a stale schedule. The stale value must never reach `lastReadback` — an authorship
    /// verdict computed from a superseded read is exactly the kind of wrong the confirm gate exists
    /// to prevent.
    func testAReclaimedReadReturningLateDoesNotClobberTheNewerResult() async {
        var clock: TimeInterval = 900
        let stale = RepeatingSchedule(events: [RepeatingPowerEvent(kind: .sleep, minuteOfDay: 60,
                                                                   weekdayMask: 0b111_1111)])
        let reader = WedgingScheduleReader()
        reader.wedgedResult = stale
        let c = SleepWakeScheduleController(setter: NoopSetter(), reader: reader, store: FakeStore(),
                                            monotonicNow: { clock })

        c.refreshReadback()                          // token 1: wedges, will return `stale`
        reader.waitUntilWedged()
        reader.wedge = false
        reader.result = RepeatingSchedule.none       // token 2 will return the FRESH value
        clock += BoundedReadGate.staleAfterSeconds + 1
        c.refreshReadback()
        await waitUntil { c.lastReadback != nil }
        XCTAssertEqual(c.lastReadback, RepeatingSchedule.none)

        reader.unwedge()                             // token 1 finally returns, holding a stale value
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(c.lastReadback, RepeatingSchedule.none,
                       "a superseded read must not clobber the newer result")
    }
}

// MARK: - the gate itself (pure)

@MainActor
final class BoundedReadGateTests: XCTestCase {

    func testBeginCoalescesWhileInFlight() {
        var gate = BoundedReadGate()
        XCTAssertEqual(gate.begin(now: 100), 1)
        XCTAssertNil(gate.begin(now: 100))
        XCTAssertNil(gate.begin(now: 100 + BoundedReadGate.staleAfterSeconds - 0.01))
    }

    func testBeginReclaimsAStaleRead() {
        var gate = BoundedReadGate()
        let first = gate.begin(now: 100)
        let second = gate.begin(now: 100 + BoundedReadGate.staleAfterSeconds)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2, "a read past the bound is presumed wedged and reclaimed")
    }

    func testOnlyTheFirstArrivalSettles() {
        var gate = BoundedReadGate()
        let token = gate.begin(now: 0)!
        XCTAssertTrue(gate.settle(token))
        XCTAssertFalse(gate.settle(token), "the loser of the race must do nothing")
    }

    func testASupersededTokenNeverSettles() {
        var gate = BoundedReadGate()
        let stale = gate.begin(now: 0)!
        let live = gate.begin(now: BoundedReadGate.staleAfterSeconds)!
        XCTAssertFalse(gate.settle(stale), "the reclaimed read must not settle the new one")
        XCTAssertTrue(gate.settle(live))
    }

    func testSettlingReleasesTheGateForTheNextRead() {
        var gate = BoundedReadGate()
        let token = gate.begin(now: 0)!
        XCTAssertTrue(gate.settle(token))
        XCTAssertNotNil(gate.begin(now: 0), "a settled gate is immediately available again")
    }

    func testIsStaleIsMonotonicAndBoundaryInclusive() {
        XCTAssertFalse(BoundedReadGate.isStale(startedAt: 10, now: 10))
        XCTAssertFalse(BoundedReadGate.isStale(startedAt: 10, now: 9))   // backwards clock is never stale
        XCTAssertFalse(BoundedReadGate.isStale(startedAt: 10, now: 10 + BoundedReadGate.staleAfterSeconds - 0.01))
        XCTAssertTrue(BoundedReadGate.isStale(startedAt: 10, now: 10 + BoundedReadGate.staleAfterSeconds))
    }

    /// The backstop must sit ABOVE the spawn's own bound, or it would preempt reads the spawn already
    /// handles honestly — the same ordering B3's 25 s XPC backstop keeps over the 20 s call timeout.
    func testTheGateBoundSitsAboveTheSpawnBound() {
        XCTAssertGreaterThan(BoundedReadGate.staleAfterSeconds,
                             PmsetProbe.timeoutSeconds + PmsetProbe.graceSeconds)
    }
}

// MARK: - the bounded, fully-drained spawn

final class PmsetProbeTests: XCTestCase {

    /// THE RED TEST FOR HALF ONE. The child writes 200 KB to stderr — far past a pipe's ~64 KB buffer —
    /// and only then writes stdout. With the pre-fix shape (`standardError = Pipe()`, never read) the
    /// child blocks on its stderr write, never closes stdout, and the parent's
    /// `readDataToEndOfFile()` never returns: a permanent wedge, on a healthy machine, with no signal.
    /// Draining both pipes concurrently is what makes this return at all.
    func testAFloodOnStderrDoesNotWedgeTheChild() {
        let outcome = PmsetProbe.capture(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' 'x' >&2; echo done"],
            timeout: 10)
        XCTAssertTrue(outcome.succeeded, "the child must not deadlock against an undrained stderr pipe")
        XCTAssertFalse(outcome.timedOut, "it must finish on its own, not be killed by the watchdog")
        XCTAssertEqual(outcome.stdout, "done\n")
        XCTAssertEqual(outcome.stderr.count, 200_000, "stderr must be drained in full, not truncated")
    }

    /// THE RED TEST FOR HALF TWO. A child that never exits is killed at the bound instead of parking a
    /// global-queue thread — and the caller can TELL it was killed, so partial stdout is never parsed.
    func testAWedgedChildIsBoundedAndKilled() {
        let start = Date()
        let outcome = PmsetProbe.capture(executable: "/bin/sleep", arguments: ["30"], timeout: 0.4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertFalse(outcome.succeeded, "a killed child's partial output must never count as a reading")
        XCTAssertLessThan(elapsed, 10, "the read must be bounded, not open-ended")
    }

    func testALaunchFailureIsReportedNotCrashed() {
        let outcome = PmsetProbe.capture(executable: "/nonexistent/pmset", arguments: ["-g"], timeout: 1)
        XCTAssertTrue(outcome.launchFailed)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.stdout)
    }

    /// The OTHER half of the discarded pipe: stderr is the only artifact that says WHY a read failed,
    /// and it now reaches the caller (and the log) instead of being dropped.
    func testStderrIsCarriedBackOnAFailedRead() {
        let outcome = PmsetProbe.capture(executable: "/bin/sh",
                                         arguments: ["-c", "echo 'pmset: unrecognized option' >&2; exit 3"],
                                         timeout: 5)
        XCTAssertEqual(outcome.exitCode, 3)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.stderr.contains("unrecognized option"))
        let note = PmsetProbe.failureNote(arguments: ["-g", "bogus"], outcome: outcome)
        XCTAssertEqual(note, "pmset -g bogus: exited 3 — pmset: unrecognized option")
    }

    /// The live read still works end to end (this is the production call the app makes).
    func testTheRealPmsetReadStillSucceeds() {
        let outcome = PmsetProbe.run(["-g"])
        XCTAssertTrue(outcome.succeeded, "pmset -g must still read cleanly through the bounded spawn")
        XCTAssertFalse(outcome.stdout?.isEmpty ?? true)
    }

    // MARK: pure diagnostics

    func testFailureNoteIsNilOnSuccess() {
        let ok = PmsetOutcome(stdout: "x", stderr: "", exitCode: 0, timedOut: false, launchFailed: false)
        XCTAssertNil(PmsetProbe.failureNote(arguments: ["-g"], outcome: ok))
    }

    func testFailureNoteNamesEachFailureShape() {
        let launch = PmsetOutcome(stdout: nil, stderr: "", exitCode: nil, timedOut: false, launchFailed: true)
        XCTAssertEqual(PmsetProbe.failureNote(arguments: ["-g"], outcome: launch),
                       "pmset -g: could not launch")

        let killed = PmsetOutcome(stdout: "part", stderr: "", exitCode: 9, timedOut: true, launchFailed: false)
        XCTAssertEqual(PmsetProbe.failureNote(arguments: ["-g", "sched"], outcome: killed),
                       "pmset -g sched: timed out and was killed")

        let garbled = PmsetOutcome(stdout: nil, stderr: "", exitCode: 0, timedOut: false, launchFailed: false)
        XCTAssertEqual(PmsetProbe.failureNote(arguments: ["-g", "cap"], outcome: garbled),
                       "pmset -g cap: produced output that is not UTF-8")
    }

    func testFirstLineIsTheFirstNonBlankLineCapped() {
        XCTAssertEqual(PmsetProbe.firstLine("\n\n  boom  \nsecond\n"), "boom")
        XCTAssertEqual(PmsetProbe.firstLine(""), "")
        XCTAssertEqual(PmsetProbe.firstLine("   \n \n"), "")
        XCTAssertEqual(PmsetProbe.firstLine(String(repeating: "x", count: 500)).count, 200)
    }
}
