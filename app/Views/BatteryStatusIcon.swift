import AppKit

/// Custom-drawn, native-style menu-bar battery glyph: an outline + a charge-proportional fill,
/// with a lightning-bolt knockout when charging. Returned as a **template** image (monochrome →
/// the menu bar tints it for light/dark).
///
/// Custom-draw is used because on macOS 26 the battery SF Symbols (`battery.100` /
/// `battery.100percent`) **ignore `variableValue`** — they render no partial fill (confirmed
/// on-device). This guarantees the continuous "like native" fill WI-A.2 requires.
enum BatteryStatusIcon {

    /// `fraction` is the live charge in `0...1`. Returns a menu-bar-sized template image.
    static func image(fraction: Double, isCharging: Bool) -> NSImage {
        let f = CGFloat(min(max(fraction, 0), 1))
        let size = NSSize(width: 27, height: 14)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Battery body outline.
            let body = NSRect(x: 0.75, y: 1.0, width: 22.5, height: 12.0)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.0, yRadius: 3.0)
            outline.lineWidth = 1.2
            outline.stroke()

            // Positive terminal nub.
            NSBezierPath(roundedRect: NSRect(x: 24.0, y: 4.5, width: 1.9, height: 5.0),
                         xRadius: 0.8, yRadius: 0.8).fill()

            // Charge-proportional fill bar.
            let inner = body.insetBy(dx: 2.2, dy: 2.2)
            let fillWidth = inner.width * f
            if fillWidth > 0.5 {
                NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                                 width: fillWidth, height: inner.height),
                             xRadius: 1.4, yRadius: 1.4).fill()
            }

            // Charging indicator: a solid bolt with a cleared moat so it reads over the fill.
            if isCharging, let ctx = NSGraphicsContext.current {
                let bolt = boltPath(in: body)
                ctx.compositingOperation = .destinationOut
                bolt.lineWidth = 2.2
                bolt.stroke()                 // clear a moat around the bolt
                ctx.compositingOperation = .sourceOver
                bolt.fill()                   // solid bolt
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A small downward lightning bolt centered in the battery body.
    private static func boltPath(in body: NSRect) -> NSBezierPath {
        let bw = body.width * 0.26, bh = body.height * 0.80
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
}
