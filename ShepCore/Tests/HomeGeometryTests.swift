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

    func testNotchIndicatorIsAChinExactlyAsWideAsTheNotchHangingFromTheMenuBar() {
        let p = HomeGeometry.place(screens: [notchScreen], statusItem: CGRect(x: 1200, y: 950, width: 30, height: 32))
        XCTAssertEqual(p?.kind, .notch)   // the notch wins over the status item
        // The notch is 856 - 656 = 200 wide; the chin is that wide, its top edge is the menu bar's bottom edge.
        XCTAssertEqual(p?.rect, CGRect(x: 656, y: 950 - HomeGeometry.chinHeight, width: 200, height: HomeGeometry.chinHeight))
        XCTAssertEqual(p?.rect.midX ?? 0, 756, accuracy: 1e-9)
        XCTAssertEqual(p?.rect.maxY ?? 0, 950, accuracy: 1e-9)
    }

    func testRealNotchValuesOfAFourteenInchDisplay() {
        let p = HomeGeometry.place(screens: [.exampleNotched], statusItem: nil)
        XCTAssertEqual(p?.kind, .notch)
        XCTAssertEqual(p?.rect, CGRect(x: 663.5, y: 950 - HomeGeometry.chinHeight, width: 185, height: HomeGeometry.chinHeight))
        XCTAssertEqual(p?.rect.midX ?? 0, 756, accuracy: 1e-9)
    }

    func testChinNeverTouchesTheMenuBarSoItCoversNoMenuItemAndNoStatusItem() {
        let s = HomeScreen.exampleNotched
        let p = HomeGeometry.place(screens: [s], statusItem: nil)!
        XCTAssertLessThanOrEqual(p.rect.maxY, s.auxLeft!.minY)    // entirely below the menu bar's lower edge
        XCTAssertLessThanOrEqual(p.rect.maxY, s.auxRight!.minY)
        XCTAssertGreaterThanOrEqual(p.rect.minX, s.auxLeft!.maxX)   // and between the two strips of menu-bar items, not under them
        XCTAssertLessThanOrEqual(p.rect.maxX, s.auxRight!.minX)
        XCTAssertGreaterThanOrEqual(HomeGeometry.chinHeight, 14)   // as short as legibility allows: 14 to 16 pt
        XCTAssertLessThanOrEqual(HomeGeometry.chinHeight, 16)
    }

    func testChinStaysOnAScreenWhoseNotchIsAtTheBottomOfTheWorld() {
        let s = HomeScreen(frame: CGRect(x: 0, y: 0, width: 400, height: 20), visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 8),
                           auxLeft: CGRect(x: 0, y: 5, width: 150, height: 15), auxRight: CGRect(x: 250, y: 5, width: 150, height: 15))
        let p = HomeGeometry.place(screens: [s], statusItem: nil)!
        XCTAssertGreaterThanOrEqual(p.rect.minY, 0)
    }

    func testNoNotchPutsAPillJustUnderTheMenuBarAtTopCentre() {
        let p = HomeGeometry.place(screens: [plain], statusItem: CGRect(x: 1200, y: 875, width: 30, height: 25))
        XCTAssertEqual(p?.kind, .topCenter)   // the status item no longer moves it, only picks the screen
        XCTAssertEqual(p?.rect, CGRect(x: 690, y: 857, width: 60, height: 18))
        XCTAssertEqual(p?.rect.maxY ?? 0, 875, accuracy: 1e-9)   // its top edge is the bar's bottom edge
    }

    func testTopCentreOnAScreenWhoseMenuBarHides() {
        let hidden = HomeScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(HomeGeometry.place(screens: [hidden], statusItem: nil)?.rect, CGRect(x: 690, y: 882, width: 60, height: 18))
    }

    func testTinyScreenKeepsThePillOnScreen() {
        let tiny = HomeScreen(frame: CGRect(x: 0, y: 0, width: 40, height: 10), visibleFrame: CGRect(x: 0, y: 0, width: 40, height: 10))
        let p = HomeGeometry.place(screens: [tiny], statusItem: nil)!
        XCTAssertGreaterThanOrEqual(p.rect.minY, 0)
        XCTAssertGreaterThanOrEqual(p.rect.minX, 0)
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
        XCTAssertEqual(p?.kind, .topCenter)
        XCTAssertEqual(p?.screenFrame, b.frame)
        XCTAssertEqual(p?.rect.midX ?? 0, 1440 + 960, accuracy: 1e-9)
        XCTAssertEqual(p?.rect.maxY ?? 0, 1055, accuracy: 1e-9)
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

    func testDoorIsTheMiddleOfTheBottomEdgeSoTheDogLeavesDownward() {
        let rect = CGRect(x: 100, y: 200, width: 185, height: 15)
        XCTAssertEqual(HomeGeometry.door(in: rect), CGPoint(x: 192.5, y: 200))
        XCTAssertEqual(HomePlacement(kind: .notch, rect: rect, screenFrame: .zero).door, CGPoint(x: 192.5, y: 200))
        let p = HomeGeometry.place(screens: [.exampleNotched], statusItem: nil)!
        XCTAssertEqual(p.door, CGPoint(x: 756, y: 950 - HomeGeometry.chinHeight))   // the chin's bottom edge, centred under the notch
    }

    func testPlacementKnowsItsCornerRadius() {
        let n = HomePlacement(kind: .notch, rect: .zero, screenFrame: .zero)
        let t = HomePlacement(kind: .topCenter, rect: .zero, screenFrame: .zero)
        XCTAssertEqual(n.cornerRadius, HomeGeometry.notchCornerRadius)
        XCTAssertEqual(t.cornerRadius, HomeGeometry.topCenterCornerRadius)
    }

    func testIconSlotsSitInTheTwoHalvesOfTheChinAndAreVerticallyCentred() {
        let chin = HomeGeometry.iconSlots(kind: .notch, size: CGSize(width: 185, height: HomeGeometry.chinHeight))
        XCTAssertEqual(chin.left.midX, HomeGeometry.chinIconInset + HomeGeometry.notchIconSize / 2, accuracy: 1e-9)
        XCTAssertEqual(chin.right.midX, 185 - HomeGeometry.chinIconInset - HomeGeometry.notchIconSize / 2, accuracy: 1e-9)
        XCTAssertEqual(chin.left.midY, HomeGeometry.chinHeight / 2, accuracy: 1e-9)
        XCTAssertEqual(chin.left.width, HomeGeometry.notchIconSize)
        XCTAssertLessThanOrEqual(chin.left.height, HomeGeometry.chinHeight - 2)   // the mark fits inside the chin with a point to spare
        XCTAssertFalse(chin.left.intersects(chin.right))
        let top = HomeGeometry.iconSlots(kind: .topCenter, size: HomeGeometry.topCenterSize)
        XCTAssertEqual(top.left.midX, 15, accuracy: 1e-9)
        XCTAssertEqual(top.right.midX, 45, accuracy: 1e-9)
        XCTAssertEqual(top.left.midY, 9, accuracy: 1e-9)
        XCTAssertFalse(top.left.intersects(top.right))
    }

    func testTheIndicatorNeverTakesTheMouse() {
        XCTAssertFalse(HomeGeometry.takesMouse(kind: .notch))
        XCTAssertFalse(HomeGeometry.takesMouse(kind: .topCenter))
    }

    func testTheNotchStripIsFullyOpaqueAndThePillIsALittleSofter() {
        XCTAssertEqual(HomeGeometry.restingAlpha(for: .notch), 1)
        XCTAssertGreaterThan(HomeGeometry.restingAlpha(for: .topCenter), 0.8)
        XCTAssertLessThan(HomeGeometry.restingAlpha(for: .topCenter), 1)
    }

    func testLogLineUsesTopLeftCoordinates() {
        let p = HomePlacement(kind: .notch, rect: CGRect(x: 663.5, y: 935, width: 185, height: 15), screenFrame: .zero)
        XCTAssertEqual(p.logDescription(primaryScreenHeight: 982), "kind=notch rect=664,32,185,15")
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
