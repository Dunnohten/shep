import XCTest
@testable import ShepCore

final class DockPlannerTests: XCTestCase {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    let own: Int32 = 777

    func plan(_ o: WindowObservation?) -> DockPlan {
        DockPlanner.plan(o, ownPID: own, screens: screens, primaryScreenHeight: 900)
    }

    func testNormalWindowGetsATabOnItsTopEdge() {
        // AX top-left (200, 100), 800x500 -> Cocoa top edge y = 800.
        let p = plan(WindowObservation(pid: 1, bundleID: "com.example.app", axFrame: CGRect(x: 200, y: 100, width: 800, height: 500), subrole: "AXStandardWindow"))
        guard case .tab(let l) = p.placement else { return XCTFail("\(p)") }
        XCTAssertEqual(l.style, .above)
        XCTAssertEqual(l.rect.minY, 800)   // the tab's base is the window's top edge
    }

    func testNoObservationHides() {
        XCTAssertEqual(plan(nil).placement, .hidden)
    }

    func testOwnWindowsAreIgnored() {
        let o = WindowObservation(pid: own, bundleID: "dev.shep.app", axFrame: CGRect(x: 200, y: 100, width: 800, height: 500))
        XCTAssertEqual(plan(o).placement, .hidden)
    }

    func testFinderDesktopHasNoFocusedWindow() {
        let o = WindowObservation(pid: 2, bundleID: "com.apple.finder", axFrame: nil)
        XCTAssertEqual(plan(o).placement, .hidden)
    }

    func testFinderWindowDocks() {
        let o = WindowObservation(pid: 2, bundleID: "com.apple.finder", axFrame: CGRect(x: 300, y: 200, width: 700, height: 450), subrole: "AXStandardWindow")
        XCTAssertNotEqual(plan(o).placement, .hidden)
    }

    func testDockAndSystemUIAreIgnored() {
        for id in ["com.apple.dock", "com.apple.loginwindow", "com.apple.Spotlight"] {
            let o = WindowObservation(pid: 3, bundleID: id, axFrame: CGRect(x: 0, y: 0, width: 800, height: 500))
            XCTAssertEqual(plan(o).placement, .hidden, id)
        }
    }

    func testFloatingPanelsAreNotDockable() {
        let o = WindowObservation(pid: 4, bundleID: "com.example.app", axFrame: CGRect(x: 200, y: 100, width: 800, height: 500), subrole: "AXFloatingWindow")
        XCTAssertEqual(plan(o).placement, .hidden)
        XCTAssertTrue(DockPlanner.isDockableSubrole(nil))
        XCTAssertTrue(DockPlanner.isDockableSubrole(""))
        XCTAssertTrue(DockPlanner.isDockableSubrole("AXDialog"))
        XCTAssertFalse(DockPlanner.isDockableSubrole("AXSystemDialog"))
    }

    func testFullScreenHidesTheTab() {
        let o = WindowObservation(pid: 5, bundleID: "com.example.app", axFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), isFullScreen: true, subrole: "AXStandardWindow")
        XCTAssertEqual(plan(o).placement, .hidden)
    }

    func testMenuBarIsNotRoomAbove() {
        // Window top 10 pt under the menu bar (usable height 876): the tab hangs inside the bar instead.
        let o = WindowObservation(pid: 8, bundleID: "com.example.app", axFrame: CGRect(x: 200, y: 34, width: 800, height: 500), subrole: "AXStandardWindow")
        let p = DockPlanner.plan(o, ownPID: own, screens: screens, usable: [CGRect(x: 0, y: 0, width: 1440, height: 876)], primaryScreenHeight: 900)
        XCTAssertEqual(p.placement.layout?.style, .inside)
    }

    func testPlannerClearsAMeasuredToolbarAndEstimatesAnUnmeasuredTitle() {
        // AX frames (top-left origin): window at (200,100) 800x500; a toolbar button at the right end of the bar.
        let button = CGRect(x: 920, y: 104, width: 60, height: 22)
        let o = WindowObservation(pid: 6, bundleID: "com.example.app", axFrame: CGRect(x: 200, y: 100, width: 800, height: 500),
                                  subrole: "AXStandardWindow", title: "Notes", titleBarFrames: [button], titleMeasured: false)
        guard case .tab(let l) = plan(o).placement else { return XCTFail() }
        XCTAssertLessThanOrEqual(l.rect.maxX, 920 - TabGeometry.obstacleGap)
        XCTAssertEqual(l.rect.minY, 800)
    }

    func testATitleEstimateStaysClearOfTheTabWhenThereIsRoom() {
        // A centred title in a wide window: the tab at the right end clears the estimated text.
        let title = "A reasonably long document title — Saved"
        for width in [800.0, 1200.0, 1400.0] {
            let ax = CGRect(x: 0, y: 100, width: CGFloat(width), height: 400)
            let cocoa = AXCoordinates.cocoaRect(fromAX: ax, primaryScreenHeight: 900)
            guard let guess = DockGeometry.estimatedTitleExtent(title: title, window: cocoa) else { continue }
            let o = WindowObservation(pid: 7, bundleID: "com.example.app", axFrame: ax, subrole: "AXStandardWindow", title: title)
            guard let l = plan(o).placement.layout else { XCTFail("width \(width)"); continue }
            XCTAssertTrue(l.rect.maxX <= guess.minX || l.rect.minX >= guess.maxX, "width \(width)")
        }
    }

    func testAVeryLongTitleStillGetsATabAtTheFixedInset() {
        // The clamped estimate fills the bar; the tab keeps its right-end slot rather than vanishing.
        let title = String(repeating: "long title ", count: 20)
        let o = WindowObservation(pid: 9, bundleID: "com.example.app", axFrame: CGRect(x: 200, y: 100, width: 800, height: 500),
                                  subrole: "AXStandardWindow", title: title)
        XCTAssertEqual(plan(o).placement.layout?.rect.maxX, 1000 - TabGeometry.rightInset)
    }
}
