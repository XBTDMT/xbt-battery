import Foundation
import Combine
import IOKit
import IOKit.ps          // §5.2 row 17: IOPSCopyExternalPowerAdapterDetails — public, IOPowerSources.h:375
import os

/// #EI-3 v2.1 (SPEC 02-SPEC-ei3v2-adapter-va.md sec 8): one USB-C Power Delivery profile rung the adapter
/// advertises (from AdapterDetails.UsbHvcMenu), e.g. 20 V / 3.75 A. `index` matches UsbHvcHvcIndex so the
/// negotiated (active) rung can be marked.
struct PdProfile: Equatable {
    let index: Int
    let voltage_mV: Int
    let current_mA: Int
}

/// #EI-3 (SPEC 02-SPEC-ei3-adapter-wattage.md). The connected power adapter's wattage CEILING, read
/// from the AppleSmartBattery node's nested AdapterDetails dict. READ-ONLY — we read the adapter's
/// rating, never set it. v1 surfaces only the wattage (no name / V·A / PD-profile — deferred).
struct PowerAdapter: Equatable {
    let watts: Int
    /// #EI-3 v2 (SPEC 02-SPEC-ei3v2-adapter-va.md): the adapter's RATED voltage/current (AdapterVoltage
    /// millivolts, Current milliamps). OPTIONAL (nil when absent/non-numeric), so v1 (watts) is unchanged.
    let voltage_mV: Int?
    let current_mA: Int?

    /// #EI-3 v2.1 (SPEC sec 8): the adapter's USB-C PD profile ladder (AdapterDetails.UsbHvcMenu) and the
    /// negotiated rung (UsbHvcHvcIndex). `var` with a default (NOT `let`) so they are DEFAULTED in the
    /// synthesized memberwise init — keeping the existing 3-arg construction + tests unchanged while
    /// letting `from(properties:)` pass them (a `let` with a default is omitted from the init entirely).
    var pdProfiles: [PdProfile] = []
    var activePdIndex: Int? = nil

    /// Value-or-nothing convenience over `resolve(properties:)` — the shape every existing caller and
    /// test already uses. It cannot tell you WHICH of the three states you got; use `resolve` when the
    /// difference matters (it always matters on screen).
    static func from(properties: [String: Any]?) -> PowerAdapter? {
        resolve(properties: properties).adapter
    }

    /// SWEEP §2.G (knowledge/12-SWEEP-silent-absence.md, hit 1). The THREE-STATE adapter read.
    ///
    /// This used to be one `guard … else { return nil }` over `props["AdapterDetails"]` at the TOP LEVEL
    /// ONLY, which made four different facts the same value: no adapter plugged in, an unreadable
    /// property dict, a missing `Watts`, and — the one that will actually happen — `AdapterDetails`
    /// relocated by a new macOS while an adapter IS attached. macOS 27 has already moved `DesignCapacity`,
    /// `NominalChargeCapacity`, `AppleRawMaxCapacity`, `Temperature` and `AppleRawCurrentCapacity` down
    /// exactly this path; `03-REF-applesmartbattery-layout.md` rule 2 says never to guard on top-level
    /// keys only, and this reader never got the ladder.
    ///
    /// Two things make the split possible:
    ///   1. **The ladder** — top level → node `BatteryData` → pack `BatteryData`, newest relocation last,
    ///      the same rungs `BatteryLifetimeParser` walks. A rung that carries an `AdapterDetails` with no
    ///      `Watts` does NOT stop the walk (this machine's live top-level dict is literally
    ///      `{FamilyCode: 0}` while on battery), so an empty rung can never shadow a populated one.
    ///   2. **The witness** — `ExternalConnected`. Something being plugged in while no rung publishes a
    ///      wattage is the relocation signature, and it is the whole reason this is not just a `nil`.
    ///
    /// AUDIT §5.2 row 17 — `publicDetails` is `IOPSCopyExternalPowerAdapterDetails()`, the **strictly
    /// public** rung. Verified before it was wired (2026-09-08, this M4 Max, adapter attached):
    /// declared in the SDK's own `IOKit.framework/Headers/ps/IOPowerSources.h:375` (no `dlsym`, no
    /// vendored prototype — that is what separates it from the `IOPMCopy*` family §5.3 parks behind the
    /// three-state work), returning a dict with the **same 11 keys and zero value differences** against
    /// the IORegistry `AdapterDetails` below, at 0.078 ms median. So `parse` is byte-unchanged; only the
    /// dict's provenance is new.
    ///
    /// **It is a RUNG, not a replacement, and that is deliberate.** Row 17 describes it as *"retiring an
    /// undocumented IORegistry read"* — it cannot, and the header says why: *"If no adapter is attached,
    /// **or if there's an error**, returns NULL."* One NULL for two facts is exactly the two-state
    /// collapse `c867c26` removed from this reader, and the `ExternalConnected` witness that tells them
    /// apart lives in the IORegistry read the swap would have deleted. So the public dict goes FIRST
    /// (it is the supported contract, and it is immune to a relocation *inside* AppleSmartBattery — the
    /// drift the ladder exists to detect), a NULL from it decides nothing, and the witness stays put.
    static func resolve(properties: [String: Any]?,
                        publicDetails: [String: Any]? = nil) -> PowerAdapterReadState {
        // Rung 0 — the supported API. A dict WITHOUT `Watts` is drift in its own right and must not
        // shadow a rung that has one, so this asks the same question the ladder does.
        if let d = publicDetails, let watts = (d["Watts"] as? NSNumber)?.intValue {
            return .connected(parse(d, watts: watts))
        }
        guard let props = properties else {
            return .unavailable("the battery node's properties could not be read")
        }

        // The three rungs, newest relocation LAST. `packPropertiesKey` is the synthetic key the live
        // readers fold the `AppleSmartBatteryPack` child in under, so this stays ONE registry visit.
        let nested = props["BatteryData"] as? [String: Any]
        let pack = (props[Self.packPropertiesKey] as? [String: Any])?["BatteryData"] as? [String: Any]
        let details = [props, nested, pack].lazy
            .compactMap { $0?["AdapterDetails"] as? [String: Any] }
            .first { ($0["Watts"] as? NSNumber)?.intValue != nil }

        if let adapter = details, let watts = (adapter["Watts"] as? NSNumber)?.intValue {
            return .connected(parse(adapter, watts: watts))
        }

        // No wattage at any rung. That is only "no adapter" if the node positively says so.
        switch externalConnected(props) {
        case .some(false):
            return .noAdapter
        case .some(true):
            return .unavailable("power is connected but this macOS publishes no adapter wattage at any layout this app knows")
        case .none:
            // The witness itself resolved nowhere. `ExternalConnected` has been top-level on every macOS
            // to date, so its absence is drift in its own right — and guessing "unplugged" here would be
            // the exact fabrication this whole change exists to stop.
            return .unavailable("neither the adapter wattage nor the external-power flag resolved at any layout this app knows")
        }
    }

    /// `ExternalConnected` bridges as a CFBoolean from the IORegistry and as a `Bool` from a test literal;
    /// read both spellings rather than let a bridging detail masquerade as an absent key.
    private static func externalConnected(_ props: [String: Any]) -> Bool? {
        guard let raw = props["ExternalConnected"] else { return nil }
        if let n = raw as? NSNumber { return n.boolValue }
        return raw as? Bool
    }

    /// The synthetic key the live readers fold the `AppleSmartBatteryPack` child's properties in under —
    /// the same constant `BatteryLifetimeParser` owns, aliased so the two readers cannot drift apart.
    static var packPropertiesKey: String { BatteryLifetimeParser.packPropertiesKey }

    /// The byte-unchanged v1/v2/v2.1 extraction, now taking the `AdapterDetails` dict the ladder found
    /// rather than digging it out of one hard-coded rung itself.
    private static func parse(_ adapter: [String: Any], watts: Int) -> PowerAdapter {
        let voltage = (adapter["AdapterVoltage"] as? NSNumber)?.intValue
        let current = (adapter["Current"] as? NSNumber)?.intValue
        // #EI-3 v2.1: parse the PD profile menu defensively (the IORegistry array bridges as [Any] of
        // dicts). Beside the byte-unchanged Watts/AdapterVoltage/Current reads, so v1/v2 cannot regress.
        var profiles: [PdProfile] = []
        if let menu = adapter["UsbHvcMenu"] as? [Any] {
            for el in menu {
                if let e = el as? [String: Any],
                   let idx = (e["Index"] as? NSNumber)?.intValue,
                   let mv  = (e["MaxVoltage"] as? NSNumber)?.intValue,
                   let ma  = (e["MaxCurrent"] as? NSNumber)?.intValue {
                    profiles.append(PdProfile(index: idx, voltage_mV: mv, current_mA: ma))
                }
            }
        }
        let activeIdx = (adapter["UsbHvcHvcIndex"] as? NSNumber)?.intValue
        return PowerAdapter(watts: watts, voltage_mV: voltage, current_mA: current,
                            pdProfiles: profiles, activePdIndex: activeIdx)
    }

    /// #EI-3 v2: the rated spec, e.g. "75 W (20 V / 3.75 A)" when BOTH V and A are present, else "75 W"
    /// (requiring both avoids a lopsided parenthetical). %g trims trailing zeros: 20.0 → "20", 3.0 → "3".
    var specText: String {
        guard let mV = voltage_mV, let mA = current_mA else { return "\(watts) W" }
        let v = String(format: "%g", Double(mV) / 1000.0)
        let a = String(format: "%g", Double(mA) / 1000.0)
        return "\(watts) W (\(v) V / \(a) A)"
    }

    /// #EI-3 v2.1 (SPEC sec 8): the adapter's USB-C PD profile ladder, active rung marked. Each rung
    /// "%gV/%gA" (trailing-zero-trimmed), joined ", "; " (active)" on the rung whose index == activePdIndex.
    /// nil under two rungs (a single-rung source adds nothing beyond the Adapter spec row).
    var pdProfileMenuText: String? {
        guard pdProfiles.count >= 2 else { return nil }
        let rungs = pdProfiles.map { p -> String in
            let v = String(format: "%g", Double(p.voltage_mV) / 1000.0)
            let a = String(format: "%g", Double(p.current_mA) / 1000.0)
            let base = "\(v)V/\(a)A"
            return p.index == activePdIndex ? "\(base) (active)" : base
        }
        return rungs.joined(separator: ", ")
    }
}

/// SWEEP §2.G. What the adapter read actually knows — the `DeviceReadState` / `TemperatureReading`
/// shape, applied to the one remaining single-rung IORegistry read in the app.
enum PowerAdapterReadState: Equatable {
    /// PRESENT — an adapter is attached and a rung published its wattage.
    case connected(PowerAdapter)
    /// ABSENT BY DESIGN — the read worked and the node says nothing is plugged in.
    case noAdapter
    /// READ FAILED — the read could not be performed, or power is connected and the wattage resolved
    /// at no layout we know. Carries the reason.
    case unavailable(String)

    /// The adapter when there is one; nil in both other states (which is the collapse this type exists
    /// to survive — the value is still convenient, it just is no longer the whole answer).
    var adapter: PowerAdapter? { if case .connected(let a) = self { return a } else { return nil } }

    /// The cue the Power card shows. nil in BOTH healthy states: an unplugged Mac is not a problem to
    /// report, and neither is a working adapter. Only a failed read gets a sentence.
    var note: String? {
        switch self {
        case .connected, .noAdapter: return nil
        case .unavailable(let why):  return "Power adapter details unavailable — \(why)."
        }
    }
}

/// Seam over the READ-ONLY AppleSmartBattery adapter read (parallel to the BatteryLifetime seam):
/// production reads the IORegistry node; tests inject a mock. The seam returns the three-state result
/// so a failure arrives WITH its reason instead of as an anonymous nil — no crash; the ceiling simply
/// isn't shown, but the card can now say why.
protocol PowerAdapterReading: AnyObject {
    func readDetailed() -> PowerAdapterReadState
}

extension PowerAdapterReading {
    /// Value-or-nothing convenience for callers that don't care WHY (the seam's original shape).
    func read() -> PowerAdapter? { readDetailed().adapter }
}

/// Production reader: match AppleSmartBattery, copy its properties, parse AdapterDetails.Watts.
/// READ-ONLY — no IOKit write, no SMC, no charge-inhibit, no assertion. Boundary adapter — exercised
/// in tests only through the seam's mock (never the live IORegistry).
final class LivePowerAdapterReader: PowerAdapterReading {
    /// SWEEP §2.G legibility: a relocation must leave a trace, exactly as `LiveBatteryLifetimeReader`
    /// does. Key names only — no user data.
    private static let log = Logger(subsystem: "com.example.batteryapp", category: "PowerAdapter")

    func readDetailed() -> PowerAdapterReadState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return Self.publicRungOr("no AppleSmartBattery service matched") }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              var props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return Self.publicRungOr("AppleSmartBattery properties could not be copied")
        }
        // 03-REF rule 1: walk the pack child and fold it in under the parser's synthetic key, so the
        // ladder's third rung is reachable and the whole read is still ONE registry visit.
        if let pack = Self.copyPackProperties(of: service) {
            props[PowerAdapter.packPropertiesKey] = pack
        }

        // §5.2 row 17: the public rung. Copied HERE, not inside `resolve` — `resolve` stays a pure
        // function of two dicts, which is the only reason all of this is testable off-device. One
        // 0.078 ms call, no fork, no undeclared symbol.
        let state = PowerAdapter.resolve(properties: props, publicDetails: Self.publicAdapterDetails())
        if case .unavailable(let why) = state {
            Self.log.warning("AppleSmartBattery adapter read degraded: \(why, privacy: .public)")
        }
        return state
    }

    /// §5.2 row 17. The strictly-public rung: `IOPSCopyExternalPowerAdapterDetails` — SDK-declared in
    /// `IOKit/ps/IOPowerSources.h:375`, returning the byte-identical dict (same 11 keys, zero value
    /// differences, verified live on this M4 Max). READ-ONLY, 0.078 ms median.
    private static func publicAdapterDetails() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }

    /// The public rung can still answer while the IORegistry read is broken — one succeeding read is
    /// enough, and reporting a failure we recovered from would be its own dishonesty. When it does NOT
    /// answer, the caller's own, more specific reason survives (a NULL from it means nothing: the header
    /// returns NULL for "unplugged" and for "error" alike, so it can never be the thing that decides).
    private static func publicRungOr(_ reason: String) -> PowerAdapterReadState {
        let state = PowerAdapter.resolve(properties: nil, publicDetails: publicAdapterDetails())
        if case .connected = state { return state }
        return .unavailable(reason)
    }

    /// READ-ONLY registry walk for the `AppleSmartBatteryPack` child — the same walk
    /// `LiveBatteryLifetimeReader` and `LiveBatteryReader` do. No IOKit write, no SMC.
    private static func copyPackProperties(of battery: io_service_t) -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(battery, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var found: [String: Any]?
        var child = IOIteratorNext(iterator)
        while child != 0 {
            if found == nil, IOObjectConformsTo(child, "AppleSmartBatteryPack") != 0 {
                var childProps: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(child, &childProps, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                    found = childProps?.takeRetainedValue() as? [String: Any]
                }
            }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return found
    }
}

// MARK: - #30 §4.6: the adapter "last" record

/// #30 §4.6 / R8: what the Devices tab's Power adapter row says while nothing is plugged in —
/// "not connected · last 94 W, 20 V rung". The last SUCCESSFUL `.connected` read, persisted as
/// `adapter.last.v1`. `ts` = seconds since the epoch of that read. Flat + Codable so the on-disk shape
/// is explicit; `pdProfiles` is deliberately not kept (the row shows the rung, not the ladder).
struct LastAdapterRecord: Codable, Equatable, Sendable {
    let watts: Int
    let voltage_mV: Int?
    let current_mA: Int?
    let activePdIndex: Int?
    let ts: Int
    /// The PD ladder's rung count at the time of the read ("rung 4 **of 5**"). Optional so older
    /// `adapter.last.v1` blobs decode (synthesized Decodable tolerates a missing optional).
    var ladderCount: Int? = nil

    init(watts: Int, voltage_mV: Int?, current_mA: Int?, activePdIndex: Int?, ts: Int, ladderCount: Int? = nil) {
        self.watts = watts; self.voltage_mV = voltage_mV; self.current_mA = current_mA
        self.activePdIndex = activePdIndex; self.ts = ts; self.ladderCount = ladderCount
    }

    init(adapter: PowerAdapter, at date: Date) {
        self.init(watts: adapter.watts, voltage_mV: adapter.voltage_mV, current_mA: adapter.current_mA,
                  activePdIndex: adapter.activePdIndex, ts: Int(date.timeIntervalSince1970),
                  ladderCount: adapter.pdProfiles.isEmpty ? nil : adapter.pdProfiles.count)
    }

    /// The negotiated rung's voltage in volts, when the record has one, e.g. "20 V rung". The
    /// negotiated rung's voltage IS `voltage_mV` (AdapterVoltage reflects the active PD contract).
    var rungVoltageText: String? {
        guard let mV = voltage_mV else { return nil }
        return String(format: "%g V rung", Double(mV) / 1000.0)
    }
}

/// UserDefaults-backed store for `LastAdapterRecord` (key `adapter.last.v1`). Mirrors the project's
/// prefs-store pattern: injected `UserDefaults`, an explicit nil on absence, and a TOLERANT decode —
/// a corrupt or foreign-shaped blob is nil, never a crash (the row then simply has no "last").
struct AdapterLastStore {
    static let key = "adapter.last.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> LastAdapterRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(LastAdapterRecord.self, from: data)
    }

    func save(_ record: LastAdapterRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

/// #EI-3 popover source: reads the adapter ON DEMAND (popover-open) and publishes it. NO timer — the
/// ceiling only renders while charging, so a stale value after unplug is harmless (the row flips to
/// "Discharging", which never appends the ceiling). nil = no adapter / read failed.
@MainActor
final class PowerAdapterSource: ObservableObject {
    /// SWEEP §2.G: the honest read state. The Power card renders `readState.note` whenever it is
    /// non-nil, so a relocated `AdapterDetails` is VISIBLE instead of looking like an unplugged Mac.
    /// Published as the state, not just the value — a split that dies at the boundary is no split
    /// (`BatteryLifetimeSource.lastFailure` sat unrendered for exactly that reason).
    @Published private(set) var readState: PowerAdapterReadState = .noAdapter

    /// The adapter when one is connected AND its wattage resolved; nil otherwise.
    var adapter: PowerAdapter? { readState.adapter }

    /// The adapter's wattage ceiling, or nil when no adapter is connected.
    var watts: Int? { adapter?.watts }

    /// #30 §4.6: the last successful `.connected` read, from `adapter.last.v1` — loaded once at init,
    /// then kept in step with every save. What the row shows as "not connected · last …".
    @Published private(set) var lastRecord: LastAdapterRecord?

    private let reader: PowerAdapterReading
    private let lastStore: AdapterLastStore
    private let now: () -> Date

    init(reader: PowerAdapterReading = LivePowerAdapterReader(),
         lastStore: AdapterLastStore = AdapterLastStore(),
         now: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.lastStore = lastStore
        self.now = now
        self.lastRecord = lastStore.load()
    }

    /// On-demand read (synchronous IORegistry read; fast). No polling timer. Every SUCCESSFUL
    /// `.connected` read is persisted as the "last" record; the other two states leave it alone.
    func refresh() {
        readState = reader.readDetailed()
        if case .connected(let adapter) = readState {
            let record = LastAdapterRecord(adapter: adapter, at: now())
            lastStore.save(record)
            lastRecord = record
        }
    }
}
