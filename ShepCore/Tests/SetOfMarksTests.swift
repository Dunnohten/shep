import CoreGraphics
import ImageIO
import XCTest
@testable import ShepCore

final class SetOfMarksTests: XCTestCase {
    /// A solid white PNG of the given pixel size.
    func whitePNG(width w: Int, height h: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// RGB of the pixel at (x, y) counted from the top-left, read from a decoded image.
    func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buf in
            let ctx = try XCTUnwrap(CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = (y * image.width + x) * 4   // the bitmap's first row is the top row
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func testMarkedImageHasTheBoxOutlineInRedAndKeepsItsSize() throws {
        let png = try whitePNG(width: 400, height: 200)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let out = try XCTUnwrap(ImageIOPreparer.marked(image, marks: [ImageMark(id: 7, box: CGRect(x: 100, y: 80, width: 120, height: 60))],
                                                       originalSize: CGSize(width: 400, height: 200)))
        XCTAssertEqual(out.width, 400); XCTAssertEqual(out.height, 200)
        let edge = try pixel(out, x: 160, y: 80)          // on the top edge of the box
        XCTAssertGreaterThan(edge.r, 180); XCTAssertLessThan(edge.g, 120)
        let inside = try pixel(out, x: 160, y: 110)       // interior stays white
        XCTAssertGreaterThan(inside.g, 240)
        let far = try pixel(out, x: 10, y: 190)
        XCTAssertGreaterThan(far.g, 240)
    }

    func testMarksAreScaledWithTheDownscale() throws {
        let png = try whitePNG(width: 800, height: 400)
        let prepared = try XCTUnwrap(ImageIOPreparer().prepare(png: png, longestSide: 400, quality: 0.9,
                                                               marks: [ImageMark(id: 1, box: CGRect(x: 200, y: 160, width: 240, height: 120))]))
        XCTAssertTrue(prepared.marked)
        XCTAssertEqual(prepared.size, CGSize(width: 400, height: 200))
        XCTAssertEqual(prepared.originalSize, CGSize(width: 800, height: 400))
        let plain = try XCTUnwrap(ImageIOPreparer().prepare(png: png, longestSide: 400, quality: 0.9))
        XCTAssertFalse(plain.marked)
        let none = try XCTUnwrap(ImageIOPreparer().prepare(png: png, longestSide: 400, quality: 0.9, marks: []))
        XCTAssertFalse(none.marked)
    }

    func testThePromptMentionsTheMarksOnlyWhenTheyAreDrawn() {
        let candidates = [VisionCandidate(id: 1, pixelBox: CGRect(x: 10, y: 10, width: 50, height: 20), screenFrame: CGRect(x: 5, y: 5, width: 25, height: 10), concept: "icon", score: 0.9)]
        func job(marked: Bool) -> NamingJob {
            NamingJob(image: PreparedImage(jpeg: Data([0xFF]), size: CGSize(width: 100, height: 50), originalSize: CGSize(width: 200, height: 100), marked: marked),
                      candidates: candidates)
        }
        XCTAssertTrue(GlimmerNaming.prompt(job(marked: true), problem: nil).contains("drawn on the image in red"))
        XCTAssertFalse(GlimmerNaming.prompt(job(marked: false), problem: nil).contains("drawn on the image"))
    }
}
