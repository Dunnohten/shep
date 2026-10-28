import XCTest
@testable import ShepCore

final class TabGeometryTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let mainUsable = CGRect(x: 0, y: 0, width: 1440, height: 876)      // 24 pt menu bar
    let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let left = CGRect(x: -1280, y: 100, width: 1280, height: 1024)    // negative origin, offset vertically
    let bar = DockGeometry.titleBarHeight

    func tab(_ p: TabPlacement, file: StaticString = #filePath, line: UInt = #line) -> TabLayout {
        guard case .tab(let l) = p else { XCTFail("expected a tab, got \(p)", file: file, line: line); return TabLayout(style: .above, rect: .zero, dogFrame: .zero, barBottom: 0, flare: 0, cornerRadius: 0) }
        return l
    }

    func place(_ w: CGRect, screens: [CGRect]? = nil, usable: [CGRect]? = nil, obstacles: [CGRect] = [], fullScreen: Bool = false) -> TabPlacement {
        TabGeometry.place(window: w, isFullScreen: fullScreen, screens: screens ?? [main], usable: usable, obstacles: obstacles)
    }

    /// True when the two rectangles do not overlap in x (edge contact counts as clear; CGRect.intersects is not relied on).
    func clearsHorizontally(_ a: CGRect, _ b: CGRect) -> Bool { a.maxX <= b.minX || a.minX >= b.maxX }

    // MARK: size and position

    func testTabRisesAboveTheTopEdgeAndItsBaseIsTheEdge() {
        let w = CGRect(x: 200, y: 300, width: 800, height: 500)   // top edge y = 800
        let l = tab(place(w))
        XCTAssertEqual(l.style, .above)
        XCTAssertEqual(l.rect.size, CGSize(width: 84, height: 30))
        XCTAssertEqual(l.rect.minY, 800)
        XCTAssertEqual(l.rect.maxY, 830)
        XCTAssertEqual(l.barBottom, 800 - bar)
    }

    func testTabSitsAtTheRightEndByDefault() {
        let w = CGRect(x: 100, y: 100, width: 1000, height: 600)
        let l = tab(place(w))
        XCTAssertEqual(l.rect.maxX, w.maxX - TabGeometry.rightInset)
        XCTAssertGreaterThan(l.rect.midX, w.midX)
    }

    func testDogIsCentredInTheBodyAndInsideTheTab() {
        let l = tab(place(CGRect(x: 100, y: 100, width: 1000, height: 600)))
        XCTAssertGreaterThanOrEqual(l.dogFrame.minX, l.rect.minX)
        XCTAssertLessThanOrEqual(l.dogFrame.maxX, l.rect.maxX)
        XCTAssertGreaterThanOrEqual(l.dogFrame.minY, l.rect.minY)
        XCTAssertLessThanOrEqual(l.dogFrame.maxY, l.rect.maxY + TabGeometry.dogPeek)   // the head peeks up
        XCTAssertEqual(l.dogFrame.midX, l.rect.midX, accuracy: 0.001)
        XCTAssertEqual(l.dogFrame.size, DockGeometry.dogSize)
    }

    func testTabClearsTheTitleTextAndToolbar() {
        let w = CGRect(x: 62, y: 100, width: 1168, height: 600)
        let title = DockGeometry.estimatedTitleExtent(title: "Quarterly Report Review Notes — Edited", window: w)!
        let l = tab(place(w, obstacles: [title]))
        XCTAssertTrue(clearsHorizontally(l.rect, title))
        let top = w.maxY - 24
        let buttons = [CGRect(x: 1100, y: top, width: 48, height: 22), CGRect(x: 1040, y: top, width: 50, height: 22)]
        let l2 = tab(place(w, obstacles: buttons))
        for b in buttons { XCTAssertTrue(clearsHorizontally(l2.rect, b)) }
        XCTAssertEqual(l2.rect.maxX, 1040 - TabGeometry.obstacleGap)
    }

    func testObstaclesBelowTheBarAndGarbageAreIgnored() {
        let w = CGRect(x: 100, y: 100, width: 1000, height: 600)
        let below = CGRect(x: 1000, y: 600, width: 48, height: 24)
        let junk = [CGRect.null, CGRect(x: CGFloat.nan, y: 674, width: 10, height: 10), CGRect(x: 1040, y: 674, width: 0, height: 10)]
        XCTAssertEqual(tab(place(w, obstacles: [below] + junk)).rect.maxX, w.maxX - TabGeometry.rightInset)
    }

    func testAFullBarFallsBackToTheFixedRightInset() {
        let w = CGRect(x: 100, y: 100, width: 300, height: 600)
        let wall = CGRect(x: 180, y: 674, width: 200, height: 24)
        XCTAssertEqual(tab(place(w, obstacles: [wall])).rect.maxX, w.maxX - TabGeometry.rightInset)
    }

    func testTabNeverGoesOverTheTrafficLights() {
        for width in stride(from: 100.0, through: 700.0, by: 20.0) {
            let w = CGRect(x: 50, y: 100, width: CGFloat(width), height: 300)
            if case .tab(let l) = place(w) {
                XCTAssertGreaterThanOrEqual(l.rect.minX, w.minX + DockGeometry.trafficLightInset, "width \(width)")
                XCTAssertLessThanOrEqual(l.rect.maxX, w.maxX, "width \(width)")
            }
        }
        for gapX in stride(from: 200.0, through: 640.0, by: 40.0) {
            let w = CGRect(x: 100, y: 100, width: 600, height: 600)
            let o = CGRect(x: CGFloat(gapX), y: 674, width: 60, height: 24)
            let l = tab(place(w, obstacles: [o]))
            XCTAssertGreaterThanOrEqual(l.rect.minX, w.minX + DockGeometry.trafficLightInset, "obstacle at \(gapX)")
        }
    }

    // MARK: hiding and clamping

    func testNarrowestWindowThatHoldsATab() {
        let min = TabGeometry.minimumWindowWidth   // 80 + 8 + 84 + 20 = 192
        XCTAssertEqual(min, 192)
        let ok = tab(place(CGRect(x: 100, y: 100, width: min, height: 300)))
        XCTAssertEqual(ok.rect.minX, 188)
        XCTAssertEqual(place(CGRect(x: 100, y: 100, width: min - 1, height: 300)), .hidden)
    }

    func testTinyAndDegenerateWindowsHide() {
        XCTAssertEqual(place(CGRect(x: 100, y: 100, width: 40, height: 20)), .hidden)
        XCTAssertEqual(place(CGRect(x: 100, y: 100, width: 600, height: 10)), .hidden)
        XCTAssertEqual(place(CGRect(x: 100, y: 100, width: 0, height: 0)), .hidden)
        XCTAssertEqual(place(CGRect(x: 0, y: 0, width: 500, height: 400), screens: []), .hidden)
        XCTAssertEqual(place(.null), .hidden)
        XCTAssertEqual(place(CGRect(x: CGFloat.nan, y: 0, width: 500, height: 400)), .hidden)
        XCTAssertEqual(place(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 400)), .hidden)
    }

    func testFullScreenHidesTheTab() {
        XCTAssertEqual(place(main, screens: [main, right], fullScreen: true), .hidden)
    }

    func testMostlyOffscreenWindowHides() {
        XCTAssertEqual(place(CGRect(x: 1400, y: 200, width: 800, height: 500)), .hidden)
        XCTAssertEqual(place(CGRect(x: 5000, y: 200, width: 800, height: 500)), .hidden)
    }

    func testWindowHangingOffTheRightOrLeftEdgeKeepsTheTabOnScreen() {
        let r = tab(place(CGRect(x: 1000, y: 200, width: 800, height: 500)))
        XCTAssertTrue(main.contains(r.rect), "\(r.rect)")
        let l = tab(place(CGRect(x: -400, y: 200, width: 800, height: 500)))
        XCTAssertTrue(main.contains(l.rect), "\(l.rect)")
    }

    // MARK: multi-monitor and the top of the screen

    func testSecondMonitorToTheRight() {
        let l = tab(place(CGRect(x: 1700, y: 200, width: 900, height: 600), screens: [main, right]))
        XCTAssertTrue(right.contains(l.rect))
        XCTAssertEqual(l.rect.minY, 800)
    }

    func testMonitorWithNegativeOrigin() {
        let l = tab(place(CGRect(x: -1000, y: 300, width: 700, height: 500), screens: [main, left]))
        XCTAssertTrue(left.contains(l.rect))
        XCTAssertEqual(l.rect.minY, 800)
    }

    func testWindowStraddlingTwoScreensKeepsTheTabOnOne() {
        let l = tab(place(CGRect(x: 1300, y: 200, width: 1000, height: 500), screens: [main, right]))
        XCTAssertTrue(right.contains(l.rect) || main.contains(l.rect), "\(l.rect)")
    }

    func testRoomAboveIsMeasuredToTheUsableAreaNotTheMenuBar() {
        // Window top 10 pt under the menu bar: only 10 pt free above it, so the tab hangs inside.
        let w = CGRect(x: 100, y: 300, width: 800, height: 566)   // top edge 866, usable top 876
        let l = tab(place(w, usable: [mainUsable]))
        XCTAssertEqual(l.style, .inside)
        // Same window with the menu bar ignored has room (900 - 866 = 34).
        XCTAssertEqual(tab(place(w)).style, .above)
    }

    func testTabHangsInsideWhenTheWindowTopIsAtTheScreenTop() {
        let w = CGRect(x: 100, y: 400, width: 800, height: 500)   // top edge 900 = screen top
        let l = tab(place(w))
        XCTAssertEqual(l.style, .inside)
        XCTAssertEqual(l.rect.maxY, 900)
        XCTAssertEqual(l.rect.height, bar)
        XCTAssertTrue(main.contains(l.rect))
        XCTAssertTrue(l.rect.contains(l.dogFrame))
    }

    func testInsideTabStaysOnScreenWhenTheWindowPokesAboveIt() {
        let w = CGRect(x: 100, y: 400, width: 800, height: 510)   // top edge 910, 10 pt above the screen
        let l = tab(place(w))
        XCTAssertEqual(l.style, .inside)
        XCTAssertLessThanOrEqual(l.rect.maxY, main.maxY)
        // Entirely above the screen: hidden.
        XCTAssertEqual(place(CGRect(x: 100, y: 950, width: 800, height: 300)), .hidden)
    }

    func testResultIsAlwaysInsideSomeScreen() {
        let screens = [main, right, left]
        var count = 0
        for x in stride(from: -2000.0, through: 3200.0, by: 170.0) {
            for w in [200.0, 300.0, 800.0, 1600.0] {
                let win = CGRect(x: CGFloat(x), y: 150, width: CGFloat(w), height: 600)
                if case .tab(let l) = place(win, screens: screens) {
                    count += 1
                    XCTAssertTrue(screens.contains { $0.contains(l.rect) }, "x=\(x) w=\(w) -> \(l.rect)")
                }
            }
        }
        XCTAssertGreaterThan(count, 10)
    }

    // MARK: outline path

    func testOutlineHasNoSegmentAlongTheBase() {
        let l = tab(place(CGRect(x: 100, y: 100, width: 1000, height: 600)))
        let p = l.path
        let h = l.rect.height, w = l.rect.width
        // Starts at the base-left corner, ends at the base-right corner, and no step of the open outline runs along y == h.
        XCTAssertEqual(p.outline.first, .move(CGPoint(x: 0, y: h)))
        guard case .curve(let end, _, _)? = p.outline.last else { return XCTFail() }
        XCTAssertEqual(end, CGPoint(x: w, y: h))
        for e in p.outline.dropFirst() {
            if case .line(let to) = e { XCTAssertFalse(to.y == h, "a line ends on the base") }
            if case .close = e { XCTFail("the outline must stay open") }
        }
        XCTAssertEqual(p.fill.last, .close)
        XCTAssertEqual(p.fill.count, p.outline.count + 1)
    }

    func testFlareIsConcaveAndCornersAreRounded() {
        let l = tab(place(CGRect(x: 100, y: 100, width: 1000, height: 600)))
        let p = l.path, f = l.flare, h = l.rect.height
        // Flare: from (0,h) horizontally tangent to the wall at (f, h-f).
        guard case .curve(let to, let c1, let c2) = p.outline[1] else { return XCTFail() }
        XCTAssertEqual(to, CGPoint(x: f, y: h - f))
        XCTAssertEqual(c1.y, h)                 // leaves the base horizontally
        XCTAssertEqual(c2.x, f)                 // arrives at the wall vertically
        XCTAssertGreaterThan(c1.x, 0); XCTAssertLessThan(c1.x, f)
        // Top-left corner ends at (f + r, 0).
        guard case .curve(let top, _, _) = p.outline[3] else { return XCTFail() }
        XCTAssertEqual(top, CGPoint(x: f + l.cornerRadius, y: 0))
    }

    func testEveryOutlinePointStaysInsideTheTabRect() {
        let l = tab(place(CGRect(x: 100, y: 100, width: 1000, height: 600)))
        let box = CGRect(origin: .zero, size: l.rect.size).insetBy(dx: -0.001, dy: -0.001)
        for e in l.path.fill {
            switch e {
            case .move(let p), .line(let p): XCTAssertTrue(box.contains(p), "\(p)")
            case .curve(let to, let c1, let c2): for p in [to, c1, c2] { XCTAssertTrue(box.contains(p), "\(p)") }
            case .close: break
            }
        }
    }

    func testInsideTabIsTheMirrorImage() {
        let up = TabGeometry.path(size: CGSize(width: 84, height: 28), flare: 10, cornerRadius: 8, style: .above)
        let down = TabGeometry.path(size: CGSize(width: 84, height: 28), flare: 10, cornerRadius: 8, style: .inside)
        XCTAssertEqual(down.outline.first, .move(CGPoint(x: 0, y: 0)))
        XCTAssertEqual(up.outline.count, down.outline.count)
        XCTAssertEqual(down.outline[2], .line(CGPoint(x: 10, y: 28 - 8)))
    }

    // MARK: colours

    func testFallbackColoursAndOutlines() {
        XCTAssertEqual(TabAppearance.fallbackFillHex(dark: false), "#E8E8E8")
        XCTAssertEqual(TabAppearance.fallbackFillHex(dark: true), "#2D2D2D")
        XCTAssertEqual(TabAppearance.outlineRGBA(dark: false), [0, 0, 0, 0.18])
        XCTAssertEqual(TabAppearance.outlineRGBA(dark: true), [1, 1, 1, 0.22])
    }

    func testHexParsing() {
        let c = TabAppearance.rgb(hex: "#FF8000")!
        XCTAssertEqual(c.r, 1, accuracy: 0.001); XCTAssertEqual(c.g, 128.0 / 255, accuracy: 0.001); XCTAssertEqual(c.b, 0)
        XCTAssertNil(TabAppearance.rgb(hex: "FF8000"))
        XCTAssertNil(TabAppearance.rgb(hex: "#GG0000"))
        XCTAssertNil(TabAppearance.rgb(hex: "#FFF"))
        XCTAssertEqual(TabAppearance.hex(r: 300, g: -4, b: 45), "#FF002D")
    }

    func testBarColourFromARowIgnoresTrafficLightsAndTitleText() {
        let width = 200
        var row = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<width { row[x * 4] = 232; row[x * 4 + 1] = 232; row[x * 4 + 2] = 232; row[x * 4 + 3] = 255 }
        for x in 5..<25 { row[x * 4] = 255; row[x * 4 + 1] = 0; row[x * 4 + 2] = 0 }          // red light
        for x in 80..<100 { row[x * 4] = 40; row[x * 4 + 1] = 40; row[x * 4 + 2] = 40 }       // a bit of title text
        XCTAssertEqual(TabAppearance.barColor(fromRow: row, width: width), "#E8E8E8")
        XCTAssertNil(TabAppearance.barColor(fromRow: [], width: 0))
        XCTAssertNil(TabAppearance.barColor(fromRow: [1, 2, 3], width: 10))
    }
}
