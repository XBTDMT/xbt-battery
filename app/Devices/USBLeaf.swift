import Foundation

/// 31 §2.1 row icon: what a leaf looks like, from its product name and interface classes (never from
/// `UsbPowerSinkAllocation`, which is an allocation, not a measurement).
enum USBLeafKind: String, Equatable, Sendable { case iphone, massStorage, keyboard, other }

/// spec 31 §1.3 / G-7 — one USB LEAF device (`IOUSBHostDevice`; hubs and billboard devices already
/// filtered out by the enumerator). Its name is used only when corroborated (§1.3 naming rule).
struct USBLeaf: Equatable, Sendable {
    let registryID: UInt64
    let productName: String
    let vendorName: String?
    /// Decided by `USBLeafFilter.kind`; `.other` when nothing says more (the row then shows `cable.connector`).
    var kind: USBLeafKind = .other
}

/// The IOUSB leaf walk behind a seam, so `PortPowerSource` stays host-app-free and the render harness
/// never walks the owner's real USB bus (spec §2.5). The live walker is `LiveUSBLeafEnumerator`
/// (`WiredDeviceSource.swift`); `PortPowerSource` stamps what it returns on every successful read.
protocol USBLeafEnumerating: Sendable {
    /// The leaves on the bus; nil when the walk FAILED — no information, never an empty bus (final review M1:
    /// a failed walk must not seed or stamp `LeafStamps`, or the next good walk makes every old leaf "new").
    func leaves() -> [USBLeaf]?
}

/// The empty bus (a successful walk that found nothing) — the test / harness seam.
struct EmptyUSBLeafEnumerator: USBLeafEnumerating {
    func leaves() -> [USBLeaf]? { [] }
}
