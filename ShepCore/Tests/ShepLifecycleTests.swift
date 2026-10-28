import XCTest
@testable import ShepCore

final class ShepLifecycleTests: XCTestCase {
    private func fresh(reduce: Bool = false) -> ShepLifecycle { ShepLifecycle(state: .asleep, reduceMotion: reduce) }

    func testStartsAsleepAndIgnoresEverythingButACall() {
        var l = fresh()
        XCTAssertEqual(l.state, .asleep)
        for e: LifecycleEvent in [.arrived, .homeReached, .taskDone, .taskStarted, .dismiss, .timeout, .windowLost, .wakeFinished(hasTarget: true)] {
            XCTAssertEqual(l.handle(e), [], "\(e)")
            XCTAssertEqual(l.state, .asleep)
        }
    }

    func testCallWakesAndStartsTracking() {
        for source in [CallSource.doghouse, .menu, .hotkey, .pushToTalk, .demo] {
            var l = fresh()
            XCTAssertEqual(l.handle(.call(source)), [.startTracking, .beginWake(reduced: false)], "\(source)")
            XCTAssertEqual(l.state, .waking)
        }
    }

    func testFullCycle() {
        var l = fresh()
        l.handle(.call(.hotkey))
        XCTAssertEqual(l.handle(.wakeFinished(hasTarget: true)), [.beginTravel(reduced: false)])
        XCTAssertEqual(l.state, .traveling)
        XCTAssertEqual(l.handle(.arrived), [.dock(reduced: false), .armTimeout(LifecycleTimings.idleSeconds)])
        XCTAssertEqual(l.state, .working)
        XCTAssertTrue(l.dockVisible)
        XCTAssertEqual(l.handle(.taskStarted), [.cancelTimeout])
        XCTAssertEqual(l.handle(.taskDone), [.armTimeout(LifecycleTimings.afterTaskSeconds)])
        XCTAssertEqual(l.handle(.dismiss), [.cancelTimeout, .stopTracking, .undock, .beginReturn(reduced: false)])
        XCTAssertEqual(l.state, .returning)
        XCTAssertFalse(l.dockVisible)
        XCTAssertEqual(l.handle(.homeReached), [.sleep])
        XCTAssertEqual(l.state, .asleep)
    }

    func testNoTargetGoesStraightBackToSleep() {
        var l = fresh()
        l.handle(.call(.menu))
        XCTAssertEqual(l.handle(.wakeFinished(hasTarget: false)), [.cancelVoice, .cancelFixTask, .stopTracking, .sleep])
        XCTAssertEqual(l.state, .asleep)
    }

    func testDismissWhileWakingSleepsAtOnce() {
        var l = fresh()
        l.handle(.call(.doghouse))
        XCTAssertEqual(l.handle(.dismiss), [.stopTracking, .sleep])
        XCTAssertEqual(l.state, .asleep)
    }

    func testSecondCallWhileAwakeIsIgnoredOrRefreshesTheClock() {
        var l = fresh()
        l.handle(.call(.doghouse))
        XCTAssertEqual(l.handle(.call(.hotkey)), [])
        l.handle(.wakeFinished(hasTarget: true))
        XCTAssertEqual(l.handle(.call(.hotkey)), [])
        l.handle(.arrived)
        XCTAssertEqual(l.handle(.call(.pushToTalk)), [.armTimeout(LifecycleTimings.idleSeconds)])
        XCTAssertEqual(l.state, .working)
    }

    func testTimeoutSendsHomeOnlyWhenNotBusy() {
        var l = fresh()
        l.handle(.call(.doghouse)); l.handle(.wakeFinished(hasTarget: true)); l.handle(.arrived)
        l.handle(.taskStarted)
        XCTAssertEqual(l.handle(.timeout), [])
        XCTAssertEqual(l.state, .working)
        XCTAssertTrue(l.busy)
        l.handle(.taskDone)
        XCTAssertFalse(l.busy)
        XCTAssertEqual(l.handle(.timeout), [.cancelTimeout, .stopTracking, .undock, .beginReturn(reduced: false)])
        XCTAssertEqual(l.state, .returning)
    }

    func testWindowLostWhileWorkingOrTravelingGoesHome() {
        var l = fresh()
        l.handle(.call(.doghouse)); l.handle(.wakeFinished(hasTarget: true))
        XCTAssertEqual(l.handle(.windowLost), [.stopTracking, .beginReturn(reduced: false)])
        XCTAssertEqual(l.state, .returning)

        var w = fresh()
        w.handle(.call(.doghouse)); w.handle(.wakeFinished(hasTarget: true)); w.handle(.arrived)
        XCTAssertEqual(w.handle(.windowLost), [.cancelTimeout, .stopTracking, .undock, .beginReturn(reduced: false)])
    }

    func testDismissWhileTravelingTurnsAround() {
        var l = fresh()
        l.handle(.call(.doghouse)); l.handle(.wakeFinished(hasTarget: true))
        XCTAssertEqual(l.handle(.dismiss), [.stopTracking, .beginReturn(reduced: false)])
        XCTAssertEqual(l.state, .returning)
        XCTAssertEqual(l.handle(.homeReached), [.sleep])
    }

    func testCalledOnTheWayHomeTurnsAroundAgain() {
        var l = fresh()
        l.handle(.call(.doghouse)); l.handle(.wakeFinished(hasTarget: true)); l.handle(.arrived); l.handle(.dismiss)
        XCTAssertEqual(l.handle(.call(.hotkey)), [.startTracking, .beginTravel(reduced: false)])
        XCTAssertEqual(l.state, .traveling)
        XCTAssertEqual(l.handle(.arrived), [.dock(reduced: false), .armTimeout(LifecycleTimings.idleSeconds)])
    }

    func testARequestStartedBeforeArrivalKeepsTheIdleClockOffUntilItIsDone() {
        var l = fresh()
        l.handle(.call(.pushToTalk))
        XCTAssertEqual(l.handle(.taskStarted), [])
        XCTAssertTrue(l.busy)
        l.handle(.wakeFinished(hasTarget: true))
        XCTAssertEqual(l.handle(.arrived), [.dock(reduced: false)], "no timeout is armed while the request runs")
        XCTAssertEqual(l.handle(.timeout), [])
        XCTAssertEqual(l.handle(.taskDone), [.armTimeout(LifecycleTimings.afterTaskSeconds)])
        XCTAssertFalse(l.busy)
    }

    func testARequestThatEndsBeforeArrivalLeavesTheNormalClock() {
        var l = fresh()
        l.handle(.call(.pushToTalk)); l.handle(.wakeFinished(hasTarget: true))
        l.handle(.taskStarted)
        XCTAssertEqual(l.handle(.taskDone), [])
        XCTAssertEqual(l.handle(.arrived), [.dock(reduced: false), .armTimeout(LifecycleTimings.idleSeconds)])
    }

    func testTasksWhileAsleepOrReturningDoNothing() {
        var l = fresh()
        XCTAssertEqual(l.handle(.taskStarted), [])
        XCTAssertFalse(l.busy)
        l.handle(.call(.doghouse)); l.handle(.wakeFinished(hasTarget: true)); l.handle(.arrived); l.handle(.dismiss)
        XCTAssertEqual(l.handle(.taskStarted), [])
        XCTAssertFalse(l.busy)
    }

    func testReduceMotionFlagReachesEveryEffectThatCanBeReduced() {
        var l = fresh(reduce: true)
        XCTAssertEqual(l.handle(.call(.doghouse)), [.startTracking, .beginWake(reduced: true)])
        XCTAssertEqual(l.handle(.wakeFinished(hasTarget: true)), [.beginTravel(reduced: true)])
        XCTAssertEqual(l.handle(.arrived), [.dock(reduced: true), .armTimeout(LifecycleTimings.idleSeconds)])
        XCTAssertEqual(l.handle(.dismiss), [.cancelTimeout, .stopTracking, .undock, .beginReturn(reduced: true)])
    }

    func testReduceMotionCanChangeAtAnyTimeWithoutMovingTheState() {
        var l = fresh()
        l.handle(.call(.doghouse))
        XCTAssertEqual(l.handle(.reduceMotion(true)), [])
        XCTAssertEqual(l.state, .waking)
        XCTAssertTrue(l.reduceMotion)
        XCTAssertEqual(l.handle(.wakeFinished(hasTarget: true)), [.beginTravel(reduced: true)])
    }

    func testTrackingOnlyWhileAwakeAndHeadingForAWindow() {
        let expect: [LifecycleState: Bool] = [.asleep: false, .waking: true, .traveling: true, .working: true, .returning: false]
        for s in LifecycleState.allCases {
            XCTAssertEqual(ShepLifecycle(state: s).tracksWindows, expect[s], "\(s)")
        }
        XCTAssertTrue(ShepLifecycle(state: .asleep).houseHoldsDog)
        XCTAssertTrue(ShepLifecycle(state: .waking).houseHoldsDog)
        XCTAssertFalse(ShepLifecycle(state: .working).houseHoldsDog)
    }

    func testTrackingEffectsAreBalancedOverACycle() {
        var l = fresh()
        var on = 0
        var effects: [LifecycleEffect] = []
        effects += l.handle(.call(.doghouse))
        effects += l.handle(.wakeFinished(hasTarget: true))
        effects += l.handle(.arrived)
        effects += l.handle(.dismiss)
        effects += l.handle(.homeReached)
        for e in effects {
            if e == .startTracking { on += 1 }
            if e == .stopTracking { on -= 1 }
        }
        XCTAssertEqual(on, 0)
        XCTAssertFalse(l.tracksWindows)
    }

    func testHouseModeFollowsState() {
        XCTAssertEqual(HouseMode.mode(for: .asleep), .asleep)
        XCTAssertEqual(HouseMode.mode(for: .waking), .waking)
        for s in [LifecycleState.traveling, .working, .returning] { XCTAssertEqual(HouseMode.mode(for: s), .away) }
    }
}

final class LifecycleFramePolicyTests: XCTestCase {
    func testSleepingBreathesSlowly() {
        XCTAssertEqual(LifecycleFramePolicy.houseFramesPerSecond(mode: .asleep, reduceMotion: false, active: true), 8)
        XCTAssertLessThanOrEqual(LifecycleFramePolicy.asleepFPS, 10)
        XCTAssertGreaterThanOrEqual(LifecycleFramePolicy.asleepFPS, 8)
    }

    func testNothingRendersWhenHiddenOrOccludedOrAway() {
        for m in HouseMode.allCases {
            XCTAssertEqual(LifecycleFramePolicy.houseFramesPerSecond(mode: m, reduceMotion: false, active: false), 0, "\(m)")
        }
        XCTAssertEqual(LifecycleFramePolicy.houseFramesPerSecond(mode: .away, reduceMotion: false, active: true), 0)
        XCTAssertEqual(LifecycleFramePolicy.travelFramesPerSecond(reduceMotion: false, active: false), 0)
    }

    func testTravelRunsAtSixtyOnlyDuringTravel() {
        XCTAssertEqual(LifecycleFramePolicy.travelFramesPerSecond(reduceMotion: false, active: true), 60)
        XCTAssertEqual(LifecycleFramePolicy.houseFramesPerSecond(mode: .waking, reduceMotion: false, active: true), 30)
        XCTAssertLessThan(LifecycleFramePolicy.houseFramesPerSecond(mode: .entering, reduceMotion: false, active: true), 60)
        XCTAssertEqual(LifecycleFramePolicy.dockFramesPerSecond(dock: .idle, reduceMotion: false, active: true), 30)
    }

    func testReduceMotionSleepIsStill() {
        XCTAssertEqual(LifecycleFramePolicy.houseFramesPerSecond(mode: .asleep, reduceMotion: true, active: true), 0)
        XCTAssertEqual(LifecycleFramePolicy.travelFramesPerSecond(reduceMotion: true, active: true), 15)
    }
}

final class CycleScriptTests: XCTestCase {
    func testOrderAndBounds() {
        XCTAssertTrue(CycleScript.isWellFormed)
        XCTAssertEqual(CycleScript.steps.map(\.action), [.call, .listen, .think, .finish, .dismiss])
    }

    func testTimingsMatchTheBrief() {
        let s = CycleScript.steps
        XCTAssertEqual(s[0].at, 3, accuracy: 0.0001)                       // asleep 3 s, then the call
        XCTAssertEqual(s[2].at - s[1].at, 2, accuracy: 0.0001)             // listening 2 s
        XCTAssertEqual(s[3].at - s[2].at, 2, accuracy: 0.0001)             // thinking 2 s
        XCTAssertEqual(s[4].at - s[3].at, CycleScript.finishSeconds, accuracy: 0.0001)   // finish held before going home
        // The work begins only after the wake, the longest travel and the dock's rise.
        XCTAssertGreaterThanOrEqual(s[1].at - s[0].at, LifecycleTimings.wakeSeconds + TravelPath.maxDuration + DogMotionMachine.dockDuration)
        // Asleep for 3 s at the end, after the longest walk home and the curl-up.
        XCTAssertGreaterThanOrEqual(CycleScript.duration - s[4].at, TravelPath.maxDuration + LifecycleTimings.enterSeconds + 3)
    }
}
