import CoreGraphics
import XCTest
@testable import ShepCore

final class HomeGeometryTests: XCTestCase {
    private let notchScreen = HomeScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                         auxLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
                                         auxRight: CGRect(x: 856, y: 950, width: 656, height: 32))
    private let plain = HomeScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))

    func testNotchPutsTheHouseJustBelowItsCentre() {
        let p = HomeGeometry.place(screens: [notchScreen], statusItem: CGRect(x: 1200, y: 950, width: 30, height: 32))
        XCTAssertEqual(p?.kind, .notch)   // the notch wins over the status item
        XCTAssertEqual(p?.rect, CGRect(x: 708, y: 864, width: 96, height: 84))   // centre 756, top = 950 - 2
        XCTAssertEqual(p?.rect.midX ?? 0, 756, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(p?.rect.maxY ?? 999, 950)
    }

    func testNoNotchUsesTheStatusItem() {
        let p = HomeGeometry.place(screens: [plain], statusItem: CGRect(x: 1200, y: 875, width: 30, height: 25))
        XCTAssertEqual(p?.kind, .statusItem)
        XCTAssertEqual(p?.rect, CGRect(x: 1167, y: 789, width: 96, height: 84))
        XCTAssertLessThan(p?.rect.maxY ?? 999, 875)   // below the menu bar
    }

    func testStatusItemAtTheScreenEdgeKeepsTheHouseOnScreen() {
        let p = HomeGeometry.place(screens: [plain], statusItem: CGRect(x: 1420, y: 875, width: 20, height: 25))
        XCTAssertEqual(p?.rect.maxX ?? 0, 1440 - HomeGeometry.edgeMargin, accuracy: 1e-9)
        let left = HomeGeometry.place(screens: [plain], statusItem: CGRect(x: 0, y: 875, width: 20, height: 25))
        XCTAssertEqual(left?.rect.minX ?? -1, HomeGeometry.edgeMargin, accuracy: 1e-9)
    }

    func testWithoutNotchOrStatusItemFallsBackToTopCentre() {
        let p = HomeGeometry.place(screens: [plain], statusItem: nil)
        XCTAssertEqual(p?.kind, .topCenter)
        XCTAssertEqual(p?.rect, CGRect(x: 672, y: 789, width: 96, height: 84))
        let empty = HomeGeometry.place(screens: [plain], statusItem: .zero)
        XCTAssertEqual(empty?.kind, .topCenter)
    }

    func testNoScreensNoHouse() {
        XCTAssertNil(HomeGeometry.place(screens: [], statusItem: nil))
        XCTAssertNil(HomeGeometry.screenIndex(screens: [], statusItem: nil))
    }

    func testPerScreenTheStatusItemsScreenHostsTheHouse() {
        let a = HomeScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let b = HomeScreen(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let item = CGRect(x: 2500, y: 1055, width: 30, height: 25)
        XCTAssertEqual(HomeGeometry.screenIndex(screens: [a, b], statusItem: item), 1)
        let p = HomeGeometry.place(screens: [a, b], statusItem: item)
        XCTAssertEqual(p?.kind, .statusItem)
        XCTAssertEqual(p?.screenFrame, b.frame)
        XCTAssertGreaterThanOrEqual(p?.rect.minX ?? 0, 1440)
        XCTAssertEqual(p?.rect.maxY ?? 0, 1055 - HomeGeometry.gap, accuracy: 1e-9)
        // No status item known: the first screen.
        XCTAssertEqual(HomeGeometry.place(screens: [a, b], statusItem: nil)?.screenFrame, a.frame)
    }

    func testNotchOnTheSecondScreenIsUsedWhenTheItemIsThere() {
        let b = HomeScreen(frame: CGRect(x: 1440, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 1440, y: 0, width: 1512, height: 950),
                           auxLeft: CGRect(x: 1440, y: 950, width: 656, height: 32), auxRight: CGRect(x: 2296, y: 950, width: 656, height: 32))
        let p = HomeGeometry.place(screens: [plain, b], statusItem: CGRect(x: 2800, y: 950, width: 30, height: 32))
        XCTAssertEqual(p?.kind, .notch)
        XCTAssertEqual(p?.rect.midX ?? 0, 2196, accuracy: 1e-9)
    }

    func testBrokenAuxiliaryAreasAreNotANotch() {
        var s = plain
        s.auxLeft = CGRect(x: 0, y: 875, width: 700, height: 25)
        s.auxRight = CGRect(x: 600, y: 875, width: 840, height: 25)   // overlaps: no gap
        XCTAssertNil(s.notch)
        s.auxRight = nil
        XCTAssertNil(s.notch)
        XCTAssertEqual(HomeGeometry.place(screens: [s], statusItem: nil)?.kind, .topCenter)
    }

    func testDoorIsInsideTheHouseAndRoughlyCentred() {
        let rect = CGRect(x: 100, y: 200, width: 96, height: 84)
        let door = HomeGeometry.door(in: rect)
        XCTAssertEqual(door.x, 148, accuracy: 1e-9)
        XCTAssertEqual(door.y, 224, accuracy: 1e-9)
        XCTAssertTrue(rect.contains(door))
        XCTAssertEqual(HomePlacement(kind: .notch, rect: rect, screenFrame: .zero).door, door)
        // The door is on the house's body, in the panel's own (top-left) space.
        XCTAssertTrue(HomeGeometry.isOnHouse(HomeGeometry.doorCenterInArt))
    }

    func testHitShapeIsTheHouseNotThePanel() {
        XCTAssertTrue(HomeGeometry.isOnHouse(CGPoint(x: 48, y: 50)))   // body
        XCTAssertTrue(HomeGeometry.isOnHouse(CGPoint(x: 48, y: 20)))   // near the roof's peak
        XCTAssertTrue(HomeGeometry.isOnHouse(CGPoint(x: 80, y: 70)))
        XCTAssertFalse(HomeGeometry.isOnHouse(CGPoint(x: 82, y: 70)))
        XCTAssertFalse(HomeGeometry.isOnHouse(CGPoint(x: 10, y: 20)))  // empty corner above the roof's eave
        XCTAssertFalse(HomeGeometry.isOnHouse(CGPoint(x: 50, y: 2)))   // above the peak
        XCTAssertFalse(HomeGeometry.isOnHouse(CGPoint(x: 4, y: 60)))
        XCTAssertFalse(HomeGeometry.isOnHouse(CGPoint(x: 88, y: 40)))
    }

    func testLogLineUsesTopLeftCoordinates() {
        let p = HomePlacement(kind: .notch, rect: CGRect(x: 708, y: 864, width: 96, height: 84), screenFrame: .zero)
        XCTAssertEqual(p.logDescription(primaryScreenHeight: 982), "kind=notch rect=708,34,96,84")
    }

    func testAuxiliaryAreasInScreenLocalCoordinatesAreShiftedToGlobal() {
        let frame = CGRect(x: 1440, y: 0, width: 1512, height: 982)
        let local = CGRect(x: 0, y: 950, width: 656, height: 32)
        XCTAssertEqual(HomeScreen.normalizedAux(local, in: frame), CGRect(x: 1440, y: 950, width: 656, height: 32))
        let global = CGRect(x: 1440, y: 950, width: 656, height: 32)
        XCTAssertEqual(HomeScreen.normalizedAux(global, in: frame), global)
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(HomeScreen.normalizedAux(local, in: primary), local)
        XCTAssertNil(HomeScreen.normalizedAux(nil, in: frame))
        XCTAssertNil(HomeScreen.normalizedAux(.zero, in: frame))
    }
}
