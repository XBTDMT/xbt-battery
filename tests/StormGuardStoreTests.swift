import XCTest

/// S-9b (Sprint 3.7): the persisted storm-guard state file — `crashCount` written atomically and
/// persisted across helper instances (a launchd KeepAlive relaunch re-reads it), with a corrupt or
/// missing file defaulting to `crashCount: 0` (fail toward "not tripped"). The Phase-2 charge
/// `restoreFailed` field is GONE with the SMC capability; this exercises the decoupled
/// `FileStormGuardStore`.
final class StormGuardStoreTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ba-stormguard-\(UUID().uuidString).json")
    }

    func testCrashCountPersistsAtomicallyAcrossInstances() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = FileStormGuardStore(url: url)
        s.crashCount = 3
        XCTAssertEqual(s.crashCount, 3)

        let reloaded = FileStormGuardStore(url: url)   // a NEW process re-reads the persisted file
        XCTAssertEqual(reloaded.crashCount, 3)

        reloaded.crashCount = 7
        XCTAssertEqual(FileStormGuardStore(url: url).crashCount, 7)
    }

    func testCorruptFileDefaultsToZero() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try! Data("not valid json {{{".utf8).write(to: url)
        let s = FileStormGuardStore(url: url)
        XCTAssertEqual(s.crashCount, 0); XCTAssertEqual(s.backoffLevel, 0)   // corrupt → (0,0) fail toward run
    }

    func testMissingFileDefaultsToZero() {
        let s = FileStormGuardStore(url: tempURL())
        XCTAssertEqual(s.crashCount, 0); XCTAssertEqual(s.backoffLevel, 0)   // never created → (0,0)
    }

    // S1 (Sprint 5.6): write-failure visibility. The atomic write to an unwritable parent dir fails;
    // the fix logs it (previously swallowed) WITHOUT gating the daemon — fail toward run is preserved.
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ba-stormguard-dir-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func setWritable(_ dir: URL, _ writable: Bool) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: dir.path)
    }

    func testWriteFailureIsLoggedAndFailsTowardRun() {
        let dir = tempDir()
        defer { setWritable(dir, true); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("energyhelper-state.json")
        setWritable(dir, false)            // unwritable parent → the atomic write fails

        var captured: [String] = []
        let s = FileStormGuardStore(url: url, log: { captured.append($0) })
        s.increment()                      // markStart()'s real path: the +1 can't persist

        XCTAssertTrue(captured.contains { $0.contains("PERSIST failed") },
                      "a swallowed storm-guard write must be made visible")
        XCTAssertEqual(s.crashCount, 0,
                       "fail toward run: the frozen counter reads 0, the daemon keeps vending")
    }

    // ── Cut 2: backoffLevel persistence + multi-field atomicity + schema evolution ──
    func testBackoffLevelPersistsAtomicallyAcrossInstances() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = FileStormGuardStore(url: url); s.backoffLevel = 4
        XCTAssertEqual(FileStormGuardStore(url: url).backoffLevel, 4)
    }
    func testCrashCountAndBackoffLevelPersistIndependently() {              // KEY RED
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = FileStormGuardStore(url: url)
        s.crashCount = 3; s.backoffLevel = 2; s.crashCount = 5             // neither set may clobber the other
        let r = FileStormGuardStore(url: url)
        XCTAssertEqual(r.crashCount, 5); XCTAssertEqual(r.backoffLevel, 2)
    }
    func testResetZeroesBothCounters() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = FileStormGuardStore(url: url); s.crashCount = 6; s.backoffLevel = 3; s.reset()
        let r = FileStormGuardStore(url: url)
        XCTAssertEqual(r.crashCount, 0); XCTAssertEqual(r.backoffLevel, 0)
    }
    func testIncrementBackoffPersists() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = FileStormGuardStore(url: url); s.incrementBackoff(); s.incrementBackoff()
        XCTAssertEqual(FileStormGuardStore(url: url).backoffLevel, 2)
    }
    func testOldSingleFieldSchemaLoadsBackoffZero() {                       // schema evolution guard
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try! Data(#"{"crashCount": 4}"#.utf8).write(to: url)               // pre-Cut-2 file, no backoffLevel key
        let s = FileStormGuardStore(url: url)
        XCTAssertEqual(s.crashCount, 4); XCTAssertEqual(s.backoffLevel, 0)
    }

    // ── Cut 2 (self-audit): the PRODUCTION mutators must be field-independent too (not just the setters).
    // increment() runs every launch (recordLaunchAttempt); incrementBackoff() every probation (beginProbation).
    func testIncrementPreservesBackoffLevel() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = FileStormGuardStore(url: url); s.backoffLevel = 2; s.increment()
        let r = FileStormGuardStore(url: url)
        XCTAssertEqual(r.crashCount, 1); XCTAssertEqual(r.backoffLevel, 2, "increment() must not clobber backoffLevel")
    }
    func testIncrementBackoffPreservesCrashCount() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = FileStormGuardStore(url: url); s.crashCount = 3; s.incrementBackoff()
        let r = FileStormGuardStore(url: url)
        XCTAssertEqual(r.backoffLevel, 1); XCTAssertEqual(r.crashCount, 3, "incrementBackoff() must not clobber crashCount")
    }
}
