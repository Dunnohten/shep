import CoreGraphics
import XCTest
@testable import ShepCore

/// Code review 3: a partial walk offers and resolves nothing; a label needs an identity the control owns; the focused window wins a
/// title tie; clearing labels asks the same question as repairing them.
final class LabelPartialWalkTests: XCTestCase {
    let frame = anchorTestFrame

    func approvedLabels(_ cs: [Control]) -> [StoredLabel] {
        LabelScanner.scan(controls: cs, windowFrame: frame, truncated: false).candidates.map { StoredLabel(fingerprint: $0.fingerprint, label: "L", anchor: $0.anchor) }
    }

    func testAPartialWalkOffersNothingEvenForAnIdentifiedControl() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, identifier: "play"), AnchorSpec(tag: "t1", x: 220, help: "Stops it")])
        let full = LabelScanner.scan(controls: cs, windowFrame: frame, truncated: false)
        XCTAssertEqual(full.candidates.count, 2)
        let partial = LabelScanner.scan(controls: cs, windowFrame: frame, truncated: true)
        XCTAssertTrue(partial.partial)
        XCTAssertTrue(partial.candidates.isEmpty)
        XCTAssertTrue(partial.entries.allSatisfy { !$0.offerable })
        XCTAssertEqual(partial.entries.filter { $0.flagged }.count, 2, "they are still counted as unlabeled")
    }

    func testAPartialReadResolvesNothingFromTheStore() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, identifier: "play")])
        let stored = approvedLabels(cs)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(LabelOverlayResolver.apply(to: cs, windowFrame: frame, labels: stored).filter { !$0.overlayLabel.isEmpty }.count, 1)
        let partial = LabelOverlayResolver.apply(to: cs, windowFrame: frame, labels: stored, partial: true)
        XCTAssertTrue(partial.allSatisfy { $0.overlayLabel.isEmpty })
    }

    func testTheSummaryAdmitsTheWindowWasTooLarge() {
        XCTAssertEqual(LabelSummary.tooLarge(flagged: 3), "Found 3 unlabeled controls, but the window is too large to check fully, so none could be labeled safely.")
        XCTAssertEqual(LabelSummary.tooLarge(flagged: 1), "Found 1 unlabeled control, but the window is too large to check fully, so none could be labeled safely.")
        XCTAssertEqual(LabelSummary.tooLarge(flagged: 0), "The window is too large to check fully, so none could be labeled safely.")
    }

    func testADuplicateHiddenByTheDepthCapCannotMakeAControlOfferable() {
        // "solo" is visible; a second control with the same identifier sits below the depth cap and is never read.
        func deep(_ n: Int) -> LabelTestNode {
            var node = LabelTestNode(role: "AXButton", frame: CGRect(x: 400, y: 300, width: 30, height: 24), actions: ["AXPress"], identifier: "solo")
            for _ in 0..<n { node = LabelTestNode(role: "AXGroup", frame: LabelFixture.windowFrame, kids: [node]) }
            return node
        }
        let visible = LabelTestNode(role: "AXButton", frame: CGRect(x: 300, y: 200, width: 30, height: 24), actions: ["AXPress"], identifier: "solo")
        let root = LabelTestNode(role: "AXWindow", frame: LabelFixture.windowFrame, kids: [visible, deep(40)])
        let result = LabelFixture.controls(root: root)!
        XCTAssertTrue(result.depthCut)
        let scan = LabelScanner.scan(controls: result.controls, windowFrame: LabelFixture.windowFrame, truncated: result.truncated || result.depthCut)
        XCTAssertTrue(scan.candidates.isEmpty)
    }
}

final class LabelControlOwnedIdentityTests: XCTestCase {
    let frame = anchorTestFrame

    func scan(_ cs: [Control]) -> LabelScan { LabelScanner.scan(controls: cs, windowFrame: frame, truncated: false) }

    func testUniqueNearbyTextAloneIsNotAnIdentity() {
        let s = scan(anchorControls([AnchorSpec(tag: "t0", x: 20), AnchorSpec(tag: "t1", x: 220)]))
        XCTAssertTrue(s.candidates.isEmpty)
        XCTAssertEqual(s.unstableSkipped, 2)
        XCTAssertEqual(s.entries.filter { $0.flagged }.count, 2)
    }

    func testAControlsOwnUniqueHelpIsAnIdentity() {
        let s = scan(anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Starts it"), AnchorSpec(tag: "t1", x: 220, help: "Stops it")]))
        XCTAssertEqual(s.candidates.count, 2)
        XCTAssertEqual(s.unstableSkipped, 0)
    }

    func testHelpSharedBySameRoleControlsIsNotAnIdentity() {
        let s = scan(anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Do it"), AnchorSpec(tag: "t1", x: 220, help: "do it"), AnchorSpec(tag: "t2", x: 420, help: "Other")]))
        XCTAssertEqual(s.candidates.count, 1)
        XCTAssertEqual(s.unstableSkipped, 2)
    }

    /// Two groups, each a static text and a button. `order` says which button (by identifier-less tag in `actions`) sits under which text.
    func twoGroups(_ order: [String]) -> [Control] {
        func button(_ tag: String, _ x: CGFloat) -> LabelTestNode {
            LabelTestNode(role: "AXButton", frame: CGRect(x: frame.minX + x, y: frame.minY + 60, width: 30, height: 24), actions: ["AXPress", tag])
        }
        func group(_ text: String, _ tag: String, _ y: CGFloat) -> LabelTestNode {
            LabelTestNode(role: "AXGroup", frame: CGRect(x: frame.minX, y: frame.minY + y, width: 500, height: 100), kids: [
                LabelTestNode(role: "AXStaticText", valueText: text, frame: CGRect(x: frame.minX + 10, y: frame.minY + y, width: 80, height: 16)), button(tag, 200)])
        }
        let root = LabelTestNode(role: "AXWindow", subrole: "AXStandardWindow", title: "W", frame: frame,
                                 kids: [group("Volume", order[0], 40), group("Brightness", order[1], 200)])
        let info = AXWindowInfo(title: "W", subrole: "AXStandardWindow", frame: frame, isMain: true, isFocused: true)
        return AXTreeReader.read(windows: [AXWindowEntry(info: info, root: root)], targetFrame: frame, targetTitle: "W", limits: .labelScan, clock: { 0 })!.controls
    }

    func testSwappingTwoControlsWhileTheirNearbyTextStaysPutLabelsNeitherOfThem() {
        let before = twoGroups(["a", "b"])
        let s = scan(before)
        XCTAssertTrue(s.candidates.isEmpty, "nearby text is not enough to store a label against")
        // A label an older build stored against the nearby text alone is not applied either.
        let legacy = LabelScanner.scan(controls: before, windowFrame: frame, truncated: false)
        XCTAssertEqual(legacy.entries.filter { $0.flagged }.count, 2)
        let nearbyOnly = before.filter { $0.role == "AXButton" }.map { c -> StoredLabel in
            let full = LabelFingerprintTestSupport.nearbyOnlyAnchor(for: c, in: before, frame: frame)
            return StoredLabel(fingerprint: full.fingerprint, label: "L" + (c.actions.last ?? ""), anchor: full.anchor)
        }
        for order in [["a", "b"], ["b", "a"]] {
            let applied = LabelOverlayResolver.apply(to: twoGroups(order), windowFrame: frame, labels: nearbyOnly)
            XCTAssertTrue(applied.allSatisfy { $0.overlayLabel.isEmpty }, "order \(order)")
        }
    }

    func testAnAnchorWithOnlyNearbyTextHasNoStableIdentity() {
        XCTAssertFalse(LabelAnchor(role: "AXButton", nearbyText: ["Volume"]).hasStableIdentity)
        XCTAssertTrue(LabelAnchor(role: "AXButton", help: "Mute").hasStableIdentity)
        XCTAssertTrue(LabelAnchor(role: "AXButton", identifier: "mute").hasStableIdentity)
        let nearbyOnly = LabelAnchor(role: "AXButton", nearbyText: ["Volume"], path: "p", siblingCount: 1, x: 0.5, y: 0.5)
        XCTAssertFalse(LabelAnchor.agrees(stored: nearbyOnly, live: nearbyOnly))
    }

    func testHelpStillHasToAgreeAndNearbyTextStillChecks() {
        let a = LabelAnchor(role: "AXButton", nearbyText: ["Volume"], help: "Mute", path: "p", siblingCount: 1, x: 0.5, y: 0.5)
        var other = a; other.nearbyText = ["Brightness"]
        XCTAssertTrue(LabelAnchor.agrees(stored: a, live: a))
        XCTAssertFalse(LabelAnchor.agrees(stored: a, live: other), "unique help does not excuse changed nearby text")
    }
}

enum LabelFingerprintTestSupport {
    /// What the previous build stored for a control with nothing of its own to go by: its fingerprint and an anchor with the nearby text.
    static func nearbyOnlyAnchor(for c: Control, in controls: [Control], frame: CGRect) -> (fingerprint: String, anchor: LabelAnchor) {
        let tree = LabelTree(controls: controls)
        let i = tree.nodes.firstIndex { $0.control.pathID == c.pathID }!
        let rel = CGRect(x: c.frame!.minX - frame.minX, y: c.frame!.minY - frame.minY, width: c.frame!.width, height: c.frame!.height)
        let input = LabelFingerprint.Input(role: c.role, subrole: c.subrole, identifier: c.identifier, ancestorPath: tree.ancestorPath(of: i),
                                           nearbyText: tree.nearbyText(of: i), help: c.help, windowSize: frame.size,
                                           relativeCenter: CGPoint(x: rel.midX, y: rel.midY), siblingCount: tree.siblingCount(of: i))
        var anchor = LabelFingerprint.anchor(input)
        anchor.window = WindowSignature(identifier: c.windowIdentifier, subrole: c.windowSubrole, title: c.window)
        return (LabelFingerprint.make(input), anchor)
    }
}

final class WindowTitleTieTests: XCTestCase {
    func info(_ title: String, frame: CGRect, main: Bool = false, focused: Bool = false) -> AXWindowInfo {
        AXWindowInfo(title: title, subrole: "AXStandardWindow", frame: frame, isMain: main, isFocused: focused)
    }

    func testDuplicateTitlesWithNoFrameMatchChooseTheFocusedOne() {
        let windows = [info("Untitled", frame: CGRect(x: 0, y: 0, width: 500, height: 400), main: true),
                       info("Untitled", frame: CGRect(x: 600, y: 0, width: 500, height: 400), focused: true)]
        let far = CGRect(x: 300, y: 300, width: 123, height: 99)
        XCTAssertEqual(WindowSelector.select(windows, targetFrame: far, targetTitle: "Untitled", preferFocused: true)?.target, 1)
        XCTAssertEqual(WindowSelector.select(windows, targetFrame: nil, targetTitle: "Untitled", preferFocused: true)?.target, 1)
    }

    func testWithOneTitleMatchTheFocusedOtherWindowDoesNotWin() {
        let windows = [info("Notes", frame: CGRect(x: 0, y: 0, width: 500, height: 400)),
                       info("Other", frame: CGRect(x: 600, y: 0, width: 500, height: 400), focused: true)]
        XCTAssertEqual(WindowSelector.select(windows, targetFrame: nil, targetTitle: "Notes", preferFocused: true)?.target, 0)
    }

    func testExactTitleMatchesComeBeforeContainsMatchesAndFocusBreaksTheTieWithinThem() {
        let windows = [info("Doc 2 copy", frame: CGRect(x: 0, y: 0, width: 10, height: 10), focused: true),
                       info("Doc 2", frame: CGRect(x: 20, y: 0, width: 10, height: 10)),
                       info("Doc 2", frame: CGRect(x: 40, y: 0, width: 10, height: 10), focused: false)]
        XCTAssertEqual(WindowSelector.select(windows, targetFrame: nil, targetTitle: "Doc 2")?.target, 1, "no focused exact match: the first exact one")
    }
}

final class LabelTargetAppTests: XCTestCase {
    func testTheWindowTheDogIsOnIsTheTargetEvenWhenAnotherAppIsInFront() {
        XCTAssertEqual(LabelTargetApp.choose(dogPID: 10, frontPID: 20, ownPID: 99), 10)
    }

    func testWithoutADogWindowTheFrontAppIsTheTarget() {
        XCTAssertEqual(LabelTargetApp.choose(dogPID: nil, frontPID: 20, ownPID: 99), 20)
    }

    func testShepItselfIsNeverTheTarget() {
        XCTAssertNil(LabelTargetApp.choose(dogPID: 99, frontPID: 99, ownPID: 99))
        XCTAssertNil(LabelTargetApp.choose(dogPID: nil, frontPID: 99, ownPID: 99))
        XCTAssertEqual(LabelTargetApp.choose(dogPID: 99, frontPID: 20, ownPID: 99), 20, "the dog's own panel is not a window to fix")
    }

    func testNothingInFrontAndNoDogGivesNoTarget() {
        XCTAssertNil(LabelTargetApp.choose(dogPID: nil, frontPID: nil, ownPID: 99))
    }
}
