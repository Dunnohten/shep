import XCTest
@testable import ShepCore

/// What Shep tells VoiceOver, when, and on which window (a live VoiceOver run: the caller's question plays clean; "On it." and "Done." are
/// spoken while the VoiceOver cursor is in another app; one "Done." before the bark).
final class AnnouncementTests: XCTestCase {
    // MARK: the target

    func testAWindowIsTheTargetNotTheApplication() {
        // VoiceOver drops announcements posted on the application element; a visible window of Shep's carries them.
        XCTAssertEqual(AnnouncementTarget.choose(cardVisible: true, dockVisible: true, homeVisible: true), .card)
        XCTAssertEqual(AnnouncementTarget.choose(cardVisible: false, dockVisible: true, homeVisible: true), .dock)
        XCTAssertEqual(AnnouncementTarget.choose(cardVisible: false, dockVisible: false, homeVisible: true), .home)
        XCTAssertEqual(AnnouncementTarget.choose(cardVisible: false, dockVisible: false, homeVisible: false), .application)
    }

    // MARK: quiet while the caller speaks

    func testNothingIsPostedWhileTheCallerSpeaks() {
        var gate = AnnouncementGate()
        XCTAssertEqual(gate.setCallerSpeaking(true, at: 0), [])
        XCTAssertEqual(gate.request("Shep is here.", kind: .status, at: 1), [])
        XCTAssertEqual(gate.request("Still busy.", kind: .line, at: 2), [])
        XCTAssertTrue(gate.callerSpeaking)
    }

    func testAStatusLineFromDuringTheQuestionIsDroppedALineIsSaidAfterIt() {
        var gate = AnnouncementGate()
        _ = gate.setCallerSpeaking(true, at: 0)
        _ = gate.request("Shep is here.", kind: .status, at: 1)   // the caller woke Shep: they know; "On it." follows
        XCTAssertEqual(gate.setCallerSpeaking(false, at: 5), [])
        _ = gate.setCallerSpeaking(true, at: 6)
        _ = gate.request("Still busy.", kind: .line, at: 7)
        _ = gate.request("Cancelled.", kind: .line, at: 8)
        // Only the newest line: a high-priority announcement would cut off the one before it anyway.
        XCTAssertEqual(gate.setCallerSpeaking(false, at: 9), ["Cancelled."])
        XCTAssertEqual(gate.setCallerSpeaking(false, at: 10), [], "nothing is said twice")
    }

    func testOutsideAQuestionEverythingIsPostedAtOnce() {
        var gate = AnnouncementGate()
        XCTAssertEqual(gate.request("Shep is here.", kind: .status, at: 0), ["Shep is here."])
        XCTAssertEqual(gate.request("On it.", kind: .line, at: 1), ["On it."])
    }

    // MARK: one "Done."

    func testEveryStepsDoneIsSaid() {
        // Two approved steps 0.5 s apart: each "Done." card is announced (nothing is dropped for being said a moment ago).
        var gate = AnnouncementGate()
        XCTAssertEqual(gate.request("Done.", kind: .line, at: 10), ["Done."])
        XCTAssertEqual(gate.request("Done.", kind: .line, at: 10.5), ["Done."])
        XCTAssertEqual(gate.lastLine?.text, "Done.")
        XCTAssertEqual(gate.lastLine?.at, 10.5)
    }

    func testTheFinishBeatDoesNotRepeatTheWalksDone() {
        // The walk's last "Done." card is the line just before the beat: the beat does not say it again.
        var gate = AnnouncementGate()
        _ = gate.request("Done.", kind: .line, at: 10)
        XCTAssertEqual(gate.requestUnlessLast("Done.", at: 10.3), [])
        // Without a walk card just before (the recorded cycle), or after another line, the beat says it.
        var cycle = AnnouncementGate()
        XCTAssertEqual(cycle.requestUnlessLast("Done.", at: 1), ["Done."])
        _ = cycle.request("Shep is here.", kind: .status, at: 2)
        XCTAssertEqual(cycle.requestUnlessLast("Done.", at: 3), ["Done."])
    }

    func testTheBeatsDoneWaitsForTheQuestionToo() {
        var gate = AnnouncementGate()
        _ = gate.setCallerSpeaking(true, at: 0)
        XCTAssertEqual(gate.requestUnlessLast("Done.", at: 0.5), [])
        XCTAssertEqual(gate.setCallerSpeaking(false, at: 0.6), ["Done."])
    }

    // MARK: the bark after "Done."

    func testWithVoiceOverTheWoofComesAfterDoneHasBeenSpoken() {
        // The beat is timed from when "Done." was posted (it may have gone out with the card just before the beat).
        let start = FinishBeat.voiceOverStart(beatStartedAt: 20.3, donePostedAt: 20.0)
        XCTAssertEqual(start, 20.0)
        XCTAssertEqual(FinishBeat.voiceOverStart(beatStartedAt: 20.3, donePostedAt: nil), 20.3)
        XCTAssertEqual(FinishBeat.voiceOverStart(beatStartedAt: 20.3, donePostedAt: 25), 20.3, "not a time far in the future")
        XCTAssertEqual(FinishBeat.voiceOverStart(beatStartedAt: 30, donePostedAt: 20), 30, "an old \"Done.\" is not this one")
        // Measured from that moment, the woof leaves room for "Done." to be spoken first.
        XCTAssertGreaterThanOrEqual(FinishBeat.woofTime(voiceOverRunning: true), FinishBeat.doneSpokenSeconds)
        // Measured live (a live VoiceOver run): VoiceOver read the dialog's name first and finished "Done." about 1.5 s after it was posted;
        // the woof must come after that with a clear gap (VoiceOver lowers other sound while it speaks), and before the
        // card gives the keyboard back.
        XCTAssertGreaterThanOrEqual(FinishBeat.doneSpokenSeconds, 1.5)
        XCTAssertGreaterThanOrEqual(FinishBeat.woofTime(voiceOverRunning: true) - FinishBeat.doneSpokenSeconds, 0.4)
        XCTAssertLessThan(FinishBeat.woofTime(voiceOverRunning: true) + FinishBeat.hopSeconds + FinishBeat.holdAfterWoof,
                          VoiceOverFlow.resultHoldSeconds)
    }
}

final class VoiceOverFinishedTests: XCTestCase {
    func testOnlyDoneFinishingTimesTheBarkWithAQuietGap() {
        // Review 3: the beat's "VoiceOver finished" observer never fired (token); when it does, only "Done." counts,
        // and the bark keeps a quiet gap after it (VoiceOver lowers other sound while it speaks).
        XCTAssertNil(FinishBeat.voiceOverFinished(announcement: "On it.", elapsed: 1.0))
        XCTAssertNil(FinishBeat.voiceOverFinished(announcement: nil, elapsed: 1.0))
        let at = FinishBeat.voiceOverFinished(announcement: FinishBeat.announcement, elapsed: 1.0)
        XCTAssertEqual(at, 1.0 + FinishBeat.quietAfterVoiceOver)
        XCTAssertGreaterThanOrEqual(FinishBeat.quietAfterVoiceOver, 0.4)
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: true, voiceOverFinishedAt: at), max(FinishBeat.woofDelay, 1.4), accuracy: 1e-9)
    }
}
