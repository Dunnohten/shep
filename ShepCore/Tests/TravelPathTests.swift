import CoreGraphics
import XCTest
@testable import ShepCore

final class TravelPathTests: XCTestCase {
    private let one = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    private let two = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]

    private func straight(_ a: CGPoint, _ b: CGPoint) -> TravelPath {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        return TravelPath(start: a, control1: CGPoint(x: a.x + d.x / 3, y: a.y + d.y / 3),
                          control2: CGPoint(x: a.x + 2 * d.x / 3, y: a.y + 2 * d.y / 3), end: b)
    }

    private func inside(_ p: CGPoint, _ screens: [CGRect]) -> Bool {
        screens.contains { $0.insetBy(dx: -0.001, dy: -0.001).contains(p) }
    }

    func testTheTravellerIsNotStretchedLikeGoo() {
        XCTAssertLessThanOrEqual(TravelPath.maxStretch, 1.06)   // a hint of velocity at most
        XCTAssertGreaterThanOrEqual(TravelPath.squash(stretch: TravelPath.maxStretch), 0.97)
        XCTAssertGreaterThanOrEqual(TravelPath.maxStretch, 1)
    }

    func testEndpoints() {
        let p = TravelPath.arc(from: CGPoint(x: 720, y: 860), to: CGPoint(x: 300, y: 300), screens: one)
        XCTAssertEqual(p.point(at: 0).x, 720, accuracy: 1e-9)
        XCTAssertEqual(p.point(at: 0).y, 860, accuracy: 1e-9)
        XCTAssertEqual(p.point(at: 1).x, 300, accuracy: 1e-9)
        XCTAssertEqual(p.point(at: 1).y, 300, accuracy: 1e-9)
    }

    func testArcBowsOffTheChordTowardTheMiddleOfTheScreens() {
        // Vertical chord at the left edge: the arc bows right (toward the screen's middle), not off the left edge.
        let p = TravelPath.arc(from: CGPoint(x: 10, y: 500), to: CGPoint(x: 10, y: 100), screens: one)
        XCTAssertGreaterThan(p.control1.x, 100)
        XCTAssertGreaterThan(p.control2.x, 100)
        XCTAssertGreaterThan(p.point(at: 0.5).x, 50)
        // Mirrored at the right edge: it bows left.
        let q = TravelPath.arc(from: CGPoint(x: 1430, y: 500), to: CGPoint(x: 1430, y: 100), screens: one)
        XCTAssertLessThan(q.control1.x, 1330)
    }

    func testDegenerateArcDoesNotBlowUp() {
        let p = TravelPath.arc(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), screens: one)
        XCTAssertEqual(p.length(), 0, accuracy: 1e-9)
        let s = p.samples(duration: 1, fps: 10)
        XCTAssertEqual(s.count, 11)
        XCTAssertTrue(s.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.speed == 0 })
    }

    func testEverySampleStaysOnScreenAcrossMonitors() {
        let starts = [CGPoint(x: 10, y: 890), CGPoint(x: 1400, y: 880), CGPoint(x: 2000, y: 1070), CGPoint(x: 720, y: 880)]
        let ends = [CGPoint(x: 3300, y: 20), CGPoint(x: 15, y: 15), CGPoint(x: 1450, y: 1070), CGPoint(x: 1000, y: 500)]
        for a in starts {
            for b in ends {
                let path = TravelPath.arc(from: a, to: b, screens: two)
                XCTAssertTrue(inside(path.control1, two), "c1 \(a) -> \(b)")
                XCTAssertTrue(inside(path.control2, two), "c2 \(a) -> \(b)")
                for s in path.samples(duration: path.duration, screens: two) {
                    XCTAssertTrue(inside(s.position, two), "sample \(s.position) for \(a) -> \(b)")
                }
            }
        }
    }

    func testClampPicksTheNearestScreen() {
        XCTAssertEqual(TravelPath.clamp(CGPoint(x: 500, y: 500), toScreens: two), CGPoint(x: 500, y: 500))
        let up = TravelPath.clamp(CGPoint(x: 1500, y: 2000), toScreens: two)
        XCTAssertEqual(up.x, 1500, accuracy: 1e-9)
        XCTAssertEqual(up.y, 1080 - TravelPath.edgeInset, accuracy: 1e-9)
        // Above the shorter screen's top, left of the taller one: nearest is the shorter screen's top edge.
        let gap = TravelPath.clamp(CGPoint(x: 1000, y: 950), toScreens: two)
        XCTAssertEqual(gap.x, 1000, accuracy: 1e-9)
        XCTAssertEqual(gap.y, 900 - TravelPath.edgeInset, accuracy: 1e-9)
        XCTAssertEqual(TravelPath.clamp(CGPoint(x: 5, y: 5), toScreens: []), CGPoint(x: 5, y: 5))
        let nan = TravelPath.clamp(CGPoint(x: CGFloat.nan, y: 5), toScreens: one)
        XCTAssertTrue(nan.x.isFinite && nan.y.isFinite)
    }

    func testDurationRunsFromNinetyToOneTwentyHundredths() {
        XCTAssertEqual(straight(.zero, .zero).duration, 0.9, accuracy: 1e-9)
        XCTAssertEqual(straight(.zero, CGPoint(x: 600, y: 0)).duration, 1.05, accuracy: 0.002)
        XCTAssertEqual(straight(.zero, CGPoint(x: 5000, y: 0)).duration, 1.2, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(TravelPath.arc(from: CGPoint(x: 700, y: 800), to: CGPoint(x: 720, y: 790), screens: one).duration, 0.9)
    }

    func testEaseInOut() {
        XCTAssertEqual(TravelPath.ease(0), 0, accuracy: 1e-12)
        XCTAssertEqual(TravelPath.ease(1), 1, accuracy: 1e-12)
        XCTAssertEqual(TravelPath.ease(0.5), 0.5, accuracy: 1e-12)
        XCTAssertLessThan(TravelPath.ease(0.1), 0.1)      // slow start
        XCTAssertGreaterThan(TravelPath.ease(0.9), 0.9)   // slow end
        var last = -1.0
        for i in 0...100 {
            let v = TravelPath.ease(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
        XCTAssertEqual(TravelPath.easeRate(0), 0, accuracy: 1e-12)
        XCTAssertEqual(TravelPath.easeRate(0.5), 1.5, accuracy: 1e-12)
        XCTAssertEqual(TravelPath.ease(-3), 0)
        XCTAssertEqual(TravelPath.ease(.nan), 0)
    }

    func testSquashAndStretchFollowSpeed() {
        XCTAssertEqual(TravelPath.stretch(speed: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(TravelPath.stretch(speed: TravelPath.fullSpeed), TravelPath.maxStretch, accuracy: 1e-12)
        XCTAssertEqual(TravelPath.stretch(speed: TravelPath.fullSpeed / 2), 1 + (TravelPath.maxStretch - 1) / 2, accuracy: 1e-12)
        XCTAssertEqual(TravelPath.stretch(speed: 99999), TravelPath.maxStretch, accuracy: 1e-12)
        XCTAssertEqual(TravelPath.stretch(speed: -5), 1)
        XCTAssertEqual(TravelPath.stretch(speed: .nan), 1)
        for st in [1.0, 1.3, 1.75] {
            let across = TravelPath.squash(stretch: st)
            XCTAssertEqual(st * across * across, 1, accuracy: 1e-9)   // area kept
            XCTAssertLessThanOrEqual(across, 1)
        }
    }

    func testSamplesOfAStraightTravel() {
        let path = straight(CGPoint(x: 100, y: 100), CGPoint(x: 700, y: 100))   // 600 pt to the right
        let s = path.samples(duration: 1, fps: 60)
        XCTAssertEqual(s.count, 61)
        XCTAssertEqual(s.first?.time ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(s.last?.time ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(s[0].position.x, 100, accuracy: 1e-9)
        XCTAssertEqual(s[60].position.x, 700, accuracy: 1e-9)
        XCTAssertEqual(s[30].position.x, 400, accuracy: 1e-9)
        // Rest at both ends, fastest in the middle: 600 pt * 1.5 / 1 s.
        XCTAssertEqual(s[0].speed, 0, accuracy: 1e-9)
        XCTAssertEqual(s[60].speed, 0, accuracy: 1e-9)
        XCTAssertEqual(s[30].speed, 900, accuracy: 1e-6)
        XCTAssertGreaterThan(s[30].speed, s[10].speed)
        XCTAssertEqual(s[30].along, TravelPath.stretch(speed: 900), accuracy: 1e-9)
        XCTAssertEqual(s[0].along, 1, accuracy: 1e-9)
        XCTAssertEqual(s[30].angleDegrees, 0, accuracy: 1e-6)
        // Opacity ramps at both ends and is full between.
        XCTAssertEqual(s[0].opacity, 0, accuracy: 1e-9)
        XCTAssertEqual(s[60].opacity, 0, accuracy: 1e-9)
        XCTAssertEqual(s[30].opacity, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(s[3].opacity, 0)
        XCTAssertLessThan(s[3].opacity, 1)
    }

    func testAngleUsesTheScreenConventionOfTheCSSPage() {
        let up = straight(CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 500)).samples(duration: 1, fps: 10)   // y grows: up the screen
        XCTAssertEqual(up[5].angleDegrees, -90, accuracy: 1e-6)
        let down = straight(CGPoint(x: 100, y: 500), CGPoint(x: 100, y: 100)).samples(duration: 1, fps: 10)
        XCTAssertEqual(down[5].angleDegrees, 90, accuracy: 1e-6)
        let left = straight(CGPoint(x: 500, y: 100), CGPoint(x: 100, y: 100)).samples(duration: 1, fps: 10)
        XCTAssertEqual(abs(left[5].angleDegrees), 180, accuracy: 1e-6)
    }

    func testSampleCountAndBadDurations() {
        let path = straight(.zero, CGPoint(x: 100, y: 0))
        XCTAssertEqual(path.samples(duration: 0.5, fps: 60).count, 31)   // 30 steps + 1
        XCTAssertEqual(path.samples(duration: -1, fps: 60).count, Int((TravelPath.minDuration * 60).rounded(.up)) + 1)
        XCTAssertGreaterThanOrEqual(path.samples(duration: 0.001, fps: 60).count, 3)
    }

    func testReversedWalksTheSameArcBack() {
        let p = TravelPath.arc(from: CGPoint(x: 720, y: 860), to: CGPoint(x: 300, y: 300), screens: one)
        let r = p.reversed
        XCTAssertEqual(r.start, p.end)
        XCTAssertEqual(r.end, p.start)
        for t in [0.0, 0.2, 0.5, 0.9, 1.0] {
            XCTAssertEqual(r.point(at: t).x, p.point(at: 1 - t).x, accuracy: 1e-9)
            XCTAssertEqual(r.point(at: t).y, p.point(at: 1 - t).y, accuracy: 1e-9)
        }
        XCTAssertEqual(r.length(), p.length(), accuracy: 1e-6)
    }

    func testLengthOfAStraightPathIsItsDistance() {
        XCTAssertEqual(straight(.zero, CGPoint(x: 300, y: 400)).length(), 500, accuracy: 1e-6)
    }

    func testCorridorCoversTheArc() {
        let p = TravelPath.arc(from: CGPoint(x: 720, y: 860), to: CGPoint(x: 300, y: 300), screens: one)
        let corridor = p.corridor(margin: 40)
        XCTAssertEqual(corridor.count, 12)
        for i in 0...50 {
            let q = p.point(at: Double(i) / 50)
            XCTAssertTrue(corridor.contains { $0.contains(q) }, "t=\(Double(i) / 50)")
        }
        // The margin is really there: the first piece reaches 40 pt past the start in every direction.
        XCTAssertLessThanOrEqual(corridor[0].minX, min(p.start.x, p.point(at: 1.0 / 12).x) - 40 + 1e-9)
    }

    func testLogDescriptionIsInTopLeftCoordinates() {
        let p = straight(CGPoint(x: 100, y: 900), CGPoint(x: 100, y: 500))
        let text = p.logDescription(primaryScreenHeight: 1000, corridorMargin: 0)
        XCTAssertTrue(text.hasPrefix("path=100,100 "), text)   // y 900 from the bottom is 100 from the top
        XCTAssertTrue(text.contains(" 100,500 duration="), text)
        XCTAssertTrue(text.contains("corridor="), text)
    }

    // MARK: targets

    func testTabTargetLandsOnTheDogOfTheTab() {
        let window = CGRect(x: 200, y: 300, width: 800, height: 500)
        let dest = TravelTarget.tab(windowFrame: window).destination(screens: one)
        let layout = TabGeometry.place(window: window, isFullScreen: false, screens: one).layout
        XCTAssertNotNil(dest)
        XCTAssertEqual(dest?.x ?? 0, layout?.dogFrame.midX ?? -1, accuracy: 1e-9)
        XCTAssertEqual(dest?.y ?? 0, layout?.dogFrame.midY ?? -1, accuracy: 1e-9)
        XCTAssertGreaterThan(dest?.y ?? 0, window.maxY - 1)   // at or above the window's top edge
    }

    func testPlacedTabWinsOverTheWindowFrame() {
        let window = CGRect(x: 200, y: 300, width: 800, height: 500)
        guard var layout = TabGeometry.place(window: window, isFullScreen: false, screens: one).layout else { return XCTFail("no tab") }
        layout.dogFrame = layout.dogFrame.offsetBy(dx: -100, dy: 0)
        let dest = TravelTarget.tab(windowFrame: window, placed: layout).destination(screens: one)
        XCTAssertEqual(dest?.x ?? 0, layout.dogFrame.midX, accuracy: 1e-9)
    }

    func testTabTargetNilWhenTheTabIsHidden() {
        XCTAssertNil(TravelTarget.tab(windowFrame: CGRect(x: 10, y: 10, width: 50, height: 300)).destination(screens: one))
        XCTAssertNil(TravelTarget.tab(windowFrame: CGRect(x: 200, y: 300, width: 800, height: 500)).destination(screens: []))
    }

    func testControlTargetHoversAboveTheControl() {
        let screen = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        let d = TravelTarget.control(CGRect(x: 100, y: 100, width: 50, height: 30)).destination(screens: screen)
        XCTAssertEqual(d?.x ?? 0, 125, accuracy: 1e-9)
        XCTAssertEqual(d?.y ?? 0, 130 + TravelPath.controlHover, accuracy: 1e-9)
        let edge = TravelTarget.control(CGRect(x: 100, y: 780, width: 50, height: 30)).destination(screens: screen)
        XCTAssertEqual(edge?.y ?? 0, 800 - TravelPath.edgeInset, accuracy: 1e-9)
        XCTAssertNil(TravelTarget.control(.zero).destination(screens: screen))
    }

    func testPositionInterpolatesBetweenSamples() {
        let path = straight(CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 0))
        let s = path.samples(duration: 1, fps: 60)
        XCTAssertEqual(TravelPath.position(in: s, at: -1), s.first?.position)
        XCTAssertEqual(TravelPath.position(in: s, at: 5), s.last?.position)
        let mid = TravelPath.position(in: s, at: 0.5)
        XCTAssertEqual(mid?.x ?? 0, 300, accuracy: 1e-6)
        // Between two samples it is between their positions.
        let t = (s[10].time + s[11].time) / 2
        let p = TravelPath.position(in: s, at: t)
        XCTAssertEqual(p?.x ?? 0, (s[10].position.x + s[11].position.x) / 2, accuracy: 1e-6)
        XCTAssertNil(TravelPath.position(in: [], at: 0))
    }
}
