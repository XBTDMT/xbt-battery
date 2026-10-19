import Foundation

/// #29 D-5 (D10 / A1 / F4): the HUD's pure, unit-testable trigger predicate + string vocabulary.
///
/// The HUD is a transient confirmation pill for state changes made WITHOUT the app's UI present —
/// Shortcuts intents (#17) and schedule / top-up completions while the user is active. It never fires
/// for direct in-app (`.user`) actions (the interaction is its own confirmation), is suppressed while
/// the popover is visible (the open UI is its own confirmation), and never duplicates a notification.
/// F4: custody origin alone cannot express "UI present," so the predicate takes the popover-visible and
/// recent-user-action facts explicitly and stays a total function — provable host-app-free.

/// What the HUD announces — a closed vocabulary (D10). Associated values carry the numbers.
enum HUDEvent: Equatable {
    case chargeLimitSet(Int)    // "Charge limit set to N%"
    case toppingUp              // "Topping up to 100%"
    case energyModeSet(String)  // "Energy mode set to X"  — D-5 new trigger (draft §4)
    case keepAwake(Bool)        // "Keep awake on/off"     — locked vocabulary (no live trigger yet)
    case devicePowerStarted(DeviceNotice)   // 31 §2.2 (U6): title = the device name alone ("iPhone") + subline
}

/// The HUD string register (D10 vocabulary). The locked strings land as-is; the energy-mode string is
/// DRAFT per §4 (D10's own new-trigger rule — the Set Energy Mode intent is a no-UI trigger that had no
/// locked string). Sentence case (D7); sign-off at the audit + owner PNG gate.
enum HUDStrings {
    static func message(for event: HUDEvent) -> String {
        switch event {
        case .chargeLimitSet(let n): return "Charge limit set to \(n)%"
        case .toppingUp:             return "Topping up to 100%"
        case .energyModeSet(let m):  return "Energy mode set to \(m)"   // DRAFT (§4)
        case .keepAwake(let on):     return on ? "Keep awake on" : "Keep awake off"
        case .devicePowerStarted(let n): return n.title
        }
    }

    /// The leading SF Symbol per event (the mockup's ring / bolt / star, mapped to SF Symbols — the exact
    /// glyphs are owner-tunable visual detail).
    static func symbol(for event: HUDEvent) -> String {
        switch event {
        case .chargeLimitSet: return "circle.dashed"
        case .toppingUp:      return "bolt.fill"
        case .energyModeSet:  return "gauge.medium"
        case .keepAwake:      return "star"
        case .devicePowerStarted(let n): return n.symbol
        }
    }

    /// Whether the leading glyph carries the charging-status color (the mockup's `.charge` green) rather
    /// than the neutral role — the charge-limit / top-up outcomes; energy-mode and keep-awake stay neutral.
    /// Foundation-only (no Color here); the view layer maps this to DSColor.charging vs .textSecondary.
    static func isChargeGlyph(for event: HUDEvent) -> Bool {
        switch event {
        case .chargeLimitSet, .toppingUp: return true
        case .energyModeSet, .keepAwake, .devicePowerStarted: return false
        }
    }

    /// 31 T4: the second line — only the device notice has one.
    static func subline(for event: HUDEvent) -> String? {
        if case .devicePowerStarted(let n) = event { return n.subline }
        return nil
    }

    /// How long the pill stays up: 4.0 s for the two-line device notice (T4; owner U6, 2026-09-29: the number was
    /// delegated to the controller); the #29 events keep 1.6 s.
    static func duration(for event: HUDEvent) -> TimeInterval {
        if case .devicePowerStarted = event { return 4.0 }
        return 1.6
    }

    /// What VoiceOver hears: for the device notice the composer's full spoken sentence (the title is only the
    /// name now, so "title. subline" would not read as a sentence); the one line otherwise.
    static func announcement(for event: HUDEvent) -> String {
        if case .devicePowerStarted(let n) = event { return n.spoken }
        return message(for: event)
    }
}

enum HUDTrigger {
    /// THE trigger predicate (A1 / F4). Total over (custody origin, popover-visible-at-outcome-time,
    /// recent-user-initiated-action). Returns whether to SHOW the HUD.
    ///
    /// Rules (D10):
    /// - popover visible → suppress (the open UI is its own confirmation).
    /// - `.user` (a direct in-app / menu action) → suppress (the interaction is its own confirmation).
    /// - `.appIntent` (a Shortcuts intent) → show (no UI present, by nature).
    /// - `.schedule` / `.topUp` (an autonomous completion) → show only while the user is active; when the
    ///   user is away the outcome stays a NOTIFICATION (the caller gates the scheduled-applied notification
    ///   on the negation of this, so one outcome never gets both surfaces).
    static func shouldShow(origin: CommandSource, popoverVisible: Bool, userActive: Bool) -> Bool {
        if popoverVisible { return false }
        switch origin {
        case .user:      return false
        case .appIntent: return true
        case .schedule:  return userActive
        case .topUp:     return userActive
        }
    }

    /// 31 §2.2 (T3): the device notice shows only on battery, with the popover closed, the user active in
    /// the last 120 s, and its switch on — otherwise the event is dropped. No `CommandSource` is involved.
    static func shouldShowDeviceNotice(onBattery: Bool, popoverVisible: Bool, userActive: Bool, switchOn: Bool) -> Bool {
        onBattery && !popoverVisible && userActive && switchOn
    }
}


// MARK: - 31 §2.2 · the plug-in latch (G-4)

/// One diagnostics read as the latch sees it: portIndex → FilteredPower (mW) for every PowerOutDetails element
/// present. `ports == nil` = the read carried no information (a failed read, or ExternalConnected unread).
struct DeviceLatchRead: Sendable {
    let ports: [Int: Int]?
    let updateTime: Int?
    /// CLOCK_MONOTONIC_RAW — counts sleep.
    let monotonicRaw: TimeInterval
    /// CLOCK_UPTIME_RAW — stops during sleep.
    let uptimeRaw: TimeInterval
}

/// Fires when a port goes absent → drawing, once per plug-in, never at launch, never at wake. Tracks on AC
/// too (only the SHOWING is gated, by `HUDTrigger.shouldShowDeviceNotice`). Latency up to ~2 min (O3).
///
/// - Seed: the first successful read after launch (or after sleep) fires nothing; ports present then are
///   quiet. A port absent at the seed arms only once a FRESH read arrives — a newer UpdateTime, or any
///   port's FilteredPower changed (U3: evidence even without a new UpdateTime) — so a device plugged in
///   during sleep whose element lands one refresh after wake stays quiet.
/// - Sleep: (MONOTONIC_RAW − UPTIME_RAW) grew ≥ 1 s since the previous successful read → re-seed. Awake
///   reads drift by microseconds (measured 3.9–6.7 µs), so "grew at all" would re-seed forever.
/// - Re-arm: a port that was present re-arms once its absence lasted ≥ 120 s from its FIRST absent read to
///   its latest (so one missed frame never re-fires; a trickle below 0.5 W is not absence).
/// - `.unread` reads are neither absent nor present. Ports firing on one read are returned together.
struct DeviceNoticeLatch: Sendable {
    static let drawingThreshold_mW = 500
    static let rearmAbsence: TimeInterval = 120
    static let sleepJump: TimeInterval = 1

    private enum Phase: Sendable { case unseeded, awaitingFresh, live }
    private struct Port: Sendable {
        var armed: Bool
        var present: Bool
        var firstAbsentAt: TimeInterval?
    }

    private var phase: Phase = .unseeded
    private var seedUpdateTime: Int?
    private var lastPower: [Int: Int] = [:]
    private var lastGap: TimeInterval?
    private var ports: [Int: Port] = [:]

    init() {}

    mutating func ingest(_ read: DeviceLatchRead) -> [Int] {
        guard let present = read.ports else { return [] }
        let gap = read.monotonicRaw - read.uptimeRaw
        let slept = lastGap.map { gap - $0 >= Self.sleepJump } ?? false
        defer { lastGap = gap; lastPower = present }
        if phase == .unseeded || slept {
            seed(read, present)
            return []
        }
        if phase == .awaitingFresh {
            let fresh = isFresh(read, present)
            _ = advance(present, at: read.monotonicRaw, mayFire: false)
            // Going live arms nothing already tracked: a port present at the seed (or any read since) that has
            // dropped out follows the normal 120 s re-arm rule. Ports never seen since the seed have no entry
            // and arm on first sight once live (`advance`).
            if fresh { phase = .live }
            return []
        }
        return advance(present, at: read.monotonicRaw, mayFire: true)
    }

    private mutating func seed(_ read: DeviceLatchRead, _ present: [Int: Int]) {
        phase = .awaitingFresh
        seedUpdateTime = read.updateTime
        ports = present.mapValues { _ in Port(armed: false, present: true, firstAbsentAt: nil) }
    }

    private func isFresh(_ read: DeviceLatchRead, _ present: [Int: Int]) -> Bool {
        if let u = read.updateTime, seedUpdateTime.map({ u > $0 }) ?? true { return true }
        return present.contains { index, mW in lastPower[index].map { $0 != mW } ?? false }
    }

    private mutating func advance(_ present: [Int: Int], at t: TimeInterval, mayFire: Bool) -> [Int] {
        for (index, current) in ports where present[index] == nil {
            var port = current
            if port.present {
                port.present = false
                port.firstAbsentAt = t
            }
            if !port.armed, let first = port.firstAbsentAt, t - first >= Self.rearmAbsence { port.armed = true }
            ports[index] = port
        }
        var fired: [Int] = []
        for (index, mW) in present {
            var port = ports[index] ?? Port(armed: phase == .live, present: false, firstAbsentAt: nil)
            port.present = true
            port.firstAbsentAt = nil
            if port.armed, mW >= Self.drawingThreshold_mW {
                port.armed = false
                if mayFire { fired.append(index) }
            }
            ports[index] = port
        }
        return fired.sorted()
    }
}

// MARK: - 31 §2.2 · the notice (T2, T4, Q2)

/// One aggregated notice. "drawing power", never "charging" (Q2: false for a drive, a hub or a full iPhone).
struct DeviceNotice: Equatable, Sendable {
    /// The device's name alone ("iPhone", "USB-C device", "2 devices"); the verb lives in the subline (owner U6 "B").
    let title: String
    let subline: String
    /// What VoiceOver hears: the full sentence, no "·" or "≈" glyphs.
    let spoken: String
    /// The leading glyph: the device's symbol when one named device fired, else `cable.connector`.
    var symbol: String = "cable.connector"
}

/// One fired port: its corroborated name (nil = unnamed), kind, and FilteredPower.
struct DeviceNoticePort: Equatable, Sendable {
    let name: String?
    let kind: USBLeafKind?
    let filteredPower_mW: Int
}

enum DeviceNoticeComposer {
    /// Owner U6 "B" (2026-09-29): the TITLE is the device name alone — "iPhone" / "USB-C device" / "2 devices" —
    /// and the verb moves to the subline: "Drawing 14.2 W · ≈ 22% of battery per hour". "Drawing", never
    /// "charging" (Q2: false for a drive, a hub or a full iPhone). Watts at 0.1 W, like the rows; the "≈" carries a
    /// non-breaking space; a rate under 1 % reads "< 1%", never "0%" (the Devices tab's rule); watts only when the
    /// pack Wh is unread (§3 rule 5). Names are NEVER shortened here: the HUD truncates the title on one line.
    static func compose(_ ports: [DeviceNoticePort], percentPerHour: Int?) -> DeviceNotice? {
        guard let first = ports.first else { return nil }
        let watts = PortPowerDisplayModel.watts(tenths: ports.reduce(0) { $0 + PortPowerDisplayModel.tenths($1.filteredPower_mW) })
        let subline = "Drawing " + (percentPerHour.map { rate in
            let lead = rate < 1 ? PortPowerDisplayModel.formatPercent(rate) : "≈\u{00A0}" + PortPowerDisplayModel.formatPercent(rate)
            return "\(watts) · \(lead) of battery per hour"
        } ?? watts)
        let spokenRate = percentPerHour.map { rate in
            rate < 1 ? ", less than 1% of battery per hour" : ", about \(rate)% of battery per hour"
        } ?? ""
        let spokenTail = "Drawing \(watts)\(spokenRate)"
        guard ports.count > 1 else {
            // A blank or whitespace-only name is not a name. The glyph follows the title: an unnamed device never
            // shows a kind glyph (the title withholds the kind), so it gets the plain cable.
            let trimmed = first.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = trimmed, !name.isEmpty else {
                // The title is a bare label; the spoken sentence keeps its article ("A USB-C device is …").
                return DeviceNotice(title: DeviceNaming.unnamedLabel, subline: subline,
                                    spoken: "A \(DeviceNaming.unnamedLabel) is drawing power from your Mac. \(spokenTail)")
            }
            return DeviceNotice(title: name, subline: subline,
                                spoken: "\(name) is drawing power from your Mac. \(spokenTail)",
                                symbol: DeviceNaming.symbol(for: first.kind))
        }
        return DeviceNotice(title: "\(ports.count) devices", subline: subline,
                            spoken: "\(ports.count) devices are drawing power from your Mac. \(spokenTail)")
    }
}

/// 31 §2.2 (T9): the switch's OWN UserDefaults key — not a NotificationEventType, not a NotificationPrefs field.
enum DeviceNoticeSetting {
    static let key = "deviceNotice.enabled.v1"
    static let defaultOn = true
    static func isOn(_ defaults: UserDefaults) -> Bool {
        // A stored value that is not a Bool (a String, Data) is unreadable, not "off": the default applies.
        defaults.object(forKey: key) as? Bool ?? defaultOn
    }
}
