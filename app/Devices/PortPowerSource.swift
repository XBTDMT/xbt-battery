import Foundation
import Combine

/// spec 31 §2.2 (G-4) — the two raw clocks the port source samples on EVERY read. `monotonicRaw`
/// (CLOCK_MONOTONIC_RAW) keeps counting through sleep; `uptimeRaw` (CLOCK_UPTIME_RAW) pauses during it —
/// so their difference growing by ≥ 1 s between reads means the Mac slept (stage 5's latch).
struct MonotonicClocks: Sendable {
    let monotonicRaw: @Sendable () -> TimeInterval
    let uptimeRaw: @Sendable () -> TimeInterval

    static let live = MonotonicClocks(
        monotonicRaw: { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 },
        uptimeRaw: { TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 })
}

/// One continuous run of reads on which a port's `PowerOutDetails` element was present. The inputs of the
/// G-7 timing match (stage 4): a USB leaf is "new" for this port when it was first enumerated after
/// `previousPresentAt` (or after the launch seed when nil) and ≤ 130 s before `firstDrawingAt`.
struct PortEpisode: Equatable, Sendable {
    /// `monotonicRaw` of the first read of this episode.
    let startedAt: TimeInterval
    /// The last read on which the port was present in its PREVIOUS episode; nil = none since launch.
    let previousPresentAt: TimeInterval?
    /// `monotonicRaw` of the first read of this episode on which the port was drawing (≥ 0.5 W); nil = not yet.
    var firstDrawingAt: TimeInterval?
}

/// spec 31 §4 (G-2) — external power, parsed off the monitor's OWN diagnostics read (the subscriber tap),
/// never riding `BatterySnapshot`. Host-app-free: it compiles into the test target via the app/Devices glob.
///
/// The parsed, derived state (stage 3) is held as plain `private(set)` properties; the one published property
/// is the rounded `display` (stage 4), observed only by `DevicesPage`. Stage 4 also added the per-read USB
/// leaf walk (`usb`) and the "as of" freshness (`now`); stage 5 adds the HUD latch feed.
@MainActor
final class PortPowerSource: ObservableObject {

    /// spec §2.1 (T10, O2): the `kern.osversion` string `PowerOutDetails` was last seen on.
    static let seenOnBuildKey = "portPower.seenOnBuild.v1"

    // MARK: seams
    private let defaults: UserDefaults
    private let now: () -> Date
    private let clocks: MonotonicClocks
    private let usb: any USBLeafEnumerating
    private let currentBuild: String

    // MARK: state for stages 4–5 (read-only outside; NOT published at stage 3)

    /// Three states (§3.1). `.unread` after a failed or malformed read — never the last rows again.
    private(set) var reading: PortPowerReading = .notYetRead
    /// `PowerOutDetails` has been reported at least once on THIS OS build (section gate, §2.1).
    private(set) var seenOnThisBuild: Bool
    /// The latest successful read's `ExternalConnected` (nil = unread → no cost line, no band, §3.5).
    private(set) var externalConnected: Bool?
    /// The latest successful read's `UpdateTime` (epoch s) — stage 4's "as of" label, stage 5's latch.
    private(set) var updateTime: Int?
    /// Ports drawing per the 0.5 W / 0.3 W hysteresis on the latest successful read.
    private(set) var drawingPortIndices: Set<Int> = []
    /// Sum of the drawing ports' `FilteredPower`, W (unrounded; stage 4 rounds for display).
    private(set) var drawingWatts: Double = 0
    /// Per `PortIndex`, the current sourcing episode (ended by an absent successful read).
    private(set) var episodes: [Int: PortEpisode] = [:]
    /// Ports whose FIRST drawing read of their episode is the latest read. For stage 4 naming ONLY: it also
    /// fires on the first (seed) read for a device that was already plugged in, so it must not drive a notice
    /// (stage 5's notice has its own latch).
    private(set) var newlyDrawingPortIndices: Set<Int> = []
    /// `monotonicRaw` of the first SUCCESSFUL read since launch (the seed).
    private(set) var launchSeedAt: TimeInterval?
    /// Both clocks as sampled on the latest ingest, successful or not.
    private(set) var lastClocks: (monotonicRaw: TimeInterval, uptimeRaw: TimeInterval)?
    /// Accumulator-averaged pack power P, mW (+ = gaining), over the last two distinct same-source frames.
    private(set) var packPower_mW: Double?
    /// On AC: the §2.1 band (held with hysteresis). `.none` on battery or when anything is unread.
    private(set) var band: OnPowerBand = .none
    /// On battery: the §2.1 cost line. nil on AC or when anything is unread.
    private(set) var costLine: BatteryCostLine?

    // MARK: private working state
    private var hysteresis = PortPowerHysteresis()
    private var bandState = OnPowerBandState()
    private var lastPresentAt: [Int: TimeInterval] = [:]
    private var previousFrame: PowerTelemetry?
    private var currentFrame: PowerTelemetry?
    private var pairSource: Bool?

    init(defaults: UserDefaults, now: @escaping () -> Date, clocks: MonotonicClocks,
         usb: any USBLeafEnumerating, osBuild: @escaping () -> String) {
        self.defaults = defaults
        self.now = now
        self.clocks = clocks
        self.usb = usb
        let build = osBuild()
        self.currentBuild = build
        self.seenOnThisBuild = !build.isEmpty && defaults.string(forKey: Self.seenOnBuildKey) == build
    }

    /// `kern.osversion` (e.g. "26B5091g"); "" when unreadable — which never marks the key.
    nonisolated static func liveOSBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Called synchronously by the monitor's subscriber tap on EVERY diagnostics read (spec §2.2).
    func ingest(_ read: DiagnosticsRead) {
        let tick = (monotonicRaw: clocks.monotonicRaw(), uptimeRaw: clocks.uptimeRaw())
        lastClocks = tick
        newlyDrawingPortIndices = []
        guard case .read(let props) = read, !PortPowerParser.portsKeyIsMalformed(props) else {
            // §3.1: a failed (or unparseable) read is `.unread` — no rows, no claims — and carries NO
            // information: hysteresis, episodes and the telemetry pair are left exactly as they were.
            reading = .unread
            packPower_mW = nil
            band = .none
            costLine = nil
            publishDisplay()   // stage 4: "couldn't read ports", never stale rows
            return
        }
        if launchSeedAt == nil { launchSeedAt = tick.monotonicRaw }
        let ports = PortPowerParser.ports(props)
        if props[PortPowerParser.portsKey] != nil { markSeenOnThisBuild() }
        reading = .read(ports)
        updateTime = PortPowerParser.updateTime(props)
        trackPorts(ports, at: tick.monotonicRaw)
        let connected = PortPowerParser.externalConnected(props)
        externalConnected = connected
        let telemetry = PortPowerParser.telemetry(props)
        advancePair(telemetry, externalConnected: connected)
        derive(props: props, telemetry: telemetry, externalConnected: connected)
        // A raw element the parser dropped (bad or repeated) may be a port that is really present (§1.3 hold).
        let rawCount = (props[PortPowerParser.portsKey] as? [Any])?.count ?? 0
        updateNames(droppedAnElement: rawCount > ports.count)   // stage 4: one IOUSB walk + corroborated names (G-7)
        feedLatch(props, droppedAnElement: rawCount > ports.count)   // stage 5 (after the names: the notice uses them)
        publishDisplay()                                        // stage 4: one rounded display per read (G-2)
    }

    // MARK: - steps

    private func markSeenOnThisBuild() {
        guard !seenOnThisBuild, !currentBuild.isEmpty else { return }
        defaults.set(currentBuild, forKey: Self.seenOnBuildKey)
        seenOnThisBuild = true
    }

    private func trackPorts(_ ports: [PortPower], at t: TimeInterval) {
        let present = Set(ports.map(\.portIndex))
        episodes = episodes.filter { present.contains($0.key) }   // absent on a good read → episode over
        hysteresis.retain(only: present)
        var drawing: Set<Int> = []
        for port in ports {
            var episode = episodes[port.portIndex]
                ?? PortEpisode(startedAt: t, previousPresentAt: lastPresentAt[port.portIndex], firstDrawingAt: nil)
            if hysteresis.isDrawing(portIndex: port.portIndex, filteredPower_mW: port.filteredPower_mW) {
                drawing.insert(port.portIndex)
                if episode.firstDrawingAt == nil {
                    episode.firstDrawingAt = t
                    newlyDrawingPortIndices.insert(port.portIndex)
                }
            }
            episodes[port.portIndex] = episode
            lastPresentAt[port.portIndex] = t
        }
        drawingPortIndices = drawing
        drawingWatts = PortPowerMath.portWatts(ports.filter { drawing.contains($0.portIndex) })
    }

    /// The last two DISTINCT frames on ONE power source (§2.1). An UNREAD `ExternalConnected` (nil) drops the
    /// frame pair (that frame's source is unknown) but touches neither `bandState` nor `pairSource`: an unread
    /// flag is not a power-source or ceiling change, so the held band survives it. A READ flag that differs
    /// from `pairSource` drops the pair, resets `bandState` and sets `pairSource`.
    /// A frame whose accumulator counts equal the current frame's is a repeat, not a new frame.
    private func advancePair(_ frame: PowerTelemetry?, externalConnected connected: Bool?) {
        guard let connected else {
            previousFrame = nil
            currentFrame = nil
            return
        }
        if connected != pairSource {
            previousFrame = nil
            currentFrame = nil
            bandState = OnPowerBandState()
            pairSource = connected
        }
        guard let frame else { return }
        if let current = currentFrame,
           current.cntBatteryPower == frame.cntBatteryPower,
           current.cntBatteryDischarge == frame.cntBatteryDischarge { return }
        previousFrame = currentFrame
        currentFrame = frame
    }

    private func derive(props: [String: Any], telemetry: PowerTelemetry?, externalConnected connected: Bool?) {
        if telemetry != nil, let previous = previousFrame, let current = currentFrame {
            packPower_mW = PackPowerAverager.averaged_mW(previous: previous, current: current)
        } else {
            packPower_mW = nil   // this read's telemetry is unread → no claim from it (§3.3)
        }
        switch connected {
        case true?:
            band = bandState.update(
                systemPowerIn_mW: PortPowerMath.systemPowerIn(telemetry, externalConnected: connected),
                ceiling_mW: PortPowerParser.inputCeiling_mW(props),
                packPower_mW: packPower_mW,
                portWatts: drawingWatts)
            costLine = nil
        case false?:
            band = .none
            costLine = BatteryCost.line(portWatts: drawingWatts, packPower_mW: packPower_mW,
                                        remaining_mAh: PortPowerParser.remainingCapacity_mAh(props),
                                        fullCharge_mAh: PortPowerParser.fullChargeCapacity_mAh(props),
                                        bankCount: PortPowerParser.bankCount(props))
        case nil:
            band = .none
            costLine = nil
        }
    }

    // MARK: - stage 4 · names + the display (31 §1.3, §2.1, G-2, G-5, G-7)

    /// The section as the Devices page prints it: derived and rounded, so it changes only when what the page
    /// shows changes (G-2). Observed ONLY by DevicesPage; the popover root holds the source as a plain `let`
    /// (spec §3 rule 7).
    @Published private(set) var display: PortPowerDisplay = .hidden
    private var stamps = LeafStamps()
    /// Corroborated names per PortIndex, kept until the port goes absent (§1.3). Read by the notice (stage 5).
    private(set) var names: [Int: PortName] = [:]
    /// The leaf a timing-matched name came from (phone-corroborated names have none).
    private var claimedLeaf: [Int: LeafClaim] = [:]
    /// Names of ports that went missing on a read that ALSO carried an unparseable element (S3.4 review M3):
    /// the port may only look absent. Restored on the very next good read if the port is back and the same
    /// leaf is still on the bus; dropped otherwise. Never outlives one good read.
    private var heldNames: [Int: (name: PortName, leaf: LeafClaim)] = [:]
    private var phone: PhoneLink?
    /// The ports whose current name came from (b), so a link that is gone or says not USB-powered, or an unplug,
    /// can take them back. (c) names are never in this set.
    private var phoneNamedPorts: Set<Int> = []
    /// `readAt` of the reading that gave the current (b) name (nil while (b) names nothing). Final review I1: the
    /// freshness and after-unplug gates apply to this FIRST naming only; the name then stands until the port
    /// goes absent, the link is cleared, a newer reading says not USB-powered, or any port unplug lands after it.
    private var phoneNamingReadAt: TimeInterval?
    /// Owner hub fix (2026-09-29): whether the latest SUCCESSFUL per-read walk showed a `.iphone` leaf (Apple
    /// vendor required, `USBLeafFilter.kind`). The presence witness for (b) and the display's phone details: a
    /// powered hub or a same-port swap keeps the port present and drawing after the iPhone leaves, but not its
    /// leaf. False until a walk succeeds; a failed walk (nil) leaves it as it was.
    private var iPhoneOnBus = false
    /// `monotonicRaw` of the latest good read on which ANY port went absent — named or not, phone or not. A port
    /// is absent when it was present on the previous GOOD read and is not on this one; an `.unread` read never
    /// sets this and is skipped by the comparison. Whatever came off may have been the phone (an unnamed port can
    /// be the iPhone too), so a phone reading that STARTED at or before this says nothing about which port the
    /// phone is on now: (b) and the display ignore it until the Devices page's next sync reading. Cost: at most
    /// a lost name (the row reads "USB-C device"), never a false one.
    private var portUnplugAt: TimeInterval?
    /// The ports present on the previous GOOD read (the baseline for `portUnplugAt`).
    private var lastGoodPresent: Set<Int> = []

    /// What identifies a claimed leaf: its registry id, and its product + vendor (a device that blips off the
    /// bus comes back under a NEW id but is still the same device).
    private struct LeafClaim: Equatable {
        let id: UInt64
        let product: String
        let vendor: String?
        init(_ leaf: USBLeaf) { id = leaf.registryID; product = leaf.productName; vendor = leaf.vendorName }
    }

    /// Corroboration (b)'s phone half, from the Devices page's sync reading. nil clears it.
    func notePhone(_ link: PhoneLink?) {
        phone = link
        applyPhoneCorroboration(at: clocks.monotonicRaw())
        publishDisplay()
    }

    /// The Devices page's walk (§3.7): a timing-matched name whose leaf has left the bus is dropped. A failed
    /// walk (nil) is no information and changes nothing; an empty walk is treated the same way.
    func refreshLeaves() {
        guard let walk = usb.leaves() else { return }
        let onBus = Set(walk.map(\.registryID))
        guard !onBus.isEmpty else { return }
        let gone = claimedLeaf.filter { !onBus.contains($0.value.id) }.map(\.key)
        guard !gone.isEmpty else { return }
        for port in gone {
            names[port] = nil
            claimedLeaf[port] = nil
        }
        publishDisplay()
    }

    private var presentPortIndices: Set<Int> {
        guard case .read(let ports) = reading else { return [] }
        return Set(ports.map(\.portIndex))
    }

    /// Once per successful read, after stage 3 updated this read's state: forget names of absent ports,
    /// stamp the leaves (one IOUSB walk, G-7), try the timing match for a single newly drawing port, then (b).
    /// The stamps use the SAME monotonic instant stage 3 stamped this read's episodes with.
    private func updateNames(droppedAnElement: Bool) {
        guard case .read = reading, let clocks = lastClocks else { return }
        let present = presentPortIndices
        if !lastGoodPresent.isSubset(of: present) { portUnplugAt = clocks.monotonicRaw }   // any port went absent
        lastGoodPresent = present
        // A failed walk (nil) is no information (final review M1): no seed, no stamps, no timing match, and a
        // held name cannot be confirmed (so it is dropped: a lost name, never a false one).
        let walk = usb.leaves()
        let leaves = walk ?? []
        let onBus = Set(leaves.map(\.registryID))
        let held = heldNames
        heldNames = [:]
        for port in Array(names.keys) where !present.contains(port) {
            if droppedAnElement, let name = names[port], let leaf = claimedLeaf[port] {
                heldNames[port] = (name, leaf)
            }
            names[port] = nil
            claimedLeaf[port] = nil
            phoneNamedPorts.remove(port)
        }
        for (port, hold) in held where present.contains(port) && names[port] == nil && onBus.contains(hold.leaf.id)
            && !claimedLeaf.values.contains(where: { $0.id == hold.leaf.id }) {
            names[port] = hold.name
            claimedLeaf[port] = hold.leaf
        }
        if let walk {
            stamps.observe(walk, at: clocks.monotonicRaw)
            iPhoneOnBus = walk.contains { $0.kind == .iphone }
        }
        let newly = newlyDrawingPortIndices
        if walk != nil, newly.count == 1, let port = newly.first, names[port] == nil,
           let episode = episodes[port], let firstDrawing = episode.firstDrawingAt {
            // A leaf held for a port that only looks absent is still that port's: never hand it to another.
            let claims = Array(claimedLeaf.values) + heldNames.values.map(\.leaf)
            let candidates = leaves.filter { leaf in !claims.contains { $0.id == leaf.registryID } }
            // A re-enumerated copy of a claimed device (same product + vendor, NEW id) is ambiguous: it may be the
            // same device blipping or a second unit, and a lone match to it must not name this port. (With two
            // fresh leaves `timingMatch` already refuses.)
            if let leaf = DeviceNaming.timingMatch(stamps: stamps,
                                                   leaves: candidates,
                                                   portLastPresentAt: episode.previousPresentAt ?? launchSeedAt,
                                                   portFirstDrawingAt: firstDrawing,
                                                   newlySourcingPortCount: newly.count),
               !claims.contains(where: { $0.product == leaf.productName && $0.vendor == leaf.vendorName }) {
                names[port] = PortName(leaf: leaf)
                claimedLeaf[port] = LeafClaim(leaf)
            }
        }
        applyPhoneCorroboration(at: clocks.monotonicRaw)
    }

    /// The link, only while the reading it carries is fresh at `instant` (STARTED ≤ `DeviceNaming.window` ago)
    /// and started after any port last went absent (`portUnplugAt`): what the FIRST (b) naming of a port trusts.
    /// The time is the READING's (`readAt`), never the time `notePhone` was called — the page re-notes an old
    /// reading on every open and beacon update. An unknown `readAt` never corroborates.
    private func freshPhone(at instant: TimeInterval) -> PhoneLink? {
        guard let phone = currentPhone, let readAt = phone.readAt, instant - readAt <= DeviceNaming.window else { return nil }
        return phone
    }

    /// The link whose reading started after any port last went absent — no age limit (final review I1) — and
    /// only while the latest successful walk shows an iPhone on the USB bus (owner hub fix). The display's phone
    /// details (percent, charging, the port-unknown row) come from it: the Devices page re-syncs on every open,
    /// so what it shows is at most one page-open old. An unknown `readAt` is never trusted.
    private var currentPhone: PhoneLink? {
        guard iPhoneOnBus, let phone, let readAt = phone.readAt else { return nil }
        if let unplugged = portUnplugAt, readAt <= unplugged { return nil }
        return phone
    }

    /// Whether the name (b) already gave still stands (final review I1, spec §1.3 "reused until the port goes
    /// absent" — the absent port itself is cleared in `updateNames`). It falls when the link is cleared, when any
    /// port went absent at or after the naming reading started (the phone may have moved: the guard that stops
    /// the Watch-charger false name), or when a reading NOT known to be older than the naming one says the phone
    /// is not USB-powered (an unknown `readAt` counts as newer: the cost is a lost name, never a false one).
    /// Owner hub fix: it also falls on the first successful walk with no iPhone leaf on the bus.
    private var phoneNameStands: Bool {
        guard iPhoneOnBus, let phone, let namedAt = phoneNamingReadAt else { return false }
        if let unplugged = portUnplugAt, unplugged >= namedAt { return false }
        if !phone.usbPowered {
            guard let readAt = phone.readAt, readAt <= namedAt else { return false }
        }
        return true
    }

    /// (b): an iPhone confirmed by MobileDevice over USB with ExternalConnected while exactly one port is
    /// SOURCING (present and drawing). The FIRST naming needs a link at most `window` old whose reading started
    /// after the last time any port went absent, and an iPhone leaf on the bus; once given, the name stays while
    /// `phoneNameStands`. (c) names are never touched and (b) never overrides one.
    private func applyPhoneCorroboration(at instant: TimeInterval) {
        if !phoneNamedPorts.isEmpty, !phoneNameStands {
            for port in phoneNamedPorts where names[port]?.kind == .iphone && claimedLeaf[port] == nil { names[port] = nil }
            phoneNamedPorts = []
        }
        if phoneNamedPorts.isEmpty { phoneNamingReadAt = nil }
        guard let fresh = freshPhone(at: instant), fresh.usbPowered, let readAt = fresh.readAt else { return }
        guard !names.values.contains(where: { $0.kind == .iphone }) else { return }
        let present = presentPortIndices
        guard present.count == 1, drawingPortIndices == present, let port = present.first, names[port] == nil else { return }
        names[port] = PortName(name: "iPhone", kind: .iphone)
        phoneNamedPorts.insert(port)
        phoneNamingReadAt = readAt
    }

    // MARK: - stage 5 · the plug-in notice (31 §2.2, G-4)

    /// Called synchronously inside `ingest` when a port goes absent → drawing; the array holds ONE aggregated
    /// notice. Tracked on AC too — the HUD wiring (S5.4's predicate) decides the SHOWING, so nothing here reads
    /// the power source except to refuse a read that did not say what it was.
    var onDeviceNotice: (@MainActor ([DeviceNotice]) -> Void)?
    private var latch = DeviceNoticeLatch()

    /// Feed the latch from THIS read (never from the published display). A read carries NO information for the
    /// latch — `ports: nil`, which changes nothing in it — when `ExternalConnected` is unread (§3 rule 5: the
    /// source it was taken on is unknown, so it may not drive a claim) or when the parser dropped an element
    /// (that element may be a port that is really present, so the read's absences are not facts: the same
    /// reason `updateNames` holds a name across such a read). A failed read never reaches here.
    /// Names are `names` as this read's `updateNames` left them — the very ones the rows show; an unnamed port
    /// passes nil and the composer falls back to the unnamed label. No fire-time walk, no MobileDevice session.
    private func feedLatch(_ props: [String: Any], droppedAnElement: Bool) {
        guard case .read(let ports) = reading, let clocks = lastClocks else { return }
        let powers = Dictionary(ports.map { ($0.portIndex, $0.filteredPower_mW) }, uniquingKeysWith: { first, _ in first })
        let informative = externalConnected != nil && !droppedAnElement
        let fired = latch.ingest(DeviceLatchRead(ports: informative ? powers : nil,
                                                 updateTime: updateTime,
                                                 monotonicRaw: clocks.monotonicRaw,
                                                 uptimeRaw: clocks.uptimeRaw))
        guard !fired.isEmpty else { return }
        let firedPorts = fired.compactMap { index -> DeviceNoticePort? in
            guard let mW = powers[index] else { return nil }
            return DeviceNoticePort(name: names[index]?.name, kind: names[index]?.kind, filteredPower_mW: mW)
        }
        // X for the device(s) that just started (the fired ports' watts). The Devices cost line rates ALL drawing
        // devices, so the two agree only when every drawing port fired; the arithmetic is the same (`BatteryCost`).
        let watts = PortPowerMath.portWatts(ports.filter { fired.contains($0.portIndex) })
        let perHour = PortPowerDisplayModel.percentPerHour(portWatts: watts,
                                                           fullCharge_mAh: PortPowerParser.fullChargeCapacity_mAh(props),
                                                           bankCount: PortPowerParser.bankCount(props))
        guard let notice = DeviceNoticeComposer.compose(firedPorts, percentPerHour: perHour) else { return }
        onDeviceNotice?([notice])
    }

    private func publishDisplay() {
        let next = PortPowerDisplayModel.build(PortPowerDisplayInput(
            everSeen: seenOnThisBuild, reading: reading, drawing: drawingPortIndices, names: names,
            phone: currentPhone,
            onBattery: externalConnected.map { !$0 }, band: band, cost: costLine,
            updateTime: updateTime, now: now()))
        if next != display { display = next }
    }
}
