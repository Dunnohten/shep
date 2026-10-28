import CoreGraphics
import XCTest
@testable import ShepCore

/// Reproductions for the 2026-10-28 live runs on a three-display layout (Cocoa frames: main 0,0,1512,982; above -737,982,1920,1080;
/// left -1293,49,1293,933) with Transmission. Each test names the run it comes from.

// MARK: bug 3 and bug 1: the namer's pick

final class NamerPickCrossCheckTests: XCTestCase {
    /// Transmission's window in the dry run: 1041 x 922 points at (471, 36), captured on a 2x display (2082 x 1844 px).
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 471, y: 36, width: 1041, height: 922), imageSize: CGSize(width: 2082, height: 1844), scale: 2)

    /// The Accessibility list of the 07:30 debug dump, reduced to role, label and frame (the labels are generic UI text).
    func axList() -> [Control] {
        func c(_ i: Int, _ role: String, _ frame: CGRect, title: String = "", description: String = "", help: String = "", actions: [String] = ["AXPress"]) -> Control {
            Control(index: i, role: role, title: title, description: description, window: "Transmission", help: help, frame: frame, actions: actions, pathID: "0/\(i)")
        }
        return [
            c(1, "AXButton", CGRect(x: 535, y: 54, width: 16, height: 16), help: "this button also has an action to zoom the window"),
            c(2, "AXButton", CGRect(x: 563, y: 36, width: 40, height: 52), description: "Create"),
            c(3, "AXButton", CGRect(x: 603, y: 36, width: 38, height: 52), description: "Open"),
            c(4, "AXCheckBox", CGRect(x: 1431, y: 36, width: 36, height: 52), description: "Filter"),
            c(5, "AXCheckBox", CGRect(x: 1467, y: 36, width: 41, height: 52), description: "Inspector"),
            c(6, "AXMenuButton", CGRect(x: 475, y: 89, width: 86, height: 22), title: "Ratio: N/A"),
            c(7, "AXMenuButton", CGRect(x: 475, y: 92, width: 28, height: 16), help: "All Groups"),
            c(8, "AXCheckBox", CGRect(x: 512, y: 91, width: 33, height: 18), title: "All"),
            c(9, "AXCheckBox", CGRect(x: 544, y: 91, width: 53, height: 18), title: "Active"),
            c(10, "AXCheckBox", CGRect(x: 596, y: 91, width: 91, height: 18), title: "Downloading"),
            c(11, "AXCheckBox", CGRect(x: 686, y: 91, width: 63, height: 18), title: "Seeding"),
            c(12, "AXCheckBox", CGRect(x: 749, y: 91, width: 59, height: 18), title: "Paused"),
            c(13, "AXCheckBox", CGRect(x: 807, y: 91, width: 46, height: 18), title: "Error"),
            c(14, "AXButton", CGRect(x: 1415, y: 92, width: 18, height: 16), description: "search"),
            c(15, "AXButton", CGRect(x: 486, y: 936, width: 20, height: 20), help: "Shortcuts for changing global settings."),
            c(16, "AXCheckBox", CGRect(x: 512, y: 936, width: 20, height: 20), help: "Speed Limit overrides the total bandwidth limits with its own limits."),
            c(17, "AXButton", CGRect(x: 489, y: 54, width: 16, height: 16)),
            c(18, "AXButton", CGRect(x: 512, y: 54, width: 16, height: 16)),
            c(19, "AXTextField", CGRect(x: 1411, y: 91, width: 97, height: 18), actions: []),
            c(20, "AXButton", CGRect(x: 641, y: 36, width: 37, height: 52), description: "Remove"),
            c(21, "AXButton", CGRect(x: 686, y: 45, width: 37, height: 36), description: "pause"),
            c(22, "AXButton", CGRect(x: 723, y: 45, width: 38, height: 36), description: "refresh"),
            c(23, "AXButton", CGRect(x: 1354, y: 36, width: 36, height: 52), description: "Share"),
            c(24, "AXCheckBox", CGRect(x: 1390, y: 36, width: 41, height: 52), description: "Quick Look"),
        ]
    }

    func input(_ request: String = "turn on the speed limit (turtle)") -> VisionInput {
        VisionInput(png: Data([1]), geometry: geometry, axControls: axList(), bundleID: "org.m0k.transmission", windowTitle: "Transmission", request: request)
    }

    func run(box: CGRect, found: [LocatedControl] = [], picker: (any ProposalPicking)? = FakePicker(result: PickResult(marks: [])),
             request: String = "turn on the speed limit (turtle)") async -> FixScreenResult {
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "A torrent window.", controls: found, targetBox: box))
        return await FixScreenPipeline(provider: provider, picker: picker, preparer: FakePreparer(result: nil)).run(input(request))
    }

    let speedLimit = "Speed Limit overrides the total bandwidth limits with its own limits."

    /// Run 4 (07:30 dry run): the model's box was 41,36,1024,1689 px (512 x 844 pt, 45 % of the window), the detector had a pane-sized
    /// box there, and the pane was offered as a click. The checkbox is the one strong match on the request words.
    func testAPaneSizedPickIsNotAControlAndTheStrongMatchWins() async {
        let box = CGRect(x: 41, y: 36, width: 1024, height: 1689)
        let r = await run(box: box, found: [LocatedControl(name: "Transfers", role: "button", box: box, score: 0.9)])
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, [speedLimit], "the checkbox, not a pane")
        XCTAssertTrue(r.proposals.allSatisfy { !$0.action.control.fromVision }, "no click on a control found on the screenshot")
        XCTAssertTrue(r.notes.contains { $0.contains("whole pane") }, "the log says why the pick was not used")
    }

    func testAPaneSizedPickWithNoStrongMatchOffersNothingRatherThanThePane() async {
        let box = CGRect(x: 41, y: 36, width: 1024, height: 1689)
        let r = await run(box: box, found: [LocatedControl(name: "Transfers", role: "button", box: box, score: 0.9)], request: "make it purple")
        XCTAssertTrue(r.proposals.allSatisfy { !$0.action.control.fromVision })
    }

    func testAPaneSizedPickWithoutAPickerStillFallsBackToTheRanking() async {
        let box = CGRect(x: 41, y: 36, width: 1024, height: 1689)
        let r = await run(box: box, found: [LocatedControl(name: "Transfers", role: "button", box: box, score: 0.9)], picker: nil)
        XCTAssertEqual(r.proposals.first?.action.control.label, speedLimit)
    }

    /// Run 1 (070758, window on the display above): the model pointed at the toolbar's Create button for a request that shares no word
    /// with it, while another listed control (the checkbox) is the one strong match. Create is at window-relative (0,0): px (185,0,80,104).
    func testAPickThatSharesNoWordWithTheRequestDoesNotBeatTheOneStrongMatch() async {
        let r = await run(box: CGRect(x: 184, y: 0, width: 82, height: 104))
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, [speedLimit])
    }

    // Guards: a normal pick still stands.
    func testAPickThatSharesWordsWithTheRequestStands() async {
        let r = await run(box: CGRect(x: 184, y: 0, width: 82, height: 104), request: "create a torrent")
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Create"])
    }

    func testASynonymPickStands() async {
        let r = await run(box: CGRect(x: 184, y: 0, width: 82, height: 104), request: "add a torrent")
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Create"], "add and create are one synonym group")
    }

    func testAnUnlabeledButtonIsStillTheModelsToPick() async {
        // Nothing in the list matches "turtle" strongly: the model's box stands even though its label shares no word.
        let r = await run(box: CGRect(x: 184, y: 0, width: 82, height: 104), request: "hide this button")
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Create"])
    }

    func testASmallBoxOnTheCheckboxIsAccepted() async {
        let screen = CGRect(x: 512, y: 936, width: 20, height: 20)
        let box = geometry.space.pixelRect(fromScreen: screen)
        let r = await run(box: box)
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, [speedLimit])
    }
}

// MARK: bug 2: a false "the target app is gone"

final class RecordingWatchFalseGoneTests: XCTestCase {
    /// Run 2 and 3: Transmission on the left display, window 7125 at (-1128,159) after the 60/70 point padding was removed.
    let target = RecordingTarget(pid: 4242, windowID: 7125, bundleID: "org.m0k.transmission", frame: CGRect(x: -1128, y: 159, width: 919, height: 657))

    func alive(bundle: String?) -> RecordingObservation {
        RecordingObservation(windowOnScreen: true, windowOwnerPID: 4242, bundleIDForTargetPID: bundle, frontPID: 4242,
                             frontBundleID: "org.m0k.transmission", frame: target.frame)
    }

    func testOneFailedBundleLookupWhileTheWindowServerStillListsTheWindowIsNotGone() {
        var state = RecordingWatchState()
        XCTAssertEqual(state.verdict(target: target, now: alive(bundle: "org.m0k.transmission")), .keep)
        XCTAssertEqual(state.verdict(target: target, now: alive(bundle: nil)), .keep, "the window is on screen and owned by the pid: the app is not gone")
        XCTAssertEqual(state.verdict(target: target, now: alive(bundle: "org.m0k.transmission")), .keep)
    }

    func testTheLookupMustFailForTheWholeLimitBeforeItStopsAndTheReasonIsNotGone() {
        var state = RecordingWatchState()
        for tick in 1..<RecordingWatchState.unresolvedLimit {
            XCTAssertEqual(state.verdict(target: target, now: alive(bundle: nil)), .keep, "tick \(tick)")
        }
        guard case .stop(let why) = state.verdict(target: target, now: alive(bundle: nil)) else { return XCTFail("a lookup that never works must stop") }
        XCTAssertFalse(why.contains("gone"), "the process is not gone; what failed is the check of who it is")
        XCTAssertTrue(why.contains("could not confirm"))
    }

    func testAResolvedLookupResetsTheCount() {
        var state = RecordingWatchState()
        for _ in 1..<RecordingWatchState.unresolvedLimit { _ = state.verdict(target: target, now: alive(bundle: nil)) }
        XCTAssertEqual(state.verdict(target: target, now: alive(bundle: "org.m0k.transmission")), .keep)
        for _ in 1..<RecordingWatchState.unresolvedLimit { XCTAssertEqual(state.verdict(target: target, now: alive(bundle: nil)), .keep) }
    }

    func testTheOtherStopsStayImmediate() {
        var state = RecordingWatchState()
        var closed = alive(bundle: "org.m0k.transmission"); closed.windowOnScreen = false
        XCTAssertEqual(state.verdict(target: target, now: closed), .stop("the target window closed or was minimised"))
        var moved = alive(bundle: "org.m0k.transmission"); moved.windowOwnerPID = 9
        XCTAssertEqual(state.verdict(target: target, now: moved), .stop("the target window changed owner"))
        XCTAssertEqual(state.verdict(target: target, now: alive(bundle: "com.apple.mail")), .stop("another app now has the target's process id"))
        var forbidden = alive(bundle: "org.m0k.transmission"); forbidden.frontBundleID = "com.apple.mail"
        XCTAssertEqual(state.verdict(target: target, now: forbidden), .stop("the app in front is a forbidden app and it is the target"))
    }

    // The observation from fake window lists (what LiveRecorder reads from CGWindowList), with negative origins.
    let leftWindow = RecordingWindowEntry(id: 7125, ownerPID: 4242, bounds: CGRect(x: -1128, y: 159, width: 919, height: 657))
    let straddle = RecordingWindowEntry(id: 7125, ownerPID: 4242, bounds: CGRect(x: 11, y: 342, width: 600, height: 365))
    let other = RecordingWindowEntry(id: 1, ownerPID: 99, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))

    func testAWindowOnTheLeftDisplayIsFoundAndKeptWhenTheDirectLookupFails() {
        for window in [leftWindow, straddle] {
            let now = RecordingWatch.observe(target: target, windows: [other, window], bundleForPID: { _ in nil },
                                             pidsForBundle: { $0 == "org.m0k.transmission" ? [4242] : [] }, frontPID: 4242,
                                             frontBundleID: "org.m0k.transmission")
            XCTAssertTrue(now.windowOnScreen)
            XCTAssertEqual(now.windowOwnerPID, 4242)
            XCTAssertEqual(now.frame, window.bounds, "negative origins pass through untouched")
            XCTAssertEqual(now.bundleIDForTargetPID, "org.m0k.transmission", "the second lookup (by bundle id) finds the same pid")
            var state = RecordingWatchState()
            XCTAssertEqual(state.verdict(target: target, now: now), .keep)
        }
    }

    func testTheSecondLookupNeverAdoptsAnotherProcess() {
        let now = RecordingWatch.observe(target: target, windows: [leftWindow], bundleForPID: { _ in nil },
                                         pidsForBundle: { _ in [31337] }, frontPID: nil, frontBundleID: nil)
        XCTAssertNil(now.bundleIDForTargetPID, "the bundle has a different pid: that is not our target")
    }

    func testAMissingWindowIsNotOnScreen() {
        let now = RecordingWatch.observe(target: target, windows: [other], bundleForPID: { _ in "org.m0k.transmission" },
                                         pidsForBundle: { _ in [4242] }, frontPID: nil, frontBundleID: nil)
        XCTAssertFalse(now.windowOnScreen)
        XCTAssertNil(now.windowOwnerPID)
    }
}

// MARK: bug 1 and bug 4 guards: the pure geometry on this layout (expected to pass; they rule out the coordinate conversions)

final class ThreeDisplayGeometryTests: XCTestCase {
    let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -737, y: 982, width: 1920, height: 1080),
                   CGRect(x: -1293, y: 49, width: 1293, height: 933)]
    func usable(menuBar: CGFloat = 37) -> [CGRect] {
        [CGRect(x: 0, y: 0, width: 1512, height: 982 - menuBar), CGRect(x: -737, y: 982, width: 1920, height: 1080 - menuBar),
         CGRect(x: -1293, y: 49, width: 1293, height: 933 - menuBar)]
    }
    func obs(_ ax: CGRect) -> WindowObservation { WindowObservation(pid: 7, bundleID: "org.m0k.transmission", axFrame: ax) }
    func plan(_ ax: CGRect, menuBar: CGFloat = 37) -> DockPlan {
        DockPlanner.plan(obs(ax), ownPID: 1, screens: screens, usable: usable(menuBar: menuBar), primaryScreenHeight: 982)
    }

    /// Run 4 (dry run 2): window (471,36,1041,922), flush under the menu bar, its right edge exactly on the screen edge.
    func testTheDryRunWindowDocksInsideOnTheMainDisplay() {
        for menuBar in [24, 33, 36, 37, 38] as [CGFloat] {
            for frame in [CGRect(x: 471, y: 36, width: 1041, height: 922), CGRect(x: 470, y: 36, width: 1043, height: 922), CGRect(x: 411, y: 36, width: 1041, height: 922)] {
                let layout = plan(frame, menuBar: menuBar).placement.layout
                XCTAssertNotNil(layout, "\(frame) menu bar \(menuBar)")
                if let layout { XCTAssertTrue(screens[0].contains(CGPoint(x: layout.rect.midX, y: layout.rect.midY))) }
            }
        }
    }

    /// Run 1: window on the display above, AX y negative. The tab stands on its top edge (Cocoa y 1763).
    func testAWindowOnTheDisplayAboveDocksAboveWithTheRightCocoaRect() {
        let ax = CGRect(x: 186, y: -781, width: 919, height: 657)
        guard let layout = plan(ax).placement.layout else { return XCTFail("hidden") }
        XCTAssertEqual(layout.style, .above)
        XCTAssertEqual(layout.rect.minY, 982 - (-781), accuracy: 0.001)
        XCTAssertTrue(screens[1].contains(CGPoint(x: layout.rect.midX, y: layout.rect.midY)))
    }

    func testAWindowOnTheLeftDisplayAndOneStraddlingBothDock() {
        for ax in [CGRect(x: -1128, y: 159, width: 919, height: 657), CGRect(x: 11, y: 342, width: 600, height: 365)] {
            XCTAssertNotNil(plan(ax).placement.layout, "\(ax)")
        }
    }

    /// A box in the screenshot of a window on the display above lands inside that window in global top-left points.
    func testPixelsMapToScreenPointsWithNegativeOriginsAtAnyScale() {
        for (frame, scale) in [(CGRect(x: 186, y: -781, width: 919, height: 657), 1.0), (CGRect(x: -1128, y: 159, width: 919, height: 657), 2.0),
                               (CGRect(x: 471, y: 36, width: 1041, height: 922), 2.0)] as [(CGRect, CGFloat)] {
            let space = CoordinateSpace(windowFrame: frame, imageSize: CGSize(width: frame.width * scale, height: frame.height * scale))
            let screen = CGRect(x: frame.minX + 100, y: frame.minY + 50, width: 40, height: 52)
            let px = space.pixelRect(fromScreen: screen)
            XCTAssertEqual(px, CGRect(x: 100 * scale, y: 50 * scale, width: 40 * scale, height: 52 * scale))
            XCTAssertEqual(space.screenRect(fromPixels: px), screen)
            XCTAssertEqual(space.screenRect(fromPixels: CGRect(x: 0, y: 0, width: 1, height: 1)).origin, frame.origin)
        }
    }

    func testControlsOfAWindowWithNegativeYSurviveTheWindowFilter() {
        let window = CGRect(x: 186, y: -781, width: 919, height: 657)
        let inside = Control(index: 1, role: "AXButton", title: "Create", frame: CGRect(x: 279, y: -781, width: 40, height: 52), actions: ["AXPress"], pathID: "0/1")
        let outside = Control(index: 2, role: "AXButton", title: "Elsewhere", frame: CGRect(x: 300, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/2")
        XCTAssertEqual(ControlFilter.prepare([inside, outside], limit: 60, window: window).map(\.title), ["Create"])
    }
}
