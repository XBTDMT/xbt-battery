import XCTest
import Darwin
@preconcurrency import Shared
// helper/XPC/EnergyHelperService.swift compiles into this target → spawnAndCapture visible.

/// Sprint 3.7 fix A3 (Grok hardening) — the BOUNDED, ISOLATED child spawn that backs the helper's
/// privileged ops. Proves: (a) bounded lifecycle (timeout → kill → REAP, no zombie) in every exit path;
/// (c) spawn isolation (controlled cwd, REPLACED env, stdin → /dev/null); and the (b) cooldown decision.
/// These run host-app-free against benign system binaries (no root needed).
final class EnergyHelperSpawnTests: XCTestCase {

    /// A second waitpid after spawnAndCapture already reaped → -1 / ECHILD. Proves NO zombie is left.
    private func wasReaped(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        return r == -1 && errno == ECHILD
    }

    // MARK: - (a) bounded lifecycle + (c) capture

    func testSpawn_success_capturesStdout_andReaps() {
        let res = EnergyHelperService.spawnAndCapture(["/bin/echo", "hello"], timeout: 5)
        XCTAssertFalse(res.timedOut)
        XCTAssertEqual(res.data.flatMap { String(data: $0, encoding: .utf8) }, "hello\n")
        XCTAssertTrue(wasReaped(res.pid), "the child must be waitpid-reaped (no zombie)")
    }

    func testSpawn_nonzeroExit_returnsNil_andReaps() {
        let res = EnergyHelperService.spawnAndCapture(["/usr/bin/false"], timeout: 5)
        XCTAssertFalse(res.timedOut)
        XCTAssertNil(res.data, "a non-zero exit yields nil (never partial output as success)")
        XCTAssertTrue(wasReaped(res.pid))
    }

    func testSpawn_timeout_killsAndReaps_returnsNil_fast() {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let res = EnergyHelperService.spawnAndCapture(["/bin/sleep", "30"], timeout: 0.4)
        let elapsedS = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9
        XCTAssertTrue(res.timedOut, "the 30s sleep must hit the 0.4s timeout")
        XCTAssertNil(res.data)
        XCTAssertTrue(wasReaped(res.pid), "a timed-out child must still be reaped (no orphan/zombie)")
        XCTAssertLessThan(elapsedS, 5.0, "the watchdog killed it well before the 30s sleep would end")
    }

    // MARK: - (c) spawn isolation

    func testSpawn_cwdIsControlled_varTmp() {
        let res = EnergyHelperService.spawnAndCapture(["/bin/pwd"], timeout: 5)
        let out = res.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(out.contains("var/tmp"), "child cwd is the controlled /var/tmp (got \(out))")
    }

    func testSpawn_envIsReplacedNotMerged() {
        setenv("DYLD_TEST_LEAK", "1", 1)                 // a var in the PARENT (test) env
        defer { unsetenv("DYLD_TEST_LEAK") }
        let res = EnergyHelperService.spawnAndCapture(["/usr/bin/env"], timeout: 5)
        let out = res.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(out.contains("DYLD_TEST_LEAK"), "the parent env is REPLACED, not merged — no DYLD_* leaks")
        XCTAssertTrue(out.contains("HOME=/var/empty"), "the sanitized HOME is present (proves the replacement env was used)")
    }

    func testSpawn_stdinIsDevNull_catDoesNotHang() {
        // /bin/cat reads stdin; with stdin → /dev/null it gets immediate EOF and exits 0 with no output.
        // If stdin were left inheriting an open fd this could hang → the timeout would trip (timedOut).
        let res = EnergyHelperService.spawnAndCapture(["/bin/cat"], timeout: 3)
        XCTAssertFalse(res.timedOut, "stdin is /dev/null → cat hits EOF immediately, never hangs")
        XCTAssertEqual(res.data, Data(), "no stdin content → empty stdout")
    }

    // MARK: - (b) sampling cooldown decision (pure)

    func testSampleThrottled_firstSampleAllowed_withinWindowThrottled_afterWindowAllowed() {
        let cd: UInt64 = 750_000_000   // 750 ms in ns
        XCTAssertFalse(EnergyHelperService.sampleThrottled(nowNs: 1_000, lastStartNs: 0, cooldownNs: cd),
                       "never-sampled (last == 0) → allowed")
        XCTAssertTrue(EnergyHelperService.sampleThrottled(nowNs: 100_000_000, lastStartNs: 1, cooldownNs: cd),
                      "100 ms after the last start → within 750 ms cooldown → throttled")
        XCTAssertFalse(EnergyHelperService.sampleThrottled(nowNs: 800_000_000, lastStartNs: 1, cooldownNs: cd),
                       "800 ms after the last start → past the 750 ms cooldown → allowed")
    }
}
