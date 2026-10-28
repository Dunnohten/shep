import CoreGraphics
import XCTest
@testable import ShepCore

final class FixScreenLaunchOptionTests: XCTestCase {
    func testSeparateAndEqualsForms() {
        XCTAssertEqual(LaunchOptions.parse(arguments: ["Shep", "--fix-screen-once", "/tmp/a.png"], environment: [:]).fixScreenOncePath, "/tmp/a.png")
        XCTAssertEqual(LaunchOptions.parse(arguments: ["Shep", "--fix-screen-once=/tmp/b.png"], environment: [:]).fixScreenOncePath, "/tmp/b.png")
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--fix-screen-once"], environment: [:]).fixScreenOncePath)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--fix-screen-once", "--dock-demo"], environment: [:]).fixScreenOncePath)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep"], environment: [:]).fixScreenOncePath)
    }
}

final class FixScreenReportTests: XCTestCase {
    func testReportListsProvidersControlsProposalsAndTiming() async {
        let geo = CaptureGeometry(windowFrame: CGRect(x: 0, y: 0, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
        let fake = FakeProvider(analysis: ScreenAnalysis(summary: "A window.", controls: [LocatedControl(name: "Gear", role: "button", box: CGRect(x: 100, y: 100, width: 60, height: 60))]))
        let r = await FixScreenPipeline(provider: fake).run(VisionInput(png: Data([1]), geometry: geo, axControls: [], bundleID: "cli", windowTitle: "W"))
        let text = FixScreenReport.render(r, seconds: 1.234)
        XCTAssertTrue(text.contains("provider: fake"))
        XCTAssertTrue(text.contains("status: ok"))
        XCTAssertTrue(text.contains("controls: 1 (1 found on screen)"))
        XCTAssertTrue(text.contains("Click the button \"Gear\" (found on screen) [needs approval:"))
        XCTAssertTrue(text.contains("time: 1.23 s"))
    }
}
