import CoreGraphics
import XCTest
@testable import ShepCore

/// P1-1: a click on a control found on the screenshot is bound to the identity of the element that was under the spot when
/// the approval card was built, and compared with the live element right before the event.
final class ClickIdentityTests: XCTestCase {
    let windowFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
    let boxFrame = CGRect(x: 300, y: 300, width: 80, height: 24)
    var point: CGPoint { CGPoint(x: boxFrame.midX, y: boxFrame.midY) }
    var approvedWindow: ApprovedWindow { ApprovedWindow(pid: 42, number: 7, frame: windowFrame, title: "Doc") }

    func identity(_ label: String = "Gear", role: String = "AXButton", subrole: String = "", enabled: Bool = true,
                  frame: CGRect? = nil, help: String = "") -> HitIdentity {
        HitIdentity.resolved(role: role, subrole: subrole, title: label, help: help, enabled: enabled, frame: frame ?? boxFrame)
    }

    func visionAction(_ id: HitIdentity?) -> ProposedAction {
        var vision = Control(index: 2, role: "AXButton", title: "Gear", window: "Doc", frame: boxFrame, pathID: "v1")
        vision.fromVision = true
        return ProposedAction(control: vision, kind: .clickPoint, bundleID: "com.example", hitIdentity: id)
    }

    /// Nothing listed at the spot; the hit test finds an element carrying `id`.
    func scene(live id: HitIdentity?, role: String = "AXButton") -> LiveClickScene {
        LiveClickScene(frontPID: 42, focusedWindowIsApproved: true, windowNumber: 7, windowFrame: windowFrame, windowTitle: "Doc",
                       hitPID: 42, hitInApprovedWindow: true, expected: nil,
                       hit: LiveHitElement(role: role, actions: ["AXPress"], frame: boxFrame, identity: id))
    }

    func check(_ action: ProposedAction, _ s: LiveClickScene) -> String? {
        ClickGuard.check(window: approvedWindow, action: action, point: point, reader: FakeSceneReader(s))
    }

    func testSameIdentityPasses() {
        XCTAssertNil(check(visionAction(identity()), scene(live: identity())))
    }

    func testSameRectangleDifferentLabelRefuses() {
        let why = check(visionAction(identity("Gear")), scene(live: identity("Delete account")))
        XCTAssertNotNil(why, "approved Gear, a different control with the same rectangle and role is there now")
        XCTAssertNotNil(check(visionAction(identity("Gear")), scene(live: identity("Settings"))), "a harmless other label is still a different control")
    }

    func testLabelCaseAndWhitespaceDoNotMatterButTheWordsDo() {
        XCTAssertNil(check(visionAction(identity("Gear")), scene(live: identity("  gear \n"))))
        XCTAssertNotNil(check(visionAction(identity("Gear")), scene(live: identity("Gears"))))
    }

    // P1-1 residual: an unnamed hit is never an identity.
    func testAnUnnamedApprovedIdentityRefusesAtClickTime() {
        let unnamed = identity("")
        XCTAssertFalse(unnamed.isUsable)
        XCTAssertEqual(check(visionAction(unnamed), scene(live: unnamed)), ClickGuard.cannotIdentifyMessage)
    }

    func testReplacingOneUnnamedButtonWithAnotherAtTheSameFrameRefuses() {
        XCTAssertEqual(check(visionAction(identity("")), scene(live: identity(""))), ClickGuard.cannotIdentifyMessage)
        XCTAssertEqual(check(visionAction(identity("Gear")), scene(live: identity("   \n"))), ClickGuard.cannotIdentifyMessage,
                       "a named approval does not survive the live element losing its name")
    }

    func testWhitespaceOnlyLabelsAreNotUsable() {
        XCTAssertFalse(identity(" \t\n ").isUsable)
        XCTAssertTrue(identity("Gear").isUsable)
    }

    func testANamedHitStillPasses() {
        XCTAssertNil(check(visionAction(identity("Gear")), scene(live: identity("Gear"))))
    }

    func testNoApprovedIdentityRefusesAVisionClick() {
        XCTAssertEqual(check(visionAction(nil), scene(live: identity())), ClickGuard.unidentified)
    }

    func testNoLiveIdentityRefuses() {
        XCTAssertEqual(check(visionAction(identity()), scene(live: nil)), ClickGuard.unidentified)
    }

    func testSensitiveLabelOnTheLiveHitRefusesEvenWhenItWasApprovedAsThat() {
        // The same label on both sides: the identity matches, ControlPolicy still says no at click time.
        let danger = identity("Delete account")
        let why = check(visionAction(danger), scene(live: danger))
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("delete") ?? false, "\(why ?? "nil")")
    }

    func testSensitiveLabelFromATooltipOnTheLiveHitRefuses() {
        let tip = HitIdentity.resolved(role: "AXButton", help: "Erase everything", frame: boxFrame)
        XCTAssertNotNil(check(visionAction(tip), scene(live: tip)))
    }

    func testSecureDisabledOrRoleLessLiveHitRefuses() {
        let approved = visionAction(identity())
        XCTAssertNotNil(check(approved, scene(live: identity(role: "AXSecureTextField"))))
        XCTAssertNotNil(check(approved, scene(live: identity(subrole: "AXSecureTextField"))))
        XCTAssertNotNil(check(approved, scene(live: identity(enabled: false))))
        XCTAssertNotNil(check(approved, scene(live: identity(role: ""))))
    }

    func testIdentityThatCouldNotBeUsedWhenApprovedNeverPasses() {
        for bad in [identity(role: "AXSecureTextField"), identity(enabled: false), identity(role: ""),
                    identity(frame: CGRect(x: 300, y: 300, width: 0, height: 24)),
                    identity(frame: CGRect(x: CGFloat.nan, y: 300, width: 80, height: 24))] {
            XCTAssertFalse(bad.isUsable, "\(bad)")
            XCTAssertNotNil(check(visionAction(bad), scene(live: bad)), "\(bad)")
        }
        XCTAssertTrue(identity().isUsable)
    }

    func testRoleSubroleAndLabelSourceMustAllMatch() {
        let approved = visionAction(identity())
        XCTAssertNotNil(check(approved, scene(live: identity(role: "AXCheckBox"))))
        XCTAssertNotNil(check(approved, scene(live: identity(subrole: "AXToggle"))))
        // Same words, but now named by a tooltip instead of a title.
        XCTAssertNotNil(check(approved, scene(live: HitIdentity.resolved(role: "AXButton", help: "Gear", frame: boxFrame))))
    }

    func testFrameMustStayWithinTheToleranceOfTheApprovedFrame() {
        let approved = visionAction(identity())
        XCTAssertNil(check(approved, scene(live: identity(frame: boxFrame.offsetBy(dx: 1, dy: 1)))))
        XCTAssertNotNil(check(approved, scene(live: identity(frame: boxFrame.offsetBy(dx: 6, dy: 0)))))
        XCTAssertNotNil(check(approved, scene(live: identity(frame: boxFrame.insetBy(dx: -6, dy: 0)))))
    }

    func testAListedControlUnderAVisionPointStillNeedsTheIdentityToMatch() {
        var s = scene(live: identity("Delete account"))
        var listed = Control(index: 1, role: "AXButton", title: "Gear", frame: boxFrame, actions: ["AXPress"], pathID: "0/1")
        listed.window = "Doc"
        s.expected = LiveExpectedElement(control: listed, live: LiveTarget(role: "AXButton", title: "Gear"), frame: boxFrame)
        s.hit?.isExpected = true
        XCTAssertNotNil(check(visionAction(identity("Gear")), s), "TargetRecheck is satisfied by the listed element but the live hit says otherwise")
        s.hit?.identity = identity("Gear")
        XCTAssertNil(check(visionAction(identity("Gear")), s))
    }

    func testAListedClickThatCarriesAnIdentityComparesItToo() {
        var listed = Control(index: 1, role: "AXButton", title: "Save", window: "Doc", frame: boxFrame, actions: ["AXPress"], pathID: "0/1")
        listed.fromVision = false
        let action = ProposedAction(control: listed, kind: .clickPoint, bundleID: "com.example", hitIdentity: identity("Save"))
        var s = scene(live: identity("Save"))
        s.expected = LiveExpectedElement(control: listed, live: LiveTarget(role: "AXButton", title: "Save"), frame: boxFrame)
        s.hit?.isExpected = true
        XCTAssertNil(check(action, s))
        s.hit?.identity = identity("Cancel")
        XCTAssertNotNil(check(action, s))
    }

    // MARK: the token is bound to the identity

    func testADifferentIdentityIsADifferentAction() {
        XCTAssertEqual(visionAction(identity()), visionAction(identity()))
        XCTAssertNotEqual(visionAction(identity("Gear")), visionAction(identity("Settings")))
        XCTAssertNotEqual(visionAction(identity()), visionAction(nil))
        let token = ApprovalToken(action: visionAction(identity("Gear")))
        XCTAssertFalse(token.consume(for: visionAction(identity("Delete account"))), "a token for Gear does not open Delete account")
        XCTAssertFalse(token.consume(for: visionAction(nil)))
        XCTAssertTrue(token.consume(for: visionAction(identity("Gear"))), "failed attempts did not spend it")
        XCTAssertFalse(token.consume(for: visionAction(identity("Gear"))), "single use")
    }

    func testTheOldInitialiserStillWorksAndMeansNoIdentity() {
        let a = ProposedAction(control: Control(role: "AXButton", title: "Save"), kind: .axPress, bundleID: "com.example")
        XCTAssertNil(a.hitIdentity)
    }

    // MARK: the card

    func testTheCardNamesWhatIsUnderTheSpot() {
        let request = ApprovalRequest(action: visionAction(identity("Gear")), reason: "why")
        XCTAssertTrue(request.cardText.contains("Under it: button \"Gear\"."), request.cardText)
        let plain = ApprovalRequest(action: visionAction(nil), reason: "why")
        XCTAssertFalse(plain.cardText.contains("Under it"))
    }
}

/// The runner asks for the identity before the card is shown, refuses when there is none, and carries it in the action.
final class ClickIdentityRunnerTests: XCTestCase {
    let found = Control(index: 2, role: "AXButton", title: "Gear", pathID: "v1", fromVision: true)
    let gear = HitIdentity.resolved(role: "AXButton", title: "Gear", frame: CGRect(x: 0, y: 0, width: 40, height: 20))
    let replan = ClickGuard.cannotIdentifyMessage

    func testNoIdentityRefusesBeforeTheCardAndBeforeAnyEvent() async {
        let e = ActionRunnerTests.FakeExecutor(); e.identity = nil
        let a = ActionRunnerTests.Asker(true)
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(out, .refused(replan))
        XCTAssertEqual(a.asked.count, 0, "no card for a spot nobody can name")
        XCTAssertEqual(e.clickCalls, 0)
    }

    func testUnusableIdentitiesRefuseBeforeTheCard() async {
        let bad = [HitIdentity.resolved(role: "AXSecureTextField", title: "Gear", frame: gear.frame),
                   HitIdentity.resolved(role: "AXButton", title: "Gear", enabled: false, frame: gear.frame),
                   HitIdentity.resolved(role: "", title: "Gear", frame: gear.frame)]
        for id in bad {
            let e = ActionRunnerTests.FakeExecutor(); e.identity = id
            let a = ActionRunnerTests.Asker(true)
            let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
            XCTAssertEqual(out, .refused(replan), "\(id)")
            XCTAssertEqual(a.asked.count + e.clickCalls, 0)
        }
    }

    func testAnUnlistedProposalWhoseHitIsAnUnnamedButtonIsRefusedBeforeAnyCardOrEvent() async {
        let e = ActionRunnerTests.FakeExecutor()
        e.identity = HitIdentity.resolved(role: "AXButton", title: "", description: "", help: "", frame: gear.frame)
        XCTAssertEqual(e.identity?.label, "")
        let a = ActionRunnerTests.Asker(true)
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(out, .refused(replan))
        XCTAssertEqual(a.asked.count, 0, "no card for a button nobody can name")
        XCTAssertEqual(e.clickCalls, 0)
    }

    func testANamedHitStillGetsACardAndTheTokenIsSingleUse() async {
        let e = ActionRunnerTests.FakeExecutor(); e.identity = gear
        let a = ActionRunnerTests.Asker(true)
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(out, .done("Click the button \"Gear\" (found on screen)"))
        let action = a.asked[0].action
        let token = ApprovalToken(action: action)
        let first = await e.click(action, token: token)
        XCTAssertEqual(first, .clicked)
        let second = await e.click(action, token: token)
        XCTAssertEqual(second, .skipped("no approval"))
    }

    func testASensitiveLabelUnderTheSpotIsRefusedBeforeTheCardEvenIfTheModelCalledItGear() async {
        let e = ActionRunnerTests.FakeExecutor()
        e.identity = HitIdentity.resolved(role: "AXButton", title: "Delete account", frame: gear.frame)
        let a = ActionRunnerTests.Asker(true)
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        guard case .refused = out else { return XCTFail("\(out)") }
        XCTAssertEqual(a.asked.count, 0)
        XCTAssertEqual(e.clickCalls, 0)
    }

    func testTheCardShowsTheIdentityAndTheClickedActionCarriesIt() async {
        let e = ActionRunnerTests.FakeExecutor(); e.identity = gear
        let a = ActionRunnerTests.Asker(true)
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(out, .done("Click the button \"Gear\" (found on screen)"))
        XCTAssertEqual(a.asked.count, 1)
        XCTAssertTrue(a.asked[0].cardText.contains("Under it: button \"Gear\"."), a.asked[0].cardText)
        XCTAssertEqual(a.asked[0].action.hitIdentity, gear)
        XCTAssertEqual(e.lastClicked?.hitIdentity, gear, "the token was made for the action with the identity in it")
    }

    func testAVisionControlWithAPressKindIsAskedAboutAndClickedWithTheIdentity() async {
        let e = ActionRunnerTests.FakeExecutor(); e.identity = gear
        let a = ActionRunnerTests.Asker(true)
        _ = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: found, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(e.lastClicked?.hitIdentity, gear)
        XCTAssertEqual(e.axCalls, 0)
    }

    func testTheClickAfterAFailedPressAsksForAnIdentityToo() async {
        let ax = Control(index: 1, role: "AXButton", title: "Share", actions: ["AXPress"], pathID: "0/1")
        let e = ActionRunnerTests.FakeExecutor(); e.axResult = false; e.identity = nil
        let a = ActionRunnerTests.Asker(true)
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(out, .refused(replan))
        XCTAssertEqual(a.asked.count, 1, "only the press was asked about; the click fallback never reached a card")
        XCTAssertEqual(e.clickCalls, 0)
        e.identity = gear
        let again = ActionRunnerTests.Asker(true)
        _ = await ActionRunner(executor: e, approve: again.callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(e.lastClicked?.hitIdentity, gear)
    }

    func testPressesThroughAccessibilityDoNotNeedAnIdentity() async {
        let ax = Control(index: 1, role: "AXButton", title: "Share", actions: ["AXPress"], pathID: "0/1")
        let e = ActionRunnerTests.FakeExecutor(); e.identity = nil
        let out = await ActionRunner(executor: e, approve: ActionRunnerTests.Asker(true).callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(out, .done("Press the button \"Share\""))
        XCTAssertEqual(e.identityCalls, 0)
    }
}
