import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of 6d026eb (F1): when the target leaves, a recording is discarded and the outcome is reported
// BEFORE the run says target-left and finished; a discard requested while a keep is finalising wins; `recording-discarded` means the
// removal succeeded, and the other outcomes are their own events.

final class RecordingDiscardStatusTests: XCTestCase {
    let nonce = "0123456789abcdef0123456789abcdef"

    func testTheNewEventsAreClosedSetTokens() {
        XCTAssertEqual(LiveStatus.line(nonce: nonce, event: .recordingDiscardFailed), nonce + " discard-failed")
        XCTAssertEqual(LiveStatus.line(nonce: nonce, event: .recordingAlreadyPublished), nonce + " recording-already-published")
    }

    func testEachOutcomeMapsToItsOwnEvent() {
        XCTAssertEqual(RecordingDiscardOutcome.removed.statusEvent, .recordingDiscarded(refused: false))
        XCTAssertEqual(RecordingDiscardOutcome.failed("x").statusEvent, .recordingDiscardFailed)
        XCTAssertEqual(RecordingDiscardOutcome.alreadyPublished.statusEvent, .recordingAlreadyPublished)
        XCTAssertEqual(RecordingDiscardOutcome.neverStarted.statusEvent, .recordingDiscarded(refused: true))
    }

    func testOnlyARealRemovalIsRemoved() {
        XCTAssertEqual(RecordingDiscardOutcome(slotResult: .removed), .removed)
        for result in [RecordingDiscardResult.identityMismatch, .clipReplaced("replaced"), .leftBehind("left"), .alreadyFinished] {
            guard case .failed = RecordingDiscardOutcome(slotResult: result) else { return XCTFail("\(result) must not be reported as removed") }
        }
        XCTAssertEqual(RecordingDiscardOutcome(slotResult: .leftBehind("left it")), .failed("left it"))
    }
}

final class RecordingEndPlannerTests: XCTestCase {
    private func decide(requested: String? = nil, pending: String? = nil, problem: String? = nil, failure: String? = nil,
                        size: Int = 100, finished: Bool = true) -> RecordingEndDecision {
        RecordingEndPlanner.decide(requested: requested, pendingDiscard: pending, slotProblem: problem, failure: failure,
                                   clipSize: size, movieFinished: finished)
    }

    func testAGoodFinishedClipIsPublished() {
        XCTAssertEqual(decide(), .publish)
    }

    func testADiscardRequestedWhileAKeepWasFinalisingWinsOverAGoodClip() {
        XCTAssertEqual(decide(pending: "the target left the front"), .discard("the target left the front"))
    }

    func testAnExplicitDiscardWinsOverAPendingOne() {
        XCTAssertEqual(decide(requested: "first", pending: "second"), .discard("first"))
    }

    func testThePendingDiscardWinsOverEveryOtherProblem() {
        XCTAssertEqual(decide(pending: "left", problem: "swapped", failure: "boom", size: 0, finished: false), .discard("left"))
    }

    func testOtherProblemsStillDiscard() {
        XCTAssertEqual(decide(problem: "swapped"), .discard("swapped"))
        XCTAssertEqual(decide(failure: "boom"), .discard("the recording failed: boom"))
        XCTAssertEqual(decide(size: 0), .discard("the movie was not finished"))
        XCTAssertEqual(decide(finished: false), .discard("the movie was not finished"))
    }
}

final class RecordingSlotDiscardIntentTests: XCTestCase {
    private func makeSlot(_ label: String) throws -> (slot: RecordingSlot, dir: String, final: String) {
        let dir = SlotFS.freshDirectory(label)
        let final = dir + "/out.mov"
        switch RecordingSlot.claim(finalPath: final) {
        case .success(let slot): return (slot, dir, final)
        case .failure(let refusal): throw NSError(domain: "claim", code: 1, userInfo: [NSLocalizedDescriptionKey: refusal.reason])
        }
    }

    func testADiscardRequestedBeforeThePublishStopsTheLinkAndLeavesTheClipForTheDiscard() throws {
        let s = try makeSlot("intent-before")
        SlotFS.write("the movie", to: s.slot.clipPath)
        XCTAssertEqual(s.slot.requestDiscard(), .latched)
        XCTAssertTrue(s.slot.discardWasRequested)
        XCTAssertEqual(s.slot.publish(), .discardRequested)
        XCTAssertFalse(SlotFS.lexists(s.final), "the clip was never published")
        XCTAssertEqual(SlotFS.read(s.slot.clipPath), "the movie", "nothing was removed by the refused publish")
        XCTAssertEqual(s.slot.discard(), .removed)
        XCTAssertEqual(SlotFS.names(in: s.dir), [], "the clip and the working directory are gone")
    }

    func testADiscardRequestedAfterThePublishSaysTheClipIsAlreadyPublished() throws {
        let s = try makeSlot("intent-after")
        SlotFS.write("the movie", to: s.slot.clipPath)
        XCTAssertEqual(s.slot.publish(), .published)
        XCTAssertEqual(s.slot.requestDiscard(), .alreadyPublished)
        XCTAssertEqual(SlotFS.read(s.final), "the movie", "the published file is not touched")
    }

    func testTheRequestIsLatchedFromInsideThePublishWindow() throws {
        // The request arrives between the checks of publish() and the link: the hook runs right before publish() looks at the file system.
        let s = try makeSlot("intent-window")
        SlotFS.write("the movie", to: s.slot.clipPath)
        s.slot.beforePublish = { XCTAssertEqual(s.slot.requestDiscard(), .latched) }
        XCTAssertEqual(s.slot.publish(), .discardRequested)
        XCTAssertFalse(SlotFS.lexists(s.final))
    }

    func testARequestOnASlotThatWasDiscardedIsLatchedNotPublished() throws {
        let s = try makeSlot("intent-discarded")
        SlotFS.write("the movie", to: s.slot.clipPath)
        XCTAssertEqual(s.slot.discard(), .removed)
        XCTAssertEqual(s.slot.requestDiscard(), .latched)
        XCTAssertEqual(s.slot.publish(), .alreadyFinished)
        XCTAssertFalse(SlotFS.lexists(s.final))
    }

    func testRequestAndPublishRacingAlwaysAgree() throws {
        // Either the clip was linked and the request says so, or it was latched and nothing is at the final path. Never both, never neither.
        for round in 0..<40 {
            let s = try makeSlot("intent-race-\(round)")
            SlotFS.write("the movie", to: s.slot.clipPath)
            let seen = RaceResults()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { seen.publish = s.slot.publish() } else { seen.request = s.slot.requestDiscard() }
            }
            switch (seen.publish, seen.request) {
            case (.published?, .alreadyPublished?):
                XCTAssertEqual(SlotFS.read(s.final), "the movie")
            case (.discardRequested?, .latched?):
                XCTAssertFalse(SlotFS.lexists(s.final), "a latched discard never publishes")
            default:
                XCTFail("publish \(String(describing: seen.publish)) and request \(String(describing: seen.request)) disagree")
            }
        }
    }
}

final class RaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var p: RecordingPublishResult?
    private var r: RecordingDiscardRequest?
    var publish: RecordingPublishResult? { get { lock.lock(); defer { lock.unlock() }; return p } set { lock.lock(); p = newValue; lock.unlock() } }
    var request: RecordingDiscardRequest? { get { lock.lock(); defer { lock.unlock() }; return r } set { lock.lock(); r = newValue; lock.unlock() } }
}
