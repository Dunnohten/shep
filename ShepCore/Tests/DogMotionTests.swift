import CoreGraphics
import XCTest
@testable import ShepCore

final class DogMotionMachineTests: XCTestCase {
    func testStartsIdleAndStatesFollowEvents() {
        var m = DogMotionMachine()
        XCTAssertEqual(m.state, .idle)
        m.send(.listen, at: 0); XCTAssertEqual(m.state, .listening)
        m.send(.think, at: 1); XCTAssertEqual(m.state, .thinking)
        m.send(.speak, at: 2); XCTAssertEqual(m.state, .speaking)
        m.send(.rest, at: 3); XCTAssertEqual(m.state, .idle)
    }

    func testDockingRisesThenReturnsToTheRestingState() {
        var m = DogMotionMachine()
        m.send(.think, at: 0)
        m.send(.dock, at: 10)
        XCTAssertEqual(m.state, .docking)
        XCTAssertEqual(m.endsAt ?? 0, 10 + DogMotionMachine.dockDuration, accuracy: 0.0001)
        m.tick(at: 10.5)
        XCTAssertEqual(m.state, .docking)
        m.tick(at: 11)
        XCTAssertEqual(m.state, .thinking)
        XCTAssertNil(m.endsAt)
    }

    func testStateRequestedWhileDockingAppliesWhenItEnds() {
        var m = DogMotionMachine()
        m.send(.dock, at: 0)
        m.send(.listen, at: 0.2)
        XCTAssertEqual(m.state, .docking)
        m.tick(at: 1)
        XCTAssertEqual(m.state, .listening)
    }

    func testDragPreemptsAndSnapsBackIntoDockingThenRest() {
        var m = DogMotionMachine()
        m.send(.listen, at: 0)
        m.send(.dragBegan, at: 1)
        XCTAssertEqual(m.state, .dragging)
        m.send(.think, at: 1.5)               // deferred
        XCTAssertEqual(m.state, .dragging)
        m.send(.dragEnded, at: 2)
        XCTAssertEqual(m.state, .docking)     // the snap-back spring
        XCTAssertEqual(m.endsAt ?? 0, 2 + DogMotionMachine.snapBackDuration, accuracy: 0.0001)
        m.tick(at: 3)
        XCTAssertEqual(m.state, .thinking)
    }

    func testDragEndedWithoutADragDoesNothing() {
        var m = DogMotionMachine()
        m.send(.dragEnded, at: 0)
        XCTAssertEqual(m.state, .idle)
    }

    func testHiddenIgnoresEverythingButShow() {
        var m = DogMotionMachine()
        m.send(.hide, at: 0)
        XCTAssertEqual(m.state, .hidden)
        m.send(.listen, at: 1); m.send(.dock, at: 1); m.send(.dragBegan, at: 1)
        XCTAssertEqual(m.state, .hidden)
        m.send(.show, at: 2)
        XCTAssertEqual(m.state, .docking)      // it rises out of the tab again
        m.tick(at: 3)
        XCTAssertEqual(m.state, .listening)    // the request made while hidden was remembered
    }

    func testReduceMotionShortensDockingAndDragEndsStraightAtRest() {
        var m = DogMotionMachine(reduceMotion: true)
        m.send(.dock, at: 0)
        XCTAssertEqual(m.endsAt ?? 0, DogMotionMachine.reducedDockDuration, accuracy: 0.0001)
        XCTAssertFalse(m.isSpringing)
        m.tick(at: 1)
        m.send(.dragBegan, at: 2)
        m.send(.dragEnded, at: 3)
        XCTAssertEqual(m.state, .idle)
    }

    func testSpringingOnlyWhileDockingOrDragging() {
        var m = DogMotionMachine()
        XCTAssertFalse(m.isSpringing)
        m.send(.dock, at: 0); XCTAssertTrue(m.isSpringing)
        m.tick(at: 2); XCTAssertFalse(m.isSpringing)
        m.send(.dragBegan, at: 3); XCTAssertTrue(m.isSpringing)
    }
}

final class FramePolicyTests: XCTestCase {
    func testIdleThirtyAndSpringsSixty() {
        XCTAssertEqual(FramePolicy.framesPerSecond(state: .idle, reduceMotion: false, active: true), 30)
        XCTAssertEqual(FramePolicy.framesPerSecond(state: .thinking, reduceMotion: false, active: true), 30)
        XCTAssertEqual(FramePolicy.framesPerSecond(state: .docking, reduceMotion: false, active: true), 60)
        XCTAssertEqual(FramePolicy.framesPerSecond(state: .dragging, reduceMotion: false, active: true), 60)
    }

    func testPausedWhenInactiveOrHidden() {
        for s in DogMotionState.allCases {
            XCTAssertEqual(FramePolicy.framesPerSecond(state: s, reduceMotion: false, active: false), 0, "\(s)")
            XCTAssertEqual(FramePolicy.framesPerSecond(state: s, reduceMotion: true, active: false), 0, "\(s)")
        }
        XCTAssertEqual(FramePolicy.framesPerSecond(state: .hidden, reduceMotion: false, active: true), 0)
    }

    func testReduceMotionIsCalm() {
        XCTAssertEqual(FramePolicy.framesPerSecond(state: .idle, reduceMotion: true, active: true), 15)
        XCTAssertEqual(FramePolicy.framesPerSecond(state: .dragging, reduceMotion: true, active: true), 15)
        XCTAssertLessThan(FramePolicy.framesPerSecond(state: .docking, reduceMotion: true, active: true), 60)
    }

    func testActivityNeedsVisibleUnoccludedAwake() {
        XCTAssertTrue(DogActivity().isActive)
        XCTAssertFalse(DogActivity(panelVisible: false).isActive)
        XCTAssertFalse(DogActivity(occluded: true).isActive)
        XCTAssertFalse(DogActivity(screenAsleep: true).isActive)
    }
}

final class DockMotionPlannerTests: XCTestCase {
    let a = CGRect(x: 700, y: 800, width: 84, height: 30)

    func testFirstAppearanceRises() {
        XCTAssertEqual(DockMotionPlanner.plan(from: nil, to: a, sameWindow: true, reduceMotion: false), .rise)
        XCTAssertEqual(DockMotionPlanner.plan(from: a, to: nil, sameWindow: true, reduceMotion: false), .none)
    }

    func testSmallMoveOfTheSameWindowSlides() {
        let b = a.offsetBy(dx: 30, dy: -40)
        XCTAssertEqual(DockMotionPlanner.plan(from: a, to: b, sameWindow: true, reduceMotion: false), .slide(duration: DockMotionPlanner.slideSeconds))
        XCTAssertEqual(DockMotionPlanner.plan(from: a, to: a, sameWindow: true, reduceMotion: false), .none)
    }

    func testBigMoveOtherWindowOrResizeRisesAgain() {
        XCTAssertEqual(DockMotionPlanner.plan(from: a, to: a.offsetBy(dx: 400, dy: 0), sameWindow: true, reduceMotion: false), .rise)
        XCTAssertEqual(DockMotionPlanner.plan(from: a, to: a.offsetBy(dx: 10, dy: 0), sameWindow: false, reduceMotion: false), .rise)
        var wider = a; wider.size.width = 90
        XCTAssertEqual(DockMotionPlanner.plan(from: a, to: wider, sameWindow: true, reduceMotion: false), .rise)
    }

    func testReduceMotionNeverSlides() {
        XCTAssertEqual(DockMotionPlanner.plan(from: a, to: a.offsetBy(dx: 30, dy: 0), sameWindow: true, reduceMotion: true), .none)
    }
}

final class DemoScriptTests: XCTestCase {
    func testStepsAreOrderedAndInsideTheRun() {
        XCTAssertTrue(DemoScript.isWellFormed)
        XCTAssertEqual(DemoScript.steps.first, DemoStep(at: 0, action: .dock))
    }

    func testSequenceCoversEveryPartInOrder() {
        func firstIndex(_ a: DemoAction) -> Int? { DemoScript.steps.firstIndex(where: { $0.action == a }) }
        let dock = firstIndex(.dock), blink = firstIndex(.blink), listen = firstIndex(.listen)
        let think = firstIndex(.think), end = firstIndex(.dragEnd)
        XCTAssertNotNil(dock); XCTAssertNotNil(blink); XCTAssertNotNil(listen); XCTAssertNotNil(think); XCTAssertNotNil(end)
        XCTAssertTrue(dock! < blink! && blink! < listen! && listen! < think! && think! < end!)
        XCTAssertTrue(DemoScript.steps.contains { if case .dragTo = $0.action { return true } else { return false } })
        XCTAssertEqual(DemoScript.steps.last?.action, .rest)
    }

    func testTimings() {
        func at(_ a: DemoAction) -> TimeInterval { DemoScript.steps.first(where: { $0.action == a })!.at }
        XCTAssertEqual(at(.think) - at(.listen), 2.5, accuracy: 0.001)   // listening 2.5 s
        XCTAssertGreaterThanOrEqual(at(.blink) - at(.rest), 3)           // idle 3 s before the blink
    }
}

final class DogGazeAndEventTests: XCTestCase {
    func testPointerRightAndAboveLooksRightAndUp() {
        let g = DogGaze.normalised(pointer: CGPoint(x: 600, y: 700), dogCenter: CGPoint(x: 500, y: 600))
        XCTAssertEqual(g.x, 100.0 / 300.0, accuracy: 0.001)
        XCTAssertEqual(g.y, -100.0 / 300.0, accuracy: 0.001)   // above the dog: the page's up is negative
    }

    func testGazeIsClampedAndSafe() {
        let far = DogGaze.normalised(pointer: CGPoint(x: -5000, y: -5000), dogCenter: CGPoint(x: 0, y: 0))
        XCTAssertEqual(far.x, -1); XCTAssertEqual(far.y, 1)
        let bad = DogGaze.normalised(pointer: CGPoint(x: CGFloat.nan, y: 0), dogCenter: .zero)
        XCTAssertEqual(bad.x, 0); XCTAssertEqual(bad.y, 0)
    }

    func testDogStatesMapToMachineEvents() {
        XCTAssertEqual(ShepDogState.thinking.motionEvent, .think)
        XCTAssertEqual(ShepDogState.listening.motionEvent, .listen)
        XCTAssertEqual(ShepDogState.talking.motionEvent, .speak)
        XCTAssertEqual(ShepDogState.sleeping.motionEvent, .rest)
        XCTAssertEqual(DogMotionEvent.dragBegan.rawValue, "dragBegan")   // the page's event names
    }
}
