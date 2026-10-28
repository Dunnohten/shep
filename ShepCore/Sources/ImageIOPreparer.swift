import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// PNG in, downscaled JPEG out, with ImageIO (no AppKit).
public struct ImageIOPreparer: ImagePreparing {
    public init() {}

    /// Size after scaling so the longest side is `longestSide`; never enlarges; never below 1 px.
    public static func targetSize(for size: CGSize, longestSide: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > 0, longestSide > 0, longest.isFinite else { return CGSize(width: 1, height: 1) }
        if longest <= longestSide { return size }
        let f = longestSide / longest
        return CGSize(width: max(1, (size.width * f).rounded()), height: max(1, (size.height * f).rounded()))
    }

    /// Pixel size of an encoded image, nil when it cannot be read.
    public static func pixelSize(of data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    public func prepare(png: Data, longestSide: CGFloat, quality: CGFloat) -> PreparedImage? {
        prepare(png: png, longestSide: longestSide, quality: quality, marks: [])
    }

    public func prepare(png: Data, longestSide: CGFloat, quality: CGFloat, marks: [ImageMark]) -> PreparedImage? {
        guard let original = ImageIOPreparer.pixelSize(of: png), let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let target = ImageIOPreparer.targetSize(for: original, longestSide: longestSide)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(target.width, target.height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        var flat = ImageIOPreparer.opaque(image) ?? image
        var drawn = false
        if !marks.isEmpty, let m = ImageIOPreparer.marked(flat, marks: marks, originalSize: original) { flat = m; drawn = true }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return PreparedImage(jpeg: out as Data, size: CGSize(width: flat.width, height: flat.height), originalSize: original, marked: drawn)
    }

    /// JPEG has no alpha: draw onto white first so transparent pixels don't turn black.
    static func opaque(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Draws each mark as a red outline with its id on a red tag at the box's top-left corner (set-of-marks), so a model
    /// shown only this image can tell which box an id means. Boxes are in original pixels, top-left origin; the context
    /// is bottom-left, hence the flip. Nil when a drawing context cannot be made.
    static func marked(_ image: CGImage, marks: [ImageMark], originalSize: CGSize) -> CGImage? {
        guard originalSize.width > 0, originalSize.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let sx = w / originalSize.width, sy = h / originalSize.height
        let red = CGColor(red: 0.95, green: 0.1, blue: 0.2, alpha: 1)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let fontSize: CGFloat = max(10, min(16, h / 60))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]
        ctx.setStrokeColor(red)
        ctx.setLineWidth(1.5)
        for mark in marks {
            let b = mark.box
            guard b.minX.isFinite, b.minY.isFinite, b.width.isFinite, b.height.isFinite else { continue }
            let box = CGRect(x: b.minX * sx, y: h - b.maxY * sy, width: b.width * sx, height: b.height * sy)
            ctx.stroke(box)
            let text = NSAttributedString(string: String(mark.id), attributes: attributes)
            let line = CTLineCreateWithAttributedString(text as CFAttributedString)
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let tag = CGSize(width: textWidth + 4, height: fontSize + 3)
            // Above the box's top-left corner when there is room, else just inside it.
            let tagY = box.maxY + tag.height <= h ? box.maxY : box.maxY - tag.height
            let tagX = min(max(box.minX, 0), max(w - tag.width, 0))
            ctx.setFillColor(red)
            ctx.fill(CGRect(x: tagX, y: tagY, width: tag.width, height: tag.height))
            ctx.textPosition = CGPoint(x: tagX + 2, y: tagY + 2.5)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }
}
