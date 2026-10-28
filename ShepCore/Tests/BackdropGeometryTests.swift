import XCTest
@testable import ShepCore

final class BackdropGeometryTests: XCTestCase {
    // One 1440 x 900 screen; the menu bar takes the top 25 points, so the usable area ends at y = 875 (Cocoa, y up).
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let usable = CGRect(x: 0, y: 0, width: 1440, height: 875)

    func testCoversEveryInputPlusTheMargin() throws {
        let house = CGRect(x: 600, y: 760, width: 96, height: 84)
        let window = CGRect(x: 560, y: 300, width: 400, height: 300)
        let tab = CGRect(x: 700, y: 600, width: 84, height: 30)
        let corridor = CGRect(x: 580, y: 590, width: 200, height: 180)
        let r = try XCTUnwrap(BackdropGeometry.rect(covering: [house, window, tab, corridor], usable: [usable]))
        for part in [house, window, tab, corridor] { XCTAssertTrue(r.contains(part), "\(part)") }
        XCTAssertLessThanOrEqual(r.minX, window.minX - BackdropGeometry.margin)
        XCTAssertLessThanOrEqual(r.minY, window.minY - BackdropGeometry.margin)
    }

    func testNeverReachesIntoTheMenuBar() throws {
        let house = CGRect(x: 600, y: 790, width: 96, height: 84)   // its top edge touches the usable top
        let r = try XCTUnwrap(BackdropGeometry.rect(covering: [house], usable: [usable]))
        XCTAssertLessThanOrEqual(r.maxY, usable.maxY)
        XCTAssertEqual(r.maxY, usable.maxY)
    }

    func testClippedToTheScreenEdges() throws {
        let r = try XCTUnwrap(BackdropGeometry.rect(covering: [CGRect(x: 2, y: 3, width: 50, height: 50)], usable: [usable]))
        XCTAssertGreaterThanOrEqual(r.minX, 0); XCTAssertGreaterThanOrEqual(r.minY, 0)
    }

    func testWholePoints() throws {
        let r = try XCTUnwrap(BackdropGeometry.rect(covering: [CGRect(x: 100.4, y: 200.6, width: 50.3, height: 40.2)], usable: [usable]))
        for v in [r.minX, r.minY, r.width, r.height] { XCTAssertEqual(v, v.rounded()) }
        XCTAssertTrue(r.contains(CGRect(x: 100.4, y: 200.6, width: 50.3, height: 40.2)))
    }

    func testTwoScreensKeepBothPieces() throws {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let r = try XCTUnwrap(BackdropGeometry.rect(covering: [CGRect(x: 1400, y: 300, width: 100, height: 100)], usable: [usable, second]))
        XCTAssertLessThan(r.minX, 1440); XCTAssertGreaterThan(r.maxX, 1440)
    }

    func testNothingUsableIsNil() {
        XCTAssertNil(BackdropGeometry.rect(covering: [], usable: [usable]))
        XCTAssertNil(BackdropGeometry.rect(covering: [CGRect(x: 5000, y: 5000, width: 10, height: 10)], usable: [usable]))
        XCTAssertNil(BackdropGeometry.rect(covering: [CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)], usable: [usable]))
        XCTAssertNil(BackdropGeometry.rect(covering: [CGRect(x: 1, y: 1, width: 10, height: 10)], usable: []))
    }

    func testLogStringIsTopLeft() {
        // Cocoa (100, 700) 200 x 100 on a 900-high primary screen: top edge at 900 - 800 = 100.
        XCTAssertEqual(BackdropGeometry.logString(CGRect(x: 100, y: 700, width: 200, height: 100), primaryScreenHeight: 900), "100,100,200,100")
    }
}
