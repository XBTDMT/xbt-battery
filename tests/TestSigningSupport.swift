import XCTest
import Security

/// The running test process's own designated requirement string (via SecCode) — the "matching" pin
/// used by the channel + peer-validation proof tests. Throws `XCTSkip` if unobtainable (no signature
/// in the environment), so the suite degrades honestly rather than failing spuriously.
func selfDesignatedRequirement() throws -> String {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw XCTSkip("SecCodeCopySelf failed") }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        throw XCTSkip("SecCodeCopyStaticCode failed")
    }
    var req: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess, let req else {
        throw XCTSkip("SecCodeCopyDesignatedRequirement failed")
    }
    var str: CFString?
    guard SecRequirementCopyString(req, [], &str) == errSecSuccess, let s = str else {
        throw XCTSkip("SecRequirementCopyString failed")
    }
    return s as String
}
