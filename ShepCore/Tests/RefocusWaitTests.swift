import XCTest
@testable import ShepCore

/// After a doghouse press hands focus back to the previous app, activation is asynchronous: the wake must not decide
/// "no window" while that app is still coming to the front. It waits, polling, up to a limit; without a refocus it never waits.
final class RefocusWaitTests: XCTestCase {
    func testNoRefocusNeverWaits() {
        XCTAssertFalse(RefocusWait.keepWaiting(refocusRequested: false, hasTarget: false, waited: 0))
    }

    func testATargetEndsTheWait() {
        XCTAssertFalse(RefocusWait.keepWaiting(refocusRequested: true, hasTarget: true, waited: 0))
    }

    func testWaitsForTheRefocusedAppUntilTheLimit() {
        XCTAssertTrue(RefocusWait.keepWaiting(refocusRequested: true, hasTarget: false, waited: 0))
        XCTAssertTrue(RefocusWait.keepWaiting(refocusRequested: true, hasTarget: false, waited: RefocusWait.limitSeconds - RefocusWait.pollSeconds))
        XCTAssertFalse(RefocusWait.keepWaiting(refocusRequested: true, hasTarget: false, waited: RefocusWait.limitSeconds))
    }

    func testLimitAndPollAreSane() {
        XCTAssertGreaterThan(RefocusWait.pollSeconds, 0)
        XCTAssertLessThanOrEqual(RefocusWait.limitSeconds, 2.0)   // the user hears "no window" soon if the app never comes
        XCTAssertGreaterThan(RefocusWait.limitSeconds, LifecycleTimings.wakeSeconds)
    }

    func testOnlyTheDoghouseRequestsARefocus() {
        XCTAssertTrue(RefocusWait.requested(source: .doghouse, activationAccepted: true))
        XCTAssertFalse(RefocusWait.requested(source: .doghouse, activationAccepted: false))   // activate() refused: decide at once
        XCTAssertFalse(RefocusWait.requested(source: .menu, activationAccepted: true))
    }
}
