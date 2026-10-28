import CoreGraphics
import Foundation

/// Shared title-bar constants and helpers; the tab itself is in TabGeometry. No AppKit: screens come in as plain rectangles.
public enum DockGeometry {
    public static let titleBarHeight: CGFloat = 28
    /// The dog art is 54:38 (bloub HEAD_BOX); 40 x 28 keeps that ratio and fills the title bar.
    public static let dogSize = CGSize(width: 40, height: 28)
    /// Traffic lights live in the left 80 pt of the title bar; the dog never goes there.
    public static let trafficLightInset: CGFloat = 80
    public static let edgeMargin: CGFloat = 8
    /// Rough width of one character of the 13 pt system title font, and of the proxy icon plus its gap.
    static let titleCharWidth: CGFloat = 7.2
    static let titleIconAllowance: CGFloat = 28

    /// Index of the screen sharing the most area with `rect`; nil when it touches none.
    public static func screenIndex(for rect: CGRect, in screens: [CGRect]) -> Int? {
        var best: Int?
        var bestArea: CGFloat = 0
        for (i, s) in screens.enumerated() {
            let r = s.intersection(rect)
            if r.isNull { continue }
            let area = r.width * r.height
            if area > bestArea { best = i; bestArea = area }
        }
        return best
    }
}

extension DockGeometry {
    /// Where a centred title of `title` probably sits (Cocoa coordinates), for apps whose title text is not in the
    /// Accessibility tree. A guess from the character count, never wider than the space between the traffic lights and
    /// the right edge. Nil for an empty title.
    public static func estimatedTitleExtent(title: String, window: CGRect) -> CGRect? {
        let count = title.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard count > 0, window.width > 0, window.height >= titleBarHeight else { return nil }
        let room = window.width - 2 * (trafficLightInset + edgeMargin)
        guard room > 0 else { return nil }
        let width = min(CGFloat(count) * titleCharWidth + titleIconAllowance, room)
        return CGRect(x: window.midX - width / 2, y: window.maxY - titleBarHeight, width: width, height: titleBarHeight)
    }
}

/// Accessibility reports frames with a top-left origin on the primary screen; AppKit wants bottom-left.
public enum AXCoordinates {
    public static func cocoaRect(fromAX r: CGRect, primaryScreenHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
