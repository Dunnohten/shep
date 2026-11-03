import CoreGraphics
import XCTest
@testable import ShepCore

final class LabelOverlayResolutionTests: XCTestCase {
    func fixtureControls() -> [Control] { LabelFixture.controls()!.controls }

    func candidates() -> [LabelCandidate] {
        LabelScanner.scan(controls: fixtureControls(), windowFrame: LabelFixture.windowFrame, truncated: false).candidates
    }

    func stored(_ c: LabelCandidate, _ label: String) -> StoredLabel { StoredLabel(fingerprint: c.fingerprint, label: label, anchor: c.anchor) }

    func labelsForAll() -> [StoredLabel] {
        candidates().map { stored($0, "Label \($0.identifier)") }
    }

    func testAnUnnamedControlGetsItsOverlayLabelAsItsName() {
        let play = candidates().first { $0.identifier == "btnPlay" }!
        let resolved = LabelOverlayResolver.apply(to: fixtureControls(), windowFrame: LabelFixture.windowFrame, labels: [stored(play, "Play music")])
        let c = resolved.first { $0.identifier == "btnPlay" }!
        XCTAssertEqual(c.label, "Play music")
        XCTAssertEqual(c.labelSource, .overlay)
        XCTAssertTrue(c.line.contains("label added by Shep"))
    }

    func testAControlWithAGenericTitleIsRenamedByTheOverlay() {
        let generic = candidates().first { $0.identifier == "u2" }!
        let resolved = LabelOverlayResolver.apply(to: fixtureControls(), windowFrame: LabelFixture.windowFrame, labels: [stored(generic, "Rename")])
        let c = resolved.first { $0.identifier == "u2" }!
        XCTAssertEqual(c.title, "button", "the app's own title is left as it was")
        XCTAssertEqual(c.label, "Rename")
    }

    func testANamedControlIsNeverOverriddenEvenIfSomethingTriesTo() {
        var named = Control(role: "AXButton", title: "Save", frame: CGRect(x: 10, y: 10, width: 30, height: 20))
        named.overlayLabel = "Delete everything"
        XCTAssertEqual(named.label, "Save")
        XCTAssertEqual(named.labelSource, .title)
        var described = Control(role: "AXButton", description: "Settings", frame: CGRect(x: 10, y: 10, width: 30, height: 20))
        described.overlayLabel = "Other"
        XCTAssertEqual(described.label, "Settings")
        // And the resolver only offers a label to a flagged control, whatever the store holds.
        let all = LabelOverlayResolver.apply(to: fixtureControls(), windowFrame: LabelFixture.windowFrame, labels: labelsForAll())
        for id in ["l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "l10", "l11", "l12", "s1", "s2", "s3"] {
            let c = all.first { $0.identifier == id }!
            XCTAssertEqual(c.overlayLabel, "", id)
        }
    }

    func testEveryFlaggedControlWithAStoredLabelGetsIt() {
        let all = LabelOverlayResolver.apply(to: fixtureControls(), windowFrame: LabelFixture.windowFrame, labels: labelsForAll())
        let named = all.filter { $0.labelSource == .overlay }
        XCTAssertEqual(named.count, 14)
    }

    func testAnEmptyStoreChangesNothing() {
        let before = fixtureControls()
        XCTAssertEqual(LabelOverlayResolver.apply(to: before, windowFrame: LabelFixture.windowFrame, labels: []), before)
    }

    func testTheFingerprintsOfTheFixtureSurviveTheWindowMoving() {
        func shift(_ n: LabelTestNode) -> LabelTestNode {
            var m = n
            m.frame = n.frame?.offsetBy(dx: 400, dy: -50)
            m.kids = n.kids.map(shift)
            return m
        }
        let movedWindow = CGRect(x: 500, y: 50, width: 600, height: 800)
        let movedTree = shift(LabelFixture.tree())
        let result = AXTreeReader.read(windows: [AXWindowEntry(info: AXWindowInfo(title: "Fixture", subrole: "AXStandardWindow", frame: movedWindow, isMain: true, isFocused: true), root: movedTree)],
                                       targetFrame: movedWindow, targetTitle: "Fixture", limits: .labelScan, clock: { 0 })!
        let before = candidates().map { $0.fingerprint }
        let after = LabelScanner.scan(controls: result.controls, windowFrame: movedWindow, truncated: false).candidates.map { $0.fingerprint }
        XCTAssertEqual(before, after)
    }

    func testAnOverlayLabelNamesTheControlForTheClickMatching() {
        let target = candidates().first { $0.identifier == "u5" }!   // the checkbox with no title, row "Remember"
        let resolved = LabelOverlayResolver.apply(to: fixtureControls(), windowFrame: LabelFixture.windowFrame, labels: [stored(target, "Remember my login")])
        let checkbox = resolved.first { $0.identifier == "u5" }!
        let other = resolved.first { $0.identifier == "l1" }!
        // The existing request-to-control matching reads `label`, so "click remember my login" now finds the checkbox.
        XCTAssertGreaterThan(ProposalRanker.requestMatch(checkbox, request: "click remember my login"), ProposalRanker.requestMatch(other, request: "click remember my login"))
        XCTAssertGreaterThan(ProposalRanker.requestMatch(checkbox, request: "click remember my login"), 0)
        let before = fixtureControls().first { $0.identifier == "u5" }!
        XCTAssertEqual(ProposalRanker.requestMatch(before, request: "click remember my login"), 0)
        let ranked = ProposalRanker.rank(ControlFilter.prepare(resolved, limit: 60, window: LabelFixture.windowFrame), request: "click remember my login",
                                         bundleID: "com.example.fixture", window: LabelFixture.windowFrame)
        XCTAssertEqual(ranked.first?.control.identifier, "u5")
    }

    func testAnActionOnAnOverlayLabelledControlSaysSo() {
        var c = Control(role: "AXButton", frame: CGRect(x: 1, y: 1, width: 30, height: 30))
        c.overlayLabel = "Mute"
        let action = ProposedAction(control: c, kind: .axPress, bundleID: "com.example")
        XCTAssertTrue(action.summary.contains("\"Mute\""))
        XCTAssertTrue(action.summary.contains("label added by Shep"))
    }

    func testAnOverlayLabelIsOnlySpokenAsShepsOwn() {
        var c = Control(role: "AXButton", frame: CGRect(x: 1, y: 1, width: 30, height: 30))
        XCTAssertNil(LabelAnnouncement.text(for: c))
        c.overlayLabel = "Mute"
        XCTAssertEqual(LabelAnnouncement.text(for: c), "Mute, a label Shep added.")
        var named = Control(role: "AXButton", title: "Save", frame: CGRect(x: 1, y: 1, width: 30, height: 30))
        named.overlayLabel = "Mute"
        XCTAssertNil(LabelAnnouncement.text(for: named))
    }
}
