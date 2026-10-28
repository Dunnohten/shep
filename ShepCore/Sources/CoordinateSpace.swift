import CoreGraphics
import Foundation

/// Written for Shep.
/// One place for every coordinate conversion in "Fix this screen". Four spaces meet there:
///   - image pixels: the original screenshot (detector boxes, Glimmer answers after conversion), top-left origin;
///   - sent pixels: the downscaled JPEG the model is shown (only its size matters; boxes are never kept in this space);
///   - normalized: Glimmer's 0...1000 scale, relative to the image it was shown, so it is the same for sent and original pixels;
///   - screen points: global points, top-left origin (AX, CGWindowList and CGEvent), where clicks happen.
/// Points and pixels differ by the backing scale, measured from the image and the window frame (a Retina capture of a
/// scaled display is 1.75, not 2), never assumed.
public struct CoordinateSpace: Equatable, Sendable {
    /// The captured window (or display) in screen points.
    public var windowFrame: CGRect
    /// Pixel size of the original screenshot.
    public var imageSize: CGSize
    /// Pixel size of the image sent to the model; equals `imageSize` when nothing was downscaled.
    public var sentSize: CGSize

    public init(windowFrame: CGRect, imageSize: CGSize, sentSize: CGSize? = nil) {
        self.windowFrame = windowFrame; self.imageSize = imageSize; self.sentSize = sentSize ?? imageSize
    }

    /// Pixels per point on each axis.
    public var scaleX: CGFloat { windowFrame.width > 0 && imageSize.width > 0 ? imageSize.width / windowFrame.width : 1 }
    public var scaleY: CGFloat { windowFrame.height > 0 && imageSize.height > 0 ? imageSize.height / windowFrame.height : 1 }
    /// Sent pixels per original pixel (1 when not downscaled).
    public var downscale: CGFloat { imageSize.width > 0 && sentSize.width > 0 ? sentSize.width / imageSize.width : 1 }

    // MARK: pixels <-> screen points

    /// A box in original-image pixels as a rectangle in global screen points.
    public func screenRect(fromPixels px: CGRect) -> CGRect {
        CGRect(x: windowFrame.minX + px.minX / scaleX, y: windowFrame.minY + px.minY / scaleY,
               width: px.width / scaleX, height: px.height / scaleY)
    }

    /// A rectangle in global screen points as original-image pixels (the inverse of `screenRect(fromPixels:)`).
    public func pixelRect(fromScreen r: CGRect) -> CGRect {
        CGRect(x: (r.minX - windowFrame.minX) * scaleX, y: (r.minY - windowFrame.minY) * scaleY,
               width: r.width * scaleX, height: r.height * scaleY)
    }

    /// The same rectangle relative to the window's own top-left corner, in points.
    public func windowRect(fromPixels px: CGRect) -> CGRect {
        CGRect(x: px.minX / scaleX, y: px.minY / scaleY, width: px.width / scaleX, height: px.height / scaleY)
    }

    // MARK: pixels <-> sent pixels

    public func sentRect(fromPixels px: CGRect) -> CGRect {
        let sx = imageSize.width > 0 ? sentSize.width / imageSize.width : 1
        let sy = imageSize.height > 0 ? sentSize.height / imageSize.height : 1
        return CGRect(x: px.minX * sx, y: px.minY * sy, width: px.width * sx, height: px.height * sy)
    }

    public func pixelRect(fromSent r: CGRect) -> CGRect {
        let sx = sentSize.width > 0 ? imageSize.width / sentSize.width : 1
        let sy = sentSize.height > 0 ? imageSize.height / sentSize.height : 1
        return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    // MARK: pixels <-> normalized 0...1000

    public static let normalizedScale: CGFloat = 1000

    /// Normalized `[x0, y0, x1, y1]` (rounded to whole thousandths, clamped to 0...1000) for a pixel box.
    public func normalized(fromPixels px: CGRect) -> [Int] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [0, 0, 0, 0] }
        func q(_ v: CGFloat, _ total: CGFloat) -> Int {
            let n = (v / total * CoordinateSpace.normalizedScale).rounded()
            return Int(min(max(n.isFinite ? n : 0, 0), CoordinateSpace.normalizedScale))
        }
        return [q(px.minX, imageSize.width), q(px.minY, imageSize.height), q(px.maxX, imageSize.width), q(px.maxY, imageSize.height)]
    }

    /// Original-image pixel rectangle for a normalized `[x0, y0, x1, y1]` (any corner order); nil when it is not four
    /// finite numbers, is empty after clipping to the image, or the image has no size.
    public func pixelRect(fromNormalized v: [Double]) -> CGRect? {
        guard v.count == 4, v.allSatisfy({ $0.isFinite }), imageSize.width > 0, imageSize.height > 0 else { return nil }
        let k = Double(CoordinateSpace.normalizedScale)
        let x0 = min(v[0], v[2]), x1 = max(v[0], v[2]), y0 = min(v[1], v[3]), y1 = max(v[1], v[3])
        let raw = CGRect(x: x0 / k * Double(imageSize.width), y: y0 / k * Double(imageSize.height),
                         width: (x1 - x0) / k * Double(imageSize.width), height: (y1 - y0) / k * Double(imageSize.height))
        guard raw.width.isFinite, raw.height.isFinite, raw.minX.isFinite, raw.minY.isFinite else { return nil }   // huge exponents overflow
        let clipped = raw.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        return clipped
    }

    // MARK: scale guessing

    /// Backing scale of a capture when the window's size in points is known: pixels over points, snapped to a scale
    /// macOS really uses (1, 1.5, 1.75, 2, 3) when within 3%, else left as measured. Nil for unusable sizes.
    public static func measuredScale(imageWidth: CGFloat, windowWidth: CGFloat) -> CGFloat? {
        guard imageWidth > 0, windowWidth > 0, imageWidth.isFinite, windowWidth.isFinite else { return nil }
        let raw = imageWidth / windowWidth
        for s in [1, 1.5, 1.75, 2, 3] as [CGFloat] where abs(raw - s) / s <= 0.03 { return s }
        return raw
    }

    /// A window frame for a capture whose real frame is unknown (a bare PNG): origin 0,0 and `scale` pixels per point.
    /// A guess; callers say so. `scale` 0 or less means 1.
    public static func assumedFrame(imageSize: CGSize, scale: CGFloat) -> CGRect {
        let s = scale > 0 ? scale : 1
        return CGRect(x: 0, y: 0, width: imageSize.width / s, height: imageSize.height / s)
    }

    /// "x,y,w,h" (points) as a rectangle; nil unless four finite numbers with a positive size.
    public static func parseFrame(_ text: String) -> CGRect? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts.allSatisfy({ $0.isFinite }), parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
