import CoreGraphics
import XCTest
@testable import ShepCore

/// P1-2: `--fix-screen-once` decides who the screenshot belongs to BEFORE any provider work, and never falls back to a
/// made-up bundle identifier when a target was named.
final class CLITargetTests: XCTestCase {
    final class FakeLookup: CLIAppLookup {
        var accessibilityAllowed = true
        var bundles: [Int32: String] = [:]
        var running: [String: [Int32]] = [:]
        func bundleID(ofPID pid: Int32) -> String? { bundles[pid] }
        func runningPIDs(forBundleID id: String) -> [Int32] { running[id] ?? [] }
    }

    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let lookupWithApps: FakeLookup = {
        let l = FakeLookup()
        l.bundles = [50: "com.apple.mail", 60: "com.example.notes", 61: "", 62: "com.apple.terminal"]
        l.running = ["com.apple.mail": [50], "com.example.notes": [60], "com.apple.terminal": [62]]
        return l
    }()

    /// Runs the whole CLI decision with a provider spy. `inputsMade` records what the app layer was asked to build.
    func run(_ env: [String: String], lookup: FakeLookup? = nil, readFails: Bool = false)
        async -> (outcome: CLIFixScreen.Outcome, provider: FakeProvider, built: [CLITarget.Resolved]) {
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "A window.", controls: []))
        let pipeline = FixScreenPipeline(provider: provider)
        var built: [CLITarget.Resolved] = []
        let outcome = await CLIFixScreen.run(environment: env, lookup: lookup ?? lookupWithApps, pipeline: pipeline) { resolved in
            built.append(resolved)
            if readFails { return nil }
            return VisionInput(png: Data([1]), geometry: self.geometry, axControls: [], bundleID: resolved.bundleID, windowTitle: "image")
        }
        return (outcome, provider, built)
    }

    func testMailOwnerWithASuppliedPNGNeverReachesTheProvider() async {
        let r = await run(["SHEP_WINDOW_OWNER": "com.apple.mail"])
        XCTAssertEqual(r.provider.calls.count, 0)
        XCTAssertNotNil(r.outcome.refusal)
        XCTAssertTrue(r.built.isEmpty, "not even the input was built")
        XCTAssertNil(r.outcome.result)
    }

    func testMailByPidNeverReachesTheProvider() async {
        let r = await run(["SHEP_AX_PID": "50"])
        XCTAssertEqual(r.provider.calls.count, 0)
        XCTAssertNotNil(r.outcome.refusal)
    }

    func testMailOwnerWithAnUnrelatedPidIsStillRefusedByTheOwnerString() async {
        let r = await run(["SHEP_WINDOW_OWNER": "com.apple.mail", "SHEP_AX_PID": "60"])
        XCTAssertEqual(r.provider.calls.count, 0, "owner says Mail, pid is Notes: a mismatch, and Mail is denied anyway")
        XCTAssertNotNil(r.outcome.refusal)
    }

    func testUnresolvedPidEmptyBundleAndUnparsablePidAreRefused() async {
        for pid in ["999", "61", "abc", "-4", "0"] {
            let r = await run(["SHEP_AX_PID": pid])
            XCTAssertEqual(r.provider.calls.count, 0, "pid \(pid)")
            XCTAssertNotNil(r.outcome.refusal, "pid \(pid)")
        }
    }

    func testOwnerAndPidThatDisagreeAreRefused() async {
        let r = await run(["SHEP_WINDOW_OWNER": "com.example.notes", "SHEP_AX_PID": "50"])
        XCTAssertEqual(r.provider.calls.count, 0)
        XCTAssertNotNil(r.outcome.refusal)
        let swapped = await run(["SHEP_WINDOW_OWNER": "com.example.other", "SHEP_AX_PID": "60"])
        XCTAssertEqual(swapped.provider.calls.count, 0)
        XCTAssertNotNil(swapped.outcome.refusal)
    }

    func testAnOwnerThatIsNotRunningCannotBeResolvedAndIsRefused() async {
        let r = await run(["SHEP_WINDOW_OWNER": "com.example.ghost"])
        XCTAssertEqual(r.provider.calls.count, 0)
        XCTAssertNotNil(r.outcome.refusal)
    }

    func testAccessibilityDeniedWithANamedTargetIsRefused() async {
        let l = FakeLookup(); l.bundles = lookupWithApps.bundles; l.running = lookupWithApps.running
        l.accessibilityAllowed = false
        let r = await run(["SHEP_WINDOW_OWNER": "com.example.notes"], lookup: l)
        XCTAssertEqual(r.provider.calls.count, 0)
        XCTAssertNotNil(r.outcome.refusal)
    }

    func testAFailedWindowReadWithANamedTargetIsRefusedAndNeverFallsBack() async {
        let r = await run(["SHEP_WINDOW_OWNER": "com.example.notes"], readFails: true)
        XCTAssertEqual(r.provider.calls.count, 0)
        XCTAssertNotNil(r.outcome.refusal)
        XCTAssertEqual(r.built.count, 1)
    }

    func testDeniedAndCommandRunnerAppsAreRefusedWhicheverWayTheyAreNamed() async {
        for env in [["SHEP_AX_PID": "62"], ["SHEP_WINDOW_OWNER": "com.apple.terminal"]] {
            let r = await run(env)
            XCTAssertEqual(r.provider.calls.count, 0, "\(env)")
        }
    }

    func testAnOrdinaryResolvedAppReachesTheProviderOnceWithItsRealBundleID() async {
        for env in [["SHEP_WINDOW_OWNER": "com.example.notes"], ["SHEP_AX_PID": "60"],
                    ["SHEP_WINDOW_OWNER": "COM.example.Notes", "SHEP_AX_PID": "60"]] {
            let r = await run(env)
            XCTAssertEqual(r.provider.calls.count, 1, "\(env)")
            XCTAssertEqual(r.provider.calls.first?.bundleID, "com.example.notes", "\(env)")
            XCTAssertNil(r.outcome.refusal)
            XCTAssertEqual(r.outcome.result?.status, .ok)
            XCTAssertNil(r.outcome.notice, "an attested app needs no notice")
        }
    }

    func testABarePNGIsAllowedAsAnUnattestedFileWithANotice() async {
        let r = await run([:])
        XCTAssertEqual(r.provider.calls.count, 1)
        XCTAssertEqual(r.provider.calls.first?.bundleID, CLITarget.unattestedBundleID)
        XCTAssertTrue(r.outcome.notice?.contains("unattested") ?? false, r.outcome.notice ?? "nil")
        XCTAssertNil(r.outcome.refusal)
        // Empty values count as not supplied.
        let blank = await run(["SHEP_WINDOW_OWNER": "  ", "SHEP_AX_PID": ""])
        XCTAssertEqual(blank.provider.calls.count, 1)
    }

    func testAnUnattestedFileKeepsTheRefusalsThatDoNotDependOnTheApp() async {
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: [
            LocatedControl(name: "Delete account", role: "button", box: CGRect(x: 600, y: 100, width: 60, height: 60)),
            LocatedControl(name: "Gear", role: "button", box: CGRect(x: 200, y: 400, width: 60, height: 60))]))
        let outcome = await CLIFixScreen.run(environment: [:], lookup: lookupWithApps, pipeline: FixScreenPipeline(provider: provider)) { resolved in
            VisionInput(png: Data([1]), geometry: self.geometry, axControls: [], bundleID: resolved.bundleID, windowTitle: "image")
        }
        XCTAssertEqual(outcome.result?.controls.map(\.label), ["Gear"], "the sensitive control is left out")
    }

    func testTheDecisionIsPure() {
        let l = lookupWithApps
        XCTAssertEqual(CLITarget.resolve(environment: [:], lookup: l), .unattestedFile)
        XCTAssertEqual(CLITarget.resolve(environment: ["SHEP_AX_PID": "60"], lookup: l), .app(pid: 60, bundleID: "com.example.notes"))
        XCTAssertEqual(CLITarget.resolve(environment: ["SHEP_WINDOW_OWNER": "com.example.notes"], lookup: l), .app(pid: 60, bundleID: "com.example.notes"))
        if case .refused = CLITarget.resolve(environment: ["SHEP_WINDOW_OWNER": "com.apple.mail"], lookup: l) {} else { XCTFail("mail") }
    }
}
