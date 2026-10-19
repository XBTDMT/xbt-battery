import Foundation
import IOKit
import IOKit.ps

/// Top-level C callback for `IOPSNotificationCreateRunLoopSource` (must not capture). It recovers
/// the reader from the opaque context and invokes its stored `onChange`. (SPEC WI-1.2.)
private func liveBatteryPowerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let reader = Unmanaged<LiveBatteryReader>.fromOpaque(context).takeUnretainedValue()
    reader.handlePowerSourceChange()
}

/// Live IOKit reader: IOPS power-source info for live state, `AppleSmartBattery` for diagnostics,
/// and an `IOPSNotificationCreateRunLoopSource` for event-driven updates. (decision #14, R-06.)
final class LiveBatteryReader: PowerSourceReading {

    private var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var callbackContext: UnsafeMutableRawPointer?   // Unmanaged.passRetained(self)

    func readLiveDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            // IOPSGetPowerSourceDescription is a Get (unretained) — do not release.
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType {
                return desc   // the INTERNAL battery (ignore UPS / other sources)
            }
        }
        return nil
    }

    func readDiagnosticsProperties() -> [String: Any]? {
        // Match by class, not a hard-coded path (Apple Silicon). kIOMainPortDefault = 12+ alias.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              var dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        // macOS 27 moved the gas-gauge dict — Temperature included — OFF this node and onto its CHILD
        // `AppleSmartBatteryPack`. Fold that child in under our synthetic key so the SINGLE diagnostics
        // read still feeds every parser (no second poll), and the pure parsers stay dict-in/struct-out.
        if let pack = Self.copyPackProperties(of: service) {
            dict[BatteryTelemetryParser.packPropertiesKey] = pack
        }
        return dict
    }

    /// READ-ONLY registry walk for the `AppleSmartBatteryPack` child of the battery node. nil where the
    /// child does not exist or has no properties (pre-27 machines) — the parser's ladder then just uses
    /// the top-level keys. No IOKit write, no SMC.
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

    func startLiveUpdates(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(liveBatteryPowerSourceChanged, context)?.takeRetainedValue() else {
            // Source creation failed — the slow timer (WI-1.3) is the fallback. Balance the retain.
            NSLog("battery_app: IOPSNotificationCreateRunLoopSource returned nil; relying on the slow timer")
            Unmanaged<LiveBatteryReader>.fromOpaque(context).release()
            return
        }
        callbackContext = context
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)   // fires on the main run loop
    }

    func stopLiveUpdates() {   // idempotent
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil   // ARC releases the +1 from takeRetainedValue
        }
        if let context = callbackContext {
            Unmanaged<LiveBatteryReader>.fromOpaque(context).release()   // balance passRetained(self)
            callbackContext = nil
        }
        onChange = nil
    }

    fileprivate func handlePowerSourceChange() {
        onChange?()
    }
}
