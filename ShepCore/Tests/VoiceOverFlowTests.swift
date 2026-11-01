import XCTest
@testable import ShepCore

/// How a call looks to someone using VoiceOver (found in a live VoiceOver run): VoiceOver speaks Shep's lines only while its cursor is in
/// one of Shep's windows, it moves its cursor into a Shep window that appears and back (reading the app again) when it goes,
/// and it speaks value changes of the home indicator.
final class VoiceOverFlowTests: XCTestCase {
    func testUnderVoiceOverShepComesOutOnlyAfterTheQuestion() {
        // Every Shep window that appears (the doghouse waking, the dock) pulls the VoiceOver cursor and is read: not over
        // the caller. Shep stays home until the final text, then comes out for the request.
        XCTAssertFalse(VoiceOverFlow.wakesDuringQuestion(voiceOverRunning: true))
        XCTAssertTrue(VoiceOverFlow.wakesDuringQuestion(voiceOverRunning: false), "without VoiceOver: wakes while you speak, as before")
    }

    func testThePillDoesNotShowTheQuestionUnderVoiceOver() {
        // The pill would pull the VoiceOver cursor away while the caller speaks; they know what they said.
        XCTAssertFalse(VoiceOverFlow.showsQuestionPill(voiceOverRunning: true))
        XCTAssertTrue(VoiceOverFlow.showsQuestionPill(voiceOverRunning: false))
    }

    func testTheHomeIndicatorStaysQuietDuringTheQuestion() {
        var gate = AnnouncementGate()
        XCTAssertTrue(gate.allowsStateNotifications)
        _ = gate.setCallerSpeaking(true, at: 0)
        XCTAssertFalse(gate.allowsStateNotifications, "no \"Shep is waking up\" over the question")
        _ = gate.setCallerSpeaking(false, at: 4)
        XCTAssertTrue(gate.allowsStateNotifications)
    }

    func testAfterApproveTheCardKeepsVoiceOverForTheResult() {
        // The cursor is in the card: "Done." is said there, then the bark, then focus goes back to the app.
        XCTAssertTrue(VoiceOverFlow.holdsCardForResult(voiceOverRunning: true, choice: "approve"))
        XCTAssertFalse(VoiceOverFlow.holdsCardForResult(voiceOverRunning: false, choice: "approve"), "without VoiceOver: as before")
        XCTAssertFalse(VoiceOverFlow.holdsCardForResult(voiceOverRunning: true, choice: "cancel"), "Deny gives focus back at once")
        XCTAssertFalse(VoiceOverFlow.holdsCardForResult(voiceOverRunning: true, choice: nil), "Escape or a replaced card too")
        // Never for long: the hold ends with the finish beat's walk home, or after this.
        XCTAssertGreaterThan(VoiceOverFlow.resultHoldSeconds, FinishBeat.voiceOverTimeout + FinishBeat.hopSeconds + FinishBeat.holdAfterWoof)
        XCTAssertLessThanOrEqual(VoiceOverFlow.resultHoldSeconds, 6)
    }
}

final class HeldResultCardTests: XCTestCase {
    func testTheHeldResultIsPostedAfterTheDialogNameAndBeforeTheBark() {
        // Live (a live VoiceOver run): "Done." posted as the held card changed was lost under VoiceOver's "Shep, Dialog".
        XCTAssertGreaterThanOrEqual(VoiceOverFlow.heldResultPostDelay, 0.8)
        // "Done." takes about half a second to say; the bark needs a quiet gap after it.
        XCTAssertLessThanOrEqual(VoiceOverFlow.heldResultPostDelay + 0.6 + 0.4, FinishBeat.woofTime(voiceOverRunning: true))
    }

    func testAnOldDoneDoesNotSilenceANewOne() {
        // Review: the beat's "Done." was skipped after any earlier "Done.", however old.
        var gate = AnnouncementGate()
        XCTAssertEqual(gate.request("Done.", kind: .line, at: 0), ["Done."])
        XCTAssertEqual(gate.requestUnlessLast("Done.", at: 10), ["Done."])
    }

    func testAScheduledLineCountsFromWhenItGoesOut() {
        // The held result is posted later; the beat sees it as said and times the bark from when it goes out.
        var gate = AnnouncementGate()
        XCTAssertEqual(gate.schedule("Done.", after: VoiceOverFlow.heldResultPostDelay, at: 10), ["Done."])
        XCTAssertEqual(gate.requestUnlessLast("Done.", at: 10.5), [], "the beat does not say it again")
        let posted = gate.lastPosted(of: "Done.", within: AnnouncementGate.repeatWindow, at: 10.5)
        XCTAssertEqual(posted, 10 + VoiceOverFlow.heldResultPostDelay)
        XCTAssertEqual(FinishBeat.voiceOverStart(beatStartedAt: 10.5, donePostedAt: posted), 10 + VoiceOverFlow.heldResultPostDelay)
    }

    func testAScheduledLineDroppedBeforeItGoesOutIsNotCounted() {
        var gate = AnnouncementGate()
        _ = gate.schedule("Done.", after: 0.9, at: 10)
        gate.unschedule(at: 10.2)
        XCTAssertEqual(gate.requestUnlessLast("Done.", at: 10.5), ["Done."])
    }

    func testNothingIsScheduledWhileTheCallerSpeaks() {
        var gate = AnnouncementGate()
        _ = gate.setCallerSpeaking(true, at: 0)
        XCTAssertEqual(gate.schedule("Done.", after: 0.9, at: 1), [])
        XCTAssertEqual(gate.setCallerSpeaking(false, at: 2), ["Done."], "held, said after the question")
    }
}

final class ArrivalAnnouncementTests: XCTestCase {
    func testACallForAnAskedQuestionDocksQuietly() {
        // Live VoiceOver run: "Shep is here." was said once after "On it." when the caller's question brought Shep out; they know they
        // called. The call made once the question is asked (VoiceOver: Shep stays home until then) docks without it.
        var arrival = ArrivalAnnouncement()
        arrival.call(from: .asleep, forQuestion: true)
        XCTAssertFalse(arrival.docked())
        // The next trip starts fresh.
        arrival.call(from: .asleep, forQuestion: false)
        XCTAssertTrue(arrival.docked())
    }

    func testAnyOtherCallAnnouncesArrival() {
        // Doghouse, menu, shortcut, demo, and the talk key going down before anything is asked (the question may still be
        // cancelled or empty, and then no "On it." follows): Shep says where it is.
        var arrival = ArrivalAnnouncement()
        arrival.call(from: .asleep, forQuestion: false)
        XCTAssertTrue(arrival.docked())
        var unseen = ArrivalAnnouncement()
        XCTAssertTrue(unseen.docked(), "a dock with no call seen: say it")
    }

    func testOnlyTheCallThatSetsShepOffDecides() {
        // Review 1: a second call while Shep is waking or crossing changes nothing in the lifecycle, so it must not
        // change the announcement either; a call that turns Shep around on the way home starts a new trip and does.
        var a = ArrivalAnnouncement()
        a.call(from: .asleep, forQuestion: true)
        a.call(from: .waking, forQuestion: false)
        a.call(from: .traveling, forQuestion: false)
        XCTAssertFalse(a.docked())

        var b = ArrivalAnnouncement()
        b.call(from: .asleep, forQuestion: false)
        b.call(from: .traveling, forQuestion: true)
        XCTAssertTrue(b.docked())

        var c = ArrivalAnnouncement()
        c.call(from: .asleep, forQuestion: false)
        c.call(from: .returning, forQuestion: true)
        XCTAssertFalse(c.docked())

        var d = ArrivalAnnouncement()
        d.call(from: .working, forQuestion: true)
        XCTAssertTrue(d.docked(), "a call while docked is not a trip")
    }

    func testATripThatNeverDockedLeavesNothingBehind() {
        // A quiet call that found no window (or was sent home while waking) goes back to sleep; the next call from home decides.
        var arrival = ArrivalAnnouncement()
        arrival.call(from: .asleep, forQuestion: true)
        arrival.call(from: .asleep, forQuestion: false)
        XCTAssertTrue(arrival.docked())
    }
}
