import CoreGraphics
import XCTest
@testable import ShepCore

/// Run 1 of 2026-10-28 08:08 (Transmission on the display above the main one, scale 1): the namer pointed at empty toolbar space
/// (box 308,18,16,15 px), the trace said `matched=yes`, `ranked=0`, `picker: not used`, and the click was refused with "I can't
/// identify what is under that spot". The speed-limit checkbox (#16, named by its tooltip) was never considered.
/// The fixture is the run's debug dump: the 22 prepared controls (role, label, label source, frame) and the window frame.
enum Run1Above {
    static let window = CGRect(x: -337, y: -1020, width: 1041, height: 922)
    /// The capture was 1041 x 922 px: scale 1 on that display. ScreenCapture passes 2 as its fallback scale.
    static let geometry = CaptureGeometry(windowFrame: window, imageSize: CGSize(width: 1041, height: 922), scale: 2)
    static let pickBox = CGRect(x: 308, y: 18, width: 16, height: 15)
    static let request = "turn on the speed limit (turtle)"
    static let speedLimit = "Speed Limit overrides the total bandwidth limits with its own limits."
    static let bundle = "org.m0k.transmission"

    /// #1-#16 enabled and pressable, #17 an unlabeled field, #18-#22 disabled (no torrent selected), which is the order
    /// `ControlFilter.prepare` gave them in the dump.
    static func controls() -> [Control] {
        func c(_ i: Int, _ role: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, title: String = "", description: String = "",
               help: String = "", enabled: Bool = true, actions: [String] = ["AXPress"]) -> Control {
            Control(index: i, role: role, title: title, description: description, window: "Transmission", help: help,
                    frame: CGRect(x: x, y: y, width: w, height: h), enabled: enabled, actions: actions, pathID: "0/\(i)")
        }
        return [
            c(1, "AXMenuButton", -322, -1005, 68, 22, title: "Window sharing"),
            c(2, "AXButton", -245, -1020, 40, 52, description: "Create"),
            c(3, "AXButton", -205, -1020, 38, 52, description: "Open"),
            c(4, "AXCheckBox", 623, -1020, 36, 52, description: "Filter"),
            c(5, "AXCheckBox", 659, -1020, 41, 52, description: "Inspector"),
            c(6, "AXMenuButton", -333, -967, 87, 22, title: "Ratio: N/A"),
            c(7, "AXMenuButton", -333, -964, 28, 16, help: "All Groups"),
            c(8, "AXCheckBox", -296, -965, 33, 18, title: "All"),
            c(9, "AXCheckBox", -264, -965, 54, 18, title: "Active"),
            c(10, "AXCheckBox", -211, -965, 91, 18, title: "Downloading"),
            c(11, "AXCheckBox", -121, -965, 64, 18, title: "Seeding"),
            c(12, "AXCheckBox", -58, -965, 59, 18, title: "Paused"),
            c(13, "AXCheckBox", 0, -965, 47, 18, title: "Error"),
            c(14, "AXButton", 607, -964, 18, 16, description: "search"),
            c(15, "AXButton", -322, -120, 20, 20, help: "Shortcuts for changing global settings."),
            c(16, "AXCheckBox", -296, -120, 20, 20, help: speedLimit),
            c(17, "AXTextField", 603, -965, 97, 18, actions: []),
            c(18, "AXButton", -167, -1020, 37, 52, description: "Remove", enabled: false),
            c(19, "AXButton", -122, -1011, 37, 36, description: "pause", enabled: false),
            c(20, "AXButton", -85, -1011, 38, 36, description: "refresh", enabled: false),
            c(21, "AXButton", 545, -1020, 36, 52, description: "Share", enabled: false),
            c(22, "AXCheckBox", 581, -1020, 42, 52, description: "Quick Look", enabled: false),
        ]
    }

    static func input(request: String = Run1Above.request, title: String = "Transmission") -> VisionInput {
        VisionInput(png: Data([1]), geometry: geometry, axControls: controls(), bundleID: bundle, windowTitle: title, request: request)
    }

    static let prepared = FakePreparer(result: PreparedImage(jpeg: Data([1]), size: CGSize(width: 960, height: 850),
                                                             originalSize: CGSize(width: 1041, height: 922)))
}

// MARK: the coordinate spaces

final class Run1GeometryTests: XCTestCase {
    func testTheFixtureIsTheDumpsOrderAfterPreparing() {
        let prepared = ControlFilter.prepare(Run1Above.controls())
        XCTAssertEqual(prepared.count, 22)
        XCTAssertEqual(prepared[15].index, 16)
        XCTAssertEqual(prepared[15].label, Run1Above.speedLimit)
        XCTAssertEqual(prepared[15].labelSource, .tooltip)
    }

    /// The scale comes from the image and the window (1 on that display), not from the fallback 2 or the main display.
    func testTheScaleIsMeasuredFromTheWindowsOwnCapture() {
        let g = Run1Above.geometry
        XCTAssertEqual(g.scaleX, 1)
        XCTAssertEqual(g.scaleY, 1)
        assertRect(g.screenRect(forPixels: Run1Above.pickBox), CGRect(x: -29, y: -1002, width: 16, height: 15))
        assertRect(g.space.windowRect(fromPixels: Run1Above.pickBox), Run1Above.pickBox)
        assertRect(g.space.pixelRect(fromScreen: CGRect(x: -296, y: -120, width: 20, height: 20)), CGRect(x: 41, y: 900, width: 20, height: 20))
    }

    /// The pick box is empty toolbar space: no listed control is under it or near it.
    func testThePickBoxIsNoListedControl() {
        let screen = Run1Above.geometry.screenRect(forPixels: Run1Above.pickBox)
        let ax = ControlFilter.prepare(Run1Above.controls())
        XCTAssertEqual(VisionRepair.axDuplicateResolution(of: screen, ax: ax), .none)
        XCTAssertNil(RoleResolver.axMatch(for: screen, in: ax))
    }
}

// MARK: item 2: a pick found only on the screenshot does not beat the one strong listed match

final class Run1ScreenshotOnlyPickTests: XCTestCase {
    /// The trace's counts: 29 detector boxes, 6 candidates, 3 of them text or pictures, `found=4`. So 3 found controls came from
    /// candidates and the fourth was the box the model drew itself (`NamedTarget.box`), with the model's own name for it.
    func pipelineRun(pickName: String, request: String = Run1Above.request, picker: (any ProposalPicking)? = FakePicker(result: PickResult(marks: []))) async -> FixScreenResult {
        let found = [
            LocatedControl(name: "unlabeled icon", role: "icon", box: CGRect(x: 880, y: 898, width: 16, height: 16), score: 0.6),
            LocatedControl(name: "unlabeled icon", role: "icon", box: CGRect(x: 960, y: 898, width: 16, height: 16), score: 0.6),
            LocatedControl(name: "unlabeled icon", role: "icon", box: CGRect(x: 1000, y: 898, width: 16, height: 16), score: 0.6),
            LocatedControl(name: pickName, role: "", box: Run1Above.pickBox, score: 0.5),
        ]
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "A torrent window.", controls: found, targetBox: Run1Above.pickBox))
        return await FixScreenPipeline(provider: provider, picker: picker, preparer: FakePreparer(result: nil)).run(Run1Above.input(request: request))
    }

    /// The model's name for its own box echoes the request, so the old rule (a pick sharing no request word does not decide) did not
    /// fire, and with two strong matches (the pick and the checkbox) `uniqueStrongMatch` was nil. The ranking never ran.
    func testThePickIsNotOfferedOverTheOneStrongListedMatch() async {
        for name in ["Speed limit (turtle)", "Speed Limit", "turtle", "speed limit toggle"] {
            let r = await pipelineRun(pickName: name)
            XCTAssertEqual(r.proposals.map { $0.action.control.label }, [Run1Above.speedLimit], "pick named \(name)")
            XCTAssertEqual(r.proposals.first?.action.control.index, 16, "pick named \(name)")
            XCTAssertTrue(r.proposals.allSatisfy { !$0.action.control.fromVision }, "pick named \(name)")
            XCTAssertGreaterThan(r.trace.rankedCount, 0, "the ranking ran (pick named \(name))")
            XCTAssertEqual(r.trace.strongMatchOffer, FixScreenTrace.strongMatchOverScreenshotPick, "pick named \(name)")
        }
    }

    func testItHoldsWithoutAPickerToo() async {
        let r = await pipelineRun(pickName: "Speed limit (turtle)", picker: nil)
        XCTAssertEqual(r.proposals.map { $0.action.control.index }, [16])
    }

    /// The same run through the detector provider: detector boxes, a namer that draws its own box, the real pipeline.
    func testTheWholeChainFromTheDetectorOffersTheCheckbox() async {
        let r = await Run1Chain.run()
        XCTAssertEqual(r.proposals.map { $0.action.control.index }, [16])
        XCTAssertEqual(r.proposals.first?.action.control.label, Run1Above.speedLimit)
    }

    // Guards: a pick on a listed control still decides; a screenshot pick with no strong listed rival still stands.
    func testAPickOnTheCheckboxItselfStands() async {
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: [], targetBox: CGRect(x: 41, y: 900, width: 20, height: 20)))
        let r = await FixScreenPipeline(provider: provider, picker: FakePicker(result: PickResult(marks: [])), preparer: FakePreparer(result: nil)).run(Run1Above.input())
        XCTAssertEqual(r.proposals.map { $0.action.control.index }, [16])
        XCTAssertTrue(r.trace.namerMatched)
        XCTAssertTrue(r.fallbackProposals.isEmpty, "a listed control needs no fallback")
    }

    func testAScreenshotPickWithNoStrongListedMatchStandsAndCarriesTheListedFallback() async {
        // "limit" is one shared word with the checkbox (10): a match, not a strong one. The model's "turtle" box decides.
        let r = await pipelineRun(pickName: "turtle", request: "set the turtle limit")
        XCTAssertEqual(r.proposals.count, 1)
        XCTAssertEqual(r.proposals.first?.action.control.fromVision, true)
        XCTAssertEqual(r.fallbackProposals.map { $0.action.control.index }, [16])
        XCTAssertEqual(r.trace.fallbackCount, 1)
    }
}

// MARK: item 2: the walk falls back to the listed controls when the screenshot spot has nothing nameable

final class ProposalFallbackTests: XCTestCase {
    let found = Control(index: 23, role: "AXButton", title: "turtle", window: "Transmission", frame: CGRect(x: -29, y: -1002, width: 16, height: 15), pathID: "v4", fromVision: true)
    let listed = Run1Above.controls()[15]

    func proposal(_ c: Control) -> Proposal {
        let action = ApprovalPolicy.defaultAction(for: c, bundleID: Run1Above.bundle)
        return Proposal(action: action, requirement: ApprovalPolicy.requirement(for: action))
    }

    func testAnUnidentifiedSpotOnAScreenshotPickWalksTheFallback() {
        let fallback = [proposal(listed)]
        XCTAssertEqual(ProposalFallback.replacement(after: .refused(ClickGuard.unidentified), of: proposal(found), fallback: fallback), fallback)
    }

    func testEverythingElseGoesOnAsBefore() {
        let fallback = [proposal(listed)]
        XCTAssertNil(ProposalFallback.replacement(after: .refused("Shep never presses that."), of: proposal(found), fallback: fallback))
        XCTAssertNil(ProposalFallback.replacement(after: .declined, of: proposal(found), fallback: fallback))
        XCTAssertNil(ProposalFallback.replacement(after: .done("x"), of: proposal(found), fallback: fallback))
        XCTAssertNil(ProposalFallback.replacement(after: .needsFreshApproval("moved"), of: proposal(found), fallback: fallback))
        XCTAssertNil(ProposalFallback.replacement(after: .refused(ClickGuard.unidentified), of: proposal(listed), fallback: fallback),
                     "a listed control is not replaced")
        XCTAssertNil(ProposalFallback.replacement(after: .refused(ClickGuard.unidentified), of: proposal(found), fallback: []))
        XCTAssertNil(ProposalFallback.replacement(after: .refused(ClickGuard.unidentified), of: proposal(found), fallback: [proposal(found)]),
                     "a fallback holds listed controls only")
    }
}

// MARK: item 1: the debug dump says what the detector saw and what the pick matched

enum Run1Chain {
    static let detections = [
        DetectedBox(box: CGRect(x: 92, y: 0, width: 40, height: 52), score: 0.9, source: "omniparser-v3", kind: "icon", caption: "CAPTION-TEXT-ONE"),
        DetectedBox(box: CGRect(x: 41, y: 900, width: 20, height: 20), score: 0.8, source: "omniparser-v3", kind: "icon", caption: "a turtle"),
        DetectedBox(box: CGRect(x: 880, y: 898, width: 16, height: 16), score: 0.7, source: "omniparser-v3", kind: "icon", caption: "CAPTION-TEXT-TWO"),
        DetectedBox(box: CGRect(x: 960, y: 898, width: 16, height: 16), score: 0.7, source: "omniparser-v3", kind: "icon"),
        DetectedBox(box: CGRect(x: 400, y: 450, width: 260, height: 20), score: 0.6, source: "omniparser-v3", kind: "text"),
    ]

    /// Candidates in reading order: 1 the text line, 2 and 3 the status-bar icons (the two boxes on listed controls are not candidates).
    static let namer = FakeNamer(result: NamingResult(summary: "A torrent window.",
                                                      labels: [1: MuseLabel(id: 1, name: "No transfers", role: "text"),
                                                               2: MuseLabel(id: 2, name: "Upload rate", role: "icon")],
                                                      target: .box(name: "Speed limit (turtle)", rect: Run1Above.pickBox)))

    static func run(title: String = "Transmission") async -> FixScreenResult {
        let provider = DetectorVisionProvider(detector: FakeDetector(boxes: detections), namer: namer, preparer: Run1Above.prepared)
        let pipeline = FixScreenPipeline(provider: provider, picker: FakePicker(result: PickResult(marks: [])), preparer: Run1Above.prepared)
        return await pipeline.run(Run1Above.input(title: title))
    }
}

final class Run1DebugDumpTests: XCTestCase {
    func testTheTraceNamesTheCoordinateSpaces() async {
        let text = LiveDebug.traceText(await Run1Chain.run())
        XCTAssertTrue(text.contains("space: image=1041x922 px window=-337,-1020,1041,922 pt scale=1.00x1.00 measured (fallback 2.00 unused) sent=960x850 px"), text)
    }

    func testTheTraceSaysWhereThePickCameFromAndWhatItMatched() async {
        let text = LiveDebug.traceText(await Run1Chain.run())
        XCTAssertTrue(text.contains("namer: pick box=308,18,16,15 "), "the old line stays: \(text)")
        XCTAssertTrue(text.contains("namer: pick px=308,18,16,15 window-pt=308,18,16,15 screen-pt=-29,-1002,16,15 from=model-box"), text)
        XCTAssertTrue(text.contains("namer: matched screenshot-only AXButton \"Speed limit (turtle)\" used=no"), text)
    }

    func testAPickOnAListedControlNamesItsNumber() async {
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: [], targetBox: CGRect(x: 41, y: 900, width: 20, height: 20)))
        let r = await FixScreenPipeline(provider: provider, picker: nil, preparer: FakePreparer(result: nil)).run(Run1Above.input())
        let text = LiveDebug.traceText(r)
        XCTAssertTrue(text.contains("namer: matched ax #16 AXCheckBox \"Speed Limit overrides the total bandwidth limits with its ow\" used=yes"), text)
    }

    func testTheTraceListsEveryDetectorBoxWithItsListedMatch() async {
        let text = LiveDebug.traceText(await Run1Chain.run())
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("detector: 5 box(es)"), text)
        func line(_ px: String) -> String? { lines.first { $0.contains("px=\(px) ") && $0.hasPrefix("  d") } }
        XCTAssertEqual(line("92,0,40,52"), "  d1 px=92,0,40,52 window-pt=92,0,40,52 kind=icon score=0.90 ax=#2 candidate=- offered=no", text)
        XCTAssertEqual(line("41,900,20,20"), "  d2 px=41,900,20,20 window-pt=41,900,20,20 kind=icon score=0.80 ax=#16 candidate=- offered=no", text)
        let status = line("880,898,16,16") ?? ""
        XCTAssertTrue(status.contains("ax=- candidate=#"), text)
        XCTAssertTrue(status.contains("offered=yes"), text)
        let words = line("400,450,260,20") ?? ""
        XCTAssertTrue(words.contains("kind=text"), text)
        XCTAssertTrue(words.contains("offered=no"), text)
    }

    func testTheDetectorLinesHoldNoCaptionNoTitleAndStayCapped() async {
        let text = LiveDebug.traceText(await Run1Chain.run(title: "SECRET-WINDOW-TITLE"))
        XCTAssertFalse(text.contains("CAPTION-TEXT"), text)
        XCTAssertFalse(text.contains("a turtle"), text)
        XCTAssertFalse(text.contains("SECRET-WINDOW-TITLE"), text)
        for line in text.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, LiveDebug.lineLimit + 1) }
    }

    func testANamerLabelIsScrubbedAndCannotForgeALine() {
        var t = FixScreenTrace(hadRequest: true)
        t.detector.detectorCount = 1
        t.detector.detectorBoxes = [TraceDetectorBox(pixelBox: CGRect(x: 1, y: 2, width: 3, height: 4), windowBox: CGRect(x: 1, y: 2, width: 3, height: 4),
                                                     kind: "icon\nstatus: ok", score: 1, candidate: 1,
                                                     label: "sk-abcdefghijklmnop1234567890\n  d9 px=0,0,1,1", offered: true)]
        let text = LiveDebug.traceText(FixScreenResult(status: .ok, provider: "fake", summary: "", controls: [], proposals: [], notes: [], trace: t))
        XCTAssertFalse(text.contains("abcdefghijkl"), text)
        XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("  d") }.count, 1, text)
        XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("status:") }.count, 1, text)
    }

    func testAFallbackScaleIsSaidOutLoud() {
        var t = FixScreenTrace(hadRequest: true)
        t.space = TraceSpace(geometry: CaptureGeometry(windowFrame: CGRect(x: 0, y: 0, width: 0, height: 0), imageSize: CGSize(width: 800, height: 600), scale: 2))
        let text = LiveDebug.traceText(FixScreenResult(status: .ok, provider: "fake", summary: "", controls: [], proposals: [], notes: [], trace: t))
        XCTAssertTrue(text.contains("scale=2.00x2.00 fallback"), text)
    }
}

// MARK: item 3: one line per change in the recording watch

final class RecordingWatchLogTests: XCTestCase {
    let target = RecordingTarget(pid: 4242, windowID: 7125, bundleID: "org.m0k.transmission", frame: CGRect(x: -337, y: -1020, width: 1041, height: 922))

    func obs(onScreen: Bool = true, owner: Int32? = 4242, bundle: String? = "org.m0k.transmission", frontPID: Int32? = 4242, frontBundle: String? = "org.m0k.transmission") -> RecordingObservation {
        RecordingObservation(windowOnScreen: onScreen, windowOwnerPID: owner, bundleIDForTargetPID: bundle, frontPID: frontPID, frontBundleID: frontBundle,
                             frame: target.frame)
    }

    func testTheLineHasExactlyTheThreeFields() {
        XCTAssertEqual(RecordingWatchLog.line(t: 1.254, alive: true, reason: .ok), "[shep] live: watch t=1.25 alive=yes reason=ok")
        XCTAssertEqual(RecordingWatchLog.line(t: 0, alive: false, reason: .windowMissing), "[shep] live: watch t=0.00 alive=no reason=window-missing")
        XCTAssertEqual(RecordingWatchLog.line(t: -3, alive: true, reason: .moved), "[shep] live: watch t=0.00 alive=yes reason=moved")
        XCTAssertEqual(RecordingWatchLog.line(t: .nan, alive: true, reason: .ok), "[shep] live: watch t=0.00 alive=yes reason=ok")
        XCTAssertEqual(RecordingWatchLog.line(t: 1e300, alive: true, reason: .ok), "[shep] live: watch t=999999.00 alive=yes reason=ok")
    }

    /// Every line any input can produce matches one fixed shape; the reason set is closed and pinned.
    func testNoLineCanHoldAnythingButThoseFields() throws {
        XCTAssertEqual(Set(WatchReason.allCases.map(\.rawValue)),
                       ["ok", "moved", "window-missing", "owner-changed", "bundle-empty", "pid-gone", "bundle-mismatch", "not-allowed",
                        "forbidden-front", "stream-error", "slot-problem"])
        let shape = try NSRegularExpression(pattern: "^\\[shep\\] live: watch t=[0-9]{1,6}\\.[0-9]{2} alive=(yes|no) reason=[a-z-]+$")
        for reason in WatchReason.allCases {
            for t in [0, 0.25, 4.999, 61.5, -1, Double.infinity] {
                for alive in [true, false] {
                    let line = RecordingWatchLog.line(t: t, alive: alive, reason: reason)
                    XCTAssertEqual(shape.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)), 1, line)
                }
            }
        }
        XCTAssertEqual(RecordingWatchLog.summaryLine(t: 5, checks: 20, notAlive: 0), "[shep] live: watch: 20 checks, all alive (t=5.00)")
        XCTAssertEqual(RecordingWatchLog.summaryLine(t: 10.5, checks: 20, notAlive: 3), "[shep] live: watch: 20 checks, 3 not alive (t=10.50)")
    }

    func testTheReasonFollowsTheVerdictsOrder() {
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(), moved: false), .ok)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(), moved: true), .moved)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(onScreen: false, owner: nil, bundle: nil), moved: false), .windowMissing)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(owner: 99), moved: false), .ownerChanged)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(bundle: nil), moved: false), .bundleEmpty)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(bundle: "  "), moved: false), .bundleEmpty)
        XCTAssertEqual(RecordingWatchLog.reason(target: target, now: obs(bundle: "com.example.other"), moved: false), .bundleMismatch)
    }

    func testRepeatsCollapseToTheFirstEveryChangeAndAFiveSecondSummary() {
        var state = RecordingWatchLogState()
        var out: [String] = []
        var t = 0.0
        while t <= 5.0 + 1e-9 { out += state.record(t: t, alive: true, reason: .ok); t += 0.25 }
        XCTAssertEqual(out, ["[shep] live: watch t=0.00 alive=yes reason=ok", "[shep] live: watch: 21 checks, all alive (t=5.00)"])
        out = state.record(t: 5.25, alive: true, reason: .bundleEmpty)
        XCTAssertEqual(out, ["[shep] live: watch t=5.25 alive=yes reason=bundle-empty"])
        XCTAssertEqual(state.record(t: 5.5, alive: true, reason: .bundleEmpty), [])
        XCTAssertEqual(state.record(t: 5.75, alive: true, reason: .ok), ["[shep] live: watch t=5.75 alive=yes reason=ok"])
        XCTAssertEqual(state.record(t: 6.0, alive: false, reason: .windowMissing), ["[shep] live: watch t=6.00 alive=no reason=window-missing"])
    }

    func testASummaryCountsTheChecksSinceTheLastOne() {
        var state = RecordingWatchLogState()
        _ = state.record(t: 0, alive: true, reason: .ok)
        _ = state.record(t: 5, alive: true, reason: .ok)   // summary of 2
        var lines: [String] = []
        for i in 1...20 { lines += state.record(t: 5 + Double(i) * 0.25, alive: true, reason: .ok) }
        XCTAssertEqual(lines, ["[shep] live: watch: 20 checks, all alive (t=10.00)"])
    }
}
