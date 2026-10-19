import XCTest

/// #EI-3 (SPEC 02-SPEC-ei3-adapter-wattage.md): the PURE AdapterDetails.Watts extraction + the nil
/// (no-adapter / failed-read) path, driven directly + through a mock PowerAdapterReading. No on-device
/// read (environment-specific), matching the #EI-2 / #EI-1a posture.
@MainActor
final class PowerAdapterTests: XCTestCase {

    // MARK: - pure Watts extraction

    func testExtractsWattsFromAdapterDetails() {
        let props: [String: Any] = ["AdapterDetails": ["Watts": 75, "AdapterVoltage": 20000, "Current": 3750]]
        XCTAssertEqual(PowerAdapter.from(properties: props),
                       PowerAdapter(watts: 75, voltage_mV: 20000, current_mA: 3750))
    }

    func testNilWhenAdapterDetailsAbsent() {
        // On battery: no AdapterDetails dict → no ceiling.
        XCTAssertNil(PowerAdapter.from(properties: ["ExternalConnected": false]))
    }

    func testNilWhenWattsMissing() {
        // AdapterDetails present but no Watts key → nil (no fabricated ceiling).
        XCTAssertNil(PowerAdapter.from(properties: ["AdapterDetails": ["AdapterVoltage": 20000]]))
    }

    func testNilWhenPropertiesNil() {
        XCTAssertNil(PowerAdapter.from(properties: nil))
    }

    // MARK: - #EI-3 v2 rated V/A spec text (pure)

    func testSpecTextWithVoltageAndCurrent() {
        // The millivolt/milliamp → V/A decode + trailing-zero trim: 20000 mV → "20", 3750 mA → "3.75".
        XCTAssertEqual(PowerAdapter(watts: 75, voltage_mV: 20000, current_mA: 3750).specText,
                       "75 W (20 V / 3.75 A)")
    }

    func testSpecTextWattsOnlyWhenVoltageOrCurrentNil() {
        // Requiring BOTH avoids a lopsided parenthetical.
        XCTAssertEqual(PowerAdapter(watts: 75, voltage_mV: nil, current_mA: 3750).specText, "75 W")
        XCTAssertEqual(PowerAdapter(watts: 75, voltage_mV: 20000, current_mA: nil).specText, "75 W")
    }

    func testSpecTextTrimsTrailingZeros() {
        // %g keeps 14.5 and trims 3.0 → "3".
        XCTAssertEqual(PowerAdapter(watts: 75, voltage_mV: 14500, current_mA: 3000).specText,
                       "75 W (14.5 V / 3 A)")
    }

    func testFromPropertiesReadsVoltageAndCurrent() {
        let props: [String: Any] = ["AdapterDetails": ["Watts": 75, "AdapterVoltage": 20000, "Current": 3750]]
        let a = PowerAdapter.from(properties: props)
        XCTAssertEqual(a?.voltage_mV, 20000)
        XCTAssertEqual(a?.current_mA, 3750)
        XCTAssertEqual(a?.specText, "75 W (20 V / 3.75 A)")
    }

    func testFromPropertiesNilVAWhenKeysAbsentButWattsIntact() {
        // v1 extraction unchanged: only Watts present → watts intact, V/A nil, specText watts-only.
        let a = PowerAdapter.from(properties: ["AdapterDetails": ["Watts": 75]])
        XCTAssertEqual(a?.watts, 75)
        XCTAssertNil(a?.voltage_mV)
        XCTAssertNil(a?.current_mA)
        XCTAssertEqual(a?.specText, "75 W")
    }

    // MARK: - source (mock reader)

    final class MockAdapterReader: PowerAdapterReading {
        var result: PowerAdapterReadState
        init(_ r: PowerAdapter?) { result = r.map { .connected($0) } ?? .noAdapter }
        init(state: PowerAdapterReadState) { result = state }
        func readDetailed() -> PowerAdapterReadState { result }
    }

    func testSourceSurfacesWatts() {
        let source = PowerAdapterSource(reader: MockAdapterReader(PowerAdapter(watts: 75, voltage_mV: nil, current_mA: nil)))
        source.refresh()
        XCTAssertEqual(source.watts, 75)
    }

    func testSourceNilWhenNoAdapter() {
        let source = PowerAdapterSource(reader: MockAdapterReader(nil))
        source.refresh()
        XCTAssertNil(source.watts, "no adapter → nil → the Power row shows no ceiling")
    }

    // MARK: - #EI-3 v2.1 USB-C PD-profile menu text (pure)

    /// The probe's 75 W 4-rung ladder (mV/mA), active index 3 → the active rung is the 20V/3.75A one.
    private func rungs4() -> [PdProfile] {
        [PdProfile(index: 0, voltage_mV: 5000,  current_mA: 3000),
         PdProfile(index: 1, voltage_mV: 9000,  current_mA: 3000),
         PdProfile(index: 2, voltage_mV: 15000, current_mA: 3000),
         PdProfile(index: 3, voltage_mV: 20000, current_mA: 3750)]
    }

    func testPdProfileMenuText() {
        let a = PowerAdapter(watts: 75, voltage_mV: 20000, current_mA: 3750, pdProfiles: rungs4(), activePdIndex: 3)
        XCTAssertEqual(a.pdProfileMenuText, "5V/3A, 9V/3A, 15V/3A, 20V/3.75A (active)",
                       "the 4-rung ladder, trailing-zero trimmed, the active rung marked")
    }

    func testPdProfileMenuSingleProfileIsNil() {
        let a = PowerAdapter(watts: 8, voltage_mV: 5000, current_mA: 1500,
                             pdProfiles: [PdProfile(index: 0, voltage_mV: 5000, current_mA: 1500)], activePdIndex: 0)
        XCTAssertNil(a.pdProfileMenuText, "a single-rung source adds nothing beyond the Adapter spec row")
    }

    func testPdProfileMenuZeroProfilesIsNil() {
        let a = PowerAdapter(watts: 75, voltage_mV: 20000, current_mA: 3750, pdProfiles: [], activePdIndex: nil)
        XCTAssertNil(a.pdProfileMenuText)
    }

    func testPdProfileMenuActiveIndexNilNoMarker() {
        let a = PowerAdapter(watts: 30, voltage_mV: nil, current_mA: nil,
                             pdProfiles: [PdProfile(index: 0, voltage_mV: 5000, current_mA: 3000),
                                          PdProfile(index: 1, voltage_mV: 9000, current_mA: 3000)],
                             activePdIndex: nil)
        XCTAssertEqual(a.pdProfileMenuText, "5V/3A, 9V/3A", "no active index → no marker")
    }

    func testPdProfileMenuActiveIndexOutOfRangeNoMarker() {
        let a = PowerAdapter(watts: 30, voltage_mV: nil, current_mA: nil,
                             pdProfiles: [PdProfile(index: 0, voltage_mV: 5000, current_mA: 3000),
                                          PdProfile(index: 1, voltage_mV: 9000, current_mA: 3000)],
                             activePdIndex: 99)
        XCTAssertEqual(a.pdProfileMenuText, "5V/3A, 9V/3A", "an active index matching no rung → no marker")
    }

    func testPdProfileMenuFractionalRungTrim() {
        let a = PowerAdapter(watts: 45, voltage_mV: nil, current_mA: nil,
                             pdProfiles: [PdProfile(index: 0, voltage_mV: 14500, current_mA: 3000),
                                          PdProfile(index: 1, voltage_mV: 20000, current_mA: 2250)],
                             activePdIndex: 0)
        XCTAssertTrue(a.pdProfileMenuText?.contains("14.5V/3A") ?? false, "the %g trim keeps 14.5 and trims 3.0 → 3")
    }

    func testFromPropertiesParsesUsbHvcMenuAndActiveIndex() {
        let menu: [Any] = [
            ["Index": 0, "MaxVoltage": 5000,  "MaxCurrent": 3000],
            ["Index": 1, "MaxVoltage": 9000,  "MaxCurrent": 3000],
            ["Index": 2, "MaxVoltage": 15000, "MaxCurrent": 3000],
            ["Index": 3, "MaxVoltage": 20000, "MaxCurrent": 3750],
        ]
        let props: [String: Any] = ["AdapterDetails": ["Watts": 75, "UsbHvcMenu": menu, "UsbHvcHvcIndex": 3]]
        let a = PowerAdapter.from(properties: props)
        XCTAssertEqual(a?.pdProfiles.count, 4, "all four rungs parsed")
        XCTAssertEqual(a?.pdProfiles.first, PdProfile(index: 0, voltage_mV: 5000, current_mA: 3000))
        XCTAssertEqual(a?.activePdIndex, 3, "the negotiated rung index")
        XCTAssertEqual(a?.pdProfileMenuText, "5V/3A, 9V/3A, 15V/3A, 20V/3.75A (active)")

        // v1/v2 extraction unchanged: AdapterDetails with only Watts → empty profiles + nil active + watts 75.
        let bare = PowerAdapter.from(properties: ["AdapterDetails": ["Watts": 75]])
        XCTAssertEqual(bare?.watts, 75)
        XCTAssertEqual(bare?.pdProfiles, [], "no menu key → empty profiles")
        XCTAssertNil(bare?.activePdIndex)
    }

    // MARK: - SWEEP §2.G · the three-state adapter read (12-SWEEP-silent-absence.md, hit 1)

    /// RED-first, the collapse itself. The OLD `from(properties:)` returned the SAME `nil` for four
    /// distinct facts: no adapter plugged in, the node's properties unreadable, and — the one that
    /// matters — `AdapterDetails`/`Watts` relocated by a new macOS while an adapter IS attached.
    /// Under the old shape every assertion below would read `nil == nil` and pass vacuously.
    func testThreeState_absenceAndFailureAreNoLongerTheSameValue() {
        // Absent BY DESIGN: the node says nothing is plugged in.
        XCTAssertEqual(PowerAdapter.resolve(properties: ["ExternalConnected": false]), .noAdapter)

        // READ FAILED: something IS plugged in, and no rung publishes a wattage. The macOS-28 signature.
        guard case .unavailable = PowerAdapter.resolve(properties: ["ExternalConnected": true]) else {
            return XCTFail("a plugged-in adapter with no resolvable Watts must NOT read as .noAdapter")
        }

        // READ FAILED: the property dict could not be copied at all.
        guard case .unavailable = PowerAdapter.resolve(properties: nil) else {
            return XCTFail("an uncopyable property dict must not present as an unplugged Mac")
        }

        // The three states are genuinely distinct values, not three spellings of nothing.
        XCTAssertNotEqual(PowerAdapter.resolve(properties: ["ExternalConnected": false]),
                          PowerAdapter.resolve(properties: ["ExternalConnected": true]))
    }

    /// The relocation ladder (03-REF rule 2): top level → node `BatteryData` → pack `BatteryData`.
    /// macOS 27 already moved `DesignCapacity` and `NominalChargeCapacity` down this exact path.
    func testThreeState_resolvesAdapterDetailsAtEveryRungOfTheLadder() {
        let details: [String: Any] = ["Watts": 96, "AdapterVoltage": 20000, "Current": 4800]

        // rung 1 — today's layout.
        XCTAssertEqual(PowerAdapter.resolve(properties: ["AdapterDetails": details]).adapter?.watts, 96)

        // rung 2 — the node's nested BatteryData, where the capacities went on 27.
        XCTAssertEqual(PowerAdapter.resolve(properties: ["BatteryData": ["AdapterDetails": details]]).adapter?.watts, 96)

        // rung 3 — the AppleSmartBatteryPack child, where the rest of the gas gauge went.
        let packed: [String: Any] = [
            BatteryLifetimeParser.packPropertiesKey: ["BatteryData": ["AdapterDetails": details]]
        ]
        XCTAssertEqual(PowerAdapter.resolve(properties: packed).adapter?.watts, 96)
    }

    /// A rung that carries `AdapterDetails` but no `Watts` (this machine's live top-level dict is
    /// literally `{FamilyCode: 0}`) must not stop the ladder — it must fall through to the next rung.
    func testThreeState_anEmptyAdapterDetailsDoesNotShadowALowerRung() {
        let props: [String: Any] = [
            "AdapterDetails": ["FamilyCode": 0],                       // live, this machine, on battery
            "BatteryData": ["AdapterDetails": ["Watts": 75]],
        ]
        XCTAssertEqual(PowerAdapter.resolve(properties: props).adapter?.watts, 75)
    }

    /// The state carries the sentence the card renders. Only the failed read gets one.
    func testThreeState_onlyTheFailedReadCarriesANote() {
        XCTAssertNil(PowerAdapterReadState.connected(PowerAdapter(watts: 75, voltage_mV: nil, current_mA: nil)).note)
        XCTAssertNil(PowerAdapterReadState.noAdapter.note, "an unplugged Mac is not a problem to report")
        let note = PowerAdapterReadState.unavailable("the wattage resolved at no known layout").note
        XCTAssertEqual(note, "Power adapter details unavailable — the wattage resolved at no known layout.")
    }

    // MARK: - §5.2 row 17 · the strictly-public IOPSCopyExternalPowerAdapterDetails rung
    //
    // VERIFIED BEFORE WRITING THIS (2026-09-08, this M4 Max, adapter attached):
    //   * PUBLIC: `IOPSCopyExternalPowerAdapterDetails(void)` is declared in the SDK's own
    //     `IOKit.framework/Headers/ps/IOPowerSources.h:375` — no dlsym, no vendored prototype, no
    //     undeclared symbol. That is what separates this swap from the `IOPMCopy*` family §5.3 parks.
    //   * BYTE-IDENTICAL: probed live against the IORegistry `AdapterDetails` the ladder reads — the
    //     SAME 11 keys (AdapterID, AdapterPowerTier, AdapterVoltage, Current, Description, FamilyCode,
    //     IsWireless, PMUConfiguration, UsbHvcHvcIndex, UsbHvcMenu, Watts) with ZERO value differences.
    //     So `parse` needs no new key names; only the SOURCE of the dict changes.
    //   * CHEAP: 0.078 ms median / 0.27 ms max over 200 calls.
    //
    // AND THE REASON IT IS A RUNG, NOT A REPLACEMENT. The header states it outright: *"If no adapter is
    // attached, **or if there is an error**, returns NULL."* One NULL for two facts is precisely the
    // collapse `c867c26` removed from this reader. Retiring the IORegistry read would take the
    // `ExternalConnected` witness with it and put the two-state bug back. So the public dict becomes the
    // FIRST rung of the existing ladder and the witness stays exactly where it is.

    func testPublicRung_isPreferredOverTheIORegistryLadder() {
        // The public API answered. It wins even though a (stale, different) IORegistry rung also has one.
        let publicDetails: [String: Any] = ["Watts": 96, "AdapterVoltage": 20000, "Current": 4800]
        let props: [String: Any] = ["AdapterDetails": ["Watts": 75], "ExternalConnected": true]
        let state = PowerAdapter.resolve(properties: props, publicDetails: publicDetails)
        XCTAssertEqual(state.adapter?.watts, 96, "the supported API is the authority when it answers")
        XCTAssertEqual(state.adapter?.voltage_mV, 20000, "and the byte-identical dict parses unchanged")
    }

    /// The whole point of the swap: it survives a relocation of `AdapterDetails` inside AppleSmartBattery,
    /// which is the drift the ladder exists to detect and the public API is immune to.
    func testPublicRung_answersWhenNoIORegistryRungDoes() {
        let state = PowerAdapter.resolve(properties: ["ExternalConnected": true],
                                         publicDetails: ["Watts": 140])
        XCTAssertEqual(state.adapter?.watts, 140,
                       "power connected + no IORegistry wattage was .unavailable; the public read now answers")
    }

    /// A public dict WITHOUT `Watts` is drift in its own right — it must not shadow a rung that has one.
    func testPublicRung_withoutWatts_fallsThroughToTheLadder() {
        XCTAssertEqual(PowerAdapter.resolve(properties: ["AdapterDetails": ["Watts": 75]],
                                            publicDetails: ["FamilyCode": 0]).adapter?.watts, 75)
    }

    /// THE REGRESSION GUARD. `IOPSCopyExternalPowerAdapterDetails` returns NULL for "unplugged" AND for
    /// "error" — so a NULL is evidence of NOTHING and must never be allowed to decide. The witness does.
    func testPublicRung_nullDoesNotCollapseAbsenceAndFailure() {
        XCTAssertEqual(PowerAdapter.resolve(properties: ["ExternalConnected": false], publicDetails: nil),
                       .noAdapter, "a NULL public read plus a witness saying unplugged is still .noAdapter")
        guard case .unavailable = PowerAdapter.resolve(properties: ["ExternalConnected": true],
                                                       publicDetails: nil) else {
            return XCTFail("a NULL public read must not launder a plugged-in Mac into .noAdapter")
        }
        guard case .unavailable = PowerAdapter.resolve(properties: nil, publicDetails: nil) else {
            return XCTFail("both reads failed — that is still three states, not two")
        }
        XCTAssertNotEqual(PowerAdapter.resolve(properties: ["ExternalConnected": false], publicDetails: nil),
                          PowerAdapter.resolve(properties: ["ExternalConnected": true], publicDetails: nil))
    }

    /// The public rung may answer even when the IORegistry read failed outright — one succeeding read is
    /// enough, and reporting a failure we recovered from would be its own dishonesty.
    func testPublicRung_answersEvenWhenThePropertyCopyFailed() {
        XCTAssertEqual(PowerAdapter.resolve(properties: nil, publicDetails: ["Watts": 61]).adapter?.watts, 61)
    }

    /// The source must publish the state, not just the value — otherwise the split dies at the boundary
    /// (exactly how `BatteryLifetimeSource.lastFailure` sat unrendered until the #29 orphan pass).
    func testSourcePublishesTheReadStateNotJustTheValue() {
        let source = PowerAdapterSource(reader: MockAdapterReader(state: .unavailable("no known layout")))
        source.refresh()
        XCTAssertNil(source.watts)
        XCTAssertEqual(source.readState, .unavailable("no known layout"))
        XCTAssertNotNil(source.readState.note, "the card has something honest to render")

        let quiet = PowerAdapterSource(reader: MockAdapterReader(state: .noAdapter))
        quiet.refresh()
        XCTAssertNil(quiet.watts)
        XCTAssertNil(quiet.readState.note, "on battery the card stays silent")
    }
}
