import Foundation
import Security
import Darwin

// Sprint 3.7 STAGE 2 — the CODIFIED designated requirement (DR) + the audit-token peer validator.
// SPEC sec 3/6: ONE place builds the DR (Apple anchor + Team ID + a specific bundle id + a min-version
// downgrade defense), used IDENTICALLY for the XPC `setCodeSigningRequirement` pin AND validated
// against the SMAppService registration — so the XPC requirement and the registration DR cannot drift.
// research-09: NEVER trust the PID (the PID-reuse TOCTOU CVE canon). Validate via the audit token.

public extension BatteryAppIDs {

    /// The codified minimum helper short-version for the DR's downgrade-defense clause.
    ///
    /// BUMP DISCIPLINE (SPEC sec 6): raise this in lockstep with the helper's `CFBundleShortVersionString`
    /// whenever a security-relevant helper change ships, so an older (potentially vulnerable) helper
    /// binary can no longer satisfy the pin. Because BOTH the XPC pin and the registration preflight
    /// read this one constant, they bump together and cannot drift.
    ///
    /// 0.1 → 0.2 (2026-10-15, security posture): the helper's client pin now refuses a debuggable /
    /// injectable app, so every 0.1 helper — which accepts one — is below the floor.
    ///
    /// COMPARISON IS NUMERIC, NOT LEXICOGRAPHIC (measured 2026-10-15 with `codesign -v -R` on ad-hoc
    /// bundles, macOS 27.2): `>= "0.10"` passes 0.10 and 1.0 and fails 0.2 and 0.9; `>= "0.2"` passes
    /// 0.10. So 0.9 → 0.10 is a safe bump. (An earlier note here claimed the opposite; it was never
    /// measured. `RequirementSemanticsTests` pins the measured behaviour.)
    static let minHelperShortVersion = "0.2"

    /// The codified minimum APP short-version — the client floor in the helper's peer pin. Before
    /// 2026-10-15 the app pin reused `minHelperShortVersion` ("0.1") against an app at "1.0", so it
    /// excluded nothing and every app build ever signed by the team was a valid client.
    ///
    /// 1.0 → 1.1 (2026-10-15, security posture): every 1.0 build was signed with
    /// `com.apple.security.get-task-allow` (Xcode injects it for Apple Development signing in Debug
    /// AND Release), so every one of them could be attached to and its audit token borrowed. 1.1 is
    /// the first build made with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. Bump this whenever a
    /// security-relevant APP change ships (anything that makes an older client unsafe to trust).
    static let minAppShortVersion = "1.1"

    /// Entitlements that let ANOTHER same-user process run code inside the signed client — and so use
    /// its genuine audit token to talk to the root helper. The helper's client pin refuses any app
    /// carrying one of them set to true (see `entitlementsAbsentClause`).
    ///   - get-task-allow: any debugger-capable process can attach (task port → run code in it).
    ///   - allow-dyld-environment-variables: `DYLD_INSERT_LIBRARIES` works under hardened runtime.
    ///   - disable-library-validation: a dylib signed by anyone (or no one) can be loaded into it.
    static let clientCodeInjectionEntitlements = [
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.disable-library-validation",
    ]

    /// `!(entitlement["k"] exists)` for each key, joined by `and`. Pure.
    ///
    /// Why this form (measured 2026-10-15, `codesign -v -R` on ad-hoc signed code, macOS 27.2):
    /// `entitlement["k"] exists` is TRUTHY for a boolean — true only when k = true, false when k is
    /// missing or k = false — so `!(entitlement["k"] exists)` accepts code without k or with k = false
    /// (both mean the capability is off) and refuses k = true. The alternatives are wrong:
    /// `entitlement["k"] = true` is a SYNTAX ERROR (no boolean literal; a pin that does not compile
    /// refuses every peer), and `entitlement["k"] absent` refuses an explicit false as well.
    /// `RequirementSemanticsTests` pins all three behaviours. A malformed key (empty, or containing a
    /// quote or backslash) is refused so the clause can never be broken into a different requirement.
    static func entitlementsAbsentClause(_ keys: [String]) -> String {
        keys.map { key -> String in
            precondition(!key.isEmpty && !key.contains("\"") && !key.contains("\\"),
                         "entitlementsAbsentClause: malformed entitlement key '\(key)'")
            return "!(entitlement[\"\(key)\"] exists)"
        }.joined(separator: " and ")
    }

    /// THE codified designated requirement string. Pure + deterministic (Team ID passed explicitly so
    /// it is unit-testable without a host app). The OU is quoted (a Team ID starting with a digit is
    /// still valid — the digit-trap), and an empty Team ID is refused so we never emit a vacuous,
    /// fail-open-looking requirement. `forbiddenEntitlements` appends one `!(entitlement[...] exists)`
    /// clause per key (empty = none, the helper-side shape).
    static func designatedRequirement(forIdentifier identifier: String,
                                      teamID: String,
                                      minShortVersion: String = minHelperShortVersion,
                                      forbiddenEntitlements: [String] = []) -> String {
        precondition(!teamID.isEmpty,
                     "designatedRequirement: teamID must be non-empty — refusing a fail-open requirement")
        var requirement = "identifier \"\(identifier)\""
            + " and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and info[CFBundleShortVersionString] >= \"\(minShortVersion)\""
        if !forbiddenEntitlements.isEmpty {
            requirement += " and " + entitlementsAbsentClause(forbiddenEntitlements)
        }
        return requirement
    }

    /// Convenience: the helper's DR (used by the app's NSXPCConnection pin AND validated against the
    /// SMAppService registration — the ONE string sec 6 requires be identical in both places).
    /// No entitlement clause: the helper runs as root, so attaching to it already requires root.
    static func helperRequirement(teamID: String) -> String {
        designatedRequirement(forIdentifier: helper, teamID: teamID)
    }

    /// Convenience: the app's DR (used by the helper listener's `setConnectionCodeSigningRequirement`
    /// pin to reject any connecting peer that is not the genuine app). The SAME string in every build
    /// configuration — the requirement the tests prove is the one that ships. It refuses an app below
    /// `minAppShortVersion` and any app with a `clientCodeInjectionEntitlements` key set to true, so a
    /// debuggable build is refused by the helper even when it is the genuine, team-signed app.
    static func appRequirement(teamID: String) -> String {
        designatedRequirement(forIdentifier: app, teamID: teamID,
                              minShortVersion: minAppShortVersion,
                              forbiddenEntitlements: clientCodeInjectionEntitlements)
    }

    /// The app pin split into its independently checkable parts, each labelled, for diagnostics only
    /// (the launch self-check names WHICH part a refused build fails — an ad-hoc or wrong-team build
    /// fails "identity", not "get-task-allow"). Joined with " and " the parts are exactly
    /// `appRequirement(teamID:)` (asserted in SharedTests), so the diagnosis cannot drift from the pin.
    static func appRequirementParts(teamID: String) -> [(label: String, requirement: String)] {
        [("identity (identifier \(app), Apple anchor, Team ID \(teamID))",
          "identifier \"\(app)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""),
         ("version >= \(minAppShortVersion)",
          "info[CFBundleShortVersionString] >= \"\(minAppShortVersion)\"")]
        + clientCodeInjectionEntitlements.map { ("no \($0)", entitlementsAbsentClause([$0])) }
    }

    /// Validate the signed code at a FILE PATH against a requirement string (SecStaticCode). Used as
    /// the registration PREFLIGHT (SPEC sec 6): before registering the daemon, confirm the binary that
    /// SMAppService will register — the embedded helper — actually satisfies the codified helper DR, so
    /// a mis-signed / wrong-team / wrong-identity helper is refused up front (an honest failure) rather
    /// than surfacing later as an opaque XPC rejection. This is the literal "DR validated against the
    /// SMAppService registration." Fail-CLOSED on any error.
    static func staticCodeSatisfies(path: String, requirement: String) -> Bool {
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var requirementRef: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &requirementRef) == errSecSuccess,
              let requirementRef else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirementRef) == errSecSuccess
    }

    /// Validate a peer — identified by its **audit_token** — against a requirement string, via the
    /// Security framework's audit-token guest attribute. This is the audit-token-backed check (the
    /// exact mechanism `NSXPCListener.setConnectionCodeSigningRequirement` performs internally); it
    /// NEVER consults the PID, so it is immune to the PID-reuse TOCTOU that the privileged-helper CVE
    /// canon exploits. Returns true iff the peer's code statically + dynamically satisfies `requirement`.
    ///
    /// NOTE: in PRODUCTION the live peer gate is the listener's `setConnectionCodeSigningRequirement`
    /// (NSXPCConnection exposes no PUBLIC audit_token to feed this). So `peerSatisfies` is the
    /// unit-PROVEN equivalent of that pin (accept + reject, on a real audit token) + reusable wherever
    /// a token IS available — NOT a second live gate in the NSXPC delegate.
    static func peerSatisfies(auditToken: audit_token_t, requirement: String) -> Bool {
        var token = auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else {
            return false   // cannot resolve the peer's code → fail CLOSED
        }
        var requirementRef: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &requirementRef) == errSecSuccess,
              let requirementRef else {
            return false   // malformed requirement → fail CLOSED (never accept on a broken pin)
        }
        return SecCodeCheckValidity(code, [], requirementRef) == errSecSuccess
    }

    /// A human-readable one-line summary of the peer's code signature (team, identifier) for the
    /// mandated auditability log line. Best-effort; never traps. NEVER includes/relies on the PID.
    static func peerSignatureSummary(auditToken: audit_token_t) -> String {
        var token = auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else {
            return "<unresolvable peer code>"
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return "<no static code>"
        }
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return "<no signing information>"
        }
        let ident = info[kSecCodeInfoIdentifier as String] as? String ?? "?"
        let team  = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "?"
        return "identifier=\(ident) team=\(team)"
    }
}

/// The current process's own `audit_token` (via the Mach task-info audit-token flavor) — used by the
/// unit tests to drive `peerSatisfies` with a REAL token, and available to any in-process caller.
/// Returns nil if the task-info call fails (never traps).
public func currentTaskAuditToken() -> audit_token_t? {
    var token = audit_token_t()
    var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &token) { tokenPtr -> kern_return_t in
        tokenPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), intPtr, &count)
        }
    }
    return kr == KERN_SUCCESS ? token : nil
}
