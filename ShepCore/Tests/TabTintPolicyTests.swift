import XCTest
@testable import ShepCore

final class TabTintPolicyTests: XCTestCase {
    func testOrdinaryAppWithPermissionIsSampled() {
        XCTAssertEqual(TabTintPolicy.source(bundleID: "com.apple.TextEdit", screenRecordingAllowed: true), .sample)
    }

    func testNoPermissionOrUnknownAppUsesTheFallback() {
        XCTAssertEqual(TabTintPolicy.source(bundleID: "com.apple.TextEdit", screenRecordingAllowed: false), .fallback)
        XCTAssertEqual(TabTintPolicy.source(bundleID: nil, screenRecordingAllowed: true), .fallback)
        XCTAssertEqual(TabTintPolicy.source(bundleID: "", screenRecordingAllowed: true), .fallback)
    }

    func testEveryNeverCaptureDeniedAndCommandRunnerAppUsesTheFallback() {
        let all = ControlPolicy.neverCaptureIDs.union(ControlPolicy.deniedBundleIDs).union(ControlPolicy.commandRunnerIDs)
        XCTAssertFalse(all.isEmpty)
        for id in all {
            XCTAssertEqual(TabTintPolicy.source(bundleID: id, screenRecordingAllowed: true), .fallback, id)
            XCTAssertEqual(TabTintPolicy.source(bundleID: id.uppercased(), screenRecordingAllowed: true), .fallback, id)
        }
        XCTAssertEqual(TabTintPolicy.source(bundleID: "com.jetbrains.intellij", screenRecordingAllowed: true), .fallback)
        XCTAssertEqual(TabTintPolicy.source(bundleID: "dev.warp.Warp-Stable", screenRecordingAllowed: true), .fallback)
    }

    func testTheTintDecisionMatchesTheFixScreenCapturePolicy() {
        for id in ["com.apple.mail", "com.apple.TextEdit", "com.apple.Terminal", "com.example.app", ""] {
            XCTAssertEqual(TabTintPolicy.source(bundleID: id, screenRecordingAllowed: true) == .sample, ControlPolicy.mayCapture(bundleID: id), id)
        }
    }
}
