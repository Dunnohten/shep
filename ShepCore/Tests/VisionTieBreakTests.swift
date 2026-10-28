import CoreGraphics
import XCTest
@testable import ShepCore

/// P2-1: when more than one AX control qualifies by centre only, the nearest centre wins, then the smaller area; a tie that
/// remains is refused (never "first in the array").
final class VisionTieBreakTests: XCTestCase {
    func ax(_ title: String, _ frame: CGRect, path: String) -> Control {
        Control(index: 1, role: "AXButton", title: title, frame: frame, actions: ["AXPress"], pathID: path)
    }
    let a = CGRect(x: 0, y: 0, width: 20, height: 20)
    let b = CGRect(x: 24, y: 0, width: 20, height: 20)
    /// Centre (23, 10): 13 from A's centre (10, 10), 11 from B's centre (34, 10). IoU with either is under 0.3.
    let box = CGRect(x: 17, y: 5, width: 12, height: 10)
    /// Centre (22, 10): 12 from both A's and B's centres.
    let middle = CGRect(x: 16, y: 5, width: 12, height: 10)

    func testBothQualifyByCentreOnlyAndTheNearerCentreWinsInEitherOrder() {
        let ca = ax("Alpha", a, path: "0/1"), cb = ax("Bravo", b, path: "0/2")
        XCTAssertLessThan(VisionRepair.iou(a, box), VisionRepair.duplicateIoU)
        XCTAssertLessThan(VisionRepair.iou(b, box), VisionRepair.duplicateIoU)
        XCTAssertEqual(VisionRepair.axDuplicate(of: box, ax: [ca, cb])?.pathID, "0/2")
        XCTAssertEqual(VisionRepair.axDuplicate(of: box, ax: [cb, ca])?.pathID, "0/2")
    }

    func testAnEqualDistanceIsBrokenByTheSmallerArea() {
        let ca = ax("Alpha", a, path: "0/1")
        let small = ax("Delta", CGRect(x: 24, y: 5, width: 20, height: 10), path: "0/4")   // centre (34, 10), area 200 against 400
        XCTAssertEqual(VisionRepair.axDuplicate(of: middle, ax: [ca, small])?.pathID, "0/4")
        XCTAssertEqual(VisionRepair.axDuplicate(of: middle, ax: [small, ca])?.pathID, "0/4")
    }

    func testAStillTiedMatchIsRefusedInEitherOrder() {
        let ca = ax("Alpha", a, path: "0/1"), cb = ax("Bravo", b, path: "0/2")
        XCTAssertNil(VisionRepair.axDuplicate(of: middle, ax: [ca, cb]))
        XCTAssertNil(VisionRepair.axDuplicate(of: middle, ax: [cb, ca]))
        XCTAssertEqual(VisionRepair.axDuplicateResolution(of: middle, ax: [ca, cb]), .ambiguous)
        XCTAssertEqual(VisionRepair.axDuplicateResolution(of: box, ax: [ca, cb]), .one(cb))
        XCTAssertEqual(VisionRepair.axDuplicateResolution(of: CGRect(x: 500, y: 500, width: 10, height: 10), ax: [ca, cb]), .none)
    }

    func testABetterOverlapStillBeatsANearerCentre() {
        let overlapping = ax("Wide", CGRect(x: 15, y: 3, width: 16, height: 14), path: "0/3")   // IoU well over 0.3 with the box
        let cb = ax("Bravo", b, path: "0/2")
        XCTAssertEqual(VisionRepair.axDuplicate(of: box, ax: [cb, overlapping])?.pathID, "0/3")
        XCTAssertEqual(VisionRepair.axDuplicate(of: box, ax: [overlapping, cb])?.pathID, "0/3")
    }

    func testAnAmbiguousBoxIsNotOfferedAsAClickableFoundControl() {
        let geometry = CaptureGeometry(windowFrame: CGRect(x: 0, y: 0, width: 200, height: 100), imageSize: CGSize(width: 200, height: 100), scale: 1)
        let regions = [SAMRegion(box: middle, score: 0.9, concept: "button")]
        let ca = ax("Alpha", a, path: "0/1"), cb = ax("Bravo", b, path: "0/2")
        XCTAssertTrue(VisionRepair.candidates(from: regions, geometry: geometry, ax: [ca, cb]).isEmpty,
                      "neither merged into a guessed control nor kept as a click-only box")
        XCTAssertEqual(VisionRepair.candidates(from: [SAMRegion(box: box, score: 0.9, concept: "button")], geometry: geometry, ax: [ca, cb]).count, 0,
                       "a resolvable box is a duplicate, as before")
    }

    func pipelineResult(_ target: CGRect, ax list: [Control]) async -> FixScreenResult {
        let geometry = CaptureGeometry(windowFrame: CGRect(x: 0, y: 0, width: 200, height: 100), imageSize: CGSize(width: 200, height: 100), scale: 1)
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: [], targetBox: target))
        let input = VisionInput(png: Data([1]), geometry: geometry, axControls: list, bundleID: "com.example.app", windowTitle: "W", request: "press it")
        return await FixScreenPipeline(provider: provider).run(input)
    }

    func testThePipelineTargetFallbackPicksTheNearerControlWhateverTheOrder() async {
        let ca = ax("Alpha", a, path: "0/1"), cb = ax("Bravo", b, path: "0/2")
        for list in [[ca, cb], [cb, ca]] {
            let r = await pipelineResult(box, ax: list)
            XCTAssertEqual(r.proposals.count, 1)
            XCTAssertEqual(r.proposals.first?.action.control.title, "Bravo")
        }
    }

    func testThePipelineDoesNotGuessOnATie() async {
        let ca = ax("Alpha", a, path: "0/1"), cb = ax("Bravo", b, path: "0/2")
        for list in [[ca, cb], [cb, ca]] {
            let r = await pipelineResult(middle, ax: list)
            XCTAssertFalse(r.proposals.contains { $0.action.control.title == "Alpha" || $0.action.control.title == "Bravo" } && r.proposals.count == 1,
                           "a tie never turns into a single guessed proposal")
            XCTAssertEqual(r.foundCount, 0, "and the box is not offered as a click-only control")
            XCTAssertTrue(r.notes.contains { $0.contains("two controls") }, "\(r.notes)")
        }
    }
}
