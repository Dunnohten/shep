import CoreGraphics
import ImageIO
import XCTest
@testable import ShepCore

final class CaptureLimitsTests: XCTestCase {
    func testASmallPictureIsKept() {
        XCTAssertEqual(CaptureLimits.decide(header: (1600, 1200), fileBytes: 900_000), .keep)
        XCTAssertEqual(CaptureLimits.decide(header: (2560, 1440), fileBytes: 5_000_000), .keep, "exactly at the longest side")
    }

    func testAWideOrTallPictureIsScaledToTheLongestSide() {
        XCTAssertEqual(CaptureLimits.decide(header: (5120, 2880), fileBytes: 9_000_000), .scale(width: 2560, height: 1440))
        XCTAssertEqual(CaptureLimits.decide(header: (1000, 8000), fileBytes: 9_000_000), .scale(width: 320, height: 2560))
        XCTAssertEqual(CaptureLimits.decide(header: (2561, 100), fileBytes: 9_000), .scale(width: 2560, height: 100))
    }

    func testAFileOverTheByteCapIsRefusedBeforeAnyDecoding() {
        XCTAssertEqual(CaptureLimits.decide(header: (100, 100), fileBytes: CaptureLimits.maxFileBytes + 1), .refuse(.tooManyBytes))
        XCTAssertEqual(CaptureLimits.decide(header: (100, 100), fileBytes: CaptureLimits.maxFileBytes), .keep)
        XCTAssertEqual(CaptureLimits.decide(header: nil, fileBytes: CaptureLimits.maxFileBytes + 1), .refuse(.tooManyBytes), "bytes are judged first")
    }

    func testAHeaderThatClaimsTooManyPixelsOrNoneIsRefused() {
        XCTAssertEqual(CaptureLimits.decide(header: (20_000, 20_000), fileBytes: 1_000), .refuse(.tooManyPixels), "a 400 MP picture in a small file")
        XCTAssertEqual(CaptureLimits.decide(header: (Int(Int32.max), Int(Int32.max)), fileBytes: 1_000), .refuse(.tooManyPixels), "no overflow")
        XCTAssertEqual(CaptureLimits.decide(header: nil, fileBytes: 1_000), .refuse(.notAPicture))
        XCTAssertEqual(CaptureLimits.decide(header: (0, 100), fileBytes: 1_000), .refuse(.notAPicture))
        XCTAssertEqual(CaptureLimits.decide(header: (100, 100), fileBytes: 0), .refuse(.notAPicture))
    }

    // MARK: files

    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shep-capture-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let d = dir, d.lastPathComponent.hasPrefix("shep-capture-tests-") { try? FileManager.default.removeItem(at: d) }
    }

    func writePNG(_ name: String, width: Int, height: Int) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testTheHeaderAndTheSizeComeFromTheFileWithoutDecoding() throws {
        let url = try writePNG("a.png", width: 300, height: 200)
        let header = try XCTUnwrap(CaptureLimits.headerSize(of: url))
        XCTAssertEqual(header.width, 300); XCTAssertEqual(header.height, 200)
        XCTAssertGreaterThan(CaptureLimits.fileBytes(of: url) ?? 0, 0)
        let junk = dir.appendingPathComponent("junk.png")
        try Data(repeating: 7, count: 100).write(to: junk)
        XCTAssertNil(CaptureLimits.headerSize(of: junk))
        XCTAssertNil(CaptureLimits.headerSize(of: dir.appendingPathComponent("missing.png")))
    }

    func testABigPictureComesBackScaledAndASmallOneUntouched() throws {
        let big = try writePNG("big.png", width: 3200, height: 1000)
        guard case .success(let scaled) = CaptureLimits.boundedPNG(file: big) else { return XCTFail("a 3200 px picture is scaled, not refused") }
        let size = try XCTUnwrap(ImageIOPreparer.pixelSize(of: scaled))
        XCTAssertEqual(size, CGSize(width: 2560, height: 800))
        let small = try writePNG("small.png", width: 800, height: 600)
        guard case .success(let kept) = CaptureLimits.boundedPNG(file: small) else { return XCTFail("a small picture is kept") }
        XCTAssertEqual(kept, try Data(contentsOf: small))
    }

    func testAFileThatIsNotAPictureIsRefusedWithoutBeingRead() throws {
        let junk = dir.appendingPathComponent("junk.png")
        try Data(repeating: 7, count: 100).write(to: junk)
        XCTAssertEqual(CaptureLimits.boundedPNG(file: junk), .failure(.notAPicture))
        XCTAssertEqual(CaptureLimits.boundedPNG(file: dir.appendingPathComponent("missing.png")), .failure(.notAPicture))
    }
}
