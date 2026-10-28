import CoreGraphics
import XCTest
@testable import ShepCore

final class AXToolFlagsTests: XCTestCase {
    func parse(_ args: [String]) -> LaunchOptions { LaunchOptions.parse(arguments: ["Shep"] + args, environment: [:]) }

    func testAxReadOnceFlags() {
        let o = parse(["--ax-read-once", "com.example.sample", "--title", "Sample Torrent App", "--frame", "100,100,900,600"])
        XCTAssertEqual(o.axReadOnceTarget, "com.example.sample")
        XCTAssertEqual(o.toolTitle, "Sample Torrent App")
        XCTAssertEqual(o.toolFrame, CGRect(x: 100, y: 100, width: 900, height: 600))
        XCTAssertNil(o.pressDemoTarget)
        XCTAssertFalse(o.approveFlag)
        XCTAssertEqual(parse(["--ax-read-once=4242"]).axReadOnceTarget, "4242")
    }

    func testPressDemoFlagsAndApproveIsOnlyTheFlag() {
        let plain = parse(["--press-demo-once", "4242", "--match", "Speed Limit"])
        XCTAssertEqual(plain.pressDemoTarget, "4242")
        XCTAssertEqual(plain.pressMatch, "Speed Limit")
        XCTAssertFalse(plain.approveFlag)
        XCTAssertTrue(parse(["--press-demo-once", "4242", "--match", "x", "--approve"]).approveFlag)
        // An environment variable never approves anything.
        XCTAssertFalse(LaunchOptions.parse(arguments: ["Shep", "--press-demo-once", "4242"], environment: ["SHEP_APPROVE": "1", "APPROVE": "1"]).approveFlag)
    }

    func testAFlagWithoutAValueIsNil() {
        XCTAssertNil(parse(["--ax-read-once"]).axReadOnceTarget)
        XCTAssertNil(parse(["--ax-read-once", "--title", "x"]).axReadOnceTarget)
        XCTAssertNil(parse(["--press-demo-once", "1", "--match"]).pressMatch)
        XCTAssertNil(parse(["--frame", "not,a,frame"]).toolFrame)
    }

    func testProcessTargets() {
        XCTAssertEqual(ProcessTarget.parse("4242"), .pid(4242))
        XCTAssertEqual(ProcessTarget.parse(" 7 "), .pid(7))
        XCTAssertEqual(ProcessTarget.parse("com.example.sample"), .bundleID("com.example.sample"))
        XCTAssertNil(ProcessTarget.parse(""))
        XCTAssertNil(ProcessTarget.parse("0"))
        XCTAssertNil(ProcessTarget.parse("99999999999"))
    }

    func testFixScreenTargetFromTheEnvironment() {
        XCTAssertEqual(ProcessTarget.from(environment: ["SHEP_AX_PID": "55", "SHEP_WINDOW_OWNER": "com.example.sample"]), .pid(55))
        XCTAssertEqual(ProcessTarget.from(environment: ["SHEP_WINDOW_OWNER": "com.example.sample"]), .bundleID("com.example.sample"))
        XCTAssertEqual(ProcessTarget.from(environment: ["SHEP_AX_PID": "abc", "SHEP_WINDOW_OWNER": "com.example.sample"]), .bundleID("com.example.sample"))
        XCTAssertNil(ProcessTarget.from(environment: [:]))
        XCTAssertNil(ProcessTarget.from(environment: ["SHEP_AX_PID": "abc"]))
    }
}
