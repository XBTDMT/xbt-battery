import Foundation
import AppKit
import IOKit.ps
import Shared   // WakeBehaviorReadback (the read-back seam's value type)

// #30 R15 parity harness — FIXTURE seams. App-side, argument-gated (`RenderHarness.runIfRequested`);
// nothing here is reachable in a normal launch. Every fake is a minimal in-memory stand-in for one
// injectable seam, shaped after the test target's fakes (which this file must NOT import). The numbers
// are the FINAL mockup's (knowledge/30-redesign-FINAL-spec.html): 32 % on battery at 13:21, −27.8 W,
// limit 80 as set, the 07:30/12:00/18:00/22:00 schedule, sleep 23:30 / wake 06:45 Mon–Fri, and so on.

// MARK: - the fixture clock

enum RenderFixtureClock {
    /// The mockup's moment: 2026-09-09 13:21 local.
    static let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 9; c.hour = 13; c.minute = 21
        return Calendar.current.date(from: c) ?? Date()
    }()
    static var epoch: Int { Int(now.timeIntervalSince1970) }
    static func at(hour: Int, minute: Int, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!
        return cal.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
    }
}

// MARK: - the fixture axis (spec 31 §2.5)

/// The harness's fixture column. `.parity` is the mockups' state (the six PNGs parity.sh pairs); the
/// worst cases drive the graph's REAL controllers into the states the clip gate must see; `.selfTest`
/// renders the harness's own self-test pages (no fixture graph).
enum RenderFixture: String, CaseIterable {
    case parity
    case nowWorst = "now-worst"
    case nowLongLead = "now-longlead"
    case automationWorst = "automation-worst"
    case automationKeepAwake = "automation-keepawake"
    /// 31 stage 4 · Devices "Powered by this Mac": the option-1 pair (paired in parity.sh), the worst case, and
    /// the unread state (a malformed PowerOutDetails after a good one → "couldn't read ports").
    case poweredOnPower = "powered-on-power"
    case poweredOnBattery = "powered-on-battery"
    case poweredWorst = "powered-worst"
    /// The worst case plus the two production inputs `powered-worst` cannot show: the longest real adapter reason
    /// (two lines) and a phone note (a thin row under the wireless card).
    case poweredWorstNotes = "powered-worst-notes"
    /// `powered-worst-notes` with a CONNECTED adapter (no adapter warning): the wireless notes fold (owner ruling
    /// 2026-09-29) and cost no row, so the adapter fold's saving gives the list its most rows on this crowded page.
    case poweredWorstNotesAdapterOK = "powered-worst-notes-adapter-ok"
    /// Both wireless notes, a CONNECTED adapter, ONE named wired row on battery (two-line cost line, no overflow, no
    /// caption) and SIX wireless devices: the page where the round-5 zero-cost fold line left the adapter grid
    /// unfolded and overflowed (S4.8 fix round 6 — the fold decision counts the line as one row).
    case poweredNotesSinglePort = "powered-notes-single-port"
    case poweredUnread = "powered-unread"
    /// Spec 30 §16 "32 · Health · history note": the parity state plus two unreadable month files that
    /// maintenance names — the LONGEST note copy ("History for September 2025 and December 2025 couldn't
    /// be read — it's kept as is.", two lines), so the clip gate covers the note at its worst. The two
    /// months (2025-09, 2025-12) hold no fixture hours, so every Health figure is the parity figure.
    case healthHistoryNote = "history-note"
    case selfTest = "selftest"
    /// Public-release images only (`--render-showcase`, `RenderShowcase.swift`) — NOT a gated variant: no
    /// `variants` entry and no `PageGate.expected` row, so `--render-pages` never builds it. The parity state
    /// with the verified read-back (the Get shortcut present and answering) instead of `.readyDegraded`.
    case showcase
    /// Public-release images only, like `.showcase`: the `.showcase` state with the gated `powered-on-battery`
    /// devices on cables, fed Now's 64 % and 91 min. Its remaining charge (3,641 mAh) is chosen so the Devices cost
    /// line's nominal-voltage math lands on Now's 91 min — it is not 64 % of the 5,435 mAh capacity (≈ 3,480).
    /// Not a gated variant; the gated powered pair is untouched.
    case showcasePowered = "showcase-powered"

    /// The two public-release fixtures (never gated): the calmer history, the verified read-back, 64 %.
    var isShowcase: Bool { self == .showcase || self == .showcasePowered }

    var isWorstCase: Bool {
        switch self {
        case .nowWorst, .nowLongLead, .automationWorst, .automationKeepAwake: true
        case .parity, .selfTest, .showcase, .showcasePowered, .poweredOnPower, .poweredOnBattery, .poweredWorst, .poweredWorstNotes, .poweredWorstNotesAdapterOK,
             .poweredNotesSinglePort, .poweredUnread, .healthHistoryNote: false
        }
    }

    /// The two fixtures with the wireless card's own note and a phone note (the folded pair).
    var hasWirelessNotes: Bool {
        self == .poweredWorstNotes || self == .poweredWorstNotesAdapterOK || self == .poweredNotesSinglePort
    }

    var isAutomationWorstCase: Bool { self == .automationWorst || self == .automationKeepAwake }
}

// MARK: - battery telemetry (BatteryMonitor)

final class FixturePowerSourceReader: PowerSourceReading {
    /// The mockup's 32 % / 38 min; the `.showcase` fixture passes its own (64 % / 91 min, see `RenderFixtureHistory`).
    let soc: Int
    let timeToEmpty: Int
    init(soc: Int = 32, timeToEmpty: Int = 38) { self.soc = soc; self.timeToEmpty = timeToEmpty }
    func readLiveDescription() -> [String: Any]? {
        [kIOPSCurrentCapacityKey: soc, kIOPSIsChargingKey: false,
         kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSTimeToEmptyKey: timeToEmpty]
    }
    func readDiagnosticsProperties() -> [String: Any]? { RenderFixtureLifetime.props }
    func startLiveUpdates(onChange: @escaping () -> Void) {}
    func stopLiveUpdates() {}
}

struct FixtureEnergyModeReader: EnergyModeReading {
    func readEnergyMode() -> EnergyMode { .automatic }
}

/// The AppleSmartBattery property dict every parser in the app reads (macOS 27 layout: raw mAh in the
/// nested `BatteryData`, `LifetimeData` under it; `PermanentFailureStatus` 0 → "Normal").
enum RenderFixtureLifetime {
    static var props: [String: Any] { [
        "CycleCount": 525,
        "AppleRawMaxCapacity": 5435,
        "DesignCapacity": 6249,
        "Voltage": 12100,
        "InstantAmperage": -2300,
        "Amperage": -2300,
        "PermanentFailureStatus": 0,
        "ExternalConnected": false,
        "BatteryData": [
            "DesignCapacity": 6249,
            "AppleRawMaxCapacity": 5435,
            "FullChargeCapacity": 5435,
            "NominalChargeCapacity": 5435,
            "DailyMinSoc": 1,
            "DailyMaxSoc": 80,
            "LifetimeData": [
                "MinimumTemperature": 9,
                "MaximumTemperature": 46,
                "AverageTemperature": 260,
                "MinimumPackVoltage": 8995,
                "MaximumPackVoltage": 13306,
                "MaximumChargeCurrent": 6816,
                "MaximumDischargeCurrent": -8970,
            ] as [String: Any],
        ] as [String: Any],
    ] }
}

final class FixtureLifetimeReader: BatteryLifetimeReading {
    func readDetailed() -> Result<BatteryLifetime, BatteryLifetimeReadFailure> {
        BatteryLifetimeParser.parse(RenderFixtureLifetime.props)
    }
}

final class FixtureAdapterReader: PowerAdapterReading {
    private let state: PowerAdapterReadState
    init(state: PowerAdapterReadState = .noAdapter) { self.state = state }
    func readDetailed() -> PowerAdapterReadState { state }
}

// MARK: - charge control (engine / setup / schedule / top-up)

/// Sets succeed silently; `list` reports the five Set shortcuts and NOT the Get one → `.readyDegraded`,
/// the only state in which the hero's Limit row carries the "· as set" custody tag.
/// `readBack` (the `.showcase` fixture only, never a gated variant): `list` ALSO reports the Get shortcut
/// → `.ready`, and Get answers the custody value (80), so a read-back succeeds — the verified mode.
struct FixtureShortcutRunner: ShortcutRunning {
    var readBack = false
    func run(name: String, outputPath: String?) async -> ShortcutRunOutcome {
        .success(stdout: readBack && name == ChargeShortcuts.get ? "80" : "")
    }
    func list() async -> ShortcutRunOutcome {
        let sets = ChargeShortcuts.validLimitValues.map(ChargeShortcuts.setName(for:))
        return .success(stdout: (readBack ? sets + [ChargeShortcuts.get] : sets).joined(separator: "\n"))
    }
}

struct FixturePauseCaptureStore: PauseCaptureStoring {
    func load() -> PauseCapture? { nil }
    func loadDetailed() -> PauseCaptureLoad { .none }
    func save(_ capture: PauseCapture) {}
    func clear() {}
}

struct FixtureCustodyStore: LastSetCustodyStoring {
    func load() -> LastSetCustody? {
        LastSetCustody(value: 80, at: RenderFixtureClock.now.addingTimeInterval(-3600))
    }
    func save(_ c: LastSetCustody) {}
}

struct FixtureTopUpStore: TopUpStoring {
    func load() -> TopUpState? { nil }
    func save(_ s: TopUpState) {}
    func clear() {}
}

struct FixtureScheduleClock: ScheduleClock {
    func now() -> Date { RenderFixtureClock.now }
}

@MainActor final class FixtureSchedulePacer: SchedulePacing {
    func start(interval: TimeInterval, onTick: @escaping () -> Void) {}
    func stop() {}
}

/// 07:30→100 · 12:00→90 · 18:00→95 · 22:00→80, enabled; the two morning rules fired today.
final class FixtureScheduleStore: ScheduleStoring, @unchecked Sendable {
    static let ruleIDs = (0..<4).map { i in UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i + 1)")! }
    static let config: ChargeScheduleConfig = {
        var c = ChargeScheduleConfig()
        c.enabled = true
        c.rules = [ChargeRule(id: ruleIDs[0], hour: 7, minute: 30, limit: 100),
                   ChargeRule(id: ruleIDs[1], hour: 12, minute: 0, limit: 90),
                   ChargeRule(id: ruleIDs[2], hour: 18, minute: 0, limit: 95),
                   ChargeRule(id: ruleIDs[3], hour: 22, minute: 0, limit: 80)]
        return c
    }()
    func loadConfig() -> ChargeScheduleConfig { Self.config }
    func saveConfig(_ c: ChargeScheduleConfig) {}
    func loadFired() -> Set<FiredOccurrence> {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: RenderFixtureClock.now)
        return [FiredOccurrence(ruleID: Self.ruleIDs[0], dayKey: day),
                FiredOccurrence(ruleID: Self.ruleIDs[1], dayKey: day)]
    }
    func saveFired(_ f: Set<FiredOccurrence>) {}
}

// MARK: - energy (snapshot ranking, sustained, rails)

/// Two sweeps: the first all-zero, the second carrying the mockup's shares — Safari 38 · Photos 24 ·
/// Mail 17 · python3 9 · Music 5 of a total that leaves a 7 % remainder (seven 1 % fillers). G-12: apps that
/// ship with every Mac (the mockup's Ghostty / Chrome / Xcode / Spotify are third-party installs), so the renders
/// reproduce on a clean Mac and carry no third-party logos.
struct FixtureEnergySampler: ProcessEnergySampling {
    static let named: [(pid: Int, name: String, share: UInt64)] = [
        (4001, "Safari", 38), (4002, "Photos", 24), (4003, "Mail", 17), (4004, "python3", 9), (4005, "Music", 5),
    ]
    static let fillers: [(pid: Int, name: String)] = (0..<7).map { (4101 + $0, "filler\($0)") }
    private let counter = FixtureCounter()

    func sample() async -> ProcessEnergySample {
        let n = counter.next()
        var energy: [Int: UInt64] = [:]
        for row in Self.named { energy[row.pid] = n == 0 ? 0 : row.share * 1_000_000_000 }
        for f in Self.fillers { energy[f.pid] = n == 0 ? 0 : 1_000_000_000 }
        let cov = ProcessEnergyCoverage(listed: energy.count, readable: energy.count, denied: 0, vanished: 0)
        return ProcessEnergySample(energyNanojoules: energy, coverage: cov)
    }
    func commandName(forPID pid: Int) -> String? {
        Self.named.first { $0.pid == pid }?.name ?? Self.fillers.first { $0.pid == pid }?.name
    }
}

final class FixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n += 1; return v }
}

struct FixtureNameResolver: AppNameResolving {
    func localizedName(forPID pid: Int) -> String? { FixtureEnergySampler.named.first { $0.pid == pid }?.name }
}

/// REAL icons for the fixture pids, loaded via NSWorkspace from apps the OS itself installs (never a running
/// process, never a third-party install — G-12). Safari is the one not under /System/Applications: since macOS 13
/// the OS ships it in the Safari cryptex, and `/Applications/Safari.app` is the system's own link to it.
final class FixtureAppIconProvider: AppIconProviding {
    static let apps: [Int: String] = [
        4001: "/Applications/Safari.app",
        4002: "/System/Applications/Photos.app",
        4003: "/System/Applications/Mail.app",
        4004: "/System/Applications/Utilities/Terminal.app",
        4005: "/System/Applications/Music.app",
    ]
    func icon(forPID pid: Int) -> NSImage? {
        guard let path = Self.apps[pid], FileManager.default.fileExists(atPath: path) else { return nil }
        // Resolve the link first: `icon(forFile:)` on a symlink draws Finder's alias badge on the icon.
        return NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }
    /// Only OS-installed apps: a bundle id that resolves to a third-party install draws no icon.
    func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              url.path.hasPrefix("/System/") || Self.apps.values.contains(url.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Fixture pids are not live processes: no executable path, so identity falls to the pid icon above / the
/// daemon table (python3 → `terminal`) and never to a real process that happens to own the pid today.
struct FixtureProcessPathProvider: ProcessPathProviding {
    func executablePath(forPID pid: Int) -> String? { nil }
    func responsiblePID(forPID pid: Int) -> Int? { nil }
}

/// The helper is not consulted: the sustained ranking reports unavailable (the strip's switch disables).
@MainActor final class FixtureTaskEnergyCollector: TaskEnergyCollecting {
    func collectTaskEnergy(samples: Int, intervalMs: Int,
                           completion: @escaping @Sendable (Result<Data, HelperClientError>) -> Void) {
        completion(.failure(.unreachable))
    }
}

/// One live rail: 8.4 J over the 2 s probe → "GPU 4.2 W · modeled · only live rail".
struct FixtureComponentPowerSampler: ComponentPowerSampling {
    func sampleEnergyDeltas(intervalSeconds: Double) -> [RawRailDelta]? {
        [RawRailDelta(name: "GPU Energy", unit: "mJ", deltaValue: Int64(4.2 * intervalSeconds * 1000))]
    }
}

// MARK: - privileged seams (never reached: no helper, no XPC)

@MainActor final class FixtureEnergyModeSetter: EnergyModeSetter {
    func setEnergyMode(mode: Int, source: Int,
                       completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
        completion(.success("ok"))
    }
}

@MainActor final class FixtureSleepWakeSetter: SleepWakeSetter {
    /// `.failure(.unreachable)` gives the Automation worst cases their one sleep/wake status line.
    let result: Result<String, HelperClientError>
    init(result: Result<String, HelperClientError> = .success("ok")) { self.result = result }

    func setRepeatingSleepWake(sleepEnabled: Bool, sleepHour: Int, sleepMinute: Int,
                               wakeEnabled: Bool, wakeHour: Int, wakeMinute: Int, weekdayMask: Int,
                               completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
        completion(result)
    }
}

@MainActor final class FixtureWakeBehaviorSetter: WakeBehaviorSetter {
    func setWakeBehavior(powerNapBattery: Bool, powerNapAC: Bool, wakeOnNetworkBattery: Bool, wakeOnNetworkAC: Bool,
                         completion: @escaping @Sendable (Result<String, HelperClientError>) -> Void) {
        completion(.success("ok"))
    }
}

struct FixtureWakeBehaviorReader: WakeBehaviorReading {
    func readCurrent() -> WakeBehaviorReadback.State? { nil }
}

// MARK: - sleep / wake schedule (authored: sleep 23:30 · wake 06:45 · Mon–Fri)

struct FixtureSleepWakeStore: SleepWakeScheduleStoring {
    static let config: SleepWakeScheduleConfig = {
        var c = SleepWakeScheduleConfig()
        c.sleepEnabled = true; c.sleepHour = 23; c.sleepMinute = 30
        c.wakeEnabled = true; c.wakeHour = 6; c.wakeMinute = 45
        c.weekdayMask = 31
        return c
    }()
    func loadConfigDetailed() -> SleepWakeConfigLoad { .config(Self.config) }
    func loadConfig() -> SleepWakeScheduleConfig { Self.config }
    func saveConfig(_ c: SleepWakeScheduleConfig) {}
}

struct FixtureSleepScheduleReader: SleepScheduleReading {
    func readRepeatingSchedule() -> RepeatingSchedule? {
        RepeatingSchedule(events: [
            RepeatingPowerEvent(kind: .sleep, minuteOfDay: 23 * 60 + 30, weekdayMask: 31),
            RepeatingPowerEvent(kind: .wake, minuteOfDay: 6 * 60 + 45, weekdayMask: 31),
        ])
    }
}

// MARK: - keep-awake (off, last preset 1 h; two foreign holders)

final class FixtureSleepAssertion: SleepAssertion {
    func create(_ kind: SleepAssertionKind, name: String) -> UInt32? { 1 }
    func release(_ id: UInt32) {}
}

struct FixtureSleepTimerReader: SleepTimerReading {
    func readSleepTimers() -> SleepTimerSettings {
        SleepTimerSettings(battery: SleepTimers(systemMinutes: 10, displayMinutes: 5),
                           charger: SleepTimers(systemMinutes: 0, displayMinutes: 20))
    }
}

final class FixtureAssertionInventory: AssertionInventory {
    func currentAssertions() -> [AssertionRecord] {
        // Dwell is `now − AssertStartWhen` with the page's clock — the fixture clock under the harness
        // (spec 31 §2.6), so anchor to the same moment.
        let now = RenderFixtureClock.now
        return [
            AssertionRecord(pid: 843, processName: "caffeinate", type: "PreventUserIdleSystemSleep",
                            name: "caffeinate command-line tool", reason: "",
                            startedAt: now.addingTimeInterval(-(5 * 86_400 + 22 * 3600))),
            // A generic developer job (a long `npm run build` under node) — the second, foreign holder.
            AssertionRecord(pid: 1207, processName: "node", type: "PreventUserIdleSystemSleep",
                            name: "npm run build", reason: "npm run build",
                            startedAt: now.addingTimeInterval(-(2 * 3600 + 10 * 60))),
        ]
    }
}

final class FixtureAppTerminator: AppTerminating, Sendable {
    func terminableApp(pid: Int) -> TerminableApp? { nil }
    @discardableResult func terminate(_ app: TerminableApp) -> Bool { false }
}

// MARK: - devices (as of 13:20)

struct FixtureAccessoryReader: AccessoryPowerSourceReading {
    /// 31 option 1: in the wired scenario the iPhone and the Magic Keyboard are on cables (they move to
    /// "Powered by this Mac"), so the Bluetooth list is AirPods Pro · Apple Watch · Magic Mouse.
    var wiredScenario = false
    /// A failed IOPS read: the card then shows its own note, and the source falls back to the (fixture) ioreg probe.
    var unavailableReason: String?

    func read() -> AccessoryReadOutcome {
        if let unavailableReason { return .unavailable(unavailableReason) }
        func src(_ name: String, id: String, part: String?, cat: String, pct: Int, charging: Bool? = false) -> AccessoryPowerSource {
            AccessoryPowerSource(name: name, accessoryID: id, partID: part, category: cat,
                                 percent: pct, isCharging: charging, transport: "Bluetooth")
        }
        let all: [AccessoryPowerSource] = [
            src("AirPods Pro", id: "AP-1", part: "Left", cat: "Headset", pct: 72),
            src("AirPods Pro", id: "AP-2", part: "Right", cat: "Headset", pct: 70),
            src("AirPods Pro", id: "AP-3", part: "Case", cat: "Headset", pct: 91),
            src("Apple Watch", id: "AW-1", part: "Single", cat: "Watch", pct: 54, charging: true),
            src("iPhone", id: "IP-1", part: "Single", cat: "Phone", pct: 88),
            src("Magic Mouse", id: "MM-1", part: "Single", cat: "Mouse", pct: 18),
            src("Magic Keyboard", id: "MK-1", part: "Single", cat: "Keyboard", pct: 61),
        ]
        return .read(wiredScenario ? all.filter { $0.name != "iPhone" && $0.name != "Magic Keyboard" } : all)
    }
}

/// The Bluetooth-HID fallback's answer when the IOPS read failed (`powered-worst-notes`, `-adapter-ok`): five devices, so the card
/// carries rows AND its own `.unavailable` note. Never spawns the real `ioreg` (the owner's devices).
struct FixtureIoregProbe: ProcessProbing {
    /// `powered-notes-single-port`: a sixth device, so the list has more devices than the cap.
    var sixDevices = false
    func run(_ launchPath: String, args: [String], timeout: TimeInterval) async -> ProcessProbeResult {
        func node(_ product: String, _ pct: Int, _ addr: String) -> String {
            "+-o \(product)  <class AppleDeviceManagementHIDEventService>\n  {\n    \"Product\" = \"\(product)\"\n    \"BatteryPercent\" = \(pct)\n    \"DeviceAddress\" = \"\(addr)\"\n  }\n"
        }
        let out = node("AirPods Pro", 72, "aa-00") + node("Apple Watch", 54, "aa-01") + node("Magic Keyboard", 61, "aa-02")
            + node("Magic Mouse", 18, "aa-03") + node("Trackpad", 90, "aa-04")
            + (sixDevices ? node("Beats Flex", 40, "aa-05") : "")
        return ProcessProbeResult(stdout: out, timedOut: false, launchFailed: false, duration: 0.01, exitCode: 0)
    }
}

// MARK: - helper / login item (healthy, no banner)

final class FixtureDaemonService: DaemonService {
    var statusValue: DaemonServiceStatus { .enabled }
    func register() throws {}
    func unregister() throws {}
}

struct FixtureDaemonProbe: HelperDaemonProbing {
    func read() -> HelperDaemonImage { HelperDaemonImage(daemonStartedAt: nil, bundledBuiltAt: nil) }
}

final class FixtureLoginItemService: LoginItemServicing {
    var status: LoginStatus { .enabled }
    func register() throws {}
    func unregister() throws {}
}

// MARK: - history (raw jsonl for 7 days + aggregates back to Jun 11)

/// Synthesises the store's on-disk layout directly (`charge-<UTC day>.jsonl`, `agg-<month>.json`,
/// `health.jsonl`, `.started`) so every §5 figure the pages compute lands on the mockup's numbers:
/// today ≈ 4 h 36 m battery / 4 h 40 m power, 108 Wh out / 83 Wh in, low 1 % at 06:52; the day rows
/// Th…W = out 157/91/176/133/199/186/108, in 140/96/150/131/180/190/83, battery hours 9/6/12/8/14/11/5;
/// limit-hold hours 151 since Jun 11, 128 h at 100 % on power and 12/14 low days (deepest 1 %).
enum RenderFixtureHistory {
    struct Day { let back: Int; let whOut: Double; let whIn: Double; let battHours: Double; let minSoc: Int }
    /// The six raw days before today (Th Sep 3 … Tu Sep 8). Friday stays above 20 % (one of the two
    /// non-low days in the 14-day window; the other is an aggregate day).
    static let rawDays: [Day] = [
        Day(back: 6, whOut: 157, whIn: 140, battHours: 9, minSoc: 12),
        Day(back: 5, whOut: 91, whIn: 96, battHours: 6, minSoc: 30),
        Day(back: 4, whOut: 176, whIn: 150, battHours: 12, minSoc: 8),
        Day(back: 3, whOut: 133, whIn: 131, battHours: 8, minSoc: 15),
        Day(back: 2, whOut: 199, whIn: 180, battHours: 14, minSoc: 5),
        Day(back: 1, whOut: 186, whIn: 190, battHours: 11, minSoc: 18),
    ]
    /// `.showcase` only: the same six days with the shallow dips of a Mac kept at a limit (no day below 20 %).
    static let showcaseMinSoc = [6: 38, 5: 45, 4: 33, 3: 41, 2: 29, 1: 44]
    /// `.showcase` only: the current reading the showcase's day ends on (the monitor's IOPS read).
    static let showcaseSoC = 64
    static let showcaseTimeToEmpty = 91   // ≈ 64 % of 5,435 mAh at 2.30 A
    static let chargeW = 30.0            // charging power while filling
    static let holdW = 0.4               // trickle while parked at the limit
    static let limitHoldTarget = 151
    static let atFullTarget = 128
    /// `.showcase` only: a Mac kept at a limit spends little time full — one afternoon at 100 % (Sep 2), not 128 h.
    static let showcaseAtFullTarget = 6

    /// `showcase` (the `.showcase` fixtures, never a gated variant) writes a calmer history: today's low is 41 %, no day
    /// dips below 29 %, and the day ends on 64 %; today's limits follow the fired rules (07:30 → 100, 12:00 → 90) and
    /// the 12:21 manual set to 80; the last full charge is the Sep 2 afternoon at 100 % (outside the 24 h chart); the
    /// 14-day aggregates sit at the 80 % limit with 6 h at 100 %; capacity eases from ≈ 88.5 % in June to 87 %. Every gated fixture calls
    /// this with `showcase: false` — unchanged.
    static func write(root: URL, showcase: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let cal = Calendar.current
        let now = RenderFixtureClock.now
        let since = RenderFixtureClock.at(hour: 0, minute: 0, dayOffset: -90)   // Jun 11
        try String(Int(since.timeIntervalSince1970)).write(to: root.appendingPathComponent(".started"), atomically: true, encoding: .utf8)

        var rows: [ChargePoint] = []
        if showcase {
            // Showcase today, under the rules that fired (07:30 → 100, 12:00 → 90) and the 12:21 manual set to 80:
            // asleep until the scheduled 06:45 wake; 06:45 → 07:31 on power, held at the 80 % limit (≈ 0.5 W);
            // 07:31 → 08:13 charging toward 100 after the 07:30 rule (80 → 86 %, ≈ 3.9 Wh ≈ 6 % of the pack);
            // 08:13 → 11:03 on battery (86 → 41 %); 11:03 → 12:21 charging (41 → 80 %; limit 100, then 90 from
            // 12:00); the 12:21 set to 80 stops the charge at 80 and 12:21 → 13:21 runs on battery (80 → 64 %).
            // Same no-30/30-hour rule: the charge starts at 07:31 (a minute after the rule), so hour 07 is 31 min
            // held, 29 charging.
            rows += segment(from: RenderFixtureClock.at(hour: 6, minute: 45), to: RenderFixtureClock.at(hour: 7, minute: 31),
                            soc: (80, 80), watts: 0.5, onAC: true, state: "limitHold", limit: 80)
            rows += segment(from: RenderFixtureClock.at(hour: 7, minute: 31), to: RenderFixtureClock.at(hour: 8, minute: 13),
                            soc: (80, 86), watts: 5.5, onAC: true, state: "charging", limit: 100)
            rows += segment(from: RenderFixtureClock.at(hour: 8, minute: 13), to: RenderFixtureClock.at(hour: 11, minute: 3),
                            soc: (86, 41), watts: -10, onAC: false, state: "discharging", limit: 100)
            rows += segment(from: RenderFixtureClock.at(hour: 11, minute: 3), to: RenderFixtureClock.at(hour: 12, minute: 0),
                            soc: (41, 70), watts: 20, onAC: true, state: "charging", limit: 100)
            rows += segment(from: RenderFixtureClock.at(hour: 12, minute: 0), to: RenderFixtureClock.at(hour: 12, minute: 21),
                            soc: (70, 80), watts: 20, onAC: true, state: "charging", limit: 90)
            rows += segment(from: RenderFixtureClock.at(hour: 12, minute: 21), to: now,
                            soc: (80, Self.showcaseSoC), watts: -10, onAC: false, state: "discharging", limit: 80,
                            includeEnd: true)
        } else {
        // Today: 04:05 → 06:52 on battery (45 → 1 %), 06:52 → 09:30 charging, 09:30 → 11:32 holding,
        // 11:32 → 13:21 on battery (80 → 32 %). Battery 4 h 36 m, power 4 h 40 m.
        // (Minute rows; segment ends chosen so no hour splits 30/30 between states — `hourly`'s dominant
        // state would then be a dictionary-order coin flip — and so the single 1 % row sits at 06:52.)
        rows += segment(from: RenderFixtureClock.at(hour: 4, minute: 5), to: RenderFixtureClock.at(hour: 6, minute: 52),
                        soc: (45, 2), watts: -23.5, onAC: false, state: "discharging", limit: 80)
        rows.append(ChargePoint(ts: Int(RenderFixtureClock.at(hour: 6, minute: 52).timeIntervalSince1970),
                                soc: 1, watts: -23.5, onAC: false, state: "discharging", limit: 80))
        rows += segment(from: RenderFixtureClock.at(hour: 6, minute: 53), to: RenderFixtureClock.at(hour: 9, minute: 31),
                        soc: (2, 80), watts: 31.05, onAC: true, state: "charging", limit: 80)
        rows += segment(from: RenderFixtureClock.at(hour: 9, minute: 31), to: RenderFixtureClock.at(hour: 11, minute: 33),
                        soc: (80, 80), watts: 0.6, onAC: true, state: "limitHold", limit: 80)
        rows += segment(from: RenderFixtureClock.at(hour: 11, minute: 33), to: now,
                        soc: (80, 32), watts: -23.5, onAC: false, state: "discharging", limit: 80, includeEnd: true)
        }
        // The six raw days: 07:00 (earlier when the day is long) battery → charge at 30 W → hold to 23:59.
        for d in rawDays {
            let dayEndH = 23.0 + 58.0 / 60
            var startH = 7.0 + 7.0 / 60   // 07:07 (off the half-hour, see above)
            if startH + d.battHours + d.whIn / chargeW > dayEndH - 0.5 {
                startH = max(0.5, dayEndH - 0.5 - d.battHours - d.whIn / chargeW)
            }
            // Wh in = charge·chargeW + hold·holdW with hold = the rest of the day → solve for the charge hours.
            let total = dayEndH - startH
            let chargeHours = (d.whIn - holdW * (total - d.battHours)) / (chargeW - holdW)
            let dayStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -d.back, to: now)!)
            let t0 = dayStart.addingTimeInterval(startH * 3600)
            let t1 = t0.addingTimeInterval(d.battHours * 3600)
            let t2 = t1.addingTimeInterval((chargeHours * 3600).rounded())
            let t3 = dayStart.addingTimeInterval(dayEndH * 3600)
            let minSoc = showcase ? (Self.showcaseMinSoc[d.back] ?? d.minSoc) : d.minSoc
            rows += segment(from: t0, to: t1, soc: (80, minSoc), watts: -(d.whOut / d.battHours), onAC: false, state: "discharging", limit: 80)
            rows += segment(from: t1, to: t2, soc: (minSoc, 80), watts: chargeW, onAC: true, state: "charging", limit: 80)
            rows += segment(from: t2, to: t3, soc: (80, 80), watts: holdW, onAC: true, state: "limitHold", limit: 80)
        }
        // "Last full charge yesterday 23:10": a single 100 % row (its hour's socMin stays 80) — gated fixtures only.
        // The showcase writes no such row: a lone 100 % minute between 80 % hold rows cannot happen. Its last full
        // charge is the one afternoon at 100 % (the Sep 2 aggregate hours, 14:00–20:00, unplugged at 20:00), so
        // Health reads "Sep 2", outside the 24 h chart.
        if !showcase {
            rows.append(ChargePoint(ts: Int(RenderFixtureClock.at(hour: 23, minute: 10, dayOffset: -1).timeIntervalSince1970),
                                    soc: 100, watts: 0.3, onAC: true, state: "charging", limit: 100))
        }
        rows.sort { $0.ts < $1.ts }

        // Raw files, keyed by UTC day like the store.
        let enc = JSONEncoder()
        var byDay: [String: [ChargePoint]] = [:]
        for r in rows { byDay[HistoryFormat.dayKey(HistoryFormat.utcDayStart(r.ts)), default: []].append(r) }
        for (day, dayRows) in byDay {
            let text = try dayRows.map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try text.write(to: root.appendingPathComponent("charge-\(day).jsonl"), atomically: true, encoding: .utf8)
        }

        // Aggregates. (a) The 7 aggregate days inside the 14-day window (Aug 27 – Sep 2): 18 h/day at
        // 100 % on power (+2 on the first → 128 h) and a low battery dip (six ≤ 20 %, one at 35 %).
        // (b) Limit-hold filler hours from Jun 11 up to Aug 26 so the stitched total is exactly 151.
        var agg: [String: [String: HourlyAggregate]] = [:]
        func put(_ hourStart: Int, _ a: HourlyAggregate) {
            agg[HistoryFormat.monthKey(hourStart), default: [:]][String(hourStart)] = a
        }
        var atFull = 0
        for back in 7...13 {
            let dayStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -back, to: now)!)
            let dip = showcase ? (back % 2 == 0 ? 36 : 47) : (back == 10 ? 35 : (back % 2 == 0 ? 14 : 19))
            for h in 0..<24 {
                let hs = HistoryFormat.utcHourStart(Int(dayStart.timeIntervalSince1970) + h * 3600)
                let fullHours = (back == 7) ? 20 : 18
                if showcase, h < fullHours {
                    // The showcase: parked at the 80 % limit, except one afternoon charged full (Sep 2, 14:00–20:00).
                    if back == 7, h >= fullHours - showcaseAtFullTarget, atFull < showcaseAtFullTarget {
                        put(hs, HourlyAggregate(socMin: 100, socMax: 100, socAvg: 100, wattsAvg: 0.2, acFraction: 1,
                                                dominantState: "unknown", count: 60))
                        atFull += 1
                    } else {
                        put(hs, HourlyAggregate(socMin: 80, socMax: 80, socAvg: 80, wattsAvg: holdW, acFraction: 1,
                                                dominantState: "limitHold", count: 60))
                    }
                } else if showcase, h == fullHours {
                    put(hs, HourlyAggregate(socMin: dip, socMax: back == 7 ? 100 : 80, socAvg: Double(dip + 20),
                                            wattsAvg: -18, acFraction: 0, dominantState: "discharging", count: 60))
                } else if h < fullHours, atFull < atFullTarget {
                    put(hs, HourlyAggregate(socMin: 100, socMax: 100, socAvg: 100, wattsAvg: 0.2, acFraction: 1,
                                            dominantState: "unknown", count: 60))
                    atFull += 1
                } else if h == fullHours {
                    put(hs, HourlyAggregate(socMin: dip, socMax: 60, socAvg: Double(dip + 20), wattsAvg: -18,
                                            acFraction: 0, dominantState: "discharging", count: 60))
                } else {
                    put(hs, HourlyAggregate(socMin: dip, socMax: 40, socAvg: 30, wattsAvg: -17, acFraction: 0,
                                            dominantState: "discharging", count: 60))
                }
            }
        }
        // Raw limit-hold hours already on disk (stitched raw wins per hour), then fill the remainder.
        let rawHold = HistoryMetrics.limitHoldHours(agg: agg.values.reduce(into: [:]) { $0.merge($1) { a, _ in a } }, raw: rows)
        var need = max(0, limitHoldTarget - rawHold)
        var cursor = cal.date(byAdding: .day, value: 14, to: since)!   // start filling ~Jun 25
        while need > 0 {
            let dayStart = cal.startOfDay(for: cursor)
            for h in 10..<18 where need > 0 {
                let hs = HistoryFormat.utcHourStart(Int(dayStart.timeIntervalSince1970) + h * 3600)
                put(hs, HourlyAggregate(socMin: 80, socMax: 80, socAvg: 80, wattsAvg: 0.4, acFraction: 1,
                                        dominantState: "limitHold", count: 60))
                need -= 1
            }
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }
        // A first aggregate hour on Jun 11 so the health chart's caption spans "Jun → Sep".
        put(HistoryFormat.utcHourStart(Int(since.timeIntervalSince1970) + 12 * 3600),
            HourlyAggregate(socMin: 60, socMax: 70, socAvg: 65, wattsAvg: -15, acFraction: 0, dominantState: "discharging", count: 60))
        for (month, hours) in agg {
            let data = try enc.encode(hours)
            try data.write(to: root.appendingPathComponent("agg-\(month).json"), options: .atomic)
        }

        // health.jsonl: one row a day from Jun 11 — cycles rising 8.6 / week to 525, capacity ≈ 87 %. The showcase's
        // capacity eases from ≈ 88.5 % (5,530 mAh) on Jun 11 to 87 % (5,435) today, with a few mAh of read jitter.
        var lines: [String] = []
        for back in stride(from: 90, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -back, to: now)!
            let cycles = 525 - Int((Double(back) * 8.6 / 7).rounded())
            let cap = showcase
                ? 5435 + Int((Double(back) * 95 / 90).rounded()) + (back == 0 ? 0 : ((back * 7) % 9) - 4)
                : 5435 + ((back * 7) % 11) - 5
            let p = HealthPoint(ts: Int(d.timeIntervalSince1970), healthPct: Double(cap) / 62.49, cycles: cycles, maxCap_mAh: cap)
            lines.append(String(decoding: try enc.encode(p), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("health.jsonl"), atomically: true, encoding: .utf8)
    }

    /// One row a minute from `from` to `to` (exclusive unless `includeEnd`), SoC linear between the ends.
    /// `.healthHistoryNote`: month files that are there but will not decode (a torn write). Inside the
    /// 12-month aggregate horizon of the fixture's Sep 9 (so maintenance keeps and names them), before the
    /// history starts (so no figure changes), and the two longest month names a two-month note can carry.
    static let unreadableMonths = ["2025-09", "2025-12"]
    static func writeUnreadableMonths(root: URL) throws {
        for m in unreadableMonths {
            try Data("{\"".utf8).write(to: root.appendingPathComponent("agg-\(m).json"))
        }
    }

    private static func segment(from: Date, to: Date, soc: (Int, Int), watts: Double, onAC: Bool,
                                state: String, limit: Int, includeEnd: Bool = false) -> [ChargePoint] {
        let t0 = Int(from.timeIntervalSince1970), t1 = Int(to.timeIntervalSince1970)
        guard t1 > t0 else { return [] }
        var out: [ChargePoint] = []
        var t = t0
        while t < t1 || (includeEnd && t == t1) {
            let f = Double(t - t0) / Double(t1 - t0)
            let s = Int((Double(soc.0) + (Double(soc.1) - Double(soc.0)) * f).rounded())
            out.append(ChargePoint(ts: t, soc: s, watts: watts, onAC: onAC, state: state, limit: limit))
            t += 60
        }
        return out
    }
}
