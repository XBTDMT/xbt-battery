import Foundation
import IOKit.pwr_mgt
import Darwin   // proc_name (process name for a pid; works for daemons, no entitlement)

/// #EI-1a (SPEC 02-SPEC-ei1a-whats-keeping-awake.md). One raw sleep-related assertion held by some
/// process, as read from the system-wide dump. The pure filter (WhatsKeepingAwake) turns a list of
/// these into the user-meaningful "what else is keeping your Mac awake" set.
struct AssertionRecord: Equatable {
    let pid: Int
    let processName: String   // v2: PREFERS the record's "Process Name"; else proc_name(pid); else "PID N"
    let type: String          // the IOPMAssertionType string (kIOPMAssertionTypeKey "AssertType")
    let name: String          // the named string (kIOPMAssertionNameKey "AssertName"); "" if absent
    let reason: String        // v2: the record's "HumanReadableReason" (literal key); "" if absent
    /// #30 §4.4 / §14-D8: when the assertion was taken — the record's "AssertStartWhen" (literal key;
    /// verified 2026-09-09 on this M4 Max / macOS 27: bridges as `__NSTaggedDate`, i.e. an NSDate, so
    /// `as? Date` reads it). nil when the key is absent or not a date. Defaulted so the existing
    /// 5-field construction (tests, fixtures) is unchanged.
    var startedAt: Date? = nil
}

/// Seam over the READ-ONLY system assertion dump (IOKit.pwr_mgt), mirroring the #EI-1 SleepAssertion
/// seam and the project's reader seams: production wraps `IOPMCopyAssertionsByProcess`; tests inject a
/// mock so the filter/grouping is driven without the live system. READ-ONLY — this NEVER creates or
/// releases an assertion (the create side is #EI-1). No root, no entitlement, app-side only.
protocol AssertionInventory: AnyObject {
    /// A snapshot of ALL currently-held assertions across processes. Empty on read failure.
    func currentAssertions() -> [AssertionRecord]
}

/// Production inventory: `IOPMCopyAssertionsByProcess` returns a pid-keyed dump of held assertions.
/// Boundary adapter — exercised in tests only through the seam's mock (never the live system call).
final class LiveAssertionInventory: AssertionInventory {
    func currentAssertions() -> [AssertionRecord] {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
              let byPID = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var records: [AssertionRecord] = []
        for (pidKey, assertions) in byPID {
            let pid = pidKey.intValue
            let fallback = Self.processName(pid: pid_t(pid))   // proc_name(pid) → "PID N" on failure
            for a in assertions {
                if let rec = Self.record(from: a, pid: pid, fallbackName: fallback) { records.append(rec) }
            }
        }
        return records
    }

    /// Pure per-record field selection (v2). PURE over the assertion dict so the "Process Name" preference
    /// and the HumanReadableReason read are testable without the live IOKit call. `type` (AssertType) and
    /// `name` (AssertName) keep their Swift constants; "Process Name" and "HumanReadableReason" are read as
    /// LITERAL keys (not exposed as constants on this OS). processName PREFERS the record's "Process Name"
    /// (free + exit-safe — no race if the PID is gone), else `fallbackName` (proc_name(pid), already "PID N").
    /// The IOPM record key for the assertion's start time (not exposed as a constant on this OS).
    static let startWhenKey = "AssertStartWhen"

    static func record(from a: [String: Any], pid: Int, fallbackName: String) -> AssertionRecord? {
        guard let type = a[kIOPMAssertionTypeKey as String] as? String else { return nil }
        let name = (a[kIOPMAssertionNameKey as String] as? String) ?? ""
        let reason = (a["HumanReadableReason"] as? String) ?? ""
        let recordName = a["Process Name"] as? String
        let processName = (recordName?.isEmpty == false) ? recordName! : fallbackName
        let startedAt = a[startWhenKey] as? Date
        return AssertionRecord(pid: pid, processName: processName, type: type, name: name, reason: reason,
                               startedAt: startedAt)
    }

    /// Resolve a pid → executable name via libproc (works for daemons; no entitlement). "PID N" on failure.
    private static func processName(pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : "PID \(pid)"
    }
}
