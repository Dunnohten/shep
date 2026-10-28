import CoreGraphics
import XCTest
@testable import ShepCore

/// A near-miss inside the right app: the picker says "none" (or fails), but the ranking has exactly one control whose label shares
/// at least two of the request's words and clearly beats every other. That one control is offered (still with an approval card).
final class StrongMatchTests: XCTestCase {
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let request = "turn on the speed limit (turtle)"

    func button(_ index: Int, _ title: String, x: Double) -> Control {
        Control(index: index, role: "AXButton", title: title, window: "Main", frame: CGRect(x: x, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/\(index)")
    }

    func run(_ controls: [Control], picker: FakePicker, request: String?) async -> FixScreenResult {
        let input = VisionInput(png: Data([1]), geometry: geometry, axControls: controls, bundleID: "org.m0k.transmission", windowTitle: "Main", request: request)
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "A window.", controls: []))
        return await FixScreenPipeline(provider: provider, picker: picker, preparer: FakePreparer(result: nil)).run(input)
    }

    let none = PickResult(marks: [], explanation: "The controls listed are browser UI elements.")

    func testTheConstantsAreDocumentedValues() {
        XCTAssertEqual(ProposalRanker.strongMatchScore, 20.0)
        XCTAssertEqual(ProposalRanker.strongMatchGap, 0.15)
        XCTAssertEqual(ProposalRanker.strongMatchMinWords, 2)
        XCTAssertEqual(FixScreenTrace.strongMatchAfterNone, "picker: model chose no control; ranking's one strong match offered")
    }

    func testAUniqueStrongMatchIsOfferedWhenThePickerChoosesNothing() async {
        let controls = [button(1, "Settings", x: 120), button(2, "Turtle speed limit", x: 200), button(3, "Add", x: 300)]
        let r = await run(controls, picker: FakePicker(result: none), request: request)
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Turtle speed limit"])
        guard case .required = r.proposals[0].requirement else { return XCTFail("it still needs approval") }
        XCTAssertEqual(r.trace.strongMatchOffer, FixScreenTrace.strongMatchAfterNone)
        XCTAssertTrue(r.explanation.isEmpty)
    }

    func testAUniqueStrongMatchIsOfferedWhenThePickerFails() async {
        let controls = [button(1, "Settings", x: 120), button(2, "Turtle speed limit", x: 200)]
        let r = await run(controls, picker: FakePicker(error: .unreachable("down")), request: request)
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Turtle speed limit"])
        XCTAssertEqual(r.trace.strongMatchOffer, FixScreenTrace.strongMatchAfterFailure)
    }

    func testTheOfferShowsInTheLiveReasonAndTheDebugTrace() async {
        let r = await run([button(1, "Turtle speed limit", x: 200)], picker: FakePicker(result: none), request: request)
        XCTAssertEqual(LiveReason.offerLine(trace: r.trace), LiveLog.reason(FixScreenTrace.strongMatchAfterNone))
        XCTAssertTrue(LiveDebug.traceText(r).contains(FixScreenTrace.strongMatchAfterNone))
        XCTAssertNil(LiveReason.offerLine(trace: FixScreenTrace()))
    }

    func testTwoNearEqualMatchesOfferNothing() async {
        let controls = [button(1, "Turtle speed limit", x: 200), button(2, "Speed limit turtle", x: 300)]
        let r = await run(controls, picker: FakePicker(result: none), request: request)
        XCTAssertTrue(r.proposals.isEmpty)
        XCTAssertNil(r.trace.strongMatchOffer)
        XCTAssertFalse(r.explanation.isEmpty)
    }

    func testAWeakOrSingleWordMatchOffersNothing() async {
        for title in ["Speed", "Limit", "Turtle"] {
            let r = await run([button(1, "Settings", x: 120), button(2, title, x: 200)], picker: FakePicker(result: none), request: request)
            XCTAssertTrue(r.proposals.isEmpty, title)
            XCTAssertNil(r.trace.strongMatchOffer, title)
        }
    }

    func testAStrongMatchBesideAWeakOneStillCountsAsUnique() async {
        let controls = [button(1, "Speed", x: 120), button(2, "Turtle speed limit", x: 200)]
        let r = await run(controls, picker: FakePicker(result: none), request: request)
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Turtle speed limit"])
    }

    func testAControlPolicyRefusesIsNeverOfferedThisWay() async {
        let controls = [button(1, "Delete turtle speed limit", x: 200), button(2, "Settings", x: 120)]
        let r = await run(controls, picker: FakePicker(result: none), request: request)
        XCTAssertTrue(r.proposals.isEmpty)
        XCTAssertNil(r.trace.strongMatchOffer)
        XCTAssertFalse(r.proposals.contains { $0.action.control.label.contains("Delete") })
    }

    func testAPasswordFieldIsNeverOfferedThisWay() async {
        let secure = Control(index: 1, role: "AXTextField", subrole: "AXSecureTextField", title: "Turtle speed limit", window: "Main",
                             frame: CGRect(x: 200, y: 100, width: 80, height: 20), actions: ["AXPress"], pathID: "0/1")
        let r = await run([secure], picker: FakePicker(result: none), request: request)
        XCTAssertTrue(r.proposals.isEmpty)
    }

    func testWithNoRequestNothingIsOfferedThisWay() async {
        let controls = [button(1, "Turtle speed limit", x: 200)]
        for text in [nil, "", "   "] as [String?] {
            let r = await run(controls, picker: FakePicker(result: none), request: text)
            XCTAssertTrue(r.proposals.isEmpty, "\(String(describing: text))")
            XCTAssertNil(r.trace.strongMatchOffer)
        }
    }

    func testWhenThePickerChoseSomethingNothingChanges() async {
        let controls = [button(1, "Turtle speed limit", x: 200), button(2, "Settings", x: 120)]
        let picker = FakePicker(result: PickResult(marks: [2]))
        let r = await run(controls, picker: picker, request: request)
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Settings"])
        XCTAssertNil(r.trace.strongMatchOffer)
    }

    func testUniqueStrongMatchDirectly() {
        func ranked(_ title: String, match: Double) -> RankedControl {
            RankedControl(control: button(1, title, x: 200), score: 30, matchScore: match)
        }
        let strong = ranked("Turtle speed limit", match: 30)
        XCTAssertEqual(ProposalRanker.uniqueStrongMatch(in: [strong, ranked("Add", match: 0)], request: request)?.label, "Turtle speed limit")
        XCTAssertNil(ProposalRanker.uniqueStrongMatch(in: [strong, ranked("Speed limit turtle", match: 30)], request: request))
        XCTAssertNil(ProposalRanker.uniqueStrongMatch(in: [strong, ranked("Speed limit turtle", match: 29.9)], request: request), "within 0.15 of it")
        XCTAssertNil(ProposalRanker.uniqueStrongMatch(in: [ranked("Turtle speed limit", match: 19.99)], request: request), "below the score")
        XCTAssertNil(ProposalRanker.uniqueStrongMatch(in: [], request: request))
        XCTAssertNil(ProposalRanker.uniqueStrongMatch(in: [strong], request: "  "))
    }
}
