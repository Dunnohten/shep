import XCTest
@testable import ShepCore

final class SharingPolicyTests: XCTestCase {
    func testHiddenByDefaultAndFollowsTheSavedChoice() {
        XCTAssertTrue(SharingPolicy.hidden(saved: nil, capturableLaunch: false))
        XCTAssertTrue(SharingPolicy.hidden(saved: true, capturableLaunch: false))
        XCTAssertFalse(SharingPolicy.hidden(saved: false, capturableLaunch: false))
    }

    func testTheCapturableLaunchFlagWinsForThatLaunch() {
        for saved in [nil, true, false] as [Bool?] { XCTAssertFalse(SharingPolicy.hidden(saved: saved, capturableLaunch: true)) }
    }
}

final class WindowPrivacySourceTests: XCTestCase {
    /// Every window or panel Shep creates must read the sharing policy where it is created: a window made after the owner
    /// chose "hide" (Setup reopened, Settings reopened) is otherwise capturable by default.
    func testEveryWindowCreationSiteSetsTheSharingType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Shep")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { throw XCTSkip("source tree not reachable") }
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let creations = text.components(separatedBy: "NSWindow(").count - 1 + text.components(separatedBy: ": NSPanel {").count - 1
            guard creations > 0 else { continue }
            checked += 1
            let sets = text.components(separatedBy: "sharingType =").count - 1
            XCTAssertGreaterThanOrEqual(sets, creations, "\(url.lastPathComponent) creates \(creations) window(s) but sets sharingType \(sets) time(s)")
        }
        try XCTSkipIf(checked == 0, "no window creation sites found")
    }
}
