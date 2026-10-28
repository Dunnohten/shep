import CoreGraphics
import XCTest
@testable import ShepCore

/// A detector box that is really a control the app already lists must never become a second, click-only control.
/// Frames are from a live run against a torrent client's main window, reproduced on a Sample Torrent App fixture.
final class VisionDuplicateTests: XCTestCase {
    let tip = "Speed Limit overrides the total bandwidth limits with its own limits."
    /// Window at the origin, 1x, so pixels equal screen points.
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 0, y: 0, width: 700, height: 700), imageSize: CGSize(width: 700, height: 700), scale: 1)
    let axFrame = CGRect(x: 112, y: 589, width: 20, height: 20)
    let visionBox = CGRect(x: 107, y: 592, width: 33, height: 12)

    var turtle: Control {
        Control(role: "AXCheckBox", window: "Sample Torrent App", help: tip, frame: axFrame, actions: ["AXPress"], pathID: "0/9")
    }

    func input(request: String? = "turn on the speed limit (turtle)") -> VisionInput {
        VisionInput(png: Data([1]), geometry: geometry, axControls: [turtle], bundleID: "com.example.torrent",
                    windowTitle: "Sample Torrent App", request: request)
    }

    func testTheBoxResolvesToTheAXCheckbox() {
        let resolved = RoleResolver.resolve(frame: visionBox, modelText: "button", name: "turtle speed limit icon", ax: [turtle])
        XCTAssertEqual(resolved.role, .checkbox)
        XCTAssertEqual(resolved.source, .ax)
        XCTAssertEqual(resolved.axMatch?.pathID, "0/9")
    }

    func testTheCandidateListDropsTheBoxThatIsAnAXControl() {
        let regions = [SAMRegion(box: visionBox, score: 0.9, concept: "icon")]
        XCTAssertTrue(VisionRepair.candidates(from: regions, geometry: geometry, ax: [turtle]).isEmpty)
    }

    func testTheDuplicateRuleCoversOverlapAndCentreInsideButNotDisabledOrNonPressable() {
        XCTAssertTrue(VisionRepair.isAXDuplicate(visionBox, ax: [turtle]))
        // Centre inside the AX frame expanded by 4 pt, though the IoU is small.
        let tall = CGRect(x: 100, y: 580, width: 30, height: 40)
        XCTAssertTrue(VisionRepair.isAXDuplicate(tall, ax: [turtle]))
        var off = turtle; off.enabled = false
        XCTAssertFalse(VisionRepair.isAXDuplicate(CGRect(x: 100, y: 582, width: 16, height: 14), ax: [off]))
        let noPress = Control(role: "AXCheckBox", help: tip, frame: axFrame, actions: [], pathID: "0/9")
        XCTAssertFalse(VisionRepair.isAXDuplicate(CGRect(x: 100, y: 582, width: 16, height: 14), ax: [noPress]))
        // A far-away box is not a duplicate.
        XCTAssertFalse(VisionRepair.isAXDuplicate(CGRect(x: 300, y: 300, width: 30, height: 30), ax: [turtle]))
    }

    func testTheProposalIsAXPressOnTheRealControlNeverAClickOnADuplicate() async {
        let analysis = ScreenAnalysis(summary: "", controls: [LocatedControl(name: "turtle speed limit icon", role: "button", box: visionBox)])
        let result = await FixScreenPipeline(provider: FakeProvider(analysis: analysis)).run(input())
        XCTAssertEqual(result.foundCount, 0, "the box is the AX checkbox, not a found control")
        XCTAssertEqual(result.proposals.count, 1)
        XCTAssertEqual(result.proposals.first?.action.kind, .axPress)
        XCTAssertEqual(result.proposals.first?.action.control.pathID, "0/9")
        XCTAssertFalse(result.proposals.contains { $0.action.control.fromVision })
    }

    func testAModelTargetBoxOnTheDuplicateProposesAXPress() async {
        let analysis = ScreenAnalysis(summary: "", controls: [LocatedControl(name: "turtle speed limit icon", role: "button", box: visionBox)],
                                      targetBox: visionBox)
        let result = await FixScreenPipeline(provider: FakeProvider(analysis: analysis)).run(input())
        XCTAssertEqual(result.proposals.count, 1)
        XCTAssertEqual(result.proposals.first?.action.kind, .axPress)
        XCTAssertFalse(result.proposals[0].action.control.fromVision)
    }

    /// Second failure of the same run: a 44x153 box over the toolbar was proposed as "unlabeled control".
    func testAnExtremelyTallVisionBoxIsNeverProposed() async {
        let tallBox = CGRect(x: 80, y: 347, width: 44, height: 153)
        XCTAssertTrue(VisionRepair.isImplausibleShape(tallBox))
        XCTAssertFalse(VisionRepair.isImplausibleShape(CGRect(x: 0, y: 0, width: 30, height: 90)), "tall but under 100 pt")
        XCTAssertFalse(VisionRepair.isImplausibleShape(CGRect(x: 0, y: 0, width: 60, height: 120)), "taller than 100 pt but under 3x")
        let analysis = ScreenAnalysis(summary: "", controls: [LocatedControl(name: "unlabeled control", role: "", box: tallBox)], targetBox: tallBox)
        let result = await FixScreenPipeline(provider: FakeProvider(analysis: analysis)).run(input(request: nil))
        XCTAssertEqual(result.foundCount, 0)
        XCTAssertTrue(result.proposals.isEmpty)
        XCTAssertTrue(VisionRepair.candidates(from: [SAMRegion(box: tallBox, score: 0.9, concept: "icon")], geometry: geometry, ax: []).isEmpty)
    }
}
