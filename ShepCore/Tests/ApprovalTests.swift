import CoreGraphics
import XCTest
@testable import ShepCore

final class ApprovalPolicyTests: XCTestCase {
    let ax = Control(index: 1, role: "AXButton", title: "Share", window: "Doc", frame: CGRect(x: 0, y: 0, width: 40, height: 20), actions: ["AXPress"], pathID: "0/1")
    let field = Control(index: 2, role: "AXTextField", title: "Name", window: "Doc", value: "", frame: CGRect(x: 0, y: 0, width: 80, height: 20), actions: [], pathID: "0/2")
    let found = Control(index: 3, role: "AXButton", title: "Gear", window: "Doc", frame: CGRect(x: 0, y: 0, width: 20, height: 20), pathID: "v1", fromVision: true)

    func req(_ c: Control, _ k: ActionKind, bundle: String = "com.example.app", fail: Bool = false) -> ApprovalRequirement {
        ApprovalPolicy.requirement(for: ProposedAction(control: c, kind: k, bundleID: bundle), afterAXFailure: fail)
    }
    func isRequired(_ r: ApprovalRequirement) -> Bool { if case .required = r { return true } else { return false } }
    func isRefused(_ r: ApprovalRequirement) -> Bool { if case .refused = r { return true } else { return false } }

    func testPlainAXPressNeedsApprovalToo() {
        for kind in [ActionKind.axPress, .axConfirm, .axPick] { XCTAssertTrue(isRequired(req(ax, kind)), "\(kind)") }
    }

    func testNoActionKindOnAnEnabledOrdinaryControlIsAutoApproved() {
        for kind in [ActionKind.axPress, .axConfirm, .axPick, .clickPoint] {
            for control in [ax, found] { XCTAssertTrue(isRequired(req(control, kind)), "\(kind)") }
        }
        XCTAssertTrue(isRequired(req(field, .setValue("Rex"))))
    }

    func testClicksAlwaysRequireApproval() {
        for control in [ax, found] { XCTAssertTrue(isRequired(req(control, .clickPoint))) }
    }

    func testVisionOnlyControlsAlwaysRequireApproval() {
        XCTAssertTrue(isRequired(req(found, .axPress)))
        XCTAssertTrue(isRequired(req(found, .clickPoint)))
    }

    func testAXFailureForcesApproval() {
        XCTAssertTrue(isRequired(req(ax, .axPress, fail: true)))
    }

    func testTypingNeedsApprovalAndRefusesNonTextAndVisionControls() {
        XCTAssertTrue(isRequired(req(field, .setValue("Rex"))))
        XCTAssertTrue(isRefused(req(ax, .setValue("x"))))
        var visionField = field; visionField.fromVision = true
        XCTAssertTrue(isRefused(req(visionField, .setValue("x"))))
    }

    func testSecureDisabledAndRiskyAreRefused() {
        let secure = Control(index: 1, role: "AXTextField", subrole: "AXSecureTextField", title: "Password")
        XCTAssertTrue(isRefused(req(secure, .setValue("x"))))
        XCTAssertTrue(isRefused(req(Control(role: "AXButton", title: "Share", enabled: false), .axPress)))
        XCTAssertTrue(isRefused(req(Control(role: "AXButton", title: "Buy now", actions: ["AXPress"]), .axPress)))
        XCTAssertTrue(isRefused(req(ax, .axPress, bundle: "com.1password.1password")))
    }

    func testCommandRunnerAppsAlwaysAsk() {
        XCTAssertTrue(isRequired(req(ax, .axPress, bundle: "com.apple.Terminal")))
        XCTAssertTrue(isRequired(req(ax, .axPress, bundle: "com.jetbrains.intellij")))
    }

    func testDefaultActionPrefersAXThenClick() {
        XCTAssertEqual(ApprovalPolicy.defaultAction(for: ax, bundleID: "b").kind, .axPress)
        var confirm = ax; confirm.actions = ["AXConfirm"]
        XCTAssertEqual(ApprovalPolicy.defaultAction(for: confirm, bundleID: "b").kind, .axConfirm)
        var none = ax; none.actions = []
        XCTAssertEqual(ApprovalPolicy.defaultAction(for: none, bundleID: "b").kind, .clickPoint)
        XCTAssertEqual(ApprovalPolicy.defaultAction(for: found, bundleID: "b").kind, .clickPoint)
    }
}

final class ApprovalTokenTests: XCTestCase {
    let ax = Control(index: 1, role: "AXButton", title: "Share", actions: ["AXPress"], pathID: "0/1")
    let other = Control(index: 2, role: "AXButton", title: "Cancel", actions: ["AXPress"], pathID: "0/2")

    func testTokenWorksOnceForItsOwnActionOnly() {
        let press = ProposedAction(control: ax, kind: .axPress, bundleID: "com.example")
        let token = ApprovalToken(action: press)
        XCTAssertFalse(token.consume(for: ProposedAction(control: other, kind: .axPress, bundleID: "com.example")), "another control")
        XCTAssertFalse(token.consume(for: ProposedAction(control: ax, kind: .clickPoint, bundleID: "com.example")), "another kind")
        XCTAssertTrue(token.consume(for: press))
        XCTAssertFalse(token.consume(for: press), "single use")
    }

    func testTokenForAPressCannotBeReusedForAClick() {
        let press = ProposedAction(control: ax, kind: .axPress, bundleID: "com.example")
        let click = ProposedAction(control: ax, kind: .clickPoint, bundleID: "com.example")
        let token = ApprovalToken(action: press)
        XCTAssertFalse(token.consume(for: click))
        XCTAssertTrue(token.consume(for: press), "the failed attempt did not spend it")
    }
}

final class ActionRunnerTests: XCTestCase {
    /// Behaves like the real performer at the boundary: with no valid token it does nothing and says so.
    final class FakeExecutor: ActionExecuting, @unchecked Sendable {
        var axResult = true
        var axChanged: String?
        var clickResult = ClickResult.clicked
        var cancelDuringClick = false
        /// What the executor reports as the element under the spot when the card is built (nil: it cannot tell).
        var identity: HitIdentity? = HitIdentity.resolved(role: "AXButton", title: "Gear", frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        private let lock = NSLock()
        private(set) var identityCalls = 0
        private(set) var lastClicked: ProposedAction?
        func hitIdentity(for action: ProposedAction) async -> HitIdentity? {
            lock.lock(); identityCalls += 1; lock.unlock()
            return identity
        }
        private(set) var axCalls = 0
        private(set) var clickCalls = 0
        private(set) var axDone = 0
        private(set) var clickDone = 0
        func performAX(_ action: ProposedAction, token: ApprovalToken) async -> AXResult {
            lock.lock(); axCalls += 1; lock.unlock()
            guard token.consume(for: action) else { return .failed }
            lock.lock(); axDone += 1; lock.unlock()
            if let why = axChanged { return .targetChanged(why) }
            return axResult ? .performed : .failed
        }
        func click(_ action: ProposedAction, token: ApprovalToken) async -> ClickResult {
            lock.lock(); clickCalls += 1; lastClicked = action; lock.unlock()
            guard token.consume(for: action) else { return .skipped("no approval") }
            lock.lock(); clickDone += 1; lock.unlock()
            if cancelDuringClick { withUnsafeCurrentTask { $0?.cancel() }; return .skipped("cancelled") }
            return clickResult
        }
    }
    final class Asker: @unchecked Sendable {
        var answer: Bool
        var cancelWhileAsking = false
        private(set) var asked: [ApprovalRequest] = []
        init(_ a: Bool) { answer = a }
        func callback() -> ApprovalCallback {
            { [self] r in
                asked.append(r)
                if cancelWhileAsking { withUnsafeCurrentTask { $0?.cancel() } }
                return answer
            }
        }
    }

    let ax = Control(index: 1, role: "AXButton", title: "Share", actions: ["AXPress"], pathID: "0/1")
    let found = Control(index: 2, role: "AXButton", title: "Gear", pathID: "v1", fromVision: true)

    func testAXPressAsksAndOnlyThenPerforms() async {
        let e = FakeExecutor(); let no = Asker(false)
        let declined = await ActionRunner(executor: e, approve: no.callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(declined, .declined)
        XCTAssertEqual(e.axCalls, 0, "an unapproved AXPress never reaches the executor")
        XCTAssertEqual(no.asked.count, 1)

        let yes = Asker(true)
        let out = await ActionRunner(executor: e, approve: yes.callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(out, .done("Press the button \"Share\""))
        XCTAssertEqual(e.axDone, 1); XCTAssertEqual(e.clickCalls, 0); XCTAssertEqual(yes.asked.count, 1)
    }

    func testUnapprovedActionsAreRefusedAtTheExecutorBoundary() async {
        let e = FakeExecutor()
        let press = ProposedAction(control: ax, kind: .axPress, bundleID: "com.example")
        let click = ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example")
        let field = Control(index: 3, role: "AXTextField", title: "Name", value: "", pathID: "0/3")
        let type = ProposedAction(control: field, kind: .setValue("Rex"), bundleID: "com.example")
        // A token made for one action does not unlock another.
        let pressToken = ApprovalToken(action: press)
        let ax1 = await e.performAX(click, token: pressToken)
        XCTAssertEqual(ax1, .failed)
        let click1 = await e.click(click, token: pressToken)
        XCTAssertEqual(click1, .skipped("no approval"))
        let ax2 = await e.performAX(type, token: pressToken)
        XCTAssertEqual(ax2, .failed)
        XCTAssertEqual(e.axDone + e.clickDone, 0, "nothing was performed without a matching token")
        // A spent token cannot be replayed.
        let ax3 = await e.performAX(press, token: pressToken)
        XCTAssertEqual(ax3, .performed)
        let ax4 = await e.performAX(press, token: pressToken)
        XCTAssertEqual(ax4, .failed)
        XCTAssertEqual(e.axDone, 1)
    }

    func testSetValueAndClickAreNeverReachedWithoutAYes() async {
        let e = FakeExecutor(); let no = Asker(false)
        let field = Control(index: 3, role: "AXTextField", title: "Name", value: "", pathID: "0/3")
        let typed = await ActionRunner(executor: e, approve: no.callback()).run(ProposedAction(control: field, kind: .setValue("Rex"), bundleID: "com.example"))
        let clicked = await ActionRunner(executor: e, approve: no.callback()).run(ProposedAction(control: ax, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(typed, .declined); XCTAssertEqual(clicked, .declined)
        XCTAssertEqual(e.axCalls + e.clickCalls, 0)
    }

    func testAXFailureNeverClicksWithoutApproval() async {
        let e = FakeExecutor(); e.axResult = false
        let no = Asker(false)
        let out = await ActionRunner(executor: e, approve: no.callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(out, .declined)
        XCTAssertEqual(e.clickCalls, 0)
        XCTAssertEqual(no.asked.count, 1)
        XCTAssertEqual(no.asked.first?.action.kind, .axPress, "the press asks first; declining it ends the run")
    }

    func testAXFailureThenDecliningTheClickFallbackNeverClicks() async {
        let e = FakeExecutor(); e.axResult = false
        let answers = Asker(true)
        let callback: ApprovalCallback = { r in
            let first = answers.asked.isEmpty
            _ = await answers.callback()(r)
            return first   // yes to the press, no to the click that follows
        }
        let out = await ActionRunner(executor: e, approve: callback).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(out, .declined)
        XCTAssertEqual(answers.asked.map(\.action.kind), [.axPress, .clickPoint])
        XCTAssertEqual(e.clickCalls, 0)
    }

    func testAXFailureThenApprovalClicksOnce() async {
        let e = FakeExecutor(); e.axResult = false
        let yes = Asker(true)
        let out = await ActionRunner(executor: e, approve: yes.callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(out, .done("Click the button \"Share\""))
        XCTAssertEqual(e.clickDone, 1)
        XCTAssertEqual(yes.asked.count, 2, "the press asked, and the click fallback asked again")
    }

    func testVisionControlNeedsApprovalThenClicksAndNeverTriesAX() async {
        let e = FakeExecutor()
        let no = Asker(false)
        let declined = await ActionRunner(executor: e, approve: no.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(declined, .declined)
        XCTAssertEqual(e.clickCalls, 0); XCTAssertEqual(e.axCalls, 0)
        let yes = Asker(true)
        let done = await ActionRunner(executor: e, approve: yes.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(done, .done("Click the button \"Gear\" (found on screen)"))
        XCTAssertEqual(yes.asked.count, 1, "one approval for one click")
        XCTAssertEqual(e.clickDone, 1); XCTAssertEqual(e.axCalls, 0)
    }

    func testVisionControlWithAXPressKindStillOnlyClicksAfterApproval() async {
        let e = FakeExecutor()
        let no = Asker(false)
        let out = await ActionRunner(executor: e, approve: no.callback()).run(ProposedAction(control: found, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(out, .declined)
        XCTAssertEqual(e.clickCalls, 0); XCTAssertEqual(e.axCalls, 0)
    }

    func testClickSkippedByTheExecutorIsAFailureNotASuccess() async {
        let e = FakeExecutor(); e.clickResult = .skipped("the window moved")
        let out = await ActionRunner(executor: e, approve: Asker(true).callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(out, .failed("the window moved"))
    }

    func testTargetChangedOnTheClickNeedsFreshApprovalAndDoesNotRetry() async {
        let e = FakeExecutor(); e.clickResult = .targetChanged("the window changed")
        let a = Asker(true)
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(out, .needsFreshApproval("the window changed"))
        XCTAssertEqual(e.clickCalls, 1); XCTAssertEqual(a.asked.count, 1)
    }

    func testTargetChangedOnAXDoesNotFallBackToAClick() async {
        let e = FakeExecutor(); e.axChanged = "the label changed"
        let a = Asker(true)
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example"))
        XCTAssertEqual(out, .needsFreshApproval("the label changed"))
        XCTAssertEqual(e.clickCalls, 0); XCTAssertEqual(a.asked.count, 1)
    }

    func testRefusedActionsNeverReachTheExecutorOrAsk() async {
        let e = FakeExecutor(); let a = Asker(true)
        let buy = Control(index: 1, role: "AXButton", title: "Buy now", actions: ["AXPress"])
        let out = await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: buy, kind: .axPress, bundleID: "com.example"))
        guard case .refused = out else { return XCTFail("\(out)") }
        XCTAssertEqual(e.axCalls + e.clickCalls, 0); XCTAssertTrue(a.asked.isEmpty)
    }

    func testSetValueFailureDoesNotFallBackToAClick() async {
        let e = FakeExecutor(); e.axResult = false
        let field = Control(index: 1, role: "AXTextField", title: "Name", value: "", pathID: "0/2")
        let out = await ActionRunner(executor: e, approve: Asker(true).callback()).run(ProposedAction(control: field, kind: .setValue("Rex"), bundleID: "com.example"))
        guard case .failed = out else { return XCTFail("\(out)") }
        XCTAssertEqual(e.clickCalls, 0)
    }

    // MARK: cancellation

    func testCancelledBeforeAnythingNeitherAsksNorActs() async {
        let e = FakeExecutor(); let a = Asker(true)
        let runner = ActionRunner(executor: e, approve: a.callback())
        let action = ProposedAction(control: ax, kind: .axPress, bundleID: "com.example")
        let task = Task { () -> ActionOutcome in
            while !Task.isCancelled { await Task.yield() }
            return await runner.run(action)
        }
        task.cancel()
        let out = await task.value
        XCTAssertEqual(out, .cancelled)
        XCTAssertTrue(a.asked.isEmpty); XCTAssertEqual(e.axCalls + e.clickCalls, 0)
    }

    func testCancelledWhileTheApprovalWasPendingDoesNothingAfterTheYes() async {
        let e = FakeExecutor(); let a = Asker(true); a.cancelWhileAsking = true
        let runner = ActionRunner(executor: e, approve: a.callback())
        for kind in [ActionKind.axPress, .clickPoint] {
            let action = ProposedAction(control: ax, kind: kind, bundleID: "com.example")
            let out = await Task { await runner.run(action) }.value
            XCTAssertEqual(out, .cancelled, "\(kind)")
        }
        XCTAssertEqual(e.axCalls + e.clickCalls, 0, "an approval that arrives after cancellation is not acted on")
    }

    func testCancelledDuringTheClickIsReportedAsCancelledNotFailed() async {
        let e = FakeExecutor(); e.cancelDuringClick = true
        let out = await Task { await ActionRunner(executor: e, approve: Asker(true).callback()).run(ProposedAction(control: found, kind: .clickPoint, bundleID: "com.example")) }.value
        XCTAssertEqual(out, .cancelled)
    }

    func testCancelledBetweenTheFailedPressAndTheFallbackClickDoesNotAskAgain() async {
        let e = FakeExecutor(); e.axResult = false
        let a = Asker(true); a.cancelWhileAsking = true
        // The first approval cancels the task; the press is then not even attempted.
        let out = await Task { await ActionRunner(executor: e, approve: a.callback()).run(ProposedAction(control: ax, kind: .axPress, bundleID: "com.example")) }.value
        XCTAssertEqual(out, .cancelled)
        XCTAssertEqual(a.asked.count, 1); XCTAssertEqual(e.clickCalls, 0)
    }
}
