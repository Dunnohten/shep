import CoreGraphics
import XCTest
@testable import ShepCore

/// `--live-target <bundle-id>`: the live request is bound to the app it was meant for. Measured on the Mac: the run-to-run variation
/// of a dry run came from WHICH APP WAS IN FRONT when Shep submitted, not from the model.
final class LiveTargetOptionTests: XCTestCase {
    func testTheFlagTakesABundleIdInBothSpellingsAndTheEnvironment() {
        let a = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", "org.m0k.transmission"], environment: [:])
        XCTAssertEqual(a.liveTarget, "org.m0k.transmission")
        XCTAssertNil(a.liveTargetIgnoredLine)
        let b = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target=org.m0k.transmission"], environment: [:])
        XCTAssertEqual(b.liveTarget, "org.m0k.transmission")
        let c = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x"], environment: ["SHEP_LIVE_TARGET": "com.example.App-1_x"])
        XCTAssertEqual(c.liveTarget, "com.example.App-1_x")
    }

    func testTheFlagWinsOverTheEnvironment() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", "a.b"], environment: ["SHEP_LIVE_TARGET": "c.d"])
        XCTAssertEqual(o.liveTarget, "a.b")
    }

    func testNoFlagMeansNoTarget() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x"], environment: [:])
        XCTAssertNil(o.liveTarget)
        XCTAssertNil(o.liveTargetIgnoredLine)
        XCTAssertNil(o.liveTargetInvalid, "no flag and no environment: the default front-app behaviour")
    }

    /// F2 of the code review: an explicitly supplied binding that is unusable must refuse the run, not fall back to the front app.
    func testABundleIdWithOtherCharactersIsAnInvalidBindingNotAnAbsentOne() {
        for bad in ["org m0k", "org/m0k", "org.m0k;rm", "org.m0k\u{00E9}", "a b.c", "$(x)", "a..b\n", "org.m0k.transmission ", " org.m0k.transmission", "-x"] {
            let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", bad], environment: [:])
            XCTAssertNil(o.liveTarget, bad)
            XCTAssertEqual(o.liveTargetInvalid, "--live-target is not a bundle id", bad)
            XCTAssertNil(o.liveTargetIgnoredLine, bad)
        }
    }

    func testATooLongValueIsInvalid() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", String(repeating: "a", count: 300)], environment: [:])
        XCTAssertNil(o.liveTarget)
        XCTAssertEqual(o.liveTargetInvalid, "--live-target is too long")
    }

    func testAMissingOrEmptyValueIsInvalid() {
        let missingAtEnd = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target"], environment: [:])
        XCTAssertNil(missingAtEnd.liveTarget)
        XCTAssertEqual(missingAtEnd.liveTargetInvalid, "--live-target needs a value")
        let equalsEmpty = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target="], environment: [:])
        XCTAssertEqual(equalsEmpty.liveTargetInvalid, "--live-target needs a value")
        let emptyArg = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", ""], environment: [:])
        XCTAssertEqual(emptyArg.liveTargetInvalid, "--live-target needs a value")
    }

    func testAFlagLikeValueIsAMissingValueAndInvalid() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", "--capturable"], environment: [:])
        XCTAssertNil(o.liveTarget)
        XCTAssertEqual(o.liveTargetInvalid, "--live-target needs a value")
    }

    func testJunkOrEmptyEnvironmentIsInvalid() {
        let junk = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x"], environment: ["SHEP_LIVE_TARGET": "org m0k"])
        XCTAssertNil(junk.liveTarget)
        XCTAssertEqual(junk.liveTargetInvalid, "SHEP_LIVE_TARGET is not a bundle id")
        let empty = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x"], environment: ["SHEP_LIVE_TARGET": ""])
        XCTAssertNil(empty.liveTarget)
        XCTAssertEqual(empty.liveTargetInvalid, "SHEP_LIVE_TARGET needs a value")
    }

    func testIfEitherSuppliedValueIsUnusableTheRunIsInvalid() {
        // A valid flag does not rescue a junk environment value, and the other way round: both are explicit bindings.
        let flagOK = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", "a.b"], environment: ["SHEP_LIVE_TARGET": "junk value"])
        XCTAssertNil(flagOK.liveTarget)
        XCTAssertEqual(flagOK.liveTargetInvalid, "SHEP_LIVE_TARGET is not a bundle id")
        let envOK = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", "junk value"], environment: ["SHEP_LIVE_TARGET": "a.b"])
        XCTAssertNil(envOK.liveTarget)
        XCTAssertEqual(envOK.liveTargetInvalid, "--live-target is not a bundle id")
    }

    func testAValidBindingHasNoInvalidReason() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-request", "x", "--live-target", "org.m0k.transmission"], environment: [:])
        XCTAssertEqual(o.liveTarget, "org.m0k.transmission")
        XCTAssertNil(o.liveTargetInvalid)
    }

    func testWithoutALiveRequestTheTargetIsIgnoredWithALogLine() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--live-target", "org.m0k.transmission"], environment: [:])
        XCTAssertNil(o.liveTarget)
        XCTAssertEqual(o.liveTargetIgnoredLine, LiveLog.prefix + "ignored: --live-target needs --live-request")
        XCTAssertNil(o.liveTargetInvalid, "without --live-request the flag is ignored, not a refusal")
        let junk = LaunchOptions.parse(arguments: ["Shep", "--live-target", "bad value"], environment: [:])
        XCTAssertNil(junk.liveTargetInvalid)
        XCTAssertEqual(junk.liveTargetIgnoredLine, LiveLog.prefix + "ignored: --live-target needs --live-request")
    }

    func testBundleIdCharset() {
        XCTAssertTrue(LiveTargetGate.isBundleID("org.m0k.transmission"))
        XCTAssertTrue(LiveTargetGate.isBundleID("A-b_c.1"))
        XCTAssertFalse(LiveTargetGate.isBundleID(""))
        XCTAssertFalse(LiveTargetGate.isBundleID("a b"))
        XCTAssertFalse(LiveTargetGate.isBundleID("a/b"))
        XCTAssertFalse(LiveTargetGate.isBundleID(String(repeating: "a", count: 300)))
    }
}

final class LiveTargetDecisionTests: XCTestCase {
    let wanted = "org.m0k.transmission"
    let budget = LiveTargetGate.arrivalBudgetSeconds

    func decide(front: String?, running: Bool = true, elapsed: Double = 0) -> LiveTargetDecision {
        LiveTargetGate.decide(wanted: wanted, front: front, wantedRunning: running, elapsed: elapsed, budget: budget)
    }

    func testTheBudgetAndPollingAreWhatWasAsked() {
        XCTAssertEqual(LiveTargetGate.arrivalBudgetSeconds, 5.0)
        XCTAssertEqual(LiveTargetGate.pollSeconds, 0.25)
    }

    func testTheWantedAppInFrontProceeds() {
        XCTAssertEqual(decide(front: wanted), .proceed)
        XCTAssertEqual(decide(front: wanted, elapsed: 4.9), .proceed)
        XCTAssertEqual(decide(front: "ORG.M0K.Transmission"), .proceed, "bundle ids compare without case")
    }

    func testAnotherAppInFrontActivatesAndWaitsWithinTheBudget() {
        XCTAssertEqual(decide(front: "com.google.Chrome"), .activateAndWait)
        XCTAssertEqual(decide(front: "com.google.Chrome", elapsed: 4.75), .activateAndWait)
        XCTAssertEqual(decide(front: nil), .activateAndWait)
    }

    func testStillNotInFrontAfterTheBudgetRefusesAndNamesBundleIdsOnly() {
        XCTAssertEqual(decide(front: "com.google.Chrome", elapsed: budget),
                       .refuse("target: front app is com.google.Chrome not org.m0k.transmission"))
        XCTAssertEqual(decide(front: "com.google.Chrome", elapsed: 60),
                       .refuse("target: front app is com.google.Chrome not org.m0k.transmission"))
        XCTAssertEqual(decide(front: nil, elapsed: budget), .refuse("target: front app is (none) not org.m0k.transmission"))
    }

    func testAWantedAppThatIsNotRunningIsRefusedAtOnce() {
        XCTAssertEqual(decide(front: "com.google.Chrome", running: false), .refuse("target: org.m0k.transmission is not running"))
        XCTAssertEqual(decide(front: nil, running: false, elapsed: 3), .refuse("target: org.m0k.transmission is not running"))
    }

    func testAnAppOnTheNeverLookListIsRefusedBeforeAnythingElse() {
        for id in ["com.apple.mail", "com.apple.Terminal", "com.1password.1password", "com.tinyspeck.slackmacgap", "com.apple.systempreferences"] {
            let expected = LiveTargetDecision.refuse("target: \(id) is on the never-look list")
            XCTAssertEqual(LiveTargetGate.decide(wanted: id, front: id, wantedRunning: true, elapsed: 0, budget: budget), expected, id)
            XCTAssertEqual(LiveTargetGate.decide(wanted: id, front: "x.y", wantedRunning: false, elapsed: 0, budget: budget), expected, id)
        }
    }

    func testTheLastCheckNeverWaitsAndNeverReadsTheWrongApp() {
        XCTAssertEqual(LiveTargetGate.recheck(wanted: wanted, front: wanted, wantedRunning: true), .proceed)
        XCTAssertEqual(LiveTargetGate.recheck(wanted: wanted, front: "com.google.Chrome", wantedRunning: true),
                       .refuse("target: front app is com.google.Chrome not org.m0k.transmission"))
        XCTAssertEqual(LiveTargetGate.recheck(wanted: wanted, front: nil, wantedRunning: true),
                       .refuse("target: front app is (none) not org.m0k.transmission"))
        XCTAssertEqual(LiveTargetGate.recheck(wanted: wanted, front: wanted, wantedRunning: false), .refuse("target: org.m0k.transmission is not running"))
        XCTAssertEqual(LiveTargetGate.recheck(wanted: "com.apple.mail", front: "com.apple.mail", wantedRunning: true),
                       .refuse("target: com.apple.mail is on the never-look list"))
    }

    func testTheLogLinesAreOneLineAndCarryNoWindowTitles() {
        XCTAssertEqual(LiveLog.targetFront("com.google.Chrome"), "[shep] live: target: front app is com.google.Chrome")
        XCTAssertEqual(LiveLog.targetFront(nil), "[shep] live: target: front app is (none)")
        let line = LiveLog.reason("target: front app is com.google.Chrome not org.m0k.transmission")
        XCTAssertEqual(line, "[shep] live: reason: target: front app is com.google.Chrome not org.m0k.transmission")
        XCTAssertFalse(LiveTargetGate.overlayLine.isEmpty)
        XCTAssertFalse(LiveTargetGate.overlayLine.contains("\n"))
        XCTAssertLessThan(LiveTargetGate.overlayLine.count, 90)
    }

    func testARefusedTargetEndsTheRunWithThatReasonLine() {
        let why = "target: front app is com.google.Chrome not org.m0k.transmission"
        let line = LiveReason.reasonLine(outcome: .refused, failure: .targetRefused(why), result: nil, actionNote: nil)
        XCTAssertEqual(line, "[shep] live: reason: " + why)
    }
}

/// Nothing is captured or sent to a provider in a refused run: the pipeline itself refuses an input whose app is not the wanted one,
/// with zero analyze and zero pick calls.
final class LiveTargetPipelineTests: XCTestCase {
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let turtle = Control(index: 1, role: "AXButton", title: "Turtle speed limit", window: "Main", frame: CGRect(x: 200, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/1")

    func input(bundle: String) -> VisionInput {
        VisionInput(png: Data([1]), geometry: geometry, axControls: [turtle], bundleID: bundle, windowTitle: "Main", request: "turn on the speed limit (turtle)")
    }

    func testAnInputFromAnotherAppNeverReachesTheProviderOrThePicker() async {
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
        let picker = FakePicker(result: PickResult(marks: [1]))
        let pipeline = FixScreenPipeline(provider: provider, picker: picker, preparer: FakePreparer(result: nil), requiredBundleID: "org.m0k.transmission")
        for other in ["com.google.Chrome", "com.example.browser", "", "org.m0k.transmission.helper"] {
            let r = await pipeline.run(input(bundle: other))
            guard case .notAllowed(let why) = r.status else { return XCTFail("\(other): \(r.status)") }
            XCTAssertTrue(why.hasPrefix("target: front app is "), why)
            XCTAssertTrue(why.hasSuffix(" not org.m0k.transmission"), why)
            XCTAssertTrue(r.proposals.isEmpty)
        }
        XCTAssertTrue(provider.calls.isEmpty, "no screenshot or control list was handed to the provider")
        XCTAssertTrue(picker.jobs.isEmpty, "the picker was never asked")
    }

    func testTheWantedAppRunsAsBeforeAndTheCaseOfTheIdDoesNotMatter() async {
        for bundle in ["org.m0k.transmission", "ORG.M0K.Transmission"] {
            let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
            let pipeline = FixScreenPipeline(provider: provider, preparer: FakePreparer(result: nil), requiredBundleID: "org.m0k.transmission")
            let r = await pipeline.run(input(bundle: bundle))
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(provider.calls.count, 1)
        }
    }

    func testNoRequiredAppKeepsTheOldBehaviour() async {
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
        let r = await FixScreenPipeline(provider: provider, preparer: FakePreparer(result: nil)).run(input(bundle: "com.google.Chrome"))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(provider.calls.count, 1)
    }
}
