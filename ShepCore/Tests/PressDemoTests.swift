import CoreGraphics
import XCTest
@testable import ShepCore

final class PressDemoTests: XCTestCase {
    let bundle = "com.example.sampletorrent"
    let tip = SampleTorrentApp.tip

    var turtle: Control {
        Control(index: 1, role: "AXCheckBox", window: "Sample Torrent App", value: "0", help: tip,
                frame: CGRect(x: 110, y: 670, width: 18, height: 18), actions: ["AXPress"], pathID: "1/9")
    }
    var dots: Control {
        Control(index: 2, role: "AXButton", window: "Sample Torrent App", help: "Shortcuts for changing global settings.",
                frame: CGRect(x: 960, y: 668, width: 30, height: 24), actions: ["AXPress"], pathID: "1/10")
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        func callback() -> @Sendable (String) -> Void { { [self] s in add(s) } }
    }

    // MARK: choosing

    func testASingleMatchByTooltipIsChosen() {
        XCTAssertEqual(PressDemo.select([turtle, dots], match: "Speed Limit"), .one(turtle))
        XCTAssertEqual(PressDemo.select([turtle, dots], match: "speed limit overrides"), .one(turtle), "case-insensitive")
        XCTAssertEqual(PressDemo.select([turtle, dots], match: "Shortcuts for changing"), .one(dots))
    }

    func testNoMatchAndAnEmptyMatchPressNothing() {
        XCTAssertEqual(PressDemo.select([turtle, dots], match: "nothing like it"), .none)
        XCTAssertEqual(PressDemo.select([turtle, dots], match: "  "), .none)
        XCTAssertNotNil(PressDemo.refusal(.none, match: "x"))
    }

    func testTwoMatchesAreRefusedAndListed() {
        let selection = PressDemo.select([turtle, dots], match: "s")
        guard case .ambiguous(let list) = selection else { return XCTFail("\(selection)") }
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(PressDemo.refusal(selection, match: "s")?.contains("2 controls match") ?? false)
    }

    func testADisabledMatchIsRefused() async {
        var off = turtle; off.enabled = false
        let selection = PressDemo.select([off], match: "Speed Limit")
        XCTAssertEqual(selection, .disabledOnly([off]))
        XCTAssertNotNil(PressDemo.refusal(selection, match: "Speed Limit"))
        // And even handed straight to the runner it is not performed.
        let exec = ActionRunnerTests.FakeExecutor()
        let log = Log()
        let outcome = await PressDemo.run(control: off, bundleID: bundle, approveFlag: true, executor: exec, log: log.callback())
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(exec.axCalls, 0)
        XCTAssertTrue(PressDemo.preview(PressDemo.proposal(for: off, bundleID: bundle)).hasPrefix("refused:"))
    }

    func testADisabledDuplicateDoesNotMakeAnEnabledMatchAmbiguous() {
        var off = turtle; off.enabled = false; off.pathID = "1/11"
        XCTAssertEqual(PressDemo.select([off, turtle], match: "Speed Limit"), .one(turtle))
    }

    func testSecureFieldsNeverMatch() {
        let pw = Control(role: "AXTextField", subrole: "AXSecureTextField", title: "Speed Limit", actions: ["AXPress"])
        XCTAssertEqual(PressDemo.select([pw], match: "Speed Limit"), .none)
    }

    // MARK: the card

    func testTheCardForATooltipOnlyCheckbox() {
        let action = PressDemo.proposal(for: turtle, bundleID: bundle)
        XCTAssertEqual(action.kind, .axPress)
        XCTAssertEqual(PressDemo.preview(action), "Press the checkbox \"\(tip)\" (named by its tooltip)?\nShep asks before every action.")
    }

    func testThePreviewIsTheSameTextTheRunnerAsks() async {
        let asker = ActionRunnerTests.Asker(false)
        let action = PressDemo.proposal(for: turtle, bundleID: bundle)
        _ = await ActionRunner(executor: ActionRunnerTests.FakeExecutor(), approve: asker.callback()).run(action)
        XCTAssertEqual(asker.asked.count, 1)
        XCTAssertEqual(asker.asked[0].cardText, PressDemo.preview(action))
    }

    // MARK: approval

    func testNoPressWithoutTheFlag() async {
        let exec = ActionRunnerTests.FakeExecutor()
        let log = Log()
        let outcome = await PressDemo.run(control: turtle, bundleID: bundle, approveFlag: false, executor: exec, log: log.callback())
        XCTAssertEqual(outcome, .declined)
        XCTAssertEqual(exec.axCalls, 0, "the executor was never reached")
        XCTAssertEqual(exec.clickCalls, 0)
        XCTAssertTrue(log.all.contains("declined: no --approve given"))
    }

    func testExactlyOnePressWithTheFlag() async {
        let exec = ActionRunnerTests.FakeExecutor()
        let log = Log()
        let outcome = await PressDemo.run(control: turtle, bundleID: bundle, approveFlag: true, executor: exec, log: log.callback())
        XCTAssertEqual(outcome, .done("Press the checkbox \"\(tip)\" (named by its tooltip)"))
        XCTAssertEqual(exec.axDone, 1)
        XCTAssertEqual(exec.clickCalls, 0)
        XCTAssertTrue(log.all.contains("approved by explicit --approve flag"))
    }

    func testAFailedPressNeverFallsBackToAClick() async {
        let exec = ActionRunnerTests.FakeExecutor()
        exec.axResult = false
        let log = Log()
        let outcome = await PressDemo.run(control: turtle, bundleID: bundle, approveFlag: true, executor: exec, log: log.callback())
        XCTAssertEqual(outcome, .declined, "the click fallback asks a second time and the demo says no")
        XCTAssertEqual(exec.clickDone, 0)
        XCTAssertTrue(log.all.contains { $0.contains("second approval") })
    }

    func testAControlWithoutAXPressIsNotPressed() async {
        var noPress = turtle; noPress.actions = []
        let exec = ActionRunnerTests.FakeExecutor()
        let outcome = await PressDemo.run(control: noPress, bundleID: bundle, approveFlag: true, executor: exec, log: Log().callback())
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(exec.axCalls + exec.clickCalls, 0)
    }

    /// Keeps the token the runner made so the test can try to use it again.
    final class KeepingExecutor: ActionExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: ApprovalToken?
        var token: ApprovalToken? { lock.lock(); defer { lock.unlock() }; return kept }
        func performAX(_ action: ProposedAction, token: ApprovalToken) async -> AXResult {
            lock.lock(); kept = token; lock.unlock()
            return token.consume(for: action) ? .performed : .failed
        }
        func click(_ action: ProposedAction, token: ApprovalToken) async -> ClickResult { .skipped("no") }
    }

    func testTheTokenWorksOnlyOnce() async {
        let exec = KeepingExecutor()
        let action = PressDemo.proposal(for: turtle, bundleID: bundle)
        let outcome = await PressDemo.run(control: turtle, bundleID: bundle, approveFlag: true, executor: exec, log: Log().callback())
        guard case .done = outcome else { return XCTFail("\(outcome)") }
        let token = try! XCTUnwrap(exec.token)
        XCTAssertFalse(token.consume(for: action), "already spent by the one press")
    }

    func testAPolicyRefusedTooltipIsStillRefused() async {
        var risky = turtle; risky.help = "Delete everything"
        let exec = ActionRunnerTests.FakeExecutor()
        let outcome = await PressDemo.run(control: risky, bundleID: bundle, approveFlag: true, executor: exec, log: Log().callback())
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(exec.axCalls, 0)
    }

    func testTheControlPolicyRefusalWordsAreUnchanged() {
        XCTAssertEqual(ControlPolicy.deniedWords, [
            "pay", "buy", "purchase", "subscribe", "checkout", "check out", "order", "send money", "transfer", "delete account",
            "erase", "format", "shut down", "restart", "log out", "sign in", "log in", "password", "empty trash", "factory reset",
            "uninstall", "remove account", "delete",
        ])
        XCTAssertNil(ControlPolicy.refusal(turtle, bundleID: bundle))
        XCTAssertNil(ControlPolicy.refusal(dots, bundleID: bundle))
    }
}

final class AXReadReportTests: XCTestCase {
    func fixtureReport() -> (String, Int, Int) {
        let r = AXTreeReader.read(windows: SampleTorrentApp.windowsWithAlert(), targetFrame: nil, targetTitle: nil, clock: { 0 })!
        let kept = ControlFilter.prepare(r.controls, limit: 200, window: SampleTorrentApp.mainFrame)
        let text = AXReadReport.render(windows: r.windows, nodesVisited: r.nodesVisited, kept: kept, truncated: r.truncated, modalInFront: r.modalInFront)
        return (text, kept.count, r.nodesVisited)
    }

    func testTheGreppableLines() {
        let (text, kept, visited) = fixtureReport()
        XCTAssertTrue(text.contains("\ncontrols_kept: \(kept)\n"))
        XCTAssertTrue(text.contains("\nnodes_visited: \(visited)\n"))
        XCTAssertTrue(text.contains("\ntruncated: no"))
        XCTAssertTrue(text.contains("\nmodal_in_front: yes"))
        XCTAssertTrue(text.hasSuffix("modal_notice: a dialog is open in front of this window"))
    }

    func testTheSelectedWindowAndEveryWindowAreListed() {
        let (text, _, _) = fixtureReport()
        XCTAssertTrue(text.hasPrefix("selected_window: title=\"Sample Torrent App\" frame=100,100,900,600 subrole=AXStandardWindow"))
        XCTAssertTrue(text.contains("windows_seen: 2"))
        XCTAssertTrue(text.contains("subrole=AXDialog modal=yes target=no"))
        XCTAssertTrue(text.contains("modal=no target=yes"))
    }

    func testTooltipControlsShowTheirLabelSource() {
        let (text, _, _) = fixtureReport()
        let lines = text.split(separator: "\n").map(String.init)
        let turtle = lines.first { $0.contains(SampleTorrentApp.tip) }
        XCTAssertNotNil(turtle)
        XCTAssertTrue(turtle?.contains("source=tooltip") ?? false)
        XCTAssertTrue(turtle?.contains("AXCheckBox") ?? false)
        XCTAssertTrue(turtle?.contains("actions=AXPress") ?? false)
        XCTAssertTrue(lines.contains { $0.contains("\"Open\" source=description") })
    }

    func testNoDialogMeansNoNotice() {
        let main = SampleTorrentApp.mainWindow()
        let r = AXTreeReader.read(windows: [AXWindowEntry(info: SampleTorrentApp.info(main, main: true), root: main)],
                                  targetFrame: nil, targetTitle: nil, clock: { 0 })!
        let text = AXReadReport.render(windows: r.windows, nodesVisited: r.nodesVisited, kept: [], truncated: r.truncated, modalInFront: r.modalInFront)
        XCTAssertTrue(text.contains("modal_in_front: no"))
        XCTAssertFalse(text.contains("modal_notice"))
        XCTAssertTrue(text.contains("controls_kept: 0"))
    }
}

final class ModalNoticeTests: XCTestCase {
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)

    func testThePipelineSaysADialogIsOpenInFront() async {
        let fake = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
        let open = VisionInput(png: Data([1]), geometry: geometry, axControls: [], bundleID: "com.example.chat", windowTitle: "Inbox", modalInFront: true)
        let closed = VisionInput(png: Data([1]), geometry: geometry, axControls: [], bundleID: "com.example.chat", windowTitle: "Inbox")
        let a = await FixScreenPipeline(provider: fake).run(open)
        let b = await FixScreenPipeline(provider: fake).run(closed)
        XCTAssertEqual(a.notes.first, "a dialog is open in front of this window")
        XCTAssertFalse(b.notes.contains { $0.contains("dialog is open") })
    }
}
