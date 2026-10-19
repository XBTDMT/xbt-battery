import XCTest
@preconcurrency import Shared

/// Sprint 3.7 STAGE 2 — INTEGRATION half of the PROOF GATE (both deliverables, end-to-end, in-process):
///   (1) a no-op `ping` ROUND-TRIPS over a real NSXPC channel whose listener is pinned to a peer the
///       client satisfies; and
///   (2) a NON-MATCHING peer is REJECTED by the SAME audit-token-backed listener pin
///       (`setConnectionCodeSigningRequirement`) the production helper uses — `ping` never returns; the
///       connection's error/invalidation handler fires instead.
///
/// This exercises the exact mechanism `helper/main.swift` sets before `resume()`, on a real
/// `NSXPCListener.anonymous()` + `NSXPCConnection`, using the production `EnergyHelperListenerDelegate`.
/// It needs no installed daemon and no approval, so it runs in CI.
final class XPCChannelTests: XCTestCase {

    /// tests/XPCChannelTests.swift → repo root is two directories up.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// sec 6 registration PREFLIGHT, proven on the REAL signed binary: the built energy helper must
    /// satisfy the codified helper DR (identifier + Apple anchor + the build's Team ID + min-version), and
    /// a wrong-team DR must reject it. This is "the DR validated against the SMAppService registration."
    /// The Team ID is the one the build was configured with — the helper's in-binary Info.plist `TeamID`
    /// (`$(DEVELOPMENT_TEAM)` from Signing.xcconfig), the same key the app and helper read at runtime — so
    /// the proof holds for whichever team signs the build, not one hard-coded team.
    func testBuiltHelperBinarySatisfiesCodifiedDR() throws {
        let bin = repoRoot.appendingPathComponent("build/sym/Debug/com.example.batteryapp.energyhelper").path
        guard FileManager.default.fileExists(atPath: bin) else {
            throw XCTSkip("no built energy-helper binary at build/sym/Debug — build first")
        }
        let info = CFBundleCopyInfoDictionaryForURL(URL(fileURLWithPath: bin) as CFURL) as? [String: Any]
        guard let team = info?["TeamID"] as? String, !team.isEmpty, !team.hasPrefix("$(") else {
            throw XCTSkip("the built helper's Info.plist carries no TeamID (DEVELOPMENT_TEAM is empty in "
                          + "Signing.xcconfig): its designated requirement needs a team-signed build")
        }
        XCTAssertTrue(BatteryAppIDs.staticCodeSatisfies(path: bin,
                        requirement: BatteryAppIDs.helperRequirement(teamID: team)),
                      "the built helper must satisfy its codified DR for team \(team) (the registration preflight)")
        XCTAssertFalse(BatteryAppIDs.staticCodeSatisfies(path: bin,
                        requirement: BatteryAppIDs.helperRequirement(teamID: "BOGUS00000")),
                       "a wrong-team DR must REJECT the built helper (preflight has teeth)")
    }

    func testPing_roundTrips_whenPeerSatisfiesTheListenerPin() throws {
        let selfDR = try selfDesignatedRequirement()
        let listener = NSXPCListener.anonymous()
        let delegate = EnergyHelperListenerDelegate(appRequirement: selfDR)
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(selfDR)   // peer == this process → ACCEPT
        listener.resume()
        defer { listener.invalidate() }

        let conn = NSXPCConnection(listenerEndpoint: listener.endpoint)
        conn.remoteObjectInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
        conn.setCodeSigningRequirement(selfDR)                  // client pins the server too (both ends)
        conn.resume()
        defer { conn.invalidate() }

        let pong = expectation(description: "pong received")
        let proxy = conn.remoteObjectProxyWithErrorHandler { err in
            XCTFail("ping must not error when the peer satisfies the pin: \(err)")
        } as? EnergyHelperProtocol
        XCTAssertNotNil(proxy)
        proxy?.ping { reply in
            XCTAssertEqual(reply, "pong")
            pong.fulfill()
        }
        wait(for: [pong], timeout: 5)
    }

    /// STAGE 3: the privileged op VALIDATES over the real channel and rejects out-of-set input with an
    /// error token — WITHOUT spawning pmset (the reject happens before any command is constructed). Safe
    /// in CI (non-root, no system change). The valid SET path is owner-validated (needs root).
    func testSetEnergyMode_rejectsOutOfSetMode_overXPC_noSpawn() throws {
        try withAcceptedChannel { proxy, done in
            proxy.setEnergyMode(mode: 99, source: 0) { token in
                XCTAssertEqual(token, EnergyModeCommand.errInvalidMode,
                               "an out-of-set mode must be rejected over XPC (no spawn)")
                done()
            }
        }
    }

    func testSetEnergyMode_rejectsOutOfSetSource_overXPC_noSpawn() throws {
        try withAcceptedChannel { proxy, done in
            proxy.setEnergyMode(mode: 0, source: 7) { token in
                XCTAssertEqual(token, EnergyModeCommand.errInvalidSource,
                               "an out-of-set source must be rejected over XPC (no spawn)")
                done()
            }
        }
    }

    /// STAGE 4: collectTaskEnergy RANGE-CHECKS over the real channel and rejects out-of-range with an
    /// error token — WITHOUT spawning powermetrics (which needs root anyway). Safe in CI.
    func testCollectTaskEnergy_rejectsOutOfRangeSamples_overXPC_noSpawn() throws {
        try withAcceptedChannel { proxy, done in
            proxy.collectTaskEnergy(samples: 99, intervalMs: 1000) { data, token in
                XCTAssertNil(data)
                XCTAssertEqual(token, TaskEnergyCommand.errInvalidSamples,
                               "out-of-range samples must be rejected over XPC (no spawn)")
                done()
            }
        }
    }

    func testCollectTaskEnergy_rejectsOutOfRangeInterval_overXPC_noSpawn() throws {
        try withAcceptedChannel { proxy, done in
            proxy.collectTaskEnergy(samples: 1, intervalMs: 50) { data, token in
                XCTAssertNil(data)
                XCTAssertEqual(token, TaskEnergyCommand.errInvalidInterval,
                               "out-of-range interval must be rejected over XPC (no spawn)")
                done()
            }
        }
    }

    /// Helper: stand up an anonymous listener pinned to (and connected from) THIS process, run `body`
    /// with a live proxy, and wait for `done()`.
    private func withAcceptedChannel(_ body: (EnergyHelperProtocol, @escaping () -> Void) -> Void) throws {
        let selfDR = try selfDesignatedRequirement()
        let listener = NSXPCListener.anonymous()
        let delegate = EnergyHelperListenerDelegate(appRequirement: selfDR)
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(selfDR)
        listener.resume(); defer { listener.invalidate() }

        let conn = NSXPCConnection(listenerEndpoint: listener.endpoint)
        conn.remoteObjectInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
        conn.setCodeSigningRequirement(selfDR)
        conn.resume(); defer { conn.invalidate() }

        let exp = expectation(description: "reply")
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ e in XCTFail("xpc error: \(e)") }) as? EnergyHelperProtocol else {
            return XCTFail("no proxy")
        }
        body(proxy, { exp.fulfill() })
        wait(for: [exp], timeout: 5)
    }

    func testConnection_isRejected_whenPeerFailsTheListenerPin() throws {
        // Pin the listener to an identity THIS process cannot satisfy → the audit-token-backed pin must
        // reject the connection before any message is delivered. This is the rejection deliverable.
        let bogusPin = "identifier \"com.bogus.nomatch.\(UUID().uuidString)\" and anchor apple generic"
        let selfDR = try selfDesignatedRequirement()   // for the delegate's per-connection pin (unused on reject)

        let listener = NSXPCListener.anonymous()
        let delegate = EnergyHelperListenerDelegate(appRequirement: selfDR)
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(bogusPin)   // peer (this process) does NOT match → REJECT
        listener.resume()
        defer { listener.invalidate() }

        let conn = NSXPCConnection(listenerEndpoint: listener.endpoint)
        conn.remoteObjectInterface = NSXPCInterface(with: EnergyHelperProtocol.self)

        let rejected = expectation(description: "connection rejected (error or invalidation fires)")
        rejected.assertForOverFulfill = false   // either handler may fire; first one proves rejection
        conn.invalidationHandler = { rejected.fulfill() }
        conn.interruptionHandler = { rejected.fulfill() }
        conn.resume()
        defer { conn.invalidate() }

        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
            rejected.fulfill()   // send failed → peer was rejected by the pin
        } as? EnergyHelperProtocol
        proxy?.ping { reply in
            XCTFail("ping MUST NOT succeed — a non-matching peer must be rejected by the audit-token pin (got \(reply))")
        }
        wait(for: [rejected], timeout: 5)
    }
}
