import Foundation
import Combine

/// Sprint 4.H (#12): connected-device batteries. Best-effort by design — we show what macOS exposes
/// and claim nothing more. iPhone/Watch battery is NOT exposed to a Mac → no rows (#30 parked).
/// NO background polling, ever — fetched on Details-page open only.
///
/// Sprint 4.I: the THREE subprocess spawns per open (`pmset -g accps`, `ioreg -k BatteryPercent`,
/// `system_profiler SPBluetoothDataType` — measured 0.43–0.55 s wall / ~0.18 s child CPU together)
/// collapse to ONE in-process `IOPSCopyPowerSourcesByType(0)` read at **0.088 ms** (measured
/// end-to-end: call + description extraction + parse). What each retired
/// spawn was providing, and why IOPS covers it:
///   • `pmset -g accps` — accessory name + percent + charging. IOPS carries all three (`Name`,
///     `Current Capacity`, `Is Charging`) from the same underlying power-source registry, in clean
///     UTF-8 (pmset's Mac-Roman apostrophe mojibake, the 2026-06-12 doubled-AirPods bug, is gone at
///     the source). It was also undocumented — `accps` is not in `man pmset`'s `-g` list.
///   • `system_profiler SPBluetoothDataType` — clean name, Left/Right/Case labels, Minor Type,
///     Address, Serial. IOPS carries the name, and `Part Identifier` gives the labels as FACT rather
///     than the percent-matching guess; `Accessory Category` replaces Minor Type. Address/Serial are
///     surfaced NOWHERE in the popover (verified against app/Views/BatteryPopoverView.swift), and on
///     this machine the connected AirPods Max carries no "Battery Level" line at all, so the parser
///     dropped it and its Address/Serial never reached the model anyway.
///   • `ioreg -r -l -k BatteryPercent` — KEPT, conditionally. See `ioregExhausted` below.

// MARK: - model (the read contract for the popover)

enum DeviceClass: String, Equatable, CaseIterable {
    case airpods, airpodsMax, headphones, mouse, keyboard, trackpad, applewatch, iphone, generic

    /// class → SF symbol, with a generic-battery fallback (never blank). #30 R8: delegates to
    /// `DeviceIcon` (class + name); this name-less form is the class-only answer. Prefer
    /// `DeviceIcon.symbol(for:name:)` where the product name is at hand — it separates AirPods Pro /
    /// 3rd-gen / Beats — and it is what fixed the trackpad blank (§14-B6).
    var sfSymbol: String { DeviceIcon.symbol(for: self, name: "") }

    /// 4.I: `category` is IOPS's `Accessory Category` (Headset / Mouse / Keyboard / …), which replaces
    /// system_profiler's "Minor Type". Name rules run first — only they separate AirPods from AirPods Max.
    static func classify(name: String, category: String?) -> DeviceClass {
        let n = name.lowercased()
        if n.contains("airpods max") { return .airpodsMax }
        if n.contains("airpods")     { return .airpods }
        if n.contains("trackpad")    { return .trackpad }
        if n.contains("keyboard")    { return .keyboard }
        if n.contains("mouse")       { return .mouse }
        if n.contains("watch")       { return .applewatch }
        if n.contains("iphone")      { return .iphone }
        guard let c = category?.lowercased() else { return .generic }
        if c.contains("headset") || c.contains("headphone") { return .headphones }
        if c.contains("trackpad") { return .trackpad }
        if c.contains("keyboard") { return .keyboard }
        if c.contains("mouse")    { return .mouse }
        if c.contains("watch")    { return .applewatch }
        return .generic
    }
}

/// One battery within a device. `label` nil = a single battery (IOPS `Part Identifier` == `Single`, or
/// no part exposed). `charging` nil = no source exposed it.
struct DeviceBatteryComponent: Equatable {
    let label: String?
    let percent: Int
    let charging: Bool?
}

struct DeviceBattery: Equatable, Identifiable {
    /// 4.I: the STABLE identity — IOPS's `Accessory Identifier` (a UUID) when there is one, else a
    /// normalized name. Was the display name, which is neither stable nor unique.
    let id: String
    let name: String
    let deviceClass: DeviceClass
    let components: [DeviceBatteryComponent]
    /// Bluetooth MAC. Only the `ioreg` fallback supplies one now; IOPS does not carry it. (Nothing in
    /// the popover renders it — it is kept because the fallback has it for free and it aids debugging.)
    let address: String?
    let asOf: Int
}

/// 4.I (audit C1): the THREE-STATE read. Absence-of-data and failure-to-read used to be the same value
/// (an empty `[DeviceBattery]`), which is why a failing source could erase the Devices card with no cue
/// — the exact silent failure the S6 cut shipped `spUnavailable` to prevent, and which then lost its
/// call site. The view MUST render `note` so a future macOS change surfaces legibly.
enum DeviceReadState: Equatable, Sendable {
    /// PRESENT — the read worked and at least one device reports a battery.
    case devices
    /// ABSENT BY DESIGN — the read worked; nothing connected reports a battery.
    case noneConnected
    /// READ FAILED — the read could not be performed (or completed only partially). Carries the reason.
    case unavailable(String)

    /// The cue the Devices card shows. nil only in the fully-healthy case.
    var note: String? {
        switch self {
        case .devices:              return nil
        case .noneConnected:        return "No connected device reports a battery."
        case .unavailable(let why): return "Device batteries unavailable — \(why)."
        }
    }
}

// MARK: - per-source raw types

struct IoregDevice: Equatable { let name: String; let percent: Int; let charging: Bool?; let address: String? }

// MARK: - parsers (pure)

enum DeviceParsers {
    /// `ioreg` HID/BT battery nodes (BatteryPercent). Charging NOT inferred (flags semantics unsure).
    static func parseIoreg(_ text: String) -> [IoregDevice] {
        text.components(separatedBy: "+-o").compactMap { node -> IoregDevice? in
            guard let pctStr = capture(node, #""BatteryPercent"\s*=\s*(\d+)"#), let pct = Int(pctStr) else { return nil }
            let name = capture(node, #""Product"\s*=\s*"([^"]+)""#) ?? "Bluetooth Device"
            let addr = capture(node, #""DeviceAddress"\s*=\s*"([^"]+)""#)
            return IoregDevice(name: name, percent: pct, charging: nil, address: addr)
        }
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

// MARK: - merge / dedupe (pure; by Accessory Identifier)

enum DeviceMerge {
    /// Name normalizer: collapse apostrophe variants to a straight ' + trim. IOPS itself emits clean
    /// UTF-8 (the Mac-Roman 0xD5 → U+FFFD mojibake was a `pmset` artefact and is gone with it), but the
    /// `ioreg` fallback names are unnormalized and this is still the name-level identity for a source
    /// that gives no `Accessory Identifier`.
    static func dedupKey(_ name: String) -> String {
        var s = name
        for v in ["\u{2019}", "\u{2018}", "\u{FFFD}", "\u{0092}", "\u{00D5}"] {
            s = s.replacingOccurrences(of: v, with: "'")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// IOPS `Part Identifier` → component label. `Single` (and an absent part) is a lone battery → nil.
    /// Any OTHER value passes through verbatim, so a part type Apple adds later surfaces instead of
    /// vanishing. This replaces the old percent-matching Left/Right guess outright.
    static func partLabel(_ partID: String?) -> String? {
        guard let p = partID?.trimmingCharacters(in: .whitespaces), !p.isEmpty,
              p.caseInsensitiveCompare("Single") != .orderedSame else { return nil }
        return p
    }

    /// Case → Left → Right → any future label → the lone unlabeled battery. (Preserves the pre-4.I
    /// on-screen chip order.)
    private static func rank(_ label: String?) -> Int {
        switch label?.lowercased() {
        case "case":  return 0
        case "left":  return 1
        case "right": return 2
        case .none:   return 4
        default:      return 3
        }
    }

    static func merge(accessories: [AccessoryPowerSource], ioreg: [IoregDevice], asOf: Int) -> [DeviceBattery] {
        var out = accessoryDevices(accessories, asOf: asOf)
        var taken = Set(out.map { dedupKey($0.name) })
        for d in ioreg {
            let key = dedupKey(d.name)
            guard !taken.contains(key) else { continue }   // IOPS wins where both saw the same device
            taken.insert(key)
            out.append(DeviceBattery(id: "ioreg:\(key)", name: d.name,
                                     deviceClass: DeviceClass.classify(name: d.name, category: nil),
                                     components: [DeviceBatteryComponent(label: nil, percent: d.percent,
                                                                         charging: d.charging)],
                                     address: d.address, asOf: asOf))
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func accessoryDevices(_ sources: [AccessoryPowerSource], asOf: Int) -> [DeviceBattery] {
        // 1. Key by the identifier IOPS supplies; a source without one falls back to its name.
        var order: [String] = []
        var groups: [String: [AccessoryPowerSource]] = [:]
        for s in sources {
            let key = s.accessoryID ?? "name:\(dedupKey(s.name))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(s)
        }

        // 2. Apple does not document whether the Left/Right/Case parts of ONE accessory share an
        //    Accessory Identifier, and the only accessory available here to observe is single-part
        //    (AirPods Max, Part Identifier "Single"). So after keying by identifier we ALSO coalesce
        //    identifier-groups that share a name AND whose part labels are present and DISJOINT: an
        //    AirPods set lands on one row under either reading, while two same-named single-part
        //    devices (two "Magic Mouse") keep their distinct identifiers and stay two rows.
        var survivors: [String] = []
        var hostForName: [String: String] = [:]
        var claimedParts: [String: Set<String>] = [:]
        for key in order {
            guard let g = groups[key] else { continue }
            let parts = Set(g.compactMap { partLabel($0.partID)?.lowercased() })
            let fullyLabelled = parts.count == g.count            // every source carries a distinct part
            let nameKey = dedupKey(g[0].name)
            if fullyLabelled, let host = hostForName[nameKey],
               let claimed = claimedParts[host], claimed.isDisjoint(with: parts) {
                groups[host]? += g
                claimedParts[host] = claimed.union(parts)
                groups[key] = nil
                continue
            }
            survivors.append(key)
            if fullyLabelled { hostForName[nameKey] = key; claimedParts[key] = parts }
        }

        // 3. One row per survivor, components in a deterministic order (sort is not stable → index tiebreak).
        return survivors.compactMap { key -> DeviceBattery? in
            guard let g = groups[key], let first = g.first else { return nil }
            let comps = g.enumerated()
                .map { (i, s) in (i, DeviceBatteryComponent(label: partLabel(s.partID), percent: s.percent,
                                                            charging: s.isCharging)) }
                .sorted { a, b in
                    let (ra, rb) = (rank(a.1.label), rank(b.1.label))
                    return ra == rb ? a.0 < b.0 : ra < rb
                }
                .map { $0.1 }
            return DeviceBattery(id: key, name: first.name,
                                 deviceClass: DeviceClass.classify(name: first.name, category: first.category),
                                 components: comps, address: nil, asOf: asOf)
        }
    }
}

// MARK: - staleness (pure)

enum DeviceStaleness {
    /// "as of N m ago" / "as of N s ago"; nil when fresh (< 10 s) — render cached instantly, note the age.
    static func note(asOf: Int, now: Int) -> String? {
        let age = now - asOf
        if age < 10 { return nil }
        if age < 60 { return "as of \(age)s ago" }
        if age < 3600 { return "as of \(age / 60)m ago" }
        return "as of \(age / 3600)h ago"
    }
}

// MARK: - the source (Details-open fetch only)

@MainActor
final class DeviceBatterySource: ObservableObject {
    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var lastFetch: Int?
    /// 4.I (audit C1): the honest read state. The Devices card renders `readState.note` whenever it is
    /// non-nil, so a failed read is VISIBLE instead of collapsing into "no devices" / no card at all.
    @Published private(set) var readState: DeviceReadState = .noneConnected

    private let reader: any AccessoryPowerSourceReading
    private let probe: any ProcessProbing
    private let now: () -> Int

    /// `ioreg -r -l -k BatteryPercent` reads IOHIDEventDriver nodes — a genuinely DIFFERENT mechanism
    /// from IOPS, and the only path that could reach a Bluetooth/USB HID battery IOPS never lists.
    /// Measured on this machine (macOS 27.0, AirPods Max connected) it returns **0 bytes**, so it is
    /// not what feeds this card here — but no BT HID device was available to falsify its value on other
    /// setups, so it is kept rather than assumed dead. It is kept only where it can ADD coverage:
    /// attempted ONLY when IOPS lists no accessory at all, and at most ONCE per session once it comes
    /// back empty (the same posture as the retired system_profiler demotion). `refresh()` re-arms it.
    ///
    /// RECOVERY (hand-off #2 from the spawn-recovery pass). This latched on `timedOut || launchFailed`,
    /// and `timedOut` folds in the case where OUR OWN watchdog killed the child. So one loaded moment
    /// permanently disarmed the only mechanism that can reach a HID battery IOPS never lists — for the
    /// whole session, with the card then claiming `.noneConnected` ("No connected device reports a
    /// battery"), a fact the app never established. The same latch-on-a-transient shape
    /// `HighPowerCapabilityReader` had, and worse here: `refresh()` is the documented way back and
    /// NOTHING IN THE APP CALLS IT (verified: the only production caller of this source is
    /// `BatteryPopoverView.detailsPage`'s `.task`, which calls `fetch()`).
    ///
    /// It now latches only a SETTLED failure. `cutShort` (we killed it) re-arms — see the budget below.
    private var ioregExhausted = false

    /// The reason we gave up, kept so the card KEEPS saying it. Nil after a completed read, including a
    /// completed read that found nothing — that one is a real `.noneConnected` and must stay one.
    private var ioregGiveUpReason: String?

    /// CONSECUTIVE cut-short attempts we will still make. Pre-consumed (decremented BEFORE the spawn)
    /// and refunded by any completed read, which is what makes the bound hold under the concurrent
    /// `fetch()` a fast push/pop of Details can produce: `fetch()` suspends across the probe, so two
    /// opens can both be past the guard at once, and a counter incremented AFTER the await would let
    /// them both spawn. Pre-consuming means the budget is the exact ceiling with no in-flight bookkeeping.
    private var ioregAttemptsLeft = DeviceBatterySource.ioregCutShortBudget

    /// WORST-CASE SPAWNS. This is a SESSION budget, not a rate: a permanently wedged `ioreg` costs at
    /// most 3 children for the life of the process and then zero, however many times Details is opened.
    /// Un-latching WITHOUT it would put the probe back on every Details open — ~1,800/hour at a
    /// determined push/pop pace, against the ~338/hour the app already spawns. That is the A11/A12
    /// spawn-count class this arc exists to delete, so the un-latch does not ship without the cap.
    ///
    /// 3 rather than the `.onceIfCutShort` 2 used for High Power because these attempts are SPREAD:
    /// High Power retries immediately (same system conditions, so a second try adds little), while
    /// these land one-per-Details-open, seconds-to-minutes apart, which is a genuinely fresh sample.
    static let ioregCutShortBudget = 3

    /// PURE. Why the fallback probe failed, or nil when it completed. Order matters: a child WE killed
    /// has no meaningful exit status to report, and `timedOut` without `cutShort` means it died on its
    /// own signal. Only the `cutShort` case is retryable; the other three are answers.
    ///
    /// The exit-code clause is the second half of the hand-off. Before it, this source ignored the
    /// child's status entirely, so a program that FAILED but printed something parseable got parsed
    /// anyway and its partial tree was merged and shown as fact with no cue — the silent-partial-read
    /// class. Gating is free here: `ioreg` exits 0 for "no matches" (verified on macOS 27.0:
    /// `ioreg -r -l -k ZZZNoSuchKey` → 0 bytes, status 0) and non-zero only on a real error, so the
    /// healthy empty case is untouched. Matched as a KNOWN non-zero status, so the `nil` that means
    /// "never launched" (already covered by `launchFailed`) is not double-counted.
    static func probeFailureReason(_ out: ProcessProbeResult) -> String? {
        if out.launchFailed { return "the Bluetooth HID probe could not be started" }
        if out.cutShort     { return "the Bluetooth HID probe did not finish in time" }
        if out.timedOut     { return "the Bluetooth HID probe stopped unexpectedly" }
        if let code = out.exitCode, code != 0 { return "the Bluetooth HID probe exited \(code)" }
        return nil
    }

    init(reader: any AccessoryPowerSourceReading = LiveAccessoryPowerSourceReader(),
         probe: any ProcessProbing = ProcessProbe(),
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.reader = reader
        self.probe = probe
        self.now = now
    }

    /// Details-open fetch: one in-process IOPS read, plus the conditional ioreg fallback. Never background.
    func fetch() async {
        let t = now()
        var accessories: [AccessoryPowerSource] = []
        var failure: String?
        switch reader.read() {
        case .read(let s):          accessories = s
        case .unavailable(let why): failure = why
        }

        var ioreg: [IoregDevice] = []
        if accessories.isEmpty {
            if !ioregExhausted && ioregAttemptsLeft > 0 {
                ioregAttemptsLeft -= 1        // consumed BEFORE the spawn — see `ioregAttemptsLeft`
                let out = await probe.run("/usr/sbin/ioreg",
                                          args: ["-r", "-l", "-k", "BatteryPercent"], timeout: 5)
                if let why = Self.probeFailureReason(out) {
                    // A dropped fallback used to be invisible; now it is a stated reason — and a
                    // DIFFERENT reason per cause, because "we killed it" and "it ran and said no" are
                    // not the same thing to a user deciding whether the list is trustworthy.
                    failure = failure ?? why
                    ioregGiveUpReason = why
                    // Latch only a SETTLED failure. `cutShort` means WE stopped listening, which says
                    // nothing about the next attempt; the budget, not the latch, bounds those.
                    ioregExhausted = !out.cutShort
                } else {
                    // A completed read refunds the budget, so three unlucky moments spread across a
                    // long session cannot starve a machine whose `ioreg` actually answers.
                    ioregAttemptsLeft = Self.ioregCutShortBudget
                    ioregGiveUpReason = nil
                    ioreg = DeviceParsers.parseIoreg(out.stdout)
                    ioregExhausted = ioreg.isEmpty
                }
            } else if let why = ioregGiveUpReason {
                // We stopped asking, and we never got an answer. Keep saying so: falling through to
                // `.noneConnected` here would assert an absence the app never established.
                failure = failure ?? why
            }
        }

        devices = DeviceMerge.merge(accessories: accessories, ioreg: ioreg, asOf: t)
        // A failed read stays `.unavailable` EVEN IF the fallback produced rows — the card is then
        // incomplete, and saying so is the whole point of the three-state result.
        if let failure { readState = .unavailable(failure) }
        else { readState = devices.isEmpty ? .noneConnected : .devices }
        lastFetch = t
    }

    /// Explicit refresh affordance — re-arms the once-per-session ioreg fallback, BOTH halves of it
    /// (the settled latch and the cut-short budget). An explicit user gesture is allowed to ask again
    /// after we gave up. NOTE: nothing in the app calls this today — the Devices card has no refresh
    /// control — so it is the tests' re-arm, not the user's. That is exactly why the latch had to stop
    /// tripping on a transient.
    func refresh() async {
        ioregExhausted = false
        ioregAttemptsLeft = Self.ioregCutShortBudget
        ioregGiveUpReason = nil
        await fetch()
    }

    func stalenessNote() -> String? {
        lastFetch.flatMap { DeviceStaleness.note(asOf: $0, now: now()) }
    }
}
