import XCTest
@testable import ShepCore

final class DockGeometryTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    func testTitleEstimateIsClampedAndEmptyTitlesHaveNone() {
        let w = CGRect(x: 0, y: 100, width: 400, height: 300)
        XCTAssertNil(DockGeometry.estimatedTitleExtent(title: "   ", window: w))
        let long = DockGeometry.estimatedTitleExtent(title: String(repeating: "x", count: 500), window: w)!
        XCTAssertEqual(long.width, 400 - 2 * (DockGeometry.trafficLightInset + DockGeometry.edgeMargin))
        XCTAssertNil(DockGeometry.estimatedTitleExtent(title: "Hi", window: CGRect(x: 0, y: 0, width: 150, height: 300)))
    }

    func testScreenIndexPicksLargestOverlapAndNilWhenNone() {
        XCTAssertEqual(DockGeometry.screenIndex(for: CGRect(x: 1400, y: 0, width: 200, height: 100), in: [main, right]), 1)
        XCTAssertEqual(DockGeometry.screenIndex(for: CGRect(x: 1300, y: 0, width: 200, height: 100), in: [main, right]), 0)
        XCTAssertNil(DockGeometry.screenIndex(for: CGRect(x: 9000, y: 0, width: 10, height: 10), in: [main, right]))
        XCTAssertNil(DockGeometry.screenIndex(for: CGRect(x: 1440, y: 0, width: 0, height: 0), in: [main]))
    }

    func testAXToCocoaConversion() {
        // Window whose top-left is (100, 50) in AX space and is 400x300, on a 900-high primary screen.
        let c = AXCoordinates.cocoaRect(fromAX: CGRect(x: 100, y: 50, width: 400, height: 300), primaryScreenHeight: 900)
        XCTAssertEqual(c, CGRect(x: 100, y: 550, width: 400, height: 300))
        XCTAssertEqual(c.maxY, 850)   // top edge sits 50 below the top of the screen
        // Window on a screen above the primary one has negative AX y.
        let above = AXCoordinates.cocoaRect(fromAX: CGRect(x: 0, y: -700, width: 500, height: 600), primaryScreenHeight: 900)
        XCTAssertEqual(above.minY, 1000)
        XCTAssertEqual(above.maxY, 1600)
    }
}
