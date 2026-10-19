import Foundation
import Combine

/// #EI-1a: one process that is holding a user-meaningful sleep-prevention assertion, with its reason(s).
/// One entry per process (several raw assertions from the same process collapse here).
struct KeepAwakeHolder: Equatable, Identifiable {
    let pid: Int
    let processName: String
    let displayName: String   // v2: the curated friendly label (else the processName) — what the popover shows
    let explanation: String   // v2: the chosen user-facing reason (record reason → curated why → AssertName)
    let reasons: [String]     // the named strings, deduped, in first-seen order
    /// #30 §4.4: the EARLIEST `startedAt` among this process's kept assertions — dwell = now − this.
    /// nil when no kept record carried `AssertStartWhen`. Defaulted so existing construction is unchanged.
    var heldSince: Date? = nil
    var id: Int { pid }
}

/// #EI-1a the FILTER (the design crux) + grouping: given the raw system assertion dump, return the
/// user-meaningful "what else is keeping your Mac awake" set. PURE + tested. Type alone is insufficient
/// (powerd and a real app both hold PreventUserIdleSystemSleep), so we gate on the sleep-prevention
/// family AND drop our own assertion, the transient/you noise, and powerd's circular display holder.
enum WhatsKeepingAwake {

    /// INCLUDE: the sleep-prevention family (the only types worth surfacing).
    static let includedTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion", "DenySystemSleep",
    ]

    /// EXCLUDE by type: transient / "that's just you" noise. (Disjoint from `includedTypes`, so the
    /// include-gate already drops these — this list is intentional belt-and-suspenders that also keeps
    /// the known-noise types documented and stays correct if the include set is ever widened. Owner-tunable.)
    static let excludedTypes: Set<String> = [
        "UserIsActive", "BackgroundTask", "NetworkClientActive", "ExternalMedia",
        "ApplePushServiceTask", "SoftwareUpdateTask",
    ]

    /// EXCLUDE the circular OS holder: powerd reflecting that the display is on (not an app keeping you
    /// awake). Matched by owner + name so a different powerd reason is NOT blanket-suppressed.
    static let circularOwner = "powerd"
    static let circularName = "Prevent sleep while display is on"

    /// Filter + group: included family, own-excluded, noise-excluded, then one entry per process with its
    /// deduped reasons (first-seen order preserved for deterministic display/testing).
    static func holders(from records: [AssertionRecord], excludingOwnName ownName: String) -> [KeepAwakeHolder] {
        var order: [Int] = []
        var byPid: [Int: (rep: AssertionRecord, reasons: [String], since: Date?)] = [:]
        for r in records where keep(r, ownName: ownName) {
            // The first kept record per process is the representative the chooser names + explains (v2).
            if byPid[r.pid] == nil { order.append(r.pid); byPid[r.pid] = (r, [], nil) }
            if !r.name.isEmpty, !byPid[r.pid]!.reasons.contains(r.name) {
                byPid[r.pid]!.reasons.append(r.name)
            }
            // #30 §4.4: the process has been holding since its OLDEST kept assertion.
            if let t = r.startedAt, byPid[r.pid]!.since.map({ t < $0 }) ?? true { byPid[r.pid]!.since = t }
        }
        return order.map { pid in
            let entry = byPid[pid]!
            return KeepAwakeHolder(pid: pid, processName: entry.rep.processName,
                                   displayName: displayName(for: entry.rep), explanation: explanation(for: entry.rep),
                                   reasons: entry.reasons, heldSince: entry.since)
        }
    }

    /// One record passes if it is a sleep-prevention-family assertion that is not ours, not transient
    /// noise, and not powerd's circular display holder.
    static func keep(_ r: AssertionRecord, ownName: String) -> Bool {
        guard includedTypes.contains(r.type) else { return false }            // only the sleep-prevention family
        if excludedTypes.contains(r.type) || r.type.hasPrefix("Internal") { return false }  // transient/you noise
        if r.name == ownName { return false }                                 // never report ourselves
        if r.processName == circularOwner && r.name == circularName { return false }  // powerd's circular holder
        return true
    }

    // MARK: - #30 §4.4: dwell text (pure)

    /// How long a holder has been holding, in the two largest units that apply: "5 d 22 h",
    /// "2 h 10 m", "12 m", "45 s". Whole units, floored. A start in the future (clock skew) is "0 s".
    static func dwellText(since: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(since)))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) m" }
        if minutes > 0 { return "\(minutes) m" }
        return "\(seconds) s"
    }

    // MARK: - v2: friendly display name + explanation chooser (pure over the record + the static table)

    /// v2 first-party hint table: a known daemon process name → (curated label, one-line why). FIRST-PARTY
    /// ONLY and deliberately small; unknown processes get NO hint (they fall back to the record). Probe
    /// confirmed these bare daemons carry no HumanReadableReason, so a curated hint is what serves them.
    static let firstPartyHints: [String: (label: String, why: String)] = [
        "configd":        ("Internet Sharing", "Network configuration or Internet Sharing"),
        "powerd":         ("Display",          "Keeping the display awake"),
        "backupd":        ("Time Machine",     "A Time Machine backup"),
        "backupd-helper": ("Time Machine",     "A Time Machine backup"),
        "mds_stores":     ("Spotlight",        "Spotlight indexing"),
        "mdsync":         ("Spotlight",        "Spotlight indexing"),
        "WindowServer":   ("User activity",    "Recent user or input activity"),
        "caffeinate":     ("caffeinate",       "The caffeinate tool is holding sleep open"),
    ]

    /// v2: the friendly display name — the curated label if the process is first-party-known, else the
    /// record's processName (its "Process Name", or proc_name(pid), or "PID N").
    static func displayName(for r: AssertionRecord) -> String {
        firstPartyHints[r.processName]?.label ?? r.processName
    }

    /// v2: the user-facing explanation, chosen in order: the record's HumanReadableReason if present, else
    /// the curated why if the process is first-party-known, else the AssertName (`name`).
    static func explanation(for r: AssertionRecord) -> String {
        if !r.reason.isEmpty { return r.reason }
        if let hint = firstPartyHints[r.processName] { return hint.why }
        return r.name
    }
}

/// #EI-1a popover source: reads the inventory ON DEMAND (popover-open) and publishes the filtered
/// holders. NO new timer — `refresh()` is called from the existing popover-open path. `hasRead`
/// distinguishes "not yet read" from "read, nothing else holding".
@MainActor
final class KeepAwakeInventorySource: ObservableObject {
    @Published private(set) var holders: [KeepAwakeHolder] = []
    @Published private(set) var hasRead = false

    private let inventory: AssertionInventory
    private let ownName: String

    init(inventory: AssertionInventory = LiveAssertionInventory(),
         ownAssertionName: String = KeepAwakeController.assertionName) {
        self.inventory = inventory
        self.ownName = ownAssertionName
    }

    /// On-demand read (synchronous IOKit dump; fast). Applies the pure filter. No polling timer.
    func refresh() {
        holders = WhatsKeepingAwake.holders(from: inventory.currentAssertions(), excludingOwnName: ownName)
        hasRead = true
    }
}
