import Foundation

// Sprint 3.7 B2 — the PRODUCTION ComponentPowerSampling: a no-root IOReport reader of the "Energy Model"
// group. On macOS 27 the IOReport symbols are NOT at the classic framework path (gone from the cryptex);
// they resolve from /usr/lib/libIOReport.dylib via the dyld shared cache (research-11), so we dlopen +
// dlsym. This is APP-SIDE and unprivileged — NOT the helper (the SMC-DEAD gate forbids dlopen in the
// helper; there is no such constraint on the app). Every failure path returns nil → the reader hides the
// section honestly. Each call creates and releases its own subscription (stateless → no shared IOReport
// state between samples). Mirrors knowledge/probes/ioreport_probe2.m, ported to Swift.

private typealias SubRef = OpaquePointer
private typealias CopyChansFn  = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
private typealias CreateSubFn  = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> SubRef?
private typealias CreateSampFn = @convention(c) (SubRef?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias DeltaFn      = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias IterateFn    = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
private typealias ChanStrFn    = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias SimpleIntFn  = @convention(c) (CFDictionary, Int32) -> Int64

/// Resolves the IOReport private API by dlopen+dlsym once at init; if anything is missing the sampler is
/// inert (returns nil). `@unchecked Sendable`: the stored pointers are immutable after init and each
/// `sampleEnergyDeltas` keeps all IOReport state local to the call.
public final class IOReportPowerSampler: ComponentPowerSampling, @unchecked Sendable {

    private let handle: UnsafeMutableRawPointer?
    private let copyChans: CopyChansFn?
    private let createSub: CreateSubFn?
    private let createSamp: CreateSampFn?
    private let delta: DeltaFn?
    private let iterate: IterateFn?
    private let getName: ChanStrFn?
    private let getUnit: ChanStrFn?
    private let simpleInt: SimpleIntFn?

    public init() {
        let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
        handle = h
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            guard let h, let s = dlsym(h, name) else { return nil }
            return unsafeBitCast(s, to: T.self)
        }
        copyChans  = load("IOReportCopyChannelsInGroup", CopyChansFn.self)
        createSub  = load("IOReportCreateSubscription", CreateSubFn.self)
        createSamp = load("IOReportCreateSamples", CreateSampFn.self)
        delta      = load("IOReportCreateSamplesDelta", DeltaFn.self)
        iterate    = load("IOReportIterate", IterateFn.self)
        getName    = load("IOReportChannelGetChannelName", ChanStrFn.self)
        getUnit    = load("IOReportChannelGetUnitLabel", ChanStrFn.self)
        simpleInt  = load("IOReportSimpleGetIntegerValue", SimpleIntFn.self)
    }

    public func sampleEnergyDeltas(intervalSeconds: Double) -> [RawRailDelta]? {
        guard let copyChans, let createSub, let createSamp, let delta, let iterate,
              let getName, let getUnit, let simpleInt,
              intervalSeconds > 0 else { return nil }

        guard let chans = copyChans("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let mchans = CFDictionaryCreateMutableCopy(nil, 0, chans) else { return nil }
        var subbedOut: Unmanaged<CFMutableDictionary>? = nil
        guard let sub = createSub(nil, mchans, &subbedOut, 0, nil) else { return nil }   // nil = would need root
        // IOReportCreateSubscription is a +1 Create. `sub` is a raw OpaquePointer (NOT ARC-managed, unlike
        // the takeRetainedValue dictionaries below), so balance the +1 explicitly on EVERY exit path —
        // else each sample leaks one subscription while the popover is open. (The throwaway probe2.m
        // leaks it.) Swift makes CFRelease unavailable, so take ownership via Unmanaged + release().
        defer { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(sub)).release() }
        let use = subbedOut?.takeRetainedValue() ?? mchans

        guard let s1 = createSamp(sub, use, nil)?.takeRetainedValue() else { return nil }
        Thread.sleep(forTimeInterval: intervalSeconds)
        guard let s2 = createSamp(sub, use, nil)?.takeRetainedValue(),
              let d = delta(s1, s2, nil)?.takeRetainedValue() else { return nil }

        var out: [RawRailDelta] = []
        let block: @convention(block) (CFDictionary) -> Int32 = { ch in
            let name = getName(ch)?.takeUnretainedValue() as String? ?? ""
            let unit = getUnit(ch)?.takeUnretainedValue() as String? ?? ""
            let value = simpleInt(ch, 0)
            out.append(RawRailDelta(name: name, unit: unit, deltaValue: value))
            return 0
        }
        iterate(d, block)
        return out
    }
}
