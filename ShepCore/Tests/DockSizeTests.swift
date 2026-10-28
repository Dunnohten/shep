import CoreGraphics
import XCTest
@testable import ShepCore

/// The first real docked screenshot showed a head far larger than the tab: nothing asserted the size that reaches the screen.
/// These tests pin the rendered head size and the panel / web view frames for a typical window.
final class DockSizeTests: XCTestCase {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    let usable = [CGRect(x: 0, y: 0, width: 1440, height: 876)]

    /// A typical TextEdit-sized window with room above it (top edge 200 pt below the screen top).
    func typicalLayout() -> PanelLayout {
        let window = CGRect(x: 200, y: 900 - 200 - 600, width: 610, height: 600)
        guard case .tab(let tab) = TabGeometry.place(window: window, isFullScreen: false, screens: screens, usable: usable) else {
            XCTFail("expected a tab"); return PanelGeometry.layout(tab: TabLayout(style: .above, rect: .zero, dogFrame: .zero, barBottom: 0, flare: 0, cornerRadius: 0), screens: screens)
        }
        return PanelGeometry.layout(tab: tab, screens: screens)
    }

    func testRenderedArtIsAboutTwentyEightPointsTallAndFitsTheTab() {
        let l = typicalLayout()
        let art = TabGeometry.renderedArt(in: l.dogInPanel)
        XCTAssertEqual(art.height, 28, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(art.height, 26)
        XCTAssertLessThanOrEqual(art.height, 30)
        XCTAssertLessThanOrEqual(art.width, 42)
        // The head peeks up: the art may rise above the tab's top by the peek, and nowhere else leaves the tab.
        XCTAssertGreaterThanOrEqual(art.minX, l.tabInPanel.minX)
        XCTAssertLessThanOrEqual(art.maxX, l.tabInPanel.maxX)
        XCTAssertLessThanOrEqual(art.maxY, l.tabInPanel.maxY)
        XCTAssertGreaterThanOrEqual(art.minY, l.tabInPanel.minY - TabGeometry.dogPeek)
    }

    func testRenderedHeadBodyIsSmallComparedWithTheTabBody() {
        let head = TabGeometry.renderedHead(in: typicalLayout().dogInPanel)
        XCTAssertLessThan(head.width, TabGeometry.bodyWidth)
        XCTAssertLessThan(head.height, TabGeometry.height)
        XCTAssertGreaterThan(head.height, 18)
    }

    func testDogIsCentredInTheTabBody() {
        let l = typicalLayout()
        XCTAssertEqual(l.dogInPanel.midX, l.tabInPanel.midX, accuracy: 0.5)
    }

    func testPanelAndWebViewFramesForATypicalWindow() {
        let l = typicalLayout()
        XCTAssertEqual(l.panelFrame.size, PanelGeometry.defaultSize)
        XCTAssertEqual(l.webViewFrame, CGRect(x: 0, y: 0, width: 320, height: 224))
        XCTAssertEqual(l.tabInPanel.size, CGSize(width: 84, height: 30))
        XCTAssertEqual(l.dogInPanel.size, DockGeometry.dogSize)
        // The page must never be able to size the dog to the whole web view.
        XCTAssertLessThan(l.dogInPanel.width, l.webViewFrame.width / 4)
        XCTAssertLessThan(l.dogInPanel.height, l.webViewFrame.height / 4)
        // Panel top is the tab top plus the headroom; the tab's base touches the window's top edge.
        XCTAssertEqual(l.panelFrame.maxY, l.tab.rect.maxY + PanelGeometry.headroom)
        XCTAssertEqual(l.tab.rect.minY, 700, accuracy: 0.001)   // window top edge: 900 - 200
    }

    func testTabSitsInsideTheWindowHorizontally() {
        let l = typicalLayout()
        XCTAssertGreaterThanOrEqual(l.tab.rect.minX, 200 + DockGeometry.trafficLightInset)
        XCTAssertLessThanOrEqual(l.tab.rect.maxX, 200 + 610 - TabGeometry.rightInset + 0.001)
    }

    func testWindowCloseUnderTheMenuBarHangsInsideTheBar() {
        // The failing screenshot: the window's top edge 22 pt under the menu bar, less than the 30 pt the tab needs.
        let window = CGRect(x: 200, y: 876 - 22 - 600, width: 610, height: 600)
        guard case .tab(let tab) = TabGeometry.place(window: window, isFullScreen: false, screens: screens, usable: usable) else { return XCTFail("expected a tab") }
        XCTAssertEqual(tab.style, .inside)
        XCTAssertLessThanOrEqual(tab.rect.maxY, usable[0].maxY)
        XCTAssertTrue(tab.rect.contains(tab.dogFrame))
    }

    func testLogLineNamesTabPanelWebViewAndHead() {
        let line = typicalLayout().logDescription
        XCTAssertTrue(line.contains("tab=("))
        XCTAssertTrue(line.contains("panel=("))
        XCTAssertTrue(line.contains("webview=(0,0 320x224)"))
        XCTAssertTrue(line.contains("head="))
    }

    func testDogIsInsideTheTabAndLogSaysSo() {
        let l = typicalLayout()
        XCTAssertTrue(PanelGeometry.dogIsInsideTab(l))
        XCTAssertTrue(l.logDescription.contains("dogInTab=yes"))
        // Head centred in the tab, peeking up: its box rises above the tab's top, but no further than the peek.
        let d = PanelGeometry.dogScreenRect(l)
        XCTAssertEqual(d.midX, l.tab.rect.midX, accuracy: 0.5)
        XCTAssertGreaterThan(d.maxY, l.tab.rect.maxY - TabGeometry.dogPeek)
        XCTAssertLessThanOrEqual(d.maxY, l.tab.rect.maxY + TabGeometry.dogPeek)
    }
}
