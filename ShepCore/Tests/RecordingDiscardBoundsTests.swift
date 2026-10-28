import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of d8213e1 (N1): a discard is never reported as done while a start or a stop is still in flight.
// `recording-discarded` and `never-started` are claimed only when they are true; a start or stop that does not finish within its bound
// is `discard-unknown` (a clip may remain); a removal that fails is `failed`.

/// A suspension point the test controls: `suspend()` parks the caller on a continuation until `resume()`.
final class Suspender: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var parked = false
    private var released = false

    func suspend() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released { lock.unlock(); c.resume(); return }
            continuation = c
            parked = true
            lock.unlock()
        }
    }

    func resume() {
        lock.lock()
        released = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    var isParked: Bool { lock.lock(); defer { lock.unlock() }; return parked && !released }

    /// True once a caller is parked in `suspend()` (polls for at most about 10 s).
    func waitUntilParked() async -> Bool {
        for _ in 0..<2000 {
            if isParked { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class RecordingDiscardPlannerTests: XCTestCase {
    func testNeverStartedOnlyWhenNoStartWasEverLaunched() {
        XCTAssertEqual(RecordingDiscardPlanner.afterStartWait(startLaunched: false, wait: .completed), .neverStarted)
    }

    func testALaunchedStartIsNeverReportedAsNeverStarted() {
        for wait in [RecordingWaitResult.completed, .timedOut] {
            XCTAssertNotEqual(RecordingDiscardPlanner.afterStartWait(startLaunched: true, wait: wait), .neverStarted, "\(wait)")
        }
    }

    func testAStartThatCompletesWithinTheBoundLetsTheDiscardProceed() {
        XCTAssertEqual(RecordingDiscardPlanner.afterStartWait(startLaunched: true, wait: .completed), .proceed)
    }

    func testAStartStillInFlightBeyondTheBoundIsUnknown() {
        guard case .unknown(let text) = RecordingDiscardPlanner.afterStartWait(startLaunched: true, wait: .timedOut) else {
            return XCTFail("a start in flight past its bound must be unknown, not a discard")
        }
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("\n"))
    }

    func testAnEndThatDoesNotFinishWithinTheBoundIsUnknown() {
        XCTAssertEqual(RecordingDiscardPlanner.afterEndWait(wait: .completed), .proceed)
        guard case .unknown = RecordingDiscardPlanner.afterEndWait(wait: .timedOut) else { return XCTFail("unknown expected") }
    }

    func testAStopThatTimedOutIsUnknownEvenWhenTheRemovalWorked() {
        guard case .unknown = RecordingDiscardPlanner.finalOutcome(removal: .removed, stopCompleted: false) else {
            return XCTFail("the stream may still be writing: never claim a discard")
        }
        guard case .unknown = RecordingDiscardPlanner.finalOutcome(removal: .failed("x"), stopCompleted: false) else {
            return XCTFail("unknown expected")
        }
    }

    func testARemovalThatFailsIsFailedNotDiscarded() {
        XCTAssertEqual(RecordingDiscardPlanner.finalOutcome(removal: .failed("could not remove"), stopCompleted: true), .failed("could not remove"))
    }

    func testARemovalThatWorkedAfterACompletedStopIsRemoved() {
        XCTAssertEqual(RecordingDiscardPlanner.finalOutcome(removal: .removed, stopCompleted: true), .removed)
    }

    func testOtherOutcomesPassThroughAfterACompletedStop() {
        XCTAssertEqual(RecordingDiscardPlanner.finalOutcome(removal: .alreadyPublished, stopCompleted: true), .alreadyPublished)
        XCTAssertEqual(RecordingDiscardPlanner.finalOutcome(removal: .neverStarted, stopCompleted: true), .neverStarted)
    }

    func testUnknownHasItsOwnEventAndIsNotADiscard() {
        let outcome = RecordingDiscardOutcome.unknown("still running")
        XCTAssertEqual(outcome.statusEvent, .recordingDiscardUnknown)
        XCTAssertNotEqual(outcome.statusEvent, .recordingDiscarded(refused: false))
        XCTAssertNotEqual(outcome.statusEvent, .recordingDiscarded(refused: true))
        XCTAssertEqual(LiveStatus.line(nonce: "0123456789abcdef0123456789abcdef", event: .recordingDiscardUnknown),
                       "0123456789abcdef0123456789abcdef discard-unknown")
    }

    func testTheBoundsAddUpToLessThanTheScriptsDrain() {
        // scripts/record-fix-demo.sh waits SHEP_DRAIN_WAIT (default 60 s) for the outcome before it stops Shep.
        let worst = RecordingDiscardPlanner.startBoundSeconds + RecordingDiscardPlanner.endBoundSeconds
        XCTAssertLessThan(worst, 60)
        XCTAssertLessThan(RecordingDiscardPlanner.stopBoundSeconds + RecordingDiscardPlanner.movieWaitSeconds + 5, RecordingDiscardPlanner.endBoundSeconds,
                          "a stop (bounded), the movie wait and 5 s of file work fit inside the end bound")
    }

    func testAStopTimeoutNeverPublishes() {
        let decision = RecordingEndPlanner.decide(requested: nil, pendingDiscard: nil, slotProblem: nil, failure: nil,
                                                  clipSize: 100, movieFinished: true, stopCompleted: false)
        guard case .discard = decision else { return XCTFail("a stream that did not stop must not be published") }
    }
}

final class BoundedAwaitTests: XCTestCase {
    func testAnOperationThatFinishesInTimeGivesItsValue() async {
        let result = await BoundedAwait.run(seconds: 5) { 42 }
        guard case .value(let v) = result else { return XCTFail("expected a value") }
        XCTAssertEqual(v, 42)
    }

    func testAnOperationThatNeverFinishesTimesOut() async {
        let s = Suspender()
        let result = await BoundedAwait.run(seconds: 0.1) { await s.suspend() }
        XCTAssertTrue(result.didTimeOut)
        s.resume()   // let the abandoned operation end
    }

    func testAnOptionalResultIsNotMistakenForATimeout() async {
        let result = await BoundedAwait.run(seconds: 5) { () -> String? in nil }
        guard case .value(let v) = result else { return XCTFail("a nil result is still a value") }
        XCTAssertNil(v)
    }
}

final class RecordingDiscardFlowTests: XCTestCase {
    @MainActor
    func testNoStartEverLaunchedIsNeverStartedAndNothingIsPerformed() async {
        let performed = CallCounter()
        let outcome = await RecordingDiscardFlow.resolve(startLaunched: false, awaitStart: {}, startBoundSeconds: 1,
                                                         perform: { performed.add(); return .removed })
        XCTAssertEqual(outcome, .neverStarted)
        XCTAssertEqual(performed.count, 0)
    }

    @MainActor
    func testAStartInFlightThatCompletesIsAwaitedThenTheDiscardIsPerformedAndReportedDiscarded() async {
        let start = Suspender()
        let performed = CallCounter()
        let flow = Task { @MainActor () -> RecordingDiscardOutcome in
            await RecordingDiscardFlow.resolve(startLaunched: true, awaitStart: { await start.suspend() }, startBoundSeconds: 10,
                                               perform: { performed.add(); return .removed })
        }
        let parked = await start.waitUntilParked()
        XCTAssertTrue(parked)
        XCTAssertEqual(performed.count, 0, "nothing is discarded or reported while the start is still running")
        start.resume()
        let outcome = await flow.value
        XCTAssertEqual(performed.count, 1, "the discard is performed once the start has finished")
        XCTAssertEqual(outcome, .removed)
    }

    @MainActor
    func testAStartInFlightBeyondTheBoundIsUnknownAndNoDiscardIsClaimed() async {
        let start = Suspender()
        let performed = CallCounter()
        let outcome = await RecordingDiscardFlow.resolve(startLaunched: true, awaitStart: { await start.suspend() }, startBoundSeconds: 0.1,
                                                         perform: { performed.add(); return .removed })
        guard case .unknown = outcome else { start.resume(); return XCTFail("expected unknown, got \(outcome)") }
        XCTAssertEqual(performed.count, 0, "removal is not claimed while the start may still write")
        XCTAssertNotEqual(outcome.statusEvent, .recordingDiscarded(refused: true))
        XCTAssertNotEqual(outcome.statusEvent, .recordingDiscarded(refused: false))
        start.resume()
    }

    @MainActor
    func testAFailedRemovalAfterTheStartIsFailed() async {
        let outcome = await RecordingDiscardFlow.resolve(startLaunched: true, awaitStart: {}, startBoundSeconds: 5,
                                                         perform: { .failed("could not remove the working directory") })
        XCTAssertEqual(outcome, .failed("could not remove the working directory"))
    }

    @MainActor
    func testAStopTimeoutReportedByThePerformStepStaysUnknown() async {
        let outcome = await RecordingDiscardFlow.resolve(startLaunched: true, awaitStart: {}, startBoundSeconds: 5,
                                                         perform: { RecordingDiscardPlanner.finalOutcome(removal: .removed, stopCompleted: false) })
        guard case .unknown = outcome else { return XCTFail("expected unknown, got \(outcome)") }
    }
}
