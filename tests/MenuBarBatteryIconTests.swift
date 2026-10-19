import XCTest
import AppKit

/// Sprint 4.B: the pure RenderPlan decision layer (exhaustive boundaries), the custom drawing
/// layer (validity + per-mode template flag), and the retained 4.A SF-Symbols fallback functions.
final class MenuBarBatteryIconTests: XCTestCase {

    private func plan(_ soc: Int, charging: Bool = false, hold: Bool = false, full: Bool = false,
                      ac: Bool = false, lowPower: Bool = false, keepAwake: Bool = false,
                      interrupted: Bool = false)
    -> MenuBarBatteryIcon.RenderPlan {
        MenuBarBatteryIcon.render(soc: soc, isChargingDisplay: charging, holdMark: hold,
                                  fullyCharged: full, onAC: ac, lowPower: lowPower, keepAwake: keepAwake,
                                  keepAwakeInterrupted: interrupted)
    }

    /// The ink footprint of the keep-awake badge column, for the cold-cup assertions below.
    /// `topRow` is the HIGHEST inked scanline (row 0 = the top of the image), so a rising `topRow`
    /// means ink disappeared from above the cup — i.e. the wisps are gone.
    private struct BadgeInk { let pixels: Set<[Int]>; let count: Int; let topRow: Int }

    private func badgeInk(_ p: MenuBarBatteryIcon.RenderPlan, steamPhase: CGFloat = 0) throws -> BadgeInk {
        let image = MenuBarBatteryIcon.draw(p, steamPhase: steamPhase)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let badge = MenuBarBatteryIcon.keepAwakeBadgeRect(batteryWidth: MenuBarBatteryIcon.canvasSize.width,
                                                          height: MenuBarBatteryIcon.canvasSize.height)
        let sx = CGFloat(rep.pixelsWide) / image.size.width
        var pixels = Set<[Int]>(); var topRow = rep.pixelsHigh
        for px in Int(badge.minX * sx)..<min(rep.pixelsWide, Int((badge.maxX * sx).rounded(.up))) {
            for py in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: px, y: py), c.alphaComponent > 0.10 else { continue }
                pixels.insert([px, py]); topRow = min(topRow, py)
            }
        }
        return BadgeInk(pixels: pixels, count: pixels.count, topRow: topRow)
    }

    // MARK: - #26 hold mark (4.E)

    func testHoldMarkOnlyAtLimitHold() {
        XCTAssertTrue(MenuBarBatteryIcon.holdMarkOn(state: .limitHold))
        // never for ambiguousHold (we don't claim a hold we can't verify), nor any other state
        for s: TelemetryChargeState in [.ambiguousHold, .charging, .discharging, .idleInhibit, .unknown] {
            XCTAssertFalse(MenuBarBatteryIcon.holdMarkOn(state: s), "\(s)")
        }
        XCTAssertFalse(MenuBarBatteryIcon.holdMarkOn(state: nil), "monitoring-only → no mark")
    }

    func testHoldMarkInPlanAndBoltMutualExclusion() {
        XCTAssertTrue(plan(80, hold: true).holdMark)
        XCTAssertFalse(plan(80, hold: true).bolt, "hold mark suppresses the bolt (truth over intent)")
        // the conflicting input (charging AND hold) resolves to hold-wins, bolt off
        let conflict = plan(80, charging: true, hold: true)
        XCTAssertTrue(conflict.holdMark)
        XCTAssertFalse(conflict.bolt)
        // ordinary charging keeps the bolt, no hold mark
        XCTAssertTrue(plan(80, charging: true).bolt)
        XCTAssertFalse(plan(80, charging: true).holdMark)
        // #21 full-on-AC: no hold mark even if asked (a full battery reads as full)
        XCTAssertFalse(plan(100, hold: true, full: true, ac: true).holdMark)
    }

    // MARK: - bolt v2 veto matrix (4.E sec 2)

    func testBoltVetoMatrix_flagTrueButVetoedStatesGiveNoBolt() {
        // The intent flag is TRUE, but at every lie-prone state the truth veto suppresses the bolt.
        for vetoed: TelemetryChargeState in [.limitHold, .ambiguousHold, .idleInhibit] {
            XCTAssertFalse(MenuBarBatteryIcon.boltOn(isChargingFlag: true, state: vetoed),
                           "flag true + \(vetoed) → vetoed, no bolt")
        }
    }

    func testBoltInstantOnPath_flagDrivesBoltAtNonVetoedStates() {
        // Native-instant: at charging/discharging/unknown the bolt follows the flag directly.
        for s: TelemetryChargeState in [.charging, .discharging, .unknown] {
            XCTAssertTrue(MenuBarBatteryIcon.boltOn(isChargingFlag: true, state: s), "flag true + \(s) → bolt")
            XCTAssertFalse(MenuBarBatteryIcon.boltOn(isChargingFlag: false, state: s), "flag false + \(s) → no bolt")
        }
    }

    func testBoltMonitoringOnlyModeIsFlagAlone() {
        // <26.4 (nil state, no pipeline) = flag alone, matching native exactly — no veto.
        XCTAssertTrue(MenuBarBatteryIcon.boltOn(isChargingFlag: true, state: nil))
        XCTAssertFalse(MenuBarBatteryIcon.boltOn(isChargingFlag: false, state: nil))
    }

    func testHoldMarkChangesThePixels() {
        // The pause-bar knockout must actually alter the rendering (hold vs plain, same SoC).
        let withMark = MenuBarBatteryIcon.draw(plan(80, hold: true)).tiffRepresentation
        let without  = MenuBarBatteryIcon.draw(plan(80, hold: false)).tiffRepresentation
        XCTAssertNotNil(withMark); XCTAssertNotNil(without)
        XCTAssertNotEqual(withMark, without, "the hold mark must change the drawn pixels")
        // …and the hold mark differs from the bolt knockout (distinct glyphs).
        let bolt = MenuBarBatteryIcon.draw(plan(80, charging: true)).tiffRepresentation
        XCTAssertNotEqual(withMark, bolt, "hold mark and bolt are visually distinct")
    }

    // MARK: - RenderPlan boundaries (SPEC sec 3)

    func testFillIsContinuousNotBucketed() {
        XCTAssertEqual(plan(37).fillFraction, 0.37, accuracy: 1e-9)
        XCTAssertEqual(plan(63).fillFraction, 0.63, accuracy: 1e-9)
        XCTAssertEqual(plan(1).fillFraction, 0.01, accuracy: 1e-9)
    }

    func testRedAlertBoundary_0_20_21() {
        // Batch 1b: soc <= 20 AND not charging → redAlert; 21 → template.
        XCTAssertEqual(plan(0).colorMode, .redAlert)
        XCTAssertEqual(plan(20).colorMode, .redAlert)
        XCTAssertEqual(plan(21).colorMode, .template)
        XCTAssertEqual(plan(100).colorMode, .template)
        // fill still tracks soc at the red boundary
        XCTAssertEqual(plan(20).fillFraction, 0.20, accuracy: 1e-9)
        XCTAssertEqual(plan(0).fillFraction, 0.0, accuracy: 1e-9)
    }

    func testChargingSuppressesRed() {
        // Same low SoC, but charging → NOT red (template), and bolt on.
        XCTAssertEqual(plan(5, charging: true).colorMode, .template)
        XCTAssertTrue(plan(5, charging: true).bolt)
        XCTAssertEqual(plan(10, charging: true).colorMode, .template)
        // …and without charging it IS red.
        XCTAssertEqual(plan(5, charging: false).colorMode, .redAlert)
        XCTAssertFalse(plan(5, charging: false).bolt)
    }

    /// #21's fill rule is unchanged; its SHAPE and COLOUR rules were superseded on 2026-09-08 — full
    /// on AC now shows the same bolt as charging on a green fill, instead of no bolt on a template.
    func testFullOnACForcesFullFill_21() {
        let p = plan(100, charging: true, full: true, ac: true)
        XCTAssertEqual(p.fillFraction, 1.0, accuracy: 1e-9)
        // The #21 branch forces full fill even if the raw soc is lower.
        XCTAssertEqual(plan(60, full: true, ac: true).fillFraction, 1.0, accuracy: 1e-9)
        // Shape + colour are pinned by testFullOnACShowsTheBoltOnGreen.
    }

    func testFullyChargedOffACDoesNotForceFull() {
        // fullyCharged only matters ON AC; off AC it falls through to the continuous mapping.
        XCTAssertEqual(plan(60, full: true, ac: false).fillFraction, 0.60, accuracy: 1e-9)
    }

    // MARK: - full-on-AC: the same bolt, on a green fill (2026-09-08 ruling; retires #21b's plug)

    func testFullOnACShowsTheBoltOnGreen() {
        let p = plan(100, full: true, ac: true)
        XCTAssertTrue(p.bolt, "full-on-AC carries the SAME bolt as charging")
        XCTAssertEqual(p.colorMode, .chargedGreen, "the green fill is what distinguishes charged")
        XCTAssertFalse(p.holdMark, "a full battery reads as full, not held below")
        XCTAssertEqual(p.fillFraction, 1.0, accuracy: 1e-9)
    }

    func testFullOnACRequiresBothHalves() {
        XCTAssertNotEqual(plan(100, full: true, ac: false).colorMode, .chargedGreen,
                          "full off AC is not 'at target'")
        XCTAssertNotEqual(plan(100, full: false, ac: true).colorMode, .chargedGreen,
                          "on AC but not full is not 'at target'")
        for soc in [0, 20, 50, 80, 99] {
            XCTAssertNotEqual(plan(soc, ac: true).colorMode, .chargedGreen, "soc \(soc) on AC is not full")
        }
    }

    func testChargedAndChargingShareTheShapeAndDifferOnlyInColour() {
        // THE ruling: one shape, colour carries the state. Both draw a bolt; only the mode differs.
        let charged = plan(100, full: true, ac: true)
        let charging = plan(80, charging: true, ac: true)
        XCTAssertTrue(charged.bolt); XCTAssertTrue(charging.bolt)
        XCTAssertEqual(charged.colorMode, .chargedGreen)
        XCTAssertEqual(charging.colorMode, .template)
        XCTAssertNotEqual(MenuBarBatteryIcon.draw(charged).tiffRepresentation,
                          MenuBarBatteryIcon.draw(charging).tiffRepresentation,
                          "charged and charging must not render identically")
    }

    func testFullOnACIsNotPixelIdenticalToFullOnBattery() {
        // The original owner-reported regression: the two states looked the same. Still guarded.
        let plugged = MenuBarBatteryIcon.draw(plan(100, full: true, ac: true)).tiffRepresentation
        let onBattery = MenuBarBatteryIcon.draw(plan(100)).tiffRepresentation
        XCTAssertNotNil(plugged); XCTAssertNotNil(onBattery)
        XCTAssertNotEqual(plugged, onBattery, "full on AC must not render identically to full on battery")
    }

    func testLimitHoldIsGreenWithItsOwnShape() {
        let p = plan(80, hold: true, ac: true)
        XCTAssertEqual(p.colorMode, .chargedGreen, "a verified hold is also 'at target'")
        XCTAssertTrue(p.holdMark); XCTAssertFalse(p.bolt, "the hold shape replaces the bolt")
        XCTAssertNotEqual(MenuBarBatteryIcon.draw(p).tiffRepresentation,
                          MenuBarBatteryIcon.draw(plan(100, full: true, ac: true)).tiffRepresentation,
                          "held and charged are both green but must stay visually distinct")
    }

    /// REGRESSION (owner-reported 2026-09-08): the keep-awake espresso badge borrowed the battery's
    /// stroke colour, so when `.chargedGreen` began stroking the body green the CUP turned green too.
    /// The badge reports our own keep-awake assertion, never the battery's condition — so no state
    /// colour may ever appear in the badge region, in any colour mode.
    func testKeepAwakeBadgeNeverTakesAStateColour() throws {
        for p in [plan(100, full: true, ac: true, keepAwake: true),
                  plan(80, hold: true, ac: true, keepAwake: true),
                  plan(8, keepAwake: true),                       // red
                  plan(50, lowPower: true, keepAwake: true),      // yellow
                  // the INTERRUPTED (cold-cup) badge is a SHAPE change, never a colour one — the
                  // honesty cue must not smuggle a state colour in through the back door.
                  plan(100, full: true, ac: true, keepAwake: true, interrupted: true),
                  plan(80, hold: true, ac: true, keepAwake: true, interrupted: true),
                  plan(8, keepAwake: true, interrupted: true),
                  plan(50, lowPower: true, keepAwake: true, interrupted: true)] {
            let image = MenuBarBatteryIcon.draw(p)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let badge = MenuBarBatteryIcon.keepAwakeBadgeRect(batteryWidth: MenuBarBatteryIcon.canvasSize.width,
                                                              height: MenuBarBatteryIcon.canvasSize.height)
            let sx = CGFloat(rep.pixelsWide) / image.size.width
            let sy = CGFloat(rep.pixelsHigh) / image.size.height
            var sawColour = false
            for px in Int(badge.minX * sx)..<Int(badge.maxX * sx) {
                for py in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: px, y: py), c.alphaComponent > 0.35 else { continue }
                    guard let rgb = c.usingColorSpace(.deviceRGB) else { continue }
                    // any pixel where one channel clearly dominates is a hue, i.e. a state colour
                    let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
                    let maxC = max(r, g, b), minC = min(r, g, b)
                    if maxC - minC > 0.25 { sawColour = true }
                }
            }
            _ = sy
            XCTAssertFalse(sawColour, "badge picked up a state colour in mode \(p.colorMode)")
        }
    }

    func testClamping() {
        XCTAssertEqual(plan(150).fillFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(plan(-5).fillFraction, 0.0, accuracy: 1e-9)
        XCTAssertEqual(plan(-5).colorMode, .redAlert, "negative is <=20 and not charging")
        XCTAssertEqual(plan(101).fillFraction, 1.0, accuracy: 1e-9)
    }

    func testBoltTracksChargingDisplay() {
        XCTAssertTrue(plan(50, charging: true).bolt)
        XCTAssertFalse(plan(50, charging: false).bolt)
    }

    // MARK: - drawing layer (validity + template flag per colorMode)

    func testDrawProducesValidImageTemplateAndRed() {
        let t = MenuBarBatteryIcon.draw(plan(50))                 // template
        XCTAssertTrue(t.isValid); XCTAssertGreaterThan(t.size.width, 0)
        XCTAssertTrue(t.isTemplate, "normal states are template")

        let r = MenuBarBatteryIcon.draw(plan(5))                  // redAlert (low, not charging)
        XCTAssertTrue(r.isValid)
        XCTAssertFalse(r.isTemplate, "the red low-battery variant is non-template")
    }

    func testDrawRasterizesAt1xAnd2x() {
        let img = MenuBarBatteryIcon.draw(plan(50))
        XCTAssertNotNil(img.cgImage(forProposedRect: nil, context: nil, hints: nil), "@1x raster")
        // Force a 2x-pixel rasterization through a bitmap rep.
        let s = img.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(s.width * 2), pixelsHigh: Int(s.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        XCTAssertNotNil(rep, "@2x rep allocates")
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep!)
        img.draw(in: NSRect(origin: .zero, size: s))
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertNotNil(rep!.tiffRepresentation, "@2x rasterization produced pixels")
    }

    func testChargingBoltChangesThePixels() {
        // The bolt knockout must actually alter the rendering (charging vs not, same SoC).
        let withBolt = MenuBarBatteryIcon.draw(plan(80, charging: true)).tiffRepresentation
        let without  = MenuBarBatteryIcon.draw(plan(80, charging: false)).tiffRepresentation
        XCTAssertNotNil(withBolt); XCTAssertNotNil(without)
        XCTAssertNotEqual(withBolt, without, "the charging bolt must change the drawn pixels")
    }

    func testChargingBoltVisibleAtLowSOC_splitDrawOverEmpty() {
        // Note 3: at a low charge the honest fill is narrow, so the bolt sits mostly over the EMPTY body.
        // The split-draw (positive foreground over empty) must still render it: a 20%-charging glyph
        // differs from a 20%-idle one even though the fill is the same narrow honest width.
        let charging = MenuBarBatteryIcon.draw(plan(20, charging: true)).tiffRepresentation
        let idle     = MenuBarBatteryIcon.draw(plan(20, charging: false)).tiffRepresentation
        XCTAssertNotNil(charging); XCTAssertNotNil(idle)
        XCTAssertNotEqual(charging, idle, "the split-drawn bolt renders even when the fill is narrow")
    }

    // MARK: - public image: never blank, fallback chain present

    func testImageIsNeverBlankAcrossInputs() {
        for soc in [0, 5, 10, 11, 50, 99, 100, 150, -5] {
            for charging in [true, false] {
                let img = MenuBarBatteryIcon.image(soc: soc, isChargingDisplay: charging,
                                                   holdMark: false, fullyCharged: false, onAC: charging,
                                                   lowPower: false)
                XCTAssertTrue(img.isValid, "soc \(soc) charging \(charging)")
                XCTAssertGreaterThan(img.size.width, 0)
            }
        }
    }

    func testImageTemplateFlagFollowsColorMode() {
        XCTAssertTrue(MenuBarBatteryIcon.image(soc: 50, isChargingDisplay: false,
                                               holdMark: false, fullyCharged: false, onAC: true,
                                               lowPower: false).isTemplate)
        XCTAssertFalse(MenuBarBatteryIcon.image(soc: 5, isChargingDisplay: false,
                                                holdMark: false, fullyCharged: false, onAC: false,
                                                lowPower: false).isTemplate,
                       "low + not charging → red, non-template")
        XCTAssertFalse(MenuBarBatteryIcon.image(soc: 50, isChargingDisplay: false,
                                                holdMark: false, fullyCharged: false, onAC: false,
                                                lowPower: true).isTemplate,
                       "Low Power Mode → yellow, non-template")
    }

    // MARK: - #2-glyph PART A: yellow Low Power Mode tint + the color ladder (RED > YELLOW > TEMPLATE)

    func testLPM_chargingAt50_isYellowWithBolt() {
        let p = plan(50, charging: true, lowPower: true)
        XCTAssertEqual(p.colorMode, .lowPower, "LPM tints yellow; charging does NOT suppress yellow")
        XCTAssertTrue(p.bolt, "the bolt still lights (a knockout cuts through the yellow fill)")
    }

    func testLPM_holdAt80_isYellowWithHoldMarkNoBolt() {
        let p = plan(80, charging: true, hold: true, lowPower: true)
        XCTAssertEqual(p.colorMode, .lowPower)
        XCTAssertTrue(p.holdMark)
        XCTAssertFalse(p.bolt, "hold (truth) still suppresses the bolt under yellow")
    }

    func testLPM_redBeatsYellow_at8NotCharging() {
        let p = plan(8, charging: false, lowPower: true)
        XCTAssertEqual(p.colorMode, .redAlert, "RED (critical, not charging) beats YELLOW")
    }

    func testLPM_chargingSuppressesRedNotYellow_at8Charging() {
        let p = plan(8, charging: true, lowPower: true)
        XCTAssertEqual(p.colorMode, .lowPower, "charging suppresses red → falls to YELLOW (not template)")
        XCTAssertTrue(p.bolt)
    }

    func testLPM_fullOnAC_isYellowNotGreen_21() {
        let p = plan(100, full: true, ac: true, lowPower: true)
        XCTAssertEqual(p.colorMode, .lowPower, "#21 full-on-AC still tints yellow under LPM — yellow outranks green")
        XCTAssertEqual(p.fillFraction, 1.0)
        XCTAssertTrue(p.bolt, "the bolt is shape-channel; the yellow tint doesn't suppress it")
        XCTAssertFalse(p.holdMark)
    }

    func testLPM_off_isUnchanged() {
        XCTAssertEqual(plan(50, lowPower: false).colorMode, .template, "LPM off → template as before")
        XCTAssertEqual(plan(8, charging: false, lowPower: false).colorMode, .redAlert, "LPM off → red as before")
    }

    func testOnlyLowEnergyModeIsYellow() {
        // The live thread is `snapshot.energyMode == .low`; .high/.automatic/.unavailable → not yellow.
        for mode in [EnergyMode.automatic, .high, .unavailable] {
            XCTAssertEqual(plan(50, lowPower: mode == .low).colorMode, .template, "\(mode) must NOT be yellow")
        }
        XCTAssertEqual(plan(50, lowPower: EnergyMode.low == .low).colorMode, .lowPower, ".low → yellow")
    }

    func testLPM_drawIsNonTemplateAndChangesPixelsVsTemplate() {
        let yellow = MenuBarBatteryIcon.draw(plan(50, lowPower: true))
        XCTAssertTrue(yellow.isValid)
        XCTAssertFalse(yellow.isTemplate, "yellow LPM glyph is non-template")
        let template = MenuBarBatteryIcon.draw(plan(50, lowPower: false)).tiffRepresentation
        XCTAssertNotEqual(yellow.tiffRepresentation, template, "yellow tint changes the drawn pixels")
    }

    /// Pins the "SHAPE logic UNCHANGED by lowPower" invariant: a lowPower vs template render at the SAME
    /// soc/charging/hold differs ONLY in hue — the drawn GEOMETRY (coverage mask, incl. the bolt
    /// knockout) is identical. (charging:true so the bolt knockout is exercised too.)
    func testLPM_changesOnlyHue_notGeometry() throws {
        func coverageMask(_ img: NSImage) throws -> [UInt8] {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))
            var mask: [UInt8] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    mask.append(a > 0.01 ? 1 : 0)   // drawn vs transparent — the geometry, not the hue
                }
            }
            return mask
        }
        let yellow = try coverageMask(MenuBarBatteryIcon.draw(plan(50, charging: true, lowPower: true)))
        let template = try coverageMask(MenuBarBatteryIcon.draw(plan(50, charging: true, lowPower: false)))
        XCTAssertEqual(yellow, template,
                       "lowPower changes only hue — the drawn geometry (fill + bolt knockout) is identical")
    }

    // MARK: - #2-glyph PART B: bolt fill-behind-when-lit invariant + honest no-bolt width

    func testFillRect_noBolt_isHonestSOCWidth() {
        let body = NSRect(x: 2, y: 1, width: 20, height: 11)
        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        let fr = MenuBarBatteryIcon.fillRect(inner: inner, body: body, socFraction: 0.5, holdMark: false)
        XCTAssertEqual(fr.width, inner.width * 0.5, accuracy: 0.001, "not holding → honest SOC width, never extended")
    }

    func testFillRect_chargingFillIsHonest_notBackedToBolt() {
        // Batch 1a: the fill is the HONEST SoC width while charging — the bolt no longer backs it (it is
        // split-drawn so it reads at any fill level). The old dishonest extend-to-~71% is gone.
        let body = NSRect(x: 2, y: 1, width: 20, height: 11)
        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        let fr = MenuBarBatteryIcon.fillRect(inner: inner, body: body, socFraction: 0.05, holdMark: false)
        XCTAssertEqual(fr.width, inner.width * 0.05, accuracy: 0.001, "charging fill is honest SoC, never extended to the bolt")
    }

    func testFillRect_fullSOC_clampedToInner() {
        let body = NSRect(x: 2, y: 1, width: 20, height: 11)
        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        let fr = MenuBarBatteryIcon.fillRect(inner: inner, body: body, socFraction: 1.0, holdMark: false)
        XCTAssertEqual(fr.width, inner.width, accuracy: 0.001, "full SOC → clamped to inner")
    }

    // MARK: - #2-glyph PART B (COMMIT 2 / ISSUE-4): hold-mark fill-behind-when-held, backed at the hold SOC

    func testFillRect_holdMarkAtLowSOC_backsTheHoldMark() {
        // ISSUE-4: at a low limit (50%) the honest SOC bar stops LEFT of the centered pause-bars, so the
        // destinationOut knockout would cut empty body (the right bar vanishes). The hold-mark must be
        // backed exactly like the bolt so the knockout always cuts through fill — even at a 50% hold.
        let body = NSRect(x: 2, y: 1, width: 20, height: 11)
        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        let fr = MenuBarBatteryIcon.fillRect(inner: inner, body: body, socFraction: 0.5, holdMark: true)
        let mark = MenuBarBatteryIcon.holdMarkPath(in: body).bounds
        XCTAssertGreaterThanOrEqual(fr.maxX, mark.maxX, "fill reaches the hold-mark's right edge — knockout has fill under it")
        XCTAssertLessThanOrEqual(fr.minX, mark.minX, "fill starts at/before the hold-mark's left edge")
        XCTAssertLessThanOrEqual(fr.width, inner.width + 0.001, "never exceeds the inner region")
    }

    func testFillRect_holdMarkAtHighSOC_coveredButNotOverExtended() {
        // Honesty: at a high limit (80%) the honest bar ALREADY covers the centered mark, so backing is a
        // no-op — the fill stays the honest SOC width (not inflated), and still fully backs the mark.
        let body = NSRect(x: 2, y: 1, width: 20, height: 11)
        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        let fr = MenuBarBatteryIcon.fillRect(inner: inner, body: body, socFraction: 0.8, holdMark: true)
        let mark = MenuBarBatteryIcon.holdMarkPath(in: body).bounds
        XCTAssertGreaterThanOrEqual(fr.maxX, mark.maxX, "honest fill already backs the mark at a high limit")
        XCTAssertEqual(fr.width, inner.width * 0.8, accuracy: 0.001,
                       "honest SOC width — backing never inflates beyond what SOC already covers")
    }

    // MARK: - #EI-1 keep-awake pip (additive overlay; independent of battery state)

    func testKeepAwakePlumbsThroughRender() {
        // PLUMB: the flag is threaded straight from render's param into the plan.
        XCTAssertTrue(plan(50, keepAwake: true).keepAwake)
        XCTAssertFalse(plan(50, keepAwake: false).keepAwake)
    }

    func testKeepAwakeIsIndependentOfBatteryState() {
        // INDEPENDENCE (the core guarantee): flipping keepAwake changes ONLY .keepAwake — fillFraction,
        // bolt, holdMark, and colorMode are identical true-vs-false across every representative state.
        let cases: [(String, () -> MenuBarBatteryIcon.RenderPlan, () -> MenuBarBatteryIcon.RenderPlan)] = [
            ("normal/template",    { self.plan(50, keepAwake: false) },                        { self.plan(50, keepAwake: true) }),
            ("low/redAlert",       { self.plan(10, keepAwake: false) },                        { self.plan(10, keepAwake: true) }),
            ("lowPower/yellow",    { self.plan(50, lowPower: true, keepAwake: false) },        { self.plan(50, lowPower: true, keepAwake: true) }),
            ("charging/bolt",      { self.plan(50, charging: true, keepAwake: false) },        { self.plan(50, charging: true, keepAwake: true) }),
            ("limitHold/holdMark", { self.plan(80, hold: true, keepAwake: false) },            { self.plan(80, hold: true, keepAwake: true) }),
            ("full-on-AC",         { self.plan(100, full: true, ac: true, keepAwake: false) }, { self.plan(100, full: true, ac: true, keepAwake: true) }),
        ]
        for (label, offMake, onMake) in cases {
            let off = offMake(), on = onMake()
            XCTAssertEqual(on.fillFraction, off.fillFraction, accuracy: 1e-9, "\(label): fillFraction unchanged by keepAwake")
            XCTAssertEqual(on.bolt,      off.bolt,      "\(label): bolt unchanged by keepAwake")
            XCTAssertEqual(on.holdMark,  off.holdMark,  "\(label): holdMark unchanged by keepAwake")
            XCTAssertEqual(on.colorMode, off.colorMode, "\(label): colorMode unchanged by keepAwake")
            XCTAssertTrue(on.keepAwake,   "\(label): keepAwake:true threads through")
            XCTAssertFalse(off.keepAwake, "\(label): keepAwake:false threads through")
        }
    }

    func testKeepAwakeBadgeSitsOutsideTheBatteryBody() {
        // NON-COLLISION (the "no glyph overload" invariant): the keep-awake espresso badge lives OUTSIDE the
        // battery to the RIGHT, so it can never overlap the interior bolt/hold marks — a stronger guarantee
        // than the old interior pip's clearance check. The badge starts at/after the battery's right edge.
        let batteryW: CGFloat = 28, H: CGFloat = 14
        let badge = MenuBarBatteryIcon.keepAwakeBadgeRect(batteryWidth: batteryW, height: H)
        XCTAssertGreaterThanOrEqual(badge.minX, batteryW, "badge starts at/after the battery's right edge")
        XCTAssertGreaterThan(badge.width, 0, "badge has a positive footprint")
        XCTAssertEqual(badge.maxX, batteryW + MenuBarBatteryIcon.keepAwakeBadgeGap + MenuBarBatteryIcon.keepAwakeBadgeWidth,
                       accuracy: 1e-9, "badge spans gap + badge width past the battery")
    }

    func testKeepAwakeWidensTheImageOnlyWhenActive() {
        // The side badge grows the canvas by exactly gap+width ONLY while keep-awake is on; the battery's own
        // footprint (and every non-keep-awake image) is unchanged — so nothing shifts when a session is off.
        let off = MenuBarBatteryIcon.draw(plan(50, keepAwake: false)).size
        let on  = MenuBarBatteryIcon.draw(plan(50, keepAwake: true)).size
        XCTAssertEqual(off.width, MenuBarBatteryIcon.canvasSize.width, accuracy: 1e-9, "off == the battery footprint")
        XCTAssertEqual(on.height, off.height, accuracy: 1e-9, "keep-awake never changes height")
        XCTAssertEqual(on.width, off.width + MenuBarBatteryIcon.keepAwakeBadgeGap + MenuBarBatteryIcon.keepAwakeBadgeWidth,
                       accuracy: 1e-9, "on == battery + badge")
    }

    // MARK: - #EI-1 HONESTY: a session the Mac SLEPT THROUGH draws a COLD cup

    /// The defect (owner-reported 2026-09-08): the badge rendered from `isOn` (`session != nil`) alone,
    /// so when macOS slept through a keep-awake session — lid close, Apple menu -> Sleep — the session
    /// object survived and the badge went on steaming as if the promise had held. `isInterrupted` had
    /// been recording exactly that since the day it was written, with no reader in the glyph.

    func testInterruptionPlumbsThroughRender() {
        XCTAssertTrue(plan(50, keepAwake: true, interrupted: true).keepAwakeInterrupted)
        XCTAssertFalse(plan(50, keepAwake: true).keepAwakeInterrupted)
        // full-on-AC returns from the OTHER branch of render() — it must plumb the flag too
        XCTAssertTrue(plan(100, full: true, ac: true, keepAwake: true, interrupted: true).keepAwakeInterrupted)
        XCTAssertFalse(plan(100, full: true, ac: true, keepAwake: true).keepAwakeInterrupted)
    }

    func testInterruptionTouchesNothingButTheBadge() {
        // Same independence guarantee `keepAwake` carries: the interruption reports OUR assertion's
        // fate, never the battery's condition, so no battery field may move with it.
        for (label, off, on) in [
            ("normal/template",    plan(50, keepAwake: true),                        plan(50, keepAwake: true, interrupted: true)),
            ("low/redAlert",       plan(10, keepAwake: true),                        plan(10, keepAwake: true, interrupted: true)),
            ("lowPower/yellow",    plan(50, lowPower: true, keepAwake: true),        plan(50, lowPower: true, keepAwake: true, interrupted: true)),
            ("charging/bolt",      plan(50, charging: true, keepAwake: true),        plan(50, charging: true, keepAwake: true, interrupted: true)),
            ("limitHold/holdMark", plan(80, hold: true, keepAwake: true),            plan(80, hold: true, keepAwake: true, interrupted: true)),
            ("full-on-AC",         plan(100, full: true, ac: true, keepAwake: true), plan(100, full: true, ac: true, keepAwake: true, interrupted: true)),
        ] {
            XCTAssertEqual(on.fillFraction, off.fillFraction, accuracy: 1e-9, "\(label): fillFraction unchanged")
            XCTAssertEqual(on.bolt,      off.bolt,      "\(label): bolt unchanged")
            XCTAssertEqual(on.holdMark,  off.holdMark,  "\(label): holdMark unchanged")
            XCTAssertEqual(on.colorMode, off.colorMode, "\(label): colorMode unchanged — the cue is SHAPE, never colour")
            XCTAssertTrue(on.keepAwake, "\(label): the session is still ON — an interruption never implies off")
        }
    }

    func testInterruptedStopsTheSteamAndKeepsTheCup() throws {
        // THE VISUAL: the wisps stop; the cup, saucer and handle stay. Removing the badge outright
        // would be a different lie — the assertions are still held and still block idle sleep.
        let steaming = try badgeInk(plan(50, keepAwake: true))
        let cold = try badgeInk(plan(50, keepAwake: true, interrupted: true))
        XCTAssertGreaterThan(cold.count, 0, "the cup still draws — the session IS still held")
        XCTAssertLessThan(cold.count, steaming.count, "strictly less ink: the wisps are gone")
        XCTAssertTrue(cold.pixels.isSubset(of: steaming.pixels),
                      "the cold cup is the steaming cup MINUS the wisps — nothing new is drawn, nothing moves")
        XCTAssertGreaterThan(cold.topRow, steaming.topRow,
                             "the highest ink drops to the cup: nothing is drawn above it any more")
    }

    func testInterruptedDrawsIdenticallyAtEveryAnimationPhase() throws {
        // "the steam animation is off": the drift timer is disarmed app-side, and the RENDERER agrees —
        // a cold cup has nothing that can animate, so every phase of the drift cycle is the same image.
        let base = MenuBarBatteryIcon.draw(plan(50, keepAwake: true, interrupted: true), steamPhase: 0).tiffRepresentation
        for phase: CGFloat in [0.1, 0.25, 0.5, 0.75, 0.99] {
            XCTAssertEqual(MenuBarBatteryIcon.draw(plan(50, keepAwake: true, interrupted: true),
                                                   steamPhase: phase).tiffRepresentation, base,
                           "interrupted badge must be phase-invariant (phase \(phase))")
        }
        // control: an UNBROKEN session genuinely does animate, so the assertion above has teeth
        XCTAssertNotEqual(MenuBarBatteryIcon.draw(plan(50, keepAwake: true), steamPhase: 0.5).tiffRepresentation,
                          MenuBarBatteryIcon.draw(plan(50, keepAwake: true), steamPhase: 0).tiffRepresentation)
    }

    func testInterruptionNeverChangesTheCanvasWidth() {
        // The width invariant is load-bearing: the canvas widens by EXACTLY the badge while a session is
        // on, and by nothing else — a width change would shove every menu-bar item to the left.
        let on = MenuBarBatteryIcon.draw(plan(50, keepAwake: true)).size
        let cold = MenuBarBatteryIcon.draw(plan(50, keepAwake: true, interrupted: true)).size
        XCTAssertEqual(cold.width, on.width, accuracy: 1e-9, "a broken claim never resizes the canvas")
        XCTAssertEqual(cold.height, on.height, accuracy: 1e-9)
        XCTAssertEqual(cold.width,
                       MenuBarBatteryIcon.canvasSize.width + MenuBarBatteryIcon.keepAwakeBadgeGap
                       + MenuBarBatteryIcon.keepAwakeBadgeWidth, accuracy: 1e-9)
    }

    func testInterruptionLeavesTheBatteryPixelsByteIdentical() throws {
        // The battery's own geometry is identical whether keep-awake is on, off, or broken.
        let onImg = MenuBarBatteryIcon.draw(plan(50, keepAwake: true))
        let coldImg = MenuBarBatteryIcon.draw(plan(50, keepAwake: true, interrupted: true))
        let a = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(onImg.tiffRepresentation)))
        let b = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(coldImg.tiffRepresentation)))
        let sx = CGFloat(a.pixelsWide) / onImg.size.width
        for px in 0..<Int(MenuBarBatteryIcon.canvasSize.width * sx) {
            for py in 0..<a.pixelsHigh {
                XCTAssertEqual(a.colorAt(x: px, y: py), b.colorAt(x: px, y: py),
                               "battery pixel (\(px),\(py)) moved with the interruption")
            }
        }
    }

    func testInterruptedWithNoSessionDrawsNothingAtAll() {
        // Defensive: the flag is only ever true alongside a live session, but a stale true must not
        // conjure a badge (nor widen the canvas) when keep-awake is off.
        XCTAssertEqual(MenuBarBatteryIcon.draw(plan(50, keepAwake: false, interrupted: true)).tiffRepresentation,
                       MenuBarBatteryIcon.draw(plan(50, keepAwake: false)).tiffRepresentation)
    }

    func testImageThreadsTheInterruptionToTheRenderer() {
        // the public entry point (what AppDelegate actually calls) must carry the flag end to end
        func img(_ interrupted: Bool) -> Data? {
            MenuBarBatteryIcon.image(soc: 50, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                     onAC: false, lowPower: false, keepAwake: true,
                                     keepAwakeInterrupted: interrupted).tiffRepresentation
        }
        XCTAssertNotEqual(img(true), img(false), "image() must not swallow the interruption")
    }

    // MARK: - retained 4.A SF-Symbols fallback functions (still unit-tested)

    func testSFFallbackBucketBoundaries() {
        let cases: [(Int, Int)] = [(0,0),(12,0),(13,25),(37,25),(38,50),(62,50),(63,75),(87,75),(88,100),(100,100)]
        for (soc, expected) in cases { XCTAssertEqual(MenuBarBatteryIcon.bucketPercent(soc: soc), expected, "\(soc)") }
        XCTAssertEqual(MenuBarBatteryIcon.bucketPercent(soc: -10), 0)
        XCTAssertEqual(MenuBarBatteryIcon.bucketPercent(soc: 999), 100)
    }

    func testSFFallbackVariantAndNames() {
        XCTAssertEqual(MenuBarBatteryIcon.variant(soc: 20, isChargingDisplay: true, fullyCharged: false, onAC: true),
                       .init(bucketPercent: 100, bolt: true))
        XCTAssertEqual(MenuBarBatteryIcon.candidateNames(.init(bucketPercent: 100, bolt: true)),
                       ["battery.100.bolt", "battery.100percent.bolt"])
        let make: (String) -> NSImage? = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        XCTAssertNotNil(MenuBarBatteryIcon.resolve(["battery.50"], make: make))
        XCTAssertNil(MenuBarBatteryIcon.resolve(["bogus.symbol.xyz"], make: make))
    }

    // MARK: - #BOLT-TREND (owner ruling 2026-09-09 night)

    func testTrendRiseLightsTheSameBoltAsTheFlag() {
        let p = MenuBarBatteryIcon.render(soc: 28, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                          onAC: true, lowPower: false, keepAwake: false, packRising: true)
        XCTAssertTrue(p.bolt); XCTAssertFalse(p.shortfall); XCTAssertEqual(p.colorMode, .template)
        XCTAssertTrue(MenuBarBatteryIcon.draw(p).isTemplate)
    }

    func testDrainingOnACWithNoRiseIsTheOrangeShortfallBolt() {
        let p = MenuBarBatteryIcon.render(soc: 28, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                          onAC: true, lowPower: false, keepAwake: false, packDraining: true)
        XCTAssertTrue(p.bolt); XCTAssertTrue(p.shortfall)
        XCTAssertFalse(MenuBarBatteryIcon.draw(p).isTemplate, "a coloured bolt cannot be a template image")
    }

    func testShortfallDoesNotSuppressRed() {
        let p = MenuBarBatteryIcon.render(soc: 15, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                          onAC: true, lowPower: false, keepAwake: false, packDraining: true)
        XCTAssertEqual(p.colorMode, .redAlert); XCTAssertTrue(p.shortfall)
    }

    func testFlagOrRiseBeatsShortfall() {
        let p = MenuBarBatteryIcon.render(soc: 28, isChargingDisplay: true, holdMark: false, fullyCharged: false,
                                          onAC: true, lowPower: false, keepAwake: false, packRising: true, packDraining: true)
        XCTAssertTrue(p.bolt); XCTAssertFalse(p.shortfall)
    }

    func testHoldMarkBeatsBothTrendInputs() {
        let p = MenuBarBatteryIcon.render(soc: 80, isChargingDisplay: false, holdMark: true, fullyCharged: false,
                                          onAC: true, lowPower: false, keepAwake: false, packRising: true, packDraining: true)
        XCTAssertTrue(p.holdMark); XCTAssertFalse(p.bolt); XCTAssertFalse(p.shortfall)
    }

    func testOnBatteryNeverShortfallOrTrendBolt() {
        let p = MenuBarBatteryIcon.render(soc: 28, isChargingDisplay: false, holdMark: false, fullyCharged: false,
                                          onAC: false, lowPower: false, keepAwake: false, packRising: true, packDraining: true)
        XCTAssertFalse(p.bolt); XCTAssertFalse(p.shortfall)
    }
}
