import CoreGraphics
import XCTest
@testable import ShepCore

final class PanelGeometryTests: XCTestCase {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1440, height: 900)]

    /// An `.above` tab whose base sits on a window top edge at `edge`, left edge at `x`.
    func tab(_ x: CGFloat, edge: CGFloat) -> TabLayout {
        let rect = CGRect(x: x, y: edge, width: TabGeometry.width, height: TabGeometry.height)
        let dog = CGRect(x: x + 22, y: edge + 30 - 2 - 28, width: 40, height: 28)
        return TabLayout(style: .above, rect: rect, dogFrame: dog, barBottom: edge - DockGeometry.titleBarHeight,
                         flare: TabGeometry.flare, cornerRadius: TabGeometry.cornerRadius)
    }

    func testBubbleSitsBelowTheTitleBarAndTheTabStaysAtTheTop() {
        let t = tab(700, edge: 800)   // tab 700...784 x 800...830, bar bottom 772
        let l = PanelGeometry.layout(tab: t, screens: screens)
        XCTAssertTrue(l.bubbleBelow)
        XCTAssertEqual(l.panelFrame, CGRect(x: 582, y: 618, width: 320, height: 224))
        XCTAssertEqual(l.tabInPanel, CGRect(x: 118, y: 12, width: 84, height: 30))
        XCTAssertEqual(l.dogInPanel, CGRect(x: 140, y: 14, width: 40, height: 28))
        XCTAssertEqual(l.bubbleFrame, CGRect(x: 582, y: 618, width: 320, height: 150))
        XCTAssertEqual(l.panelFrame.maxY, 842)   // tab top 830 plus the 12 pt headroom
        XCTAssertEqual(PanelGeometry.defaultSize, CGSize(width: 320, height: 224))
    }

    func testPanelNeverLeavesTheScreenHorizontallyAndKeepsTheTabUnderItsOriginalSpot() {
        let left = PanelGeometry.layout(tab: tab(2, edge: 800), screens: screens)
        XCTAssertEqual(left.panelFrame.minX, 0)
        XCTAssertEqual(left.panelFrame.minX + left.tabInPanel.minX, 2)
        let right = PanelGeometry.layout(tab: tab(1350, edge: 800), screens: screens)
        XCTAssertEqual(right.panelFrame.maxX, 1440)
        XCTAssertEqual(right.panelFrame.minX + right.tabInPanel.minX, 1350)
    }

    func testSecondScreenIsChosenByTheTabCentre() {
        let l = PanelGeometry.layout(tab: tab(2000, edge: 800), screens: screens)
        XCTAssertGreaterThanOrEqual(l.panelFrame.minX, 1440)
        XCTAssertLessThanOrEqual(l.panelFrame.maxX, 2880)
    }

    func testNoRoomBelowFlipsTheBubbleAboveTheTab() {
        let t = tab(700, edge: 100)   // bar bottom 72: not enough room for 154
        let l = PanelGeometry.layout(tab: t, screens: screens)
        XCTAssertFalse(l.bubbleBelow)
        XCTAssertEqual(l.bubbleFrame, CGRect(x: 582, y: 134, width: 320, height: 150))
        XCTAssertEqual(l.panelFrame.maxY, l.bubbleFrame.maxY + PanelGeometry.headroom)
        XCTAssertEqual(l.tabInPanel.minY, l.panelFrame.maxY - 130)
    }

    func testTheBubbleIsInsideThePanelAndNeverCoversTheTab() {
        for edge in stride(from: CGFloat(40), through: 860, by: 40) {
            let t = tab(500, edge: edge)
            let l = PanelGeometry.layout(tab: t, screens: screens)
            XCTAssertTrue(l.panelFrame.contains(l.bubbleFrame), "edge=\(edge)")
            XCTAssertTrue(l.panelFrame.contains(t.rect), "edge=\(edge)")
            XCTAssertTrue(l.panelFrame.contains(t.dogFrame), "edge=\(edge)")
            XCTAssertFalse(l.bubbleFrame.intersects(t.rect), "edge=\(edge)")
        }
    }

    func testOnlyTheTabIsInteractiveUntilABubbleShows() {
        let l = PanelGeometry.layout(tab: tab(700, edge: 800), screens: screens)
        let idle = PanelGeometry.interactiveRects(l, bubbleVisible: false)
        XCTAssertTrue(PanelGeometry.shouldCapture(point: CGPoint(x: 740, y: 815), rects: idle))
        XCTAssertFalse(PanelGeometry.shouldCapture(point: CGPoint(x: 700, y: 700), rects: idle), "bubble area is click-through while hidden")
        XCTAssertFalse(PanelGeometry.shouldCapture(point: CGPoint(x: 580, y: 815), rects: idle), "transparent margin beside the tab")
        XCTAssertFalse(PanelGeometry.shouldCapture(point: CGPoint(x: 740, y: 790), rects: idle), "the title bar band under the tab belongs to the window")
        let shown = PanelGeometry.interactiveRects(l, bubbleVisible: true)
        XCTAssertTrue(PanelGeometry.shouldCapture(point: CGPoint(x: 700, y: 700), rects: shown))
        XCTAssertFalse(PanelGeometry.shouldCapture(point: CGPoint(x: 100, y: 100), rects: shown))
    }

    func testHeadroomIsDroppedWhereTheScreenEnds() {
        let t = tab(700, edge: 880)   // tab top 910 is past a 900 pt screen: no room for headroom
        let l = PanelGeometry.layout(tab: t, screens: screens)
        XCTAssertEqual(l.panelFrame.maxY, t.rect.maxY)
        let near = PanelGeometry.layout(tab: tab(700, edge: 862), screens: screens)   // tab top 892: 8 pt left
        XCTAssertEqual(near.panelFrame.maxY, 900)
    }

    // The web page is top-left origin, the panel bottom-left. These pin the conversion the dock log relies on.
    func testWebRectConvertsToScreenRectBySubtractingFromThePanelTop() {
        let l = PanelGeometry.layout(tab: tab(700, edge: 800), screens: screens)
        let s = PanelGeometry.dogScreenRect(l)
        XCTAssertEqual(s, CGRect(x: 722, y: 800, width: 40, height: 28))   // the tab's dogFrame, recovered from the web rect
        XCTAssertEqual(s, l.tab.dogFrame)
        XCTAssertEqual(PanelGeometry.screenRect(fromPanel: CGRect(x: 0, y: 0, width: 10, height: 10), in: l.panelFrame),
                       CGRect(x: l.panelFrame.minX, y: l.panelFrame.maxY - 10, width: 10, height: 10))
    }

    func testDogLiesInsideTheTabOnScreen() {
        for edge in stride(from: CGFloat(60), through: 840, by: 60) {
            let l = PanelGeometry.layout(tab: tab(500, edge: edge), screens: screens)
            XCTAssertTrue(PanelGeometry.dogIsInsideTab(l), "edge=\(edge)")
        }
        // A dog drawn at the web view's top-left corner (the unplaced state in the failing screenshot) is not in the tab.
        var l = PanelGeometry.layout(tab: tab(700, edge: 800), screens: screens)
        l.dogInPanel = CGRect(x: 0, y: 0, width: 40, height: 28)
        XCTAssertFalse(PanelGeometry.dogIsInsideTab(l))
        // Flipping y by mistake (distance from the bottom) puts it outside too.
        var f = PanelGeometry.layout(tab: tab(700, edge: 800), screens: screens)
        f.dogInPanel = CGRect(x: 140, y: f.panelFrame.height - 14 - 28, width: 40, height: 28)
        XCTAssertFalse(PanelGeometry.dogIsInsideTab(f))
    }
}
