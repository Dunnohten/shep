import CoreGraphics
import XCTest
@testable import ShepCore

/// Label repair reads the window the dog sits on. A later read that applies the stored labels must pick the same window, not the app's
/// "main" one, or the labels are resolved against a window that was never scanned.
final class WindowReadTargetTests: XCTestCase {
    let mainFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let focusedFrame = CGRect(x: 900, y: 0, width: 500, height: 400)

    func windows() -> [AXWindowInfo] {
        [AXWindowInfo(title: "Main", subrole: "AXStandardWindow", frame: mainFrame, isMain: true, isFocused: false, zOrder: 0),
         AXWindowInfo(title: "Inspector", subrole: "AXStandardWindow", frame: focusedFrame, isMain: false, isFocused: true, zOrder: 1)]
    }

    func testTheDefaultSelectionIsTheMainWindowAndTheFocusedTargetIsTheFocusedOne() {
        XCTAssertEqual(WindowReadTarget(frame: nil, title: nil, preferFocused: false).selection(in: windows()), 0, "what the old later read did")
        XCTAssertEqual(WindowReadTarget.focused(frame: focusedFrame, title: "Inspector").selection(in: windows()), 1)
    }

    func testTheFocusedWindowIsPreferredEvenWhenItsFrameAndTitleCannotBeRead() {
        XCTAssertEqual(WindowReadTarget.focused(frame: nil, title: nil).selection(in: windows()), 1, "falls back to the focused window, not main")
        XCTAssertEqual(WindowReadTarget.focused(frame: nil, title: "   ").selection(in: windows()), 1)
        XCTAssertNil(WindowReadTarget.focused(frame: nil, title: "  ").title)
    }

    func testBothReadsOfOneWindowPickTheSameWindowAndTheSameControlsEndToEnd() {
        func node(_ tag: String, in frame: CGRect) -> LabelTestNode {
            LabelTestNode(role: "AXWindow", subrole: "AXStandardWindow", title: tag, frame: frame,
                          kids: [LabelTestNode(role: "AXButton", frame: CGRect(x: frame.minX + 10, y: frame.minY + 40, width: 30, height: 24), actions: ["AXPress", tag])])
        }
        let entries = [AXWindowEntry(info: windows()[0], root: node("Main", in: mainFrame)), AXWindowEntry(info: windows()[1], root: node("Inspector", in: focusedFrame))]
        let target = WindowReadTarget.focused(frame: focusedFrame, title: "Inspector")
        // The label-repair read and the later read are built from the same target, so they cannot disagree.
        let repair = AXTreeReader.read(windows: entries, targetFrame: target.frame, targetTitle: target.title, limits: .labelScan, clock: { 0 },
                                       preferFocused: target.preferFocused)!
        let later = AXTreeReader.read(windows: entries, targetFrame: target.frame, targetTitle: target.title, limits: .standard, clock: { 0 },
                                      preferFocused: target.preferFocused)!
        XCTAssertEqual(repair.target, 1)
        XCTAssertEqual(later.target, 1)
        XCTAssertEqual(repair.controls.compactMap { $0.actions.last }.filter { $0 == "Inspector" || $0 == "Main" }, ["Inspector"])
        XCTAssertEqual(later.controls.compactMap { $0.actions.last }.filter { $0 == "Inspector" || $0 == "Main" }, ["Inspector"])
        // The old later read (no target) would have read Main.
        let old = AXTreeReader.read(windows: entries, targetFrame: nil, targetTitle: nil, limits: .standard, clock: { 0 })!
        XCTAssertEqual(old.target, 0)
    }
}
