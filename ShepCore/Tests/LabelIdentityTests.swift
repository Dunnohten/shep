import CoreGraphics
import XCTest
@testable import ShepCore

/// A label is offered, stored and shown only for a control that can be told apart from every other control of its role in the window:
/// a non-empty identifier that no other control shares, or the control's own help text, non-empty and shared by no other same-role control.
/// Path, position and the text near the control never decide: they stay put when two controls swap. A label that vanishes is acceptable; a label on the wrong control is not.
final class LabelStableIdentityTests: XCTestCase {
    typealias Spec = AnchorSpec
    static let frame = anchorTestFrame

    func controls(_ specs: [Spec], nearby: String = "Tools") -> [Control] { anchorControls(specs, nearby: nearby) }
    func tag(_ c: Control) -> String? { c.actions.first { $0.hasPrefix("t") || $0.hasPrefix("n") } }

    func approve(_ cs: [Control]) -> [StoredLabel] {
        LabelScanner.scan(controls: cs, windowFrame: Self.frame, truncated: false).candidates.map { cand in
            StoredLabel(fingerprint: cand.fingerprint, label: "L\(cs.first { $0.pathID == cand.pathID }.flatMap(tag) ?? "?")", anchor: cand.anchor)
        }
    }

    func resolve(_ stored: [StoredLabel], _ cs: [Control]) -> [String: String] {
        var out: [String: String] = [:]
        for c in LabelOverlayResolver.apply(to: cs, windowFrame: Self.frame, labels: stored) where !c.overlayLabel.isEmpty {
            if let t = tag(c) { out[t] = c.overlayLabel }
        }
        return out
    }

    /// Two unnamed buttons 30 points apart in one group, with the one line of text they share. Swapping them must not swap their labels.
    func testAdjacentControlsThatShareTheirContextAreNeitherOfferedNorShown() {
        let pair = [Spec(tag: "t0", x: 20), Spec(tag: "t1", x: 50)]
        let scan = LabelScanner.scan(controls: controls(pair), windowFrame: Self.frame, truncated: false)
        XCTAssertTrue(scan.candidates.isEmpty, "nothing tells the two apart but their place")
        XCTAssertEqual(scan.entries.filter { $0.flagged }.count, 2, "both are still counted as unlabeled")
        XCTAssertEqual(scan.unstableSkipped, 2)
        // A label an older build stored for the first one (hand-made, as that build wrote it), then the two swap places.
        let old = LabelAnchor(role: "AXButton", nearbyText: ["Tools"], path: "AXWindow>AXGroup[0]>AXButton[0]", siblingCount: 2, x: 0.05, y: 0.03,
                              windowWidth: 600, windowHeight: 800)
        let firstFingerprint = LabelScanner.scan(controls: controls(pair), windowFrame: Self.frame, truncated: false).entries
            .first { $0.role == "AXButton" }!.fingerprint
        let stored = [StoredLabel(fingerprint: firstFingerprint, label: "Lt0", anchor: old)]
        let swapped = controls([Spec(tag: "t1", x: 20), Spec(tag: "t0", x: 50)])
        XCTAssertEqual(resolve(stored, swapped), [:])
        XCTAssertEqual(resolve(approve(controls(pair)), swapped), [:])
    }

    func testAControlWithItsOwnHelpKeepsItsLabelAndASwappedOneDoesNot() {
        // Two groups, each with its own text, one unnamed button each; each button has a help text of its own.
        func window(_ first: String, _ second: String) -> [Control] {
            func group(_ text: String, row: CGFloat, _ tag: String) -> LabelTestNode {
                LabelTestNode(role: "AXGroup", frame: CGRect(x: 110, y: 110 + row, width: 500, height: 30), kids: [
                    LabelTestNode(role: "AXStaticText", valueText: text, frame: CGRect(x: 120, y: 112 + row, width: 80, height: 16)),
                    LabelTestNode(role: "AXButton", help: tag == "t0" ? "Plays it" : "Pauses it", frame: CGRect(x: 400, y: 112 + row, width: 30, height: 24), actions: ["AXPress", tag]),
                ])
            }
            let root = LabelTestNode(role: "AXWindow", subrole: "AXStandardWindow", title: "W", frame: Self.frame,
                                     kids: [LabelTestNode(role: "AXGroup", frame: Self.frame, kids: [group(first, row: 0, "t0"), group(second, row: 40, "t1")])])
            return AXTreeReader.read(windows: [AXWindowEntry(info: AXWindowInfo(title: "W", subrole: "AXStandardWindow", frame: Self.frame, isMain: true, isFocused: true), root: root)],
                                     targetFrame: Self.frame, targetTitle: "W", limits: .labelScan, clock: { 0 })!.controls
        }
        let stored = approve(window("Volume", "Brightness"))
        XCTAssertEqual(stored.count, 2, "each is the only same-role control with its help")
        XCTAssertEqual(resolve(stored, window("Volume", "Brightness")), ["t0": "Lt0", "t1": "Lt1"])
        XCTAssertEqual(resolve(stored, window("Brightness", "Volume")), [:], "the groups swapped places: neither slot keeps the other's label")
        XCTAssertEqual(resolve(stored, window("Volume", "Contrast")), ["t0": "Lt0"], "a replaced context loses its label; the other keeps it")
    }

    func testADifferentControlOfTheSameRoleInTheSameSlotGetsNoLabel() {
        // Stored for a control with an identifier; the slot now holds a control with another identifier, or none.
        let stored = approve(controls([Spec(tag: "t0", x: 20, identifier: "play")]))
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(resolve(stored, controls([Spec(tag: "n0", x: 20, identifier: "delete")])), [:])
        XCTAssertEqual(resolve(stored, controls([Spec(tag: "n0", x: 20)])), [:])
        // Stored by help; the replacement sits in a window where another button now shares that help, or has other help.
        let byHelp = approve(controls([Spec(tag: "t0", x: 20, help: "Starts it")]))
        XCTAssertEqual(byHelp.count, 1)
        XCTAssertEqual(resolve(byHelp, controls([Spec(tag: "n0", x: 20, help: "Starts it"), Spec(tag: "n1", x: 50, help: "starts it")])), [:])
        XCTAssertEqual(resolve(byHelp, controls([Spec(tag: "n0", x: 20, help: "Deletes it")])), [:], "other help text")
        XCTAssertEqual(resolve(byHelp, controls([Spec(tag: "n0", x: 20)])), [:], "no help text")
    }

    func testAControlWithNoIdentifierNoNearbyTextAndNoHelpIsNeverOffered() {
        let bare = LabelTestNode(role: "AXButton", frame: CGRect(x: 300, y: 130, width: 30, height: 24), actions: ["AXPress"])
        let root = LabelTestNode(role: "AXWindow", subrole: "AXStandardWindow", title: "W", frame: Self.frame, kids: [bare])
        let cs = AXTreeReader.read(windows: [AXWindowEntry(info: AXWindowInfo(title: "W", subrole: "AXStandardWindow", frame: Self.frame, isMain: true, isFocused: true), root: root)],
                                   targetFrame: Self.frame, targetTitle: "W", limits: .labelScan, clock: { 0 })!.controls
        let scan = LabelScanner.scan(controls: cs, windowFrame: Self.frame, truncated: false)
        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertEqual(scan.unstableSkipped, 1)
        XCTAssertEqual(scan.entries.filter { $0.flagged }.count, 1)
    }

    func testTheScanSeparatesFlaggedFromOfferable() {
        let specs = [Spec(tag: "t0", x: 20, identifier: "solo"), Spec(tag: "t1", x: 220, identifier: "dup"), Spec(tag: "t2", x: 420, identifier: "dup")]
        let scan = LabelScanner.scan(controls: controls(specs), windowFrame: Self.frame, truncated: false)
        XCTAssertEqual(scan.entries.filter { $0.flagged }.count, 3)
        XCTAssertEqual(scan.candidates.count, 1)
        XCTAssertEqual(scan.unstableSkipped, 2)
        XCTAssertEqual(scan.entries.filter { $0.flagged && !$0.offerable }.count, 2)
    }

    func testAnAnchorWithoutAnIdentityNeverAgreesAndIsNeverStored() {
        let bare = LabelAnchor(role: "AXButton", path: "AXWindow>AXGroup[0]>AXButton[0]", siblingCount: 1, x: 0.5, y: 0.5)
        XCTAssertFalse(bare.hasStableIdentity)
        XCTAssertFalse(LabelAnchor.agrees(stored: bare, live: bare))
        var withText = bare; withText.nearbyText = ["Tools"]
        XCTAssertFalse(withText.hasStableIdentity, "text near the control is not the control's own")
        XCTAssertFalse(LabelAnchor.agrees(stored: withText, live: withText))
        var withHelp = bare; withHelp.help = "Opens it"
        XCTAssertTrue(withHelp.hasStableIdentity)
        withHelp.nearbyText = ["Tools"]
        XCTAssertTrue(LabelAnchor.agrees(stored: withHelp, live: withHelp))
        var withID = bare; withID.identifier = " play "
        XCTAssertTrue(withID.hasStableIdentity)
        let proposal = LabelProposal(id: 1, fingerprint: "p2-x", role: "AXButton", kind: "button", context: "x", label: "Play", confidence: 0.9, anchor: bare)
        XCTAssertNil(LabelApproval.resolve(LabelReview(bundleID: "com.a", appName: "A", proposals: [proposal]), answer: .acceptAll),
                     "the approval gate builds no token for a label that cannot be told apart")
        var good = proposal; good.id = 2; good.anchor = withHelp
        let approved = LabelApproval.resolve(LabelReview(bundleID: "com.a", appName: "A", proposals: [proposal, good]), answer: .acceptAll)
        XCTAssertEqual(approved?.items.count, 1)
    }

    func testTheSummaryCountsWhatCannotBeToldApart() {
        let kinds = ["button", "button", "button"]
        XCTAssertEqual(LabelSummary.afterApproval(found: 3, labeled: 1, kinds: kinds, partial: false, skipped: 2),
                       "Found 3 unlabeled buttons. Labeled 1. Skipped 2 that cannot be told apart.")
        XCTAssertTrue(LabelSummary.noneTellApart(skipped: 4, partial: false).contains("4 unlabeled controls that cannot be told apart"))
    }
}
