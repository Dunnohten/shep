import CoreGraphics
import XCTest
@testable import ShepCore

final class LabelScanLaunchTests: XCTestCase {
    func parse(_ args: [String], env: [String: String] = [:]) -> LaunchOptions { LaunchOptions.parse(arguments: args, environment: env) }

    func testScanFlagTakesAPidOrABundleId() {
        XCTAssertEqual(parse(["Shep", "--fix-screen-scan", "1234"]).fixScreenScanTarget, "1234")
        XCTAssertEqual(parse(["Shep", "--fix-screen-scan", "dev.shep.fixture"]).fixScreenScanTarget, "dev.shep.fixture")
        XCTAssertEqual(parse(["Shep", "--fix-screen-scan=dev.shep.fixture"]).fixScreenScanTarget, "dev.shep.fixture")
    }

    func testScanFlagNeedsAValue() {
        XCTAssertNil(parse(["Shep", "--fix-screen-scan"]).fixScreenScanTarget)
        XCTAssertNil(parse(["Shep", "--fix-screen-scan", "--approve"]).fixScreenScanTarget)
        XCTAssertNil(parse(["Shep"]).fixScreenScanTarget)
    }

    func testScanFlagDoesNotDisturbTheOtherTools() {
        let o = parse(["Shep", "--fix-screen-scan", "99", "--title", "Fixture"])
        XCTAssertEqual(o.toolTitle, "Fixture")
        XCTAssertNil(o.axReadOnceTarget)
        XCTAssertNil(o.fixScreenOncePath)
    }
}

final class LabelScanReportTests: XCTestCase {
    func scan() -> LabelScan {
        let result = LabelFixture.controls()!
        return LabelScanner.scan(controls: result.controls, windowFrame: LabelFixture.windowFrame, truncated: result.truncated)
    }

    func testOneJSONObjectPerLineAndASummaryLast() throws {
        let lines = LabelScanReport.jsonLines(scan: scan(), bundleID: "dev.shep.fixture", pid: 42)
        XCTAssertEqual(lines.count, scan().entries.count + 1)
        for line in lines {
            XCTAssertFalse(line.contains("\n"))
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let summary = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String: Any]
        XCTAssertEqual(summary["kind"] as? String, "summary")
        XCTAssertEqual(summary["flagged"] as? Int, 14)
        XCTAssertEqual(summary["checked"] as? Int, scan().entries.count)
        XCTAssertEqual(summary["partial"] as? Bool, false)
        XCTAssertEqual(summary["bundle"] as? String, "dev.shep.fixture")
        XCTAssertEqual(summary["labeled"] as? Int, scan().entries.filter { $0.verdict == "labeled" }.count)
        XCTAssertEqual(summary["ignored"] as? Int, scan().entries.filter { $0.verdict.hasPrefix("skipped") }.count, "disabled, hidden and window buttons")
        XCTAssertEqual(summary["unlabeled"] as? Int, 14)
        XCTAssertEqual(summary["falseFlags"] as? Int, 0, "no named control of the fixture is flagged")
        XCTAssertEqual(summary["offerable"] as? Int, 14, "every flagged fixture control has its own identifier")
        XCTAssertEqual(summary["skipped"] as? Int, 0, "none of them is skipped for being indistinguishable")
    }

    func testEntryLinesCarryTheFlagAndTheReason() throws {
        let lines = LabelScanReport.jsonLines(scan: scan(), bundleID: "b", pid: 1)
        let objects = try lines.dropLast().map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let play = objects.first { ($0["identifier"] as? String) == "btnPlay" }!
        XCTAssertEqual(play["kind"] as? String, "control")
        XCTAssertEqual(play["flagged"] as? Bool, true)
        XCTAssertEqual(play["verdict"] as? String, "unlabeled:empty")
        XCTAssertEqual(play["role"] as? String, "AXButton")
        XCTAssertNotNil(play["subrole"] as? String)
        XCTAssertNotNil(play["value"] as? String)
        XCTAssertEqual((play["fingerprint"] as? String)?.isEmpty, false)
        let wifi = objects.first { ($0["identifier"] as? String) == "u11" }!
        XCTAssertEqual(wifi["subrole"] as? String, "AXSwitch")
        let popup = objects.first { ($0["identifier"] as? String) == "l7" }!
        XCTAssertEqual(popup["value"] as? String, "Sort by name")
        let save = objects.first { ($0["identifier"] as? String) == "l1" }!
        XCTAssertEqual(save["flagged"] as? Bool, false)
        XCTAssertEqual(save["verdict"] as? String, "labeled")
    }

    func testTheReportIsReadOnlyAndNamesNoModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("ShepCore/Sources/LabelScanReport.swift"), encoding: .utf8)
        XCTAssertFalse(text.contains("LabelNaming") || text.contains("GlimmerLabelNamer") || text.contains("MetaLabelNamer"))
        XCTAssertFalse(text.contains("LabelOverlayStore"))
    }
}

final class LabelCropTests: XCTestCase {
    func testTheControlRectIsScaledToPixelsWithPaddingAndKeptInsideTheImage() {
        let r = LabelCrop.pixelRect(relative: CGRect(x: 100, y: 50, width: 30, height: 20), scale: 2, imageSize: CGSize(width: 1200, height: 1600))!
        XCTAssertEqual(r, CGRect(x: 192, y: 92, width: 76, height: 56))
    }

    func testARectAtTheEdgeIsClipped() {
        let r = LabelCrop.pixelRect(relative: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 2, imageSize: CGSize(width: 1200, height: 1600))!
        XCTAssertEqual(r.minX, 0); XCTAssertEqual(r.minY, 0)
    }

    func testNothingIsCroppedForBadOrHugeRects() {
        let size = CGSize(width: 1200, height: 1600)
        XCTAssertNil(LabelCrop.pixelRect(relative: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), scale: 2, imageSize: size))
        XCTAssertNil(LabelCrop.pixelRect(relative: CGRect(x: 0, y: 0, width: 0, height: 10), scale: 2, imageSize: size))
        XCTAssertNil(LabelCrop.pixelRect(relative: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 0, imageSize: size))
        XCTAssertNil(LabelCrop.pixelRect(relative: CGRect(x: 5000, y: 5000, width: 10, height: 10), scale: 2, imageSize: size))
        XCTAssertNil(LabelCrop.pixelRect(relative: CGRect(x: 0, y: 0, width: 400, height: 400), scale: 2, imageSize: size), "a pane is not a control")
    }

    func testImagesAreOffUnlessAskedForAndPermitted() {
        XCTAssertFalse(LabelCrop.enabled(environment: [:], screenRecordingGranted: true))
        XCTAssertFalse(LabelCrop.enabled(environment: ["SHEP_LABEL_IMAGES": "0"], screenRecordingGranted: true))
        XCTAssertFalse(LabelCrop.enabled(environment: ["SHEP_LABEL_IMAGES": "1"], screenRecordingGranted: false))
        XCTAssertTrue(LabelCrop.enabled(environment: ["SHEP_LABEL_IMAGES": "1"], screenRecordingGranted: true))
        XCTAssertTrue(LabelCrop.enabled(environment: ["SHEP_LABEL_IMAGES": "true"], screenRecordingGranted: true))
    }
}

final class LabelScanTotalsTests: XCTestCase {
    func testFlaggedAndOfferableAreSeparateCountsAndFalseFlagsUseTheFixtureNaming() throws {
        let specs = [AnchorSpec(tag: "t0", x: 20), AnchorSpec(tag: "t1", x: 50), AnchorSpec(tag: "t2", x: 220, identifier: "u2"),
                     AnchorSpec(tag: "t3", x: 320, identifier: "l9")]
        let scan = LabelScanner.scan(controls: anchorControls(specs), windowFrame: anchorTestFrame, truncated: false)
        let lines = LabelScanReport.jsonLines(scan: scan, bundleID: "b", pid: 1)
        let summary = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String: Any]
        XCTAssertEqual(summary["flagged"] as? Int, 4)
        XCTAssertEqual(summary["unlabeled"] as? Int, 4)
        XCTAssertEqual(summary["falseFlags"] as? Int, 1, "the control called l9 is flagged although the fixture names it")
        XCTAssertEqual(summary["offerable"] as? Int, 2, "the two with identifiers; the pair that shares its text is not")
        XCTAssertEqual(summary["skipped"] as? Int, 2)
        let objects = try lines.dropLast().map { line in try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any] }
        XCTAssertEqual(objects.filter { o in (o["flagged"] as? Bool) == true && (o["offerable"] as? Bool) == false }.count, 2)
    }
}
