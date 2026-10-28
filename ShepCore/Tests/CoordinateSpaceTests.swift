import XCTest
@testable import ShepCore

/// A synthetic capture of known size with controls at known places, pushed through every space and back.
final class CoordinateSpaceTests: XCTestCase {
    /// (backing scale, window frame in points). The 1.75 case is the one from the first live run: 3024 x 1964 px on a 1728 x 1122 pt display.
    let cases: [(scale: CGFloat, frame: CGRect)] = [
        (1.0, CGRect(x: 40, y: 30, width: 1200, height: 800)),
        (1.75, CGRect(x: 0, y: 0, width: 1728, height: 1122)),
        (2.0, CGRect(x: -1440, y: 25, width: 1000, height: 700)),   // a window on a display left of the primary
    ]
    /// Boxes in window points (relative to the window), chosen to be exact at every scale above.
    let controlsInWindow = [CGRect(x: 12, y: 8, width: 16, height: 16), CGRect(x: 400, y: 100, width: 80, height: 28), CGRect(x: 900, y: 600, width: 40, height: 40)]

    func space(_ c: (scale: CGFloat, frame: CGRect), longest: CGFloat? = nil) -> CoordinateSpace {
        let image = CGSize(width: c.frame.width * c.scale, height: c.frame.height * c.scale)
        let sent = longest.map { ImageIOPreparer.targetSize(for: image, longestSide: $0) } ?? image
        return CoordinateSpace(windowFrame: c.frame, imageSize: image, sentSize: sent)
    }

    func close(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: eps, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: eps, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: eps, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: eps, file: file, line: line)
    }

    func testScaleIsMeasuredNotAssumed() {
        for c in cases {
            let s = space(c)
            XCTAssertEqual(s.scaleX, c.scale, accuracy: 1e-9)
            XCTAssertEqual(s.scaleY, c.scale, accuracy: 1e-9)
            XCTAssertEqual(s.downscale, 1, accuracy: 1e-9)
        }
        XCTAssertEqual(space(cases[1], longest: 960).downscale, 960.0 / 3024.0, accuracy: 0.001)
    }

    func testDetectorPixelsToScreenPointsAndBack() {
        for c in cases {
            let s = space(c)
            for local in controlsInWindow {
                let px = CGRect(x: local.minX * c.scale, y: local.minY * c.scale, width: local.width * c.scale, height: local.height * c.scale)
                let screen = s.screenRect(fromPixels: px)
                close(screen, local.offsetBy(dx: c.frame.minX, dy: c.frame.minY))
                close(s.pixelRect(fromScreen: screen), px)
                close(s.windowRect(fromPixels: px), local)
            }
        }
    }

    func testGlimmerNormalizedBoxesLandOnTheSameScreenPointsWithAndWithoutDownscale() {
        for c in cases {
            for longest in [nil, 960] as [CGFloat?] {
                let s = space(c, longest: longest)
                for local in controlsInWindow {
                    let px = CGRect(x: local.minX * c.scale, y: local.minY * c.scale, width: local.width * c.scale, height: local.height * c.scale)
                    // What the prompt shows the model, and what the model answers with: the same 0-1000 numbers.
                    let n = s.normalized(fromPixels: px)
                    let back = try! XCTUnwrap(s.pixelRect(fromNormalized: n.map(Double.init)))
                    // Rounding to whole thousandths costs at most 0.5/1000 of the image per edge.
                    let eps = max(s.imageSize.width, s.imageSize.height) / 1000 * 1.5
                    close(back, px, eps)
                    close(s.screenRect(fromPixels: back), local.offsetBy(dx: c.frame.minX, dy: c.frame.minY), eps / c.scale + 0.05)
                }
            }
        }
    }

    func testNormalizedDoesNotDependOnTheDownscale() {
        let full = space(cases[1])
        let small = space(cases[1], longest: 960)
        let px = CGRect(x: 600, y: 300, width: 300, height: 100)
        XCTAssertEqual(full.normalized(fromPixels: px), small.normalized(fromPixels: px))
        let sent = small.sentRect(fromPixels: px)
        close(small.pixelRect(fromSent: sent), px)
        XCTAssertEqual(sent.width / px.width, small.downscale, accuracy: 0.001)
    }

    func testNormalizedEdgesAreClampedAndBadInputIsRejected() {
        let s = space(cases[1])
        XCTAssertEqual(s.normalized(fromPixels: CGRect(x: -50, y: -50, width: 10_000, height: 10_000)), [0, 0, 1000, 1000])
        XCTAssertNil(s.pixelRect(fromNormalized: [1, 2, 3]))
        XCTAssertNil(s.pixelRect(fromNormalized: [Double.nan, 0, 10, 10]))
        XCTAssertNil(s.pixelRect(fromNormalized: [500, 500, 500, 500]), "empty")
        XCTAssertNil(s.pixelRect(fromNormalized: [2000, 2000, 3000, 3000]), "entirely off the image")
        XCTAssertNotNil(s.pixelRect(fromNormalized: [900, 900, 1200, 1200]), "clipped to the image")
        XCTAssertNotNil(s.pixelRect(fromNormalized: [300, 300, 100, 100]), "corners in any order")
    }

    // MARK: the shapes of the first live run's problems

    func testAssumingTwoTimesOnA175DisplayShiftsEveryPointByTwelvePercent() {
        // Live run: a 3024 x 1964 px capture of a 1728 x 1122 pt display, treated as 2x (1512 x 982 pt).
        let image = CGSize(width: 3024, height: 1964)
        let real = CoordinateSpace(windowFrame: CGRect(x: 0, y: 0, width: 1728, height: 1122), imageSize: image)
        let guess = CoordinateSpace(windowFrame: CoordinateSpace.assumedFrame(imageSize: image, scale: 2), imageSize: image)
        let urlBar = CGRect(x: 866, y: 100, width: 700, height: 60)   // pixels; its real x is 495 pt
        XCTAssertEqual(real.screenRect(fromPixels: urlBar).minX, 495, accuracy: 0.5)
        XCTAssertEqual(guess.screenRect(fromPixels: urlBar).minX, 433, accuracy: 0.5)
        XCTAssertEqual(guess.screenRect(fromPixels: urlBar).minX / real.screenRect(fromPixels: urlBar).minX, 1.75 / 2, accuracy: 0.002)
    }

    func testMeasuredScaleSnapsToRealScalesAndFlagsOddOnes() {
        XCTAssertEqual(CoordinateSpace.measuredScale(imageWidth: 3024, windowWidth: 1728), 1.75)
        XCTAssertEqual(CoordinateSpace.measuredScale(imageWidth: 2000, windowWidth: 1000), 2)
        XCTAssertEqual(CoordinateSpace.measuredScale(imageWidth: 1000, windowWidth: 1000), 1)
        XCTAssertEqual(CoordinateSpace.measuredScale(imageWidth: 1300, windowWidth: 1000)!, 1.3, accuracy: 1e-9)
        XCTAssertNil(CoordinateSpace.measuredScale(imageWidth: 100, windowWidth: 0))
        XCTAssertNil(CoordinateSpace.measuredScale(imageWidth: CGFloat.infinity, windowWidth: 10))
    }

    func testThousandthsMistakenForPixelsLandNearTheTopLeftOfTheScreen() {
        // The other suspect: a 0-1000 box read as pixels. It lands in the top-left corner and ignores the real position, which is
        // what the live run's "close window at (191,7 29x16)" looked like. The conversion must never be skipped.
        let s = space(cases[1])
        let n: [Int] = [111, 6, 128, 12]            // roughly where (191, 7) in points would sit on a 1728 pt wide window
        let wrong = s.screenRect(fromPixels: CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1]))
        let right = s.screenRect(fromPixels: s.pixelRect(fromNormalized: n.map(Double.init))!)
        XCTAssertLessThan(wrong.minX, 70)
        XCTAssertGreaterThan(right.minX, 180)
        XCTAssertNotEqual(wrong.minX, right.minX)
    }

    func testBoxesStayInsideTheWindowAcrossTheWholeChain() {
        let s = space(cases[1], longest: 960)
        for gx in stride(from: 0.0, through: 1000.0, by: 125.0) {
            for gy in stride(from: 0.0, through: 1000.0, by: 125.0) {
                guard let px = s.pixelRect(fromNormalized: [gx, gy, gx + 40, gy + 40]) else { continue }
                let screen = s.screenRect(fromPixels: px)
                XCTAssertTrue(s.windowFrame.insetBy(dx: -0.01, dy: -0.01).contains(screen), "\(gx),\(gy) -> \(screen)")
            }
        }
    }

    // MARK: CaptureGeometry and the helpers

    func testCaptureGeometryAgreesWithCoordinateSpace() {
        for c in cases {
            let s = space(c)
            let g = CaptureGeometry(windowFrame: c.frame, imageSize: s.imageSize, scale: 2)
            let px = CGRect(x: 100, y: 50, width: 40, height: 20)
            XCTAssertEqual(g.screenRect(forPixels: px), s.screenRect(fromPixels: px))
        }
    }

    func testGlimmerBoxesUseTheSharedConversion() {
        let size = CGSize(width: 3024, height: 1964)
        let r = GlimmerBoxes.pixelRect(fromThousandths: [100, 100, 200, 200], imageSize: size)!
        close(r, CGRect(x: 302.4, y: 196.4, width: 302.4, height: 196.4), 0.001)
        XCTAssertEqual(GlimmerBoxes.thousandths(forPixelRect: r, imageSize: size), [100, 100, 200, 200])
    }

    func testParseFrame() {
        XCTAssertEqual(CoordinateSpace.parseFrame("10, 20,300,400"), CGRect(x: 10, y: 20, width: 300, height: 400))
        XCTAssertNil(CoordinateSpace.parseFrame("10,20,300"))
        XCTAssertNil(CoordinateSpace.parseFrame("10,20,0,400"))
        XCTAssertNil(CoordinateSpace.parseFrame("a,b,c,d"))
        XCTAssertEqual(CoordinateSpace.assumedFrame(imageSize: CGSize(width: 400, height: 200), scale: 2), CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(CoordinateSpace.assumedFrame(imageSize: CGSize(width: 400, height: 200), scale: 0), CGRect(x: 0, y: 0, width: 400, height: 200))
    }
}
