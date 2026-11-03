import CoreGraphics
import XCTest
@testable import ShepCore

/// Labels are kept per app, so a label also records which kind of window it was approved in. It is shown only in a window of that kind, and
/// when more than one open window of the app is of that kind, nothing is applied (Shep reads only the target window, so it cannot check
/// that the control would not also resolve in the other one). A label that vanishes is acceptable; a label on the wrong window is not.
final class WindowSignatureTests: XCTestCase {
    func testTitleClassIgnoresDocumentNames() {
        XCTAssertEqual(WindowSignature.titleClass(of: "Report.docx"), "")
        XCTAssertEqual(WindowSignature.titleClass(of: "Report.docx \u{2014} Edited"), "")
        XCTAssertEqual(WindowSignature.titleClass(of: "Untitled 3"), "")
        XCTAssertEqual(WindowSignature.titleClass(of: "Untitled"), "")
        XCTAssertEqual(WindowSignature.titleClass(of: "~/Documents/notes"), "")
        XCTAssertEqual(WindowSignature.titleClass(of: ""), "")
        XCTAssertEqual(WindowSignature.titleClass(of: "Settings"), "settings")
        XCTAssertEqual(WindowSignature.titleClass(of: "  Inspector  "), "inspector")
        XCTAssertEqual(WindowSignature.titleClass(of: "Budget.xlsx \u{2013} Spreadsheets"), "spreadsheets", "the app or section part stays")
        XCTAssertEqual(WindowSignature.titleClass(of: "Notes - Inbox 12"), "inbox #", "digits are blurred")
        XCTAssertEqual(WindowSignature.titleClass(of: "How to bake a very good loaf of bread at home"), "long", "a long title is content")
    }

    func testAnIdentifierDecidesAloneOtherwiseSubroleAndTitleClass() {
        let main = WindowSignature(identifier: "main", subrole: "AXStandardWindow", title: "A")
        XCTAssertTrue(main.matches(WindowSignature(identifier: "main", subrole: "AXDialog", title: "Z")))
        XCTAssertFalse(main.matches(WindowSignature(identifier: "prefs", subrole: "AXStandardWindow", title: "A")))
        XCTAssertFalse(main.matches(WindowSignature(identifier: "", subrole: "AXStandardWindow", title: "A")))
        let byTitle = WindowSignature(identifier: "", subrole: "AXStandardWindow", title: "Inspector")
        XCTAssertTrue(byTitle.matches(WindowSignature(identifier: "", subrole: "AXStandardWindow", title: "Inspector")))
        XCTAssertTrue(byTitle.matches(WindowSignature(identifier: "later-added", subrole: "AXStandardWindow", title: "Inspector")))
        XCTAssertFalse(byTitle.matches(WindowSignature(identifier: "", subrole: "AXStandardWindow", title: "Settings")))
        XCTAssertFalse(byTitle.matches(WindowSignature(identifier: "", subrole: "AXFloatingWindow", title: "Inspector")))
        XCTAssertFalse(WindowSignature.empty.matches(.empty), "a window nothing identifies matches nothing")
        XCTAssertTrue(WindowSignature(identifier: " main ", subrole: "", titleClass: "").identifier == "main", "trimmed")
    }

    func testTheSignatureSurvivesJSON() throws {
        let sig = WindowSignature(identifier: "main", subrole: "AXStandardWindow", title: "Report.docx")
        let back = try JSONDecoder().decode(WindowSignature.self, from: JSONEncoder().encode(sig))
        XCTAssertEqual(back, sig)
        XCTAssertEqual(sig.titleClass, "", "the document name is not kept")
    }

    func testTheReaderCarriesTheWindowIdentifierToEveryControl() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Starts it")], windowTitle: "Inspector", windowSubrole: "AXFloatingWindow", windowIdentifier: "insp")
        XCTAssertTrue(cs.allSatisfy { $0.windowIdentifier == "insp" && $0.windowSubrole == "AXFloatingWindow" && $0.window == "Inspector" })
        let scan = LabelScanner.scan(controls: cs, windowFrame: anchorTestFrame, truncated: false)
        XCTAssertEqual(scan.window, WindowSignature(identifier: "insp", subrole: "AXFloatingWindow", title: "Inspector"))
        XCTAssertEqual(scan.candidates.first?.anchor.window, scan.window)
        XCTAssertEqual(AXWindowInfo(title: "T", subrole: "AXStandardWindow", identifier: "w1").signature.identifier, "w1")
    }

    func testAWindowNothingIdentifiesStoresNoSignature() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, help: "Starts it")], windowTitle: "", windowSubrole: "")
        let scan = LabelScanner.scan(controls: cs, windowFrame: anchorTestFrame, truncated: false)
        XCTAssertTrue(scan.window.isEmpty)
        XCTAssertEqual(scan.candidates.count, 1)
        XCTAssertNil(scan.candidates[0].anchor.window)
    }
}

final class LabelWindowResolutionTests: XCTestCase {
    static let frame = anchorTestFrame
    let specs = [AnchorSpec(tag: "t0", x: 20, help: "Starts playback"), AnchorSpec(tag: "t1", x: 220, help: "Stops playback")]

    func live(title: String = "Inspector", subrole: String = "AXStandardWindow", id: String = "") -> [Control] {
        anchorControls(specs, windowTitle: title, windowSubrole: subrole, windowIdentifier: id)
    }

    func tags(_ cs: [Control]) -> [String: String] {
        var out: [String: String] = [:]
        for c in cs where !c.overlayLabel.isEmpty { if let t = c.actions.first(where: { $0.hasPrefix("t") }) { out[t] = c.overlayLabel } }
        return out
    }

    func approve(_ cs: [Control]) -> [StoredLabel] {
        LabelScanner.scan(controls: cs, windowFrame: Self.frame, truncated: false).candidates.map { c in
            StoredLabel(fingerprint: c.fingerprint, label: "L" + c.help.prefix(2), anchor: c.anchor)
        }
    }

    func resolve(_ stored: [StoredLabel], _ cs: [Control], open: [WindowSignature?]? = nil) -> [String: String] {
        tags(LabelOverlayResolver.apply(to: cs, windowFrame: Self.frame, labels: stored, openWindows: open))
    }

    func sig(_ cs: [Control]) -> WindowSignature { LabelScanner.scan(controls: cs, windowFrame: Self.frame, truncated: false).window }

    let both = ["t0": "LSt", "t1": "LSt"]

    // MARK: two windows with one layout

    func testALabelIsShownOnlyInAWindowOfItsKind() {
        let stored = approve(live(id: "main"))
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(resolve(stored, live(id: "main")).count, 2)
        XCTAssertEqual(resolve(stored, live(id: "prefs")), [:], "the same layout under another window identifier")
        XCTAssertEqual(resolve(stored, live(id: "")), [:])
    }

    func testWithNoIdentifierTheSubroleAndTitleClassTellWindowsApart() {
        let stored = approve(live(title: "Inspector"))
        XCTAssertEqual(resolve(stored, live(title: "Inspector")).count, 2)
        XCTAssertEqual(resolve(stored, live(title: "Settings")), [:])
        XCTAssertEqual(resolve(stored, live(title: "Inspector", subrole: "AXFloatingWindow")), [:])
    }

    func testDocumentNamesDoNotMakeTwoDocumentWindowsDifferent() {
        let stored = approve(live(title: "Report.docx \u{2014} Edited"))
        XCTAssertEqual(resolve(stored, live(title: "Budget.xlsx")).count, 2, "a single document window of the same kind keeps the label")
    }

    func testTwoOpenWindowsOfOneKindApplyNothing() {
        let a = live(title: "Report.docx")
        let b = live(title: "Budget.docx")
        let stored = approve(a)
        let open: [WindowSignature?] = [sig(a), sig(b)]
        XCTAssertEqual(sig(a), sig(b), "two document windows are one kind")
        XCTAssertEqual(resolve(stored, a, open: open), [:], "which of the two was it for?")
        XCTAssertEqual(resolve(stored, b, open: open), [:])
        XCTAssertEqual(resolve(stored, a, open: [sig(a)]).count, 2, "with the other one closed the label returns")
    }

    func testOtherKindsOfWindowOpenAtTheSameTimeDoNotBlockIt() {
        let doc = live(title: "Report.docx")
        let prefs = live(title: "Settings")
        let sheet = live(title: "", subrole: "AXSheet")
        let stored = approve(doc)
        XCTAssertEqual(resolve(stored, doc, open: [sig(doc), sig(prefs), sig(sheet)]).count, 2)
    }

    func testTwoWindowsWithOneIdentifierEachAreTwoKindsAndKeepTheirOwnLabels() {
        let a = live(id: "left"), b = live(id: "right")
        let stored = approve(a)
        XCTAssertEqual(resolve(stored, a, open: [sig(a), sig(b)]).count, 2)
        XCTAssertEqual(resolve(stored, b, open: [sig(a), sig(b)]), [:])
    }

    func testAWindowTheReaderDidNotExamineMightBeTheSameKind() {
        let a = live(title: "Report.docx")
        XCTAssertEqual(resolve(approve(a), a, open: [sig(a), nil]), [:])
    }

    // MARK: labels saved before windows were told apart

    func legacy(_ cs: [Control]) -> [StoredLabel] {
        approve(cs).map { l in
            var anchor = l.anchor!
            anchor.window = nil
            return StoredLabel(fingerprint: l.fingerprint, label: l.label, anchor: anchor)
        }
    }

    func testALabelWithNoWindowSignatureNeedsExactlyOneStandardWindow() {
        let cs = live()
        let stored = legacy(cs)
        XCTAssertEqual(resolve(stored, cs, open: [sig(cs)]).count, 2, "one standard window")
        XCTAssertEqual(resolve(stored, cs, open: [sig(cs), sig(live(title: "Other"))]), [:], "two standard windows")
        XCTAssertEqual(resolve(stored, cs, open: [sig(cs), sig(live(title: "", subrole: "AXSheet"))]).count, 2, "a sheet is not a standard window")
        XCTAssertEqual(resolve(stored, cs, open: [sig(cs), nil]), [:], "a window that was not examined")
        let floating = live(subrole: "AXFloatingWindow")
        XCTAssertEqual(resolve(legacy(floating), floating, open: [sig(floating)]), [:], "the live window is not a standard window")
    }

    func testAnOldIdentifierKeyedLabelWithNoAnchorFollowsTheSameRule() {
        let cs = anchorControls([AnchorSpec(tag: "t0", x: 20, identifier: "play")])
        let c = LabelScanner.scan(controls: cs, windowFrame: Self.frame, truncated: false).candidates[0]
        let v1 = [StoredLabel(fingerprint: c.fingerprint, label: "Play", anchor: nil)]
        XCTAssertEqual(resolve(v1, cs, open: [sig(cs)]).count, 1)
        XCTAssertEqual(resolve(v1, cs, open: [sig(cs), sig(live(title: "Other"))]), [:], "a version 1 entry with two windows open")
    }

    // MARK: the store keeps one label per control per kind of window

    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shep-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let d = dir, d.lastPathComponent.hasPrefix("shep-store-tests-") { try? FileManager.default.removeItem(at: d) }
    }

    func approved(_ cs: [Control], label: String) throws -> ApprovedLabels {
        let scan = LabelScanner.scan(controls: cs, windowFrame: Self.frame, truncated: false)
        let proposals = scan.candidates.map { c in
            LabelProposal(id: c.id, fingerprint: c.fingerprint, role: c.role, kind: c.kind, context: "x", label: label, confidence: 0.9, anchor: c.anchor)
        }
        return try XCTUnwrap(LabelApproval.resolve(LabelReview(bundleID: "com.a", appName: "A", proposals: proposals), answer: .acceptAll))
    }

    func testTheSameControlInTwoKindsOfWindowKeepsTwoLabelsAndASecondApprovalReplacesOnlyItsOwn() throws {
        let file = dir.appendingPathComponent("label-overlay.json")
        let store = LabelOverlayStore(fileURL: file)
        try store.apply(approved(live(id: "main"), label: "Main one"))
        try store.apply(approved(live(id: "prefs"), label: "Prefs one"))
        XCTAssertEqual(store.count(bundleID: "com.a"), 4)
        try store.apply(approved(live(id: "main"), label: "Main two"))
        XCTAssertEqual(store.count(bundleID: "com.a"), 4)
        let labels = LabelOverlayStore(fileURL: file).storedLabels(bundleID: "com.a")
        XCTAssertEqual(Set(labels.map { $0.label }), ["Main two", "Prefs one"])
        XCTAssertEqual(Set(labels.compactMap { $0.anchor?.window?.identifier }), ["main", "prefs"])
        let cs = live(id: "prefs")
        XCTAssertEqual(tags(LabelOverlayResolver.apply(to: cs, windowFrame: Self.frame, labels: labels)).values.sorted(), ["Prefs one", "Prefs one"])
    }

    func testAVersionTwoFileLoadsWithNoWindowAndTheFileIsWrittenAsVersionThree() throws {
        let file = dir.appendingPathComponent("label-overlay.json")
        let json = #"{"version":2,"entries":[{"bundleID":"com.a","fingerprint":"p2-abc","label":"Play","role":"AXButton","updated":"2026-11-01T00:00:00Z","anchor":{"role":"AXButton","subrole":"","identifier":"","nearbyText":["Tools"],"help":"","path":"AXWindow>AXGroup[0]>AXButton[0]","siblingCount":1,"x":0.1,"y":0.1,"windowWidth":600,"windowHeight":800}}]}"#
        try Data(json.utf8).write(to: file)
        let store = LabelOverlayStore(fileURL: file)
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertNil(store.storedLabels(bundleID: "com.a").first?.anchor?.window)
        try store.apply(approved(live(id: "main"), label: "New"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(object["version"] as? Int, 3)
        XCTAssertEqual(store.count(bundleID: "com.a"), 3, "the old entry stays; the new ones are for their own window")
    }
}
