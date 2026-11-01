import CoreGraphics
import Foundation

/// Written for Shep.
/// Where Shep's home indicator stands: a slim "chin" under the menu bar exactly as wide as the notch when the screen has one
/// (the notch itself has no pixels, and the menu-bar items either side of it stay uncovered), otherwise a small pill hanging
/// from the menu bar at the top centre. Neither takes the mouse.
/// Pure geometry in Cocoa screen coordinates (bottom-left origin), no AppKit.

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
    /// A 14-inch MacBook Pro's built-in display, for the snapshot harness when no notched screen is attached.
    public static var exampleNotched: HomeScreen {
        HomeScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                   auxLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                   auxRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
    }

    /// The auxiliary areas are meant to be in the same global coordinates as `frame`; if a system reports them relative to the
    /// screen's own origin (they then start left of or below the frame), shift them into global coordinates.
    public static func normalizedAux(_ rect: CGRect?, in frame: CGRect) -> CGRect? {
        guard let r = rect, r.width > 0, r.height > 0, r.minX.isFinite, r.minY.isFinite else { return nil }
        let inside = r.minX >= frame.minX - 0.5 && r.maxX <= frame.maxX + 0.5 && r.minY >= frame.minY - 0.5 && r.maxY <= frame.maxY + 0.5
        return inside ? r : r.offsetBy(dx: frame.minX, dy: frame.minY)
    }
}

public enum HomeKind: String, Equatable {
    case notch, topCenter
}

public struct HomePlacement: Equatable {
    public var kind: HomeKind
    /// The indicator's panel, Cocoa coordinates.
    public var rect: CGRect
    public var screenFrame: CGRect

    /// The middle of the bottom edge: where the dog leaves and returns.
    public var door: CGPoint { HomeGeometry.door(in: rect) }

    /// The radius of the two lower corners (the upper edge is flush with the bar).
    public var cornerRadius: CGFloat { kind == .notch ? HomeGeometry.notchCornerRadius : HomeGeometry.topCenterCornerRadius }

    /// One line for the capture scripts: the kind and the panel in top-left screen coordinates.
    public func logDescription(primaryScreenHeight h: CGFloat) -> String {
        let r = rect
        return "kind=\(kind.rawValue) rect=\(Int(r.minX.rounded())),\(Int((h - r.maxY).rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }
}

public enum HomeGeometry {
    /// The chin under the notch: as short as the paw and the status mark stay legible. It hangs this far below the menu bar and
    /// so covers this much of whatever window is under the notch's width.
    public static let chinHeight: CGFloat = 15
    public static let notchCornerRadius: CGFloat = 7
    public static let notchIconSize: CGFloat = 10
    /// The gap between the chin's side edge and the mark nearest it.
    public static let chinIconInset: CGFloat = 16
    /// A screen without a notch: a small pill under the menu bar.
    public static let topCenterSize = CGSize(width: 60, height: 18)
    public static let topCenterCornerRadius: CGFloat = 8
    public static let topCenterIconSize: CGFloat = 12
    /// The indicator is click-through everywhere: a click on it belongs to the window or title bar under it. Shep is called from
    /// the status item menu, the shortcut and the other call inputs.
    public static func takesMouse(kind: HomeKind) -> Bool { false }
    /// How strong the indicator is at rest. The chin must match the black hardware above it exactly.
    public static func restingAlpha(for kind: HomeKind) -> CGFloat { kind == .notch ? 1 : 0.9 }
    /// The doghouse header of the setup window still shows the doghouse page at this size.
    public static let headerSize = CGSize(width: 96, height: 84)

    /// The middle of a panel's bottom edge in screen coordinates: the dog leaves from and returns to this point.
    public static func door(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.minY)
    }

    /// Which screen hosts the indicator: the one holding Shep's status item, else the first screen.
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
    ///   - statusItem: the status item button's window frame, Cocoa coordinates, when it exists (it only picks the screen).
    public static func place(screens: [HomeScreen], statusItem: CGRect?) -> HomePlacement? {
        guard let i = screenIndex(screens: screens, statusItem: statusItem) else { return nil }
        let screen = screens[i]
        let area = screen.frame
        // 1. Notch: the chin, exactly the notch's width, its top edge on the menu bar's bottom edge. Never inside the menu bar.
        if let n = screen.notch, n.bottom < area.maxY, n.minX >= area.minX, n.maxX <= area.maxX {
            let y = max(n.bottom - chinHeight, area.minY)
            let rect = CGRect(x: n.minX, y: y, width: n.maxX - n.minX, height: n.bottom - y)
            return HomePlacement(kind: .notch, rect: rect, screenFrame: area)
        }
        // 2. No notch: a small pill hanging from the menu bar's lower edge, at the top centre.
        var x = area.midX - topCenterSize.width / 2
        x = min(max(x, area.minX), max(area.maxX - topCenterSize.width, area.minX))
        let y = max(screen.visibleFrame.maxY - topCenterSize.height, area.minY)   // a tiny screen: clamped, not lost
        let rect = CGRect(x: x, y: y, width: min(topCenterSize.width, area.width), height: min(topCenterSize.height, area.height))
        return HomePlacement(kind: .topCenter, rect: rect, screenFrame: area)
    }

    /// Where the paw and the status symbol go, in the panel's space (top-left origin): one square in each half.
    public static func iconSlots(kind: HomeKind, size: CGSize) -> (left: CGRect, right: CGRect) {
        let icon = kind == .notch ? notchIconSize : topCenterIconSize
        let y = (size.height - icon) / 2
        if kind == .notch {
            return (CGRect(x: chinIconInset, y: y, width: icon, height: icon),
                    CGRect(x: size.width - chinIconInset - icon, y: y, width: icon, height: icon))
        }
        let zone = size.width / 2
        let left = CGRect(x: (zone - icon) / 2, y: y, width: icon, height: icon)
        let right = CGRect(x: size.width - zone + (zone - icon) / 2, y: y, width: icon, height: icon)
        return (left, right)
    }
}
