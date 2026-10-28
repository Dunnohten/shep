import CoreGraphics
import XCTest
@testable import ShepCore

final class FixScreenPipelineTests: XCTestCase {
    /// A 400x300 pt window at (100, 50) captured on Retina: 800x600 px.
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let sendAX = Control(index: 1, role: "AXButton", title: "Send", window: "Inbox", frame: CGRect(x: 200, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/1")

    func input(ax: [Control]? = nil, bundle: String = "com.example.chat") -> VisionInput {
        VisionInput(png: Data([1]), geometry: geometry, axControls: ax ?? [sendAX], bundleID: bundle, windowTitle: "Inbox")
    }

    func testEndToEndWithFakeProvider() async {
        let analysis = ScreenAnalysis(summary: "A chat window.", controls: [
            LocatedControl(name: "Settings", role: "button", box: CGRect(x: 600, y: 100, width: 60, height: 60)),   // new
            LocatedControl(name: "Send", role: "button", box: CGRect(x: 204, y: 102, width: 80, height: 40)),       // the AX Send button
            LocatedControl(name: "Buy now", role: "button", box: CGRect(x: 100, y: 400, width: 60, height: 60)),    // refused by policy
            LocatedControl(name: "Attach file", role: "button", box: CGRect(x: 200, y: 400, width: 60, height: 60)),
        ])
        let fake = FakeProvider(analysis: analysis)
        let result = await FixScreenPipeline(provider: fake).run(input())

        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.provider, "fake")
        XCTAssertEqual(result.summary, "A chat window.")
        XCTAssertEqual(result.controls.map(\.label), ["Send", "Settings", "Attach file"])
        XCTAssertEqual(result.controls.map(\.index), [1, 2, 3])
        XCTAssertEqual(result.foundCount, 2)
        XCTAssertTrue(result.notes.contains { $0.contains("left out 1") })
        // Found controls sit at screen points: window origin + pixels / 2.
        XCTAssertEqual(result.controls[1].frame, CGRect(x: 400, y: 100, width: 30, height: 30))

        XCTAssertEqual(result.proposals.count, 2)
        for p in result.proposals {
            XCTAssertEqual(p.action.kind, .clickPoint)
            guard case .required = p.requirement else { return XCTFail("every proposal must ask") }
            XCTAssertTrue(p.action.control.fromVision)
        }
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].axControls.map(\.label), ["Send"], "the provider sees the prepared AX list")
    }

    func testAllProposalsAreApprovalGatedThroughTheRunner() async {
        let fake = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: [LocatedControl(name: "Gear", role: "button", box: CGRect(x: 600, y: 100, width: 60, height: 60))]))
        let result = await FixScreenPipeline(provider: fake).run(input())
        let action = try! XCTUnwrap(result.proposals.first).action
        let exec = ActionRunnerTests.FakeExecutor()
        let declined = await ActionRunner(executor: exec, approve: { _ in false }).run(action)
        XCTAssertEqual(declined, .declined)
        XCTAssertEqual(exec.clickCalls, 0)
        let done = await ActionRunner(executor: exec, approve: { _ in true }).run(action)
        guard case .done = done else { return XCTFail("\(done)") }
        XCTAssertEqual(exec.clickCalls, 1)
    }

    func testProviderFailureKeepsTheAXListAndProposesNothing() async {
        let r = await FixScreenPipeline(provider: FakeProvider(error: .unreachable("down"))).run(input())
        guard case .failed(let why) = r.status else { return XCTFail("\(r.status)") }
        XCTAssertTrue(why.contains("Couldn't reach"))
        XCTAssertEqual(r.controls.map(\.label), ["Send"])
        XCTAssertTrue(r.proposals.isEmpty)
    }

    func testSensitiveAppsAreNeverSentToAnyProvider() async {
        let fake = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
        for bundle in ["com.tinyspeck.slackmacgap", "com.apple.Terminal", "com.1password.1password", ""] {
            let r = await FixScreenPipeline(provider: fake).run(input(bundle: bundle))
            guard case .notAllowed = r.status else { return XCTFail("\(bundle): \(r.status)") }
        }
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testCloudProvidersNeedTheOptInLocalOnesDoNot() async {
        let cloud = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []), sendsOffDevice: true)
        let off = await FixScreenPipeline(provider: cloud, cloudAllowed: { false }).run(input())
        guard case .notAllowed = off.status else { return XCTFail("\(off.status)") }
        XCTAssertTrue(cloud.calls.isEmpty)
        let on = await FixScreenPipeline(provider: cloud, cloudAllowed: { true }).run(input())
        XCTAssertEqual(on.status, .ok)
        XCTAssertEqual(cloud.calls.count, 1)
        let local = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
        let l = await FixScreenPipeline(provider: local).run(input())
        XCTAssertEqual(l.status, .ok)
    }

    func testProposalsAreCapped() async {
        let many = (0..<20).map { LocatedControl(name: "C\($0)", role: "button", box: CGRect(x: Double($0 % 5) * 150, y: Double($0 / 5) * 120, width: 60, height: 60)) }
        let r = await FixScreenPipeline(provider: FakeProvider(analysis: ScreenAnalysis(summary: "", controls: many))).run(input(ax: []))
        XCTAssertEqual(r.proposals.count, FixScreenPipeline.maxProposals)
    }

    func testEmptySummaryFallsBackToTheCounts() async {
        let r = await FixScreenPipeline(provider: FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))).run(input())
        XCTAssertEqual(r.summary, "Inbox has 1 control I can use; say “press” and a number.")
    }
}
