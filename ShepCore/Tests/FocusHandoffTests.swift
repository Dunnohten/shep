import XCTest
@testable import ShepCore

/// Code review F2: a call made while Shep's own window is in front hands the focus back and waits for it, so the 0.6 s dock check
/// sees the previous app's window instead of Shep's.
final class FocusHandoffTests: XCTestCase {
    private let previous: Int32 = 501
    private let own: Int32 = 77

    func testStartAsksForActivationAndDoesNotCallYet() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        XCTAssertEqual(h.start(), [.log(WakeLog.handoffRequested), .activate(previous)])
        XCTAssertNil(h.outcome)
    }

    func testConfirmedActivationRefreshesTheTrackerThenCalls() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        XCTAssertEqual(h.observe(frontmostPID: own, elapsed: 0.1), [], "still Shep in front: keep waiting")
        XCTAssertEqual(h.observe(frontmostPID: previous, elapsed: 0.2), [.log(WakeLog.handoffConfirmed), .refreshTracker, .call])
        XCTAssertEqual(h.outcome, .confirmed)
    }

    func testTimeoutCallsWithoutClaimingTheHandoff() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        XCTAssertEqual(h.observe(frontmostPID: own, elapsed: FocusHandoff.timeoutSeconds - 0.01), [])
        XCTAssertEqual(h.observe(frontmostPID: own, elapsed: FocusHandoff.timeoutSeconds), [.log(WakeLog.handoffFailed), .call])
        XCTAssertEqual(h.outcome, .timedOut)
    }

    // Code review R3: the handoff confirms only when the target is in front at the moment of the look, and a foreign app coming to
    // the front is the user leaving: the handoff is abandoned and nothing is called.

    func testAnotherAppActivatingIsNotAConfirmationAndAbandonsTheHandoff() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        XCTAssertEqual(h.observe(frontmostPID: 999, elapsed: 0.3), [.log(WakeLog.handoffAbandoned), .cancelVoice])
        XCTAssertEqual(h.outcome, .abandoned)
    }

    func testAnUnknownFrontAppKeepsWaiting() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        XCTAssertEqual(h.observe(frontmostPID: nil, elapsed: 0.4), [])
        XCTAssertNil(h.outcome)
    }

    func testAStaleNoteForTheTargetDoesNotConfirmWhenAForeignAppIsInFront() {
        // The target's activation note is queued, the user switches to another app, and the note is handled afterwards:
        // the look reads the front app at handling time (999), not the note's pid.
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        let effects = h.observe(frontmostPID: 999, elapsed: 0.2)
        XCTAssertFalse(effects.contains(.call))
        XCTAssertFalse(effects.contains(.log(WakeLog.handoffConfirmed)))
        XCTAssertNotEqual(h.outcome, .confirmed)
    }

    func testTheTimeoutWithAForeignAppInFrontDoesNotCall() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        let effects = h.observe(frontmostPID: 999, elapsed: FocusHandoff.timeoutSeconds)
        XCTAssertFalse(effects.contains(.call))
        XCTAssertEqual(effects, [.log(WakeLog.handoffAbandoned), .cancelVoice])
        XCTAssertEqual(h.outcome, .abandoned)
    }

    func testAnAbandonedHandoffNeverCallsLater() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        _ = h.observe(frontmostPID: 999, elapsed: 0.3)
        XCTAssertEqual(h.observe(frontmostPID: previous, elapsed: 0.5), [], "the target arriving afterwards does not revive it")
        XCTAssertEqual(h.observe(frontmostPID: own, elapsed: 5), [])
        XCTAssertEqual(h.outcome, .abandoned)
    }

    func testWaitingBehindShepsOwnWindowStillConfirmsWhenTheTargetArrives() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        XCTAssertEqual(h.observe(frontmostPID: own, elapsed: 0.1), [])
        XCTAssertEqual(h.observe(frontmostPID: previous, elapsed: 0.2), [.log(WakeLog.handoffConfirmed), .refreshTracker, .call])
    }

    func testAbandonedHasItsOwnFixedLogLine() {
        XCTAssertEqual(WakeLog.handoffAbandoned, "[shep] wake: focus handoff abandoned (another app came to the front)")
    }

    func testTheOutcomeFiresOnce() {
        var h = FocusHandoff(pid: previous, ownPID: own)
        _ = h.start()
        XCTAssertFalse(h.observe(frontmostPID: previous, elapsed: 0.1).isEmpty)
        XCTAssertEqual(h.observe(frontmostPID: previous, elapsed: 0.2), [], "a second activation note does not call again")
        XCTAssertEqual(h.observe(frontmostPID: own, elapsed: 5), [], "nor does the timeout after a confirmation")
        XCTAssertEqual(h.outcome, .confirmed)
    }

    func testTheWaitIsBoundedAboveTheWakeStretch() {
        XCTAssertEqual(FocusHandoff.timeoutSeconds, 1.0)
        XCTAssertGreaterThan(FocusHandoff.timeoutSeconds, LifecycleTimings.wakeSeconds)
    }

    func testTheLogLinesAreFixedAndSayWhatWasConfirmed() {
        XCTAssertEqual(WakeLog.handoffRequested, "[shep] wake: Shep was in front; focus handoff requested")
        XCTAssertEqual(WakeLog.handoffConfirmed, "[shep] wake: focus handed back to the previous app")
        XCTAssertEqual(WakeLog.handoffFailed, "[shep] wake: focus handoff failed (timeout)")
    }
}
