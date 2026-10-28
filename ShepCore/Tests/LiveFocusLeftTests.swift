import CoreGraphics
import XCTest
@testable import ShepCore

/// Measured on the Mac (12:28 CT, dry run 2 of the broken-page phrasing, status `target-ok request-submitted card-shown`): the
/// person moved to another app while the approval card waited. Shep did not end the run (exit 0, no refusal): its tracker docked to
/// the other app's window (log `dock tab=(1079,2004 ...) inside panel=(863,1850 ...)`, then `(119,2004)`), read that window's frame,
/// title and title-bar items through Accessibility, and the tab tint may have captured that window (`TabTint.sampleBarColor`).
/// The `--live-target` gates only look at the START (target-ok, then the look at submission). A run bound to an app must stay bound.
final class LiveFocusLeftTests: XCTestCase {
    private let wanted = "org.m0k.transmission"
    private let other = "com.example.otherapp"

    func testTheRunEndsWithATargetRefusalWhenTheWantedAppLeavesTheFront() {
        XCTAssertEqual(LiveTargetGate.focusLeft(wanted: wanted, front: other), LiveTargetGate.wrongFrontText(front: other, wanted: wanted))
        XCTAssertEqual(LiveTargetGate.focusLeft(wanted: wanted, front: nil), LiveTargetGate.wrongFrontText(front: nil, wanted: wanted))
    }

    func testTheRunCarriesOnWhileTheWantedAppIsInFront() {
        XCTAssertNil(LiveTargetGate.focusLeft(wanted: wanted, front: wanted))
        XCTAssertNil(LiveTargetGate.focusLeft(wanted: wanted, front: wanted.uppercased()))
    }

    func testTheRefusalNamesNoPathAndIsOneLine() {
        let text = LiveTargetGate.focusLeft(wanted: wanted, front: "com.example.other app\nsecond line") ?? ""
        XCTAssertTrue(text.hasPrefix("target: "))
        XCTAssertFalse(text.contains("\n"))
    }

    func testTheDockDoesNotFollowAnotherAppDuringALiveRun() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let transmission = WindowObservation(pid: 10, bundleID: wanted, axFrame: CGRect(x: 71, y: 342, width: 480, height: 269), title: "Transmission")
        let elsewhere = WindowObservation(pid: 20, bundleID: other, axFrame: CGRect(x: 300, y: 200, width: 800, height: 500), title: "Some private title")
        let onTarget = DockPlanner.plan(transmission, ownPID: 1, screens: screens, primaryScreenHeight: 900, liveTarget: wanted)
        XCTAssertNotEqual(onTarget.placement, .hidden, "the target is still docked to")
        let away = DockPlanner.plan(elsewhere, ownPID: 1, screens: screens, primaryScreenHeight: 900, liveTarget: wanted)
        XCTAssertEqual(away.placement, .hidden, "a live run bound to \(wanted) must not dock to another app")
        XCTAssertFalse(away.note.contains("Some private title"), "the note never carries another app's window title")
        // Without a live target nothing changes.
        let free = DockPlanner.plan(elsewhere, ownPID: 1, screens: screens, primaryScreenHeight: 900)
        XCTAssertNotEqual(free.placement, .hidden)
    }

    func testTheTabTintNeverCapturesAnotherAppDuringALiveRun() {
        XCTAssertEqual(TabTintPolicy.source(bundleID: wanted, screenRecordingAllowed: true, liveTarget: wanted), .sample)
        XCTAssertEqual(TabTintPolicy.source(bundleID: other, screenRecordingAllowed: true, liveTarget: wanted), .fallback,
                       "a live run bound to \(wanted) must not capture another app's window, not even one pixel row")
        XCTAssertEqual(TabTintPolicy.source(bundleID: other, screenRecordingAllowed: true), .sample, "no live target: unchanged")
    }
}
