import CoreGraphics
import XCTest
@testable import ShepCore

final class ControlTests: XCTestCase {
    func btn(_ title: String, x: CGFloat = 0, y: CGFloat = 0, enabled: Bool = true, actions: [String] = ["AXPress"]) -> Control {
        Control(role: "AXButton", title: title, frame: CGRect(x: x, y: y, width: 40, height: 20), enabled: enabled, actions: actions, pathID: "0/\(Int(x))")
    }

    func testLabelFallsBackToDescriptionThenHelpAndIsCapped() {
        XCTAssertEqual(Control(role: "AXButton", title: "Send").label, "Send")
        XCTAssertEqual(Control(role: "AXButton", title: "  ", description: "Close").label, "Close")
        XCTAssertEqual(Control(role: "AXButton", help: "Opens settings").label, "Opens settings")
        XCTAssertEqual(Control(role: "AXButton", title: String(repeating: "a", count: 200)).label.count, 80)
        XCTAssertEqual(Control(role: "AXButton").label, "")
    }

    func testSecureFieldsAreNeverUsefulAndNeverShowTheirValue() {
        let pw = Control(role: "AXTextField", subrole: "AXSecureTextField", title: "Password", value: "hunter2", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        XCTAssertTrue(pw.isSecure)
        XCTAssertFalse(pw.isTextInput)
        XCTAssertFalse(ControlFilter.isUseful(pw))
        XCTAssertFalse(pw.line.contains("hunter2"))
        XCTAssertFalse(ControlFilter.serialize([pw.renumbered(1)]).contains("hunter2"))
    }

    func testPrepareDropsNoiseDedupesRanksAndNumbers() {
        let controls = [
            btn("Disabled", x: 0, enabled: false),
            btn("Send", x: 200),
            btn("Send", x: 200),                                              // duplicate
            Control(role: "AXGroup", title: "Box", frame: CGRect(x: 0, y: 0, width: 50, height: 50)),   // not actionable
            Control(role: "AXButton", title: "Tiny", frame: CGRect(x: 0, y: 0, width: 1, height: 1)),   // too small
            btn("Back", x: 10),
            Control(role: "AXButton", title: "", frame: CGRect(x: 100, y: 0, width: 30, height: 30), actions: ["AXPress"]),   // unlabeled
        ]
        let out = ControlFilter.prepare(controls)
        XCTAssertEqual(out.map(\.label), ["Back", "Send", "", "Disabled"], "enabled+labelled first in reading order, unlabelled next, disabled last")
        XCTAssertEqual(out.map(\.index), [1, 2, 3, 4])
    }

    func testPrepareRespectsLimitAndWindow() {
        let many = (0..<100).map { btn("B\($0)", x: CGFloat($0 * 50)) }
        XCTAssertEqual(ControlFilter.prepare(many, limit: 10).count, 10)
        let inside = ControlFilter.prepare(many, window: CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(inside.map(\.label), ["B0", "B1", "B2"])
    }

    func testRankIsDeterministic() {
        let c = [btn("A", x: 0), btn("B", x: 50), btn("C", x: 100)]
        XCTAssertEqual(ControlFilter.rank(c), ControlFilter.rank(c))
        XCTAssertEqual(ControlFilter.rank(c), [0, 1, 2])
    }

    func testSerializeIsCompactJSON() throws {
        let c = btn("Send", x: 10, y: 20).renumbered(3)
        let data = Data(ControlFilter.serialize([c]).utf8)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as? Int, 3)
        XCTAssertEqual(rows[0]["role"] as? String, "button")
        XCTAssertEqual(rows[0]["label"] as? String, "Send")
        XCTAssertEqual(rows[0]["frame"] as? [Int], [10, 20, 40, 20])
        XCTAssertEqual(ControlFilter.serialize([]), "[]")
    }

    func testKindAndLine() {
        let c = Control(index: 2, role: "AXSearchField", title: "Search", window: "Mail", value: "cats", enabled: false)
        XCTAssertEqual(c.kind, "text field")
        XCTAssertEqual(c.line, "#2 text field \"Search\" in window \"Mail\" value=\"cats\" (disabled)")
    }
}
