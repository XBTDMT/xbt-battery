import Foundation

/// #iPhone · PURE. Folds the two phone routes into one Devices-card row (`DeviceBattery`, class `.iphone`):
/// the sync-link reading wins when present (exact percent + charging); otherwise a fresh hotspot beacon
/// supplies presence and its coarse percent. Nothing here reads hardware — tested host-app-free.
enum PhoneBatteryModel {
    /// How the row was sourced — the card says so when the figure is the beacon's approximation.
    enum Provenance: Equatable, Sendable { case sync(viaWiFi: Bool), beacon }

    struct Resolved: Equatable, Sendable {
        let device: DeviceBattery
        let provenance: Provenance
        /// 31 §1.3: the phone's own "on external power" flag from the sync read (nil for a beacon row).
        var externalConnected: Bool? = nil
        /// MobileDevice interface type 1 — the phone is on a cable to THIS Mac.
        var viaUSB: Bool = false
        /// `MonotonicClocks.monotonicRaw` when the sync read STARTED (never when it was noted or re-resolved);
        /// nil for a beacon row or an unstamped reading. Corroboration (b) trusts a link only by this time.
        var readAt: TimeInterval? = nil
    }

    /// A beacon older than this (seconds) no longer counts as "nearby".
    static let beaconMaxAge = 180

    static func resolve(sync: PhoneSyncResult?, beacons: [PhoneBeacon], beaconSeenAt: Int?, now: Int,
                        syncReadAt: TimeInterval? = nil) -> Resolved? {
        if case .reading(let r)? = sync {
            let device = DeviceBattery(id: "phone:" + (r.productType.isEmpty ? r.name : r.productType), name: r.name,
                                       deviceClass: .iphone,
                                       components: [DeviceBatteryComponent(label: nil, percent: r.percent, charging: r.charging)],
                                       address: nil, asOf: now)
            return Resolved(device: device, provenance: .sync(viaWiFi: r.viaWiFi),
                            externalConnected: r.externalConnected, viaUSB: r.viaUSB, readAt: syncReadAt)
        }
        guard let seen = beaconSeenAt, now - seen <= beaconMaxAge,
              let b = beacons.first(where: { $0.percent != nil }) ?? beacons.first, let pct = b.percent else { return nil }
        let device = DeviceBattery(id: "phone:" + (b.model.isEmpty ? b.id : b.model), name: b.name, deviceClass: .iphone,
                                   components: [DeviceBatteryComponent(label: nil, percent: pct, charging: nil)],
                                   address: nil, asOf: seen)
        return Resolved(device: device, provenance: .beacon)
    }

    /// The thin-state line under the card. nil when the row is exact (sync) or absent for a plain reason.
    static func note(resolved: Resolved?, sync: PhoneSyncResult?, beaconUnavailable: String?) -> String? {
        switch resolved?.provenance {
        case .sync?: return nil
        case .beacon?: return "iPhone level from its nearby beacon · approximate"
        case nil:
            if case .unavailable(let why)? = sync { return "iPhone unavailable — \(why)" }
            if let beaconUnavailable { return "iPhone unavailable — \(beaconUnavailable)" }
            return nil
        }
    }

    // MARK: - 31 §1.3 · which connection to read, and what the port source may use

    static let usbInterfaceType: Int32 = 1
    static let wifiInterfaceType: Int32 = 2

    /// The reader collects every CONNECTED phone for up to 1.5 s; this picks the one to open a session on:
    /// the USB interface wins, else the first candidate. nil when nothing connected.
    static func prefer(candidates: [Int32]) -> Int? {
        candidates.firstIndex(of: usbInterfaceType) ?? (candidates.isEmpty ? nil : 0)
    }

    /// What the port source needs from an exact (sync) reading: its percent and charging flag for the
    /// row, and — corroboration (b)'s phone half — whether it is on a cable to this Mac AND on external power.
    static func link(_ resolved: Resolved?) -> PhoneLink? {
        guard let r = resolved, case .sync = r.provenance, let part = r.device.components.first else { return nil }
        return PhoneLink(percent: part.percent, charging: part.charging == true,
                         usbPowered: r.viaUSB && r.externalConnected == true, readAt: r.readAt)
    }
}

/// 31 §1.3 · the phone as the port source sees it (PortPowerSource.notePhone).
struct PhoneLink: Equatable, Sendable {
    let percent: Int
    let charging: Bool
    /// MobileDevice over USB with ExternalConnected — corroboration (b)'s phone half.
    let usbPowered: Bool
    /// The monotonic time the sync reading STARTED (`MonotonicClocks.monotonicRaw`); nil = unknown, and an
    /// unknown time never corroborates (b). Re-noting the same reading keeps this value.
    var readAt: TimeInterval? = nil
}
