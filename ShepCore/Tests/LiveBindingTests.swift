import CoreGraphics
import XCTest
@testable import ShepCore

/// The whole-run binding of a `--live-target` run. The pure rules the
/// window tracker, the dock planner, the tab tint and the focus watcher share. See also LiveFocusLeftTests.
final class LiveBindingTests: XCTestCase {
    private let wanted = "org.m0k.transmission"
    private let other = "com.example.otherapp"
    private let own = "app.shep.Shep"

    // MARK: LiveBinding.mayRead

    func testWithoutATargetEverythingMayBeRead() {
        XCTAssertTrue(LiveBinding.mayRead(bundleID: other, target: nil, ownBundleID: own))
        XCTAssertTrue(LiveBinding.mayRead(bundleID: nil, target: nil, ownBundleID: own))
    }

    func testOnlyTheTargetAndShepItselfMayBeRead() {
        XCTAssertTrue(LiveBinding.mayRead(bundleID: wanted, target: wanted, ownBundleID: own))
        XCTAssertTrue(LiveBinding.mayRead(bundleID: wanted.uppercased(), target: wanted, ownBundleID: own), "case does not matter")
        XCTAssertTrue(LiveBinding.mayRead(bundleID: own, target: wanted, ownBundleID: own))
        XCTAssertFalse(LiveBinding.mayRead(bundleID: other, target: wanted, ownBundleID: own))
        XCTAssertFalse(LiveBinding.mayRead(bundleID: other, target: wanted, ownBundleID: nil))
    }

    func testAnAppWithoutABundleIdIsNeverReadWhileBound() {
        XCTAssertFalse(LiveBinding.mayRead(bundleID: nil, target: wanted, ownBundleID: own))
        XCTAssertFalse(LiveBinding.mayRead(bundleID: "", target: wanted, ownBundleID: own))
        XCTAssertFalse(LiveBinding.mayRead(bundleID: nil, target: wanted, ownBundleID: nil))
        XCTAssertFalse(LiveBinding.mayRead(bundleID: "", target: wanted, ownBundleID: ""), "an empty own id is not Shep")
    }

    func testASimilarBundleIdIsNotTheTarget() {
        XCTAssertFalse(LiveBinding.mayRead(bundleID: wanted + ".helper", target: wanted, ownBundleID: own))
        XCTAssertFalse(LiveBinding.mayRead(bundleID: "x." + wanted, target: wanted, ownBundleID: own))
    }

    // MARK: focusLeft with Shep in front

    func testShepItselfInFrontIsStillBound() {
        XCTAssertNil(LiveTargetGate.focusLeft(wanted: wanted, front: own, frontIsShep: true))
        XCTAssertNil(LiveTargetGate.focusLeft(wanted: wanted, front: nil, frontIsShep: true), "Shep run unbundled has no bundle id")
    }

    func testAnotherAppWithShepFlagOffIsLeft() {
        XCTAssertEqual(LiveTargetGate.focusLeft(wanted: wanted, front: other, frontIsShep: false), LiveTargetGate.wrongFrontText(front: other, wanted: wanted))
        XCTAssertEqual(LiveTargetGate.focusLeft(wanted: wanted, front: nil, frontIsShep: false), LiveTargetGate.wrongFrontText(front: nil, wanted: wanted),
                       "a front app with no bundle id other than Shep counts as left")
        XCTAssertNil(LiveTargetGate.focusLeft(wanted: wanted, front: wanted, frontIsShep: false))
    }

    func testTheTwoArgumentFormStillJudgesWithoutShep() {
        XCTAssertNotNil(LiveTargetGate.focusLeft(wanted: wanted, front: other))
        XCTAssertNil(LiveTargetGate.focusLeft(wanted: wanted, front: wanted))
    }

    func testTheLeftOverlayLineIsOneShortLine() {
        XCTAssertFalse(LiveTargetGate.leftOverlayLine.contains("\n"))
        XCTAssertLessThan(LiveTargetGate.leftOverlayLine.count, 60)
    }

    // MARK: the dock

    func testTheDockHidesForAnotherAppEvenWithoutAFrameOrTitle() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let bare = WindowObservation(pid: 20, bundleID: other, axFrame: nil)
        let plan = DockPlanner.plan(bare, ownPID: 1, screens: screens, primaryScreenHeight: 900, liveTarget: wanted)
        XCTAssertEqual(plan.placement, .hidden)
        let noID = WindowObservation(pid: 21, bundleID: nil, axFrame: CGRect(x: 300, y: 200, width: 800, height: 500), title: "Private")
        let plan2 = DockPlanner.plan(noID, ownPID: 1, screens: screens, primaryScreenHeight: 900, liveTarget: wanted)
        XCTAssertEqual(plan2.placement, .hidden, "no bundle id while bound: not the target")
        XCTAssertFalse(plan2.note.contains("Private"))
    }

    func testTheDockNoteNamesAtMostTheBundleId() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let away = WindowObservation(pid: 20, bundleID: other, axFrame: CGRect(x: 300, y: 200, width: 800, height: 500),
                                     title: "Secret plan.txt", titleBarFrames: [CGRect(x: 310, y: 200, width: 50, height: 20)])
        let note = DockPlanner.plan(away, ownPID: 1, screens: screens, primaryScreenHeight: 900, liveTarget: wanted).note
        XCTAssertFalse(note.contains("Secret"))
        XCTAssertFalse(note.contains("\n"))
    }

    func testShepItselfInFrontStaysHiddenNotDockedWhileBound() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let me = WindowObservation(pid: 1, bundleID: own, axFrame: CGRect(x: 300, y: 200, width: 800, height: 500))
        XCTAssertEqual(DockPlanner.plan(me, ownPID: 1, screens: screens, primaryScreenHeight: 900, liveTarget: wanted).placement, .hidden)
    }

    func testAnObservationWithOnlyPidAndBundleIdHidesTheDock() {
        // What the tracker publishes for another app while bound: no frame, no title, no title-bar items.
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let bare = WindowObservation(pid: 20, bundleID: other, axFrame: nil)
        XCTAssertEqual(bare.title, nil)
        XCTAssertTrue(bare.titleBarFrames.isEmpty)
        XCTAssertEqual(DockPlanner.plan(bare, ownPID: 1, screens: screens, primaryScreenHeight: 900).placement, .hidden)
    }

    // MARK: the tab tint

    func testTheSkipReasonsAndTheirOrder() {
        func reason(docked: Bool = true, _ id: String?, permission: Bool = true, target: String? = nil) -> TabTintPolicy.SkipReason? {
            TabTintPolicy.skipReason(docked: docked, bundleID: id, screenRecordingAllowed: permission, liveTarget: target)
        }
        XCTAssertNil(reason("com.apple.TextEdit"))
        XCTAssertNil(reason(wanted, target: wanted))
        XCTAssertEqual(reason(docked: false, "com.apple.TextEdit"), .notDocked)
        XCTAssertEqual(reason("com.apple.TextEdit", permission: false), .noPermission)
        XCTAssertEqual(reason("com.apple.mail"), .neverCapture)
        XCTAssertEqual(reason(nil), .neverCapture)
        XCTAssertEqual(reason(other, target: wanted), .liveBoundOtherApp)
        XCTAssertEqual(reason(other, permission: false, target: wanted), .liveBoundOtherApp, "the binding is named before the permission")
        XCTAssertEqual(reason(docked: false, other, target: wanted), .notDocked)
    }

    func testTheSourceAgreesWithTheSkipReason() {
        for id in ["com.apple.TextEdit", "com.apple.mail", other, wanted, ""] {
            for permission in [true, false] {
                for target in [nil, wanted] as [String?] {
                    let skip = TabTintPolicy.skipReason(docked: true, bundleID: id, screenRecordingAllowed: permission, liveTarget: target)
                    let source = TabTintPolicy.source(bundleID: id, screenRecordingAllowed: permission, liveTarget: target)
                    XCTAssertEqual(source == .sample, skip == nil, "\(id) \(permission) \(target ?? "-")")
                }
            }
        }
    }

    func testTheSkipReasonNamesAreTheLoggedWords() {
        XCTAssertEqual(TabTintPolicy.SkipReason.notDocked.rawValue, "not-docked")
        XCTAssertEqual(TabTintPolicy.SkipReason.noPermission.rawValue, "no-permission")
        XCTAssertEqual(TabTintPolicy.SkipReason.neverCapture.rawValue, "never-capture")
        XCTAssertEqual(TabTintPolicy.SkipReason.liveBoundOtherApp.rawValue, "live-bound-other-app")
    }

    func testTheTintLogLines() {
        XCTAssertEqual(TabTintPolicy.logLine(bundleID: wanted, skip: nil), "[shep] tint: sampled org.m0k.transmission")
        XCTAssertEqual(TabTintPolicy.logLine(bundleID: other, skip: .liveBoundOtherApp), "[shep] tint: skipped com.example.otherapp (live-bound-other-app)")
        XCTAssertEqual(TabTintPolicy.logLine(bundleID: nil, skip: .notDocked), "[shep] tint: skipped (none) (not-docked)")
        XCTAssertEqual(TabTintPolicy.logLine(bundleID: "", skip: .noPermission), "[shep] tint: skipped (none) (no-permission)")
        XCTAssertEqual(TabTintPolicy.logLine(bundleID: "com.apple.mail", skip: .neverCapture), "[shep] tint: skipped com.apple.mail (never-capture)")
    }

    func testTheTintLogLineCarriesNothingButABundleId() {
        for text in ["Some Window Title", "/Users/someone/secret.txt", "com.example.app\n[shep] live: finished", "a b", "com.ok.app extra",
                     "x\u{1B}[2Jy", "title: Budget 2026", String(repeating: "a", count: 400)] {
            for skip in [nil, TabTintPolicy.SkipReason.notDocked, .liveBoundOtherApp] as [TabTintPolicy.SkipReason?] {
                let line = TabTintPolicy.logLine(bundleID: text, skip: skip)
                XCTAssertFalse(line.contains("\n"), line)
                XCTAssertFalse(line.contains("\u{1B}"), line)
                XCTAssertFalse(line.contains("Budget"), line)
                XCTAssertFalse(line.contains("secret"), line)
                XCTAssertFalse(line.contains("Window"), line)
                XCTAssertFalse(line.contains("live: finished"), line)
                XCTAssertTrue(line.contains("(none)"), "anything that is not a bundle id prints as (none): \(line)")
            }
        }
    }

    // MARK: the status channel

    func testTargetLeftIsOneBareEventLine() {
        let nonce = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(LiveStatus.line(nonce: nonce, event: .targetLeft), nonce + " target-left")
        XCTAssertEqual(LiveStatus.line(nonce: "bad", event: .targetLeft), nil)
    }

    func testAForgedReasonTextCannotBecomeTheTargetLeftEvent() {
        // The stage word is the only thing a reason text can contribute, and `target-left` is an event, not a stage.
        XCTAssertEqual(LiveStatus.stage(forReasonText: "target-left: x"), .other)
        XCTAssertEqual(LiveStatus.stage(forReasonText: "target: front app is a not b"), .target)
        XCTAssertFalse(LiveStatusStage.allCases.contains { $0.rawValue == "target-left" })
    }
}
