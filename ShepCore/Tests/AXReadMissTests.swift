import CoreGraphics
import XCTest
@testable import ShepCore

/// Reproduces the misses found reading a torrent client's main window (a Sample Torrent App fixture, no real data).
/// These compile against the code as it was: the first two fail until the reader and the CLI are fixed.
final class AXReadMissTests: XCTestCase {
    func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func source(_ relative: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relative)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "source tree not reachable from the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Miss 1: the reader looked only at the focused window, so a modal alert hid the main window the screenshot shows.
    func testTheReaderLooksAtEveryWindowOfTheApp() throws {
        let text = try source("Shep/AXReader.swift")
        XCTAssertTrue(text.contains("kAXWindowsAttribute"), "AXReader must list the app's windows, not only the focused one")
    }

    /// Miss 2: --fix-screen-once passed no Accessibility controls at all, so every box looked "not in the Accessibility list".
    func testTheFixScreenCLIDoesNotPassAnEmptyControlList() throws {
        let text = try source("Shep/FixScreenCLI.swift")
        XCTAssertFalse(text.contains("axControls: []"), "the CLI must read Accessibility for the targeted window")
    }

    /// Miss 3 (current behaviour, kept): a control with only a tooltip is named by it. What was missing is saying so.
    func testATooltipOnlyCheckboxIsNamedByItsTooltip() {
        let tip = "Speed Limit overrides the total bandwidth limits with its own limits."
        let c = Control(role: "AXCheckBox", window: "Sample Torrent App", help: tip, frame: CGRect(x: 10, y: 560, width: 18, height: 18),
                        actions: ["AXPress"], pathID: "0/9")
        XCTAssertEqual(c.label, tip)
    }
}
