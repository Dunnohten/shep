import XCTest
@testable import ShepCore

/// A VoiceOver user meets an approval card the way a sighted user does: the question first, then Approve one VO-Right away,
/// then Deny. Keyboard focus stays on Deny (a stray Return or Space never approves) and Escape still cancels.
final class CardVoiceOverOrderTests: XCTestCase {
    private let line = "Press the checkbox \"Speed Limit\"?"
    private func card(_ choices: [(id: String, label: String)] = Brief.approvalChoices, text: String? = nil) -> CardModel {
        CardModel.approval(text: text ?? line, choices: choices, title: "Shep wants to press Speed Limit in Transmission")
    }

    func testVoiceOverStartsOnTheCardText() {
        XCTAssertEqual(card().initialVoiceOverFocus, .text)
    }

    func testApproveIsOneVORightAfterTheText() {
        XCTAssertEqual(card().accessibilityOrder, [.text, .button("approve"), .button("cancel")])
        let order = card().accessibilityOrder
        XCTAssertEqual(order.firstIndex(of: .button("approve")), order.firstIndex(of: .text)! + 1)
    }

    func testTheOrderFollowsTheButtonsAsShownWhateverOrderTheyCameIn() {
        let reversed = [(id: "cancel", label: "Deny"), (id: "approve", label: "Approve")]
        XCTAssertEqual(card(reversed).accessibilityOrder, [.text, .button("cancel"), .button("approve")])
        let blank = [(id: "approve", label: "Approve"), (id: "cancel", label: " ")]
        XCTAssertEqual(card(blank).accessibilityOrder, [.text, .button("approve")])   // a hidden button is not in the order
    }

    func testKeyboardFocusStartsOnTheTextSoVoiceOverFollowingItReadsTheQuestion() {
        // VoiceOver follows keyboard focus (a layoutChanged hint alone did not move it, checked live), so the text takes it.
        XCTAssertEqual(card().initialKeyboardFocus, .text)
        XCTAssertEqual(card(text: " ").initialKeyboardFocus, .button("cancel"))   // no text: the safe button, as before
        XCTAssertNil(card([(id: "approve", label: "Approve")], text: "").initialKeyboardFocus)   // never Approve
        XCTAssertNil(CardModel.reply("Done.", milliseconds: 1000).initialKeyboardFocus)
    }

    func testKeyboardSafetyIsUnchanged() {
        let m = card()
        XCTAssertEqual(m.initialFocusID, "cancel")   // keyboard focus: Deny
        XCTAssertNotEqual(m.initialVoiceOverFocus, .button("approve"))   // VoiceOver never starts on Approve
        XCTAssertEqual(m.kind.escapeResult, .cancelChoice)
        XCTAssertTrue(m.buttons.allSatisfy { $0.spec.keyEquivalent.isEmpty })   // no default button
        XCTAssertEqual(m.buttons.first { $0.label == "Deny" }?.id, "cancel")
        XCTAssertEqual(m.buttons.first { $0.id == "cancel" }?.role, .cancel)
    }

    func testTheTextIsReadByTheFocusMoveNotByASecondAnnouncement() {
        // VoiceOver reads the text when its cursor lands there; announcing the same card as well would talk over it.
        XCTAssertNil(card().announcement)
    }

    func testAnEmptyTextFallsBackToTheSafeButton() {
        let m = card(text: "  ")
        XCTAssertEqual(m.initialVoiceOverFocus, .button("cancel"))
        XCTAssertFalse(m.accessibilityOrder.contains(.text))
        let noCancel = card([(id: "approve", label: "Approve")], text: "")
        XCTAssertNil(noCancel.initialVoiceOverFocus)   // never Approve
    }

    func testOtherCardsDoNotMoveVoiceOver() {
        XCTAssertNil(CardModel.reply("Done.", milliseconds: 1000).initialVoiceOverFocus)
        XCTAssertNil(CardModel.transcript("hey").initialVoiceOverFocus)
        XCTAssertNil(CardModel.askField.initialVoiceOverFocus)
    }
}
