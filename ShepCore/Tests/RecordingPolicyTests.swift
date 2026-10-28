import CoreGraphics
import XCTest
@testable import ShepCore

/// P1-4: the fix demo is recorded window-bound. Which windows are in the movie, who may be recorded, and when a running
/// recording is discarded are pure decisions.
final class RecordingPolicyTests: XCTestCase {
    let own: Int32 = 100
    let targetPID: Int32 = 200
    let targetWindow: UInt32 = 50
    let frame = CGRect(x: 100, y: 100, width: 600, height: 400)

    func win(_ id: UInt32, pid: Int32, layer: Int = 0, onScreen: Bool = true, overlay: Bool = false) -> RecordingWindow {
        RecordingWindow(id: id, pid: pid, layer: layer, onScreen: onScreen, isShepOverlay: overlay)
    }

    func select(_ windows: [RecordingWindow]) -> [UInt32] {
        RecordingWindowSelection.select(windows: windows, targetPID: targetPID, targetWindowID: targetWindow, ownPID: own)
    }

    // MARK: selection

    func testAnotherAppsWindowIsNeverSelectedEvenWhenItOverlapsAndIsOnTop() {
        // Front to back: a chat app's window on top of the target, then Shep's dog, then the target, then a browser.
        let windows = [win(90, pid: 300), win(11, pid: own, layer: 3, overlay: true), win(targetWindow, pid: targetPID), win(91, pid: 301)]
        let chosen = select(windows)
        XCTAssertEqual(chosen, [11, targetWindow])
        XCTAssertFalse(chosen.contains(90))
        XCTAssertFalse(chosen.contains(91))
    }

    func testOnlyTheTargetAndShepOverlaysAreIncluded() {
        let windows = [win(11, pid: own, layer: 3, overlay: true), win(12, pid: own, layer: 3, overlay: true),
                       win(13, pid: own, layer: 0, overlay: false),   // Shep's backdrop or setup window
                       win(targetWindow, pid: targetPID), win(51, pid: targetPID)]   // a second window of the target app
        XCTAssertEqual(select(windows), [11, 12, targetWindow])
    }

    func testTheTargetWindowIdOwnedByAnotherPidIsNotSelected() {
        // The number is listed, but another process owns it: a different window.
        XCTAssertEqual(select([win(targetWindow, pid: 999)]), [])
    }

    func testAnOffScreenTargetOrOverlayIsNotSelected() {
        XCTAssertEqual(select([win(targetWindow, pid: targetPID, onScreen: false), win(11, pid: own, layer: 3, onScreen: false, overlay: true)]), [])
    }

    func testAMenuLayerWindowOfTheTargetIsNotTheTargetWindow() {
        XCTAssertEqual(select([win(targetWindow, pid: targetPID, layer: 25)]), [])
    }

    func testShepItselfIsNeverTheTarget() {
        let chosen = RecordingWindowSelection.select(windows: [win(targetWindow, pid: own)], targetPID: own, targetWindowID: targetWindow, ownPID: own)
        XCTAssertEqual(chosen, [])
    }

    func testDuplicateWindowsAreListedOnce() {
        XCTAssertEqual(select([win(11, pid: own, layer: 3, overlay: true), win(11, pid: own, layer: 3, overlay: true)]), [11])
    }

    // MARK: policy

    func testForbiddenBundlesAreRefusedBeforeStart() {
        for id in ["com.apple.mail", "com.apple.terminal", "com.1password.1password", "com.tinyspeck.slackmacgap", "com.jetbrains.intellij"] {
            XCTAssertFalse(RecordingPolicy.allowed(bundleID: id), id)
            XCTAssertNotNil(RecordingPolicy.refusal(bundleID: id, screenRecordingAllowed: true, targetWindowFound: true), id)
        }
    }

    func testUnknownBundleIdsAreRefusedBeforeStart() {
        XCTAssertFalse(RecordingPolicy.allowed(bundleID: ""))
        for id in [nil, "", "   "] as [String?] {
            XCTAssertNotNil(RecordingPolicy.refusal(bundleID: id, screenRecordingAllowed: true, targetWindowFound: true))
        }
    }

    func testNoPermissionOrNoWindowRefusesAnAllowedApp() {
        XCTAssertNil(RecordingPolicy.refusal(bundleID: "org.m0k.transmission", screenRecordingAllowed: true, targetWindowFound: true))
        XCTAssertNotNil(RecordingPolicy.refusal(bundleID: "org.m0k.transmission", screenRecordingAllowed: false, targetWindowFound: true))
        XCTAssertNotNil(RecordingPolicy.refusal(bundleID: "org.m0k.transmission", screenRecordingAllowed: true, targetWindowFound: false))
    }

    func testThePolicyIsTheSameFunctionAsTheCapturePolicy() {
        for id in ["org.m0k.transmission", "com.apple.mail", "", "com.apple.dt.xcode", "com.apple.TextEdit"] {
            XCTAssertEqual(RecordingPolicy.allowed(bundleID: id), ControlPolicy.mayCapture(bundleID: id), id)
        }
    }

    // MARK: watch

    var target: RecordingTarget { RecordingTarget(pid: targetPID, windowID: targetWindow, bundleID: "org.m0k.transmission", frame: frame) }

    func observation(onScreen: Bool = true, owner: Int32? = 200, bundle: String? = "org.m0k.transmission", frontPID: Int32? = 200,
                     frontBundle: String? = "org.m0k.transmission", frame: CGRect? = nil) -> RecordingObservation {
        RecordingObservation(windowOnScreen: onScreen, windowOwnerPID: owner, bundleIDForTargetPID: bundle, frontPID: frontPID,
                             frontBundleID: frontBundle, frame: frame ?? self.frame)
    }

    func testAHealthyTargetKeepsRecording() {
        XCTAssertEqual(RecordingWatch.verdict(target: target, now: observation()), .keep)
    }

    func testTheTargetWindowDisappearingStopsAndDiscards() {
        guard case .stop = RecordingWatch.verdict(target: target, now: observation(onScreen: false)) else { return XCTFail("closed or minimised") }
    }

    func testTheWindowChangingOwnerStopsAndDiscards() {
        guard case .stop = RecordingWatch.verdict(target: target, now: observation(owner: 777)) else { return XCTFail("owner pid changed") }
        guard case .stop = RecordingWatch.verdict(target: target, now: observation(owner: nil)) else { return XCTFail("no owner") }
    }

    func testAPidReusedByAnotherAppStopsAndDiscards() {
        guard case .stop = RecordingWatch.verdict(target: target, now: observation(bundle: "com.example.other")) else { return XCTFail("bundle changed") }
        guard case .stop = RecordingWatch.verdict(target: target, now: observation(bundle: nil)) else { return XCTFail("process gone") }
    }

    func testTheTargetBundleBecomingForbiddenStops() {
        let mail = RecordingTarget(pid: targetPID, windowID: targetWindow, bundleID: "com.apple.mail", frame: frame)
        guard case .stop = RecordingWatch.verdict(target: mail, now: observation(bundle: "com.apple.mail", frontBundle: "com.apple.mail")) else {
            return XCTFail("a forbidden target")
        }
        // The process now running under the pid is forbidden even though the recorded bundle was fine.
        guard case .stop = RecordingWatch.verdict(target: target, now: observation(bundle: "com.apple.terminal")) else { return XCTFail("changed to a forbidden app") }
    }

    func testSwitchingToAForbiddenAppDoesNotMatterForWindowBoundCapture() {
        let now = observation(frontPID: 900, frontBundle: "com.apple.mail")
        XCTAssertEqual(RecordingWatch.verdict(target: target, now: now), .keep, "the movie holds only the target and Shep's windows")
    }

    func testAForbiddenFrontAppThatIsTheTargetStops() {
        guard case .stop = RecordingWatch.verdict(target: target, now: observation(frontPID: 200, frontBundle: "com.apple.terminal")) else {
            return XCTFail("the front app is the target and forbidden")
        }
    }

    func testMovingTheTargetIsNotAStopButIsLogged() {
        let moved = frame.offsetBy(dx: 300, dy: 80)
        XCTAssertEqual(RecordingWatch.verdict(target: target, now: observation(frame: moved)), .keep)
        XCTAssertEqual(RecordingWatch.movement(from: frame, to: moved), "target window moved to 400,180,600,400")
        XCTAssertNil(RecordingWatch.movement(from: frame, to: frame.offsetBy(dx: 1, dy: -1)), "within tolerance")
        XCTAssertNil(RecordingWatch.movement(from: frame, to: nil))
        XCTAssertNil(RecordingWatch.movement(from: frame, to: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)))
    }
}

final class LiveRecordOptionsTests: XCTestCase {
    func parse(_ args: [String], _ env: [String: String] = [:]) -> LaunchOptions { LaunchOptions.parse(arguments: args, environment: env) }

    func testLiveRecordWithLiveRequestIsParsed() {
        let o = parse(["--live-request", "Fix this screen", "--live-record", "/tmp/out.mov", "--live-record-seconds", "45"])
        XCTAssertEqual(o.liveRecordPath, "/tmp/out.mov")
        XCTAssertEqual(o.liveRecordSeconds, 45)
        XCTAssertNil(o.liveRecordIgnoredLine)
    }

    func testEqualsFormsAndDefaultSeconds() {
        let o = parse(["--live-request=Fix this screen", "--live-record=/tmp/out.mov"])
        XCTAssertEqual(o.liveRecordPath, "/tmp/out.mov")
        XCTAssertEqual(o.liveRecordSeconds, 70)
    }

    func testEnvironmentVariables() {
        let o = parse([], ["SHEP_LIVE_REQUEST": "Fix this screen", "SHEP_LIVE_RECORD": "/tmp/e.mov", "SHEP_LIVE_RECORD_SECONDS": "30"])
        XCTAssertEqual(o.liveRecordPath, "/tmp/e.mov")
        XCTAssertEqual(o.liveRecordSeconds, 30)
        let flagWins = parse(["--live-record", "/tmp/f.mov"], ["SHEP_LIVE_REQUEST": "x", "SHEP_LIVE_RECORD": "/tmp/e.mov"])
        XCTAssertEqual(flagWins.liveRecordPath, "/tmp/f.mov")
    }

    func testLiveRecordWithoutLiveRequestIsIgnoredWithALogLine() {
        let o = parse(["--live-record", "/tmp/out.mov"])
        XCTAssertNil(o.liveRecordPath)
        XCTAssertEqual(o.liveRecordIgnoredLine, "[shep] live: ignored: --live-record needs --live-request")
        XCTAssertNil(parse(["--live-request", "go"]).liveRecordIgnoredLine, "nothing was asked to record")
    }

    func testBadSecondsFallBackToTheDefault() {
        for bad in ["0", "9", "601", "abc", "-5", "", "7.5"] {
            XCTAssertEqual(parse(["--live-request", "go", "--live-record", "/tmp/o.mov", "--live-record-seconds", bad]).liveRecordSeconds, 70, bad)
        }
        XCTAssertEqual(parse(["--live-request", "go", "--live-record", "/tmp/o.mov", "--live-record-seconds", "600"]).liveRecordSeconds, 600)
        XCTAssertEqual(parse(["--live-request", "go", "--live-record", "/tmp/o.mov", "--live-record-seconds", "10"]).liveRecordSeconds, 10)
    }

    func testAFlagLikeValueIsNotAPath() {
        let o = parse(["--live-request", "go", "--live-record", "--live-record-seconds", "20"])
        XCTAssertNil(o.liveRecordPath)
        XCTAssertEqual(o.liveRecordSeconds, 20)
    }

    func testTheLogLinesTheScriptReads() {
        XCTAssertEqual(LiveLog.recordWritten("/x/a.mov"), "[shep] live: recording written: /x/a.mov")
        XCTAssertEqual(LiveLog.recordRefused("no window"), "[shep] live: record refused: no window")
        XCTAssertTrue(LiveLog.recordDiscarded("the target window closed").hasPrefix("[shep] live: recording discarded: "))
    }
}
