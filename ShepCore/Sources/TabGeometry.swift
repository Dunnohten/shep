import CoreGraphics
import Foundation

/// Written for Shep.
/// Shep docks as a TAB on the window's title bar: a small shape that rises above the window's top edge, fused to the
/// bar like a browser tab (same fill, concave flare corners at the base, rounded top corners). Pure geometry, no AppKit.
/// Frames are Cocoa screen coordinates (bottom-left origin); `TabPath` is in the tab's own space (top-left origin, y down).

public enum TabStyle: Equatable {
    /// Rises above the window's top edge (the normal case).
    case above
    /// No room above the window (its top is at the menu bar / screen top): the tab hangs down into the title bar.
    case inside
}

public struct TabLayout: Equatable {
    public var style: TabStyle
    /// The whole tab including both flares, Cocoa coordinates. For `.above` its bottom edge is the window's top edge.
    public var rect: CGRect
    /// Where the dog head sits, Cocoa coordinates, inside `rect`.
    public var dogFrame: CGRect
    /// Bottom of the title bar (Cocoa y). The speech bubble starts below this so it never covers the bar.
    public var barBottom: CGFloat
    public var flare: CGFloat
    public var cornerRadius: CGFloat

    public var path: TabPath { TabGeometry.path(size: rect.size, flare: flare, cornerRadius: cornerRadius, style: style) }
}

public enum TabPlacement: Equatable {
    case tab(TabLayout)
    case hidden

    public var layout: TabLayout? {
        if case .tab(let l) = self { return l }
        return nil
    }
}

/// One drawing step in tab space (top-left origin).
public enum TabPathElement: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    case close
}

public struct TabPath: Equatable {
    /// The open outline: from the base-left corner up the flare, round the top, down to the base-right corner.
    /// Stroked with the hairline. It has NO segment along the base, so the tab fuses with the bar.
    public var outline: [TabPathElement]
    /// The same shape closed along the base, for the fill.
    public var fill: [TabPathElement]
    public var size: CGSize
}

public enum TabGeometry {
    /// Width of the flat part of the tab (between the two flares), points.
    public static let bodyWidth: CGFloat = 64
    /// Height of the tab above the window's top edge (flares included).
    public static let height: CGFloat = 30
    /// Radius of the concave flare at each base corner.
    public static let flare: CGFloat = 10
    /// Radius of the rounded top corners.
    public static let cornerRadius: CGFloat = 8
    /// Total width: body plus a flare on each side.
    public static var width: CGFloat { bodyWidth + 2 * flare }
    /// Gap kept between the tab and the title text / toolbar items beside it.
    public static let obstacleGap: CGFloat = 8
    /// Distance from the window's right edge to the tab's right flare: clear of the window's rounded corner (up to ~26 pt on recent macOS).
    public static let rightInset: CGFloat = 20
    /// Fraction of a circle's radius that places a cubic Bezier's controls for a quarter-circle.
    static let arc: CGFloat = 0.5522847498
    /// Dog head: bottom of the head at the window edge, centred in the body.
    public static let dogSize = DockGeometry.dogSize
    static let dogTopInset: CGFloat = 2
    /// The head peeks up out of an `.above` tab: its box rises this far above the tab's top edge (the panel's headroom holds it).
    public static let dogPeek: CGFloat = 4
    /// The dog art's bounding box in the art's own units (bloub HEAD_BOX, ears and outline included) and the head body alone
    /// (HEAD half-width 17, half-height 15). The page fits the art into `dogFrame` with `preserveAspectRatio="xMidYMid meet"`.
    public static let artUnits = CGSize(width: 54, height: 38)
    public static let headUnits = CGSize(width: 34, height: 30)

    /// Where the art really lands inside `frame` (meet-fit, centred): what the screen shows for a given dog frame.
    public static func renderedArt(in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let s = min(frame.width / artUnits.width, frame.height / artUnits.height)
        let w = artUnits.width * s, h = artUnits.height * s
        return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
    }

    /// Size of the head body (without ears) when the art is fitted into `frame`.
    public static func renderedHead(in frame: CGRect) -> CGSize {
        let art = renderedArt(in: frame)
        guard art.width > 0 else { return .zero }
        let s = art.width / artUnits.width
        return CGSize(width: headUnits.width * s, height: headUnits.height * s)
    }

    /// Narrowest window that still holds a tab: traffic lights, margin, the tab, the right inset.
    public static var minimumWindowWidth: CGFloat {
        DockGeometry.trafficLightInset + DockGeometry.edgeMargin + width + rightInset
    }

    /// - Parameters:
    ///   - window: the window's frame, Cocoa coordinates.
    ///   - isFullScreen: AXFullScreen; a full-screen window has no title bar, so no tab.
    ///   - screens: every screen's full frame.
    ///   - usable: each screen's usable area (visible frame: no menu bar or Dock), same order as `screens`. Defaults to `screens`.
    ///   - obstacles: title-bar content (title text, toolbar buttons), Cocoa coordinates. The tab steps left past them.
    public static func place(window: CGRect, isFullScreen: Bool, screens: [CGRect], usable: [CGRect]? = nil,
                             obstacles: [CGRect] = []) -> TabPlacement {
        let finite = [window.minX, window.minY, window.width, window.height].allSatisfy { $0.isFinite }
        guard finite, !window.isNull, window.width > 0, window.height > 0, !screens.isEmpty, !isFullScreen else { return .hidden }
        guard window.height >= DockGeometry.titleBarHeight, window.width >= minimumWindowWidth else { return .hidden }

        let bar = CGRect(x: window.minX, y: window.maxY - DockGeometry.titleBarHeight, width: window.width, height: DockGeometry.titleBarHeight)
        guard let i = DockGeometry.screenIndex(for: bar, in: screens) else { return .hidden }
        let screen = screens[i]
        let area = (usable != nil && usable!.count == screens.count) ? usable![i] : screen
        let visible = bar.intersection(area)
        guard !visible.isNull, visible.width >= width, visible.height >= DockGeometry.titleBarHeight / 2 else { return .hidden }

        // Horizontal slot for the whole tab (flares included): right of the traffic lights, inside the screen.
        let lo = max(window.minX + DockGeometry.trafficLightInset + DockGeometry.edgeMargin, visible.minX + DockGeometry.edgeMargin)
        let hi = min(window.maxX - rightInset, visible.maxX - DockGeometry.edgeMargin) - width
        guard lo <= hi else { return .hidden }
        let x = rightEndX(lo: lo, hi: hi, bar: bar, obstacles: obstacles)

        let roomAbove = area.maxY - window.maxY
        if roomAbove >= height {
            let rect = CGRect(x: x, y: window.maxY, width: width, height: height)
            let dog = CGRect(x: x + flare + (bodyWidth - dogSize.width) / 2, y: window.maxY + height - dogTopInset - dogSize.height + dogPeek,
                             width: dogSize.width, height: dogSize.height)
            return .tab(TabLayout(style: .above, rect: rect, dogFrame: dog, barBottom: bar.minY, flare: flare, cornerRadius: cornerRadius))
        }
        // No room above: hang inside the bar, flush with the window's top edge, as tall as the bar.
        guard window.maxY <= area.maxY + DockGeometry.titleBarHeight / 2 else { return .hidden }   // mostly above the screen: nothing to show
        let h = DockGeometry.titleBarHeight
        let rect = CGRect(x: x, y: window.maxY - h, width: width, height: h)
        let dog = CGRect(x: x + flare + (bodyWidth - dogSize.width) / 2, y: rect.minY, width: dogSize.width, height: dogSize.height)
        // Keep everything on the usable screen when the window pokes above it.
        let dy = min(0, area.maxY - rect.maxY)
        return .tab(TabLayout(style: .inside, rect: rect.offsetBy(dx: 0, dy: dy), dogFrame: dog.offsetBy(dx: 0, dy: dy),
                              barBottom: bar.minY + dy, flare: flare, cornerRadius: cornerRadius))
    }

    /// Right-most x in `lo...hi` where the tab clears every obstacle sharing the title bar's band; falls back to `hi`
    /// when the bar is too full (a tab over one button beats no tab).
    static func rightEndX(lo: CGFloat, hi: CGFloat, bar: CGRect, obstacles: [CGRect]) -> CGFloat {
        let relevant = obstacles.filter { o in
            o.minX.isFinite && o.maxX.isFinite && o.minY.isFinite && o.maxY.isFinite && !o.isNull
                && o.width > 0 && o.height > 0 && o.maxY > bar.minY && o.minY < bar.maxY
        }
        var x = hi
        var rounds = relevant.count + 1
        while rounds > 0 {
            rounds -= 1
            let slotMin = x - obstacleGap
            let slotMax = x + width + obstacleGap
            var moved = false
            for o in relevant where o.maxX > slotMin && o.minX < slotMax {
                x = min(x, o.minX - obstacleGap - width)
                moved = true
            }
            if !moved { break }
        }
        return x >= lo ? x : hi
    }

    /// The tab's outline in its own space (top-left origin, y down). `.above`: base at the bottom. `.inside`: the
    /// same shape mirrored, base at the top (it hangs from the window's top edge).
    public static func path(size: CGSize, flare f: CGFloat, cornerRadius r: CGFloat, style: TabStyle) -> TabPath {
        let w = size.width, h = size.height
        let k = arc
        var o: [TabPathElement] = []
        // Base-left, flare up to the left wall, left wall, top-left corner, top, top-right corner, right wall, flare down.
        o.append(.move(CGPoint(x: 0, y: h)))
        o.append(.curve(to: CGPoint(x: f, y: h - f), control1: CGPoint(x: k * f, y: h), control2: CGPoint(x: f, y: h - f + k * f)))
        o.append(.line(CGPoint(x: f, y: r)))
        o.append(.curve(to: CGPoint(x: f + r, y: 0), control1: CGPoint(x: f, y: r - k * r), control2: CGPoint(x: f + r - k * r, y: 0)))
        o.append(.line(CGPoint(x: w - f - r, y: 0)))
        o.append(.curve(to: CGPoint(x: w - f, y: r), control1: CGPoint(x: w - f - r + k * r, y: 0), control2: CGPoint(x: w - f, y: r - k * r)))
        o.append(.line(CGPoint(x: w - f, y: h - f)))
        o.append(.curve(to: CGPoint(x: w, y: h), control1: CGPoint(x: w - f, y: h - f + k * f), control2: CGPoint(x: w - k * f, y: h)))
        var fill = o
        fill.append(.close)   // straight along the base
        if style == .inside {
            o = o.map { mirrored($0, height: h) }
            fill = fill.map { mirrored($0, height: h) }
        }
        return TabPath(outline: o, fill: fill, size: size)
    }

    private static func mirrored(_ e: TabPathElement, height h: CGFloat) -> TabPathElement {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        switch e {
        case .move(let p): return .move(m(p))
        case .line(let p): return .line(m(p))
        case .curve(let to, let c1, let c2): return .curve(to: m(to), control1: m(c1), control2: m(c2))
        case .close: return .close
        }
    }
}

/// Colours of the tab: fill matches the title bar, the hairline matches the window border.
public enum TabAppearance {
    public static let lightFill = "#E8E8E8"
    public static let darkFill = "#2D2D2D"
    /// rgba components (0...1) of the 1 px outline.
    public static let lightOutline: [Double] = [0, 0, 0, 0.18]
    public static let darkOutline: [Double] = [1, 1, 1, 0.22]

    public static func fallbackFillHex(dark: Bool) -> String { dark ? darkFill : lightFill }
    public static func outlineRGBA(dark: Bool) -> [Double] { dark ? darkOutline : lightOutline }

    /// Parses "#RRGGBB"; nil for anything else.
    public static func rgb(hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), hex.dropFirst().allSatisfy({ $0.isHexDigit }), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func hex(r: Int, g: Int, b: Int) -> String {
        func c(_ v: Int) -> Int { min(max(v, 0), 255) }
        return String(format: "#%02X%02X%02X", UInt32(c(r)), UInt32(c(g)), UInt32(c(b)))
    }

    /// Picks the title-bar colour from one sampled pixel row (RGBA bytes, 4 per pixel). Uses the median-most common
    /// colour of the row's middle section, skipping the traffic-light and edge zones; nil when the row is unusable.
    public static func barColor(fromRow rgba: [UInt8], width: Int) -> String? {
        guard width > 0, rgba.count >= width * 4 else { return nil }
        let from = min(width / 4, width - 1), to = max(from + 1, width - width / 8)
        var counts: [UInt32: Int] = [:]
        for x in from..<min(to, width) {
            let i = x * 4
            let key = (UInt32(rgba[i]) << 16) | (UInt32(rgba[i + 1]) << 8) | UInt32(rgba[i + 2])
            counts[key, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        return hex(r: Int((best.key >> 16) & 0xFF), g: Int((best.key >> 8) & 0xFF), b: Int(best.key & 0xFF))
    }
}
