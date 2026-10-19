import XCTest

/// The #29 C1 regression gate, wired into the suite the way `SMCDeadGateTests` wires the SMC-DEAD gate.
///
/// WHY A TEST IS THE RIGHT HOST. The bug this guards against is *a shipped, unit-tested feature with no
/// screen*. `44cfb79` deleted the call site; `f2f1eaa` excised the now-unreferenced builders; the suite
/// stayed green the whole way, because a test asserting a string is PRODUCED passes happily while
/// nothing RENDERS it. Swift offers no help: the compiler does not warn on an unused `internal`
/// declaration. So the check has to be an explicit one, and it has to run where the deletions land.
///
/// WHAT IS ENFORCING TODAY, precisely:
///   * a NEW orphan fails the suite (the allowlist is a baseline ratchet, not an open door);
///   * a STALE allowlist entry — one that has since gained a reader — also fails, so the file cannot
///     rot into permanent amnesty: fixing an orphan forces its line out;
///   * the gate has TEETH, proven against a synthesized orphan rather than assumed.
///
/// WHAT IS NOT COVERED, stated plainly: short and common identifiers (`soc`, `note`) are not swept at
/// all — a bare word-boundary match on them is meaningless. Both were real #29 casualties. The script
/// prints every such declaration under UNSWEPT rather than counting them as clear.
final class UIOrphanGateTests: XCTestCase {

    /// tests/UIOrphanGateTests.swift → repo root is two directories up.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private var gateScript: URL { repoRoot.appendingPathComponent("scripts/ui-orphan-gate.sh") }
    private var allowlist: URL { repoRoot.appendingPathComponent("scripts/ui-orphan-allowlist.txt") }
    private var appDir: URL { repoRoot.appendingPathComponent("app") }

    private func runGate(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [gateScript.path] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "spawn failed: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testGateScriptAndAllowlistExist() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: gateScript.path),
                      "scripts/ui-orphan-gate.sh must exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: allowlist.path),
                      "scripts/ui-orphan-allowlist.txt must exist (an absent allowlist is not a clean tree)")
    }

    /// The ratchet: the real tree must have no orphan that is not on the allowlist, and no allowlist
    /// entry that has since gained a reader.
    func testGatePassesOnTheRealTree() {
        let r = runGate([appDir.path, allowlist.path])
        XCTAssertEqual(r.status, 0, """
            The UI-orphan gate failed. Either a UI-facing declaration lost its last reader (re-home it, \
            delete it, or allowlist it WITH a reason), or an allowlist entry is now live and its line \
            must be deleted.
            \(r.output)
            """)
    }

    /// TEETH — the analogue of `testMembershipGateHasTeeth`. A synthesized app tree with one obviously
    /// orphaned `@Published` must FAIL. Guards against a regression that neuters the sweep (a broken
    /// regex, an over-broad "too common" list) and leaves a gate that passes because it checks nothing.
    func testGateHasTeethOnASynthesizedOrphan() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ui-orphan-teeth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        import Combine
        @MainActor final class WidgetModel: ObservableObject {
            @Published private(set) var widgetGuidance: String?
            func update() { widgetGuidance = "something the user should have been told" }
        }
        """.write(to: dir.appendingPathComponent("WidgetModel.swift"), atomically: true, encoding: .utf8)
        // A second file that reads something ELSE, so the tree is not trivially empty.
        try """
        import SwiftUI
        struct WidgetView: View { var body: some View { Text("hi") } }
        """.write(to: dir.appendingPathComponent("WidgetView.swift"), atomically: true, encoding: .utf8)

        let empty = dir.appendingPathComponent("empty-allowlist.txt")
        try "".write(to: empty, atomically: true, encoding: .utf8)

        let r = runGate([dir.path, empty.path])
        XCTAssertNotEqual(r.status, 0, "the gate must FAIL on an unread @Published.\n\(r.output)")
        XCTAssertTrue(r.output.contains("widgetGuidance"), "it must NAME the orphan.\n\(r.output)")
    }

    /// The allowlist must actually suppress — otherwise the ratchet is unusable and someone will delete
    /// the gate rather than the noise.
    func testAllowlistSuppressesAKnownOrphan() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ui-orphan-allow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        import Combine
        @MainActor final class WidgetModel: ObservableObject {
            @Published private(set) var widgetGuidance: String?
            func update() { widgetGuidance = "x" }
        }
        """.write(to: dir.appendingPathComponent("WidgetModel.swift"), atomically: true, encoding: .utf8)

        let allow = dir.appendingPathComponent("allow.txt")
        try "widgetGuidance   # REAL-ORPHAN: parked\n".write(to: allow, atomically: true, encoding: .utf8)

        let r = runGate([dir.path, allow.path])
        XCTAssertEqual(r.status, 0, "an allowlisted orphan must not fail the gate.\n\(r.output)")
    }

    /// ANTI-ROT — the property that separates this from a suppression file. An allowlist entry for a
    /// symbol that is NOW read must FAIL, forcing the line to be deleted. Without this the allowlist
    /// only ever grows and the gate quietly stops meaning anything.
    func testStaleAllowlistEntryFailsTheGate() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ui-orphan-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        import Combine
        @MainActor final class WidgetModel: ObservableObject {
            @Published private(set) var widgetGuidance: String?
        }
        """.write(to: dir.appendingPathComponent("WidgetModel.swift"), atomically: true, encoding: .utf8)
        // …and here is the reader that makes the allowlist entry stale.
        try """
        import SwiftUI
        struct WidgetView: View {
            @ObservedObject var model: WidgetModel
            var body: some View { Text(model.widgetGuidance ?? "") }
        }
        """.write(to: dir.appendingPathComponent("WidgetView.swift"), atomically: true, encoding: .utf8)

        let allow = dir.appendingPathComponent("allow.txt")
        try "widgetGuidance   # stale: this symbol has a reader now\n"
            .write(to: allow, atomically: true, encoding: .utf8)

        let r = runGate([dir.path, allow.path])
        XCTAssertNotEqual(r.status, 0, "a stale allowlist entry must FAIL the gate.\n\(r.output)")
        XCTAssertTrue(r.output.contains("STALE"), "it must say WHY.\n\(r.output)")
    }

    /// The coverage disclosure is part of the contract, not a nicety: a gate that silently skips
    /// `soc` and `note` manufactures confidence it has not earned.
    func testGateDisclosesItsUnsweptNames() {
        let r = runGate(["--list", appDir.path, allowlist.path])
        XCTAssertTrue(r.output.contains("UNSWEPT"),
                      "the gate must print what it declined to sweep.\n\(r.output)")
        XCTAssertTrue(r.output.contains("soc"),
                      "`soc` is the canonical unswept case and must be named.\n\(r.output)")
    }

    /// Every allowlist line must carry a reason. An entry with no `#` comment is an unexplained
    /// suppression, which is how a ratchet becomes a dumping ground.
    func testEveryAllowlistEntryCarriesAReason() throws {
        let text = try String(contentsOf: allowlist, encoding: .utf8)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            XCTAssertTrue(line.contains("#"), "allowlist entry without a reason: \(line)")
        }
    }
}

// =================================================================================================

/// The **authoring-time** half of the #29 C1 guard: `scripts/ui-orphan-diff-gate.sh`.
///
/// WHY A SECOND CLASS AND NOT MORE CASES ABOVE. `UIOrphanGateTests` guards a property of the TREE
/// ("nothing is dark right now"). This guards a property of a COMMIT ("this change did not leave
/// anything dark without saying so"). They fail for different reasons and are fixed by different
/// people at different times, so they are kept apart.
///
/// WHY THIS ONE MATTERS MORE. The tree gate found #29's casualties in September; the commits that
/// created them landed in July. §2.C of the audit names the diff rule as the higher-signal half —
/// *"that is the check that would have caught `f2f1eaa` at authoring time"* — and
/// `testItWouldHaveCaughtTheCommitsThatStartedThisWorkstream` is that claim, executed against the
/// real history rather than asserted. It is the acceptance criterion for the whole workstream.
///
/// ONE HEURISTIC, NOT TWO. The diff gate does not define "UI-facing" itself; it drives
/// `ui-orphan-gate.sh --inventory` over the before/after trees and diffs the verdicts. A second,
/// subtly different definition would be worse than one — the sibling gate already carries a fix
/// (`cdceb58`) for a name-extraction defect a re-implementation would have been free to reinvent.
///
/// WHAT IS NOT COVERED, stated plainly: every blind spot of the tree gate (short names, `private`
/// declarations, app/ only), plus this gate's own — a symbol read only from its own file reads as
/// orphaned in BOTH trees and can never fire; a symbol already dark before the range is invisible;
/// merges are skipped; and a declaration born with no reader is reported but deliberately does NOT
/// fail, because a micro-commit-per-stage workflow creates those legitimately. The script prints all
/// of this under COVERAGE on every run, and `testDiffGateDisclosesItsBlindSpots` holds it to that.
final class UIOrphanDiffGateTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private var diffGate: URL { repoRoot.appendingPathComponent("scripts/ui-orphan-diff-gate.sh") }

    @discardableResult
    private func run(_ exe: String, _ args: [String], cwd: URL? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "spawn failed: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func gate(_ args: [String]) -> (status: Int32, output: String) {
        run("/bin/bash", [diffGate.path] + args)
    }

    /// Exit 2 means the range could not be resolved at all (shallow clone, detached history, no git).
    /// That is an environment fact, not a verdict — skip rather than manufacture a failure.
    private func skipIfUnresolvable(_ r: (status: Int32, output: String)) throws {
        if r.status == 2 { throw XCTSkip("range not resolvable in this checkout:\n\(r.output)") }
    }

    func testDiffGateScriptExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: diffGate.path),
                      "scripts/ui-orphan-diff-gate.sh must exist")
    }

    // MARK: - the acceptance criterion

    /// **The reason this workstream exists.** `44cfb79` deleted the Details tail that was the only
    /// call site for the relocated builders; `f2f1eaa` then excised what looked unreferenced. Both
    /// commits must FAIL this gate, and must NAME casualties the audit independently identified in
    /// §2.C — otherwise the gate is firing on something, but not on the thing it was built for.
    func testItWouldHaveCaughtTheCommitsThatStartedThisWorkstream() throws {
        // `44cfb79` — the commit that actually removed the readers. Its casualties are, verbatim, the
        // audit's "the entire charge-control honesty layer is dark" list.
        let tail = gate(["44cfb79"])
        try skipIfUnresolvable(tail)
        XCTAssertNotEqual(tail.status, 0, "44cfb79 must FAIL the diff gate.\n\(tail.output)")
        for casualty in ["engineNote", "syncProblem", "pauseCaveat", "telemetryReadFailed",
                         "verdictWasDegraded", "transientConfirmation", "statusPrefix",
                         "commandLabel", "limitProvenanceTag", "limitReadProblemLabel"] {
            XCTAssertTrue(tail.output.contains(casualty),
                          "44cfb79 orphaned \(casualty) (audit §2.C) and the gate must name it.\n\(tail.output)")
        }

        // `f2f1eaa` — the excise-gate commit the audit calls out by name. Its own deletions cascaded
        // onto the lifetime sub-stats and the `spUnavailable` cue, both named in §2.C's cheapest-win
        // subset. Deleting a builder is allowed; silently orphaning what it was reading is not.
        let excise = gate(["f2f1eaa"])
        try skipIfUnresolvable(excise)
        XCTAssertNotEqual(excise.status, 0, "f2f1eaa must FAIL the diff gate.\n\(excise.output)")
        for casualty in ["spUnavailable", "lifetimeTemperatureText",
                         "lifetimePeakCurrentText", "lifetimeVoltageRangeText"] {
            XCTAssertTrue(excise.output.contains(casualty),
                          "f2f1eaa orphaned \(casualty) (audit §2.C) and the gate must name it.\n\(excise.output)")
        }
    }

    /// The ratchet, pointed at the commit you just wrote — the analogue of the tree gate's
    /// `testGatePassesOnTheRealTree`.
    func testTheCommitJustWrittenLeftNothingDark() throws {
        let r = gate(["HEAD~1..HEAD"])
        try skipIfUnresolvable(r)
        XCTAssertEqual(r.status, 0, """
            The last commit removed a UI-facing symbol's last reader without deleting the symbol or \
            declaring it. Re-home it, delete it, or add to the commit message: \
            `Re-homed: <Symbol> -> <where it is read now, or why it is deliberately dark>`.
            \(r.output)
            """)
    }

    // MARK: - teeth, on synthesized history

    /// Builds a throwaway repo whose HEAD commit removes `widgetGuidance`'s only cross-file reader.
    /// `deletingModel` also removes the declaration; `message` is the commit message.
    private func synthesize(
        deletingModel: Bool = false, message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (status: Int32, output: String) {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else {
            throw XCTSkip("git not available at \(git)")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ui-orphan-diff-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let model = app.appendingPathComponent("Model.swift")
        let view = app.appendingPathComponent("View.swift")
        try """
        import Combine
        @MainActor final class WidgetModel: ObservableObject {
            @Published private(set) var widgetGuidance: String?
        }
        """.write(to: model, atomically: true, encoding: .utf8)
        // BEFORE: a genuine cross-file reader, so the symbol starts LIVE. Without this the gate would
        // see "orphaned in both trees" and correctly stay silent, and the test would prove nothing.
        try """
        import SwiftUI
        struct WidgetView: View {
            @ObservedObject var model: WidgetModel
            var body: some View { Text(model.widgetGuidance ?? "") }
        }
        """.write(to: view, atomically: true, encoding: .utf8)

        run(git, ["init", "-q", "."], cwd: dir)
        run(git, ["config", "user.email", "gate@test.local"], cwd: dir)
        run(git, ["config", "user.name", "gate"], cwd: dir)
        run(git, ["add", "-A"], cwd: dir)
        run(git, ["commit", "-q", "-m", "base: the symbol has a reader"], cwd: dir)

        // AFTER: the reader is gone.
        try """
        import SwiftUI
        struct WidgetView: View { var body: some View { Text("hi") } }
        """.write(to: view, atomically: true, encoding: .utf8)
        if deletingModel { try FileManager.default.removeItem(at: model) }
        run(git, ["add", "-A"], cwd: dir)
        let commit = run(git, ["commit", "-q", "-m", message], cwd: dir)
        XCTAssertEqual(commit.status, 0, "synthesized commit failed: \(commit.output)", file: file, line: line)

        return gate(["--repo", dir.path, "--allowlist", "/dev/null", "HEAD"])
    }

    /// TEETH. Removing the last reader while keeping the symbol, and saying nothing, must FAIL.
    /// Guards against a regression that neuters the diff (an inventory format change, a broken status
    /// comparison) and leaves a gate that passes because it compares nothing.
    func testUndeclaredOrphaningFails() throws {
        let r = try synthesize(message: "remove the call site, say nothing")
        XCTAssertNotEqual(r.status, 0, "orphaning a symbol silently must FAIL.\n\(r.output)")
        XCTAssertTrue(r.output.contains("widgetGuidance"), "it must NAME the symbol.\n\(r.output)")
    }

    /// The escape hatch has to actually work, or it is not a gate, it is a wall — and someone will
    /// delete it rather than route around it.
    func testReHomedManifestClearsIt() throws {
        let r = try synthesize(message: """
            remove the call site

            Re-homed: widgetGuidance -> parked for D-6, no screen yet, owner ruling pending
            """)
        XCTAssertEqual(r.status, 0, "a declared symbol must PASS.\n\(r.output)")
        XCTAssertTrue(r.output.contains("declared Re-homed:"), "it must say WHY it passed.\n\(r.output)")
    }

    /// The `-> destination` half is the whole value of the manifest. A bare name would let an author
    /// clear a real orphan by typing it, which is a rubber stamp, not a decision. Being made to write
    /// where it went is the moment you find out whether it went anywhere.
    func testBareNameWithoutADestinationDoesNotClearIt() throws {
        let r = try synthesize(message: """
            remove the call site

            Re-homed: widgetGuidance
            """)
        XCTAssertNotEqual(r.status, 0, "a bare name with no destination must NOT clear.\n\(r.output)")
    }

    /// Deleting the symbol along with its reader is the OTHER correct answer, and must be silent.
    /// If this failed, every legitimate feature removal would need a manifest line and the gate would
    /// be turned off within a week.
    func testDeletingTheSymbolTooPasses() throws {
        let r = try synthesize(deletingModel: true, message: "delete the reader AND the symbol")
        XCTAssertEqual(r.status, 0, "deleting the symbol too must PASS.\n\(r.output)")
    }

    /// The coverage disclosure is part of the contract, exactly as it is for the tree gate. A diff
    /// check that does not say it is blind to same-file readers and to already-dark symbols invites
    /// the reader to believe a green run means more than it does.
    func testDiffGateDisclosesItsBlindSpots() throws {
        let r = gate(["--list", "HEAD~1..HEAD"])
        try skipIfUnresolvable(r)
        XCTAssertTrue(r.output.contains("COVERAGE"), "the gate must disclose its blind spots.\n\(r.output)")
        XCTAssertTrue(r.output.contains("own file"),
                      "the same-file-reader blind spot must be named.\n\(r.output)")
        XCTAssertTrue(r.output.contains("TRANSITIONS only"),
                      "it must say it catches transitions, not state.\n\(r.output)")
    }
}
