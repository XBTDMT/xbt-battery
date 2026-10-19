import AppKit

/// Sprint 4.B (SPEC `02-SPEC-phase-4b-native-glyph.md`): the menu-bar battery glyph, route (b) —
/// **custom-drawn to Apple's native geometry with CONTINUOUS fill**. Supersedes 4.A's discrete
/// SF-Symbols renderer (which survives here as the secondary fallback). The 4.A selection
/// architecture carries over: bolt source = the TRUTH pipeline (caller passes it), never-blank
/// discipline, and a pure decision layer tested exhaustively.
///
/// **Geometry — measured from Apple's `battery.100` SF Symbol (2026-06-10, 240pt render =
/// 407×201 px):** body 309×159 (0.759·W × 0.791·H), stroke 19 (0.094·H), fill inset 14 (0.070·H),
/// nub gap 17 / width 22 (0.042·W / 0.054·W), L/R pad 30 (0.074·W), aspect 2.025:1. Kept as
/// canvas fractions so it scales at @1x/@2x with no per-scale code.
enum MenuBarBatteryIcon {

    // MARK: - decision layer (pure; SPEC sec 3)

    enum ColorMode: Equatable {
        case template   // isTemplate=true — AppKit tints (every normal state)
        case redAlert   // isTemplate=false — system-red fill for low battery
        case lowPower   // isTemplate=false — system-yellow fill for Low Power Mode (#2-glyph)
        /// isTemplate=false — system-green FILL with the interior mark drawn SOLID WHITE on top
        /// (option 5, owner pick 2026-09-08). Fires at "at your target": full-on-AC, or a verified
        /// limit hold. White rather than a knockout so the mark reads identically in light and dark —
        /// a knockout shows the menu bar through it, which is near-white in light and dark grey in dark.
        case chargedGreen
    }

    struct RenderPlan: Equatable {
        let fillFraction: Double   // 0…1 continuous (no buckets)
        let bolt: Bool
        let holdMark: Bool         // #26 (4.E): two pause-bars knocked out of the fill at a limit hold
        let colorMode: ColorMode
        let keepAwake: Bool        // #EI-1: our OWN keep-awake assertion is active — an additive overlay,
                                   // INDEPENDENT of colorMode and of the bolt/holdMark precedence.
        /// #EI-1 HONESTY: the session is STILL held, but the Mac slept through it at least once
        /// (`KeepAwakeController.isInterrupted`, backed by `Session.sleepInterruptions`). Our
        /// assertions are idle-sleep only — IOPMLib.h:286 — so a lid close / Apple-menu Sleep
        /// falsifies the "won't sleep" claim while the session object survives. Independent of
        /// every battery input, exactly like `keepAwake`; it changes ONLY the badge's steam.
        let keepAwakeInterrupted: Bool
        /// #BOLT-TREND (owner ruling 2026-09-09 night): the adapter is attached but covers LESS than the
        /// Mac is using — the pack is draining on AC. The bolt is drawn SOLID ORANGE (the one colour slot
        /// free of red / yellow / green). Never true together with a charging `bolt`.
        var shortfall: Bool = false
    }

    /// #26 (4.E): the hold indicator shows ONLY at a verified `.limitHold` — never `.ambiguousHold`
    /// (we don't claim a hold we can't verify; the popover carries ambiguity). Sourced from TRUTH,
    /// so it needs no veto (unlike the intent-flag bolt). nil state (monitoring-only) → no mark.
    static func holdMarkOn(state: TelemetryChargeState?) -> Bool { state == .limitHold }

    /// Bolt v2 (4.E sec 2 / the 4.D ruling): the bolt lights on the IOPS charging INTENT flag
    /// (`kIOPSIsChargingKey`, native-instant) but is VETOED wherever intent-flags lie — at
    /// `.limitHold`, `.ambiguousHold`, `.idleInhibit` the (now event-fast) classifier suppresses it
    /// within seconds. Monitoring-only mode (<26.4, nil state) = flag alone, matching native exactly.
    /// The flag feeds ONLY the bolt; the audited state machine never sees it.
    static func boltOn(isChargingFlag: Bool, state: TelemetryChargeState?) -> Bool {
        guard let state else { return isChargingFlag }   // monitoring-only: flag alone
        switch state {
        case .limitHold, .ambiguousHold, .idleInhibit: return false   // truth veto
        case .charging, .discharging, .unknown:        return isChargingFlag
        }
    }

    /// (soc, isChargingDisplay, holdMark, fullyCharged, onAC, lowPower) → RenderPlan. Pure, total.
    /// Precedence: #21 full-on-AC → full fill, no bolt, no holdMark (a full battery reads as
    /// "full," not "held below" — see hand-back flag) and #21b's plug mark, so full-on-AC is no
    /// longer pixel-identical to full-on-battery; else continuous fill. Bolt and holdMark are
    /// mutually exclusive: the hold mark (truth) suppresses the bolt (intent). red iff
    /// `soc <= 20 AND not bolt` (note 1: warn earlier; charging suppresses red).
    ///
    /// COLOR ladder (#2-glyph): RED (critical, !charging) > YELLOW (Low Power Mode) > TEMPLATE. Yellow
    /// is NOT suppressed by charging (a bolt knockout cuts through the yellow fill, color-independent);
    /// red IS suppressed by charging (existing). lowPower comes from snapshot.energyMode == .low only —
    /// .high / .automatic / .unavailable are never yellow. SHAPE logic is unchanged by lowPower.
    ///
    /// #BOLT-TREND (owner ruling 2026-09-09 night): `packRising` = the `PackTrend` verdict is `.rising`
    /// (the % stepped up within the window) — it lights the SAME bolt as the flag, because the flag is
    /// off for ~98 % of a real climb on macOS 27 (see `PackTrend`). `packDraining` = on AC with the sampled
    /// pack current at or below −350 mA (the classifier's flow threshold): with no bolt from either flag
    /// or trend, that is "power in < draw" → the orange `shortfall` bolt. Hold mark still wins over both.
    static func render(soc: Int, isChargingDisplay: Bool, holdMark: Bool,
                       fullyCharged: Bool, onAC: Bool, lowPower: Bool, keepAwake: Bool,
                       keepAwakeInterrupted: Bool = false,
                       packRising: Bool = false, packDraining: Bool = false) -> RenderPlan {
        if fullyCharged && onAC {
            // Owner ruling 2026-09-08: full-on-AC keeps the SAME bolt as charging; the only difference
            // is the GREEN fill behind it. One shape, colour carries the state — which retires #21b's
            // plug mark entirely. Noted for the record: the bolt conventionally means "current is
            // flowing", and at 100% it is not; green is what says "done", the bolt now reads as
            // "connected". Deliberate, owner-approved, and distinct from the hold state, which still
            // has its own pause-bar shape.
            return RenderPlan(fillFraction: 1.0, bolt: true, holdMark: false,
                              colorMode: lowPower ? .lowPower : .chargedGreen,
                              keepAwake: keepAwake,   // #EI-1: pure pass-through; battery semantics untouched
                              keepAwakeInterrupted: keepAwakeInterrupted)
        }
        let fill = min(max(Double(soc) / 100.0, 0.0), 1.0)   // continuous + clamped
        let showBolt = (isChargingDisplay || (onAC && packRising)) && !holdMark   // hold (truth) wins over bolt (intent/trend)
        let shortfall = onAC && !showBolt && !holdMark && packDraining             // #BOLT-TREND: plugged in, still losing
        let red = BatteryRedRule.isLow(soc) && !showBolt                     // note 1: warn earlier; charging suppresses red (a shortfall does NOT)
        // RED > YELLOW > GREEN(hold) > TEMPLATE. Green sits below yellow: a limit hold in Low Power
        // Mode still reads yellow, because LPM is a system state the user needs to see and the hold is
        // already carried by the mark's shape. Charging is deliberately NOT coloured (owner, 2026-09-08).
        let color: ColorMode = red ? .redAlert
            : (lowPower ? .lowPower : (holdMark ? .chargedGreen : .template))
        return RenderPlan(fillFraction: fill, bolt: showBolt || shortfall, holdMark: holdMark,
                          colorMode: color,
                          keepAwake: keepAwake,   // #EI-1: pure pass-through; battery semantics untouched
                          keepAwakeInterrupted: keepAwakeInterrupted,
                          shortfall: shortfall)
    }

    // MARK: - geometry (native fractions)

    /// Canonical canvas — aspect 2.0, status-bar height. AppKit scales the template to fit.
    static let canvasSize = NSSize(width: 28, height: 14)

    /// #EI-1 side badge: the keep-awake espresso cup lives to the RIGHT of the battery. These are the extra
    /// canvas it adds — a gap clearing the terminal nub, plus the badge's own width — applied ONLY while a
    /// keep-awake session is active. (Owner-tuned at the gate, like the bolt/hold-mark geometry.)
    static let keepAwakeBadgeWidth: CGFloat = 11
    static let keepAwakeBadgeGap: CGFloat = 1.5

    private enum G {   // fractions of the canvas (W,H). Native ratios, then eyeball-tuned at
                       // status-bar scale against Apple's symbol (stroke lightened, corners
                       // tightened) — recorded in the 4.B hand-back.
        static let bodyX = 0.074, bodyW = 0.759
        static let bodyTopPad = 0.1045, bodyH = 0.791
        static let stroke = 0.072           // × H  (~1.0 pt @ H=14)
        static let outerRadius = 0.23       // × bodyH
        static let fillPad = 0.0697         // × H, inside the inner wall
        static let fillRadius = 0.22        // × inner height
        static let nubGap = 0.0418, nubW = 0.0541   // × W
        static let nubH = 0.45              // × bodyH
    }

    // MARK: - custom drawing (primary)

    /// Draw the native-geometry glyph for a plan. Returns an image whose `isTemplate` matches the
    /// color mode. (`flipped:false` → standard AppKit coords.)
    static func draw(_ plan: RenderPlan, size: NSSize = canvasSize, steamPhase: CGFloat = 0) -> NSImage {
        // #EI-1 (side badge): the keep-awake espresso cup sits to the RIGHT of the battery, OUTSIDE the body,
        // so the image grows by exactly the badge ONLY while a session is active — the battery's own geometry
        // (drawn at `batteryW`, left of the badge) is byte-for-byte identical whether keep-awake is on or off.
        let batteryW = size.width, H = size.height
        let extra: CGFloat = plan.keepAwake ? keepAwakeBadgeGap + keepAwakeBadgeWidth : 0
        let image = NSImage(size: NSSize(width: batteryW + extra, height: H), flipped: false) { _ in
            let W = batteryW
            // COLOR channel: .template tints via AppKit (.black + isTemplate); the non-template alerts
            // draw an explicit visible stroke + a colored fill. .lowPower mirrors .redAlert (yellow).
            let strokeColor: NSColor
            let fillColor: NSColor
            switch plan.colorMode {
            // #BOLT-TREND: a shortfall bolt is a colour, so the image cannot be a template; the body keeps
            // its label-colour look (what the template tints to) and only the bolt goes orange.
            case .template: strokeColor = plan.shortfall ? .labelColor : .black
                            fillColor   = plan.shortfall ? .labelColor : .black
            case .redAlert: strokeColor = .labelColor; fillColor = .systemRed
            case .lowPower: strokeColor = .labelColor; fillColor = .systemYellow
            // "At your target": green FILL, like red/yellow. The interior mark is drawn white on top
            // (see the mark passes below) rather than knocked out.
            case .chargedGreen: strokeColor = .labelColor; fillColor = .systemGreen
            }

            let stroke = G.stroke * H
            let body = NSRect(x: G.bodyX * W, y: G.bodyTopPad * H,
                              width: G.bodyW * W, height: G.bodyH * H)
            let outerR = G.outerRadius * body.height

            // Body outline (stroke stays INSIDE the body rect → inset by half the line width).
            strokeColor.setStroke()
            let outline = NSBezierPath(roundedRect: body.insetBy(dx: stroke / 2, dy: stroke / 2),
                                       xRadius: outerR, yRadius: outerR)
            outline.lineWidth = stroke
            outline.stroke()

            // Terminal nub (same color as the outline).
            strokeColor.setFill()
            let nubW = G.nubW * W, nubH = G.nubH * body.height
            let nub = NSRect(x: body.maxX + G.nubGap * W, y: body.midY - nubH / 2,
                             width: nubW, height: nubH)
            NSBezierPath(roundedRect: nub, xRadius: nubW * 0.4, yRadius: nubW * 0.4).fill()

            // Continuous fill bar, inset inside the inner wall. The fill is the HONEST SoC width (note 3).
            let inset = stroke / 2 + G.fillPad * H
            let inner = body.insetBy(dx: inset, dy: inset)
            let fr = fillRect(inner: inner, body: body, socFraction: plan.fillFraction, holdMark: plan.holdMark)
            let r = inner.height * G.fillRadius
            if fr.width > 0.3 {
                fillColor.setFill()
                NSBezierPath(roundedRect: fr, xRadius: r, yRadius: r).fill()
            }

            // Note 3: SPLIT-DRAW the bolt so it reads at ANY fill level (native style), which is what lets
            // the fill stay honest. Where the bolt overlaps the filled bar it is a destinationOut knockout
            // (an empty-colored bolt cut into the fill); where it overlaps the empty body it is a POSITIVE
            // mark in the foreground color. Clipping each pass to its region tiles them with no gap, so the
            // bolt is one continuous, self-legible shape across the fill line. red+bolt never co-occur (red
            // requires !charging); yellow+bolt can (the colors match either way).
            if plan.shortfall {
                // #BOLT-TREND: solid orange bolt over whatever fill is there (white / yellow / red).
                shortfallBoltColor.setFill()
                boltPath(in: body).fill()
            } else if plan.bolt, plan.colorMode == .chargedGreen {
                // Full-on-AC: the bolt sits SOLID WHITE on the green fill (matching the hold mark's
                // treatment) rather than being knocked through — a knockout shows the menu bar, which
                // reads near-white in light mode and dark grey in dark. White is identical in both.
                NSColor.white.setFill()
                boltPath(in: body).fill()
            } else if plan.bolt, let ctx = NSGraphicsContext.current {
                let bolt = boltPath(in: body)
                NSGraphicsContext.saveGraphicsState()                       // 1) knockout over the fill
                NSBezierPath(rect: fr).addClip()
                ctx.compositingOperation = .destinationOut
                bolt.fill()
                ctx.compositingOperation = .sourceOver
                NSGraphicsContext.restoreGraphicsState()

                let empty = NSRect(x: fr.maxX, y: inner.minY,             // 2) positive over the empty body
                                   width: max(0, inner.maxX - fr.maxX), height: inner.height)
                if empty.width > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: empty).addClip()
                    fillColor.setFill()
                    bolt.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            } else if plan.holdMark, fr.width > 0.3, plan.colorMode == .chargedGreen {
                NSColor.white.setFill()                      // option 5: solid white on the green fill
                holdMarkPath(in: body).fill()
            } else if plan.holdMark, fr.width > 0.3, let ctx = NSGraphicsContext.current {
                // #26 hold mark: a pure destinationOut knockout, unchanged. The hold sits in the fill
                // (fillRect backs the mark), so the knockout always cuts through fill.
                ctx.compositingOperation = .destinationOut
                holdMarkPath(in: body).fill()
                ctx.compositingOperation = .sourceOver
            }

            // #EI-1: keep-awake espresso badge — our OWN sleep assertion is active. ADDITIVE, drawn LAST and
            // INDEPENDENT of the battery-state passes above (fill / bolt / holdMark / color all untouched). It
            // lives OUTSIDE the body to the RIGHT (the image was widened by exactly the badge for it), so unlike
            // the old interior pip it needs no split-draw — a steaming cup reads "staying awake" at a glance.
            // Uses strokeColor so the isTemplate rule stays intact (the badge never forces a non-template image;
            // the normal glyph still inverts/adapts in the menu bar — image.isTemplate is set below, unchanged).
            if plan.keepAwake {
                // #EI-1: the badge reports OUR keep-awake assertion, NOT the battery's condition, so it
                // must never inherit a state colour. It used to borrow `strokeColor`, which was safe
                // while every mode's stroke was .black or .labelColor — but `.chargedGreen` strokes the
                // body green, and the cup went green with it (owner-reported 2026-09-08). Pin it: .black
                // in template mode so AppKit still tints the whole image together, .labelColor in every
                // coloured mode so it stays neutral against the menu bar.
                let badgeInk: NSColor = (plan.colorMode == .template) ? .black : .labelColor
                // #EI-1 HONESTY (owner-reported 2026-09-08): when the Mac has SLEPT THROUGH the session
                // the cup goes COLD — the cup, saucer and handle still draw (the session is still held
                // and still inhibits idle sleep from here on, so removing the badge would be a different
                // lie: "nothing is held"), but the steam, which is what reads as "actively holding",
                // is not drawn at all.
                drawKeepAwakeBadge(in: keepAwakeBadgeRect(batteryWidth: batteryW, height: H),
                                   ink: badgeInk, steamPhase: steamPhase,
                                   steam: !plan.keepAwakeInterrupted)
            }
            return true
        }
        image.isTemplate = (plan.colorMode == .template) && !plan.shortfall
        return image
    }

    /// The shortfall bolt's orange — owner pick 2026-09-10 ("orange is fine"): A, `systemOrange`, from the
    /// four candidates (B amber #ffb340, C tangerine #ff7a1a, D burnt #f0641e).
    static let shortfallBoltColor: NSColor = .systemOrange

    /// The fill rectangle to draw inside `inner`: the HONEST SoC bar (width = inner.width × socFraction).
    /// Note 3: the bolt NO LONGER backs the fill — it is split-drawn in `draw()` (knockout over the fill,
    /// positive over the empty body) so it reads at any fill level, which lets the fill stay honest while
    /// charging. The HOLDMARK still backs the fill (ISSUE-4): a hold sits at or above the native 80%
    /// floor, where the honest fill already covers the centered mark, so the backing is a no-op there and
    /// the knockout never cuts empty body. Clamped to inner.width. Pure + testable.
    static func fillRect(inner: NSRect, body: NSRect, socFraction: Double, holdMark: Bool) -> NSRect {
        var width = inner.width * CGFloat(min(max(socFraction, 0), 1))
        if holdMark {
            let markMaxX = holdMarkPath(in: body).bounds.maxX
            width = max(width, markMaxX - inner.minX)   // back the hold-mark's full horizontal footprint
        }
        width = min(max(width, 0), inner.width)
        return NSRect(x: inner.minX, y: inner.minY, width: width, height: inner.height)
    }

    /// A downward lightning bolt centered in the battery body (carried from the legacy glyph).
    /// #2-glyph: emboldened (wider footprint, `0.32 → 0.42`) so the knockout cut is chunkier + more
    /// legible. `internal` so tests can assert the fill-behind-when-lit invariant against its bounds.
    /// (Final thickness/size = owner visual acceptance — "reads well" needs the owner's eyes.)
    static func boltPath(in body: NSRect) -> NSBezierPath {
        // Owner visual pass 2026-09-08: 0.42 → 0.27 wide, height unchanged at 0.84. A narrower, taller
        // bolt — it reads as a sharper strike rather than a wide wedge, and it leaves more green
        // showing around it in the charged state, which is what now distinguishes charged from charging.
        let bw = body.width * 0.27, bh = body.height * 0.84
        let bx = body.midX - bw / 2, by = body.midY - bh / 2
        let uv: [(CGFloat, CGFloat)] = [
            (0.55, 1.00), (0.08, 0.46), (0.40, 0.46),
            (0.32, 0.00), (0.95, 0.55), (0.60, 0.55),
        ]
        let path = NSBezierPath()
        for (i, c) in uv.enumerated() {
            let pt = NSPoint(x: bx + c.0 * bw, y: by + c.1 * bh)
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.close()
        return path
    }

    /// #26: two vertical pause-bars centered in the body, knocked out of the fill (the bolt's
    /// visual sibling — same destinationOut technique). Geometry mirrors the bolt's footprint.
    /// `internal` so tests can assert the fill-behind-when-held invariant against its bounds (ISSUE-4).
    static func holdMarkPath(in body: NSRect) -> NSBezierPath {
        // ORIGINAL slim geometry, RESTORED per owner visual acceptance — the COMMIT-2 chunkier bars
        // (0.17/0.62/0.13) read too thick at menu-bar scale. SHAPE-channel only (still a knockout, no
        // color). The ISSUE-4 fix is INDEPENDENT and stays: fillRect backs the mark at the hold SOC so
        // the bars don't vanish at low limits — that's geometry-agnostic, so the slim look keeps it.
        // Owner visual pass 2026-09-07: bars 20% narrower (0.12 → 0.096) and the gap tightened
        // (0.11 → 0.045) so the pair reads as a PAUSE rather than two separate bars. At 14pt that is
        // a 2.04pt bar with a 0.96pt gap — a gap:bar ratio of 0.47, inside pause-glyph territory.
        // Below ~0.04 the bars start to merge at menu-bar scale.
        let barW = body.width * 0.096
        let barH = body.height * 0.52
        let gap  = body.width * 0.045
        let y = body.midY - barH / 2
        let leftX  = body.midX - gap / 2 - barW
        let rightX = body.midX + gap / 2
        let r = barW * 0.32
        let path = NSBezierPath()
        path.append(NSBezierPath(roundedRect: NSRect(x: leftX,  y: y, width: barW, height: barH), xRadius: r, yRadius: r))
        path.append(NSBezierPath(roundedRect: NSRect(x: rightX, y: y, width: barW, height: barH), xRadius: r, yRadius: r))
        return path
    }


    /// #EI-1: the keep-awake badge rect — the region to the RIGHT of the battery (outside the body, past the
    /// gap that clears the terminal nub) where the espresso cup is drawn. Being outside the body it can never
    /// collide with the interior bolt/hold marks — a stronger guarantee than the old interior pip. `internal`
    /// so a test asserts the clearance. `batteryWidth` is the battery's own footprint; `height` the canvas H.
    static func keepAwakeBadgeRect(batteryWidth: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: batteryWidth + keepAwakeBadgeGap, y: 0, width: keepAwakeBadgeWidth, height: height)
    }

    /// #EI-1: draw the keep-awake indicator — a small steaming espresso cup on a saucer (owner-accepted
    /// candidate "E2"). A positive fill in `ink` (no knockout: it sits outside the battery body). Pure,
    /// badge-relative geometry so it scales with the canvas. Final size/placement = owner visual acceptance,
    /// exactly like the bolt thickness and the hold-mark geometry ("reads well" needs the owner's eyes at the gate).
    /// `steamPhase` (0…1, wrapping) drifts the two wisps upward and fades them out as they rise —
    /// the owner-picked "drift" treatment. 0 renders the original static cup exactly, so every
    /// non-animating call site is unchanged.
    ///
    /// `steam: false` draws a COLD CUP — cup + saucer + handle, no wisps at all. That is the honest
    /// rendering of an INTERRUPTED session (the Mac slept through it), and it is deliberately a
    /// SHAPE-channel signal:
    ///   • not colour — the owner's standing rule is that this badge never takes a state colour
    ///     (`testKeepAwakeBadgeNeverTakesAStateColour`), and a greyed cup would also read as
    ///     "disabled", which is wrong: the session is still live;
    ///   • not removal — the assertions are still held and still stop idle sleep, so an empty badge
    ///     would swap one lie for another (and it would also re-narrow the canvas, which shifts every
    ///     menu-bar item to its left — a jarring, meaningless jump);
    ///   • not a slash / overlay mark — that reads as "off" or "blocked", and at 14 pt a stroke laid
    ///     across an 11 pt cup is mud;
    ///   • not merely FREEZING the drift (a still frame of steam is indistinguishable from steam at a
    ///     glance — an honesty cue you can only see by watching for motion is not a cue).
    /// A cup with no steam reads, correctly and instantly, as "this went cold while you were away".
    /// The caller also stops the animation timer, so no CPU is spent on a badge with nothing moving.
    static func drawKeepAwakeBadge(in badge: NSRect, ink: NSColor, steamPhase: CGFloat = 0,
                                   steam: Bool = true) {
        // Work box: a touch shorter than the badge; the ink is re-centered within it via yShift below.
        let boxH = min(badge.height, 12.5)
        let b = NSRect(x: badge.minX, y: badge.midY - boxH / 2, width: badge.width, height: boxH)
        ink.setFill(); ink.setStroke()

        let sw = b.width * 0.92, sh = b.height * 0.16     // saucer size
        let cupH = b.height * 0.40, cupW = b.width * 0.52 // cup size
        let cupX = b.minX + (b.width - cupW) * 0.42       // biased left → leaves room for the handle on the right

        // Vertically center the cup+saucer SOLID mass on the badge midline (saucer-at-bottom + rising steam
        // otherwise leave the ink bottom-biased in the box, so the cup looked low), then drop it a hair below
        // center per owner taste ("slightly lower"). `saucerY`/`baseY` fold the shift in; the handle + steam
        // derive from baseY so they follow. `dropBelowCenter` is the sole tuning knob — larger = lower.
        let dropBelowCenter: CGFloat = 1.5
        let yShift = badge.midY - (b.minY + (sh * 0.6 + cupH) / 2) - dropBelowCenter
        let saucerY = b.minY + yShift
        let baseY = b.minY + sh * 0.6 + yShift

        // saucer: a shallow rounded lens under the cup, a little wider than it.
        NSBezierPath(roundedRect: NSRect(x: b.midX - sw / 2, y: saucerY, width: sw, height: sh),
                     xRadius: sh / 2, yRadius: sh / 2).fill()

        // cup: a tapered demitasse (top wider than bottom) with a rounded bottom, sitting on the saucer.
        let taper: CGFloat = 0.10
        let tl = NSPoint(x: cupX, y: baseY + cupH)
        let tr = NSPoint(x: cupX + cupW, y: baseY + cupH)
        let br = NSPoint(x: cupX + cupW * (1 - taper), y: baseY)
        let bl = NSPoint(x: cupX + cupW * taper, y: baseY)
        let cup = NSBezierPath()
        cup.move(to: tl); cup.line(to: tr); cup.line(to: br)
        cup.appendArc(from: bl, to: NSPoint(x: tl.x, y: tl.y - cupW * 0.16), radius: cupW * 0.16)
        cup.line(to: tl); cup.close(); cup.fill()

        // handle: a small C-ring on the right (even-odd annulus — the inner hole is knocked out).
        let hd = cupH * 0.72
        let hr = NSRect(x: cupX + cupW - hd * 0.30, y: baseY + cupH * 0.20, width: hd, height: hd)
        let ring = NSBezierPath()
        ring.appendOval(in: hr)
        ring.appendOval(in: hr.insetBy(dx: hd * 0.30, dy: hd * 0.30))
        ring.windingRule = .evenOdd
        ring.fill()

        // steam: two thin wavy wisps rising above the cup — the "hot"/awake cue (a custom flourish; Apple's
        // own cup.and.saucer.fill carries none).
        // DRIFT: each wisp rides its own phase, offset by half a cycle so they alternate rather than
        // pulsing in lockstep. A wisp rises by `driftRise` over its cycle and fades as it goes, so the
        // pair reads as steam leaving the cup. steamPhase == 0 reproduces the original static art.
        // COLD CUP: an interrupted session draws no wisps at all (see the doc comment above).
        guard steam else { return }
        let driftRise = b.height * 0.16
        for (i, dx) in [-cupW * 0.16, cupW * 0.20].enumerated() {
            let phase = steamPhase == 0 ? 0 : (steamPhase + CGFloat(i) * 0.5).truncatingRemainder(dividingBy: 1)
            let rise = driftRise * phase
            // fade in over the first fifth, then out across the rest — never a hard pop at the wrap
            let alpha: CGFloat = steamPhase == 0 ? 1 : (phase < 0.2 ? phase / 0.2 : 1 - (phase - 0.2) / 0.8)
            let x0 = cupX + cupW * 0.5 + dx, y0 = baseY + cupH + b.height * 0.04 + rise
            let s = NSBezierPath()
            s.move(to: NSPoint(x: x0, y: y0))
            s.curve(to: NSPoint(x: x0, y: y0 + b.height * 0.24),
                    controlPoint1: NSPoint(x: x0 - cupW * 0.14, y: y0 + b.height * 0.08),
                    controlPoint2: NSPoint(x: x0 + cupW * 0.14, y: y0 + b.height * 0.16))
            s.lineWidth = max(0.7, b.width * 0.05); s.lineCapStyle = .round
            ink.withAlphaComponent(max(0, min(1, alpha))).setStroke()
            s.stroke()
        }
        ink.setStroke()   // restore for any later drawing
    }

    // MARK: - public image with the fallback chain (custom → 4.A SF Symbols → legacy; never blank)

    static func image(soc: Int, isChargingDisplay: Bool, holdMark: Bool, fullyCharged: Bool, onAC: Bool,
                      lowPower: Bool, keepAwake: Bool = false, keepAwakeInterrupted: Bool = false,
                      style: GlyphStyle = .nativeContinuous,
                      packRising: Bool = false, packDraining: Bool = false,
                      make: (String) -> NSImage? = { NSImage(systemSymbolName: $0, accessibilityDescription: "Battery") },
                      legacy: (Double, Bool) -> NSImage = BatteryStatusIcon.image,
                      steamPhase: CGFloat = 0,
                      logOnce: () -> Void = MenuBarBatteryIcon.logFallbackOnce) -> NSImage {
        let plan = render(soc: soc, isChargingDisplay: isChargingDisplay, holdMark: holdMark,
                          fullyCharged: fullyCharged, onAC: onAC, lowPower: lowPower, keepAwake: keepAwake,
                          keepAwakeInterrupted: keepAwakeInterrupted,
                          packRising: packRising, packDraining: packDraining)

        // Feature #13: the user chose Apple's SF-Symbols family — render it DIRECTLY as the primary
        // (monochrome template; no hold/keep-awake marks or red/yellow — the fidelity gap is DISCLOSED in
        // Settings, §5, not hidden). Falls through to the custom/legacy chain if the symbol is unavailable.
        if style == .sfSymbols {
            let v = variant(soc: soc, isChargingDisplay: isChargingDisplay, fullyCharged: fullyCharged, onAC: onAC)
            if let symbol = resolve(candidateNames(v), make: make) { symbol.isTemplate = true; return symbol }
            // fall through to custom/legacy if the symbol is unavailable (never blank)
        }

        // Primary: custom native-geometry drawing.
        let drawn = draw(plan, steamPhase: steamPhase)
        if drawn.isValid, drawn.size.width > 0 { return drawn }

        // Secondary (4.A): the SF-Symbols family.
        logOnce()
        let v = variant(soc: soc, isChargingDisplay: isChargingDisplay,
                        fullyCharged: fullyCharged, onAC: onAC)
        if let symbol = resolve(candidateNames(v), make: make) {
            symbol.isTemplate = (plan.colorMode == .template)
            return symbol
        }

        // Tertiary: the legacy custom glyph. Never blank.
        return legacy(min(max(Double(soc), 0), 100) / 100.0, isChargingDisplay)
    }

    // MARK: - 4.A SF-Symbols path (DEMOTED to secondary fallback; still unit-tested)

    struct Variant: Equatable { let bucketPercent: Int; let bolt: Bool }

    static func bucketPercent(soc: Int) -> Int {
        switch min(max(soc, 0), 100) {
        case 0...12:  return 0
        case 13...37: return 25
        case 38...62: return 50
        case 63...87: return 75
        default:      return 100
        }
    }

    static func variant(soc: Int, isChargingDisplay: Bool, fullyCharged: Bool, onAC: Bool) -> Variant {
        if fullyCharged && onAC { return Variant(bucketPercent: 100, bolt: false) }
        if isChargingDisplay    { return Variant(bucketPercent: 100, bolt: true) }   // only battery.100.bolt exists
        return Variant(bucketPercent: bucketPercent(soc: soc), bolt: false)
    }

    static func candidateNames(_ v: Variant) -> [String] {
        if v.bolt { return ["battery.100.bolt", "battery.100percent.bolt"] }
        return ["battery.\(v.bucketPercent)", "battery.\(v.bucketPercent)percent"]
    }

    static func resolve(_ names: [String], make: (String) -> NSImage?) -> NSImage? {
        for name in names { if let image = make(name) { return image } }
        return nil
    }

    // One-shot fallback log. Only touched on the @MainActor UI path.
    nonisolated(unsafe) private static var didLogFallback = false
    static func logFallbackOnce() {
        guard !didLogFallback else { return }
        didLogFallback = true
        NSLog("battery_app: custom battery glyph unavailable — falling back to the SF-Symbols/legacy chain")
    }
}
