import CoreGraphics
import XCTest
@testable import ShepCore

let anchorTestFrame = CGRect(x: 100, y: 100, width: 600, height: 800)

/// One window holding a group: a static text, then buttons with no name. A button's `tag` rides along in `actions`, so a test can say
/// which control it is looking at without giving the control anything the fingerprint reads.
struct AnchorSpec {
    var tag: String
    var x: CGFloat
    var identifier = ""
    var help = ""
}

func anchorControls(_ specs: [AnchorSpec], nearby: String = "Tools", window: CGRect = anchorTestFrame, windowTitle: String = "W",
                    windowSubrole: String = "AXStandardWindow", windowIdentifier: String = "") -> [Control] {
    var kids: [LabelTestNode] = [LabelTestNode(role: "AXStaticText", valueText: nearby, frame: CGRect(x: window.minX + 10, y: window.minY + 10, width: 80, height: 16))]
    for s in specs {
        kids.append(LabelTestNode(role: "AXButton", help: s.help, frame: CGRect(x: window.minX + s.x, y: window.minY + 40, width: 30, height: 24), isEnabled: true,
                                  actions: ["AXPress", s.tag], identifier: s.identifier))
    }
    let root = LabelTestNode(role: "AXWindow", subrole: windowSubrole, title: windowTitle, frame: window,
                             kids: [LabelTestNode(role: "AXGroup", frame: window, kids: kids)])
    let info = AXWindowInfo(title: windowTitle, subrole: windowSubrole, frame: window, isMain: true, isFocused: true, identifier: windowIdentifier)
    let result = AXTreeReader.read(windows: [AXWindowEntry(info: info, root: root)],
                                   targetFrame: window, targetTitle: windowTitle, limits: .labelScan, clock: { 0 })!
    return result.controls
}

/// A stored label is shown on a live control only when exactly one control still looks like the one it was approved for.
/// "Looks like" is the anchor: roles, place among same-role siblings, text near it, help, and where it sits in the window.
/// A label that vanishes is acceptable. A label on the wrong control is not.
final class LabelAnchorResolutionTests: XCTestCase {
    static let frame = anchorTestFrame

    typealias Spec = AnchorSpec

    func controls(_ specs: [Spec], nearby: String = "Tools", window: CGRect = frame) -> [Control] {
        anchorControls(specs, nearby: nearby, window: window)
    }

    func tag(_ c: Control) -> String? { c.actions.first { $0.hasPrefix("t") || $0.hasPrefix("n") } }

    /// What the person approved: a label "L<tag>" for every flagged control, with its anchor.
    func approve(_ cs: [Control], window: CGRect = frame) -> [StoredLabel] {
        let scan = LabelScanner.scan(controls: cs, windowFrame: window, truncated: false)
        return scan.candidates.map { cand in
            let t = cs.first { $0.pathID == cand.pathID }.flatMap(tag) ?? "?"
            return StoredLabel(fingerprint: cand.fingerprint, label: "L\(t)", anchor: cand.anchor)
        }
    }

    /// tag -> the label the control now carries.
    func resolve(_ stored: [StoredLabel], _ cs: [Control], window: CGRect = frame) -> [String: String] {
        var out: [String: String] = [:]
        for c in LabelOverlayResolver.apply(to: cs, windowFrame: window, labels: stored) where !c.overlayLabel.isEmpty {
            if let t = tag(c) { out[t] = c.overlayLabel }
        }
        return out
    }

    func neverOnTheWrongControl(_ resolved: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        for (t, label) in resolved { XCTAssertEqual(label, "L" + t, "\(t) was given \(label)", file: file, line: line) }
    }

    /// Each button has a hint of its own (nothing else tells unnamed buttons of one group apart).
    let three = [Spec(tag: "t0", x: 20, help: "Starts playback"), Spec(tag: "t1", x: 220, help: "Stops playback"), Spec(tag: "t2", x: 420, help: "Skips ahead")]

    func testEveryLabelComesBackOnTheSameWindow() {
        let stored = approve(controls(three))
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(resolve(stored, controls(three)), ["t0": "Lt0", "t1": "Lt1", "t2": "Lt2"])
    }

    func testASiblingInsertedBeforeNeverMovesALabelToAnotherControl() {
        let stored = approve(controls(three))
        let live = controls([Spec(tag: "n1", x: 5, help: "Brand new")] + three)
        let resolved = resolve(stored, live)
        neverOnTheWrongControl(resolved)
        XCTAssertNil(resolved["n1"], "the new control has no label")
        XCTAssertEqual(resolved, [:], "with a same-role sibling added the paths no longer mean what they did, so nothing is shown")
    }

    func testASiblingInsertedAfterNeverMovesALabelToAnotherControl() {
        let stored = approve(controls(three))
        let resolved = resolve(stored, controls(three + [Spec(tag: "n1", x: 520, help: "Brand new")]))
        neverOnTheWrongControl(resolved)
        XCTAssertNil(resolved["n1"])
    }

    func testASiblingInsertedInTheMiddleNeverMovesALabelToAnotherControl() {
        let stored = approve(controls(three))
        let live = controls([three[0], Spec(tag: "n1", x: 120, help: "Brand new"), three[1], three[2]])
        let resolved = resolve(stored, live)
        neverOnTheWrongControl(resolved)
        XCTAssertNil(resolved["n1"])
    }

    func testASiblingRemovedNeverMovesALabelToAnotherControl() {
        let stored = approve(controls(three))
        for removed in 0..<3 {
            var left = three
            left.remove(at: removed)
            let resolved = resolve(stored, controls(left))
            neverOnTheWrongControl(resolved)
            XCTAssertEqual(resolved, [:], "removing t\(removed) changes the sibling count, so nothing is shown")
        }
    }

    func testTwoIdenticalControlsThatSwapPlacesDoNotSwapTheirLabels() {
        let stored = approve(controls(three))
        let swapped = controls([three[1], three[0], three[2]])
        neverOnTheWrongControl(resolve(stored, swapped))
    }

    func testTheTextNearTheControlMustStillAgree() {
        let stored = approve(controls(three))
        XCTAssertEqual(resolve(stored, controls(three, nearby: "Something else")), [:])
        XCTAssertEqual(resolve(stored, controls(three, nearby: "Tools")).count, 3)
    }

    func testDigitsInTheNearbyTextDoNotMatter() {
        let stored = approve(controls(three, nearby: "3 items"))
        XCTAssertEqual(resolve(stored, controls(three, nearby: "14 items")).count, 3)
    }

    func testTheHelpTextMustStillAgree() {
        let stored = approve(controls([Spec(tag: "t0", x: 20, help: "Starts it")]))
        XCTAssertEqual(resolve(stored, controls([Spec(tag: "t0", x: 20, help: "Starts it")])).count, 1)
        XCTAssertEqual(resolve(stored, controls([Spec(tag: "t0", x: 20, help: "Does something else")])), [:])
    }

    // MARK: resize and move

    func testMovingTheWindowKeepsTheLabels() {
        let stored = approve(controls(three))
        let moved = CGRect(x: -900, y: 300, width: 600, height: 800)
        XCTAssertEqual(resolve(stored, controls(three, window: moved), window: moved).count, 3)
    }

    func testResizingTheWindowKeepsTheLabels() {
        let stored = approve(controls(three))
        for size in [CGSize(width: 800, height: 900), CGSize(width: 520, height: 700), CGSize(width: 1000, height: 800)] {
            let bigger = CGRect(x: 100, y: 100, width: size.width, height: size.height)
            XCTAssertEqual(resolve(stored, controls(three, window: bigger), window: bigger), ["t0": "Lt0", "t1": "Lt1", "t2": "Lt2"], "\(size)")
        }
    }

    func testAControlThatIsSomewhereElseEntirelyKeepsNoLabel() {
        let stored = approve(controls([Spec(tag: "t0", x: 20)]))
        let bigger = CGRect(x: 100, y: 100, width: 800, height: 800)
        XCTAssertEqual(resolve(stored, controls([Spec(tag: "t0", x: 740)], window: bigger), window: bigger), [:])
    }

    // MARK: identifiers

    func testAnIdentifierKeepsItsLabelWhereverTheControlGoes() {
        let a = [Spec(tag: "t0", x: 20, identifier: "play"), Spec(tag: "t1", x: 220, identifier: "stop")]
        let stored = approve(controls(a))
        let reordered = controls([Spec(tag: "n0", x: 20, identifier: "other"), Spec(tag: "t1", x: 220, identifier: "stop"), Spec(tag: "t0", x: 40, identifier: "play")])
        let resolved = resolve(stored, reordered)
        XCTAssertEqual(resolved["t0"], "Lt0")
        XCTAssertEqual(resolved["t1"], "Lt1")
        XCTAssertNil(resolved["n0"])
    }

    func testTwoFlaggedControlsWithOneIdentifierAreNeitherProposedNorStored() {
        let specs = [Spec(tag: "t0", x: 20, identifier: "dup"), Spec(tag: "t1", x: 220, identifier: "dup"), Spec(tag: "t2", x: 420, identifier: "solo")]
        let scan = LabelScanner.scan(controls: controls(specs), windowFrame: Self.frame, truncated: false)
        XCTAssertEqual(scan.candidates.map { $0.identifier }, ["solo"])
        XCTAssertEqual(scan.candidates.map { $0.id }, [1])
        XCTAssertEqual(scan.duplicatesSkipped, 2)
        XCTAssertEqual(scan.entries.filter { $0.duplicate }.map { $0.identifier }, ["dup", "dup"])
        XCTAssertEqual(scan.entries.filter { $0.flagged }.count, 3, "they are still counted as unlabeled")
        let inputs = scan.candidates.map { LabelModelInput(candidate: $0) }
        XCTAssertEqual(inputs.map { $0.identifier }, ["solo"], "the model is never asked about them")
    }

    func testALabelIsNotShownWhenTwoLiveControlsShareItsIdentifier() {
        let stored = approve(controls([Spec(tag: "t0", x: 20, identifier: "play")]))
        XCTAssertEqual(resolve(stored, controls([Spec(tag: "t0", x: 20, identifier: "play")])), ["t0": "Lt0"])
        let twice = controls([Spec(tag: "t0", x: 20, identifier: "play"), Spec(tag: "n1", x: 220, identifier: "play")])
        XCTAssertEqual(resolve(stored, twice), [:])
    }

    func testTheSummaryCountsTheSkippedOnes() {
        XCTAssertEqual(LabelSummary.afterApproval(found: 3, labeled: 3, kinds: ["button", "button", "button"], partial: false, skipped: 2),
                       "Found 3 unlabeled buttons. Labeled 3. Skipped 2 that cannot be told apart.")
        XCTAssertEqual(LabelSummary.afterApproval(found: 3, labeled: 3, kinds: ["button", "button", "button"], partial: true, skipped: 1),
                       "Found 3 unlabeled buttons. Labeled 3. Skipped 1 that cannot be told apart. Checked part of the window.")
        XCTAssertEqual(LabelSummary.afterApproval(found: 1, labeled: 1, kinds: ["button"], partial: false), "Found 1 unlabeled button. Labeled 1.")
    }

    // MARK: the anchor on its own

    func testAnEmptyOrMismatchedAnchorNeverAgrees() {
        let a = LabelAnchor(role: "AXButton", nearbyText: ["Tools"], help: "Does it", path: "AXWindow>AXGroup[0]>AXButton[0]", siblingCount: 1, x: 0.5, y: 0.5)
        XCTAssertTrue(LabelAnchor.agrees(stored: a, live: a))
        XCTAssertFalse(LabelAnchor.agrees(stored: .empty, live: .empty))
        var other = a; other.role = "AXCheckBox"
        XCTAssertFalse(LabelAnchor.agrees(stored: a, live: other))
        other = a; other.subrole = "AXSwitch"
        XCTAssertFalse(LabelAnchor.agrees(stored: a, live: other))
        other = a; other.siblingCount = 2
        XCTAssertFalse(LabelAnchor.agrees(stored: a, live: other))
        other = a; other.path = "AXWindow>AXGroup[1]>AXButton[0]"
        XCTAssertFalse(LabelAnchor.agrees(stored: a, live: other))
    }

    func testTheSameSizeWindowAllowsOnlyASmallShiftAndAResizedOneAllowsMore() {
        var a = LabelAnchor(role: "AXButton", nearbyText: ["Tools"], help: "Does it", siblingCount: 1, x: 0.2, y: 0.2, windowWidth: 600, windowHeight: 800)
        var live = a
        live.x = 0.26
        XCTAssertTrue(LabelAnchor.agrees(stored: a, live: live))
        live.x = 0.4
        XCTAssertFalse(LabelAnchor.agrees(stored: a, live: live), "same window size, 0.2 away")
        live.windowWidth = 900
        XCTAssertTrue(LabelAnchor.agrees(stored: a, live: live), "a resized window gets the looser guard")
        live.x = 0.9
        XCTAssertFalse(LabelAnchor.agrees(stored: a, live: live))
        a.windowWidth = 0
        live.windowWidth = 600
        live.x = 0.4
        XCTAssertTrue(LabelAnchor.agrees(stored: a, live: live), "an unknown stored size uses the looser guard")
    }
}

final class LabelLegacyStoreTests: XCTestCase {
    var dir: URL!
    var file: URL { dir.appendingPathComponent("label-overlay.json") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shep-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let d = dir, d.lastPathComponent.hasPrefix("shep-store-tests-") { try? FileManager.default.removeItem(at: d) }
    }

    func testAVersionOneFileStillLoadsWithNoAnchors() throws {
        let json = #"{"version":1,"entries":[{"bundleID":"com.a","fingerprint":"p1-abc","label":"Play","role":"AXButton","updated":"2026-11-01T00:00:00Z"},{"bundleID":"com.a","fingerprint":"i1-def","label":"Stop","role":"AXButton","updated":"2026-11-01T00:00:00Z"}]}"#
        try Data(json.utf8).write(to: file)
        let s = LabelOverlayStore(fileURL: file)
        XCTAssertEqual(s.loadState, .loaded)
        XCTAssertEqual(s.count(bundleID: "com.a"), 2)
        XCTAssertTrue(s.storedLabels(bundleID: "com.a").allSatisfy { $0.anchor == nil })
    }

    func testAnOldPositionKeyedLabelIsNeverShownButAnIdentifierKeyedOneIs() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, identifier: "play"), AnchorSpec(tag: "t1", x: 220, help: "Stops it")])
        let scan = LabelScanner.scan(controls: cs, windowFrame: anchorTestFrame, truncated: false)
        let byID = scan.candidates.first { $0.identifier == "play" }!
        let byPath = scan.candidates.first { $0.identifier.isEmpty }!
        XCTAssertTrue(byID.fingerprint.hasPrefix("i1-"))
        let legacy = [StoredLabel(fingerprint: byID.fingerprint, label: "Play", anchor: nil),
                      StoredLabel(fingerprint: "p1-\(byPath.fingerprint.dropFirst(3))", label: "Old", anchor: nil),
                      StoredLabel(fingerprint: byPath.fingerprint, label: "NoAnchor", anchor: nil)]
        let labeled = LabelOverlayResolver.apply(to: cs, windowFrame: anchorTestFrame, labels: legacy).filter { !$0.overlayLabel.isEmpty }
        XCTAssertEqual(labeled.map { $0.overlayLabel }, ["Play"])
    }

    func testAnchorsSurviveSavingAndLoading() throws {
        let anchor = LabelAnchor(role: "AXButton", subrole: "", identifier: "", nearbyText: ["Tools"], help: "tip", path: "AXWindow>AXGroup[0]>AXButton[2]",
                                 siblingCount: 3, x: 0.25, y: 0.5, windowWidth: 600, windowHeight: 800)
        let proposal = LabelProposal(id: 1, fingerprint: "p2-x", role: "AXButton", kind: "button", context: "Tools", label: "Play", confidence: 0.9, anchor: anchor)
        let approved = LabelApproval.resolve(LabelReview(bundleID: "com.a", appName: "A", proposals: [proposal]), answer: .acceptAll)!
        XCTAssertEqual(approved.items.first?.anchor, anchor)
        let s = LabelOverlayStore(fileURL: file)
        try s.apply(approved)
        let back = LabelOverlayStore(fileURL: file).storedLabels(bundleID: "com.a")
        XCTAssertEqual(back, [StoredLabel(fingerprint: "p2-x", label: "Play", anchor: anchor)])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(object["version"] as? Int, 3)
    }

    func testProposalsCarryTheCandidatesAnchor() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Starts it")])
        let scan = LabelScanner.scan(controls: cs, windowFrame: anchorTestFrame, truncated: false)
        let proposals = LabelProposals.make(candidates: scan.candidates, suggestions: [LabelSuggestion(id: 1, label: "Play", confidence: 0.9)],
                                            windowSize: anchorTestFrame.size)
        XCTAssertEqual(proposals.first?.anchor, scan.candidates.first?.anchor)
        XCTAssertFalse(scan.candidates[0].anchor.isEmpty)
    }
}
