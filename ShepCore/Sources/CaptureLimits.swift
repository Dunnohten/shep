import CoreGraphics
import Foundation
import ImageIO

// Written for Shep.

/// How big a window screenshot may be before anything decodes it. A huge window on a big display can be tens of megapixels; the whole PNG
/// would be read and decoded before the label crop caps (256 px a side, 1.5 MB in all) ever applied. The checks here use only the file's
/// size on disk and the 24-byte PNG header, and a picture that is too wide is scaled down while it is read (ImageIO thumbnail), never
/// decoded at full size first.
public enum CaptureLimits {
    /// The longest side kept, in pixels. A Retina window of up to 1280 points is untouched; a bigger one is scaled to this.
    public static let maxLongestSide = 2560
    /// A screenshot file bigger than this is refused without being read.
    public static let maxFileBytes = 30_000_000
    /// A header that claims more pixels than this is refused without being decoded.
    public static let maxSourcePixels = 100_000_000

    public enum Refusal: String, Error, Equatable, Sendable {
        case notAPicture, tooManyBytes, tooManyPixels
    }

    public enum Decision: Equatable, Sendable {
        /// Use the file as it is.
        case keep
        /// Scale down to this size while reading.
        case scale(width: Int, height: Int)
        case refuse(Refusal)
    }

    /// From the file's size on disk and the pixel size its header gives (nil when the header is not a PNG's).
    public static func decide(header: (width: Int, height: Int)?, fileBytes: Int) -> Decision {
        guard fileBytes > 0 else { return .refuse(.notAPicture) }
        guard fileBytes <= maxFileBytes else { return .refuse(.tooManyBytes) }
        guard let h = header, h.width > 0, h.height > 0 else { return .refuse(.notAPicture) }
        // Widths and heights are 32-bit in a PNG header; the product is checked in floating point so it cannot overflow.
        guard Double(h.width) * Double(h.height) <= Double(maxSourcePixels) else { return .refuse(.tooManyPixels) }
        let longest = max(h.width, h.height)
        if longest <= maxLongestSide { return .keep }
        let f = Double(maxLongestSide) / Double(longest)
        return .scale(width: max(1, Int((Double(h.width) * f).rounded())), height: max(1, Int((Double(h.height) * f).rounded())))
    }

    /// The first 24 bytes of a file read as a PNG header; nothing else of the file is read.
    public static func headerSize(of file: URL) -> (width: Int, height: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 24) else { return nil }
        return LabelCrop.pngSize(head)
    }

    public static func fileBytes(of file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
    }

    /// The PNG at `file`, scaled so its longest side is `longestSide`, decoded at the small size (never in full). nil if it cannot be made.
    public static func scaledPNG(file: URL, longestSide: Int = maxLongestSide) -> Data? {
        guard longestSide > 0, let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The bytes of the screenshot at `file` under the limits above, or the reason there are none.
    public static func boundedPNG(file: URL) -> Result<Data, Refusal> {
        let bytes = fileBytes(of: file) ?? 0
        switch decide(header: headerSize(of: file), fileBytes: bytes) {
        case .refuse(let why): return .failure(why)
        case .keep:
            guard let data = try? Data(contentsOf: file) else { return .failure(.notAPicture) }
            return .success(data)
        case .scale:
            guard let data = scaledPNG(file: file) else { return .failure(.notAPicture) }
            return .success(data)
        }
    }
}
