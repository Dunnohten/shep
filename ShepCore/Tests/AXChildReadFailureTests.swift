import CoreGraphics
import XCTest
@testable import ShepCore

/// A node whose child read can fail, as an Accessibility call can (timeout, app busy, element gone). A failed read is not a leaf.
struct FlakyNode: AXNodeSource {
    var role: String
    var help: String = ""
    var identifier: String = ""
    var frame: CGRect?
    var kids: [FlakyNode] = []
    /// The child read reports failure (and returns nothing).
    var childReadFails = false

    var subrole: String { "" }
    var title: String { "" }
    var descriptionText: String { "" }
    var valueText: String? { nil }
    var isEnabled: Bool { true }
    var actions: [String] { role == "AXButton" ? ["AXPress"] : [] }
    var titleElementText: String { "" }

    func children() -> [FlakyNode] { childReadFails ? [] : kids }
    func children(limit: Int) -> [FlakyNode] { Array(children().prefix(max(0, limit))) }
    func readChildren(limit: Int) -> AXChildRead<FlakyNode> {
        childReadFails ? AXChildRead(children: [], failed: true) : AXChildRead(children: Array(kids.prefix(max(0, limit))))
    }
}

final class AXChildReadFailureTests: XCTestCase {
    let window = CGRect(x: 100, y: 100, width: 600, height: 800)

    func button(id: String, x: CGFloat) -> FlakyNode {
        FlakyNode(role: "AXButton", identifier: id, frame: CGRect(x: window.minX + x, y: window.minY + 40, width: 30, height: 24))
    }

    /// A window with one button "solo" and a group beside it. The group's child read fails; if it had worked it would have shown a second
    /// "solo".
    func tree(groupReadFails: Bool, hiddenTwin: Bool = true) -> FlakyNode {
        let group = FlakyNode(role: "AXGroup", frame: window, kids: hiddenTwin ? [button(id: "solo", x: 300)] : [], childReadFails: groupReadFails)
        let root = FlakyNode(role: "AXWindow", frame: window, kids: [button(id: "solo", x: 20), group])
        return root
    }

    func read(_ root: FlakyNode) -> AXReadResult<FlakyNode> {
        let info = AXWindowInfo(title: "W", subrole: "AXStandardWindow", frame: window, isMain: true, isFocused: true)
        return AXTreeReader.read(windows: [AXWindowEntry(info: info, root: root)], targetFrame: window, targetTitle: "W", limits: .labelScan, clock: { 0 })!
    }

    func testAFailedChildReadMarksTheWalkPartial() {
        XCTAssertTrue(read(tree(groupReadFails: true)).truncated)
    }

    func testAnElementWithNoChildrenIsNotPartial() {
        XCTAssertFalse(read(tree(groupReadFails: false, hiddenTwin: false)).truncated)
    }

    func testAFailedReadWithNoRoomLeftIsStillPartial() {
        // maxNodes 3 is spent on the window and its two children, so the group's children are asked for with a limit of one.
        var limits = AXWalkLimits.labelScan
        limits.maxNodes = 3
        let budget = AXWalkBudget(limits: limits, clock: { 0 })
        let walked = AXTreeWalker.walk(root: tree(groupReadFails: true), rootPath: "0", windowTitle: "W", windowSubrole: "AXStandardWindow", budget: budget)
        XCTAssertTrue(walked.truncated)
    }

    func testAScanOffersNothingWhenAReadFailedBehindADuplicate() {
        let hidden = read(tree(groupReadFails: true))
        let scan = LabelScanner.scan(controls: hidden.controls, windowFrame: window, truncated: hidden.truncated || hidden.depthCut)
        XCTAssertTrue(scan.partial)
        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.entries.allSatisfy { !$0.offerable })
        // The same tree read without the failure sees the twin and offers neither.
        let whole = read(tree(groupReadFails: false))
        let full = LabelScanner.scan(controls: whole.controls, windowFrame: window, truncated: whole.truncated || whole.depthCut)
        XCTAssertFalse(full.partial)
        XCTAssertTrue(full.candidates.isEmpty, "two controls share one identifier")
        // Without the twin the lone button is offered, so the cases above are not empty for some other reason.
        let alone = read(tree(groupReadFails: false, hiddenTwin: false))
        let one = LabelScanner.scan(controls: alone.controls, windowFrame: window, truncated: alone.truncated || alone.depthCut)
        XCTAssertEqual(one.candidates.count, 1)
    }

    func testTheResolverAppliesNothingWhenAReadFailedBehindADuplicate() {
        // Approved when the window held one "solo".
        let alone = read(tree(groupReadFails: false, hiddenTwin: false))
        let approvedScan = LabelScanner.scan(controls: alone.controls, windowFrame: window, truncated: false)
        let stored = approvedScan.candidates.map { StoredLabel(fingerprint: $0.fingerprint, label: "Solo", anchor: $0.anchor) }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(LabelOverlayResolver.apply(to: alone.controls, windowFrame: window, labels: stored, partial: alone.truncated || alone.depthCut)
            .filter { !$0.overlayLabel.isEmpty }.count, 1)
        // Later a twin exists behind a child read that fails: the visible button must not take the label on the strength of what was read.
        let hidden = read(tree(groupReadFails: true))
        let applied = LabelOverlayResolver.apply(to: hidden.controls, windowFrame: window, labels: stored, partial: hidden.truncated || hidden.depthCut)
        XCTAssertTrue(applied.allSatisfy { $0.overlayLabel.isEmpty })
    }
}
