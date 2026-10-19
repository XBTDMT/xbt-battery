import Foundation

/// #30 R8 icon rule: every device row ALWAYS gets a device SF Symbol chosen from the device class AND
/// the product name; `battery.100` is the last resort; never blank. PURE — no AppKit — so the whole
/// table is testable host-app-free. `DeviceIconTests` proves EVERY symbol this can return resolves via
/// `NSImage(systemSymbolName:)` on this OS, which is the check that would have caught the trackpad blank
/// (§14-B6: `trackpad` does not exist as a symbol here; `rectangle.and.hand.point.up.left` does).
///
/// Name rules run before the class switch only where the class alone cannot tell the products apart
/// (AirPods variants, Beats). The name is matched case-insensitively.
enum DeviceIcon {

    /// The complete set of symbols this can return — the totality test iterates it, so adding a case
    /// below without adding its symbol here fails the test rather than shipping a blank.
    static let allSymbols: [String] = [
        "airpodspro", "airpodsmax", "airpods.gen3", "airpods",
        "beats.headphones", "headphones",
        "magicmouse", "keyboard", "rectangle.and.hand.point.up.left",
        "applewatch", "iphone", "battery.100",
    ]

    static func symbol(for deviceClass: DeviceClass, name: String) -> String {
        let n = name.lowercased()
        switch deviceClass {
        case .airpods:
            if n.contains("pro") { return "airpodspro" }
            if isThirdGeneration(n) { return "airpods.gen3" }
            return "airpods"
        case .airpodsMax:
            return "airpodsmax"
        case .headphones:
            return isBeats(n) ? "beats.headphones" : "headphones"
        case .mouse:
            return "magicmouse"
        case .keyboard:
            return "keyboard"
        case .trackpad:
            // §14-B6: no `trackpad` symbol exists on this OS (it rendered nil, i.e. a blank row).
            return "rectangle.and.hand.point.up.left"
        case .applewatch:
            return "applewatch"
        case .iphone:
            return "iphone"
        case .generic:
            // A Beats product with no usable Accessory Category still has a name to go on.
            return isBeats(n) ? "beats.headphones" : "battery.100"
        }
    }

    /// "AirPods 3", "AirPods (3rd generation)". The bare "3" test is anchored to the AirPods word so
    /// "Alex's AirPods #3" (a numbered pair) is NOT the third generation.
    private static func isThirdGeneration(_ n: String) -> Bool {
        n.contains("(3rd") || n.contains("airpods 3")
    }

    private static func isBeats(_ n: String) -> Bool { n.contains("beats") }
}
