import CoreGraphics

/// #29 D-5 (A1 / F4): pure computation of the HUD panel's top-left anchor point from the status-item
/// button's frame (in screen coordinates) and the screen it lives on. Degrades gracefully — a missing,
/// zero-size, non-finite, or off-screen button frame falls back to the screen's top-trailing corner,
/// NEVER (0,0). Kept pure so the anchor + fallback are unit-testable host-app-free (F4: naive anchoring
/// fails on auto-hidden menu bars / multi-display; the graceful helper is the remedy).
enum StatusItemAnchor {
    /// The panel's top-LEFT point (for `NSWindow.setFrameTopLeftPoint`), CENTERED under the status item's
    /// center-x and just below it. (Right-aligning the wide pill to the item's right edge left its body
    /// sitting several items to the left — the owner's placement finding; centering puts the item in the
    /// middle of the pill.) Falls back to the screen's top-trailing corner when the button frame is unusable.
    static func topLeft(buttonFrame: CGRect?, screenFrame: CGRect,
                        panelSize: CGSize, gap: CGFloat = 6) -> CGPoint {
        func fallback() -> CGPoint {
            CGPoint(x: screenFrame.maxX - panelSize.width - gap, y: screenFrame.maxY - gap)
        }
        guard let b = buttonFrame,
              b.width > 0, b.height > 0,
              b.minX.isFinite, b.minY.isFinite, b.maxX.isFinite, b.maxY.isFinite,
              screenFrame.intersects(b) else { return fallback() }

        var x = b.midX - panelSize.width / 2   // center the pill under the status item's center-x
        var y = b.minY - gap                   // top just below the button (the menu-bar underside)
        // Clamp fully inside the screen — never off-screen, never negative-into-(0,0).
        x = min(max(x, screenFrame.minX), screenFrame.maxX - panelSize.width)
        y = min(max(y, screenFrame.minY + panelSize.height), screenFrame.maxY)
        let p = CGPoint(x: x, y: y)
        return (p.x == 0 && p.y == 0) ? fallback() : p
    }
}
