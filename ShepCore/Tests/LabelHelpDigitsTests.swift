import CoreGraphics
import XCTest
@testable import ShepCore

/// Help text is identity: "Open account 1234" and "Open account 5678" are two different controls. Digits are folded only in the text
/// near a control, never in its help.
final class LabelHelpDigitsTests: XCTestCase {
    let frame = anchorTestFrame

    func scan(_ cs: [Control]) -> LabelScan { LabelScanner.scan(controls: cs, windowFrame: frame, truncated: false) }

    func approved(_ cs: [Control]) -> [StoredLabel] {
        scan(cs).candidates.map { StoredLabel(fingerprint: $0.fingerprint, label: "Open", anchor: $0.anchor) }
    }

    func labels(_ stored: [StoredLabel], on cs: [Control]) -> [String] {
        LabelOverlayResolver.apply(to: cs, windowFrame: frame, labels: stored).map { $0.overlayLabel }.filter { !$0.isEmpty }
    }

    func testHelpThatDiffersOnlyInDigitsIsAnotherControlAndTheOldLabelIsNotApplied() {
        let before = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Open account 1234")])
        let stored = approved(before)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(labels(stored, on: before), ["Open"], "the same control is still labelled")
        let after = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Open account 5678")])
        XCTAssertEqual(labels(stored, on: after), [])
    }

    func testTheAnchorDoesNotAgreeWhenOnlyTheDigitsOfTheHelpChange() {
        let a = LabelFingerprint.anchor(LabelFingerprint.Input(role: "AXButton", help: "Open account 1234", windowSize: frame.size, relativeCenter: .zero))
        let b = LabelFingerprint.anchor(LabelFingerprint.Input(role: "AXButton", help: "Open account 5678", windowSize: frame.size, relativeCenter: .zero))
        XCTAssertTrue(LabelAnchor.agrees(stored: a, live: a))
        XCTAssertFalse(LabelAnchor.agrees(stored: a, live: b))
    }

    func testTheKeyChangesWithTheDigitsOfTheHelpButNotWithCaseOrSpacing() {
        func key(_ help: String) -> String {
            LabelFingerprint.make(LabelFingerprint.Input(role: "AXButton", ancestorPath: ["AXWindow"], help: help, windowSize: frame.size, relativeCenter: .zero))
        }
        XCTAssertNotEqual(key("Open account 1234"), key("Open account 5678"))
        XCTAssertNotEqual(key("Item 12"), key("Item 1 2"))
        XCTAssertEqual(key("Open account 1234"), key("  open   ACCOUNT 1234 "))
    }

    func testTwoControlsWhoseHelpDiffersOnlyInDigitsAreBothOffered() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Open account 1234"), AnchorSpec(tag: "t1", x: 220, help: "Open account 5678")])
        let s = scan(cs)
        XCTAssertEqual(s.candidates.count, 2)
        XCTAssertEqual(Set(s.candidates.map { $0.fingerprint }).count, 2)
        XCTAssertEqual(s.unstableSkipped, 0)
        XCTAssertEqual(s.duplicatesSkipped, 0)
        XCTAssertEqual(s.entries.filter { $0.offerable }.count, 2)
    }

    func testTheTwoControlsKeepTheirOwnLabelsAndSwappingTheirHelpMovesNothing() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Open account 1234"), AnchorSpec(tag: "t1", x: 220, help: "Open account 5678")])
        let stored = scan(cs).candidates.map { StoredLabel(fingerprint: $0.fingerprint, label: "L" + $0.help.suffix(4), anchor: $0.anchor) }
        XCTAssertEqual(Set(labels(stored, on: cs)), ["L1234", "L5678"])
        let swapped = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Open account 5678"), AnchorSpec(tag: "t1", x: 220, help: "Open account 1234")])
        XCTAssertEqual(labels(stored, on: swapped), [], "the help moved to the other place, so the anchors no longer agree")
    }

    func testIdenticalHelpIsStillADuplicate() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Open account 1234"), AnchorSpec(tag: "t1", x: 220, help: "Open  Account 1234")])
        let s = scan(cs)
        XCTAssertTrue(s.candidates.isEmpty)
        XCTAssertEqual(s.unstableSkipped, 2)
    }

    func testNearbyTextStillBlursDigits() {
        func key(_ near: String) -> String {
            LabelFingerprint.make(LabelFingerprint.Input(role: "AXButton", ancestorPath: ["AXWindow"], nearbyText: [near], help: "Same", windowSize: frame.size, relativeCenter: .zero))
        }
        XCTAssertEqual(key("3 items"), key("14 items"))
    }

    func testALabelStoredUnderTheOldHelpKeyIsNotApplied() {
        // An earlier build keyed a control by its help with digits folded ("p2-"). That key is never produced now, so such a label is
        // not found, even when its anchor matches the live control exactly.
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Open account 1234")])
        let live = scan(cs).candidates[0]
        XCTAssertTrue(live.fingerprint.hasPrefix("p3-"))
        let old = StoredLabel(fingerprint: "p2-" + live.fingerprint.dropFirst(3), label: "Old", anchor: live.anchor)
        XCTAssertEqual(labels([old], on: cs), [])
    }
}
