#!/usr/bin/env swift
// gen-appicon.swift — #29 R5: renders AppIcon.appiconset PNGs from the owner-approved
// ring-identity geometry (knowledge/29-phase2-mockup-appicon.html is the source of truth).
//
// The mockup SVG IS the spec; this reproduces its geometry in Core Graphics (no SVG
// rasterizer on the box) so the icon is reproducible from the geometry, not a hand PNG.
//
// The per-size ladder BINDS (mockup "Size discipline"):
//   1024/512/256/128 : full art (track + 288° arc + battery body + cap), master strokes
//   64               : full art, strokes nudged up
//   32               : SIMPLIFIED — drop the track, thicken the arc, drop the cap
//   16               : ring only — the 288° arc alone (body vanishes to mush < ~24px)
//
// The colors are the icon's OWN fixed marks — they do NOT track the app's semantic
// tokens or accent (an icon is a fixed mark). Run:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     xcrun swift scripts/gen-appicon.swift <output-dir>
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ---- palette (fixed icon marks, from the mockup) ----
func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}
let gradTop   = rgb(0x2b, 0x2f, 0x34)   // radial highlight  #2b2f34
let gradBot   = rgb(0x17, 0x19, 0x1c)   // radial base       #17191c
let trackCol  = rgb(0x3a, 0x3e, 0x44)   // --track           #3a3e44
let ringCol   = rgb(0x30, 0xd1, 0x58)   // --ring green      #30d158
let markCol   = rgb(0xf2, 0xf3, 0xf5)   // battery near-white #f2f3f5

// ---- SEGMENTED CELL (owner pick 2026-09-08, "variation 1 · original") ----
// Four segments, each a vertical two-stop gradient, running red -> teal left to right: the cell
// reads as a charge scale, not just a battery. Replaces the ring identity above (kept in the file
// because the ladder's small rungs still borrow its simplification discipline).
let segStops: [(CGColor, CGColor)] = [
    (rgb(0xff, 0x3b, 0x30), rgb(0xff, 0x95, 0x00)),   // red   -> orange
    (rgb(0xff, 0x95, 0x00), rgb(0xff, 0xcc, 0x00)),   // orange-> yellow
    (rgb(0xff, 0xcc, 0x00), rgb(0x34, 0xc7, 0x59)),   // yellow-> green
    (rgb(0x34, 0xc7, 0x59), rgb(0x00, 0xc7, 0xbe)),   // green -> teal
]

// ---- one rung of the binding ladder ----
struct Rung {
    var ringR: CGFloat          // arc/track radius (320-space)
    var ringStroke: CGFloat     // arc/track stroke width
    var track: Bool             // draw the full track circle behind the arc?
    var body: CGRect?           // battery body rect (nil = omit), 320-space (y in SVG/top-down)
    var bodyStroke: CGFloat
    var cap: CGRect?            // battery cap rect (nil = omit), 320-space
}

// master full art (1024/512/256/128) — mockup master SVG
let master = Rung(ringR: 100, ringStroke: 28, track: true,
                  body: CGRect(x: 118, y: 136, width: 70, height: 48), bodyStroke: 10,
                  cap: CGRect(x: 194, y: 150, width: 12, height: 20))
// 64 — full art, strokes nudged up (mockup "64" figure)
let rung64 = Rung(ringR: 100, ringStroke: 30, track: true,
                  body: CGRect(x: 116, y: 134, width: 74, height: 52), bodyStroke: 12,
                  cap: CGRect(x: 198, y: 150, width: 13, height: 21))
// 32 — simplified: no track, thick arc, body only, no cap (mockup "32 (simplified)")
let rung32 = Rung(ringR: 98, ringStroke: 40, track: false,
                  body: CGRect(x: 112, y: 130, width: 82, height: 60), bodyStroke: 16,
                  cap: nil)
// 16 — ring only (mockup "16 (ring only)")
let rung16 = Rung(ringR: 96, ringStroke: 52, track: false,
                  body: nil, bodyStroke: 0, cap: nil)

// pixel size -> rung (each native pixel size rendered from its matching ladder rung)
func rung(for px: Int) -> Rung {
    switch px {
    case 16:  return rung16
    case 32:  return rung32
    case 64:  return rung64
    default:  return master   // 128/256/512/1024
    }
}

func render(_ px: Int, to url: URL) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("ctx \(px)")
    }
    let S = CGFloat(px)
    let k = S / 320                      // 320-space -> pixels
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // ---- rounded-rect tile clip + radial gradient (light from top-left) ----
    let corner = 0.2237 * S              // mockup border-radius: 22.37%
    let tile = CGRect(x: 0, y: 0, width: S, height: S)
    let clip = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(clip); ctx.clip()
    // radial-gradient(120% 120% at 30% 20% ...): center 30% from left, 20% from TOP (y-up: 0.8H)
    let grad = CGGradient(colorsSpace: cs, colors: [gradTop, gradBot, gradBot] as CFArray,
                          locations: [0.0, 0.7, 1.0])!
    let center = CGPoint(x: 0.30 * S, y: 0.80 * S)
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: 1.20 * S,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // subtle inset top highlight (mockup: inset 0 1px 0 rgba(255,255,255,.06))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.setLineWidth(max(1, S/256))
    let inset = CGRect(x: 0.5, y: 0.5, width: S-1, height: S-1)
    ctx.addPath(CGPath(roundedRect: inset, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    // ---- segmented cell (320-space, scaled by k) ----
    // Ladder discipline is unchanged in spirit: fewer, fatter parts as the tile shrinks, because a
    // four-segment comb comes apart below ~32px.
    //   1024/512/256/128 : outline + nub + 4 segments
    //   64               : outline + nub + 4 segments, thicker outline
    //   32               : outline + nub + 3 segments (a 4-comb greys out)
    //   16               : SOLID cell, no segments, no nub — silhouette only
    let segCount: Int   = px <= 16 ? 0 : (px <= 32 ? 3 : 4)
    let showNub: Bool   = px > 16
    let outlineW: CGFloat = px <= 32 ? 22 : (px <= 64 ? 17 : 13)

    // body: centred, 200 x 118 in 320-space (~63% of the tile wide)
    let bodyW: CGFloat = 200, bodyH: CGFloat = 118
    let bodyX = (320 - bodyW) / 2 - 8            // shifted left to leave room for the nub
    let bodyY = (320 - bodyH) / 2
    let bodyR: CGFloat = 30
    let body = CGRect(x: bodyX*k, y: bodyY*k, width: bodyW*k, height: bodyH*k)

    if px <= 16 {
        // solid silhouette — anything hollow disappears at this size
        ctx.setFillColor(markCol)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: bodyR*k, cornerHeight: bodyR*k, transform: nil))
        ctx.fillPath()
    } else {
        ctx.setStrokeColor(markCol); ctx.setLineWidth(outlineW * k)
        let inset = body.insetBy(dx: outlineW*k/2, dy: outlineW*k/2)
        ctx.addPath(CGPath(roundedRect: inset, cornerWidth: bodyR*k, cornerHeight: bodyR*k, transform: nil))
        ctx.strokePath()
    }

    if showNub {
        let nub = CGRect(x: (bodyX + bodyW + 10)*k, y: (160 - 21)*k, width: 15*k, height: 42*k)
        ctx.setFillColor(markCol)
        ctx.addPath(CGPath(roundedRect: nub, cornerWidth: 7.5*k, cornerHeight: 7.5*k, transform: nil))
        ctx.fillPath()
    }

    if segCount > 0 {
        let pad = (outlineW + 12) * k
        let innerX = body.minX + pad, innerY = body.minY + pad
        let innerW = body.width - pad*2, innerH = body.height - pad*2
        let gap = innerW * 0.07
        let segW = (innerW - gap * CGFloat(segCount - 1)) / CGFloat(segCount)
        // at 3 segments borrow the outermost stops so the scale still runs red -> teal
        let stops = segCount == 4 ? segStops : [segStops[0], segStops[1], segStops[3]]
        for i in 0..<segCount {
            let x = innerX + CGFloat(i) * (segW + gap)
            let rect = CGRect(x: x, y: innerY, width: segW, height: innerH)
            let rr = min(segW * 0.28, 10 * k)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil))
            ctx.clip()
            let g = CGGradient(colorsSpace: cs, colors: [stops[i].1, stops[i].0] as CFArray,
                               locations: [0.0, 1.0])!
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()
        }
    }

    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("png \(px)") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// ---- main ----
let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: gen-appicon.swift <out-dir>\n", stderr); exit(2) }
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let url = outDir.appendingPathComponent("icon_\(px).png")
    render(px, to: url)
    print("wrote icon_\(px).png")
}
