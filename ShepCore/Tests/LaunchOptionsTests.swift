import XCTest
@testable import ShepCore

final class LaunchOptionsTests: XCTestCase {
    func testDefaults() {
        let o = LaunchOptions.parse(arguments: ["Shep"], environment: [:])
        XCTAssertFalse(o.dockDemo)
        XCTAssertEqual(o.theme.name, "Tangerine")
        XCTAssertEqual(o.state, .idle)
    }

    func testFlagAndEnvironment() {
        XCTAssertTrue(LaunchOptions.parse(arguments: ["Shep", "--dock-demo"], environment: [:]).dockDemo)
        XCTAssertTrue(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_DOCK_DEMO": "1"]).dockDemo)
        XCTAssertFalse(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_DOCK_DEMO": "0"]).dockDemo)
    }

    func testThemeAndState() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--theme=Beagle Tan", "--state=look-left"], environment: [:])
        XCTAssertEqual(o.theme.name, "Beagle Tan")
        XCTAssertEqual(o.state, .lookLeft)
        let bad = LaunchOptions.parse(arguments: ["Shep", "--theme=zzz", "--state=zzz"], environment: [:])
        XCTAssertEqual(bad.theme.name, "Tangerine")
        XCTAssertEqual(bad.state, .idle)
    }

    func testUISnapshotFlag() {
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep"], environment: [:]).uiSnapshotDir)
        XCTAssertEqual(LaunchOptions.parse(arguments: ["Shep", "--ui-snapshot", "/tmp/out"], environment: [:]).uiSnapshotDir, "/tmp/out")
        XCTAssertEqual(LaunchOptions.parse(arguments: ["Shep", "--ui-snapshot=/tmp/out"], environment: [:]).uiSnapshotDir, "/tmp/out")
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--ui-snapshot"], environment: [:]).uiSnapshotDir)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--ui-snapshot", "--dock-demo"], environment: [:]).uiSnapshotDir)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--ui-snapshot="], environment: [:]).uiSnapshotDir)
    }

    func testTheExampleNotchedDisplayIsTheDocumentedOne() {
        let s = HomeScreen.exampleNotched
        XCTAssertEqual(s.frame, CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(s.auxLeft, CGRect(x: 0, y: 950, width: 663.5, height: 32))
        XCTAssertEqual(s.auxRight, CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
        XCTAssertEqual(s.notch?.minX, 663.5)
        XCTAssertEqual(s.notch?.maxX, 848.5)
        XCTAssertEqual(s.notch?.bottom, 950)
    }

    func testDemoScriptFlag() {
        XCTAssertFalse(LaunchOptions.parse(arguments: ["Shep"], environment: [:]).demoScript)
        XCTAssertTrue(LaunchOptions.parse(arguments: ["Shep", "--dock-demo", "--demo-script"], environment: [:]).demoScript)
        XCTAssertTrue(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_DEMO_SCRIPT": "1"]).demoScript)
    }

    func testDemoCycleFlag() {
        let a = LaunchOptions.parse(arguments: ["Shep", "--demo-script=cycle"], environment: [:])
        XCTAssertTrue(a.demoCycle)
        XCTAssertFalse(a.demoScript)
        XCTAssertTrue(LaunchOptions.parse(arguments: ["Shep", "--demo-script", "cycle"], environment: [:]).demoCycle)
        XCTAssertTrue(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_DEMO_SCRIPT": "Cycle"]).demoCycle)
        let bare = LaunchOptions.parse(arguments: ["Shep", "--demo-script", "--dock-demo"], environment: [:])
        XCTAssertFalse(bare.demoCycle)
        XCTAssertTrue(bare.demoScript)
        XCTAssertFalse(LaunchOptions.parse(arguments: ["Shep"], environment: [:]).demoCycle)
    }
}

final class BarkAndBackdropLaunchTests: XCTestCase {
    func testExportBarkPath() {
        let o = LaunchOptions.parse(arguments: ["Shep", "--export-bark=/tmp/bark.wav"], environment: [:])
        XCTAssertEqual(o.exportBarkPath, "/tmp/bark.wav")
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep", "--export-bark="], environment: [:]).exportBarkPath)
        XCTAssertNil(LaunchOptions.parse(arguments: ["Shep"], environment: [:]).exportBarkPath)
    }

    func testDemoBackdropFlag() {
        XCTAssertTrue(LaunchOptions.parse(arguments: ["Shep", "--demo-script=cycle", "--demo-backdrop"], environment: [:]).demoBackdrop)
        XCTAssertTrue(LaunchOptions.parse(arguments: ["Shep"], environment: ["SHEP_DEMO_BACKDROP": "1"]).demoBackdrop)
        XCTAssertFalse(LaunchOptions.parse(arguments: ["Shep"], environment: [:]).demoBackdrop)
    }
}
