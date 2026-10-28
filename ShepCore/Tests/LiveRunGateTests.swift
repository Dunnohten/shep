import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of 6d026eb (F2, F3 and the late result): the "target left" latch is a thread-safe holder with
// one winner, the departure is judged from the activated app named by the notification itself, and a result that arrives after the
// latch is neither offered, nor dumped, nor sent further.

final class LiveRunGateTests: XCTestCase {
    func testTheGateStartsOpenAndLatchesOnce() {
        let gate = LiveRunGate()
        XCTAssertFalse(gate.isLeft)
        XCTAssertTrue(gate.latchLeft(), "the first call is the winner")
        XCTAssertTrue(gate.isLeft)
        XCTAssertFalse(gate.latchLeft(), "a second call is not")
        XCTAssertFalse(gate.latchLeft())
        XCTAssertTrue(gate.isLeft, "it stays latched")
    }

    func testConcurrentLatchesHaveExactlyOneWinner() {
        for _ in 0..<50 {
            let gate = LiveRunGate()
            let box = WinnerCounter()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                if gate.latchLeft() { box.add() }
                _ = gate.isLeft
            }
            XCTAssertEqual(box.count, 1)
            XCTAssertTrue(gate.isLeft)
        }
    }

    func testAResultBeforeTheLatchIsAccepted() {
        let gate = LiveRunGate()
        XCTAssertEqual(gate.decideResult(), .accept)
        XCTAssertTrue(gate.decideResult().writeDump)
        XCTAssertTrue(gate.decideResult().offer)
        XCTAssertTrue(gate.decideResult().forward)
    }

    func testAResultAfterTheLatchIsDroppedNotOfferedNotDumpedNotSentFurther() {
        let gate = LiveRunGate()
        gate.latchLeft()
        let decision = gate.decideResult()
        XCTAssertEqual(decision, .drop)
        XCTAssertFalse(decision.writeDump, "the debug dump does not record a result that was dropped late")
        XCTAssertFalse(decision.offer, "nothing is offered")
        XCTAssertFalse(decision.forward, "nothing is sent further")
    }

    func testTheDecisionFollowsTheLatchEveryTimeItIsAsked() {
        let gate = LiveRunGate()
        XCTAssertEqual(gate.decideResult(), .accept)
        gate.latchLeft()
        for _ in 0..<3 { XCTAssertEqual(gate.decideResult(), .drop) }
    }
}

final class WinnerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class LiveActivationLeftTests: XCTestCase {
    private let wanted = "org.m0k.transmission"
    private let other = "com.example.otherapp"

    func testAnotherAppBeingActivatedIsALeaveWhateverIsInFrontNow() {
        // The notification names the activated app. A leave-and-return that both queued while main was busy still names the other app.
        let why = LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: other, activatedPID: 200, ownPID: 1)
        XCTAssertEqual(why, LiveTargetGate.wrongFrontText(front: other, wanted: wanted))
    }

    func testTheTargetBeingActivatedIsNotALeave() {
        XCTAssertNil(LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: wanted, activatedPID: 100, ownPID: 1))
        XCTAssertNil(LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: wanted.uppercased(), activatedPID: 100, ownPID: 1))
    }

    func testShepItselfBeingActivatedIsNotALeave() {
        XCTAssertNil(LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: "com.example.shep", activatedPID: 1, ownPID: 1))
        XCTAssertNil(LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: nil, activatedPID: 1, ownPID: 1))
    }

    func testAnActivatedAppWithNoBundleIDIsALeave() {
        let why = LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: nil, activatedPID: 200, ownPID: 1)
        XCTAssertEqual(why, LiveTargetGate.wrongFrontText(front: nil, wanted: wanted))
    }

    func testANotificationThatNamesNoAppIsNotALook() {
        XCTAssertNil(LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: nil, activatedPID: nil, ownPID: 1),
                     "nothing to judge: the poll and the rechecks still look at the live front app")
    }

    func testTheTextIsOneLineWithBundleIDsOnly() {
        let text = LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: "com.example.x\nsecond", activatedPID: 9, ownPID: 1) ?? ""
        XCTAssertTrue(text.hasPrefix("target: "))
        XCTAssertFalse(text.contains("\n"))
    }

    func testTheLiveFrontLookStillJudgesTheFrontAppForTheCardChecks() {
        // Before the card and after the approval the coordinator reads the live front app (not a flag).
        XCTAssertNil(LiveTargetGate.focusLeft(wanted: wanted, front: wanted, frontIsShep: false))
        XCTAssertNotNil(LiveTargetGate.focusLeft(wanted: wanted, front: other, frontIsShep: false))
        XCTAssertNil(LiveTargetGate.focusLeft(wanted: wanted, front: other, frontIsShep: true))
    }
}

final class LiveHitBindingTests: XCTestCase {
    func testOnlyAHitInTheApprovedAppMayBeInspected() {
        XCTAssertTrue(LiveBinding.mayReadHit(hitPID: 100, approvedPID: 100))
        XCTAssertFalse(LiveBinding.mayReadHit(hitPID: 200, approvedPID: 100), "another app's element is not read: not its role, actions, frame or identity")
        XCTAssertFalse(LiveBinding.mayReadHit(hitPID: nil, approvedPID: 100))
    }
}
