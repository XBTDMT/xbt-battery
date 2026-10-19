import XCTest

/// A9 / review item N1 — **the `Equatable` contract of `BatterySnapshot`, pinned.**
///
/// WHY THIS FILE EXISTS. `BatterySnapshot.==` is SYNTHESISED, and until A9 that was harmless: it was
/// a SwiftUI diffing convenience, and a `==` that never held merely cost a redundant redraw. A9 made
/// the same synthesised operator LOAD-BEARING — `BatteryMonitor.recompose()` now elides the publish
/// entirely on `next == snapshot`, which is what took `$snapshot` from ~856 publishes/hr to the real
/// change rate. A synthesised `==` over an UNREVIEWED field list is therefore an unreviewed contract,
/// and it can fail in exactly two directions:
///
///   * **an identity field** — a `Date`, a monotonic sample id, a read counter, an adapter identity,
///     any per-read nonce. `==` then NEVER holds, A9 becomes dead code, and the whole saving silently
///     evaporates with no test going red and no symptom anywhere.
///   * **a flapping value field** — something that moves on every gauge read while SoC does not (a raw
///     unfiltered capacity, an unsmoothed instantaneous current). Same outcome, more gradually.
///
/// So the field LIST is pinned, every listed field is proved to participate in `==`, and the "same
/// inputs at two different moments compare equal" property is asserted directly. Per the review's
/// ruling: **do not hand-write `==` unless this test fails.** If it fails because a field was ADDED,
/// that failure IS the review — decide whether the newcomer is a value (extend both lists below) or an
/// identity (in which case it does not belong on the published snapshot at all).
final class BatterySnapshotEquatableTests: XCTestCase {

    /// Every field set to a non-default, distinguishable value, so the mutation sweep below can move
    /// each one independently and a defaulted field cannot masquerade as "participating".
    private func pinned() -> BatterySnapshot {
        BatterySnapshot(
            chargePercent: 62,
            isCharging: true,
            powerSource: .ac,
            minutesToFull: 41,
            minutesToEmpty: 233,
            healthPercent: 86.4,
            cycleCount: 411,
            temperatureCelsius: 39.79,
            voltageVolts: 12.1,
            amperageMilliamps: 2496,
            smoothedAmperageMilliamps: 2311,
            fullChargeCapacity_mAh: 5399,
            designCapacity_mAh: 6249,
            energyMode: .low,
            perSourceMode: .init(battery: .low, charger: .high),
            packRising: true,
            packInflowMilliamps: 3120)
    }

    /// THE FIELD LIST. Adding a stored property to `BatterySnapshot` fails here, on purpose.
    private static let pinnedFields = [
        "chargePercent", "isCharging", "powerSource", "minutesToFull", "minutesToEmpty",
        "healthPercent", "cycleCount", "temperatureCelsius", "voltageVolts", "amperageMilliamps",
        "smoothedAmperageMilliamps", "fullChargeCapacity_mAh", "designCapacity_mAh",
        "energyMode", "perSourceMode",
        // #POPOVER-TREND (reviewed 2026-09-14): VALUES, not identities. `packRising` flips only at a gauge
        // step or when a rise ages out of `PackTrend`'s window; `packInflowMilliamps` is a step-aligned
        // slope that moves only when a step enters or leaves `PackInflowEstimator`'s window — both on the
        // ~50 s gauge cadence, never per read, so A9's dedup still holds between steps.
        "packRising", "packInflowMilliamps",
    ]

    func testSnapshotFieldListIsPinned() {
        let labels = Mirror(reflecting: pinned()).children.compactMap(\.label)
        XCTAssertEqual(labels, Self.pinnedFields,
                       "BatterySnapshot's stored properties changed. A9 elides a publish on `next == "
                       + "snapshot`, so this list is a contract: a timestamp / sample id / nonce here "
                       + "makes `==` never hold and turns the dedup into dead code. Review the new "
                       + "field, then extend this list AND the mutation sweep below.")
    }

    /// No field may carry IDENTITY. A `Date`, a `UUID`, or anything that re-reads a clock on each
    /// construction defeats `==` structurally rather than by value — this names the shapes explicitly
    /// so the failure message says WHY, not just "the list changed".
    func testNoSnapshotFieldCarriesIdentity() {
        for child in Mirror(reflecting: pinned()).children {
            let type = String(describing: type(of: child.value))
            for banned in ["Date", "UUID", "ObjectIdentifier"] {
                XCTAssertFalse(type.contains(banned),
                               "field `\(child.label ?? "?")` is a \(type): an identity/timestamp field "
                               + "makes BatterySnapshot.== never hold, which silently kills the A9 dedup.")
            }
        }
    }

    /// The property A9 actually depends on: two snapshots built from the SAME inputs, at two different
    /// moments, are equal. A defaulted `Date()` (or any per-construction nonce) breaks exactly this.
    func testSameInputsAtDifferentMomentsCompareEqual() {
        let first = pinned()
        // Burn real wall-clock time between the two constructions — a clock-reading field would diverge.
        let start = Date()
        while Date().timeIntervalSince(start) < 0.01 { _ = Mirror(reflecting: first).children.count }
        XCTAssertEqual(first, pinned(),
                       "same inputs must compare equal regardless of WHEN the snapshot was built")
        XCTAssertEqual(BatterySnapshot.empty, BatterySnapshot(),
                       "the first-launch placeholder must equal a freshly defaulted snapshot")
    }

    /// Every pinned field must MOVE `==`. A field that is present but ignored by equality is the mirror
    /// image of the identity hazard: A9 would suppress a publish that carried a real change.
    func testEveryPinnedFieldParticipatesInEquality() {
        let base = pinned()
        let mutations: [(String, (inout BatterySnapshot) -> Void)] = [
            ("chargePercent",             { $0.chargePercent = 63 }),
            ("isCharging",                { $0.isCharging = false }),
            ("powerSource",               { $0.powerSource = .battery }),
            ("minutesToFull",             { $0.minutesToFull = 42 }),
            ("minutesToEmpty",            { $0.minutesToEmpty = 234 }),
            ("healthPercent",             { $0.healthPercent = 86.5 }),
            ("cycleCount",                { $0.cycleCount = 412 }),
            ("temperatureCelsius",        { $0.temperatureCelsius = 39.80 }),
            ("voltageVolts",              { $0.voltageVolts = 12.2 }),
            ("amperageMilliamps",         { $0.amperageMilliamps = 2497 }),
            ("smoothedAmperageMilliamps", { $0.smoothedAmperageMilliamps = 2312 }),
            ("fullChargeCapacity_mAh",    { $0.fullChargeCapacity_mAh = 5400 }),
            ("designCapacity_mAh",        { $0.designCapacity_mAh = 6250 }),
            ("energyMode",                { $0.energyMode = .high }),
            ("perSourceMode",             { $0.perSourceMode = .init(battery: .high, charger: .high) }),
            ("packRising",                { $0.packRising = false }),
            ("packInflowMilliamps",       { $0.packInflowMilliamps = 3121 }),
        ]

        XCTAssertEqual(mutations.count, Self.pinnedFields.count,
                       "the mutation sweep must cover every pinned field")
        XCTAssertEqual(mutations.map(\.0), Self.pinnedFields,
                       "…in the same order, so a renamed field cannot silently drop out of the sweep")

        for (name, mutate) in mutations {
            var moved = base
            mutate(&moved)
            XCTAssertNotEqual(moved, base,
                              "changing `\(name)` must break equality — otherwise A9's `next != snapshot` "
                              + "gate would swallow a real change to it")
        }
    }

    /// Nil-vs-value is a real change for every optional field: a gauge that STOPS publishing a figure
    /// must reach subscribers, not be deduped away as "same as before".
    func testClearingAnOptionalFieldIsAChange() {
        let base = pinned()
        let clears: [(String, (inout BatterySnapshot) -> Void)] = [
            ("chargePercent",             { $0.chargePercent = nil }),
            ("isCharging",                { $0.isCharging = nil }),
            ("minutesToFull",             { $0.minutesToFull = nil }),
            ("minutesToEmpty",            { $0.minutesToEmpty = nil }),
            ("healthPercent",             { $0.healthPercent = nil }),
            ("cycleCount",                { $0.cycleCount = nil }),
            ("temperatureCelsius",        { $0.temperatureCelsius = nil }),
            ("voltageVolts",              { $0.voltageVolts = nil }),
            ("amperageMilliamps",         { $0.amperageMilliamps = nil }),
            ("smoothedAmperageMilliamps", { $0.smoothedAmperageMilliamps = nil }),
            ("fullChargeCapacity_mAh",    { $0.fullChargeCapacity_mAh = nil }),
            ("designCapacity_mAh",        { $0.designCapacity_mAh = nil }),
            ("packInflowMilliamps",       { $0.packInflowMilliamps = nil }),
        ]
        for (name, clear) in clears {
            var cleared = base
            clear(&cleared)
            XCTAssertNotEqual(cleared, base, "`\(name)` going nil must publish — absence is information")
        }
    }
}
