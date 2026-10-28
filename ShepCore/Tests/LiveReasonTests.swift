import CoreGraphics
import XCTest
@testable import ShepCore

/// Part B: a live run that ends nothing-to-offer, failed, refused (or any outcome but done, declined, cancelled) logs why:
/// `[shep] live: reason: <stage>: <cause>` right before the outcome line, plus a `ranked:` line when a request was made.
final class LiveReasonTests: XCTestCase {
    let box = CGRect(x: 10, y: 20, width: 30, height: 40)

    func okResult(_ trace: FixScreenTrace, explanation: String = "") -> FixScreenResult {
        FixScreenResult(status: .ok, provider: "fake", summary: "A window.", controls: [], proposals: [], notes: [], explanation: explanation, trace: trace)
    }

    func ranked(_ n: Int) -> [TraceRankedControl] {
        (1...n).map { TraceRankedControl(mark: $0, role: "AXButton", label: "Item \($0)", matchScore: Double($0) / 2, fromVision: $0 % 2 == 0) }
    }

    func body(_ line: String?) -> String? {
        guard let line = line else { return nil }
        let head = LiveLog.prefix + "reason: "
        XCTAssertTrue(line.hasPrefix(head), line)
        return String(line.dropFirst(head.count))
    }

    // MARK: which outcomes print a reason

    func testDoneDeclinedAndCancelledPrintNoReasonAndNoRankedLine() {
        let trace = FixScreenTrace(hadRequest: true, rankedCount: 3, ranked: ranked(3))
        for outcome in [LiveOutcome.done, .declined, .cancelled] {
            XCTAssertNil(LiveReason.text(outcome: outcome, failure: .readFailed, result: okResult(trace), actionNote: "x"), "\(outcome)")
            XCTAssertNil(LiveReason.reasonLine(outcome: outcome, failure: .readFailed, result: okResult(trace), actionNote: "x"), "\(outcome)")
            XCTAssertNil(LiveReason.rankedLine(outcome: outcome, trace: trace), "\(outcome)")
        }
    }

    func testEveryOtherOutcomeGetsAReasonLine() {
        for outcome in [LiveOutcome.refused, .failed, .nothingToOffer, .needsFreshApproval, .busy] {
            let line = LiveReason.reasonLine(outcome: outcome, failure: nil, result: nil, actionNote: nil)
            XCTAssertNotNil(line, "\(outcome) must say why, even when nothing more is known")
            XCTAssertFalse(body(line)?.isEmpty ?? true)
        }
    }

    // MARK: every stage yields a line that names the stage and the cause

    func testReadStage() {
        XCTAssertEqual(LiveReason.text(outcome: .failed, failure: .readFailed, result: nil, actionNote: nil),
                       "read: could not read the window's controls (no snapshot)")
    }

    func testCaptureStage() {
        XCTAssertEqual(LiveReason.text(outcome: .refused, failure: .captureNoPermission, result: nil, actionNote: nil),
                       "capture: no permission (Screen Recording is not allowed)")
        XCTAssertEqual(LiveReason.text(outcome: .failed, failure: .captureNoWindow, result: nil, actionNote: nil), "capture: no window")
        XCTAssertEqual(LiveReason.text(outcome: .failed, failure: .captureFailed, result: nil, actionNote: nil), "capture: capture failed")
    }

    func testProviderStage() {
        XCTAssertEqual(LiveReason.text(outcome: .failed, failure: .providerSetup("No model server is set up."), result: nil, actionNote: nil),
                       "provider: No model server is set up.")
        let failed = FixScreenResult(status: .failed("Couldn't reach the model server (down)."), provider: "fake", summary: "", controls: [], proposals: [], notes: [])
        XCTAssertEqual(LiveReason.text(outcome: .failed, failure: nil, result: failed, actionNote: nil), "provider: Couldn't reach the model server (down).")
    }

    func testPolicyStage() {
        let denied = FixScreenResult(status: .notAllowed("Shep never looks at this app's window."), provider: "fake", summary: "", controls: [], proposals: [], notes: [])
        XCTAssertEqual(LiveReason.text(outcome: .refused, failure: nil, result: denied, actionNote: nil), "policy: refused (Shep never looks at this app's window.)")
        for failure in [LiveFailure.accessibilityNotAllowed, .noOtherAppInFront, .appNeverLooked, .captureNotAllowed] {
            let text = LiveReason.text(outcome: .refused, failure: failure, result: nil, actionNote: nil) ?? ""
            XCTAssertTrue(text.hasPrefix("policy: refused ("), "\(failure): \(text)")
        }
        XCTAssertEqual(LiveReason.text(outcome: .refused, failure: nil, result: nil, actionNote: "Shep won't press \"Delete\"."),
                       "policy: refused (Shep won't press \"Delete\".)")
        let dropped = okResult(FixScreenTrace(hadRequest: true, rankedCount: 2, ranked: ranked(2), chosenCount: 2, droppedByPolicy: 2))
        XCTAssertEqual(LiveReason.text(outcome: .nothingToOffer, failure: nil, result: dropped, actionNote: nil),
                       "policy: refused (every control chosen is one Shep never presses)")
        let namerRefused = okResult(FixScreenTrace(hadRequest: true, namerTargetBox: box, namerMatched: true, namerRefused: true))
        XCTAssertEqual(LiveReason.text(outcome: .nothingToOffer, failure: nil, result: namerRefused, actionNote: nil),
                       "policy: refused (the control the model pointed at is one Shep never presses)")
    }

    func testNamerStage() {
        let none = okResult(FixScreenTrace(hadRequest: true, namerTargetBox: box, namerMatched: false))
        let text = LiveReason.text(outcome: .nothingToOffer, failure: nil, result: none, actionNote: nil) ?? ""
        XCTAssertTrue(text.hasPrefix("namer: pick did not match any listed control"), text)
        let two = okResult(FixScreenTrace(hadRequest: true, namerTargetBox: box, namerMatched: false, namerAmbiguous: true))
        XCTAssertTrue((LiveReason.text(outcome: .nothingToOffer, failure: nil, result: two, actionNote: nil) ?? "")
            .hasPrefix("namer: pick fit two controls equally well"))
    }

    func testPickerStage() {
        let nothing = okResult(FixScreenTrace(hadRequest: true, rankedCount: 4, ranked: ranked(4), pickerUsed: true, pickerMarks: [],
                                              pickerExplanation: "Nothing here sends mail."))
        XCTAssertEqual(LiveReason.text(outcome: .nothingToOffer, failure: nil, result: nothing, actionNote: nil),
                       "picker: model chose no control: \"Nothing here sends mail.\"")
        let broke = okResult(FixScreenTrace(hadRequest: true, rankedCount: 4, ranked: ranked(4), pickerUsed: false, pickerError: "The model server answered 500: boom"))
        let text = LiveReason.text(outcome: .nothingToOffer, failure: nil, result: broke, actionNote: nil) ?? ""
        XCTAssertTrue(text.hasPrefix("picker: failed (The model server answered 500: boom); ranking decided"), text)
    }

    func testRankingStage() {
        let words = okResult(FixScreenTrace(hadRequest: true, rankedCount: 3, ranked: ranked(3)))
        XCTAssertEqual(LiveReason.text(outcome: .nothingToOffer, failure: nil, result: words, actionNote: nil),
                       "ranking: no candidate matched the request words")
        let empty = okResult(FixScreenTrace(hadRequest: true, axCount: 4, foundCount: 1, rankedCount: 0))
        let text = LiveReason.text(outcome: .nothingToOffer, failure: nil, result: empty, actionNote: nil) ?? ""
        XCTAssertTrue(text.hasPrefix("ranking: no candidate controls"), text)
        XCTAssertTrue(text.contains("4") && text.contains("1"), "the counts are in it: \(text)")
        let noAsk = okResult(FixScreenTrace(hadRequest: false, rankedCount: 3, ranked: ranked(3)))
        XCTAssertEqual(LiveReason.text(outcome: .nothingToOffer, failure: nil, result: noAsk, actionNote: nil), "ranking: nothing worth offering")
    }

    func testActionStage() {
        XCTAssertEqual(LiveReason.text(outcome: .failed, failure: nil, result: okResult(FixScreenTrace()), actionNote: "The field didn't accept the text."),
                       "action: The field didn't accept the text.")
        XCTAssertEqual(LiveReason.text(outcome: .needsFreshApproval, failure: nil, result: okResult(FixScreenTrace()), actionNote: "The window moved or changed size."),
                       "action: target changed after approval (The window moved or changed size.)")
    }

    func testBusy() {
        XCTAssertEqual(LiveReason.text(outcome: .busy, failure: .busy, result: nil, actionNote: nil), "busy: a fix is already running")
    }

    // MARK: the line

    func testTheLineIsOneLineWithThePrefixAndAtMost240Characters() {
        let long = String(repeating: "word ", count: 200) + "\nsecond line\twith a tab"
        for outcome in [LiveOutcome.failed, .nothingToOffer, .refused] {
            let line = LiveReason.reasonLine(outcome: outcome, failure: .providerSetup(long), result: nil, actionNote: nil) ?? ""
            let text = body(line) ?? ""
            XCTAssertLessThanOrEqual(text.count, LiveReason.maxLength)
            XCTAssertEqual(LiveReason.maxLength, 240)
            XCTAssertFalse(line.contains("\n"))
            XCTAssertFalse(line.contains("\t"))
            XCTAssertTrue(text.hasSuffix("…"), "a cut text ends in an ellipsis")
        }
        let exact = LiveReason.clean(String(repeating: "z", count: 240))
        XCTAssertEqual(exact.count, 240)
        XCTAssertFalse(exact.hasSuffix("…"))
        XCTAssertEqual(LiveReason.clean(String(repeating: "z", count: 241)).count, 240)
    }

    func testEveryStageStaysWithinTheLimitWhateverTheModelSaid() {
        let huge = String(repeating: "x", count: 1000)
        let results: [FixScreenResult] = [
            okResult(FixScreenTrace(hadRequest: true, rankedCount: 4, ranked: ranked(4), pickerUsed: true, pickerExplanation: huge)),
            okResult(FixScreenTrace(hadRequest: true, rankedCount: 4, ranked: ranked(4), pickerError: huge)),
            FixScreenResult(status: .failed(huge), provider: "fake", summary: "", controls: [], proposals: [], notes: []),
            FixScreenResult(status: .notAllowed(huge), provider: "fake", summary: "", controls: [], proposals: [], notes: []),
        ]
        for r in results {
            let text = LiveReason.text(outcome: .nothingToOffer, failure: nil, result: r, actionNote: nil) ?? ""
            XCTAssertLessThanOrEqual(text.count, 240, text)
        }
        XCTAssertLessThanOrEqual((LiveReason.text(outcome: .failed, failure: nil, result: nil, actionNote: huge) ?? "").count, 240)
    }

    func testScrubIsAppliedBeforeTheCut() {
        let key = "sk-abcdefghijklmnop1234567890"
        let a = LiveReason.reasonLine(outcome: .failed, failure: .providerSetup("auth failed with \(key)"), result: nil, actionNote: nil) ?? ""
        XCTAssertFalse(a.contains("abcdefghijkl"), a)
        XCTAssertTrue(a.contains(Redact.mask), a)
        // A secret that straddles the cut would survive scrubbing after the cut; here it is masked first.
        let padding = String(repeating: "x", count: 225)
        let b = LiveReason.reasonLine(outcome: .failed, failure: .providerSetup("provider: \(padding) Bearer abcdefghijklmnopqrstuvwxyz"), result: nil, actionNote: nil) ?? ""
        XCTAssertFalse(b.contains("abcdefgh"), b)
        Redact.register("a-registered-secret-value")
        let c = LiveReason.reasonLine(outcome: .failed, failure: nil, result: nil, actionNote: "failed with a-registered-secret-value inside") ?? ""
        XCTAssertFalse(c.contains("a-registered-secret-value"), c)
    }

    func testLiveLogReasonFormat() {
        XCTAssertEqual(LiveLog.reason("read: could not read"), "[shep] live: reason: read: could not read")
    }

    // MARK: the ranked line

    func testRankedLineShowsTheTopFiveInTheDocumentedFormat() {
        let trace = FixScreenTrace(hadRequest: true, rankedCount: 8, ranked: ranked(8))
        let line = LiveReason.rankedLine(outcome: .nothingToOffer, trace: trace) ?? ""
        XCTAssertEqual(line, "[shep] live: ranked: #1 AXButton \"Item 1\" score=0.50; #2 AXButton \"Item 2\" score=1.00; #3 AXButton \"Item 3\" score=1.50; "
            + "#4 AXButton \"Item 4\" score=2.00; #5 AXButton \"Item 5\" score=2.50")
        XCTAssertFalse(line.contains("#6"))
    }

    func testRankedLineNeedsARequestAndSaysNoneWhenNothingWasRanked() {
        XCTAssertNil(LiveReason.rankedLine(outcome: .nothingToOffer, trace: FixScreenTrace(hadRequest: false, rankedCount: 3, ranked: ranked(3))))
        XCTAssertEqual(LiveReason.rankedLine(outcome: .failed, trace: FixScreenTrace(hadRequest: true)), "[shep] live: ranked: none")
        for outcome in [LiveOutcome.refused, .failed, .nothingToOffer, .needsFreshApproval, .busy] {
            XCTAssertNotNil(LiveReason.rankedLine(outcome: outcome, trace: FixScreenTrace(hadRequest: true, ranked: ranked(1))), "\(outcome)")
        }
    }

    func testRankedLineIsScrubbedAndOneLine() {
        let nasty = TraceRankedControl(mark: 1, role: "AXButton", label: "Token\nsk-abcdefghijklmnop1234567890 now", matchScore: 1, fromVision: false)
        let line = LiveReason.rankedLine(outcome: .failed, trace: FixScreenTrace(hadRequest: true, ranked: [nasty])) ?? ""
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("abcdefghijkl"), line)
    }

    func testRankedLabelsAreCappedAt60() {
        let c = TraceRankedControl(mark: 1, role: "AXButton", label: String(repeating: "L", count: 100), matchScore: 0, fromVision: false)
        XCTAssertLessThanOrEqual(c.label.count, 60)
        XCTAssertEqual(TraceRankedControl.labelLimit, 60)
        XCTAssertEqual(TraceRankedControl(mark: 1, role: "AXButton", label: "  Save \n file  ", matchScore: 0, fromVision: false).label, "Save file")
    }
}

/// What the pipeline records for the log and the debug dump.
final class FixScreenTraceTests: XCTestCase {
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)

    func button(_ i: Int, _ title: String) -> Control {
        Control(index: i, role: "AXButton", title: title, window: "Inbox",
                frame: CGRect(x: 110 + CGFloat(i) * 20, y: 100, width: 18, height: 18), actions: ["AXPress"], pathID: "0/\(i)")
    }

    func input(_ controls: [Control], request: String?) -> VisionInput {
        VisionInput(png: Data([1]), geometry: geometry, axControls: controls, bundleID: "com.example.chat", windowTitle: "Inbox", request: request)
    }

    func pipeline(_ analysis: ScreenAnalysis, picker: (any ProposalPicking)? = nil) -> FixScreenPipeline {
        FixScreenPipeline(provider: FakeProvider(analysis: analysis), picker: picker, preparer: FakePreparer(result: nil))
    }

    let empty = ScreenAnalysis(summary: "A chat window.", controls: [])

    func testTheOldInitialiserMeansAnEmptyTrace() {
        let r = FixScreenResult(status: .ok, provider: "fake", summary: "s", controls: [], proposals: [], notes: [])
        XCTAssertEqual(r.trace, FixScreenTrace())
        XCTAssertTrue(r.trace.ranked.isEmpty)
        XCTAssertFalse(r.trace.hadRequest)
    }

    func testCountsAndTheRankedListAreRecordedAndCappedAtEight() async {
        let controls = (1...12).map { button($0, "Item \($0)") }
        let r = await pipeline(empty).run(input(controls, request: "item"))
        XCTAssertTrue(r.trace.hadRequest)
        XCTAssertEqual(r.trace.axCount, 12)
        XCTAssertEqual(r.trace.foundCount, 0)
        XCTAssertGreaterThan(r.trace.rankedCount, 8)
        XCTAssertEqual(r.trace.ranked.count, FixScreenTrace.rankedLimit)
        XCTAssertEqual(FixScreenTrace.rankedLimit, 8)
        XCTAssertEqual(r.trace.ranked.map(\.mark), Array(1...8), "marks are the positions the picker is shown")
        XCTAssertTrue(r.trace.ranked.allSatisfy { $0.role == "AXButton" && !$0.fromVision && $0.matchScore > 0 })
    }

    func testTheNamersPickIsRecordedWhetherOrNotItMatched() async {
        // 800x600 px image over a 400x300 pt window at (100, 50): pixel (x, y) is screen (100 + x/2, 50 + y/2).
        // button 1 sits at screen (130, 100, 18, 18) = pixels (60, 100, 36, 36).
        let controls = [button(1, "Send")]
        let hit = CGRect(x: 60, y: 100, width: 36, height: 36)
        let matched = await pipeline(ScreenAnalysis(summary: "s", controls: [], targetBox: hit)).run(input(controls, request: "send it"))
        XCTAssertEqual(matched.trace.namerTargetBox, hit)
        XCTAssertTrue(matched.trace.namerMatched)
        XCTAssertEqual(matched.proposals.count, 1)

        let missBox = CGRect(x: 700, y: 500, width: 40, height: 40)
        let missed = await pipeline(ScreenAnalysis(summary: "s", controls: [], targetBox: missBox)).run(input(controls, request: "send it"))
        XCTAssertEqual(missed.trace.namerTargetBox, missBox)
        XCTAssertFalse(missed.trace.namerMatched)

        let none = await pipeline(empty).run(input(controls, request: "send it"))
        XCTAssertNil(none.trace.namerTargetBox)
    }

    func testThePickersMarksExplanationAndErrorAreRecorded() async {
        let controls = [button(1, "Send"), button(2, "Attach file")]
        let chose = await pipeline(empty, picker: FakePicker(result: PickResult(marks: [2], explanation: "")))
            .run(input(controls, request: "attach a file"))
        XCTAssertTrue(chose.trace.pickerUsed)
        XCTAssertEqual(chose.trace.pickerMarks, [2])
        XCTAssertEqual(chose.trace.chosenCount, 1)

        let nothing = await pipeline(empty, picker: FakePicker(result: PickResult(marks: [], explanation: "Nothing here sends mail.")))
            .run(input(controls, request: "email my boss"))
        XCTAssertTrue(nothing.trace.pickerUsed)
        XCTAssertEqual(nothing.trace.pickerMarks, [])
        XCTAssertEqual(nothing.trace.pickerExplanation, "Nothing here sends mail.")
        XCTAssertTrue(nothing.proposals.isEmpty)

        let broke = await pipeline(empty, picker: FakePicker(error: .unreachable("down")))
            .run(input(controls, request: "attach a file"))
        XCTAssertFalse(broke.trace.pickerUsed)
        XCTAssertNotNil(broke.trace.pickerError)
        XCTAssertTrue(broke.trace.pickerError?.contains("down") ?? false)
    }

    func testTheEarlyRefusalsKeepTheCountsAndNothingElse() async {
        let blocked = VisionInput(png: Data([1]), geometry: geometry, axControls: [button(1, "Send")], bundleID: "com.apple.keychainaccess",
                                  windowTitle: "Keychain", request: "send")
        let r = await pipeline(empty).run(blocked)
        guard case .notAllowed = r.status else { return XCTFail("\(r.status)") }
        XCTAssertEqual(r.trace.axCount, 1)
        XCTAssertTrue(r.trace.ranked.isEmpty)
    }

    func testTheResultOfARealRunFeedsTheReason() async {
        let controls = [button(1, "Send"), button(2, "Attach file")]
        let r = await pipeline(empty, picker: FakePicker(result: PickResult(marks: [], explanation: "Nothing here sends mail.")))
            .run(input(controls, request: "email my boss"))
        let text = LiveReason.text(outcome: .nothingToOffer, failure: nil, result: r, actionNote: nil) ?? ""
        XCTAssertEqual(text, "picker: model chose no control: \"Nothing here sends mail.\"")
        let line = LiveReason.rankedLine(outcome: .nothingToOffer, trace: r.trace) ?? ""
        XCTAssertTrue(line.hasPrefix("[shep] live: ranked: #1 "), line)
    }
}
