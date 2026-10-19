import Foundation
import IOKit

// 31 §1.3 / G-5 / G-7 · the wired half of "Powered by this Mac". Read-only IOUSB-plane walks: every
// IOUSBHostDevice, hubs and billboard devices filtered out, what is left is a LEAF. No IOKit write, no SMC,
// no helper. The per-read stamp walk lives in PortPowerSource (it calls `leaves()` once per successful
// diagnostics read — one IOServiceGetMatchingServices, milliseconds, ~60 per hour, spec §3.7); the Devices
// page's `.task` runs one more walk via `PortPowerSource.refreshLeaves()`.

/// One IOUSBHostDevice as the walk saw it — the pure filter's input.
struct USBNode: Equatable, Sendable {
    let registryID: UInt64
    let productName: String?
    let vendorName: String?
    let deviceClass: Int?
    let interfaceClasses: [Int]
    /// True when the device has USB devices under it in the IOUSB plane (a hub, a dock).
    let hasChildDevices: Bool
    /// Numeric USB vendor id (`idVendor`); nil when unread. Apple is 0x05AC.
    var vendorID: Int? = nil
}

enum USBLeafFilter {
    static let hubClass = 9
    static let billboardClass = 0x11
    static let massStorageClass = 8
    static let appleVendorID = 0x05AC

    /// Hubs (class 9, a hub interface, or USB devices beneath) and billboard devices (class 0x11, a billboard
    /// interface, or "Billboard" in the name) are never leaves. A device with no product name IS a leaf —
    /// it still counts toward "exactly one new leaf" — with an empty name.
    static func leaves(_ nodes: [USBNode]) -> [USBLeaf] {
        nodes.compactMap { n in
            if n.hasChildDevices || n.deviceClass == hubClass || n.interfaceClasses.contains(hubClass) { return nil }
            if n.deviceClass == billboardClass || n.interfaceClasses.contains(billboardClass) { return nil }
            if n.productName?.localizedCaseInsensitiveContains("billboard") == true { return nil }
            let name = n.productName ?? ""
            return USBLeaf(registryID: n.registryID, productName: name, vendorName: n.vendorName,
                           kind: kind(productName: name, deviceClass: n.deviceClass, interfaceClasses: n.interfaceClasses,
                                      vendorID: n.vendorID, vendorName: n.vendorName))
        }
    }

    /// `.iphone` needs the name AND an Apple vendor: the numeric id when it was read (it is authoritative),
    /// else the "Apple Inc." vendor string. A third-party "iPhone Dock" is `.other`; an iPad is `.other`.
    static func kind(productName: String, deviceClass: Int?, interfaceClasses: [Int],
                     vendorID: Int? = nil, vendorName: String? = nil) -> USBLeafKind {
        let name = productName.lowercased()
        let isApple = vendorID.map { $0 == appleVendorID } ?? (vendorName == "Apple Inc.")
        if name.contains("iphone") && isApple { return .iphone }
        if deviceClass == massStorageClass || interfaceClasses.contains(massStorageClass) { return .massStorage }
        if name.contains("keyboard") { return .keyboard }
        return .other
    }
}

/// Production walk over the IOUSB plane. A failed match returns nil, never [] — the caller then stamps
/// nothing and seeds nothing (final review M1; absence is not a fact). `LeafStamps` never forgets a stamp,
/// so an empty walk can never make an old leaf "new" either.
struct LiveUSBLeafEnumerator: USBLeafEnumerating {
    func leaves() -> [USBLeaf]? { Self.nodes().map(USBLeafFilter.leaves) }

    /// nil when `IOServiceGetMatchingServices` fails.
    static func nodes() -> [USBNode]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var out: [USBNode] = []
        var device = IOIteratorNext(iterator)
        while device != 0 {
            // An unreadable registry id skips the node (id 0 would collide across devices — absence is not
            // a fact). The device is still released exactly once, here, on every path.
            if let n = node(device) { out.append(n) }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
        return out
    }

    private static func node(_ device: io_registry_entry_t) -> USBNode? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(device, &id) == KERN_SUCCESS else { return nil }
        var interfaces: [Int] = []
        forEachChild(of: device, plane: "IOService") { child in
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0, let c = int(child, "bInterfaceClass") {
                interfaces.append(c)
            }
        }
        var hasChildDevices = false
        forEachChild(of: device, plane: "IOUSB") { child in
            if IOObjectConformsTo(child, "IOUSBHostDevice") != 0 { hasChildDevices = true }
        }
        return USBNode(registryID: id, productName: string(device, "USB Product Name"),
                       vendorName: string(device, "USB Vendor Name"), deviceClass: int(device, "bDeviceClass"),
                       interfaceClasses: interfaces, hasChildDevices: hasChildDevices,
                       vendorID: int(device, "idVendor"))
    }

    private static func forEachChild(of entry: io_registry_entry_t, plane: String,
                                     _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            body(child)
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? { property(entry, key) as? String }
    private static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? { (property(entry, key) as? NSNumber)?.intValue }
}

/// Test / harness seam: a leaf set the caller replaces between reads; `setFailed()` makes the walks fail (nil)
/// until the next `set`.
final class SettableUSBLeafEnumerator: USBLeafEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [USBLeaf]?
    init(_ leaves: [USBLeaf] = []) { current = leaves }
    func set(_ leaves: [USBLeaf]) { lock.lock(); current = leaves; lock.unlock() }
    func setFailed() { lock.lock(); current = nil; lock.unlock() }
    func leaves() -> [USBLeaf]? { lock.lock(); defer { lock.unlock() }; return current }
}

/// G-7 · each leaf is stamped with the monotonic time of the read that first enumerated it. A registry id
/// is unique for the boot, so a stamp is kept after the leaf leaves (a re-plug is a new id): an empty walk
/// can never re-stamp an old leaf as new. Only a SUCCESSFUL walk is observed — a failed one (nil) sets no
/// seed and no stamps (final review M1). Bounded: past `capacity`, the oldest departed
/// leaves are evicted — never one still on the bus.
struct LeafStamps: Equatable, Sendable {
    static let capacity = 256
    private var stamps: [UInt64: TimeInterval] = [:]
    /// The monotonic time of the first walk (the launch seed); nil before any walk.
    private(set) var seedAt: TimeInterval?

    mutating func observe(_ leaves: [USBLeaf], at monotonic: TimeInterval) {
        if seedAt == nil { seedAt = monotonic }
        for leaf in leaves where stamps[leaf.registryID] == nil { stamps[leaf.registryID] = monotonic }
        guard stamps.count > Self.capacity else { return }
        let onBus = Set(leaves.map(\.registryID))
        let departed = stamps.filter { !onBus.contains($0.key) }.sorted { $0.value < $1.value }
        for (id, _) in departed.prefix(stamps.count - Self.capacity) { stamps[id] = nil }
    }

    func firstSeen(_ id: UInt64) -> TimeInterval? { stamps[id] }
}

/// A corroborated name stored per PortIndex until the port goes absent (spec §1.3).
struct PortName: Equatable, Sendable {
    let name: String
    let kind: USBLeafKind

    init(name: String, kind: USBLeafKind) {
        self.name = name
        self.kind = kind
    }

    /// A matched leaf with no product name (empty or whitespace-only) is still unnamed on screen; a padded
    /// name is trimmed.
    init(leaf: USBLeaf) {
        let trimmed = leaf.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? DeviceNaming.unnamedLabel : trimmed
        kind = leaf.kind
    }
}
