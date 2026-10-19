import XCTest
import Shared

/// Sprint 3.7 STAGE 3 — app-side controller behavior via the `EnergyModeSetter` seam (host-app-free,
/// no NSXPC). Proves app-side pre-validation rejects out-of-set without a round-trip, success surfaces
/// the read-back, and an unreachable/unapproved helper produces an HONEST error (never a silent no-op).
@MainActor
final class EnergyModeControllerTests: XCTestCase {

    @MainActor
    private final class MockSetter: EnergyModeSetter {
        var result: Result<String, HelperClientError> = .success("0")
        var autoComplete = true            // false → capture the completion to fire later (serialize test)
        private(set) var callCount = 0
        private(set) var lastMode: Int?
        private(set) var lastSource: Int?
        // A QUEUE, not a single slot (B3): the timeout tests need a reply held from an EARLIER set to
        // still be deliverable after a later one has started. FIFO, so the single-pending tests are
        // byte-unchanged in behavior.
        private var pending: [(Result<String, HelperClientError>) -> Void] = []
        func setEnergyMode(mode: Int, source: Int,
                           completion: @escaping (Result<String, HelperClientError>) -> Void) {
            callCount += 1; lastMode = mode; lastSource = source
            if autoComplete { completion(result) } else { pending.append(completion) }
        }
        func complete() { guard !pending.isEmpty else { return }; pending.removeFirst()(result) }
        /// Deliver the oldest held reply with an EXPLICIT result (the late-reply race).
        func complete(with explicit: Result<String, HelperClientError>) {
            guard !pending.isEmpty else { return }
            pending.removeFirst()(explicit)
        }
        var pendingCount: Int { pending.count }
    }

    func testSetMode_invalidInput_doesNotCallSetter_setsHonestError() {
        let setter = MockSetter()
        let c = EnergyModeController(setter: setter)
        c.setMode(99, source: 0)
        XCTAssertEqual(setter.callCount, 0, "out-of-set input must NOT reach the helper")
        XCTAssertNotNil(c.lastError, "an invalid input surfaces an honest error")
        XCTAssertEqual(c.lastReadback, "—", "no read-back on a rejected input")
    }

    func testSetMode_invalidSource_doesNotCallSetter() {
        let setter = MockSetter()
        let c = EnergyModeController(setter: setter)
        c.setMode(0, source: 5)
        XCTAssertEqual(setter.callCount, 0)
        XCTAssertNotNil(c.lastError)
    }

    func testSetMode_success_setsReadback_clearsError() {
        let setter = MockSetter(); setter.result = .success("1")
        let c = EnergyModeController(setter: setter)
        c.setMode(1, source: 0)
        XCTAssertEqual(setter.callCount, 1)
        XCTAssertEqual(setter.lastMode, 1); XCTAssertEqual(setter.lastSource, 0)
        XCTAssertEqual(c.lastReadback, "1", "success surfaces the helper's read-back value")
        XCTAssertNil(c.lastError)
        XCTAssertFalse(c.isBusy)
    }

    func testSetMode_unreachable_setsHonestError_noSilentNoOp() {
        let setter = MockSetter(); setter.result = .failure(.unreachable)
        let c = EnergyModeController(setter: setter)
        c.setMode(1, source: 0)
        XCTAssertEqual(setter.callCount, 1)
        XCTAssertNotNil(c.lastError, "an unreachable helper MUST surface an honest error (no silent no-op)")
        XCTAssertTrue(c.lastError?.localizedCaseInsensitiveContains("unavailable") ?? false)
        XCTAssertEqual(c.lastReadback, "—")
        XCTAssertFalse(c.isBusy)
    }

    func testSetMode_helperErrorToken_setsHonestError() {
        let setter = MockSetter(); setter.result = .failure(.helperError(EnergyModeCommand.errSetFailed))
        let c = EnergyModeController(setter: setter)
        c.setMode(2, source: 2)
        XCTAssertNotNil(c.lastError)
        XCTAssertTrue(c.lastError?.contains("set-failed") ?? false)
    }

    // MARK: STAGE 5 — picker gating, serialize, affordance, re-read

    func testAvailableModes_gatedByHighPowerCapability() {
        let c = EnergyModeController(setter: MockSetter())
        c.highPowerAvailable = false
        XCTAssertEqual(c.availableModes, [.automatic, .low], "High hidden when the cap lacks it")
        c.highPowerAvailable = true
        XCTAssertEqual(c.availableModes, [.automatic, .low, .high], "High shown when the cap lists it")
    }

    func testSetMode_serializes_ignoresOverlappingWhileInFlight() {
        let setter = MockSetter(); setter.autoComplete = false
        let c = EnergyModeController(setter: setter)
        c.setMode(1, source: 0)
        XCTAssertEqual(setter.callCount, 1); XCTAssertTrue(c.isBusy)
        c.setMode(2, source: 0)   // overlapping → dropped
        XCTAssertEqual(setter.callCount, 1, "an overlapping set is ignored while one is in flight")
        setter.complete()
        XCTAssertFalse(c.isBusy)
        c.setMode(2, source: 0)   // now allowed
        XCTAssertEqual(setter.callCount, 2)
    }

    func testSetMode_unreachable_setsHelperUnreachableFlag_forAffordance() {
        let setter = MockSetter(); setter.result = .failure(.unreachable)
        let c = EnergyModeController(setter: setter)
        c.setMode(1, source: 0)
        XCTAssertTrue(c.isHelperUnreachable, "unreachable drives the disabled-picker + approve affordance")
        XCTAssertNotNil(c.lastError)
    }

    func testSetMode_success_callsOnSetSucceeded_clearsUnreachable() {
        let setter = MockSetter()
        let c = EnergyModeController(setter: setter)
        // First an unreachable to raise the flag…
        setter.result = .failure(.unreachable)
        c.setMode(1, source: 0)
        XCTAssertTrue(c.isHelperUnreachable)
        // …then a success clears it AND triggers the 1.8 re-read.
        var reReads = 0
        c.onSetSucceeded = { reReads += 1 }
        setter.result = .success("1")
        c.setMode(1, source: 0)
        XCTAssertEqual(reReads, 1, "success triggers the 1.8 re-read (honest resulting value)")
        XCTAssertFalse(c.isHelperUnreachable, "a later success clears the unreachable flag")
    }

    func testSetMode_failure_doesNotCallOnSetSucceeded() {
        let setter = MockSetter(); setter.result = .failure(.unreachable)
        let c = EnergyModeController(setter: setter)
        var reReads = 0
        c.onSetSucceeded = { reReads += 1 }
        c.setMode(1, source: 0)
        XCTAssertEqual(reReads, 0, "failure must NOT re-read (no optimistic update)")
    }

    func testTypedSetMode_mapsEnumsToValidatedInts() {
        let setter = MockSetter()
        let c = EnergyModeController(setter: setter)
        c.setMode(.high, source: .charger)
        XCTAssertEqual(setter.lastMode, 2)
        XCTAssertEqual(setter.lastSource, 1)
    }

    func testClearTransientState_reEnablesPickerAfterUnreachable() {
        // Recovery path: an unreachable disables the picker; popover-open clears the transient state so
        // a since-approved helper re-enables it (otherwise the disabled buttons could never re-enable).
        let setter = MockSetter(); setter.result = .failure(.unreachable)
        let c = EnergyModeController(setter: setter)
        c.setMode(1, source: 0)
        XCTAssertTrue(c.isHelperUnreachable)
        c.clearTransientState()
        XCTAssertFalse(c.isHelperUnreachable, "popover-open recovery re-enables the picker")
        XCTAssertNil(c.lastError)
    }

    // MARK: - B-arc B4: High Power capability is resolved ONCE per launch

    /// A counter the `@Sendable` probe can bump from the detached read.
    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testResolveHighPowerAvailability_spawnsOncePerLaunch() async {
        // High Power support is a HARDWARE fact — it cannot change while the process lives, so the
        // `pmset -g cap` spawn that used to run on EVERY popover open runs exactly once now.
        let counter = ProbeCounter()
        let c = EnergyModeController(setter: MockSetter())
        XCTAssertFalse(c.highPowerAvailable, "defaults conservatively to hidden")

        await c.resolveHighPowerAvailability(probe: { counter.bump(); return true })
        XCTAssertTrue(c.highPowerAvailable, "the first resolve adopts the probe's answer")
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(c.availableModes.contains(.high), "and the picker gains High Power")

        // Four more opens: no further spawns, and the resolved value stands even if the probe would
        // now answer differently (it cannot in reality — that is exactly why caching is safe).
        for _ in 0..<4 {
            await c.resolveHighPowerAvailability(probe: { counter.bump(); return false })
        }
        XCTAssertEqual(counter.count, 1, "later opens cost nothing")
        XCTAssertTrue(c.highPowerAvailable, "and cannot be flipped by a later probe")
    }

    func testResolveHighPowerAvailability_falseAnswerAlsoSticks() async {
        // The negative answer must cache too — otherwise hardware WITHOUT High Power would keep paying
        // the spawn on every open, which is the case the trim most needs to cover.
        let counter = ProbeCounter()
        let c = EnergyModeController(setter: MockSetter())
        await c.resolveHighPowerAvailability(probe: { counter.bump(); return false })
        await c.resolveHighPowerAvailability(probe: { counter.bump(); return true })
        XCTAssertEqual(counter.count, 1, "an absent capability is still a resolved fact")
        XCTAssertFalse(c.highPowerAvailable)
        XCTAssertFalse(c.availableModes.contains(.high))
    }

    // MARK: - HAND-OFF #1 (`21ec965`): an UNKNOWN read must not latch, and must say so
    //
    // THE DEFECT, graded HIGH: `highPowerResolved` was set BEFORE the await, so a single `pmset -g cap`
    // killed at the bound deleted the High Power option from the picker for the ENTIRE session — no
    // cue, no way back short of quitting. `.unknown` ("we do not know") and `.unsupported` ("this Mac
    // genuinely has none") were the same latched `false`.
    //
    // The fix has to hold BOTH ends at once, and each of these tests pins one of them:
    //   * an `.unknown` may not latch — the next popover open re-probes;
    //   * the re-probe is CAPPED — a permanently wedged `pmset` must not become a probe per open
    //     forever, which is finding A11/A12, the spawn-count class this audit spent the day removing.

    /// A scripted three-state probe that counts its calls — the `HighPowerCapability` analogue of
    /// `ProbeCounter`, and `@unchecked Sendable` for the same reason (it is called from the detached
    /// read). Runs off the end by repeating its last answer, so "and then it stayed broken" needs no
    /// padding at the call site.
    private final class ScriptedCapabilityProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let answers: [HighPowerCapability]
        private var n = 0
        init(_ answers: [HighPowerCapability]) { self.answers = answers }
        func next() -> HighPowerCapability {
            lock.lock(); defer { lock.unlock() }
            defer { n += 1 }
            return n < answers.count ? answers[n] : (answers.last ?? .unsupported)
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private static let cutShortTwice = "the capability read did not finish in time, twice"

    func testResolveHighPower_unknownDoesNotLatch_soTheNextOpenReprobes() async {
        // The recovery, end to end: a launch whose capability read was killed, then a popover open on a
        // machine that has calmed down. The option comes BACK — which before this it could not.
        let probe = ScriptedCapabilityProbe([.unknown(Self.cutShortTwice), .supported])
        let c = EnergyModeController(setter: MockSetter())

        await c.resolveHighPowerAvailability(probe: { probe.next() })
        XCTAssertFalse(c.highPowerResolved, "an unknown is not an answer — nothing may latch on it")
        XCTAssertFalse(c.highPowerAvailable,
                       "and the option still stays hidden: hiding what we cannot prove is unchanged")
        XCTAssertFalse(c.availableModes.contains(.high))
        XCTAssertNotNil(c.highPowerNote, "the change is that the absence now EXPLAINS itself")

        await c.resolveHighPowerAvailability(probe: { probe.next() })
        XCTAssertEqual(probe.count, 2, "the next popover open re-probes")
        XCTAssertTrue(c.highPowerResolved, "a SETTLED answer latches — that is the only thing that may")
        XCTAssertTrue(c.availableModes.contains(.high), "and the recovered option appears")
        XCTAssertNil(c.highPowerNote, "the cue clears the moment we actually know")
    }

    func testResolveHighPower_reprobeIsCapped_soAWedgedPmsetCannotStorm() async {
        // The other half. Un-latching without a cap turns a permanently broken `pmset -g cap` into a
        // probe on EVERY popover open, forever — the exact spawn-count regression (A11/A12) this cap
        // exists to make impossible. Eight opens, two probes.
        let probe = ScriptedCapabilityProbe([.unknown(Self.cutShortTwice)])
        let c = EnergyModeController(setter: MockSetter())
        for _ in 0..<8 { await c.resolveHighPowerAvailability(probe: { probe.next() }) }

        XCTAssertEqual(EnergyModeController.highPowerProbeLimit, 2, "two attempts, and there is no third")
        XCTAssertEqual(probe.count, EnergyModeController.highPowerProbeLimit,
                       "at most the cap per launch, then zero forever")
        XCTAssertFalse(c.highPowerResolved,
                       "nothing was ever settled — the CAP is what stops the re-read, not a fake answer")
        XCTAssertNotNil(c.highPowerNote, "and the cue stands, because we still do not know")
    }

    func testHighPowerWorstCaseSpawnsPerLaunch_isTheCapTimesTheRetryPolicy() {
        // The launch budget as arithmetic rather than a claim in a commit message: the controller may
        // start 2 reads, and `.onceIfCutShort` makes each read at most 2 children → 4, worst case, and
        // only while the machine is actually killing `pmset`. A healthy launch spawns exactly one.
        XCTAssertEqual(HighPowerCapabilityReader.retryPolicy, .onceIfCutShort)
        XCTAssertEqual(HighPowerCapabilityReader.maxSpawnsPerRead, 2)
        XCTAssertEqual(EnergyModeController.highPowerProbeLimit
                       * HighPowerCapabilityReader.maxSpawnsPerRead, 4)
    }

    func testHighPowerNote_speaksOnlyInTheUnknownState() async {
        // The three-state rule, at the SURFACE. A Mac with High Power and a Mac without it are both
        // healthy states and neither gets a sentence; only a failed read does. This is what stops the
        // note from becoming a permanent line of furniture under a picker that is working fine.
        for settled in [HighPowerCapability.supported, .unsupported] {
            let c = EnergyModeController(setter: MockSetter())
            await c.resolveHighPowerAvailability(probe: { settled })
            XCTAssertTrue(c.highPowerResolved, "\(settled) is an answer")
            XCTAssertNil(c.highPowerNote, "\(settled) is not a problem to report")
        }
        let c = EnergyModeController(setter: MockSetter())
        await c.resolveHighPowerAvailability(probe: { .unknown("the capability read could not be started") })
        XCTAssertEqual(c.highPowerNote,
                       "High Power availability unknown — the capability read could not be started.",
                       "verbatim `HighPowerCapability.note` — the surface adds no copy of its own")
    }

    /// C1's rule, applied to the SECOND surface. `760a638` gave the popover's energy card the note; the
    /// Settings·Automation picker renders the same two-of-three options from the same `availableModes`
    /// and still omitted High Power in silence — the identical defect, one screen over. A unit test that
    /// asserts the string is PRODUCED passes happily while nothing renders it (that is verbatim why the
    /// ui-orphan gate exists), so this asserts the RENDER, at the file, for both homes.
    func testHighPowerNote_isRenderedByBothEnergyModePickers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for surface in ["app/Views/BatteryPopoverView.swift", "app/App/SettingsView.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(surface), encoding: .utf8)
            XCTAssertTrue(src.contains("energyMode.highPowerNote"),
                          "\(surface) hides the High Power option without ever saying why")
        }
    }

    func testResolveHighPower_overlappingOpensStillProbeOnce() async {
        // Re-entrancy safety used to be a SIDE EFFECT of latching before the await. Un-latching had to
        // keep it, so it is now an explicit in-flight flag — otherwise two fast opens would race into
        // two `pmset` children and blow the cap in one go.
        let probe = ScriptedCapabilityProbe([.unsupported])
        let c = EnergyModeController(setter: MockSetter())
        async let first: Void = c.resolveHighPowerAvailability(probe: { probe.next() })
        async let second: Void = c.resolveHighPowerAvailability(probe: { probe.next() })
        _ = await (first, second)
        XCTAssertEqual(probe.count, 1, "a second open during the first read is still a no-op")
    }

    func testResolveHighPower_boolSeamIsUnchanged_becauseEveryBoolIsAnAnswer() async {
        // The `() -> Bool` entry point BatteryApp still passes (`HighPowerCapabilityReader.read`)
        // CANNOT express an unknown — a Bool has no third state — so it settles and latches on the
        // first call exactly as it did before. This feature is INERT until that call site moves to
        // `readDetailed`, and this test is what says so out loud.
        let counter = ProbeCounter()
        let c = EnergyModeController(setter: MockSetter())
        await c.resolveHighPowerAvailability(probe: { counter.bump(); return false })
        XCTAssertTrue(c.highPowerResolved, "a Bool is always a settled answer")
        XCTAssertNil(c.highPowerNote, "so the Bool seam can never raise the cue")
        await c.resolveHighPowerAvailability(probe: { counter.bump(); return true })
        XCTAssertEqual(counter.count, 1, "and it still costs exactly one probe per launch")
    }

    // MARK: - B3: a completion that never arrives must not wedge the picker
    //
    // `isBusy` is cleared ONLY in the completion, and both surfaces bind `.disabled(… || isBusy)`
    // (BatteryPopoverView:342, SettingsView:734) — so before the backstop, ONE lost reply deadened the
    // Energy Mode picker for the life of the process. NOTE this is NOT the 2026-06 "no swallowed
    // failure" finding: failures that ARRIVE were always reported honestly. These pin the outcome that
    // never arrives at all.

    private func makeTimedController(_ setter: MockSetter)
        -> (EnergyModeController, ManualSetWatchdog) {
        let watchdog = ManualSetWatchdog()
        return (EnergyModeController(setter: setter, setTimeout: 25, scheduleWatchdog: watchdog.schedule),
                watchdog)
    }

    func testSetMode_lostCompletion_backstopClearsIsBusyAndSurfacesHonestFailure() {
        let setter = MockSetter(); setter.autoComplete = false      // takes the call, never replies
        let (c, watchdog) = makeTimedController(setter)
        var outcomes: [Result<String, HelperClientError>] = []

        c.setMode(1, source: 0) { outcomes.append($0) }
        XCTAssertTrue(c.isBusy, "the set is in flight — the picker is disabled")
        XCTAssertEqual(outcomes.count, 0)
        XCTAssertEqual(watchdog.armedCount, 1, "every set arms exactly one deadline")
        XCTAssertEqual(watchdog.lastDelay, 25)

        watchdog.fireFirst()
        XCTAssertFalse(c.isBusy, "the deadline un-wedges the picker — this is the whole point")
        XCTAssertEqual(outcomes.count, 1, "the completion fires on the timeout path too")
        XCTAssertEqual(outcomes.first, .failure(.unreachable),
                       "routed through the EXISTING failure vocabulary, not a new case")
        XCTAssertTrue(c.isHelperUnreachable, "and drives the approve-helper affordance like a real error")
        XCTAssertNotNil(c.lastError)
        XCTAssertEqual(c.lastReadback, "—", "a timeout is never an optimistic success")

        // And the picker really is usable again.
        setter.autoComplete = true; setter.result = .success("1")
        c.setMode(1, source: 0)
        XCTAssertEqual(setter.callCount, 2, "a set after the timeout reaches the helper")
        XCTAssertEqual(c.lastReadback, "1")
    }

    func testSetMode_lateReplyRacingTheBackstop_completionFiresExactlyOnce() {
        let setter = MockSetter(); setter.autoComplete = false
        let (c, watchdog) = makeTimedController(setter)
        var outcomes: [Result<String, HelperClientError>] = []

        c.setMode(1, source: 0) { outcomes.append($0) }
        watchdog.fireFirst()                                   // the deadline wins…
        setter.complete(with: .success("1"))                   // …and the reply arrives anyway

        XCTAssertEqual(outcomes.count, 1, "EXACTLY once — the loser is discarded, not queued")
        XCTAssertEqual(outcomes.first, .failure(.unreachable), "the winner's verdict stands")
        XCTAssertEqual(c.lastReadback, "—", "a losing reply must not publish a read-back")
        XCTAssertTrue(c.isHelperUnreachable, "nor clear the honest failure state")
    }

    func testSetMode_replyBeatsTheBackstop_deadlineIsInert() {
        // The normal case: the reply settles the set, and the still-pending deadline is a no-op when it
        // later expires (it must not clobber a controller that has moved on).
        let setter = MockSetter(); setter.result = .success("1")
        let (c, watchdog) = makeTimedController(setter)
        var outcomes: [Result<String, HelperClientError>] = []

        c.setMode(1, source: 0) { outcomes.append($0) }
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(c.isBusy)

        watchdog.fireAll()
        XCTAssertEqual(outcomes.count, 1, "the expired deadline of a settled set changes nothing")
        XCTAssertEqual(c.lastReadback, "1")
        XCTAssertFalse(c.isHelperUnreachable, "and must not fake an unreachable helper after a success")
    }

    func testSetMode_expiredSetsLateReplyCannotDisturbANewerSet() {
        // The hazard the token guards: set A times out, set B starts, THEN A's reply lands. It must not
        // clear B's `isBusy` or fire B's completion.
        let setter = MockSetter(); setter.autoComplete = false
        let (c, watchdog) = makeTimedController(setter)
        var aOutcomes = 0, bOutcomes = 0

        c.setMode(1, source: 0) { _ in aOutcomes += 1 }
        watchdog.fireFirst()                                   // A expires
        XCTAssertEqual(aOutcomes, 1)

        c.setMode(2, source: 0) { _ in bOutcomes += 1 }        // B starts
        XCTAssertTrue(c.isBusy)
        XCTAssertEqual(setter.pendingCount, 2, "both replies are outstanding")

        setter.complete(with: .success("1"))                   // A's late reply (FIFO)
        XCTAssertEqual(aOutcomes, 1, "A is settled — no second completion")
        XCTAssertEqual(bOutcomes, 0, "and A's reply is NOT B's")
        XCTAssertTrue(c.isBusy, "B is still in flight")

        setter.complete(with: .success("2"))                   // B's own reply
        XCTAssertEqual(bOutcomes, 1)
        XCTAssertFalse(c.isBusy)
        XCTAssertEqual(c.lastReadback, "2")
    }

    // MARK: - S9: the validate guard used to return WITHOUT firing the completion

    func testSetMode_invalidMode_firesCompletionWithHelpersOwnRejectionToken() {
        // This path is what LiveEnergyRestoring and EnergyModeIntentSurface each pre-validate to route
        // AROUND — a `withCheckedContinuation` bridged over it hung forever.
        let setter = MockSetter()
        let c = EnergyModeController(setter: setter)
        var outcomes: [Result<String, HelperClientError>] = []
        c.setMode(99, source: 0) { outcomes.append($0) }

        XCTAssertEqual(setter.callCount, 0, "still no round-trip for out-of-set input")
        XCTAssertEqual(outcomes.count, 1, "but the caller is TOLD — no path returns silently now")
        XCTAssertEqual(outcomes.first, .failure(.helperError(EnergyModeCommand.errInvalidMode)))
        XCTAssertNotNil(c.lastError)
        XCTAssertFalse(c.isBusy, "a rejected input never went in flight")
    }

    func testSetMode_invalidSource_firesCompletionWithHelpersOwnRejectionToken() {
        let setter = MockSetter()
        let c = EnergyModeController(setter: setter)
        var outcomes: [Result<String, HelperClientError>] = []
        c.setMode(0, source: 5) { outcomes.append($0) }

        XCTAssertEqual(setter.callCount, 0)
        XCTAssertEqual(outcomes.first, .failure(.helperError(EnergyModeCommand.errInvalidSource)))
        XCTAssertEqual(outcomes.count, 1)
    }

    func testSetMode_invalidInput_armsNoDeadline() {
        // A path that never went in flight must not leave a timer behind that could later trip.
        let setter = MockSetter()
        let (c, watchdog) = makeTimedController(setter)
        c.setMode(99, source: 0)
        XCTAssertEqual(watchdog.armedCount, 0)
        watchdog.fireAll()
        XCTAssertFalse(c.isHelperUnreachable)
    }
}
