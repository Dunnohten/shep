import CoreGraphics
import XCTest
@testable import ShepCore

final class LabelApprovalTests: XCTestCase {
    func proposals() -> [LabelProposal] {
        [
            LabelProposal(id: 1, fingerprint: "f1", role: "AXButton", kind: "button", context: "Playback", label: "Play", confidence: 0.9, anchor: storableAnchor()),
            LabelProposal(id: 2, fingerprint: "f2", role: "AXCheckBox", kind: "checkbox", context: "Remember", label: "Remember me", confidence: 0.75, anchor: storableAnchor()),
            LabelProposal(id: 3, fingerprint: "f3", role: "AXLink", kind: "link", context: "the top left", label: "More", confidence: 0.4, anchor: storableAnchor()),
        ]
    }

    func review() -> LabelReview { LabelReview(bundleID: "com.example.app", appName: "Example", proposals: proposals()) }

    func testProposalsAloneWriteNothing() throws {
        let store = LabelOverlayStore(fileURL: tempFile())
        let r = review()
        _ = r.cardText
        XCTAssertEqual(store.count(bundleID: "com.example.app"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testNoApprovalWithoutAnAnswer() {
        XCTAssertNil(LabelApproval.resolve(review(), answer: nil), "Escape or a dismissed card is not an approval")
        XCTAssertNil(LabelApproval.resolve(review(), answer: .cancel))
    }

    func testAcceptAllApprovesEveryProposalWithItsLabel() throws {
        let approved = try XCTUnwrap(LabelApproval.resolve(review(), answer: .acceptAll))
        XCTAssertEqual(approved.bundleID, "com.example.app")
        XCTAssertEqual(approved.items.map { $0.fingerprint }, ["f1", "f2", "f3"])
        XCTAssertEqual(approved.items.map { $0.label }, ["Play", "Remember me", "More"])
        XCTAssertEqual(approved.items.map { $0.edited }, [false, false, false])
    }

    func testRejectedItemsAreNotApprovedAndNotStored() throws {
        var r = review()
        r.reject(2)
        let approved = try XCTUnwrap(LabelApproval.resolve(r, answer: .acceptAll))
        XCTAssertEqual(approved.items.map { $0.fingerprint }, ["f1", "f3"])
        let store = LabelOverlayStore(fileURL: tempFile())
        try store.apply(approved)
        XCTAssertNil(store.label(bundleID: "com.example.app", fingerprint: "f2"))
        XCTAssertEqual(store.count(bundleID: "com.example.app"), 2)
    }

    func testEditReplacesTheLabelAndMarksItEdited() throws {
        var r = review()
        XCTAssertTrue(r.edit(1, to: "  Play / pause "))
        let approved = try XCTUnwrap(LabelApproval.resolve(r, answer: .acceptAll))
        XCTAssertEqual(approved.items[0].label, "Play / pause")
        XCTAssertTrue(approved.items[0].edited)
        XCTAssertEqual(approved.items[1].label, "Remember me")
    }

    func testAnEditThatIsNotAGoodLabelIsRefusedAndTheOldLabelStays() throws {
        var r = review()
        XCTAssertFalse(r.edit(1, to: "button"))
        XCTAssertFalse(r.edit(1, to: "https://x.example"))
        XCTAssertFalse(r.edit(1, to: ""))
        XCTAssertFalse(r.edit(99, to: "Fine"))
        let approved = try XCTUnwrap(LabelApproval.resolve(r, answer: .acceptAll))
        XCTAssertEqual(approved.items[0].label, "Play")
    }

    func testRejectingEverythingLeavesNothingToApprove() {
        var r = review()
        for id in [1, 2, 3] { r.reject(id) }
        XCTAssertNil(LabelApproval.resolve(r, answer: .acceptAll))
        XCTAssertEqual(r.activeProposals.count, 0)
    }

    func testAcceptedCountIsAcceptedPlusEdited() {
        var r = review()
        r.reject(3)
        _ = r.edit(1, to: "Play")
        XCTAssertEqual(r.activeProposals.count, 2)
    }

    func testCardTextListsEveryProposalInTheAgreedShape() {
        let text = review().cardText
        XCTAssertTrue(text.contains("1. button near Playback: Play (0.90)"), text)
        XCTAssertTrue(text.contains("2. checkbox near Remember: Remember me (0.75)"), text)
        XCTAssertTrue(text.contains("3. link near the top left: More (0.40)"), text)
        XCTAssertTrue(text.contains("3 labels"), text)
        XCTAssertFalse(text.contains("\n\n\n"))
    }

    func testCardShowsRejectedItemsAsRemovedAndEditedItemsWithTheirNewLabel() {
        var r = review()
        r.reject(2)
        _ = r.edit(1, to: "Play / pause")
        let text = r.cardText
        XCTAssertTrue(text.contains("Play / pause"))
        XCTAssertFalse(text.contains("Remember me"))
        XCTAssertTrue(text.contains("2 labels"))
    }

    func testCardActionsParseFromChoiceIdsAndNothingElse() {
        XCTAssertEqual(LabelCardAction.parse("accept-all"), .answer(.acceptAll))
        XCTAssertEqual(LabelCardAction.parse("cancel"), .answer(.cancel))
        XCTAssertEqual(LabelCardAction.parse("reject-one"), .pick(.reject))
        XCTAssertEqual(LabelCardAction.parse("edit-one"), .pick(.edit))
        XCTAssertEqual(LabelCardAction.parse("reject:2"), .reject(2))
        XCTAssertEqual(LabelCardAction.parse("edit:3"), .edit(3))
        XCTAssertEqual(LabelCardAction.parse("back"), .back)
        XCTAssertEqual(LabelCardAction.parse("page:2"), .page(2))
        XCTAssertNil(LabelCardAction.parse("approve"))
        XCTAssertNil(LabelCardAction.parse("reject:x"))
        XCTAssertNil(LabelCardAction.parse(nil))
        XCTAssertNil(LabelCardAction.parse("accept-all "))
    }

    func testMainCardHasAcceptAllEditRejectCancelAndCancelIsPresent() {
        let card = LabelCardBuilder.main(review())
        XCTAssertEqual(card.choices.map { $0.id }, ["accept-all", "edit-one", "reject-one", "cancel"])
        XCTAssertEqual(card.choices[0].label, "Accept all (3)")
        XCTAssertTrue(card.title.contains("Example"))
    }

    func testPickerListsItemsWithPagingAndABackButton() {
        var ps: [LabelProposal] = []
        for i in 1...12 { ps.append(LabelProposal(id: i, fingerprint: "f\(i)", role: "AXButton", kind: "button", context: "c\(i)", label: "L\(i)x", confidence: 0.5)) }
        let r = LabelReview(bundleID: "b", appName: "A", proposals: ps)
        let page0 = LabelCardBuilder.picker(r, mode: .reject, page: 0)
        XCTAssertEqual(LabelCardBuilder.pageSize, 2)
        XCTAssertEqual(page0.choices.map { $0.id }, ["reject:1", "reject:2", "page:1", "back"])
        XCTAssertTrue(page0.text.contains("(page 1 of 6)"))
        let page1 = LabelCardBuilder.picker(r, mode: .edit, page: 1)
        XCTAssertEqual(page1.choices.map { $0.id }, ["edit:3", "edit:4", "page:2", "page:0", "back"])
        let last = LabelCardBuilder.picker(r, mode: .edit, page: 99)
        XCTAssertEqual(last.choices.map { $0.id }, ["edit:11", "edit:12", "page:4", "back"])
        XCTAssertTrue(last.text.contains("(page 6 of 6)"))
    }

    func testEveryLabelIsReachableThroughThePickerPages() {
        var ps: [LabelProposal] = []
        for i in 1...13 { ps.append(LabelProposal(id: i, fingerprint: "f\(i)", role: "AXButton", kind: "button", context: "c", label: "L\(i)x", confidence: 0.5)) }
        let r = LabelReview(bundleID: "b", appName: "A", proposals: ps)
        var seen: [String] = []
        var page = 0
        while true {
            let card = LabelCardBuilder.picker(r, mode: .reject, page: page)
            let items = card.choices.filter { $0.id.hasPrefix("reject:") }
            XCTAssertLessThanOrEqual(items.count, LabelCardBuilder.pageSize)
            seen += items.map { $0.id }
            XCTAssertTrue(card.choices.contains { $0.id == "back" })
            guard let more = card.choices.first(where: { $0.label == "More\u{2026}" }), case .page(let n)? = LabelCardAction.parse(more.id) else { break }
            page = n
        }
        XCTAssertEqual(seen, (1...13).map { "reject:\($0)" })
    }

    func testFlowAppliesRejectAndEditFromCardActions() {
        var r = review()
        XCTAssertEqual(LabelCardFlow.apply(.reject(2), to: &r), .stay)
        XCTAssertEqual(r.activeProposals.map { $0.id }, [1, 3])
        XCTAssertEqual(LabelCardFlow.apply(.edit(1), to: &r), .needsText(1))
        XCTAssertEqual(LabelCardFlow.apply(.answer(.cancel), to: &r), .finish(.cancel))
    }

    // MARK: helpers

    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shep-label-tests-\(UUID().uuidString)").appendingPathComponent("label-overlay.json")
    }
}

final class ApprovalIsTheOnlyWriterTests: XCTestCase {
    func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testOnlyTheApprovalFileCanConstructAnApprovalToken() throws {
        let dir = repoRoot().appendingPathComponent("ShepCore/Sources")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { throw XCTSkip("source tree not reachable") }
        var sawApprovalFile = false
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if url.lastPathComponent == "LabelApproval.swift" { sawApprovalFile = true; continue }
            XCTAssertFalse(text.contains("ApprovedLabels("), "\(url.lastPathComponent) builds an ApprovedLabels")
            XCTAssertFalse(text.contains("ApprovedClear("), "\(url.lastPathComponent) builds an ApprovedClear")
        }
        XCTAssertTrue(sawApprovalFile)
        let app = repoRoot().appendingPathComponent("Shep")
        if let w = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let url as URL in w where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(text.contains("ApprovedLabels("), url.lastPathComponent)
                XCTAssertFalse(text.contains("ApprovedClear("), url.lastPathComponent)
            }
        }
    }

    func testTheStoreHasNoWritePathThatTakesPlainValues() throws {
        let text = try String(contentsOf: repoRoot().appendingPathComponent("ShepCore/Sources/LabelOverlayStore.swift"), encoding: .utf8)
        // The only public mutators are apply(ApprovedLabels) and clear(ApprovedClear).
        let mutators = text.components(separatedBy: "\n").filter { $0.contains("public func ") && ($0.contains("apply") || $0.contains("clear") || $0.contains("set") || $0.contains("remove") || $0.contains("save") || $0.contains("add")) }
        XCTAssertEqual(mutators.count, 2, mutators.joined(separator: "\n"))
        XCTAssertTrue(mutators.contains { $0.contains("ApprovedLabels") })
        XCTAssertTrue(mutators.contains { $0.contains("ApprovedClear") })
    }
}
