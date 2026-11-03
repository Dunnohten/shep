import XCTest
@testable import ShepCore

final class LabelOverlayStoreTests: XCTestCase {
    var dir: URL!
    var file: URL { dir.appendingPathComponent("label-overlay.json") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shep-store-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let d = dir, d.lastPathComponent.hasPrefix("shep-store-tests-") { try? FileManager.default.removeItem(at: d) }
    }

    func approved(_ bundle: String, _ items: [(String, String)], edited: Bool = false) -> ApprovedLabels {
        var proposals: [LabelProposal] = []
        for (i, item) in items.enumerated() {
            proposals.append(LabelProposal(id: i + 1, fingerprint: item.0, role: "AXButton", kind: "button", context: "c", label: item.1, confidence: 0.9, anchor: storableAnchor()))
        }
        return LabelApproval.resolve(LabelReview(bundleID: bundle, appName: "App", proposals: proposals), answer: .acceptAll)!
    }

    func testSaveThenLoadAcrossInstances() throws {
        let a = LabelOverlayStore(fileURL: file)
        try a.apply(approved("com.a", [("f1", "Play"), ("f2", "Pause")]))
        let b = LabelOverlayStore(fileURL: file)
        XCTAssertEqual(b.label(bundleID: "com.a", fingerprint: "f1"), "Play")
        XCTAssertEqual(b.label(bundleID: "com.a", fingerprint: "f2"), "Pause")
        XCTAssertNil(b.label(bundleID: "com.b", fingerprint: "f1"))
        XCTAssertEqual(b.loadState, .loaded)
    }

    func testAFreshStoreIsEmptyAndWritesNothingUntilApproved() {
        let s = LabelOverlayStore(fileURL: file)
        XCTAssertEqual(s.loadState, .fresh)
        XCTAssertEqual(s.count(bundleID: "com.a"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLabelsAreKeyedByBundleAndFingerprint() throws {
        let s = LabelOverlayStore(fileURL: file)
        try s.apply(approved("com.a", [("f1", "Play")]))
        try s.apply(approved("com.b", [("f1", "Other")]))
        XCTAssertEqual(s.label(bundleID: "com.a", fingerprint: "f1"), "Play")
        XCTAssertEqual(s.label(bundleID: "com.b", fingerprint: "f1"), "Other")
        XCTAssertEqual(s.storedLabels(bundleID: "com.a").map { [$0.fingerprint, $0.label] }, [["f1", "Play"]])
    }

    func testApplyingAgainReplacesTheLabel() throws {
        let s = LabelOverlayStore(fileURL: file)
        try s.apply(approved("com.a", [("f1", "Play")]))
        try s.apply(approved("com.a", [("f1", "Play music")]))
        XCTAssertEqual(s.label(bundleID: "com.a", fingerprint: "f1"), "Play music")
        XCTAssertEqual(s.count(bundleID: "com.a"), 1)
    }

    func testClearRemovesOnlyThatBundleAndNeverTouchesOtherFiles() throws {
        let s = LabelOverlayStore(fileURL: file)
        try s.apply(approved("com.a", [("f1", "Play"), ("f2", "Pause")]))
        try s.apply(approved("com.b", [("f1", "Other")]))
        let other = dir.appendingPathComponent("unrelated.txt")
        try "keep".write(to: other, atomically: true, encoding: .utf8)
        let removed = try s.clear(LabelApproval.confirmClear(bundleID: "com.a", answer: .confirm)!)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(s.count(bundleID: "com.a"), 0)
        XCTAssertEqual(s.count(bundleID: "com.b"), 1)
        XCTAssertEqual(LabelOverlayStore(fileURL: file).count(bundleID: "com.a"), 0)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "keep")
    }

    func testClearNeedsAConfirmation() {
        XCTAssertNil(LabelApproval.confirmClear(bundleID: "com.a", answer: nil))
        XCTAssertNil(LabelApproval.confirmClear(bundleID: "com.a", answer: .keep))
        XCTAssertNil(LabelApproval.confirmClear(bundleID: "", answer: .confirm))
    }

    func testFileIsVersionedJSON() throws {
        let s = LabelOverlayStore(fileURL: file)
        try s.apply(approved("com.a", [("f1", "Play")]))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(object["version"] as? Int, 3)
        let entries = object["entries"] as! [[String: Any]]
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["bundleID"] as? String, "com.a")
        XCTAssertEqual(entries[0]["fingerprint"] as? String, "f1")
        XCTAssertEqual(entries[0]["label"] as? String, "Play")
    }

    func testACorruptFileLoadsEmptyAndIsNotTouchedBySimplyLoading() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let junk = Data("{ not json".utf8)
        try junk.write(to: file)
        let s = LabelOverlayStore(fileURL: file)
        XCTAssertEqual(s.count(bundleID: "com.a"), 0)
        if case .corrupt = s.loadState {} else { XCTFail("expected corrupt, got \(s.loadState)") }
        XCTAssertEqual(try Data(contentsOf: file), junk)
    }

    func testWritingOverACorruptFileKeepsAnExactCopyFirst() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let junk = Data("{ not json".utf8)
        try junk.write(to: file)
        let s = LabelOverlayStore(fileURL: file)
        let result = try s.apply(approved("com.a", [("f1", "Play")]))
        let backup = try XCTUnwrap(result.corruptBackup)
        XCTAssertEqual(try Data(contentsOf: backup), junk)
        XCTAssertEqual(LabelOverlayStore(fileURL: file).label(bundleID: "com.a", fingerprint: "f1"), "Play")
    }

    func testAFileFromANewerVersionIsTreatedAsUnreadableNotOverwrittenSilently() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let future = Data(#"{"version":99,"entries":[]}"#.utf8)
        try future.write(to: file)
        let s = LabelOverlayStore(fileURL: file)
        if case .corrupt = s.loadState {} else { XCTFail("expected an unreadable state") }
        let result = try s.apply(approved("com.a", [("f1", "Play")]))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.corruptBackup)), future)
    }

    func testTheWriteIsAtomicNoTempFileIsLeftBehind() throws {
        let s = LabelOverlayStore(fileURL: file)
        try s.apply(approved("com.a", [("f1", "Play")]))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["label-overlay.json"])
    }

    func testAFailedWriteLeavesTheStoreAndTheFileAsTheyWere() throws {
        let s = LabelOverlayStore(fileURL: file)
        try s.apply(approved("com.a", [("f1", "Play")]))
        // Make the directory unwritable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        XCTAssertThrowsError(try s.apply(approved("com.a", [("f2", "Pause")])))
        XCTAssertNil(s.label(bundleID: "com.a", fingerprint: "f2"))
        XCTAssertEqual(LabelOverlayStore(fileURL: file).label(bundleID: "com.a", fingerprint: "f1"), "Play")
    }

    func testDefaultLocationIsUnderApplicationSupportShep() {
        let url = LabelOverlayStore.defaultFileURL(home: "/Users/someone")
        XCTAssertEqual(url.path, "/Users/someone/Library/Application Support/Shep/label-overlay.json")
    }

    func testEntriesWithBadLabelsInTheFileAreIgnored() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"version":1,"entries":[{"bundleID":"com.a","fingerprint":"f1","label":"Play","role":"AXButton","updated":"2026-11-01T00:00:00Z"},{"bundleID":"com.a","fingerprint":"f2","label":"https://x.example","role":"AXButton","updated":"2026-11-01T00:00:00Z"}]}"#
        try Data(json.utf8).write(to: file)
        let s = LabelOverlayStore(fileURL: file)
        XCTAssertEqual(s.label(bundleID: "com.a", fingerprint: "f1"), "Play")
        XCTAssertNil(s.label(bundleID: "com.a", fingerprint: "f2"))
    }
}
