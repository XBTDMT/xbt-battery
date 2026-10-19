import Foundation
import IOKit.pwr_mgt

/// #EI-1 keep-awake (SPEC 02-SPEC-ei1-keep-awake.md). The IOPM sleep-prevention assertion kinds this
/// feature uses, each mapping to the IOKit assertion-type STRING of the same name (probe-confirmed on
/// macOS 27.0). We deliberately use the literal type strings — the spec records that these map to the
/// `IOPMAssertionType` constants of the same names.
enum SleepAssertionKind: String, CaseIterable, Sendable {
    /// `PreventUserIdleSystemSleep` — the machine will not idle-sleep (the display may still sleep).
    case systemIdle = "PreventUserIdleSystemSleep"
    /// `PreventUserIdleDisplaySleep` — the display stays on (so the system stays awake too).
    case displayIdle = "PreventUserIdleDisplaySleep"
}

/// Seam over the in-process power assertion (IOKit.pwr_mgt), mirroring the project's reader seams
/// (`EnergyModeReading` / `PowerSourceReading`): production wraps `IOPMAssertionCreateWithName` /
/// `IOPMAssertionRelease`; tests inject a mock so the keep-awake state machine is driven WITHOUT a
/// real assertion. NO root, NO entitlement, NO subprocess — app-side only; it never touches the
/// privileged helper, the XPC protocol, or the SMC-dead gate.
protocol SleepAssertion: AnyObject {
    /// Create a named, level-on assertion of `kind`. Returns the assertion id, or nil on failure.
    /// A nil is a REAL failure, not a shrug: nothing is being prevented for that kind, so the caller
    /// must not present a capability it does not hold (KeepAwakeController stays off when every kind
    /// fails). The id is never synthesised — an id we don't hold must never be released.
    func create(_ kind: SleepAssertionKind, name: String) -> UInt32?
    /// Release a previously-created assertion id. Idempotent — an unknown / already-released id is safe.
    func release(_ id: UInt32)
}

/// Production assertion: `IOPMAssertionCreateWithName` (level ON) / `IOPMAssertionRelease`. The
/// assertion releases the instant THIS process exits (the OS backstop), but the controller also
/// releases explicitly on every exit path — the safety spine, so no dangling assertion is left
/// (SPEC #EI-1: the pid-716 forever-caffeinate is the anti-pattern). Boundary adapter: exercised in
/// tests only through the seam's mock (never a real assertion), like the project's other Live readers.
final class LiveSleepAssertion: SleepAssertion {
    func create(_ kind: SleepAssertionKind, name: String) -> UInt32? {
        var id: IOPMAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kind.rawValue as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 name as CFString,
                                                 &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) {
        _ = IOPMAssertionRelease(id)
    }
}
