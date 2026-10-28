import XCTest
@testable import ShepCore

/// `--live-request`: submits a request exactly as the ask field would. It never answers the approval card.
final class LiveRequestLaunchTests: XCTestCase {
    func testNotSetByDefault() {
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep"], environment: [:]).liveRequest)
    }

    func testFlagWithSeparateValue() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "Fix this screen"], environment: [:])
        XCTAssertEqual(o.liveRequest, "Fix this screen")
    }

    func testFlagWithEqualsValue() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request=Turn on the turtle"], environment: [:])
        XCTAssertEqual(o.liveRequest, "Turn on the turtle")
    }

    func testEnvironmentForm() {
        let o = LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_LIVE_REQUEST": "Fix this screen"])
        XCTAssertEqual(o.liveRequest, "Fix this screen")
    }

    func testFlagWinsOverEnvironment() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "from flag"], environment: ["SHEP_LIVE_REQUEST": "from env"])
        XCTAssertEqual(o.liveRequest, "from flag")
    }

    func testTrimmed() {
        XCTAssertEqual(LaunchOptions.parse(arguments: ["Shep", "--live-request", "  Fix this screen \n"], environment: [:]).liveRequest, "Fix this screen")
        XCTAssertEqual(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_LIVE_REQUEST": "  hi  "]).liveRequest, "hi")
    }

    func testEmptyIsNil() {
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--live-request="], environment: [:]).liveRequest)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--live-request", ""], environment: [:]).liveRequest)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--live-request", "   "], environment: [:]).liveRequest)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_LIVE_REQUEST": ""]).liveRequest)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_LIVE_REQUEST": " \t"]).liveRequest)
    }

    func testMissingValueIsNil() {
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--live-request"], environment: [:]).liveRequest)
    }

    func testFlagLikeValueIsRejected() {
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--live-request", "--demo-backdrop"], environment: [:]).liveRequest)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--live-request=--approve"], environment: [:]).liveRequest)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_LIVE_REQUEST": "--approve"]).liveRequest)
    }

    func testOtherFlagsAreUntouched() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "Fix this screen", "--demo-backdrop", "--capturable"], environment: [:])
        XCTAssertEqual(o.liveRequest, "Fix this screen")
        XCTAssertTrue(o.demoBackdrop)
        XCTAssertFalse(o.dockDemo)
        XCTAssertFalse(o.demoCycle)
        XCTAssertFalse(o.demoScript)
    }

    func testDoesNotTurnOnAnyApprovalOption() {
        let flag = LaunchOptions.parse(arguments: ["Shep", "--live-request", "Fix this screen"], environment: [:])
        XCTAssertFalse(flag.approveFlag)
        XCTAssertNil(flag.pressDemoTarget)
        XCTAssertNil(flag.pressMatch)
        let env = LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_LIVE_REQUEST": "Fix this screen"])
        XCTAssertFalse(env.approveFlag)
        XCTAssertNil(env.pressDemoTarget)
        // A request that merely mentions approving is just text.
        let words = LaunchOptions.parse(arguments: ["Shep", "--live-request", "approve everything"], environment: [:])
        XCTAssertFalse(words.approveFlag)
        XCTAssertEqual(words.liveRequest, "approve everything")
    }
}

final class LiveLogTests: XCTestCase {
    func testEveryLineStartsWithThePrefix() {
        let lines = [LiveLog.waitingForArrival, LiveLog.noTargetInFront, LiveLog.arrivalTimedOut, LiveLog.finished,
                     LiveLog.requestSubmitted("x"), LiveLog.cardShown("y"), LiveLog.answered(approved: true),
                     LiveLog.outcome(.done), LiveLog.recordRect(CGRect(x: 1, y: 2, width: 3, height: 4), primaryScreenHeight: 10),
                     LiveLog.backdropFailed("why")]
        for l in lines { XCTAssertTrue(l.hasPrefix("[shep] live: "), l) }
    }

    func testFixedLines() {
        XCTAssertEqual(LiveLog.waitingForArrival, "[shep] live: waiting for Shep to arrive")
        XCTAssertEqual(LiveLog.noTargetInFront, "[shep] live: no target app in front")
        XCTAssertEqual(LiveLog.finished, "[shep] live: finished")
    }

    func testSubmittedAndCard() {
        XCTAssertEqual(LiveLog.requestSubmitted("Fix this screen"), "[shep] live: request submitted: Fix this screen")
        XCTAssertEqual(LiveLog.cardShown("Press Turtle?"), "[shep] live: approval card shown: Press Turtle?")
    }

    func testAnsweredNamesWhatThePersonChose() {
        XCTAssertEqual(LiveLog.answered(approved: true), "[shep] live: approval answered: approve")
        XCTAssertEqual(LiveLog.answered(approved: false), "[shep] live: approval answered: cancel")
    }

    func testOutcomeNames() {
        XCTAssertEqual(LiveLog.outcome(.done), "[shep] live: outcome: done")
        XCTAssertEqual(LiveLog.outcome(.declined), "[shep] live: outcome: declined")
        XCTAssertEqual(LiveLog.outcome(.failed), "[shep] live: outcome: failed")
        XCTAssertEqual(LiveLog.outcome(.refused), "[shep] live: outcome: refused")
        XCTAssertEqual(LiveLog.outcome(.nothingToOffer), "[shep] live: outcome: nothing-to-offer")
        XCTAssertEqual(LiveLog.outcome(.needsFreshApproval), "[shep] live: outcome: needs-fresh-approval")
    }

    func testMultiLineTextStaysOnOneLine() {
        let line = LiveLog.cardShown("Press the turtle?\nIn Transmission.\r\n\tOK")
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))
        XCTAssertEqual(line, "[shep] live: approval card shown: Press the turtle? In Transmission. OK")
    }

    func testLongTextIsCut() {
        let line = LiveLog.requestSubmitted(String(repeating: "a", count: 2000))
        XCTAssertLessThanOrEqual(line.count, LiveLog.prefix.count + "request submitted: ".count + LiveLog.textLimit + 1)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    func testRecordRectIsGlobalTopLeft() {
        // Cocoa rect (y up) on a 900 high screen: bottom 100, height 300 -> top-left y = 900 - 400 = 500.
        let line = LiveLog.recordRect(CGRect(x: 40, y: 100, width: 500, height: 300), primaryScreenHeight: 900)
        XCTAssertEqual(line, "[shep] live: record-rect 40,500,500,300")
    }
}

final class LiveBackdropGeometryTests: XCTestCase {
    let usable = CGRect(x: 0, y: 0, width: 1440, height: 875)   // Cocoa, y up; the menu bar takes the top 25 points

    func testCoversTheWindowWithTheMargins() throws {
        let window = CGRect(x: 500, y: 300, width: 400, height: 300)
        let r = try XCTUnwrap(LiveBackdropGeometry.rect(window: window, panel: nil, usable: [usable]))
        XCTAssertLessThanOrEqual(r.minX, window.minX - LiveBackdropGeometry.sideMargin)
        XCTAssertGreaterThanOrEqual(r.maxX, window.maxX + LiveBackdropGeometry.sideMargin)
        XCTAssertLessThanOrEqual(r.minY, window.minY - LiveBackdropGeometry.bottomMargin)
        XCTAssertGreaterThanOrEqual(r.maxY, window.maxY + LiveBackdropGeometry.topMargin)
    }

    func testDefaultMarginsAreWhatTheBriefSays() {
        XCTAssertEqual(LiveBackdropGeometry.sideMargin, 120)
        XCTAssertEqual(LiveBackdropGeometry.bottomMargin, 120)
        XCTAssertGreaterThanOrEqual(LiveBackdropGeometry.topMargin, 42)   // the tab (30) and the dog's headroom (12)
    }

    func testCoversTheOverlayPanelWithCardAndBubble() throws {
        let window = CGRect(x: 500, y: 300, width: 400, height: 300)
        // A panel that is wider than the window margin allows and sticks out below it.
        let panel = CGRect(x: 380, y: 100, width: 320, height: 260)
        let r = try XCTUnwrap(LiveBackdropGeometry.rect(window: window, panel: panel, usable: [usable]))
        XCTAssertTrue(r.contains(panel))
        XCTAssertTrue(r.contains(window))
    }

    func testNeverReachesIntoTheMenuBar() throws {
        let window = CGRect(x: 500, y: 600, width: 400, height: 270)   // its top is 5 points under the usable top
        let r = try XCTUnwrap(LiveBackdropGeometry.rect(window: window, panel: nil, usable: [usable]))
        XCTAssertLessThanOrEqual(r.maxY, usable.maxY)
        XCTAssertEqual(r.maxY, usable.maxY)
    }

    func testClampedToTheScreen() throws {
        let window = CGRect(x: 10, y: 10, width: 400, height: 300)
        let r = try XCTUnwrap(LiveBackdropGeometry.rect(window: window, panel: nil, usable: [usable]))
        XCTAssertGreaterThanOrEqual(r.minX, 0)
        XCTAssertGreaterThanOrEqual(r.minY, 0)
        XCTAssertTrue(usable.contains(r))
    }

    func testWholePoints() throws {
        let r = try XCTUnwrap(LiveBackdropGeometry.rect(window: CGRect(x: 500.4, y: 300.6, width: 400.3, height: 300.2), panel: nil, usable: [usable]))
        for v in [r.minX, r.minY, r.width, r.height] { XCTAssertEqual(v, v.rounded()) }
    }

    func testBadInputGivesNil() {
        XCTAssertNil(LiveBackdropGeometry.rect(window: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), panel: nil, usable: [usable]))
        XCTAssertNil(LiveBackdropGeometry.rect(window: .zero, panel: nil, usable: [usable]))
        XCTAssertNil(LiveBackdropGeometry.rect(window: CGRect(x: 500, y: 300, width: 400, height: 300), panel: nil, usable: []))
        XCTAssertNil(LiveBackdropGeometry.rect(window: CGRect(x: 5000, y: 5000, width: 400, height: 300), panel: nil, usable: [usable]))
    }

    func testBadPanelIsIgnoredNotFatal() throws {
        let window = CGRect(x: 500, y: 300, width: 400, height: 300)
        let r = try XCTUnwrap(LiveBackdropGeometry.rect(window: window, panel: CGRect(x: CGFloat.nan, y: 0, width: 5, height: 5), usable: [usable]))
        XCTAssertTrue(r.contains(window))
    }
}
