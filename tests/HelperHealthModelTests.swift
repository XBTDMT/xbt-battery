import XCTest
import Shared
@testable import Battery

/// 5.3: the helper-health model re-reads the live registration status on popover-open (so a post-launch
/// approval clears the "approve" nag), while preserving a hard verdict a raw status read can't re-derive.
@MainActor
final class HelperHealthModelTests: XCTestCase {

    private final class StubDaemon: DaemonService {
        var statusValue: DaemonServiceStatus
        init(_ s: DaemonServiceStatus) { statusValue = s }
        func register() throws {}
        func unregister() throws {}
    }

    // refresh() adopts the live status — a granted approval (requiresApproval → enabled) clears the nag.
    func testRefreshAdoptsLiveApproval() {
        let model = HelperHealthModel(service: StubDaemon(.enabled), launchVerdict: .requiresApproval)
        model.refresh()
        XCTAssertEqual(model.registration, .enabled)
    }

    // .signatureMismatch is STICKY — a raw status read (which looks fine) must not clear a signing verdict.
    func testSignatureMismatchIsPreserved() {
        let model = HelperHealthModel(service: StubDaemon(.enabled), launchVerdict: .signatureMismatch)
        model.refresh()
        XCTAssertEqual(model.registration, .signatureMismatch)
    }

    // .needsManualReset is likewise sticky (needs sfltool + reboot, not a re-read).
    func testNeedsManualResetIsPreserved() {
        let model = HelperHealthModel(service: StubDaemon(.enabled), launchVerdict: .needsManualReset)
        model.refresh()
        XCTAssertEqual(model.registration, .needsManualReset)
    }

    // DEGRADE direction (the safety-relevant one): a previously-enabled helper that is later
    // de-registered / un-approved must surface — refresh() adopts the worsened live status (.enabled is
    // NOT sticky). Guards against a regression that adds .enabled to the sticky early-return set.
    func testEnabledDegradesWhenLiveStatusWorsens() {
        let model = HelperHealthModel(service: StubDaemon(.notRegistered), launchVerdict: .enabled)
        model.refresh()
        XCTAssertEqual(model.registration, .notRegistered,
                       "a healthy launch verdict must adopt a worsened live status so the nag surfaces")
    }
}

// MARK: - B4: telling the three helper failure states apart
//
// The recorded defect: the app held TWO signals (SMAppService registration + the XPC reachability
// latch) and rendered a single sentence — "Energy helper isn't responding right now" — for every one
// of them. "Not approved", "approved but silent" and "answering from a stale binary" are three
// different problems with three different fixes, and the middle one is this project's most expensive
// recurring dev-loop failure (00-CURRENT.md's gotcha, proven on-device 2026-07-05 and 2026-07-17).
//
// These tests drive the PURE derivation + copy. The live probe (sysctl + a stat of the bundled helper)
// is seamed behind `HelperDaemonProbing`, so nothing here reads the real machine.
@MainActor
final class HelperStalenessTests: XCTestCase {

    private final class StubDaemon: DaemonService {
        var statusValue: DaemonServiceStatus
        init(_ s: DaemonServiceStatus) { statusValue = s }
        func register() throws {}
        func unregister() throws {}
    }

    private struct StubProbe: HelperDaemonProbing {
        var image: HelperDaemonImage
        func read() -> HelperDaemonImage { image }
    }

    private let built = Date(timeIntervalSince1970: 1_788_850_699)   // helper binary rewritten
    private let older = Date(timeIntervalSince1970: 1_788_467_534)   // daemon started BEFORE that
    private let newer = Date(timeIntervalSince1970: 1_788_900_000)   // daemon started AFTER that

    private func image(start: Date?, built: Date?) -> HelperDaemonImage {
        HelperDaemonImage(daemonStartedAt: start, bundledBuiltAt: built)
    }

    // MARK: staleness — the comparison itself

    // The live case on this machine at the time of writing: the daemon has been up since Sep 3 and the
    // helper binary it was launched from was rewritten Sep 7. It is executing an image that no longer
    // exists on disk, so the app's XPC peer-signature pin can never validate it again.
    func testDaemonOlderThanTheBundledBinaryIsStale() {
        XCTAssertTrue(HelperHealthModel.isStale(image(start: older, built: built)))
    }

    func testDaemonStartedAfterTheBuildIsNotStale() {
        XCTAssertFalse(HelperHealthModel.isStale(image(start: newer, built: built)))
    }

    // Absence of evidence is not evidence of staleness. No daemon running, or an unreadable binary,
    // must answer "no" — inventing a maybe here would put a scary command in front of the owner for a
    // state the app never actually observed.
    func testUnknownDatesAreNeverStale() {
        XCTAssertFalse(HelperHealthModel.isStale(image(start: nil, built: built)))
        XCTAssertFalse(HelperHealthModel.isStale(image(start: older, built: nil)))
        XCTAssertFalse(HelperHealthModel.isStale(image(start: nil, built: nil)))
    }

    // MARK: the verdict — three failure states, distinguishable

    // (1) Registration outranks everything: an unapproved helper is not "not responding", and telling
    // the owner to kickstart a daemon that was never approved sends him to the wrong place entirely.
    func testRegistrationProblemOutranksReachabilityAndStaleness() {
        let v = HelperHealthModel.verdict(registration: .requiresApproval, unreachable: true,
                                          hasResponded: false, image: image(start: older, built: built))
        XCTAssertEqual(v, .registrationProblem(.requiresApproval))
    }

    // (2) The headline: registered + approved + silent, split by whether the running image explains it.
    func testUnreachableSplitsOnStaleness() {
        XCTAssertEqual(HelperHealthModel.verdict(registration: .enabled, unreachable: true,
                                                 hasResponded: false, image: image(start: older, built: built)),
                       .unreachableStale)
        XCTAssertEqual(HelperHealthModel.verdict(registration: .enabled, unreachable: true,
                                                 hasResponded: true, image: image(start: newer, built: built)),
                       .unreachable)
    }

    // (3) Answering AND stale is reachable in its own right — a daemon registered from a different
    // bundle copy (the LaunchServices duplicate-bundle trap this repo already documents) validates its
    // own on-disk image happily while serving code older than the app that is talking to it.
    func testRespondingHelperCanStillBeStale() {
        XCTAssertEqual(HelperHealthModel.verdict(registration: .enabled, unreachable: false,
                                                 hasResponded: true, image: image(start: older, built: built)),
                       .stale)
    }

    // The positive state must be EARNED. Silence is not health: a helper nothing has ever called looks
    // exactly like a healthy one through the reachability latch alone, which is half of what B4 records.
    func testHealthyRequiresEvidenceOfAReply() {
        let current = image(start: newer, built: built)
        XCTAssertEqual(HelperHealthModel.verdict(registration: .enabled, unreachable: false,
                                                 hasResponded: false, image: current),
                       .notYetContacted)
        XCTAssertEqual(HelperHealthModel.verdict(registration: .enabled, unreachable: false,
                                                 hasResponded: true, image: current),
                       .responding)
    }

    // MARK: copy — every state says what it is, and the stale ones say what to run

    func testEveryVerdictSaysSomething() {
        let all: [HelperHealthVerdict] = [.registrationProblem(.requiresApproval), .unreachableStale,
                                          .unreachable, .stale, .responding, .notYetContacted]
        for v in all {
            XCTAssertFalse(HelperHealthCopy.note(for: v, lastReply: nil).text.isEmpty,
                           "\(v) must render a sentence, never an empty line")
        }
    }

    // The remediation for staleness is a command the owner can run — the same one relaunch-app.sh
    // prints — and it names the REAL Mach service, so it cannot rot away from the identity it bounces.
    func testStaleVerdictsCarryTheKickstartCommand() {
        for v in [HelperHealthVerdict.unreachableStale, .stale] {
            let remedy = HelperHealthCopy.note(for: v, lastReply: nil).remedy
            XCTAssertEqual(remedy, "sudo launchctl kickstart -k system/com.example.batteryapp.energyhelper",
                           "\(v) must hand over the exact command")
            XCTAssertTrue(remedy?.contains(BatteryAppIDs.machService) == true)
        }
    }

    // The three failure sentences must not be interchangeable — that identity IS the defect.
    func testTheThreeFailureStatesReadDifferently() {
        let texts = [HelperHealthVerdict.registrationProblem(.requiresApproval), .unreachableStale, .unreachable, .stale]
            .map { HelperHealthCopy.note(for: $0, lastReply: nil).text }
        XCTAssertEqual(Set(texts).count, texts.count, "each state needs its own sentence")
    }

    // The positive state keeps the surface added earlier today: the helper's OWN reply text, which is
    // the one identity check available over a protocol that carries no version.
    func testRespondingQuotesTheHelpersOwnReply() {
        XCTAssertTrue(HelperHealthCopy.note(for: .responding, lastReply: "pong").text.contains("pong"))
        XCTAssertFalse(HelperHealthCopy.note(for: .responding, lastReply: nil).text.contains("—"))
    }

    // Attention states are orange; the calm ones are not. A stale helper is actionable, so it is orange
    // even while it is answering.
    func testTintsMatchActionability() {
        XCTAssertEqual(HelperHealthCopy.note(for: .unreachableStale, lastReply: nil).tint, .attention)
        XCTAssertEqual(HelperHealthCopy.note(for: .stale, lastReply: nil).tint, .attention)
        XCTAssertEqual(HelperHealthCopy.note(for: .unreachable, lastReply: nil).tint, .attention)
        XCTAssertEqual(HelperHealthCopy.note(for: .responding, lastReply: "pong").tint, .neutral)
        XCTAssertEqual(HelperHealthCopy.note(for: .notYetContacted, lastReply: nil).tint, .neutral)
    }

    // MARK: the observed-daemon detail line

    func testDaemonDetailNamesWhatWasObserved() {
        let fmt: (Date) -> String = { _ in "3 Sep at 13:32" }
        XCTAssertEqual(HelperHealthCopy.daemonDetail(image(start: older, built: built), formatted: fmt),
                       "Running helper started 3 Sep at 13:32; this app’s helper was built 3 Sep at 13:32.")
        XCTAssertEqual(HelperHealthCopy.daemonDetail(image(start: nil, built: built), formatted: fmt),
                       "No helper process is running right now — macOS starts it on the next request.")
        XCTAssertNil(HelperHealthCopy.daemonDetail(image(start: older, built: nil), formatted: fmt),
                     "with nothing to compare against, say nothing rather than half a comparison")
    }

    // MARK: the model composes the two signals with the probe

    func testRefreshAdoptsTheProbedImage() {
        let probe = StubProbe(image: image(start: older, built: built))
        let model = HelperHealthModel(service: StubDaemon(.enabled), launchVerdict: .enabled, probe: probe)
        model.refresh()
        XCTAssertEqual(model.daemonImage, image(start: older, built: built))
        XCTAssertEqual(model.verdict(unreachable: true, hasResponded: false), .unreachableStale)
    }

    // The sticky-verdict early return guarded a REGISTRATION re-read; it must not also skip the image
    // probe, or a signature-mismatch build would go permanently blind to the daemon it is talking to.
    func testStickyRegistrationVerdictStillRefreshesTheImage() {
        let probe = StubProbe(image: image(start: older, built: built))
        let model = HelperHealthModel(service: StubDaemon(.enabled), launchVerdict: .signatureMismatch, probe: probe)
        model.refresh()
        XCTAssertEqual(model.registration, .signatureMismatch, "the sticky verdict still stands")
        XCTAssertEqual(model.daemonImage.daemonStartedAt, older, "…and the image was still read")
    }
}
