import Foundation

/// 31 §1.3 naming rule (T6, G-5, O1, G-7). A row or the notice names a device only when corroborated:
/// (a) proven port parentage — NOT built until stage 0 proves U1 (spec §7.1); (b) an iPhone confirmed by
/// MobileDevice over USB with ExternalConnected while exactly one port sources (applied in
/// PortPowerSource.notePhone); (c) the timing match below. Otherwise the label is "USB-C device" (owner
/// 2026-10-15: no leading "A" — a label, not a sentence; spec 30 §16 row "31-7 · label").
enum DeviceNaming {
    static let unnamedLabel = "USB-C device"
    /// Two ~60 s record refreshes plus a poll (G-7).
    static let window: TimeInterval = 130
    static let allSymbols = ["iphone", "externaldrive.fill", "keyboard", "cable.connector"]

    /// (c) Exactly one port started sourcing on this read AND exactly one leaf is new: first enumerated
    /// strictly after the later of the port's last present read and the launch seed,
    /// no later than the port's first drawing read, and at most `window` before it. The caller passes only
    /// leaves not already claimed by another port's name.
    static func timingMatch(stamps: LeafStamps, leaves: [USBLeaf], portLastPresentAt: TimeInterval?,
                            portFirstDrawingAt: TimeInterval, newlySourcingPortCount: Int) -> USBLeaf? {
        // The floor is the LATER of the port's last present read and the launch seed: a port last seen before
        // the first walk must not make leaves stamped at the seed (already on the bus) look new.
        let floor: TimeInterval?
        switch (portLastPresentAt, stamps.seedAt) {
        case let (present?, seed?): floor = max(present, seed)
        case let (present?, nil): floor = present
        case let (nil, seed?): floor = seed
        case (nil, nil): floor = nil
        }
        guard newlySourcingPortCount == 1, let floor else { return nil }
        let fresh = leaves.filter { leaf in
            guard let t = stamps.firstSeen(leaf.registryID) else { return false }
            return t > floor && t <= portFirstDrawingAt && portFirstDrawingAt - t <= window
        }
        return fresh.count == 1 ? fresh[0] : nil
    }

    /// The row / notice glyph (spec §2.1): `iphone`, `externaldrive.fill`, `keyboard`, else `cable.connector`.
    static func symbol(for kind: USBLeafKind?) -> String {
        switch kind {
        case .iphone?: return "iphone"
        case .massStorage?: return "externaldrive.fill"
        case .keyboard?: return "keyboard"
        case .other?, nil: return "cable.connector"
        }
    }
}
