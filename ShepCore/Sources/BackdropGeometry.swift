import CoreGraphics
import Foundation

/// Written for Shep.
/// `--demo-backdrop`: the rectangle Shep paints a plain backdrop over, so a recording of exactly that rectangle holds only
/// Shep-owned pixels plus the test window. It covers the doghouse, the travel corridor, the tab (with its headroom) and the test
/// window, plus a margin, and never reaches into the menu bar or the Dock (it is clamped to each screen's usable area).
/// All rectangles are in Cocoa screen coordinates (y up); the log converts to the top-left space the scripts read.
public enum BackdropGeometry {
    public static let margin: CGFloat = 20

    /// The union of `rects` grown by `margin`, clipped to the screens' usable areas and rounded outward to whole points.
    /// Nil when nothing usable is left (no rectangles, non-finite numbers, or all of it off every screen).
    public static func rect(covering rects: [CGRect], usable: [CGRect], margin: CGFloat = BackdropGeometry.margin) -> CGRect? {
        let good = rects.filter { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && !$0.isNull && !$0.isEmpty }
        guard let first = good.first, margin.isFinite, margin >= 0 else { return nil }
        let union = good.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -margin, dy: -margin)
        var pieces: [CGRect] = []
        for area in usable where area.width > 0 && area.height > 0 {
            let part = union.intersection(area)
            if !part.isNull && part.width > 0 && part.height > 0 { pieces.append(part) }
        }
        guard let head = pieces.first else { return nil }
        let r = pieces.dropFirst().reduce(head) { $0.union($1) }
        let x0 = r.minX.rounded(.down), y0 = r.minY.rounded(.down), x1 = r.maxX.rounded(.up), y1 = r.maxY.rounded(.up)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `x,y,w,h` in global top-left points, the form the scripts read (`[shep] backdrop rect=...`).
    public static func logString(_ r: CGRect, primaryScreenHeight h: CGFloat) -> String {
        "\(Int(r.minX.rounded())),\(Int((h - r.maxY).rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }
}
