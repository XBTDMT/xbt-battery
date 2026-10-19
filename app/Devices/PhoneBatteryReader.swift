import Foundation
import ObjectiveC

// #iPhone (owner ask 2026-09-10: "why can we not see my iphone … in the devices tab?"). macOS does not
// publish an iPhone's battery to apps — the Batteries widget's own list (BatteryCenter over IOPS) is
// Bluetooth accessories only, and iOS does not expose the GATT battery service to a Mac. Two routes DO
// reach the phone from an unsandboxed, unentitled process, both verified on this Mac (macOS 27.0
// 26A5425a, 2026-09-10, probes in the session scratchpad; ledger entry of the same date):
//
//   1. **Finder's sync link** — MobileDevice.framework (private). Delivers the phone over USB *or*
//      Wi-Fi (Finder → "Show this iPhone when on Wi-Fi") and answers the EXACT figures through the
//      `com.apple.mobile.battery` domain: BatteryCurrentCapacity, BatteryIsCharging, ExternalConnected.
//      Needs an existing pairing (the "Trust This Computer" record); a session over Wi-Fi takes seconds.
//   2. **The Instant-Hotspot beacon** — Sharing.framework (private) `SFRemoteHotspotSession`. The phone
//      advertises name · model · battery · signal over BLE for the Wi-Fi menu; browsing needs no
//      entitlement. Coarse percent, refreshed every 30–60 s, no charging flag, works with no Wi-Fi.
//
// Both are dlopen/dlsym or ObjC-runtime lookups — the same idiom as `AccessoryPowerSourceReader` and
// `IOReportPowerSampler` — and both degrade to an honest `.unavailable` / empty when a symbol is
// missing. Nothing here writes to the phone; the helper is not involved. Personal use only.

// MARK: - the sync-link read (exact figures)

struct PhoneSyncReading: Equatable, Sendable {
    let name: String
    /// "iPhone18,2"
    let productType: String
    let percent: Int
    let charging: Bool
    /// nil when the phone did not answer the key (absence is not "unplugged").
    let externalConnected: Bool?
    /// MobileDevice interface type 2 = Wi-Fi, 1 = USB.
    let viaWiFi: Bool
    /// 31 §1.3: MobileDevice interface type 1 = USB (a cable to this Mac).
    var viaUSB: Bool = false
}

enum PhoneSyncResult: Equatable, Sendable {
    case reading(PhoneSyncReading)
    /// The subscription worked and no paired phone answered within the timeout.
    case noDevice
    /// The framework or a symbol is missing, or the session failed — the reason, for the card.
    case unavailable(String)
}

protocol PhoneSyncReadable: Sendable {
    func read(timeout: TimeInterval) async -> PhoneSyncResult
}

/// Production reader over MobileDevice.framework. One read at a time (the C callback has no context
/// pointer, so the in-flight read lives in a locked static). 31 §1.3: each read subscribes and COLLECTS
/// every CONNECTED phone — retaining each reference (`AMDeviceRetain`) with its `AMDeviceGetInterfaceType` —
/// for up to `collectWindow` (or until a USB one arrives), unsubscribes, opens ONE session on the preferred
/// candidate (`PhoneBatteryModel.prefer`, USB wins), then releases every reference (`AMDeviceRelease`).
/// No session runs inside the callback. Runs on its own thread with a run loop — MobileDevice delivers
/// notifications on the subscribing thread's run loop.
final class LiveMobileDevicePhoneReader: PhoneSyncReadable {
    private struct NotifInfo { var dev: UnsafeMutableRawPointer?; var msg: UInt32; var sub: UnsafeMutableRawPointer? }
    private typealias CB = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias SubF = @convention(c) (CB, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias UnsubF = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias DevF = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias CopyF = @convention(c) (UnsafeMutableRawPointer?, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias RetainF = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias ReleaseF = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// 31 §1.3: how long to collect candidates before choosing; the Devices page never waits longer on it.
    static let collectWindow: TimeInterval = 1.5

    private struct Symbols {
        let subscribe: SubF, unsubscribe: UnsubF
        let connect: DevF, isPaired: DevF, validate: DevF, start: DevF, stop: DevF, disconnect: DevF, interface: DevF
        let copyValue: CopyF
        let retain: RetainF, release: ReleaseF
    }

    private struct Candidate { let ref: UnsafeMutableRawPointer; let interface: Int32 }

    /// The in-flight read the C callback reports into. Guarded by `lock`; only one read runs at a time.
    /// `candidates` is touched only on the read's own run-loop thread (the callback runs there).
    private final class Pending: @unchecked Sendable {
        var candidates: [Candidate] = []
        var result: PhoneSyncResult?
        let symbols: Symbols
        init(symbols: Symbols) { self.symbols = symbols }
    }
    nonisolated(unsafe) private static var pending: Pending?
    private static let lock = NSLock()
    private static let serial = DispatchQueue(label: "battery_app.phone.mobiledevice")

    private static let symbols: Symbols? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else { return nil }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let subscribe = sym("AMDeviceNotificationSubscribe", SubF.self),
              let unsubscribe = sym("AMDeviceNotificationUnsubscribe", UnsubF.self),
              let connect = sym("AMDeviceConnect", DevF.self),
              let isPaired = sym("AMDeviceIsPaired", DevF.self),
              let validate = sym("AMDeviceValidatePairing", DevF.self),
              let start = sym("AMDeviceStartSession", DevF.self),
              let stop = sym("AMDeviceStopSession", DevF.self),
              let disconnect = sym("AMDeviceDisconnect", DevF.self),
              let interface = sym("AMDeviceGetInterfaceType", DevF.self),
              let copyValue = sym("AMDeviceCopyValue", CopyF.self),
              let retain = sym("AMDeviceRetain", RetainF.self),
              let release = sym("AMDeviceRelease", ReleaseF.self) else { return nil }
        return Symbols(subscribe: subscribe, unsubscribe: unsubscribe, connect: connect, isPaired: isPaired,
                       validate: validate, start: start, stop: stop, disconnect: disconnect, interface: interface,
                       copyValue: copyValue, retain: retain, release: release)
    }()

    /// The C callback: no context, so it reads the locked static. It only COLLECTS (retained ref + interface).
    private static let callback: CB = { info, _ in
        guard let i = info?.assumingMemoryBound(to: NotifInfo.self).pointee, i.msg == 1, let d = i.dev else { return }
        lock.lock(); let p = pending; lock.unlock()
        guard let p, let retained = p.symbols.retain(d) else { return }
        p.candidates.append(Candidate(ref: retained, interface: p.symbols.interface(retained)))
    }

    /// One session on the chosen phone (moved out of the callback, unchanged in what it reads).
    private static func session(_ d: UnsafeMutableRawPointer, _ s: Symbols) -> PhoneSyncResult {
        guard s.connect(d) == 0 else { return .unavailable("the phone did not accept a connection") }
        defer { _ = s.disconnect(d) }
        guard s.isPaired(d) == 1, s.validate(d) == 0 else { return .unavailable("this Mac is not trusted by the phone") }
        guard s.start(d) == 0 else { return .unavailable("the phone refused a session") }
        defer { _ = s.stop(d) }
        func value(_ domain: String?, _ key: String) -> Any? {
            s.copyValue(d, domain.map { $0 as CFString }, key as CFString)?.takeRetainedValue()
        }
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        guard let pct = int(value("com.apple.mobile.battery", "BatteryCurrentCapacity")) else {
            return .unavailable("the phone answered without a battery figure")
        }
        let iface = s.interface(d)
        return .reading(PhoneSyncReading(
            name: (value(nil, "DeviceName") as? String) ?? "iPhone",
            productType: (value(nil, "ProductType") as? String) ?? "",
            percent: max(0, min(100, pct)),
            charging: int(value("com.apple.mobile.battery", "BatteryIsCharging")) == 1,
            // An unanswered key stays nil — absence is not "not plugged in".
            externalConnected: int(value("com.apple.mobile.battery", "ExternalConnected")).map { $0 == 1 },
            viaWiFi: iface == PhoneBatteryModel.wifiInterfaceType,
            viaUSB: iface == PhoneBatteryModel.usbInterfaceType))
    }

    func read(timeout: TimeInterval) async -> PhoneSyncResult {
        guard let symbols = Self.symbols else { return .unavailable("MobileDevice framework not available on this macOS") }
        return await withCheckedContinuation { cont in
            // One read at a time; each on a fresh thread with its own run loop (MobileDevice's contract).
            Self.serial.async {
                let done = DispatchSemaphore(value: 0)
                let box = Pending(symbols: symbols)
                let thread = Thread {
                    Self.lock.lock(); Self.pending = box; Self.lock.unlock()
                    var sub: UnsafeMutableRawPointer? = nil
                    let rc = symbols.subscribe(Self.callback, 0, 0, nil, &sub)
                    if rc != 0 {
                        box.result = .unavailable("device notifications refused (\(rc))")
                    } else {
                        let started = Date()
                        let deadline = started.addingTimeInterval(timeout)
                        let windowEnd = started.addingTimeInterval(Self.collectWindow)
                        while Date() < deadline {
                            let interfaces = box.candidates.map(\.interface)
                            if interfaces.contains(PhoneBatteryModel.usbInterfaceType) { break }   // USB wins outright
                            if !interfaces.isEmpty, Date() >= windowEnd { break }
                            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
                        }
                    }
                    // Late callbacks are inert from here on: the callback reads `pending` under the lock and
                    // returns without retaining when it is nil, and this thread's run loop is not run again
                    // until after `unsubscribe`, so nothing touches `candidates` while the session runs.
                    Self.lock.lock(); Self.pending = nil; Self.lock.unlock()
                    if rc == 0, let i = PhoneBatteryModel.prefer(candidates: box.candidates.map(\.interface)) {
                        // The session runs while STILL subscribed (as before 31 §1.3): a Wi-Fi ref found via
                        // RemotePairing may lose its link if the browser is cancelled first.
                        box.result = Self.session(box.candidates[i].ref, symbols)
                    }
                    // Every retained reference is released exactly once, on every path (incl. subscribe refused).
                    for c in box.candidates { symbols.release(c.ref) }
                    if rc == 0 { _ = symbols.unsubscribe(sub) }
                    done.signal()
                }
                thread.name = "battery_app.phone.mobiledevice.runloop"
                thread.start()
                done.wait()
                cont.resume(returning: box.result ?? .noDevice)
            }
        }
    }
}

// MARK: - the hotspot beacon (presence + coarse percent)

struct PhoneBeacon: Equatable, Sendable {
    let id: String
    let name: String
    /// "iPhone18,2"
    let model: String
    /// The advert's battery figure (0…100), nil when the advert carried none.
    let percent: Int?
}

/// Start/stop browsing; `onUpdate` is called on the MAIN thread with the current set of nearby phones.
@MainActor
protocol PhoneBeaconBrowsing: AnyObject {
    func start(onUpdate: @escaping @MainActor ([PhoneBeacon]) -> Void)
    func stop()
    /// nil when the framework and class resolved; else the reason the beacon route is unavailable.
    var unavailableReason: String? { get }
}

/// Production browser over Sharing.framework's `SFRemoteHotspotSession` (the Wi-Fi menu's hotspot list).
/// The delegate protocol is informal at runtime — the selector MUST be `session:updatedFoundDevices:`.
@MainActor
final class LiveHotspotBeaconBrowser: PhoneBeaconBrowsing {
    private var session: NSObject?
    private var delegate: Delegate?
    private(set) var unavailableReason: String?

    private final class Delegate: NSObject {
        var onUpdate: (@MainActor ([PhoneBeacon]) -> Void)?
        @objc func session(_ session: Any, updatedFoundDevices devices: Any) {
            let beacons = (devices as? [NSObject] ?? []).map { d in
                PhoneBeacon(id: (d.value(forKey: "deviceIdentifier") as? String) ?? (d.value(forKey: "deviceName") as? String) ?? "phone",
                            name: (d.value(forKey: "deviceName") as? String) ?? "iPhone",
                            model: (d.value(forKey: "model") as? String) ?? "",
                            percent: (d.value(forKey: "batteryLife") as? NSNumber).map { max(0, min(100, $0.intValue)) })
            }
            let cb = onUpdate
            DispatchQueue.main.async { MainActor.assumeIsolated { cb?(beacons) } }
        }
    }

    func start(onUpdate: @escaping @MainActor ([PhoneBeacon]) -> Void) {
        stop()
        guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil,
              let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else {
            unavailableReason = "the hotspot beacon is not available on this macOS"; return
        }
        let s = cls.init()
        guard s.responds(to: NSSelectorFromString("setDelegate:")), s.responds(to: NSSelectorFromString("startBrowsing")) else {
            unavailableReason = "the hotspot beacon API changed on this macOS"; return
        }
        let d = Delegate(); d.onUpdate = onUpdate
        s.perform(NSSelectorFromString("setDelegate:"), with: d)
        s.perform(NSSelectorFromString("startBrowsing"))
        session = s; delegate = d; unavailableReason = nil
    }

    func stop() {
        if let s = session, s.responds(to: NSSelectorFromString("stopBrowsing")) { s.perform(NSSelectorFromString("stopBrowsing")) }
        session = nil; delegate = nil
    }
}
