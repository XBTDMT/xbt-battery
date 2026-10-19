import XCTest

/// #EI-1a (SPEC 02-SPEC-ei1a-whats-keeping-awake.md): the FILTER + grouping is the tested crux. Given
/// raw assertion records (process, type, name) it returns the user-meaningful, own-excluded,
/// per-process grouped "what else is keeping your Mac awake" list. Driven directly (pure) + through a
/// mock AssertionInventory for the source. Never the live system call.
@MainActor
final class WhatsKeepingAwakeTests: XCTestCase {

    private let ourName = KeepAwakeController.assertionName   // "Battery: keep awake"

    private func rec(_ pid: Int, _ proc: String, _ type: String, _ name: String,
                     _ reason: String = "") -> AssertionRecord {
        AssertionRecord(pid: pid, processName: proc, type: type, name: name, reason: reason)
    }

    // MARK: - include-set passes

    func testIncludedFamilyTypesAreSurfacedWithReasons() {
        let recs = [
            rec(10, "caffeinate", "PreventUserIdleSystemSleep", "caffeinate command-line tool"),
            rec(11, "Brave", "NoIdleSleepAssertion", "WebRTC has active PeerConnections"),
            rec(12, "configd", "DenySystemSleep", "InternetSharingPreferencePlugin"),
            rec(13, "coreaudiod", "PreventUserIdleDisplaySleep", "Audio is playing"),
        ]
        let holders = WhatsKeepingAwake.holders(from: recs, excludingOwnName: ourName)
        XCTAssertEqual(holders.map(\.processName), ["caffeinate", "Brave", "configd", "coreaudiod"])
        XCTAssertEqual(holders[1].reasons, ["WebRTC has active PeerConnections"], "the reason string is carried")
    }

    // MARK: - exclude-set is dropped

    func testNoiseTypesAreDropped() {
        let recs = [
            rec(1, "WindowServer", "UserIsActive", "user input"),
            rec(2, "x", "BackgroundTask", "bg"),
            rec(3, "x", "NetworkClientActive", "net"),
            rec(4, "x", "ExternalMedia", "media"),
            rec(5, "apsd", "ApplePushServiceTask", "push"),
            rec(6, "softwareupdated", "SoftwareUpdateTask", "update"),
            rec(7, "x", "InternalPreventDisplaySleep", "internal"),   // Internal* family
        ]
        XCTAssertTrue(WhatsKeepingAwake.holders(from: recs, excludingOwnName: ourName).isEmpty,
                      "all transient/noise types dropped")
    }

    func testOwnAssertionExcluded() {
        let recs = [rec(99, "Battery", "PreventUserIdleSystemSleep", "Battery: keep awake")]
        XCTAssertTrue(WhatsKeepingAwake.holders(from: recs, excludingOwnName: ourName).isEmpty,
                      "we never report ourselves")
    }

    func testPowerdCircularDroppedButRealHoldersKept() {
        let recs = [
            rec(50, "powerd", "PreventUserIdleSystemSleep", "Prevent sleep while display is on"),  // circular → drop
            rec(51, "coreaudiod", "PreventUserIdleSystemSleep", "Audio is playing"),               // real → keep
        ]
        let holders = WhatsKeepingAwake.holders(from: recs, excludingOwnName: ourName)
        XCTAssertEqual(holders.map(\.processName), ["coreaudiod"],
                       "powerd's circular display holder dropped; a real same-type holder kept")
    }

    func testPowerdNonCircularReasonIsKept() {
        // Match the circular holder by owner + name, so a DIFFERENT powerd reason is not blanket-excluded.
        let recs = [rec(50, "powerd", "PreventSystemSleep", "Some other real reason")]
        XCTAssertEqual(WhatsKeepingAwake.holders(from: recs, excludingOwnName: ourName).map(\.processName),
                       ["powerd"])
    }

    // MARK: - grouping / attribution

    func testMultipleAssertionsFromOneProcessCollapseAndReasonsDedupe() {
        let recs = [
            rec(20, "backupd", "PreventSystemSleep", "Backup Job"),
            rec(20, "backupd", "PreventUserIdleSystemSleep", "Backup Job"),   // duplicate reason → deduped
            rec(20, "backupd", "DenySystemSleep", "Indexing"),               // distinct reason
        ]
        let holders = WhatsKeepingAwake.holders(from: recs, excludingOwnName: ourName)
        XCTAssertEqual(holders.count, 1, "one entry per process")
        XCTAssertEqual(holders.first?.processName, "backupd")
        XCTAssertEqual(holders.first?.reasons, ["Backup Job", "Indexing"], "reasons carried, deduped, in order")
    }

    // MARK: - empty distinct from populated

    func testEmptyDistinctFromPopulated() {
        XCTAssertTrue(WhatsKeepingAwake.holders(from: [], excludingOwnName: ourName).isEmpty)
        let populated = WhatsKeepingAwake.holders(
            from: [rec(1, "caffeinate", "PreventSystemSleep", "the 114-hour one")], excludingOwnName: ourName)
        XCTAssertFalse(populated.isEmpty)
        XCTAssertEqual(populated.first?.reasons, ["the 114-hour one"])
    }

    func testFamilyHolderWithEmptyReasonIsStillSurfacedWithNoReasons() {
        // A real family assertion with no named string: the process is still surfaced (it IS holding
        // the Mac awake), just with no reason text. The empty name is skipped, not displayed as blank.
        let holders = WhatsKeepingAwake.holders(
            from: [rec(30, "someDaemon", "PreventSystemSleep", "")], excludingOwnName: ourName)
        XCTAssertEqual(holders.map(\.processName), ["someDaemon"], "the holder is surfaced")
        XCTAssertEqual(holders.first?.reasons, [], "an empty reason is skipped, leaving no reason text")
    }

    // MARK: - source reads through the seam (mock inventory)

    final class MockInventory: AssertionInventory {
        var records: [AssertionRecord]
        init(_ r: [AssertionRecord]) { records = r }
        func currentAssertions() -> [AssertionRecord] { records }
    }

    func testSourceRefreshAppliesFilterAndExcludesOwn() {
        let mock = MockInventory([
            rec(1, "caffeinate", "PreventSystemSleep", "the 114-hour one"),
            rec(2, "Battery", "PreventUserIdleSystemSleep", "Battery: keep awake"),  // ours → excluded
            rec(3, "powerd", "PreventUserIdleSystemSleep", "Prevent sleep while display is on"),  // circular → excluded
        ])
        let source = KeepAwakeInventorySource(inventory: mock, ownAssertionName: ourName)
        XCTAssertFalse(source.hasRead, "not yet read")
        source.refresh()
        XCTAssertTrue(source.hasRead, "read state distinct from not-yet-read")
        XCTAssertEqual(source.holders.map(\.processName), ["caffeinate"], "only the real holder survives the filter")
    }

    // MARK: - v2: the friendly name + explanation chooser (record reason → curated hint → AssertName)

    /// The record's HumanReadableReason wins when present (caffeinate carries one on-device).
    func testExplanation_recordReasonWins() {
        let r = rec(10, "caffeinate", "PreventUserIdleSystemSleep", "caffeinate command-line tool",
                    "THE CAFFEINATE TOOL IS PREVENTING SLEEP.")
        XCTAssertEqual(WhatsKeepingAwake.explanation(for: r), "THE CAFFEINATE TOOL IS PREVENTING SLEEP.",
                       "the record's HumanReadableReason wins when present")
    }

    /// A bare first-party daemon (no HumanReadableReason) gets its curated label + curated why.
    func testCuratedHint_bareDaemon_displayNameAndWhy() {
        let r = rec(20, "backupd", "PreventSystemSleep", "Backup Job", "")   // no record reason
        XCTAssertEqual(WhatsKeepingAwake.displayName(for: r), "Time Machine",
                       "a known first-party daemon gets its curated label")
        XCTAssertEqual(WhatsKeepingAwake.explanation(for: r), "A Time Machine backup",
                       "with no record reason, the curated why is used")
    }

    /// An unknown process with no reason falls back: displayName = its record processName, explanation = AssertName.
    func testAssertNameFallback_unknownProcess_noReason() {
        let r = rec(30, "com.acme.helper", "PreventSystemSleep", "Doing work", "")
        XCTAssertEqual(WhatsKeepingAwake.displayName(for: r), "com.acme.helper",
                       "an unknown process falls back to its record processName")
        XCTAssertEqual(WhatsKeepingAwake.explanation(for: r), "Doing work",
                       "no reason and no hint → the AssertName")
    }

    // MARK: - v2: record parsing — Process Name preference vs the proc_name / "PID N" fallback

    /// The record's "Process Name" is preferred (free, exit-safe); HumanReadableReason is carried.
    func testRecordParse_processNamePreferredWhenPresent() {
        let dict: [String: Any] = ["AssertType": "PreventSystemSleep", "AssertName": "Backup Job",
                                   "Process Name": "backupd", "HumanReadableReason": "A backup"]
        let r = LiveAssertionInventory.record(from: dict, pid: 42, fallbackName: "PID 42")
        XCTAssertEqual(r?.processName, "backupd", "the record's Process Name is preferred over the fallback")
        XCTAssertEqual(r?.reason, "A backup", "HumanReadableReason is carried")
        XCTAssertEqual(r?.name, "Backup Job")
        XCTAssertEqual(r?.type, "PreventSystemSleep")
    }

    /// With no "Process Name", the proc_name / "PID N" fallback path stays reachable; absent reason → "".
    func testRecordParse_fallsBackWhenProcessNameAbsent() {
        let dict: [String: Any] = ["AssertType": "PreventSystemSleep", "AssertName": "x"]
        let r = LiveAssertionInventory.record(from: dict, pid: 7, fallbackName: "PID 7")
        XCTAssertEqual(r?.processName, "PID 7", "absent Process Name → the proc_name / \"PID N\" fallback is reachable")
        XCTAssertEqual(r?.reason, "", "absent HumanReadableReason → empty")
    }

    // MARK: - (1b) terminate keep-awake holders: confirm copy + the quit-target seam

    /// A mock terminator: resolves only the pids it's told about (absent = a daemon / CLI / self), and
    /// records terminate calls. Models "already gone" via terminateResult = false.
    final class MockTerminator: AppTerminating {
        var resolve: [Int: TerminableApp] = [:]
        var terminateCalls: [TerminableApp] = []
        var terminateResult = true
        func terminableApp(pid: Int) -> TerminableApp? { resolve[pid] }
        @discardableResult func terminate(_ app: TerminableApp) -> Bool {
            terminateCalls.append(app); return terminateResult
        }
    }

    private func holder(_ pid: Int, _ display: String, explanation: String) -> KeepAwakeHolder {
        KeepAwakeHolder(pid: pid, processName: display, displayName: display,
                        explanation: explanation, reasons: explanation.isEmpty ? [] : [explanation])
    }

    func testConfirmMessage_withExplanation_surfacesReasonAfterColon() {
        let m = KeepAwakeTerminator.confirmMessage(for: holder(42, "Brave", explanation: "WebRTC has active PeerConnections"))
        XCTAssertEqual(m.title, "Quit Brave?")
        XCTAssertEqual(m.body, "It's keeping your Mac awake: WebRTC has active PeerConnections")
    }

    func testConfirmMessage_emptyExplanation_endsWithCleanPeriodNoColon() {
        let m = KeepAwakeTerminator.confirmMessage(for: holder(7, "SomeApp", explanation: ""))
        XCTAssertEqual(m.title, "Quit SomeApp?")
        XCTAssertEqual(m.body, "It's keeping your Mac awake.", "no reason → a clean period, no dangling separator")
        XCTAssertFalse(m.body.contains(":"), "no colon when there is no reason")
    }

    func testQuitTarget_guiAppResolvesToTerminable() {
        let mock = MockTerminator()
        let app = TerminableApp(pid: 42, name: "Brave", bundleId: "com.brave.Browser")
        mock.resolve[42] = app
        XCTAssertEqual(KeepAwakeTerminator.quitTarget(for: holder(42, "Brave", explanation: "call"), via: mock), app,
                       "a GUI-app holder resolves to its terminable app (the row offers Quit)")
    }

    func testQuitTarget_daemonResolvesToNil() {
        let mock = MockTerminator()   // resolves nothing → models a daemon / CLI / self
        XCTAssertNil(KeepAwakeTerminator.quitTarget(for: holder(99, "powerd", explanation: "Display"), via: mock),
                     "a daemon holder is non-terminable → no Quit, the cue shows instead")
    }

    func testTerminate_invokedExactlyOnceWithTarget() {
        let mock = MockTerminator()
        let app = TerminableApp(pid: 42, name: "Brave", bundleId: nil)
        XCTAssertTrue(mock.terminate(app), "graceful terminate returns true while running")
        XCTAssertEqual(mock.terminateCalls, [app], "terminate invoked exactly once with the target")
    }

    func testTerminate_reResolveMissReturnsFalse() {
        let mock = MockTerminator()
        mock.terminateResult = false   // the app already quit between classification and the call
        XCTAssertFalse(mock.terminate(TerminableApp(pid: 1, name: "X", bundleId: nil)),
                       "an already-gone re-resolve returns false")
    }

    // MARK: - #30 §4.4 / §14-D8: AssertStartWhen → startedAt → heldSince, and dwell text

    func testRecordReadsAssertStartWhenAsDate() {
        let t = Date(timeIntervalSince1970: 1_757_000_000)
        let dict: [String: Any] = ["AssertType": "PreventUserIdleSystemSleep", "AssertName": "x",
                                   "AssertStartWhen": t as NSDate]   // the IOPM record bridges an NSDate (verified: __NSTaggedDate)
        let r = LiveAssertionInventory.record(from: dict, pid: 7, fallbackName: "p")
        XCTAssertEqual(r?.startedAt, t)
        XCTAssertEqual(LiveAssertionInventory.startWhenKey, "AssertStartWhen")
    }

    func testRecordStartedAtIsNilWhenAbsentOrNotADate() {
        let base: [String: Any] = ["AssertType": "PreventUserIdleSystemSleep"]
        XCTAssertNil(LiveAssertionInventory.record(from: base, pid: 7, fallbackName: "p")?.startedAt)
        var wrong = base; wrong["AssertStartWhen"] = 1_757_000_000
        XCTAssertNil(LiveAssertionInventory.record(from: wrong, pid: 7, fallbackName: "p")?.startedAt,
                     "a number is not a date; no guessing")
    }

    func testHolderHeldSinceIsTheEarliestKeptStart() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 5_000)
        var a = rec(11, "Brave", "NoIdleSleepAssertion", "later"); a.startedAt = late
        var b = rec(11, "Brave", "PreventUserIdleSystemSleep", "earlier"); b.startedAt = early
        var noise = rec(11, "Brave", "UserIsActive", "noise"); noise.startedAt = Date(timeIntervalSince1970: 1)
        let c = rec(12, "configd", "DenySystemSleep", "sharing")   // no start → nil
        let hs = WhatsKeepingAwake.holders(from: [a, noise, b, c], excludingOwnName: ourName)
        XCTAssertEqual(hs.map(\.pid), [11, 12])
        XCTAssertEqual(hs[0].heldSince, early, "the oldest KEPT record, not the first-seen one")
        XCTAssertNil(hs[1].heldSince)
    }

    func testDwellText() {
        let t0 = Date(timeIntervalSince1970: 0)
        func d(_ s: TimeInterval) -> String { WhatsKeepingAwake.dwellText(since: t0, now: t0.addingTimeInterval(s)) }
        XCTAssertEqual(d(45), "45 s")
        XCTAssertEqual(d(0), "0 s")
        XCTAssertEqual(d(59.9), "59 s")
        XCTAssertEqual(d(60), "1 m")
        XCTAssertEqual(d(12 * 60 + 30), "12 m")
        XCTAssertEqual(d(2 * 3600 + 10 * 60 + 5), "2 h 10 m")
        XCTAssertEqual(d(3600), "1 h 0 m")
        XCTAssertEqual(d(5 * 86400 + 22 * 3600 + 59 * 60), "5 d 22 h")
        XCTAssertEqual(d(86400), "1 d 0 h")
        XCTAssertEqual(d(-30), "0 s", "a start in the future never renders negative")
    }
}
