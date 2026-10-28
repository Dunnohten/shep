import CoreGraphics
import Foundation

/// The overlay panel is bigger than the tab so the speech bubble and input pill are never clipped. Everything outside
/// the tab (and the bubble, while one is showing) is transparent and click-through. Pure geometry, Cocoa coordinates
/// (bottom-left origin) for frames; the `...InPanel` rectangles are in web coordinates (top-left origin) for the page.
public struct PanelLayout: Equatable {
    public var panelFrame: CGRect
    /// The tab this layout was built for (Cocoa coordinates).
    public var tab: TabLayout
    /// The dog's rectangle inside the panel, top-left origin (what the page positions the dog with).
    public var dogInPanel: CGRect
    /// The tab's rectangle inside the panel, top-left origin (where the native tab shape is drawn).
    public var tabInPanel: CGRect
    /// True when the bubble sits below the title bar (the normal case); false when there was no room and it sits above the tab.
    public var bubbleBelow: Bool
    /// Screen-space (Cocoa) rectangle of the bubble/pill area.
    public var bubbleFrame: CGRect

    /// The web view fills the whole panel: its frame in the panel's own space (the CSS viewport the page sees).
    public var webViewFrame: CGRect { CGRect(origin: .zero, size: panelFrame.size) }

    /// One line for the dock-time log: tab rect, panel frame, web view frame and the dog's rectangle in the panel.
    public var logDescription: String {
        func r(_ f: CGRect) -> String { "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))" }
        let head = TabGeometry.renderedHead(in: dogInPanel)
        return "tab=\(r(tab.rect)) \(tab.style == .above ? "above" : "inside") panel=\(r(panelFrame)) webview=\(r(webViewFrame)) "
            + "dog=\(r(dogInPanel)) head=\(Int(head.width.rounded()))x\(Int(head.height.rounded())) "
            + "dogOnScreen=\(r(PanelGeometry.dogScreenRect(self))) dogInTab=\(PanelGeometry.dogIsInsideTab(self) ? "yes" : "NO")"
    }
}

public enum PanelGeometry {
    public static let panelWidth: CGFloat = 320
    public static let bubbleHeight: CGFloat = 150
    public static let gap: CGFloat = 4
    /// Transparent room above the tab, so the head can peek (and spring) above the tab body without being clipped.
    public static let headroom: CGFloat = 12

    /// Size of a panel with the bubble below: the tab, the title bar band under it, and the bubble.
    public static var defaultSize: CGSize {
        CGSize(width: panelWidth, height: headroom + TabGeometry.height + DockGeometry.titleBarHeight + gap + bubbleHeight)
    }

    /// - Parameters:
    ///   - tab: the tab from TabGeometry.
    ///   - screens: every screen's full frame, Cocoa coordinates.
    public static func layout(tab: TabLayout, screens: [CGRect]) -> PanelLayout {
        let t = tab.rect
        let screen = screens.first(where: { $0.contains(CGPoint(x: t.midX, y: t.midY)) })
            ?? screens.first(where: { $0.intersects(t) }) ?? screens.first
            ?? CGRect(x: t.minX - 400, y: t.minY - 400, width: 1200, height: 1200)
        let width = min(max(panelWidth, t.width), max(screen.width, t.width))
        // Horizontal: centre the panel on the tab, then slide it back inside the screen.
        var x = t.midX - width / 2
        x = min(max(x, screen.minX), max(screen.maxX - width, screen.minX))

        let needed = bubbleHeight + gap
        let head = max(0, min(headroom, screen.maxY - t.maxY))   // never above the screen's top edge
        let below = tab.barBottom - screen.minY >= needed
        let top: CGFloat, bottom: CGFloat, bubble: CGRect
        if below {
            top = t.maxY + head
            bottom = tab.barBottom - needed
            bubble = CGRect(x: x, y: bottom, width: width, height: bubbleHeight)
        } else {
            bottom = min(t.minY, tab.barBottom)
            top = t.maxY + needed + head
            bubble = CGRect(x: x, y: t.maxY + gap, width: width, height: bubbleHeight)
        }
        let panel = CGRect(x: x, y: bottom, width: width, height: top - bottom)
        func web(_ r: CGRect) -> CGRect { CGRect(x: r.minX - x, y: top - r.maxY, width: r.width, height: r.height) }
        return PanelLayout(panelFrame: panel, tab: tab, dogInPanel: web(tab.dogFrame), tabInPanel: web(t),
                           bubbleBelow: below, bubbleFrame: bubble)
    }

    /// A rectangle in the panel's web space (top-left origin) as a Cocoa screen rectangle.
    public static func screenRect(fromPanel r: CGRect, in panelFrame: CGRect) -> CGRect {
        CGRect(x: panelFrame.minX + r.minX, y: panelFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The dog box on the screen (Cocoa coordinates), converted from the page's top-left space.
    public static func dogScreenRect(_ layout: PanelLayout) -> CGRect {
        screenRect(fromPanel: layout.dogInPanel, in: layout.panelFrame)
    }

    /// Dock-time check: the dog sits inside the tab horizontally and above its base, and rises above the tab's top by no
    /// more than the peek. Cocoa screen coordinates.
    public static func dogIsInsideTab(_ layout: PanelLayout, tolerance: CGFloat = 0.5) -> Bool {
        let d = dogScreenRect(layout), t = layout.tab.rect
        return d.minX >= t.minX - tolerance && d.maxX <= t.maxX + tolerance
            && d.minY >= t.minY - tolerance && d.maxY <= t.maxY + TabGeometry.dogPeek + tolerance
    }

    /// The only places the panel takes mouse events: the tab always, the bubble area only while one is showing.
    public static func interactiveRects(_ layout: PanelLayout, bubbleVisible: Bool) -> [CGRect] {
        bubbleVisible ? [layout.tab.rect, layout.bubbleFrame] : [layout.tab.rect]
    }

    public static func shouldCapture(point: CGPoint, rects: [CGRect]) -> Bool {
        rects.contains { $0.contains(point) }
    }
}
