import Foundation
import Combine

/// #iPhone · the phone's two routes behind one observable. `refresh()` runs the sync-link read (seconds
/// over Wi-Fi, off the main thread); `startBeacon()` / `stopBeacon()` bracket the hotspot browse to the
/// Devices page's lifetime (§8: no read survives the page). `resolved` is the row the card shows.
@MainActor
final class PhoneBatterySource: ObservableObject {
    @Published private(set) var resolved: PhoneBatteryModel.Resolved?
    @Published private(set) var note: String?
    private var lastSync: PhoneSyncResult?
    /// `clocks.monotonicRaw()` taken BEFORE the last sync read began (the reading's own time, spec 31 §1.3).
    private var lastSyncStartedAt: TimeInterval?
    private let clocks: MonotonicClocks

    private let sync: any PhoneSyncReadable
    private let beacon: any PhoneBeaconBrowsing
    private let now: () -> Int
    private var beacons: [PhoneBeacon] = []
    private var beaconSeenAt: Int?
    private var refreshing = false

    /// The sync read's budget. A Wi-Fi session took ~2–4 s on this Mac; the page never waits on it.
    static let syncTimeout: TimeInterval = 8

    init(sync: any PhoneSyncReadable = LiveMobileDevicePhoneReader(),
         beacon: any PhoneBeaconBrowsing = LiveHotspotBeaconBrowser(),
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         clocks: MonotonicClocks = .live) {
        self.sync = sync; self.beacon = beacon; self.now = now; self.clocks = clocks
    }

    func startBeacon() {
        beacon.start { [weak self] found in
            guard let self else { return }
            self.beacons = found
            if !found.isEmpty { self.beaconSeenAt = self.now() }
            self.recompute()
        }
        recompute()
    }

    func stopBeacon() { beacon.stop() }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let startedAt = clocks.monotonicRaw()
        let result = await sync.read(timeout: Self.syncTimeout)
        lastSync = result
        lastSyncStartedAt = startedAt
        recompute()
    }

    private func recompute() {
        resolved = PhoneBatteryModel.resolve(sync: lastSync, beacons: beacons, beaconSeenAt: beaconSeenAt, now: now(),
                                               syncReadAt: lastSyncStartedAt)
        note = PhoneBatteryModel.note(resolved: resolved, sync: lastSync, beaconUnavailable: beacon.unavailableReason)
    }
}

/// Test / harness seams: a fixed sync answer and a beacon browser that reports a fixed set on start.
struct FixedPhoneSyncReader: PhoneSyncReadable {
    let result: PhoneSyncResult
    func read(timeout: TimeInterval) async -> PhoneSyncResult { result }
}

@MainActor
final class FixedPhoneBeaconBrowser: PhoneBeaconBrowsing {
    let beacons: [PhoneBeacon]
    let unavailableReason: String?
    private(set) var browsing = false
    init(beacons: [PhoneBeacon] = [], unavailableReason: String? = nil) { self.beacons = beacons; self.unavailableReason = unavailableReason }
    func start(onUpdate: @escaping @MainActor ([PhoneBeacon]) -> Void) { browsing = true; onUpdate(beacons) }
    func stop() { browsing = false }
}
