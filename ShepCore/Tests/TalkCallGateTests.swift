import XCTest
@testable import ShepCore

/// Review H1: a voice call made from Shep's own window joins two readinesses, the focus handoff and the end of the question,
/// in either order. Exactly one request goes to the pipeline, only after the handoff, and under VoiceOver Shep never wakes
/// while the caller is still asking.
final class TalkCallGateTests: XCTestCase {
    private let ask = "turn on the speed limit"

    // MARK: no handoff (unchanged behaviour)

    func testWithoutVoiceOverShepWakesAtOnceAndTheRequestFollows() {
        var g = TalkCallGate()
        XCTAssertEqual(g.begin(handoff: false, voiceOverRunning: false).effects, [.call(forQuestion: false)])
        XCTAssertEqual(g.questionEnded(ask), [.submit(ask)])
    }

    func testWithVoiceOverShepComesOutWithTheRequest() {
        var g = TalkCallGate()
        XCTAssertEqual(g.begin(handoff: false, voiceOverRunning: true).effects, [])
        XCTAssertEqual(g.questionEnded(ask), [.call(forQuestion: true), .submit(ask)])
    }

    // MARK: handoff confirmed before the question ends

    func testConfirmBeforeFinalWithoutVoiceOver() {
        var g = TalkCallGate()
        let gen = g.begin(handoff: true, voiceOverRunning: false)
        XCTAssertEqual(gen.effects, [], "nothing is called before the previous app is back")
        XCTAssertEqual(g.handoffCalled(generation: gen.generation), [.call(forQuestion: false)])
        XCTAssertEqual(g.questionEnded(ask), [.submit(ask)])
    }

    func testConfirmBeforeFinalWithVoiceOverDoesNotWakeDuringTheQuestion() {
        var g = TalkCallGate()
        let gen = g.begin(handoff: true, voiceOverRunning: true)
        XCTAssertEqual(g.handoffCalled(generation: gen.generation), [], "under VoiceOver Shep stays home while the caller asks")
        XCTAssertEqual(g.questionEnded(ask), [.call(forQuestion: true), .submit(ask)])
    }

    // MARK: question ends before the handoff confirms

    func testFinalBeforeConfirmIsHeldThenSubmittedOnce() {
        for vo in [false, true] {
            var g = TalkCallGate()
            let gen = g.begin(handoff: true, voiceOverRunning: vo)
            XCTAssertEqual(g.questionEnded(ask), [], "held: Shep is still in front (vo \(vo))")
            XCTAssertTrue(g.isHolding)
            XCTAssertEqual(g.handoffCalled(generation: gen.generation), [.call(forQuestion: true), .submit(ask)])
            XCTAssertFalse(g.isHolding)
            XCTAssertEqual(g.handoffCalled(generation: gen.generation), [], "a duplicate callback does nothing")
        }
    }

    func testTimedOutHandoffStillSubmitsAndThePipelineDecides() {
        // FocusHandoff calls on timeout too; the pipeline then refuses if Shep is still in front (never Shep's own window).
        var g = TalkCallGate()
        let gen = g.begin(handoff: true, voiceOverRunning: true)
        _ = g.questionEnded(ask)
        XCTAssertEqual(g.handoffCalled(generation: gen.generation), [.call(forQuestion: true), .submit(ask)])
    }

    // MARK: cancellation and abandonment

    func testAbandonedHandoffDropsTheHeldRequest() {
        var g = TalkCallGate()
        let gen = g.begin(handoff: true, voiceOverRunning: false)
        _ = g.questionEnded(ask)
        g.handoffAbandoned(generation: gen.generation)
        XCTAssertFalse(g.isHolding)
        XCTAssertEqual(g.handoffCalled(generation: gen.generation), [])
    }

    func testAbandonedBeforeEitherCallsNothing() {
        var g = TalkCallGate()
        let gen = g.begin(handoff: true, voiceOverRunning: true)
        g.handoffAbandoned(generation: gen.generation)
        XCTAssertEqual(g.handoffCalled(generation: gen.generation), [])
    }

    func testCancelBeforeEitherCallsNothing() {
        var g = TalkCallGate()
        let gen = g.begin(handoff: true, voiceOverRunning: false)
        g.cancel()
        XCTAssertEqual(g.handoffCalled(generation: gen.generation), [], "a cancelled call does not wake Shep later")
    }

    func testCancelWhileHoldingDropsTheRequest() {
        var g = TalkCallGate()
        let gen = g.begin(handoff: true, voiceOverRunning: true)
        _ = g.questionEnded(ask)
        g.cancel()
        XCTAssertEqual(g.handoffCalled(generation: gen.generation), [])
    }

    // MARK: generations

    func testAStaleHandoffFromAnEarlierCallIsIgnored() {
        var g = TalkCallGate()
        let first = g.begin(handoff: true, voiceOverRunning: true)
        let second = g.begin(handoff: true, voiceOverRunning: true)
        XCTAssertNotEqual(first.generation, second.generation)
        _ = g.questionEnded(ask)
        XCTAssertEqual(g.handoffCalled(generation: first.generation), [])
        g.handoffAbandoned(generation: first.generation)
        XCTAssertTrue(g.isHolding, "an old handoff cannot drop the new call's request")
        XCTAssertEqual(g.handoffCalled(generation: second.generation), [.call(forQuestion: true), .submit(ask)])
    }

    func testExactlyOneSubmitPerCall() {
        var g = TalkCallGate()
        let gen = g.begin(handoff: true, voiceOverRunning: false)
        var effects = g.handoffCalled(generation: gen.generation)
        effects += g.questionEnded(ask)
        effects += g.handoffCalled(generation: gen.generation)
        XCTAssertEqual(effects.filter { if case .submit = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(effects.filter { if case .call = $0 { return true } else { return false } }.count, 1)
    }

    // MARK: a new press while the old handoff is pending

    func testSecondPressDropsTheHeldFirstQuestionAndNothingWakesDuringTheSecond() {
        var g = TalkCallGate()
        let first = g.begin(handoff: true, voiceOverRunning: true)
        XCTAssertEqual(g.questionEnded(ask), [], "call 1's final is held")
        g.cancel()   // the app stops the old waiter and cancels the old generation
        let second = g.begin(handoff: true, voiceOverRunning: true)
        XCTAssertFalse(g.isHolding, "call 1's held text is gone")
        XCTAssertEqual(g.handoffCalled(generation: first.generation), [], "old handoff confirms: nothing for call 1, no wake")
        g.handoffAbandoned(generation: first.generation)
        XCTAssertEqual(g.handoffCalled(generation: second.generation), [], "under VoiceOver Shep stays home during call 2's question")
    }

    func testSecondPressWhileOldWaiterPendingBehavesLikeANormalCall() {
        for vo in [false, true] {
            var g = TalkCallGate()
            let first = g.begin(handoff: true, voiceOverRunning: vo)
            g.cancel()
            let second = g.begin(handoff: false, voiceOverRunning: vo)
            XCTAssertEqual(second.effects, vo ? [] : [.call(forQuestion: false)])
            XCTAssertEqual(g.handoffCalled(generation: first.generation), [], "old callbacks are ignored (vo \(vo))")
            let end = g.questionEnded("second question")
            XCTAssertEqual(end, vo ? [.call(forQuestion: true), .submit("second question")] : [.submit("second question")])
            XCTAssertEqual(g.handoffCalled(generation: first.generation), [])
        }
    }

    // MARK: a closed gate drops late transcripts

    func testALateFinalAfterCancelIsDropped() {
        var g = TalkCallGate()
        XCTAssertEqual(g.questionEnded(ask), [], "a gate that never opened a call")
        _ = g.begin(handoff: false, voiceOverRunning: false)
        g.cancel()
        XCTAssertEqual(g.questionEnded(ask), [])
    }

    func testALateFinalAfterASubmitIsDropped() {
        var g = TalkCallGate()
        _ = g.begin(handoff: false, voiceOverRunning: false)
        XCTAssertEqual(g.questionEnded(ask), [.submit(ask)])
        XCTAssertEqual(g.questionEnded(ask), [], "the call is finished: a second final does nothing")
    }
}
