import CoreGraphics
import Foundation

/// Written for Shep.
/// Where the doghouse stands: just below the notch when the screen has one, otherwise just under Shep's own status item,
/// otherwise at the top centre of the screen. Pure geometry in Cocoa screen coordinates (bottom-left origin), no AppKit.

/// What the geometry needs to know about one screen. `auxLeft` / `auxRight` are NSScreen.auxiliaryTopLeftArea and
/// auxiliaryTopRightArea (the strips of the menu bar either side of the notch, in the same global coordinates as `frame`);
/// both nil on a screen without a notch.
public struct HomeScreen: Equatable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var auxLeft: CGRect?
    public var auxRight: CGRect?

    public init(frame: CGRect, visibleFrame: CGRect? = nil, auxLeft: CGRect? = nil, auxRight: CGRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.auxLeft = auxLeft
        self.auxRight = auxRight
    }

    /// The gap between the two strips, when both exist and leave a real gap.
    public var notch: (minX: CGFloat, maxX: CGFloat, bottom: CGFloat)? {
        guard let l = auxLeft, let r = auxRight, l.width > 0, r.width > 0, r.minX > l.maxX else { return nil }
        return (l.maxX, r.minX, min(l.minY, r.minY))
    }
}

extension HomeScreen {
    /// The auxiliary areas are meant to be in the same global coordinates as `frame`; if a system reports them relative to the
    /// screen's own origin (they then start left of or below the frame), shift them into global coordinates.
    public static func normalizedAux(_ rect: CGRect?, in frame: CGRect) -> CGRect? {
        guard let r = rect, r.width > 0, r.height > 0, r.minX.isFinite, r.minY.isFinite else { return nil }
        let inside = r.minX >= frame.minX - 0.5 && r.maxX <= frame.maxX + 0.5 && r.minY >= frame.minY - 0.5 && r.maxY <= frame.maxY + 0.5
        return inside ? r : r.offsetBy(dx: frame.minX, dy: frame.minY)
    }
}

public enum HomeKind: String, Equatable {
    case notch, statusItem, topCenter
}

public struct HomePlacement: Equatable {
    public var kind: HomeKind
    /// The doghouse panel, Cocoa coordinates.
    public var rect: CGRect
    public var screenFrame: CGRect

    /// The middle of the door: where the dog leaves and returns.
    public var door: CGPoint { HomeGeometry.door(in: rect) }

    /// One line for the capture scripts: the kind and the panel in top-left screen coordinates.
    public func logDescription(primaryScreenHeight h: CGFloat) -> String {
        let r = rect
        return "kind=\(kind.rawValue) rect=\(Int(r.minX.rounded())),\(Int((h - r.maxY).rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }
}

public enum HomeGeometry {
    /// The doghouse panel. The art fills it: a roof, a body with a round door, and room for a small "z".
    public static let size = CGSize(width: 96, height: 84)
    /// Gap between the menu bar (or the notch) and the roof's peak.
    public static let gap: CGFloat = 2
    /// Never closer than this to a screen's side.
    public static let edgeMargin: CGFloat = 4
    /// The door's centre and radius in the art's own space (top-left origin, the panel's size).
    public static let doorCenterInArt = CGPoint(x: 48, y: 60)
    public static let doorRadius: CGFloat = 14

    /// Door centre in screen coordinates for a panel rectangle.
    public static func door(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + doorCenterInArt.x, y: rect.maxY - doorCenterInArt.y)
    }

    /// The panel's rectangle for a centre x and the y the roof's peak touches (just under the bar), kept inside the screen.
    static func panelRect(centerX: CGFloat, topY: CGFloat, screen: HomeScreen) -> CGRect {
        let area = screen.frame
        var x = centerX - size.width / 2
        x = min(max(x, area.minX + edgeMargin), max(area.maxX - size.width - edgeMargin, area.minX))
        var y = topY - size.height
        y = max(y, area.minY)   // never below the screen (a tiny screen: the house is clamped, not lost)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Which screen the house stands on: the one holding Shep's status item, else the first screen.
    public static func screenIndex(screens: [HomeScreen], statusItem: CGRect?) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let s = statusItem, s.width > 0, s.height > 0 {
            let c = CGPoint(x: s.midX, y: s.midY)
            if let i = screens.firstIndex(where: { $0.frame.contains(c) }) { return i }
            if let i = screens.firstIndex(where: { $0.frame.intersects(s) }) { return i }
        }
        return 0
    }

    /// - Parameters:
    ///   - screens: every screen, primary first.
    ///   - statusItem: the status item button's window frame, Cocoa coordinates, when it exists.
    public static func place(screens: [HomeScreen], statusItem: CGRect?) -> HomePlacement? {
        guard let i = screenIndex(screens: screens, statusItem: statusItem) else { return nil }
        let screen = screens[i]
        // 1. Notch: centred in the gap, just below the strip.
        if let n = screen.notch {
            let rect = panelRect(centerX: (n.minX + n.maxX) / 2, topY: n.bottom - gap, screen: screen)
            return HomePlacement(kind: .notch, rect: rect, screenFrame: screen.frame)
        }
        // 2. Under the status item: centred on the button, below the menu bar.
        if let s = statusItem, s.width > 0, s.height > 0, s.midX.isFinite, s.minY.isFinite, screen.frame.intersects(s) {
            let rect = panelRect(centerX: s.midX, topY: min(s.minY, screen.visibleFrame.maxY) - gap, screen: screen)
            return HomePlacement(kind: .statusItem, rect: rect, screenFrame: screen.frame)
        }
        // 3. Top centre, under the menu bar (the usable area's top).
        let rect = panelRect(centerX: screen.frame.midX, topY: screen.visibleFrame.maxY - gap, screen: screen)
        return HomePlacement(kind: .topCenter, rect: rect, screenFrame: screen.frame)
    }

    /// The part of the panel that is the house (roof triangle and body), for hit-testing: points are in the panel's space,
    /// top-left origin. The rest of the panel is transparent and click-through.
    public static func isOnHouse(_ p: CGPoint) -> Bool {
        // Body: 64 x 40 under the roof's base line.
        if p.x >= 16, p.x <= 80, p.y >= 40, p.y <= 80 { return true }
        // Roof: the triangle from the peak (48, 14) to the base corners (8, 40) and (88, 40).
        guard p.y >= 14, p.y < 40 else { return false }
        let half = (p.y - 14) / (40 - 14) * 40
        return abs(p.x - 48) <= half
    }
}
