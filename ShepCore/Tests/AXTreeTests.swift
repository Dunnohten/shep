import CoreGraphics
import XCTest
@testable import ShepCore

/// A node of a synthetic Accessibility tree.
struct FakeAX: AXNodeSource {
    var role: String
    var subrole: String = ""
    var title: String = ""
    var descriptionText: String = ""
    var help: String = ""
    var valueText: String? = nil
    var frame: CGRect? = nil
    var isEnabled: Bool = true
    var actions: [String] = []
    var kids: [FakeAX] = []
    func children() -> [FakeAX] { kids }
}

/// Shaped like the main window of a torrent client ("Sample Torrent App": made-up names, no real data) plus a modal alert.
enum SampleTorrentApp {
    static let mainFrame = CGRect(x: 100, y: 100, width: 900, height: 600)
    static let alertFrame = CGRect(x: 300, y: 250, width: 420, height: 160)

    static func button(_ title: String = "", description: String = "", help: String = "", x: CGFloat, y: CGFloat = 110, subrole: String = "") -> FakeAX {
        FakeAX(role: "AXButton", subrole: subrole, title: title, descriptionText: description, help: help,
               frame: CGRect(x: x, y: y, width: 30, height: 24), actions: ["AXPress"])
    }

    static func checkbox(_ title: String = "", help: String = "", x: CGFloat, y: CGFloat, value: String = "0") -> FakeAX {
        FakeAX(role: "AXCheckBox", title: title, help: help, valueText: value, frame: CGRect(x: x, y: y, width: 80, height: 18), actions: ["AXPress"])
    }

    static let tip = "Speed Limit overrides the total bandwidth limits with its own limits."

    /// 1 window, toolbar (2 groups of buttons), segmented buttons, 4 filter checkboxes, a search field with an inner button,
    /// a table, a status bar with a "..." button (tooltip only) and a tooltip-only checkbox, and the window buttons.
    static func mainWindow() -> FakeAX {
        let toolbar = FakeAX(role: "AXToolbar", frame: CGRect(x: 100, y: 100, width: 900, height: 40), kids: [
            FakeAX(role: "AXGroup", frame: CGRect(x: 110, y: 104, width: 200, height: 32), kids: [
                button(description: "Open", x: 110, y: 104), button(description: "Remove", x: 150, y: 104), button(description: "Pause", x: 190, y: 104),
            ]),
            FakeAX(role: "AXGroup", frame: CGRect(x: 320, y: 104, width: 200, height: 32), kids: [
                button(description: "Resume", x: 320, y: 104), button(description: "Info", x: 360, y: 104),
            ]),
            FakeAX(role: "AXRadioGroup", frame: CGRect(x: 540, y: 104, width: 200, height: 32), kids: [
                FakeAX(role: "AXRadioButton", title: "All", frame: CGRect(x: 540, y: 104, width: 60, height: 24), actions: ["AXPress"]),
                FakeAX(role: "AXRadioButton", title: "Active", frame: CGRect(x: 600, y: 104, width: 60, height: 24), actions: ["AXPress"]),
            ]),
            FakeAX(role: "AXTextField", subrole: "AXSearchField", descriptionText: "Search", valueText: "", frame: CGRect(x: 780, y: 104, width: 200, height: 24),
                   actions: ["AXConfirm"], kids: [button(description: "cancel", x: 955, y: 106, subrole: "AXSearchFieldCancelButton")]),
        ])
        let filters = FakeAX(role: "AXGroup", frame: CGRect(x: 100, y: 140, width: 900, height: 24), kids: [
            checkbox("Downloading", x: 110, y: 142), checkbox("Seeding", x: 200, y: 142), checkbox("Paused", x: 290, y: 142), checkbox("Error", x: 380, y: 142),
        ])
        let table = FakeAX(role: "AXScrollArea", frame: CGRect(x: 100, y: 170, width: 900, height: 480), kids: [
            FakeAX(role: "AXTable", frame: CGRect(x: 100, y: 170, width: 900, height: 480), kids: [
                FakeAX(role: "AXRow", frame: CGRect(x: 100, y: 170, width: 900, height: 40), kids: [
                    FakeAX(role: "AXStaticText", valueText: "sample-file.iso", frame: CGRect(x: 110, y: 175, width: 300, height: 20)),
                ]),
            ]),
        ])
        let statusBar = FakeAX(role: "AXGroup", frame: CGRect(x: 100, y: 660, width: 900, height: 40), kids: [
            checkbox(help: tip, x: 110, y: 670),
            button(help: "Shortcuts for changing global settings.", x: 960, y: 668),
        ])
        let windowButtons = [
            button(description: "close button", x: 108, y: 108, subrole: "AXCloseButton"),
            button(description: "minimize button", x: 140, y: 108, subrole: "AXMinimizeButton"),
            button(description: "zoom button", x: 172, y: 108, subrole: "AXZoomButton"),
        ]
        return FakeAX(role: "AXWindow", subrole: "AXStandardWindow", title: "Sample Torrent App", frame: mainFrame,
                      kids: windowButtons + [toolbar, filters, table, statusBar])
    }

    static func alertWindow() -> FakeAX {
        FakeAX(role: "AXWindow", subrole: "AXDialog", title: "", frame: alertFrame, kids: [
            FakeAX(role: "AXStaticText", valueText: "Quit while transfers are active?", frame: CGRect(x: 320, y: 270, width: 380, height: 20)),
            FakeAX(role: "AXButton", title: "Cancel", frame: CGRect(x: 330, y: 360, width: 80, height: 24), actions: ["AXPress"]),
            FakeAX(role: "AXButton", title: "Quit", frame: CGRect(x: 620, y: 360, width: 80, height: 24), actions: ["AXPress"]),
        ])
    }

    static func info(_ node: FakeAX, main: Bool = false, focused: Bool = false, modalFlag: Bool = false) -> AXWindowInfo {
        AXWindowInfo(title: node.title, subrole: node.subrole, frame: node.frame, isMain: main, isFocused: focused, modalFlag: modalFlag)
    }

    /// The order AXWindows gives: the alert first (it is focused), then the main window.
    static func windowsWithAlert() -> [AXWindowEntry<FakeAX>] {
        let main = mainWindow(), alert = alertWindow()
        return [AXWindowEntry(info: info(alert, focused: true), root: alert), AXWindowEntry(info: info(main, main: true), root: main)]
    }
}

final class AXTreeReadTests: XCTestCase {
    let t0: () -> TimeInterval = { 0 }

    func read(_ windows: [AXWindowEntry<FakeAX>], frame: CGRect? = nil, title: String? = nil, limits: AXWalkLimits = .standard,
              clock: (() -> TimeInterval)? = nil) -> AXReadResult<FakeAX> {
        guard let r = AXTreeReader.read(windows: windows, targetFrame: frame, targetTitle: title, limits: limits, clock: clock ?? t0) else {
            XCTFail("no result"); fatalError("no result")
        }
        return r
    }

    func labels(_ r: AXReadResult<FakeAX>) -> [String] { r.controls.map { $0.label } }

    // MARK: the focused modal no longer hides the main window

    func testFocusedModalStillReturnsTheMainWindowsControls() {
        let r = read(SampleTorrentApp.windowsWithAlert())
        XCTAssertEqual(r.target, 1, "the main window is the target even though the alert is listed first and focused")
        XCTAssertTrue(r.windows[1].isTarget)
        XCTAssertFalse(r.windows[0].isTarget)
        let names = labels(r)
        for expected in ["Open", "Remove", "Pause", "Downloading", "Seeding", "Search", "close button", SampleTorrentApp.tip] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        XCTAssertTrue(r.controls.filter { $0.window == "Sample Torrent App" }.count > 20)
    }

    func testTheModalsButtonsAreKeptAndTaggedWithTheirWindow() {
        let r = read(SampleTorrentApp.windowsWithAlert())
        let quit = r.controls.first { $0.label == "Quit" }
        XCTAssertNotNil(quit)
        XCTAssertEqual(quit?.windowSubrole, "AXDialog")
        XCTAssertEqual(quit?.window, "")
        let mainButton = r.controls.first { $0.label == "Open" }
        XCTAssertEqual(mainButton?.windowSubrole, "AXStandardWindow")
        XCTAssertEqual(mainButton?.window, "Sample Torrent App")
    }

    func testPathIDsAreUniqueAcrossWindows() {
        let r = read(SampleTorrentApp.windowsWithAlert())
        let ids = r.controls.map { $0.pathID }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testModalInFrontIsReportedForADialogOverTheTarget() {
        XCTAssertTrue(read(SampleTorrentApp.windowsWithAlert()).modalInFront)
        let main = SampleTorrentApp.mainWindow()
        let alone = read([AXWindowEntry(info: SampleTorrentApp.info(main, main: true), root: main)])
        XCTAssertFalse(alone.modalInFront)
        XCTAssertEqual(alone.windows.count, 1)
    }

    func testModalFlagOnAStandardSubroleCounts() {
        let main = SampleTorrentApp.mainWindow()
        var other = SampleTorrentApp.alertWindow(); other.subrole = "AXStandardWindow"
        let r = read([AXWindowEntry(info: SampleTorrentApp.info(main, main: true), root: main),
                      AXWindowEntry(info: SampleTorrentApp.info(other, modalFlag: true), root: other)])
        XCTAssertTrue(r.modalInFront)
    }

    func testWhenTheDialogIsTheTargetNoModalInFrontIsReported() {
        let windows = SampleTorrentApp.windowsWithAlert()
        let r = read(windows, frame: SampleTorrentApp.alertFrame)
        XCTAssertEqual(r.target, 0)
        XCTAssertFalse(r.modalInFront)
    }

    func testASheetThatDoesNotOverlapTheTargetIsNotInFront() {
        let main = SampleTorrentApp.mainWindow()
        var far = SampleTorrentApp.alertWindow(); far.subrole = "AXSheet"; far.frame = CGRect(x: 3000, y: 3000, width: 300, height: 100)
        let r = read([AXWindowEntry(info: SampleTorrentApp.info(main, main: true), root: main), AXWindowEntry(info: SampleTorrentApp.info(far), root: far)])
        XCTAssertFalse(r.modalInFront)
    }

    func testControlsOfAnotherWindowAreKeptOnlyWhenTheyOverlapTheTarget() {
        let main = SampleTorrentApp.mainWindow()
        var far = SampleTorrentApp.alertWindow(); far.subrole = "AXStandardWindow"; far.title = "Elsewhere"
        far.frame = CGRect(x: 3000, y: 3000, width: 300, height: 100)
        far.kids = [FakeAX(role: "AXButton", title: "Far away", frame: CGRect(x: 3010, y: 3010, width: 50, height: 20), actions: ["AXPress"])]
        let r = read([AXWindowEntry(info: SampleTorrentApp.info(main, main: true), root: main), AXWindowEntry(info: SampleTorrentApp.info(far), root: far)])
        XCTAssertFalse(labels(r).contains("Far away"))
        XCTAssertEqual(r.windows[1].nodesVisited, 0, "P1-3: an unrelated window is rejected before any child or value getter (it used to be read and then dropped)")
    }

    // MARK: choosing the target window

    func testTargetFrameWithinFourPointsPicksThatWindow() {
        let a = SampleTorrentApp.mainWindow()
        var b = SampleTorrentApp.mainWindow(); b.title = "Second"; b.frame = CGRect(x: 120, y: 140, width: 900, height: 600)
        let windows = [AXWindowEntry(info: SampleTorrentApp.info(a, main: true), root: a), AXWindowEntry(info: SampleTorrentApp.info(b), root: b)]
        XCTAssertEqual(read(windows, frame: CGRect(x: 123, y: 143, width: 902, height: 598)).target, 1, "3 pt off still matches")
        XCTAssertEqual(read(windows, frame: CGRect(x: 100, y: 100, width: 900, height: 600)).target, 0)
        XCTAssertEqual(read(windows, frame: CGRect(x: 126, y: 140, width: 900, height: 600)).target, 0, "6 pt off matches nothing: main window")
    }

    func testTitleBreaksTiesAndIsUsedWithoutAFrame() {
        let a = SampleTorrentApp.mainWindow()
        var b = SampleTorrentApp.mainWindow(); b.title = "Second"
        let windows = [AXWindowEntry(info: SampleTorrentApp.info(a, main: true), root: a), AXWindowEntry(info: SampleTorrentApp.info(b), root: b)]
        XCTAssertEqual(read(windows, frame: SampleTorrentApp.mainFrame, title: "second").target, 1, "same frame twice: the title decides")
        XCTAssertEqual(read(windows, title: "Second").target, 1)
        XCTAssertEqual(read(windows, title: "econd").target, 1, "contains")
        XCTAssertEqual(read(windows, title: "nothing like it").target, 0, "no title match: the main window")
    }

    func testFallbacksAreMainThenFocusedNonModalThenFirst() {
        let a = SampleTorrentApp.mainWindow(), alert = SampleTorrentApp.alertWindow()
        var c = SampleTorrentApp.mainWindow(); c.title = "Third"
        let w = { (flags: [(Bool, Bool)]) -> [AXWindowEntry<FakeAX>] in
            [AXWindowEntry(info: SampleTorrentApp.info(alert, main: flags[0].0, focused: flags[0].1), root: alert),
             AXWindowEntry(info: SampleTorrentApp.info(a, main: flags[1].0, focused: flags[1].1), root: a),
             AXWindowEntry(info: SampleTorrentApp.info(c, main: flags[2].0, focused: flags[2].1), root: c)]
        }
        XCTAssertEqual(read(w([(false, true), (false, false), (true, false)])).target, 2, "main wins over a focused alert")
        XCTAssertEqual(read(w([(false, true), (false, false), (false, false)])).target, 1, "the focused alert is modal: the first non-modal window")
        XCTAssertEqual(read(w([(false, false), (false, true), (false, false)])).target, 1, "focused non-modal")
        XCTAssertEqual(read(w([(false, false), (false, false), (false, false)])).target, 1, "first non-modal (window 0 is the alert)")
        XCTAssertEqual(read([AXWindowEntry(info: SampleTorrentApp.info(alert), root: alert)]).target, 0, "only modals: the first")
    }

    func testNoWindowsGivesNoResult() {
        XCTAssertNil(AXTreeReader.read(windows: [AXWindowEntry<FakeAX>](), targetFrame: nil, targetTitle: nil, clock: t0))
    }

    // MARK: shared caps, target first

    func testCapsAreSharedAndTheTargetIsWalkedFirst() {
        var limits = AXWalkLimits.standard
        limits.maxNodes = 12
        let r = read(SampleTorrentApp.windowsWithAlert(), limits: limits)
        XCTAssertEqual(r.nodesVisited, 12)
        XCTAssertEqual(r.windows[1].nodesVisited, 12, "the target (listed second) took the whole budget")
        XCTAssertEqual(r.windows[0].nodesVisited, 0, "the alert got nothing and could not starve it")
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.controls.count, 12)
        XCTAssertTrue(r.controls.allSatisfy { $0.window == "Sample Torrent App" })
    }

    func testLeftoverBudgetGoesToOtherWindows() {
        var limits = AXWalkLimits.standard
        let total = read(SampleTorrentApp.windowsWithAlert()).nodesVisited
        limits.maxNodes = total
        let r = read(SampleTorrentApp.windowsWithAlert(), limits: limits)
        XCTAssertFalse(r.truncated, "exactly enough")
        XCTAssertEqual(r.nodesVisited, total)
        limits.maxNodes = total - 1
        XCTAssertTrue(read(SampleTorrentApp.windowsWithAlert(), limits: limits).truncated)
    }

    func testTimeBudgetIsSharedAndUsesTheInjectedClock() {
        final class Ticker { var calls = 0; func next() -> TimeInterval { defer { calls += 1 }; return Double(calls) * 0.5 } }
        let ticker = Ticker()
        let r = read(SampleTorrentApp.windowsWithAlert(), clock: { ticker.next() })
        // The budget made its deadline at t=0 (2.0 s); checks at 0.5, 1.0, 1.5, 2.0 pass (not past it), 2.5 stops.
        XCTAssertEqual(r.nodesVisited, 4)
        XCTAssertTrue(r.truncated)
    }

    // MARK: walker rules

    func testSecureFieldsAreListedWithoutValueAndNotDescended() {
        let secret = FakeAX(role: "AXTextField", subrole: "AXSecureTextField", title: "Password", valueText: "hunter2",
                            frame: CGRect(x: 0, y: 0, width: 100, height: 20),
                            kids: [FakeAX(role: "AXStaticText", valueText: "inner-secret", frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        let root = FakeAX(role: "AXWindow", subrole: "AXStandardWindow", title: "Login", frame: CGRect(x: 0, y: 0, width: 200, height: 100), kids: [secret])
        let r = read([AXWindowEntry(info: SampleTorrentApp.info(root, main: true), root: root)])
        XCTAssertEqual(r.nodesVisited, 2)
        let field = r.controls.first { $0.isSecure }
        XCTAssertNotNil(field)
        XCTAssertNil(field?.value)
        XCTAssertFalse(r.controls.contains { $0.value == "inner-secret" })
    }

    func testMenuBarsAreListedButNotDescended() {
        let bar = FakeAX(role: "AXMenuBar", frame: CGRect(x: 0, y: 0, width: 500, height: 24),
                         kids: [FakeAX(role: "AXMenuBarItem", title: "File", frame: CGRect(x: 0, y: 0, width: 40, height: 24), actions: ["AXPress"])])
        let root = FakeAX(role: "AXWindow", title: "W", frame: CGRect(x: 0, y: 0, width: 200, height: 100), kids: [bar])
        let r = read([AXWindowEntry(info: SampleTorrentApp.info(root, main: true), root: root)])
        XCTAssertEqual(r.nodesVisited, 2)
        XCTAssertFalse(labels(r).contains("File"))
    }

    func testDepthCapStopsDescendingWithoutFlaggingTruncation() {
        var node = FakeAX(role: "AXGroup", title: "leaf", frame: CGRect(x: 0, y: 0, width: 5, height: 5))
        for d in 0..<12 { node = FakeAX(role: "AXGroup", title: "level\(d)", frame: CGRect(x: 0, y: 0, width: 5, height: 5), kids: [node]) }
        let root = FakeAX(role: "AXWindow", title: "W", frame: CGRect(x: 0, y: 0, width: 50, height: 50), kids: [node])
        let r = read([AXWindowEntry(info: SampleTorrentApp.info(root, main: true), root: root)])
        XCTAssertEqual(r.nodesVisited, 9, "window at depth 0 plus depths 1...8")
        XCTAssertFalse(r.truncated, "the depth cap is not the node or time cap")
        XCTAssertFalse(labels(r).contains("leaf"))
    }

    func testStandardLimitsAreTheOldCaps() {
        XCTAssertEqual(AXWalkLimits.standard, AXWalkLimits(maxDepth: 8, maxNodes: 400, timeBudget: 2.0))
    }

    func testTruncationFlagNeedsNodesLeftBehind() {
        let kids = (0..<4).map { FakeAX(role: "AXButton", title: "b\($0)", frame: CGRect(x: 0, y: 0, width: 5, height: 5), actions: ["AXPress"]) }
        let root = FakeAX(role: "AXWindow", title: "W", frame: CGRect(x: 0, y: 0, width: 50, height: 50), kids: kids)
        let windows = [AXWindowEntry(info: SampleTorrentApp.info(root, main: true), root: root)]
        XCTAssertFalse(read(windows, limits: AXWalkLimits(maxDepth: 8, maxNodes: 5, timeBudget: 2)).truncated)
        XCTAssertTrue(read(windows, limits: AXWalkLimits(maxDepth: 8, maxNodes: 4, timeBudget: 2)).truncated)
    }

    // MARK: tooltip labels

    func testTooltipOnlyControlsAreNamedByTheirTooltipAndMarked() {
        let r = read(SampleTorrentApp.windowsWithAlert())
        let turtle = r.controls.first { $0.help == SampleTorrentApp.tip }
        XCTAssertEqual(turtle?.label, SampleTorrentApp.tip)
        XCTAssertEqual(turtle?.labelSource, .tooltip)
        XCTAssertTrue(turtle?.line.contains("(named by its tooltip)") ?? false)
        let dots = r.controls.first { $0.help == "Shortcuts for changing global settings." }
        XCTAssertEqual(dots?.labelSource, .tooltip)
    }

    func testTheTooltipIsTheLastResort() {
        XCTAssertEqual(Control(role: "AXButton", title: "Go", description: "Start", help: "Tip").labelSource, .title)
        XCTAssertEqual(Control(role: "AXButton", description: "Start", help: "Tip").labelSource, .description)
        XCTAssertEqual(Control(role: "AXStaticText", value: "Hello", help: "Tip").labelSource, .value)
        XCTAssertEqual(Control(role: "AXStaticText", value: "Hello", help: "Tip").label, "Hello")
        XCTAssertEqual(Control(role: "AXCheckBox", value: "1", help: "Tip").labelSource, .tooltip, "a checkbox's 1 is not its name")
        XCTAssertEqual(Control(role: "AXButton", title: " ", help: "").labelSource, .none)
        XCTAssertFalse(Control(role: "AXButton", title: "Go", help: "Tip").line.contains("tooltip"))
    }

    func testTheApprovalSummaryAdmitsATooltipName() {
        let c = Control(role: "AXCheckBox", help: SampleTorrentApp.tip, actions: ["AXPress"], pathID: "1/9")
        let summary = ProposedAction(control: c, kind: .axPress, bundleID: "com.example.sample").summary
        XCTAssertEqual(summary, "Press the checkbox \"\(SampleTorrentApp.tip)\" (named by its tooltip)")
    }

    // MARK: the whole fixture through the existing filter

    func testPrepareKeepsTheActionableSubsetOfTheFixture() {
        let r = read(SampleTorrentApp.windowsWithAlert())
        let kept = ControlFilter.prepare(r.controls, limit: 200, window: SampleTorrentApp.mainFrame)
        XCTAssertLessThan(kept.count, r.nodesVisited, "static text, groups, the table and the window are not offered")
        XCTAssertTrue(kept.allSatisfy { ControlFilter.isUseful($0) })
        // Main window: 3 window buttons, 5 toolbar buttons, 2 radio buttons, search field + its cancel button, 4 filters, 2 tooltip-only = 18.
        XCTAssertEqual(kept.filter { $0.window == "Sample Torrent App" }.count, 18)
        XCTAssertEqual(kept.filter { $0.windowSubrole == "AXDialog" }.count, 2)
    }
}
