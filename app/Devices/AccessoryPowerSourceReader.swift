import Foundation
import IOKit.ps

/// Sprint 4.I (#12 follow-on): the connected-device battery read, done IN PROCESS.
///
/// `IOPSCopyPowerSourcesByType` is exported by IOKit but declared in NO SDK header, so it is resolved
/// by dlopen/dlsym — the SAME idiom as `app/Energy/IOReportPowerSampler` (whose own comment records
/// that a dylib path already MOVED once on macOS 27, which is why the resolve is path-tolerant and the
/// missing-symbol path returns an honest `.unavailable` rather than a crash or a silent empty list).
///
/// Two verified facts about the entry point (measured on this machine, macOS 27.0, 2026-09-08):
///   • it takes an **Int**, not a string — `byType("All")` returns empty, `byType(0)` returns everything;
///   • the plain public `IOPSCopyPowerSourcesInfo()` is NOT a substitute: it returns count=1 (the
///     internal battery only) and carries no accessory at all.
/// Everything downstream (`IOPSCopyPowerSourcesList`, `IOPSGetPowerSourceDescription`) is public API.
private typealias CopyPowerSourcesByTypeFn = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?

// MARK: - the raw accessory row (one battery within one accessory)

/// One IOPS accessory power source. `partID` / `accessoryID` are the fields that retire the app's two
/// guesses: the dedupe key was a NAME STRING, and Left/Right/Case were inferred by percent-matching.
struct AccessoryPowerSource: Equatable, Sendable {
    let name: String
    /// "Accessory Identifier" — a stable UUID per accessory. The real dedupe key.
    let accessoryID: String?
    /// "Part Identifier" — `Single` / `Left` / `Right` / `Case`. The real component label.
    let partID: String?
    /// "Accessory Category" — `Headset` / `Mouse` / `Keyboard` / … . Replaces system_profiler's "Minor Type".
    let category: String?
    let percent: Int
    let isCharging: Bool?
    let transport: String?
}

/// The read is a RESULT, not an array: an empty array and a failed read must never be the same value
/// (audit C1 — that conflation is exactly what let a failing source silently erase the Devices card).
enum AccessoryReadOutcome: Equatable, Sendable {
    /// The read succeeded. An empty payload means "nothing connected reports a battery" — absent BY DESIGN.
    case read([AccessoryPowerSource])
    /// The read itself could not be performed (symbol gone, no snapshot). Carries a user-facing reason.
    case unavailable(String)
}

/// Seam over the IOPS accessory read (the project's reader-seam idiom: protocol + `Live*` boundary
/// adapter). Production reads IOPS; tests inject a mock and never touch the live power sources.
protocol AccessoryPowerSourceReading: Sendable {
    func read() -> AccessoryReadOutcome
}

/// Production reader. READ-ONLY, unprivileged, no subprocess. Measured on this machine (2026-09-08,
/// mean over 50 calls, one accessory connected): **0.088 ms/call** end-to-end — the dlsym-resolved call,
/// the description extraction AND the parse (the raw IOPS call alone is 0.076 ms; the dlsym resolve is a
/// one-off 0.006 ms at init). The three spawns it replaces cost 0.43-0.55 s wall / ~0.18 s child CPU.
final class LiveAccessoryPowerSourceReader: AccessoryPowerSourceReading, @unchecked Sendable {
    /// Immutable after init → `@unchecked Sendable` is sound (same posture as IOReportPowerSampler).
    private let copyByType: CopyPowerSourcesByTypeFn?
    private let symbolName: String

    /// `symbolName` is injectable ONLY so the symbol-missing path is a real test, not a claim.
    init(symbolName: String = "IOPSCopyPowerSourcesByType") {
        self.symbolName = symbolName
        func resolve(_ handle: UnsafeMutableRawPointer?) -> CopyPowerSourcesByTypeFn? {
            guard let handle, let sym = dlsym(handle, symbolName) else { return nil }
            return unsafeBitCast(sym, to: CopyPowerSourcesByTypeFn.self)
        }
        // IOKit is already linked into the app, so RTLD_DEFAULT ((void *)-2) resolves it with no
        // dlopen at all; the explicit paths are the belt-and-braces for a macOS-27-style relocation.
        // `??` short-circuits, so the dlopens only run if the in-process lookup misses.
        copyByType = resolve(UnsafeMutableRawPointer(bitPattern: -2))
            ?? resolve(dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY))
            ?? resolve(dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY))
    }

    func read() -> AccessoryReadOutcome {
        guard let copyByType else {
            return .unavailable("this macOS build does not export \(symbolName)")
        }
        guard let blob = copyByType(0)?.takeRetainedValue() else {
            return .unavailable("macOS returned no power-source snapshot")
        }
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue()
        // Walked via the CF accessors rather than an `as? [CFTypeRef]` bridge cast (which the compiler
        // warns "always succeeds") — this is the boundary, so it stays explicit.
        var descriptions: [[String: Any]] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let source = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            if let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] {
                descriptions.append(d)
            }
        }
        return .read(DeviceParsers.parseAccessories(descriptions))
    }
}

// MARK: - the pure mapping (dict → model), so a REAL captured dict is testable host-app-free

extension DeviceParsers {
    /// IOPS descriptions → accessory rows. The internal battery is dropped: it is the popover's own
    /// subject, not a "device" (this is precisely what `pmset -g accps` did by skipping InternalBattery).
    static func parseAccessories(_ descriptions: [[String: Any]]) -> [AccessoryPowerSource] {
        descriptions.compactMap { d -> AccessoryPowerSource? in
            func str(_ k: String) -> String? {
                guard let s = d[k] as? String else { return nil }
                let t = s.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            func num(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
            func flag(_ k: String) -> Bool? { (d[k] as? NSNumber)?.boolValue }

            guard str(kIOPSTypeKey) != kIOPSInternalBatteryType,
                  str(kIOPSTransportTypeKey) != kIOPSInternalType,
                  flag(kIOPSIsPresentKey) != false,
                  let name = str(kIOPSNameKey),
                  let current = num(kIOPSCurrentCapacityKey) else { return nil }
            // Accessories report Max Capacity = 100, but normalise rather than assume it.
            let ceiling = num(kIOPSMaxCapacityKey) ?? 100
            let raw = ceiling > 0 ? Int((100.0 * Double(current) / Double(ceiling)).rounded()) : current
            return AccessoryPowerSource(name: name,
                                        accessoryID: str("Accessory Identifier"),
                                        partID: str("Part Identifier"),
                                        category: str("Accessory Category"),
                                        percent: min(100, max(0, raw)),
                                        isCharging: flag(kIOPSIsChargingKey),
                                        transport: str(kIOPSTransportTypeKey))
        }
    }
}
