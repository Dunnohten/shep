import CoreGraphics
import XCTest
@testable import ShepCore

final class LabelFingerprintTests: XCTestCase {
    let size = CGSize(width: 600, height: 800)

    func input(id: String = "", role: String = "AXButton", path: [String] = ["AXWindow", "AXGroup[0]", "AXButton[0]"], nearby: [String] = ["Playback"],
               help: String = "", at p: CGPoint = CGPoint(x: 215, y: 130)) -> LabelFingerprint.Input {
        LabelFingerprint.Input(role: role, subrole: "", identifier: id, ancestorPath: path, nearbyText: nearby, help: help, windowSize: size, relativeCenter: p)
    }

    func testSameInputGivesTheSameFingerprintEveryTime() {
        XCTAssertEqual(LabelFingerprint.make(input()), LabelFingerprint.make(input()))
    }

    func testTheFingerprintIsAPinnedValueNotAPerProcessHash() {
        // FNV-1a over fixed bytes: the same on every run and every machine (a store written by one run is read by the next).
        XCTAssertEqual(LabelFingerprint.hash(["a", "b"]), LabelFingerprint.hash(["a", "b"]))
        XCTAssertEqual(LabelFingerprint.hash([""]), "cbf29ce484222325")   // the FNV-1a 64-bit offset basis
        XCTAssertEqual(LabelFingerprint.hash(["a"]), "af63dc4c8601ec8c")   // the published FNV-1a test vector for "a"
        // "p3-" since help text is compared with its digits (it was "p2-", digits folded). Only the prefix and the hashed bytes changed;
        // the hash function above is the same, so its vectors stay as they were.
        XCTAssertTrue(LabelFingerprint.make(input()).hasPrefix("p3-"))
        XCTAssertTrue(LabelFingerprint.make(input(id: "btnPlay")).hasPrefix("i1-"))
    }

    func testIdentifierDecidesAlone() {
        let a = LabelFingerprint.make(input(id: "btnPlay", path: ["AXWindow", "AXGroup[3]"], nearby: ["Playback"], at: CGPoint(x: 10, y: 10)))
        let b = LabelFingerprint.make(input(id: "btnPlay", path: ["AXWindow", "AXSplitGroup[1]", "AXGroup[0]"], nearby: ["Something else"], help: "tip", at: CGPoint(x: 500, y: 700)))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, LabelFingerprint.make(input(id: "btnPause")))
        XCTAssertNotEqual(a, LabelFingerprint.make(input(id: "btnPlay", role: "AXCheckBox")))
    }

    func testPositionIsNotPartOfTheFingerprintSoMovingOrResizingKeepsIt() {
        let base = LabelFingerprint.make(input(at: CGPoint(x: 215, y: 130)))
        XCTAssertEqual(base, LabelFingerprint.make(input(at: CGPoint(x: 219, y: 133))))
        XCTAssertEqual(base, LabelFingerprint.make(input(at: CGPoint(x: 515, y: 630))))
    }

    func testThePositionIsKeptInTheAnchorAsAFractionOfTheWindow() {
        let a = LabelFingerprint.anchor(input(at: CGPoint(x: 300, y: 400)))
        XCTAssertEqual(a.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(a.y, 0.5, accuracy: 0.0001)
        let off = LabelFingerprint.anchor(input(at: CGPoint(x: -50, y: 9999)))
        XCTAssertEqual([off.x, off.y], [0, 1])
    }

    func testDifferentButtonsInTheSameWindowAreDistinct() {
        let a = LabelFingerprint.make(input(path: ["AXWindow", "AXGroup[0]", "AXButton[0]"], nearby: ["Playback"], at: CGPoint(x: 215, y: 130)))
        let b = LabelFingerprint.make(input(path: ["AXWindow", "AXGroup[0]", "AXButton[1]"], nearby: ["Playback"], at: CGPoint(x: 215, y: 130)))
        let c = LabelFingerprint.make(input(path: ["AXWindow", "AXGroup[0]", "AXButton[0]"], nearby: ["Volume"], at: CGPoint(x: 215, y: 130)))
        let d = LabelFingerprint.make(input(role: "AXCheckBox", path: ["AXWindow", "AXGroup[0]", "AXCheckBox[0]"], nearby: ["Playback"], at: CGPoint(x: 215, y: 130)))
        XCTAssertEqual(Set([a, b, c, d]).count, 4)
    }

    func testDigitsInNearbyTextAreBlurred() {
        XCTAssertEqual(LabelFingerprint.make(input(nearby: ["3 items"])), LabelFingerprint.make(input(nearby: ["14 items"])))
        XCTAssertNotEqual(LabelFingerprint.make(input(nearby: ["3 items"])), LabelFingerprint.make(input(nearby: ["3 files"])))
        XCTAssertEqual(LabelFingerprint.make(input(nearby: ["Inbox  (3)"])), LabelFingerprint.make(input(nearby: ["inbox (4)"])))
    }

    func testNonFiniteInputsDoNotCrashAndStayInRange() {
        _ = LabelFingerprint.make(LabelFingerprint.Input(role: "AXButton", windowSize: .zero, relativeCenter: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)))
        let anchor = LabelFingerprint.anchor(LabelFingerprint.Input(role: "AXButton", windowSize: .zero, relativeCenter: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)))
        XCTAssertEqual([anchor.x, anchor.y], [0, 0])
    }

    // MARK: through the scanner, on controls

    func scannedFingerprint(valueOfCheckbox: String? = nil, windowTitle: String = "Inbox (3)", shift: CGSize = .zero, extraSiblingBefore: Bool = false,
                            windowOrigin: CGPoint = CGPoint(x: 100, y: 100)) -> [String: String] {
        let wf = CGRect(origin: windowOrigin, size: size)
        func at(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: windowOrigin.x + x + shift.width, y: windowOrigin.y + y + shift.height, width: w, height: h)
        }
        var controls: [Control] = []
        func add(_ c: Control) { controls.append(c) }
        var win = Control(role: "AXWindow", window: windowTitle, frame: wf, pathID: "0"); win.inTargetWindow = true; add(win)
        add(Control(role: "AXGroup", window: windowTitle, frame: wf, pathID: "0/0"))
        add(Control(role: "AXStaticText", window: windowTitle, value: "Playback", frame: at(20, 20, 100, 20), pathID: "0/0/0"))
        var b1 = Control(role: "AXButton", window: windowTitle, frame: at(200, 20, 30, 24), pathID: "0/0/1"); b1.identifier = ""; b1.help = "First"
        add(b1)
        var b2 = Control(role: "AXButton", window: windowTitle, frame: at(250, 20, 30, 24), pathID: "0/0/2")
        b2.help = "Second"
        add(b2)
        var cb = Control(role: "AXCheckBox", window: windowTitle, value: valueOfCheckbox, frame: at(300, 20, 30, 24), pathID: "0/0/3")
        cb.titleElementText = ""; cb.help = "Third"
        add(cb)
        _ = extraSiblingBefore
        for i in controls.indices { controls[i].inTargetWindow = true }
        let scan = LabelScanner.scan(controls: controls, windowFrame: wf, truncated: false)
        var out: [String: String] = [:]
        for cand in scan.candidates { out[cand.pathID] = cand.fingerprint }
        return out
    }

    func testVolatileValuesDoNotChangeTheFingerprint() {
        let base = scannedFingerprint(valueOfCheckbox: "0", windowTitle: "Inbox (3)")
        XCTAssertEqual(base.count, 3)
        XCTAssertEqual(base, scannedFingerprint(valueOfCheckbox: "1", windowTitle: "Inbox (4)"))
    }

    func testMovingTheWindowKeepsTheFingerprints() {
        let base = scannedFingerprint()
        XCTAssertEqual(base, scannedFingerprint(windowOrigin: CGPoint(x: 700, y: 40)))
        XCTAssertEqual(base, scannedFingerprint(windowOrigin: CGPoint(x: -1200, y: 300)))
    }

    func testAnyLayoutShiftKeepsTheFingerprints() {
        let base = scannedFingerprint()
        XCTAssertEqual(base, scannedFingerprint(shift: CGSize(width: 3, height: 2)))
        XCTAssertEqual(base, scannedFingerprint(shift: CGSize(width: 0, height: 300)))
    }

    func testThreeControlsInTheSameWindowHaveThreeFingerprints() {
        XCTAssertEqual(Set(scannedFingerprint().values).count, 3)
    }

    func testCandidatesRoundTripThroughJSON() throws {
        let wf = CGRect(origin: .zero, size: size)
        var win = Control(role: "AXWindow", frame: wf, pathID: "0"); win.inTargetWindow = true
        let b = Control(role: "AXButton", title: "icon.png", help: "tip", frame: CGRect(x: 10, y: 10, width: 30, height: 30), pathID: "0/0")
        let scan = LabelScanner.scan(controls: [win, b], windowFrame: wf, truncated: false)
        let data = try JSONEncoder().encode(scan.candidates)
        let back = try JSONDecoder().decode([LabelCandidate].self, from: data)
        XCTAssertEqual(back, scan.candidates)
        XCTAssertEqual(back.first?.reason, .generic("icon.png"))
    }
}
