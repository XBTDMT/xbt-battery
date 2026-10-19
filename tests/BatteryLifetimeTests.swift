import XCTest

/// #EI-2 (SPEC 02-SPEC-ei2-lifetime-analyzer.md): the PURE percent/condition logic + the nil failure
/// path, driven directly + through a mock BatteryLifetimeReading. No on-device read (environment-specific).
@MainActor
final class BatteryLifetimeTests: XCTestCase {

    private func lt(cycles: Int = 420, nominal: Int? = 5563, raw: Int? = 5411,
                    design: Int? = 6249, pfs: Int? = 0,
                    minTempC: Int? = nil, maxTempC: Int? = nil, avgDeci: Int? = nil,
                    dailyMin: Int? = nil, dailyMax: Int? = nil,
                    minPackV: Int? = nil, maxPackV: Int? = nil,
                    maxChargeA: Int? = nil, maxDischargeA: Int? = nil) -> BatteryLifetime {
        BatteryLifetime(cycleCount: cycles, designCapacity_mAh: design,
                        nominalCapacity_mAh: nominal, rawMaxCapacity_mAh: raw, permanentFailureStatus: pfs,
                        lifetimeMinTempC: minTempC, lifetimeMaxTempC: maxTempC, lifetimeAvgTempDeciC: avgDeci,
                        dailyMinSoc: dailyMin, dailyMaxSoc: dailyMax,
                        lifetimeMinPackVoltage_mV: minPackV, lifetimeMaxPackVoltage_mV: maxPackV,
                        lifetimeMaxChargeCurrent_mA: maxChargeA, lifetimeMaxDischargeCurrent_mA: maxDischargeA)
    }

    // MARK: - maximum-capacity percent (round(100 * numerator / design))

    func testMaxCapacityPercentRoundsFromRawMax() {
        // v1 numerator is AppleRawMaxCapacity (continuous with the old "Health (computed)" figure).
        XCTAssertEqual(lt(raw: 5428, design: 6249).maxCapacityPercent, 87, "5428/6249 → 87%")
        XCTAssertEqual(lt(raw: 5411, design: 6249).maxCapacityPercent, 87, "5411/6249 → 87%")
        // The math rounds (a higher numerator → 89), confirming round() not Int truncation.
        XCTAssertEqual(lt(raw: 5580, design: 6249).maxCapacityPercent, 89, "5580/6249 → 89% (rounds)")
    }

    func testNominalChargeCapacityIsTheUnusedAlternative() {
        // Proof of the numerator switch: changing NominalChargeCapacity does NOT move the percent —
        // AppleRawMaxCapacity is the numerator; NominalChargeCapacity is the one-line alternative.
        XCTAssertEqual(lt(nominal: 5563, raw: 5428, design: 6249).maxCapacityPercent, 87)
        XCTAssertEqual(lt(nominal: 9999, raw: 5428, design: 6249).maxCapacityPercent, 87,
                       "a wildly different nominal can't change the result; only raw does")
    }

    func testMaxCapacityPercentNilWhenDesignNonPositive() {
        XCTAssertNil(lt(design: 0).maxCapacityPercent, "guards divide-by-zero / a bad read")
    }

    // MARK: - condition mapping (PermanentFailureStatus)

    func testConditionMapping() {
        XCTAssertEqual(lt(pfs: 0).condition, "Normal")
        XCTAssertEqual(lt(pfs: 1).condition, "Service recommended")
        XCTAssertEqual(lt(pfs: 64).condition, "Service recommended", "any non-zero → service note")
    }

    // MARK: - #EI-2 v2 lifetime sub-stats (pure decode)

    // #30 stage 10: the `*Text` formatters moved off BatteryLifetime (HealthPageModelTests pins the
    // wording, including the deci-average rounding and the no-partial-range rule). These assert the FIELDS.
    func testLifetimeTemperatureFieldsCarryThrough() {
        let full = lt(minTempC: 9, maxTempC: 45, avgDeci: 244)
        XCTAssertEqual(full.lifetimeMinTempC, 9)
        XCTAssertEqual(full.lifetimeMaxTempC, 45)
        XCTAssertEqual(full.lifetimeAvgTempDeciC, 244, "deci-Celsius stays raw on the model")
        XCTAssertNil(lt(minTempC: 9, maxTempC: 45, avgDeci: nil).lifetimeAvgTempDeciC, "average absent → nil")
        XCTAssertNil(lt(minTempC: nil, maxTempC: 45, avgDeci: 244).lifetimeMinTempC)
        XCTAssertNil(lt(minTempC: 9, maxTempC: nil, avgDeci: 244).lifetimeMaxTempC)
    }

    func testDailyChargeRangeFields() {
        XCTAssertEqual(lt(dailyMin: 18, dailyMax: 100).dailyMinSoc, 18)
        XCTAssertEqual(lt(dailyMin: 18, dailyMax: 100).dailyMaxSoc, 100)
        XCTAssertNil(lt(dailyMin: nil, dailyMax: 100).dailyMinSoc)
        XCTAssertNil(lt(dailyMin: 18, dailyMax: nil).dailyMaxSoc)
    }

    func testV2FieldsNilSafeWithV1Figures() {
        // A lifetime with the nested values absent still yields the v1 figures and nil v2 text (no crash;
        // the v2 rows simply do not render).
        let v1only = lt()   // no v2 args → all v2 fields nil
        XCTAssertEqual(v1only.maxCapacityPercent, 87)
        XCTAssertEqual(v1only.condition, "Normal")
        XCTAssertNil(v1only.lifetimeMinTempC)
        XCTAssertNil(v1only.dailyMinSoc)
    }

    // MARK: - the seam / source (mock reader)

    final class MockReader: BatteryLifetimeReading {
        var result: Result<BatteryLifetime, BatteryLifetimeReadFailure>
        /// nil = "the read produced nothing" (the seam's original shape), reported as an unavailable dict.
        init(_ r: BatteryLifetime?) { result = r.map { .success($0) } ?? .failure(.propertiesUnavailable) }
        init(failure: BatteryLifetimeReadFailure) { result = .failure(failure) }
        func readDetailed() -> Result<BatteryLifetime, BatteryLifetimeReadFailure> { result }
    }

    func testSourceNilWhenReadFails() {
        let source = BatteryLifetimeSource(reader: MockReader(nil))
        source.refresh()
        XCTAssertNil(source.lifetime, "a failed read → nil → the section renders nothing (no crash)")
    }

    func testSourcePublishesOnSuccessfulRead() {
        let source = BatteryLifetimeSource(reader: MockReader(lt()))
        source.refresh()
        XCTAssertEqual(source.lifetime?.cycleCount, 420)
        XCTAssertEqual(source.lifetime?.maxCapacityPercent, 87, "default raw 5411 / design 6249 → 87%")
        XCTAssertEqual(source.lifetime?.condition, "Normal")
        XCTAssertEqual(source.lifetime?.nominalCapacity_mAh, 5563, "the alternative numerator is still captured")
        // v2 fields absent (a v1-only lifetime) → nil text through the mock, no crash, rows don't render.
        XCTAssertNil(source.lifetime?.lifetimeMinTempC, "absent nested values → nil v2 fields")
        XCTAssertNil(source.lifetime?.dailyMinSoc)
    }

    // MARK: - #EI-2 v2.1 lifetime electrical extremes (pure decode)

    func testLifetimeVoltageRangeFields() {
        // millivolts stay raw on the model (HealthPageModel.packVoltageText does the /1000, one decimal).
        let full = lt(minPackV: 9396, maxPackV: 13306)
        XCTAssertEqual(full.lifetimeMinPackVoltage_mV, 9396)
        XCTAssertEqual(full.lifetimeMaxPackVoltage_mV, 13306)
        XCTAssertNil(lt(minPackV: nil, maxPackV: 13306).lifetimeMinPackVoltage_mV)
        XCTAssertNil(lt(minPackV: 9396, maxPackV: nil).lifetimeMaxPackVoltage_mV)
    }

    func testLifetimePeakCurrentFields() {
        // milliamps stay raw and SIGNED on the model (HealthPageModel.peakCurrentText takes the magnitude).
        let full = lt(maxChargeA: 6816, maxDischargeA: -8970)
        XCTAssertEqual(full.lifetimeMaxChargeCurrent_mA, 6816)
        XCTAssertEqual(full.lifetimeMaxDischargeCurrent_mA, -8970)
        XCTAssertNil(lt(maxChargeA: nil, maxDischargeA: -8970).lifetimeMaxChargeCurrent_mA)
        XCTAssertNil(lt(maxChargeA: 6816, maxDischargeA: nil).lifetimeMaxDischargeCurrent_mA)
    }

    func testV21FieldsFlowThroughSourceAndAreNilSafe() {
        // WITH the four fields (as the reader maps them) → the new fields + texts surface through the seam.
        let full = lt(minPackV: 9396, maxPackV: 13306, maxChargeA: 6816, maxDischargeA: -8970)
        let source = BatteryLifetimeSource(reader: MockReader(full))
        source.refresh()
        XCTAssertEqual(source.lifetime?.lifetimeMinPackVoltage_mV, 9396, "the new field is carried")
        XCTAssertEqual(source.lifetime?.lifetimeMaxDischargeCurrent_mA, -8970, "discharge stays signed in the field")
        XCTAssertEqual(source.lifetime?.lifetimeMaxPackVoltage_mV, 13306)
        XCTAssertEqual(source.lifetime?.lifetimeMaxChargeCurrent_mA, 6816)

        // WITHOUT them (a machine missing the keys) → nil new fields + texts, v1/v2 figures intact (no regression).
        let v1only = lt()
        XCTAssertNil(v1only.lifetimeMinPackVoltage_mV, "absent key → nil field")
        XCTAssertNil(v1only.lifetimeMaxPackVoltage_mV)
        XCTAssertNil(v1only.lifetimeMaxChargeCurrent_mA)
        XCTAssertEqual(v1only.maxCapacityPercent, 87, "v1 figure intact — no regression")
        XCTAssertNil(v1only.lifetimeMinTempC, "v2 field intact")
    }

    // MARK: - macOS layout ladder (audit finding B0 — the health card silently vanished on macOS 27)

    /// The PRE-27 shape: every required figure at the TOP level, no `BatteryData` dict at all.
    private var preMacOS27Props: [String: Any] {
        ["CycleCount": 420,
         "DesignCapacity": 6249,
         "NominalChargeCapacity": 5563,
         "AppleRawMaxCapacity": 5411,
         "PermanentFailureStatus": 0]
    }

    /// The macOS 27 `AppleSmartBattery` NODE alone (`ioreg -r -c AppleSmartBattery -d1`), i.e. what a read
    /// that never walks the pack child can see: `CycleCount` is the only top-level survivor, some capacities
    /// moved into `BatteryData` (no `AppleRawMaxCapacity` — `FullChargeCapacity` is the lower rung), and
    /// `PermanentFailureStatus` / `LifetimeData` / `DailyMin/MaxSoc` are nowhere on this node. Also the
    /// shape a machine WITHOUT a readable pack child degrades to.
    private var macOS27NodeOnlyProps: [String: Any] {
        ["CycleCount": 523,
         "BatteryData": ["FullChargeCapacity": 5479, "NominalChargeCapacity": 5631, "DesignCapacity": 6249,
                         "MaxCapacity": 100, "CurrentCapacity": 66, "RemainingCapacity": 3460,
                         "FullyCharged": 0, "AvgTimeToEmpty": 71, "AbsoluteCapacity": 0,
                         "TrueRemainingCapacity": 0]]
    }

    /// The REAL macOS 27.0 shape read off this machine (`ioreg -r -c AppleSmartBattery -d1` +
    /// `ioreg -r -c AppleSmartBatteryPack`, 2026-09-08): the node above, PLUS the child
    /// `AppleSmartBatteryPack`'s own nested `BatteryData` folded in under the parser's synthetic key —
    /// exactly what `LiveBatteryLifetimeReader` builds. The gauge lives HERE on 27: `AppleRawMaxCapacity`
    /// (5479, identical to the node's `FullChargeCapacity` on this pack), `PermanentFailureStatus` (0),
    /// `DailyMin/MaxSoc` (24/100) and the whole `LifetimeData` dict.
    private var macOS27Props: [String: Any] {
        var props = macOS27NodeOnlyProps
        props[BatteryLifetimeParser.packPropertiesKey] = [
            "Serial": "REDACTED", "BankCount": 1, "CarrierMode": 0, "KioskMode": 0,
            "BatteryData": [
                "AppleRawMaxCapacity": 5479, "NominalChargeCapacity": 5631, "DesignCapacity": 6249,
                "AppleRawCurrentCapacity": 3409, "MaxCapacity": 100, "CycleCount": 523,
                "PermanentFailureStatus": 0, "DailyMinSoc": 24, "DailyMaxSoc": 100,
                "Temperature": 4059, "VirtualTemperature": 4059, "BatteryHealthMetric": 0,
                "LifetimeData": ["MinimumTemperature": 9, "MaximumTemperature": 46,
                                 "AverageTemperature": 255, "TemperatureSamples": 255902,
                                 "MinimumPackVoltage": 8995, "MaximumPackVoltage": 13306,
                                 "MaximumChargeCurrent": 6816, "MaximumDischargeCurrent": -8970,
                                 "CycleCountLastQmax": 515, "TotalOperatingTime": 15993]
            ]
        ]
        return props
    }

    private func parsed(_ props: [String: Any],
                        file: StaticString = #filePath, line: UInt = #line) -> BatteryLifetime? {
        switch BatteryLifetimeParser.parse(props) {
        case .success(let value): return value
        case .failure(let failure):
            XCTFail("parse failed: \(failure.summary)", file: file, line: line)
            return nil
        }
    }

    func testParseTopLevelOnlyDictIsUnchangedOnOlderOS() {
        let lt = parsed(preMacOS27Props)
        XCTAssertEqual(lt?.cycleCount, 420)
        XCTAssertEqual(lt?.designCapacity_mAh, 6249)
        XCTAssertEqual(lt?.nominalCapacity_mAh, 5563)
        XCTAssertEqual(lt?.rawMaxCapacity_mAh, 5411, "AppleRawMaxCapacity read at the top level")
        XCTAssertEqual(lt?.maxCapacityPercent, 87)
        XCTAssertEqual(lt?.condition, "Normal", "PermanentFailureStatus == 0 still reads Normal")
        XCTAssertEqual(lt?.unresolvedKeys, [], "nothing drifted on this layout")
    }

    func testParseNestedOnlyDictYieldsALifetimeIsTheB0Regression() {
        // THE BUG: on macOS 27 the old five-key top-level guard failed → read() returned nil → the health
        // chip and the whole Battery-health card silently disappeared. A nested-only dict must parse.
        let lt = parsed(macOS27Props)
        XCTAssertNotNil(lt, "macOS 27's nested-only layout MUST still yield a lifetime (finding B0)")
        XCTAssertEqual(lt?.cycleCount, 523)
        XCTAssertEqual(lt?.designCapacity_mAh, 6249, "BatteryData.DesignCapacity")
        XCTAssertEqual(lt?.nominalCapacity_mAh, 5631, "BatteryData.NominalChargeCapacity")
        XCTAssertEqual(lt?.rawMaxCapacity_mAh, 5479, "pack BatteryData.AppleRawMaxCapacity")
        XCTAssertEqual(lt?.maxCapacityPercent, 88, "5479/6249 → 87.7 → 88%")
        XCTAssertEqual(lt?.unresolvedKeys, [], "every figure resolved on a known rung — no drift to report")
    }

    func testParseNestedOnlyNeverUsesThePercentMaxCapacityAsNumerator() {
        // R-06 trap: BatteryData.MaxCapacity is 100 (a PERCENT), not mAh — on the node AND on the pack.
        // It must never feed health at either rung.
        for props in [macOS27NodeOnlyProps, macOS27Props] {
            let lt = parsed(props)
            XCTAssertEqual(lt?.rawMaxCapacity_mAh, 5479)
            XCTAssertNotEqual(lt?.maxCapacityPercent, 2, "the 2%-health shape (percent used as mAh) must not recur")
        }
    }

    // MARK: - the PACK child rung (finding B0b — the gas gauge moved to AppleSmartBatteryPack)

    func testParsePackChildRungRestoresConditionOnMacOS27() {
        // PermanentFailureStatus was never deleted on macOS 27 — it moved to the CHILD pack node, where it
        // reads 0. Walking the child restores a REAL condition instead of an honest-but-blank "Unknown".
        let lt = parsed(macOS27Props)
        XCTAssertEqual(lt?.permanentFailureStatus, 0, "pack BatteryData.PermanentFailureStatus")
        XCTAssertEqual(lt?.condition, "Normal", "a value we actually read — not a fabricated default")
        XCTAssertEqual(lt?.unresolvedKeys, [], "it resolved, so nothing is reported as drift")
    }

    func testParsePrefersTheRawMaxKeyOverFullChargeCapacity() {
        // Decision #13: health is computed from the RAW mAh. `AppleRawMaxCapacity` still exists under its
        // own name on the pack, so it OUTRANKS the node's `FullChargeCapacity` substitute. Pinned with the
        // two deliberately disagreeing (on this machine they happen to be equal, 5479 == 5479).
        var props = macOS27Props
        props["BatteryData"] = ["DesignCapacity": 6249, "NominalChargeCapacity": 5631,
                                "FullChargeCapacity": 5000]
        let lt = parsed(props)
        XCTAssertEqual(lt?.rawMaxCapacity_mAh, 5479, "the raw key on the pack wins over FullChargeCapacity")
        XCTAssertEqual(lt?.maxCapacityPercent, 88)
    }

    func testParsePackDailyChargeRange() {
        // DailyMin/MaxSoc are pack BatteryData siblings of LifetimeData — 24/100 on this machine.
        let lt = parsed(macOS27Props)
        XCTAssertEqual(lt?.dailyMinSoc, 24)
        XCTAssertEqual(lt?.dailyMaxSoc, 100)
    }

    func testParsePackLifetimeDataRestoresTheV2AndV21SubStats() {
        // LifetimeData lives in the PACK's BatteryData on macOS 27. Real captured values from this machine.
        let lt = parsed(macOS27Props)
        XCTAssertEqual(lt?.lifetimeMinTempC, 9)
        XCTAssertEqual(lt?.lifetimeMaxTempC, 46)
        XCTAssertEqual(lt?.lifetimeAvgTempDeciC, 255, "deci-C, raw (HealthPageModel rounds 25.5 → 26)")
        XCTAssertEqual(lt?.lifetimeMinPackVoltage_mV, 8995)
        XCTAssertEqual(lt?.lifetimeMaxPackVoltage_mV, 13306)
        XCTAssertEqual(lt?.lifetimeMaxChargeCurrent_mA, 6816)
        XCTAssertEqual(lt?.lifetimeMaxDischargeCurrent_mA, -8970, "the field itself stays signed")
    }

    func testParseWithoutAReadablePackDegradesHonestly() {
        // The pack walk can fail (pre-27 machines, or a future OS that moves it again). The node rungs
        // still carry the capacities via FullChargeCapacity, and condition goes back to the honest
        // "Unknown" — never a defaulted "Normal" — with the unresolved path named.
        let lt = parsed(macOS27NodeOnlyProps)
        XCTAssertEqual(lt?.rawMaxCapacity_mAh, 5479, "the FullChargeCapacity lower rung still answers")
        XCTAssertEqual(lt?.maxCapacityPercent, 88)
        XCTAssertNil(lt?.permanentFailureStatus, "absent everywhere → nil, never a defaulted 0")
        XCTAssertEqual(lt?.condition, "Unknown", "we cannot confirm the pack is healthy, so we don't say Normal")
        XCTAssertEqual(lt?.unresolvedKeys,
                       ["PermanentFailureStatus / BatteryData.PermanentFailureStatus / Pack.BatteryData.PermanentFailureStatus"],
                       "the key we could not resolve is named — no silent blank")
    }

    // MARK: - plausibility guards (a 0xFFFF gauge placeholder is never a figure)

    func testSaturatedGaugePlaceholdersNeverRenderAsFigures() {
        // An unlatched gas gauge publishes all-ones. None of it may reach a row: 65535 mAh is not a pack,
        // 65535 is not a failure bitfield, 255% is not a state of charge, 65535 is not 655 °C or 65 V.
        var props = macOS27Props
        props[BatteryLifetimeParser.packPropertiesKey] = [
            "BatteryData": ["AppleRawMaxCapacity": 65535, "DesignCapacity": 6249,
                            "NominalChargeCapacity": 5631, "PermanentFailureStatus": 65535,
                            "DailyMinSoc": 255, "DailyMaxSoc": 255,
                            "LifetimeData": ["MinimumTemperature": 9, "MaximumTemperature": 65535,
                                             "AverageTemperature": 65535,
                                             "MinimumPackVoltage": 8995, "MaximumPackVoltage": 65535,
                                             "MaximumChargeCurrent": 65535, "MaximumDischargeCurrent": -8970]]
        ]
        props["BatteryData"] = ["DesignCapacity": 6249, "NominalChargeCapacity": 5631]   // no lower rung either
        let lt = parsed(props)
        XCTAssertNil(lt?.rawMaxCapacity_mAh, "65535 mAh is a placeholder, not a capacity")
        XCTAssertNil(lt?.maxCapacityPercent, "so no health percent is invented")
        XCTAssertEqual(lt?.condition, "Unknown", "an all-ones bitfield must not shout Service recommended")
        XCTAssertNil(lt?.dailyMinSoc, "255% is not a state of charge")
        XCTAssertNil(lt?.dailyMaxSoc)
        XCTAssertNil(lt?.lifetimeMaxTempC, "no 655 °C lifetime maximum")
        XCTAssertNil(lt?.lifetimeAvgTempDeciC)
        XCTAssertNil(lt?.lifetimeMaxPackVoltage_mV, "65535 mV is not 65 V")
        XCTAssertNil(lt?.lifetimeMaxChargeCurrent_mA)
        // The un-saturated halves stay real on the model; the page's "both endpoints or nothing" rule
        // (HealthPageModel.packVoltageText / peakCurrentText, pinned in HealthPageModelTests) is what
        // keeps a half-range off the screen.
        XCTAssertEqual(lt?.lifetimeMinPackVoltage_mV, 8995)
        XCTAssertEqual(lt?.lifetimeMaxDischargeCurrent_mA, -8970)
        XCTAssertEqual(lt?.cycleCount, 523, "the figures that ARE real still render")
        XCTAssertEqual(lt?.designCapacity_mAh, 6249)
    }

    func testAPlaceholderAtOneRungFallsThroughToTheNext() {
        // The guard is part of the LADDER, not a terminal veto: an implausible value at one rung means
        // "not published here", so the next rung still gets its turn.
        var props = macOS27Props
        props["BatteryData"] = ["DesignCapacity": 65535, "NominalChargeCapacity": 65535,
                                "FullChargeCapacity": 65535]
        let lt = parsed(props)
        XCTAssertEqual(lt?.designCapacity_mAh, 6249, "the pack rung answers when the node rung is garbage")
        XCTAssertEqual(lt?.nominalCapacity_mAh, 5631)
        XCTAssertEqual(lt?.rawMaxCapacity_mAh, 5479)
        XCTAssertEqual(lt?.unresolvedKeys, [])
    }

    func testParseBothLayoutsPrefersTheTopLevelKey() {
        var props = preMacOS27Props
        props["BatteryData"] = ["DesignCapacity": 9999, "NominalChargeCapacity": 9999,
                                "FullChargeCapacity": 9999]
        let lt = parsed(props)
        XCTAssertEqual(lt?.designCapacity_mAh, 6249, "top-level rung wins when both layouts are present")
        XCTAssertEqual(lt?.nominalCapacity_mAh, 5563)
        XCTAssertEqual(lt?.rawMaxCapacity_mAh, 5411)
        XCTAssertEqual(lt?.maxCapacityPercent, 87)
    }

    func testParseNeitherLayoutDegradesHonestlyAndNamesTheDrift() {
        // A future OS that publishes the capacities at NEITHER rung: the card still renders what we do
        // have (the cycle count), the capacity rows go absent rather than wrong, and the missing key
        // paths are named — the legibility that finding B0 lacked.
        let lt = parsed(["CycleCount": 523])
        XCTAssertEqual(lt?.cycleCount, 523, "the read survives on the figure that IS there")
        XCTAssertNil(lt?.designCapacity_mAh)
        XCTAssertNil(lt?.nominalCapacity_mAh)
        XCTAssertNil(lt?.rawMaxCapacity_mAh)
        XCTAssertNil(lt?.maxCapacityPercent, "absent → no row, never a wrong number")
        XCTAssertEqual(lt?.unresolvedKeys,
                       ["DesignCapacity / BatteryData.DesignCapacity / Pack.BatteryData.DesignCapacity",
                        "NominalChargeCapacity / BatteryData.NominalChargeCapacity / Pack.BatteryData.NominalChargeCapacity",
                        "AppleRawMaxCapacity / Pack.BatteryData.AppleRawMaxCapacity / BatteryData.FullChargeCapacity",
                        "PermanentFailureStatus / BatteryData.PermanentFailureStatus / Pack.BatteryData.PermanentFailureStatus"],
                       "unanticipated drift is reported by key path, every rung named")
    }

    func testParseWithoutCycleCountIsANamedFailureNotAnAnonymousNil() {
        // The one genuinely required figure (the popover prints it unconditionally). A missing key and a
        // failed read are no longer the same value: the failure says WHICH key.
        switch BatteryLifetimeParser.parse(["BatteryData": ["DesignCapacity": 6249]]) {
        case .success:
            XCTFail("a dict without CycleCount cannot produce a lifetime")
        case .failure(let failure):
            XCTAssertEqual(failure, .missingRequiredKeys(["CycleCount"]))
            XCTAssertTrue(failure.summary.contains("CycleCount"), "the log line names the drifted key")
        }
    }

    func testSubStatsDegradeToAbsentWhereLifetimeDataIsGenuinelyMissing() {
        // A machine (older, or a future OS that moves the dict again) that publishes LifetimeData and
        // DailyMin/MaxSoc at NO rung: every v2 / v2.1 sub-stat reads nil and its row does not render. That
        // is the designed degradation, not drift — so it is NOT reported in unresolvedKeys.
        let lt = parsed(macOS27NodeOnlyProps)
        XCTAssertNil(lt?.lifetimeMinTempC)
        XCTAssertNil(lt?.lifetimeMaxTempC)
        XCTAssertNil(lt?.dailyMinSoc, "DailyMin/MaxSoc are absent with it")
        XCTAssertNil(lt?.dailyMaxSoc)
        XCTAssertNil(lt?.lifetimeMinPackVoltage_mV)
        XCTAssertNil(lt?.lifetimeMaxChargeCurrent_mA)
        XCTAssertFalse(lt?.unresolvedKeys.contains(where: { $0.contains("LifetimeData") }) ?? true,
                       "an optional-by-design dict is not reported as unanticipated drift")
    }

    func testParsePicksUpSubStatsWhenTheNestedDictsExist() {
        // The v2 / v2.1 reads are unchanged: where LifetimeData still exists, it still decodes.
        var props = preMacOS27Props
        props["BatteryData"] = ["DailyMinSoc": 18, "DailyMaxSoc": 100,
                                "LifetimeData": ["MinimumTemperature": 9, "MaximumTemperature": 45,
                                                 "AverageTemperature": 244,
                                                 "MinimumPackVoltage": 9396, "MaximumPackVoltage": 13306,
                                                 "MaximumChargeCurrent": 6816, "MaximumDischargeCurrent": -8970]]
        let lt = parsed(props)
        XCTAssertEqual(lt?.lifetimeMinTempC, 9)
        XCTAssertEqual(lt?.lifetimeMaxTempC, 45)
        XCTAssertEqual(lt?.lifetimeAvgTempDeciC, 244)
        XCTAssertEqual(lt?.dailyMinSoc, 18)
        XCTAssertEqual(lt?.dailyMaxSoc, 100)
        XCTAssertEqual(lt?.lifetimeMinPackVoltage_mV, 9396)
        XCTAssertEqual(lt?.lifetimeMaxPackVoltage_mV, 13306)
        XCTAssertEqual(lt?.lifetimeMaxChargeCurrent_mA, 6816)
        XCTAssertEqual(lt?.lifetimeMaxDischargeCurrent_mA, -8970)
    }

    func testConditionUnknownWhenPermanentFailureStatusAbsent() {
        XCTAssertEqual(lt(pfs: nil).condition, "Unknown", "no key → no claim about the pack")
    }

    func testMaxCapacityPercentNilWhenACapacityIsAbsent() {
        XCTAssertNil(lt(raw: nil).maxCapacityPercent, "no numerator → no percent")
        XCTAssertNil(lt(design: nil).maxCapacityPercent, "no denominator → no percent")
    }

    // MARK: - the source surfaces WHY a read produced nothing

    func testSourceRecordsTheFailureReason() {
        let source = BatteryLifetimeSource(reader: MockReader(failure: .missingRequiredKeys(["CycleCount"])))
        source.refresh()
        XCTAssertNil(source.lifetime, "still no render — but the reason is now inspectable")
        XCTAssertEqual(source.lastFailure, .missingRequiredKeys(["CycleCount"]))
    }

    func testSourceClearsTheFailureOnASubsequentGoodRead() {
        let reader = MockReader(failure: .noBatteryService)
        let source = BatteryLifetimeSource(reader: reader)
        source.refresh()
        XCTAssertEqual(source.lastFailure, .noBatteryService)

        reader.result = .success(lt())
        source.refresh()
        XCTAssertNotNil(source.lifetime)
        XCTAssertNil(source.lastFailure, "a good read clears the stale reason")
    }

    // MARK: - SWEEP §2.G · `unresolvedKeys` gets a screen (12-SWEEP-silent-absence.md, hit 2)

    /// RED-first, the collapse itself. `unresolvedKeys` was populated by the parser and logged by the
    /// live reader — and rendered NOWHERE. `lastFailure` only fires on a TOTAL read failure, so a
    /// PARTIAL relocation (one figure moves off every rung we know) leaves `lastFailure == nil`, the
    /// parse succeeding, and the affected row silently deleted from a card that looks healthy. That is
    /// B0 recurring one notch below the branch built to catch it.
    func testDriftNote_aPartialRelocationIsNotAReadFailureAndMustStillSpeak() {
        // A macOS that still publishes CycleCount but has moved DesignCapacity off every known rung.
        let props: [String: Any] = ["CycleCount": 523,
                                    "BatteryData": ["NominalChargeCapacity": 5583],
                                    "PermanentFailureStatus": 0]
        guard case .success(let lt) = BatteryLifetimeParser.parse(props) else {
            return XCTFail("a moved figure is NOT a read failure — the parse must still succeed")
        }
        XCTAssertNil(lt.maxCapacityPercent, "the row it feeds is gone…")
        XCTAssertFalse(lt.unresolvedKeys.isEmpty, "…and the model knew why all along")
        XCTAssertNotNil(lt.driftNote, "the card must now be able to say so out loud")
        XCTAssertTrue(lt.driftNote?.contains("DesignCapacity") ?? false,
                      "the note names the Apple key that moved, so the next relocation is legible")
    }

    /// The note is SILENT on a healthy read — it is drift reporting, not a permanent disclaimer.
    /// (Verified live on this machine 2026-09-08: every figure resolves, so this is today's real state.)
    func testDriftNote_silentWhenEveryFigureResolves() {
        let props: [String: Any] = [
            "CycleCount": 523,
            BatteryLifetimeParser.packPropertiesKey: ["BatteryData": [
                "DesignCapacity": 6249, "NominalChargeCapacity": 5583,
                "AppleRawMaxCapacity": 5431, "PermanentFailureStatus": 0,
            ]],
        ]
        guard case .success(let lt) = BatteryLifetimeParser.parse(props) else { return XCTFail("healthy read") }
        XCTAssertEqual(lt.unresolvedKeys, [])
        XCTAssertNil(lt.driftNote, "a healthy card carries no note")
    }

    /// The note names FIGURES, not the internal three-rung path strings — a 320-pt card cannot render
    /// "DesignCapacity / BatteryData.DesignCapacity / Pack.BatteryData.DesignCapacity", and the reader
    /// needs the Apple key name, which is what a search or a bug report is made of.
    func testDriftNote_namesTheKeysNotTheInternalLadderPaths() {
        var lt = Self.lifetimeFixtureForDrift()
        lt.unresolvedKeys = ["DesignCapacity / BatteryData.DesignCapacity / Pack.BatteryData.DesignCapacity"]
        let note = lt.driftNote
        XCTAssertTrue(note?.contains("DesignCapacity") ?? false)
        XCTAssertFalse(note?.contains("Pack.BatteryData") ?? true, "no internal path spelling on screen")
        XCTAssertFalse(note?.contains(" / ") ?? true)
    }

    /// Two missing figures read as two, not as a stuttered singular — the count is the useful half
    /// ("one row is gone" and "the whole gas gauge moved" are different problems).
    func testDriftNote_countsWhatIsMissing() {
        var one = Self.lifetimeFixtureForDrift()
        one.unresolvedKeys = ["DesignCapacity / BatteryData.DesignCapacity / Pack.BatteryData.DesignCapacity"]
        var two = Self.lifetimeFixtureForDrift()
        two.unresolvedKeys = one.unresolvedKeys + ["PermanentFailureStatus / BatteryData.PermanentFailureStatus / Pack.BatteryData.PermanentFailureStatus"]
        XCTAssertTrue(one.driftNote?.hasPrefix("One battery figure is missing") ?? false, one.driftNote ?? "nil")
        XCTAssertTrue(two.driftNote?.hasPrefix("2 battery figures are missing") ?? false, two.driftNote ?? "nil")
    }

    private static func lifetimeFixtureForDrift() -> BatteryLifetime {
        BatteryLifetime(cycleCount: 523, designCapacity_mAh: nil, nominalCapacity_mAh: nil,
                        rawMaxCapacity_mAh: nil, permanentFailureStatus: nil,
                        lifetimeMinTempC: nil, lifetimeMaxTempC: nil, lifetimeAvgTempDeciC: nil,
                        dailyMinSoc: nil, dailyMaxSoc: nil,
                        lifetimeMinPackVoltage_mV: nil, lifetimeMaxPackVoltage_mV: nil,
                        lifetimeMaxChargeCurrent_mA: nil, lifetimeMaxDischargeCurrent_mA: nil)
    }
}
