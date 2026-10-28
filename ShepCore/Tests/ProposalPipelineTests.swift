import CoreGraphics
import XCTest
@testable import ShepCore

final class ProposalPipelineTests: XCTestCase {
    /// A 400x300 pt window at (100, 50) captured on Retina: 800x600 px (screen = (100 + px/2, 50 + px/2)).
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let sendAX = Control(index: 1, role: "AXButton", title: "Send", window: "Inbox", frame: CGRect(x: 200, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/1")
    let closeAX = Control(index: 2, role: "AXButton", subrole: "AXCloseButton", title: "Close", window: "Inbox", frame: CGRect(x: 110, y: 52, width: 14, height: 14), actions: ["AXPress"], pathID: "0/2")

    func input(request: String? = nil) -> VisionInput {
        VisionInput(png: Data([1]), geometry: geometry, axControls: [sendAX, closeAX], bundleID: "com.example.chat", windowTitle: "Inbox", request: request)
    }

    /// Found on the screenshot: Settings (top right), Attach file (left), Mute (middle). Reading order: Settings, Attach file, Mute.
    func analysis() -> ScreenAnalysis {
        ScreenAnalysis(summary: "A chat window.", controls: [
            LocatedControl(name: "Settings", role: "button", box: CGRect(x: 600, y: 100, width: 60, height: 60)),
            LocatedControl(name: "Attach file", role: "button", box: CGRect(x: 200, y: 400, width: 60, height: 60)),
            LocatedControl(name: "Mute", role: "button", box: CGRect(x: 400, y: 500, width: 60, height: 60)),
        ])
    }

    func pipeline(picker: (any ProposalPicking)?) -> FixScreenPipeline {
        FixScreenPipeline(provider: FakeProvider(analysis: analysis()), picker: picker, preparer: FakePreparer(result: nil))
    }

    // Ranking with the three found controls plus the AX Send button (the AX Close button is window chrome):
    //   no request:       Send 6.5, then Settings, Attach file, Mute at 4.5 each      -> marks 1 Send, 2 Settings, 3 Attach file, 4 Mute
    //   "attach a file":  Attach file 3 + 20 + 1.5 = 24.5, Send 6.5, Settings, Mute  -> marks 1 Attach file, 2 Send, 3 Settings, 4 Mute

    func testThePickerSeesTheTopCandidatesByMarkAndWindowChromeIsNotAmongThem() async {
        let picker = FakePicker(result: PickResult(marks: [1]))
        _ = await pipeline(picker: picker).run(input(request: "attach a file"))
        let job = picker.jobs.first
        XCTAssertEqual(job?.candidates.map(\.mark), [1, 2, 3, 4])
        XCTAssertEqual(job?.candidates.map { $0.control.label }, ["Attach file", "Send", "Settings", "Mute"])
        XCTAssertEqual(job?.request, "attach a file")
        XCTAssertEqual(job?.windowTitle, "Inbox")
        XCTAssertEqual(job?.maxPicks, 3)
    }

    func testTheMarkTheModelPicksBecomesTheProposal() async {
        let r = await pipeline(picker: FakePicker(result: PickResult(marks: [1]))).run(input(request: "attach a file"))
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Attach file"])
        guard case .required? = r.proposals.first?.requirement else { return XCTFail("a proposal always asks") }
        XCTAssertTrue(r.explanation.isEmpty)
    }

    func testMarksOutOfRangeRepeatedOrBeyondThreeAreIgnored() async {
        let r = await pipeline(picker: FakePicker(result: PickResult(marks: [3, 9, 3, 2, 1, 4]))).run(input(request: "attach a file"))
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Settings", "Send", "Attach file"], "unknown 9 and the repeat of 3 dropped, at most three kept")
    }

    func testWithoutARequestTheModelIsAskedForOneNextStep() async {
        let picker = FakePicker(result: PickResult(marks: [2, 3, 4]))
        let r = await pipeline(picker: picker).run(input())
        XCTAssertNil(picker.jobs.first?.request)
        XCTAssertEqual(picker.jobs.first?.maxPicks, 1)
        XCTAssertEqual(picker.jobs.first?.candidates.map { $0.control.label }, ["Send", "Settings", "Attach file", "Mute"])
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Settings"], "one step, even if the model sent three")
    }

    func testNothingFitsGivesNoProposalsAndTheModelsExplanation() async {
        let r = await pipeline(picker: FakePicker(result: PickResult(marks: [], explanation: "Nothing here sends mail."))).run(input(request: "email my boss"))
        XCTAssertTrue(r.proposals.isEmpty)
        XCTAssertEqual(r.explanation, "Nothing here sends mail.")
        let silent = await pipeline(picker: FakePicker(result: PickResult(marks: []))).run(input(request: "email my boss"))
        XCTAssertEqual(silent.explanation, "None of the controls does that.")
        let none = await pipeline(picker: FakePicker(result: PickResult(marks: []))).run(input())
        XCTAssertEqual(none.explanation, "I didn't see a clear next step.")
    }

    func testAFailingModelFallsBackToTheRanking() async {
        let withRequest = await pipeline(picker: FakePicker(error: .unreachable("down"))).run(input(request: "attach a file"))
        XCTAssertEqual(withRequest.proposals.map { $0.action.control.label }, ["Attach file"], "only controls whose words match the request")
        XCTAssertTrue(withRequest.notes.contains { $0.contains("picking failed") })
        let noRequest = await pipeline(picker: FakePicker(error: .unreachable("down"))).run(input())
        XCTAssertEqual(noRequest.proposals.map { $0.action.control.label }, ["Settings", "Attach file", "Mute"], "the controls found on the screenshot, best first")
    }

    func testNoModelAndNoMatchExplains() async {
        let r = await pipeline(picker: nil).run(input(request: "play music"))
        XCTAssertTrue(r.proposals.isEmpty)
        XCTAssertTrue(r.explanation.contains("play music"), r.explanation)
    }

    func testNeverProposesCloseUnlessAskedFor() async {
        let plain = await pipeline(picker: nil).run(input())
        XCTAssertFalse(plain.proposals.contains { $0.action.control.label == "Close" })
        let asked = await pipeline(picker: nil).run(input(request: "close this window"))
        XCTAssertEqual(asked.proposals.first?.action.control.label, "Close")
        XCTAssertEqual(asked.proposals.first?.action.kind, .axPress)
    }

    func testNoMoreThanThreeProposalsEver() async {
        let many = (0..<12).map { LocatedControl(name: "Tool \($0)", role: "button", box: CGRect(x: Double($0 % 4) * 180 + 20, y: Double($0 / 4) * 150 + 20, width: 60, height: 60)) }
        let r = await FixScreenPipeline(provider: FakeProvider(analysis: ScreenAnalysis(summary: "", controls: many)),
                                        picker: FakePicker(result: PickResult(marks: [1, 2, 3, 4, 5, 6])), preparer: FakePreparer(result: nil)).run(input(request: "tool"))
        XCTAssertLessThanOrEqual(r.proposals.count, 3)
        XCTAssertEqual(FixScreenPipeline.maxProposals, 3)
    }

    func testTheReportSaysWhyThereAreNoProposals() {
        let r = FixScreenResult(status: .ok, provider: "fake", summary: "s", controls: [], proposals: [], notes: [], explanation: "Nothing fits.")
        XCTAssertTrue(FixScreenReport.render(r, seconds: 1).contains("none: Nothing fits."))
    }
}

final class GlimmerPickingTests: XCTestCase {
    let ctl = { (i: Int, t: String) in Control(index: i, role: "AXButton", title: t, frame: CGRect(x: 10, y: 10, width: 30, height: 20), actions: ["AXPress"], pathID: "0/\(i)") }
    func job(request: String?) -> PickJob {
        PickJob(image: nil, candidates: [PickCandidate(mark: 1, control: ctl(1, "Send")), PickCandidate(mark: 2, control: ctl(2, "Gear"))], request: request, windowTitle: "Inbox")
    }

    func testParseKeepsListedMarksInOrder() {
        let p = GlimmerPicking.parse(text: "```json\n{\"picks\": [2, 1], \"reason\": \"The gear opens settings.\"}\n```", job: job(request: "settings"))
        XCTAssertEqual(p.result?.marks, [2, 1])
        XCTAssertEqual(p.result?.explanation, "The gear opens settings.")
        XCTAssertTrue(p.problems.isEmpty)
        XCTAssertEqual(GlimmerPicking.parse(text: #"{"picks":[2.0],"reason":""}"#, job: job(request: "x")).result?.marks, [2])
    }

    func testAnyMalformedPickRejectsTheWholeAnswer() {
        for picks in ["[2, 7, 1]", "[2, 2]", "[true]", "[1, true]", "[\"1\"]", "[1.5]", "[0]", "[-1]", "[null]", "[[1]]", "[1e400]", "[2, \"bad\", 1]", "[9999999999999999999]"] {
            let p = GlimmerPicking.parse(text: "{\"picks\": \(picks), \"reason\": \"x\"}", job: job(request: "x"))
            XCTAssertNil(p.result, "\(picks) must not become a different pick")
            XCTAssertFalse(p.problems.isEmpty, picks)
        }
    }

    func testWithoutARequestOnlyOneMarkSurvives() {
        let p = GlimmerPicking.parse(text: #"{"picks":[1,2],"reason":"x"}"#, job: job(request: nil))
        XCTAssertEqual(p.result?.marks, [1])
    }

    func testEmptyPicksIsAValidAnswer() {
        let p = GlimmerPicking.parse(text: #"{"picks":[],"reason":"Nothing fits."}"#, job: job(request: "x"))
        XCTAssertEqual(p.result, PickResult(marks: [], explanation: "Nothing fits."))
    }

    func testUnusableAnswersAreRejected() {
        for text in ["", "no", "{}", #"{"picks":"1"}"#] {
            let p = GlimmerPicking.parse(text: text, job: job(request: "x"))
            XCTAssertNil(p.result, text)
            XCTAssertFalse(p.problems.isEmpty, text)
        }
    }

    func testRequestIsSchemaConstrainedLocalAndThinkingOff() throws {
        let r = try GlimmerPicking.body(job(request: "open settings"), config: GlimmerConfig(), useSchema: true, problem: nil)
        XCTAssertEqual(r.url.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertNil(r.headers["Authorization"])
        XCTAssertTrue(r.localOnly)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertEqual(obj["reasoning_strength"] as? String, "none")
        XCTAssertEqual(obj["max_tokens"] as? Int, 400)
        let format = try XCTUnwrap(obj["response_format"] as? [String: Any])
        let schema = try XCTUnwrap((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["picks", "reason"])
        let content = try XCTUnwrap(((obj["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(content.count, 1, "no image part when there is no image")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("open settings"))
        XCTAssertTrue(text.contains("1: button \"Send\" (listed by the app)"), text)
        XCTAssertTrue(text.contains("Never pick anything that closes, quits, deletes or pays"))
        let noRequest = GlimmerPicking.prompt(job(request: nil), problem: "bad")
        XCTAssertTrue(noRequest.contains("Pick exactly ONE mark number"))
        XCTAssertTrue(noRequest.contains("previous answer was rejected: bad"))
    }

    struct StubTransport: MetaTransport {
        var responses: [MetaHTTPResponse]
        func send(_ request: MetaHTTPRequest) async throws -> MetaHTTPResponse { responses[0] }
    }

    func testPickerWithAStubServer() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": #"{"picks":[2],"reason":"gear"}"#]]]])
        let picker = GlimmerPicker(transport: StubTransport(responses: [MetaHTTPResponse(status: 200, body: body)]))
        let r = try await picker.pick(job(request: "settings"))
        XCTAssertEqual(r.marks, [2])
    }

    func testPickerRefusesANonLocalServer() async {
        var config = GlimmerConfig()
        config.baseURL = URL(string: "http://example.com/v1")!
        do { _ = try await GlimmerPicker(config: config, transport: StubTransport(responses: [])).pick(job(request: "x")); XCTFail("must throw") }
        catch { XCTAssertTrue(error is ProviderError) }
    }

    func testFactoryGivesGlimmerAPickerAndTheCloudNone() {
        let local = ProviderConfig.from(environment: [:], home: "/Users/x")
        XCTAssertNotNil(ProviderFactory.makePicker(config: local, environment: [:]))
        let fake = ProviderConfig.from(environment: ["SHEP_PROVIDER": "fake"], home: "/Users/x")
        XCTAssertNil(ProviderFactory.makePicker(config: fake, environment: ["SHEP_PROVIDER": "fake"]))
        let meta = ProviderConfig.from(environment: ["SHEP_PROVIDER": "meta", "MODEL_API_KEY": "k"], home: "/Users/x")
        XCTAssertNil(ProviderFactory.makePicker(config: meta, environment: ["SHEP_PROVIDER": "meta", "MODEL_API_KEY": "k"]))
    }
}
