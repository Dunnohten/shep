import XCTest
@testable import ShepCore

final class VoiceSessionTests: XCTestCase {
    func granted() -> VoiceEvent { .press(microphone: .granted, speech: .granted) }

    func testPressStartsListeningAndCapture() {
        var v = VoiceSession()
        XCTAssertEqual(v.handle(granted()), [.dogListening, .startCapture, .armTimeout(VoiceTimings.maxHoldSeconds)])
        XCTAssertEqual(v.state, .listening)
    }

    func testHoldSpeakReleaseSubmitsTheFinalText() {
        var v = VoiceSession()
        v.handle(granted())
        XCTAssertEqual(v.handle(.partial("open")), [.showPartial("open")])
        XCTAssertEqual(v.handle(.partial("open the settings")), [.showPartial("open the settings")])
        XCTAssertEqual(v.transcript, "open the settings")
        XCTAssertEqual(v.handle(.release), [.cancelTimeout, .stopCapture, .armTimeout(VoiceTimings.finalWaitSeconds)])
        XCTAssertEqual(v.state, .finishing)
        XCTAssertEqual(v.handle(.partial("open the settings")), [.showPartial("open the settings")], "late partials still update the pill")
        XCTAssertEqual(v.handle(.final("Open the settings.")), [.cancelTimeout, .clearPartial, .submit("Open the settings.")])
        XCTAssertEqual(v.state, .idle)
        XCTAssertEqual(v.transcript, "")
    }

    func testFinalTextWinsButAnEmptyFinalFallsBackToTheLastPartial() {
        var v = VoiceSession()
        v.handle(granted()); v.handle(.partial("find the gear")); v.handle(.release)
        XCTAssertEqual(v.handle(.final("")), [.cancelTimeout, .clearPartial, .submit("find the gear")])
    }

    func testNothingHeardApologisesInsteadOfSubmitting() {
        var v = VoiceSession()
        v.handle(granted()); v.handle(.release)
        let e = v.handle(.final("   "))
        XCTAssertEqual(e, [.cancelTimeout, .clearPartial, .dogIdle, .say("I didn\u{2019}t catch that.")])
        XCTAssertFalse(e.contains { if case .submit = $0 { return true } else { return false } })
    }

    func testTimeoutAfterReleaseUsesTheLastPartial() {
        var v = VoiceSession()
        v.handle(granted()); v.handle(.partial("go back")); v.handle(.release)
        XCTAssertEqual(v.handle(.timeout), [.cancelTimeout, .clearPartial, .submit("go back")])
        XCTAssertEqual(v.state, .idle)
    }

    func testHoldingTooLongIsTreatedAsARelease() {
        var v = VoiceSession()
        v.handle(granted())
        XCTAssertEqual(v.handle(.timeout), [.cancelTimeout, .stopCapture, .armTimeout(VoiceTimings.finalWaitSeconds)])
        XCTAssertEqual(v.state, .finishing)
    }

    func testRecogniserEndingByItselfWhileHeldStillSubmits() {
        var v = VoiceSession()
        v.handle(granted())
        XCTAssertEqual(v.handle(.final("search for cats")), [.cancelTimeout, .stopCapture, .clearPartial, .submit("search for cats")])
        XCTAssertEqual(v.state, .idle)
        XCTAssertEqual(v.handle(.release), [], "the key coming up afterwards does nothing")
    }

    func testCancelThrowsTheAudioAway() {
        var v = VoiceSession()
        v.handle(granted()); v.handle(.partial("half a sent"))
        XCTAssertEqual(v.handle(.cancel), [.cancelTimeout, .cancelCapture, .clearPartial, .dogIdle])
        XCTAssertEqual(v.state, .idle)
        XCTAssertEqual(v.transcript, "")
        XCTAssertEqual(v.handle(.final("half a sentence")), [], "a final from the dropped recogniser is ignored")
        XCTAssertEqual(v.handle(.cancel), [])
    }

    func testPermissionDeniedSaysSoAndOpensSetup() {
        var v = VoiceSession()
        let e = v.handle(.press(microphone: .denied, speech: .granted))
        XCTAssertEqual(e, [.clearPartial, .dogIdle, .say("Microphone is off for Shep. Turn it on in Setup to talk to me."), .showSetup])
        XCTAssertEqual(v.state, .idle)
        let both = v.handle(.press(microphone: .restricted, speech: .denied))
        XCTAssertTrue(both.contains(.say("Microphone and Speech Recognition are off for Shep. Turn it on in Setup to talk to me.")))
        XCTAssertFalse(both.contains(.startCapture))
    }

    func testNotAskedYetRequestsThePermissionsAndDoesNotListen() {
        var v = VoiceSession()
        let e = v.handle(.press(microphone: .notDetermined, speech: .notDetermined))
        XCTAssertTrue(e.contains(.requestPermissions([.microphone, .speech])))
        XCTAssertFalse(e.contains(.startCapture))
        XCTAssertEqual(v.state, .idle)
        let one = v.handle(.press(microphone: .granted, speech: .notDetermined))
        XCTAssertTrue(one.contains(.requestPermissions([.speech])))
        // Refused wins over not asked: Setup is the place to fix it.
        let mixed = v.handle(.press(microphone: .denied, speech: .notDetermined))
        XCTAssertTrue(mixed.contains(.showSetup))
        XCTAssertFalse(mixed.contains { if case .requestPermissions = $0 { return true } else { return false } })
    }

    func testFailuresReleaseTheKeyAndSayWhy() {
        var v = VoiceSession()
        v.handle(granted())
        let e = v.handle(.failed("no microphone"))
        XCTAssertEqual(e, [.cancelTimeout, .cancelCapture, .clearPartial, .dogIdle, .say("I couldn\u{2019}t listen: no microphone")])
        XCTAssertEqual(v.state, .idle)
        XCTAssertEqual(v.handle(.failed("again")), [], "idle ignores failures")
        // A failure after release with text already heard still submits it.
        var w = VoiceSession()
        w.handle(granted()); w.handle(.partial("zoom in")); w.handle(.release)
        XCTAssertEqual(w.handle(.failed("late")), [.cancelTimeout, .clearPartial, .submit("zoom in")])
    }

    func testPressWhileSpeakingInterruptsTheVoiceFirst() {
        var v = VoiceSession()
        v.handle(.speechStarted)
        XCTAssertTrue(v.speaking)
        let e = v.handle(granted())
        XCTAssertEqual(e.first, .stopSpeaking)
        XCTAssertFalse(v.speaking)
        v.handle(.speechEnded)
        XCTAssertFalse(v.speaking)
    }

    func testANewPressWhileFinishingStartsOver() {
        var v = VoiceSession()
        v.handle(granted()); v.handle(.partial("old")); v.handle(.release)
        let e = v.handle(granted())
        XCTAssertEqual(Array(e.prefix(2)), [.cancelCapture, .cancelTimeout])
        XCTAssertTrue(e.contains(.startCapture))
        XCTAssertEqual(v.state, .listening)
        XCTAssertEqual(v.transcript, "")
    }

    func testRequestsAreOneLineAndCapped() {
        var v = VoiceSession()
        v.handle(granted())
        v.handle(.release)
        let long = String(repeating: "a", count: 900)
        let e = v.handle(.final("first line\nsecond line " + long))
        guard case .submit(let text)? = e.last else { return XCTFail("\(e)") }
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual(text.count, VoiceTimings.maxRequestCharacters)
        XCTAssertTrue(text.hasPrefix("first line second line"))
    }

    func testStrayEventsWhileIdleDoNothing() {
        var v = VoiceSession()
        for e: VoiceEvent in [.partial("x"), .final("x"), .release, .timeout, .cancel, .failed("x")] {
            XCTAssertEqual(v.handle(e), [], "\(e)")
        }
    }
}

final class VoiceReplyPolicyTests: XCTestCase {
    func testSpokenWhenOnAndVoiceOverIsNotAlreadyTalking() {
        XCTAssertTrue(VoiceReplyPolicy.shouldSpeak(text: "Done.", enabled: true, voiceOverRunning: false))
        XCTAssertFalse(VoiceReplyPolicy.shouldSpeak(text: "Done.", enabled: false, voiceOverRunning: false), "muted")
        XCTAssertFalse(VoiceReplyPolicy.shouldSpeak(text: "Done.", enabled: true, voiceOverRunning: true), "VoiceOver announces it")
        XCTAssertFalse(VoiceReplyPolicy.shouldSpeak(text: " \n ", enabled: true, voiceOverRunning: false))
    }

    func testUtteranceIsOneLineAndShort() {
        XCTAssertEqual(VoiceReplyPolicy.utterance("Cancelled.\nNothing was done."), "Cancelled. Nothing was done.")
        XCTAssertEqual(VoiceReplyPolicy.utterance(String(repeating: "x", count: 1000)).count, 400)
    }
}
