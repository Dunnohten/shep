import XCTest
@testable import ShepCore

/// Code review F4: when Shep finds no window and goes home, the voice session goes with it: capture, transcript and any submit.
final class NoTargetVoiceCancelTests: XCTestCase {
    /// The voice side as the coordinator sees it: `cancelVoice()` sends `.cancel` to a real `VoiceSession`, and every effect
    /// it produces is recorded, so a later submit would show.
    private final class FakeVoice: VoiceCancelling {
        var session = VoiceSession()
        var effects: [VoiceEffect] = []
        func send(_ event: VoiceEvent) { effects += session.handle(event) }
        func cancelVoice() { send(.cancel) }
        var submitted: [String] { effects.compactMap { if case .submit(let t) = $0 { return t } else { return nil } } }
    }

    /// What `ShepCoordinator.perform` does with the voice effect and the fix-task effect.
    private func carryOut(_ effects: [LifecycleEffect], voice: VoiceCancelling, cancelFixTask: () -> Void = {}) {
        for effect in effects {
            if effect == .cancelVoice { voice.cancelVoice() }
            if effect == .cancelFixTask { cancelFixTask() }
        }
    }

    private func talking() -> FakeVoice {
        let v = FakeVoice()
        v.send(.press(microphone: .granted, speech: .granted))
        v.send(.partial("turn on the speed"))
        XCTAssertEqual(v.session.state, .listening)
        return v
    }

    func testNoTargetAfterTheWakeCancelsTheVoiceSession() {
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk))
        let effects = l.handle(.wakeFinished(hasTarget: false))
        XCTAssertEqual(effects, [.cancelVoice, .cancelFixTask, .stopTracking, .sleep])
        XCTAssertEqual(l.state, .asleep)
    }

    func testAFailedArrivalOnTheWayCancelsTheVoiceSession() {
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk)); l.handle(.wakeFinished(hasTarget: true))
        XCTAssertEqual(l.handle(.arrivalFailed), [.cancelVoice, .cancelFixTask, .stopTracking, .beginReturn(reduced: false)])
        XCTAssertEqual(l.state, .returning)
    }

    func testAWindowToSitOnKeepsTheVoiceSession() {
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk))
        XCTAssertFalse(l.handle(.wakeFinished(hasTarget: true)).contains(.cancelVoice))
        XCTAssertFalse(l.handle(.arrived).contains(.cancelVoice))
    }

    func testNothingSubmitsAfterShepWentHomeWithoutATarget() {
        let voice = talking()
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk))
        carryOut(l.handle(.wakeFinished(hasTarget: false)), voice: voice)
        XCTAssertEqual(voice.session.state, .idle)
        XCTAssertEqual(voice.session.transcript, "")
        XCTAssertTrue(voice.effects.contains(.cancelCapture))
        // The recogniser's late final text, the silence release and the hold limit all find nothing to submit.
        voice.send(.final("turn on the speed limit"))
        voice.send(.release)
        voice.send(.timeout)
        XCTAssertEqual(voice.submitted, [])
    }

    func testAPendingSubmitAfterReleaseIsDroppedToo() {
        let voice = talking()
        voice.send(.release)
        XCTAssertEqual(voice.session.state, .finishing, "waiting for the final text")
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk)); l.handle(.wakeFinished(hasTarget: true))
        carryOut(l.handle(.arrivalFailed), voice: voice)
        voice.send(.final("turn on the speed limit"))
        voice.send(.timeout)
        XCTAssertEqual(voice.submitted, [])
    }

    // Code review R4: the final transcript can arrive before the no-target wake check, so the fix task already exists by then.
    // The voice session is idle at that point and `.cancelVoice` finds nothing; the task needs its own cancel.

    func testAFinalThatSubmittedBeforeTheNoTargetWakeStillGetsItsFixTaskCancelled() {
        let voice = talking()
        voice.send(.release)
        voice.send(.final("turn on the speed limit"))
        XCTAssertEqual(voice.submitted, ["turn on the speed limit"], "the fix task is created from this submit")
        XCTAssertEqual(voice.session.state, .idle)
        var cancels = 0
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk))
        carryOut(l.handle(.wakeFinished(hasTarget: false)), voice: voice, cancelFixTask: { cancels += 1 })
        XCTAssertEqual(cancels, 1)
    }

    func testAFailedArrivalCancelsTheFixTaskToo() {
        var cancels = 0
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk)); l.handle(.wakeFinished(hasTarget: true))
        carryOut(l.handle(.arrivalFailed), voice: FakeVoice(), cancelFixTask: { cancels += 1 })
        XCTAssertEqual(cancels, 1)
    }

    func testAWindowToSitOnLeavesTheFixTaskAlone() {
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk))
        XCTAssertFalse(l.handle(.wakeFinished(hasTarget: true)).contains(.cancelFixTask))
        XCTAssertFalse(l.handle(.arrived).contains(.cancelFixTask))
    }

    func testTheFixTaskIsCancelledAfterTheVoiceSession() {
        var l = ShepLifecycle()
        l.handle(.call(.pushToTalk))
        let effects = l.handle(.wakeFinished(hasTarget: false))
        XCTAssertEqual(effects.first, .cancelVoice)
        XCTAssertEqual(effects.dropFirst().first, .cancelFixTask)
    }
}
