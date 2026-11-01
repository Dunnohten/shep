import CoreGraphics
import XCTest
@testable import ShepCore

final class CardModelTests: XCTestCase {
    private let yesNo = [(id: "approve", label: "Approve"), (id: "cancel", label: "Cancel")]

    // MARK: approval

    func testApprovalCardKeepsTheTitleAndNamesTheDialogForVoiceOver() {
        let m = CardModel.approval(text: "Press Save in TextEdit.", choices: yesNo, title: "Shep wants to press Save in TextEdit")
        XCTAssertEqual(m.kind, .approval)
        XCTAssertEqual(m.accessibilityTitle, "Shep wants to press Save in TextEdit")
        XCTAssertEqual(m.text, "Press Save in TextEdit.")
        XCTAssertEqual(m.buttons.map(\.id), ["approve", "cancel"])
        XCTAssertEqual(m.buttons.map(\.label), ["Approve", "Cancel"])
    }

    func testApprovalIsReadByMovingVoiceOverToItsTextNotByAnAnnouncement() {
        let m = CardModel.approval(text: "x", choices: yesNo, title: "Shep wants to press Save in TextEdit")
        XCTAssertNil(m.announcement)
        XCTAssertEqual(m.initialVoiceOverFocus, .text)
    }

    func testTitleFallsBackToTheFirstLineThenToAFixedLine() {
        XCTAssertEqual(CardModel.approval(text: "Press Save.\nIt is in the toolbar.", choices: yesNo, title: "  ").accessibilityTitle, "Press Save.")
        XCTAssertEqual(CardModel.approval(text: "", choices: yesNo, title: "").accessibilityTitle, "Shep needs your approval")
        XCTAssertEqual(CardModel.approval(text: "\n\nlater", choices: yesNo, title: "").accessibilityTitle, "Shep needs your approval")
    }

    func testFocusStartsOnCancelSoAStrayEnterOrSpaceNeverApproves() {
        XCTAssertEqual(CardModel.approval(text: "x", choices: yesNo, title: "t").initialFocusID, "cancel")
        let reversed = [(id: "cancel", label: "Cancel"), (id: "approve", label: "Approve")]
        XCTAssertEqual(CardModel.approval(text: "x", choices: reversed, title: "t").initialFocusID, "cancel")
        XCTAssertNil(CardModel.approval(text: "x", choices: [], title: "t").initialFocusID)
    }

    func testWithoutACancelButtonNothingTakesFocusSoApproveIsNeverFirst() {
        XCTAssertNil(CardModel.approval(text: "x", choices: [(id: "approve", label: "Approve")], title: "t").initialFocusID)
        XCTAssertNil(CardModel.approval(text: "x", choices: [(id: "approve", label: "Approve"), (id: "later", label: "Later")], title: "t").initialFocusID)
        // A Cancel whose label was blank is not shown, so it cannot hold focus either.
        let blank = CardModel.approval(text: "x", choices: [(id: "approve", label: "Approve"), (id: "cancel", label: " ")], title: "t")
        XCTAssertNil(blank.initialFocusID)
    }

    func testTheButtonSpecTheViewBuildsFromHasNoKeyEquivalent() {
        // The card view builds every NSButton from this spec only, so Return and Space-bar defaults cannot approve.
        let m = CardModel.approval(text: "x", choices: yesNo, title: "t")
        XCTAssertEqual(m.buttons.map(\.spec), [
            CardButtonSpec(title: "Approve", id: "approve", keyEquivalent: "", accessibilityLabel: "Approve"),
            CardButtonSpec(title: "Cancel", id: "cancel", keyEquivalent: "", accessibilityLabel: "Cancel"),
        ])
        XCTAssertTrue(m.buttons.map(\.spec).allSatisfy { $0.keyEquivalent.isEmpty })
        XCTAssertEqual(CardButtonSpec.keyEquivalent, "")
    }

    func testCancelIsMarkedAsCancelAndOthersAreActions() {
        let m = CardModel.approval(text: "x", choices: yesNo, title: "t")
        XCTAssertEqual(m.buttons.first(where: { $0.id == "cancel" })?.role, .cancel)
        XCTAssertEqual(m.buttons.first(where: { $0.id == "approve" })?.role, .action)
    }

    func testEveryButtonHasAnAccessibilityLabelEqualToItsVisibleLabel() {
        for b in CardModel.approval(text: "x", choices: yesNo, title: "t").buttons {
            XCTAssertEqual(b.accessibilityLabel, b.label)
            XCTAssertFalse(b.accessibilityLabel.isEmpty)
        }
    }

    func testEmptyLabelsAreNotShownAsBlankButtons() {
        let m = CardModel.approval(text: "x", choices: [(id: "approve", label: "  "), (id: "cancel", label: "Cancel")], title: "t")
        XCTAssertEqual(m.buttons.map(\.id), ["cancel"])
    }

    // MARK: the other cards

    func testReplyIsReadOnlyAndHidesItself() {
        let m = CardModel.reply("Done. I pressed Save.", milliseconds: 4000)
        XCTAssertEqual(m.kind, .reply)
        XCTAssertEqual(m.autoHideSeconds, 4.0)
        XCTAssertEqual(m.announcement, "Done. I pressed Save.")
        XCTAssertTrue(m.buttons.isEmpty)
        XCTAssertEqual(CardModel.reply("x", milliseconds: 0).autoHideSeconds, CardModel.minimumReplySeconds)   // never a card that flashes by
    }

    func testAskFieldAndTranscript() {
        XCTAssertEqual(CardModel.askField.kind, .askField)
        XCTAssertNil(CardModel.askField.autoHideSeconds)
        XCTAssertEqual(CardModel.askField.accessibilityTitle, "Ask Shep")
        let t = CardModel.transcript("press save")
        XCTAssertEqual(t.kind, .transcript)
        XCTAssertEqual(t.text, "press save")
        XCTAssertNil(t.announcement)   // partial speech is not announced word by word
    }

    func testOnlyTheCardsThatTakeInputBecomeKey() {
        XCTAssertTrue(CardKind.approval.takesKey)
        XCTAssertTrue(CardKind.askField.takesKey)
        XCTAssertFalse(CardKind.reply.takesKey)
        XCTAssertFalse(CardKind.transcript.takesKey)
    }

    func testEscapeCancelsAnApprovalAndClosesTheAskFieldAndNothingElse() {
        XCTAssertEqual(CardKind.approval.escapeResult, .cancelChoice)
        XCTAssertEqual(CardKind.askField.escapeResult, .closeField)
        XCTAssertEqual(CardKind.reply.escapeResult, .none)
        XCTAssertEqual(CardKind.transcript.escapeResult, .none)
    }

    func testLongTextIsClippedForTheCardNotTheRequest() {
        let long = String(repeating: "word ", count: 2000)
        XCTAssertLessThanOrEqual(CardModel.reply(long, milliseconds: 1000).text.count, CardModel.maxTextLength)
    }

    func testSubmittedTextIsTrimmedAndEmptyMeansCancel() {
        XCTAssertEqual(CardModel.submission(from: "  press save \n"), .submit("press save"))
        XCTAssertEqual(CardModel.submission(from: "   "), .cancel)
        XCTAssertEqual(CardModel.submission(from: ""), .cancel)
    }

    // MARK: layout

    private func layout(below: Bool) -> PanelLayout {
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
        let win = below ? CGRect(x: 120, y: 300, width: 720, height: 460) : CGRect(x: 120, y: 20, width: 720, height: 100)
        let tab = TabGeometry.place(window: win, isFullScreen: false, screens: screens).layout!
        let l = PanelGeometry.layout(tab: tab, screens: screens)
        XCTAssertEqual(l.bubbleBelow, below)
        return l
    }

    func testCardHangsFromTheTopOfTheBubbleAreaWhenItIsBelowTheTitleBar() {
        let l = layout(below: true)
        let f = CardGeometry.frame(in: l, contentHeight: 90)
        XCTAssertEqual(f.minX, l.bubbleFrame.minX)
        XCTAssertEqual(f.width, l.bubbleFrame.width)
        XCTAssertEqual(f.height, 90)
        XCTAssertEqual(f.maxY, l.bubbleFrame.maxY, accuracy: 1e-9)   // the near edge stays under the title bar
    }

    func testCardSitsOnTheTabWhenThereIsNoRoomBelow() {
        let l = layout(below: false)
        let f = CardGeometry.frame(in: l, contentHeight: 90)
        XCTAssertEqual(f.minY, l.bubbleFrame.minY, accuracy: 1e-9)   // grows upward from the tab
        XCTAssertEqual(f.height, 90)
    }

    func testCardHeightIsClampedToTheRoomAndToAMinimum() {
        let l = layout(below: true)
        XCTAssertEqual(CardGeometry.frame(in: l, contentHeight: 900).height, l.bubbleFrame.height)
        XCTAssertEqual(CardGeometry.frame(in: l, contentHeight: 3).height, CardGeometry.minHeight)
        XCTAssertEqual(CardGeometry.frame(in: l, contentHeight: CGFloat.nan).height, CardGeometry.minHeight)
    }

    func testCardStaysInsideTheBubbleArea() {
        for below in [true, false] {
            let l = layout(below: below)
            for h in [10, 60, 150, 400] as [CGFloat] {
                XCTAssertTrue(l.bubbleFrame.insetBy(dx: -0.001, dy: -0.001).contains(CardGeometry.frame(in: l, contentHeight: h)))
            }
        }
    }

    func testTheCardPanelOnlyTakesTheMouseOverItsOwnFrame() {
        // The dog's panel is click-through except over the tab: a card is its own window now.
        let l = layout(below: true)
        XCTAssertEqual(PanelGeometry.interactiveRects(l, bubbleVisible: false), [l.tab.rect])
    }

    // MARK: presence and typing

    func testACardShownWhileAnotherFadesOutArrivesFreshSoItIsNeverStuckAtAlphaZero() {
        XCTAssertEqual(CardPresence.resolve(isVisible: false, fadingOut: false), .hidden)
        XCTAssertEqual(CardPresence.resolve(isVisible: false, fadingOut: true), .hidden)
        XCTAssertEqual(CardPresence.resolve(isVisible: true, fadingOut: false), .shown)
        XCTAssertEqual(CardPresence.resolve(isVisible: true, fadingOut: true), .fadingOut)
        XCTAssertTrue(CardPresence.hidden.arrivesFresh)
        XCTAssertTrue(CardPresence.fadingOut.arrivesFresh)   // the visible-but-fading window gets the fade-in back to alpha 1
        XCTAssertFalse(CardPresence.shown.arrivesFresh)
    }

    func testTypingIsKeptOnlyWhenTheSameAskFieldIsLaidOutAgain() {
        XCTAssertTrue(CardModel.keepsTyping(previous: .askField, next: .askField, isRefresh: true))
        XCTAssertFalse(CardModel.keepsTyping(previous: .askField, next: .askField, isRefresh: false))   // a new ask field starts empty
        XCTAssertFalse(CardModel.keepsTyping(previous: .approval, next: .askField, isRefresh: true))
        XCTAssertFalse(CardModel.keepsTyping(previous: nil, next: .askField, isRefresh: true))
        XCTAssertFalse(CardModel.keepsTyping(previous: .askField, next: .reply, isRefresh: true))
    }
}
