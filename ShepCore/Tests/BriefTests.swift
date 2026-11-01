import XCTest
@testable import ShepCore

/// Shep's flow copy is short: a word or two spoken, one line on a card, Approve and Deny.
final class BriefTests: XCTestCase {
    private let save = Control(role: "AXButton", title: "Save", actions: ["AXPress"])

    func testSpokenLinesAreAWordOrTwo() {
        for line in [Brief.onIt, Brief.done, Brief.cancelled, Brief.nothing, Brief.busy] {
            XCTAssertLessThanOrEqual(line.split(separator: " ").count, 3, line)
            XCTAssertTrue(line.hasSuffix("."), line)
        }
        XCTAssertEqual(Brief.onIt, "On it.")
        XCTAssertEqual(Brief.done, "Done.")
    }

    func testApproveAndDenyKeepTheCancelSemantics() {
        XCTAssertEqual(Brief.approvalChoices.map(\.id), ["approve", "cancel"])
        XCTAssertEqual(Brief.approvalChoices.map(\.label), ["Approve", "Deny"])
        let m = CardModel.approval(text: "Press \"Save\"?", choices: Brief.approvalChoices, title: "Shep wants to press Save in TextEdit")
        XCTAssertEqual(m.initialFocusID, "cancel")   // focus starts on Deny: a stray Return or Space never approves
        XCTAssertEqual(m.buttons.first { $0.id == "cancel" }?.role, .cancel)
        XCTAssertEqual(m.accessibilityOrder, [.text, .button("approve"), .button("cancel")])   // text, then Approve, then Deny
    }

    private func line(_ action: ProposedAction, peers: [Control] = []) -> String {
        guard case .required(let why) = ApprovalPolicy.requirement(for: action) else { XCTFail("refused"); return "" }
        return ApprovalRequest(action: action, reason: why).cardText(peers: peers)
    }

    func testTheCardIsOneShortLine() {
        let l = line(ProposedAction(control: save, kind: .axPress, bundleID: "com.apple.TextEdit"))
        XCTAssertEqual(l, "Press the button \"Save\"?")
        XCTAssertFalse(l.contains("\n"))
    }

    private let tip = "Speed Limit overrides the total bandwidth limits with its own limits."

    func testATooltipNameKeepsItsLeadingCapitalisedWords() {
        let turtle = Control(index: 1, role: "AXCheckBox", value: "0", help: tip, actions: ["AXPress"])
        XCTAssertEqual(turtle.labelSource, .tooltip)
        XCTAssertEqual(Brief.shortName(turtle), "Speed Limit")
        XCTAssertEqual(line(ProposedAction(control: turtle, kind: .axPress, bundleID: "org.m0k.transmission"), peers: [turtle]),
                       "Press the checkbox \"Speed Limit\"?")
        let lower = Control(index: 2, role: "AXCheckBox", value: "0", help: "toggles the alternative speed limits for all transfers", actions: ["AXPress"])
        XCTAssertLessThanOrEqual(Brief.shortName(lower).count, Brief.maxNameCharacters)
        XCTAssertTrue(Brief.shortName(lower).hasSuffix("…"))
    }

    func testANameIsNotShortenedWhenAnotherControlWouldLookTheSame() {
        let a = Control(index: 1, role: "AXCheckBox", value: "0", help: tip, actions: ["AXPress"])
        let b = Control(index: 2, role: "AXCheckBox", value: "0", help: "Speed Limit for uploads only.", actions: ["AXPress"])
        XCTAssertEqual(Brief.shortName(b), "Speed Limit")
        XCTAssertEqual(Brief.displayName(a, peers: [a, b]), tip)   // both would read "Speed Limit": the full names are shown
        XCTAssertEqual(Brief.displayName(a, peers: [a]), "Speed Limit")
        let plain = Control(index: 3, role: "AXButton", title: "Speed Limit", actions: ["AXPress"])
        XCTAssertEqual(Brief.displayName(a, peers: [a, plain]), tip)   // a control already called that
        let long1 = Control(index: 4, role: "AXButton", title: "Reset all of the advanced network preferences now", actions: ["AXPress"])
        let long2 = Control(index: 5, role: "AXButton", title: "Reset all of the advanced network preferences later", actions: ["AXPress"])
        XCTAssertEqual(Brief.displayName(long1, peers: [long1, long2]), long1.label)
        XCTAssertTrue(Brief.displayName(long1, peers: [long1]).hasSuffix("…"))
    }

    func testLongNamesAreCutAtAWord() {
        XCTAssertEqual(Brief.clip("Save"), "Save")
        let cut = Brief.clip("Reset all of the advanced network preferences now")
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, Brief.maxNameCharacters)
        XCTAssertFalse(cut.dropLast().hasSuffix(" "))
        XCTAssertEqual(Brief.clip(String(repeating: "x", count: 40)).count, Brief.maxNameCharacters)
    }

    func testTypedTextIsShownWhole() {
        let field = Control(role: "AXTextField", title: "Name", actions: [])
        let text = "a long piece of text that is well over twenty-eight characters, all of it written"
        let l = line(ProposedAction(control: field, kind: .setValue(text), bundleID: "x"))
        XCTAssertEqual(l, "Type \"\(text)\" in the \(field.kind) \"Name\"?")
    }

    func testReasonsThatChangeTheDecisionStayAsShortTags() {
        XCTAssertEqual(Brief.reasonTag(""), "")
        let reasons = [
            "This uses the mouse pointer: after you approve, Shep clicks once at that spot.",
            "The control didn't respond to Accessibility, so the only option left is a mouse click.",
            "Found on the screenshot, not in the app's own controls, so it can only be clicked with the mouse.",
            "This app can run commands.",
        ]
        for r in reasons {
            let tag = Brief.reasonTag(r)
            XCTAssertFalse(tag.isEmpty, r)
            XCTAssertLessThan(tag.count, r.count, r)
        }
        XCTAssertEqual(Brief.reasonTag("Something new to say."), "Something new to say.")   // unknown reasons are kept whole
        let runner = ApprovalRequest(action: ProposedAction(control: save, kind: .axPress, bundleID: "x"), reason: "This app can run commands.")
        XCTAssertEqual(runner.cardText, "Press the button \"Save\"? This app runs commands.")
        let click = line(ProposedAction(control: save, kind: .clickPoint, bundleID: "com.apple.TextEdit"))
        XCTAssertTrue(click.contains("With the mouse."), click)
    }

    func testACardThatCannotShowEverythingIsNotShown() {
        XCTAssertTrue(Brief.cardFits(String(repeating: "a", count: CardModel.maxTextLength)))
        XCTAssertFalse(Brief.cardFits(String(repeating: "a", count: CardModel.maxTextLength + 1)))
    }

    func testTheSpecificMouseReasonsReachTheCard() {
        let vision = Control(index: 9, role: "AXButton", title: "Gear", frame: CGRect(x: 10, y: 10, width: 20, height: 20), fromVision: true)
        if case .required(let why) = ApprovalPolicy.requirement(for: ProposedAction(control: vision, kind: .clickPoint, bundleID: "x")) {
            XCTAssertEqual(Brief.reasonTag(why), "With the mouse: seen only on screen.")
        } else { XCTFail("not asked") }
        if case .required(let why) = ApprovalPolicy.requirement(for: ProposedAction(control: save, kind: .clickPoint, bundleID: "x"), afterAXFailure: true) {
            XCTAssertEqual(Brief.reasonTag(why), "With the mouse: it ignored Accessibility.")
        } else { XCTFail("not asked") }
    }

    func testEveryRequiredActionStillAsks() {
        // The copy changed; the gate did not: no kind of action skips approval.
        for kind: ActionKind in [.axPress, .axConfirm, .axPick, .clickPoint, .setValue("a")] {
            let c = kind == .setValue("a") ? Control(role: "AXTextField", title: "Name", actions: []) : save
            if case .refused = ApprovalPolicy.requirement(for: ProposedAction(control: c, kind: kind, bundleID: "com.apple.TextEdit")) { continue }
            guard case .required = ApprovalPolicy.requirement(for: ProposedAction(control: c, kind: kind, bundleID: "com.apple.TextEdit")) else {
                return XCTFail("\(kind) does not ask")
            }
        }
    }

    func testTheFinishIsQuickerButStillWaitsForSpeech() {
        XCTAssertLessThanOrEqual(FinishBeat.holdAfterWoof, 0.5)
        XCTAssertEqual(FinishBeat.replyTimeout, 2.5)   // the review fix's bound is unchanged
        XCTAssertLessThan(Brief.stepGapSeconds, 1.2)
        XCTAssertGreaterThan(Brief.stepGapSeconds, 0)
    }
}
