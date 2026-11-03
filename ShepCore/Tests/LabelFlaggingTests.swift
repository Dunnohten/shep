import CoreGraphics
import XCTest
@testable import ShepCore

final class LabelTextTests: XCTestCase {
    func testEmptyAndBlankAreGeneric() {
        for s in ["", " ", "\n\t "] { XCTAssertTrue(LabelText.isGeneric(s), s) }
    }

    func testRoleWordsAreGeneric() {
        for s in ["button", "Button", "BUTTON", "checkbox", "check box", "link", "icon", "image", "img", "graphic", "toggle", "menu",
                  "switch", "menu button", "Image button", "icon image", "Button 3", "image 12", "pop-up button", "radio button"] {
            XCTAssertTrue(LabelText.isGeneric(s), s)
        }
    }

    func testFileNamesAreGeneric() {
        for s in ["icon.png", "Icon.PNG", "btn_close@2x", "close@3x", "ic_play.svg", "arrow.pdf", "photo.jpeg", "logo.icns", "my picture.png",
                  "sprite.TIFF", "glyph.heic"] {
            XCTAssertTrue(LabelText.isGeneric(s), s)
        }
    }

    func testSingleCharactersAndSymbolsAndDigitsAreGeneric() {
        for s in ["X", "x", "+", "-", "…", "✕", "★", "1", "42", "3.14", "( )", "▶︎", "---", "#", "1/2", "..."] {
            XCTAssertTrue(LabelText.isGeneric(s), s)
        }
    }

    func testMachineIdentifiersAreGeneric() {
        for s in ["NSButton", "_NS:123", "_NS:9", "AXButton", "AXMenuButton", "UIButton", "NSImageView", "_NSKeyedArchive",
                  "btnPlay", "btn_close", "imgLogo", "icClose", "icon_close", "com.apple.thing.button",
                  "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "0x7ffeefbff5c8"] {
            XCTAssertTrue(LabelText.isGeneric(s), s)
        }
    }

    func testRealNamesAreNotGeneric() {
        for s in ["Save", "OK", "Go", "Close", "Close button", "Play", "Settings", "Wi-Fi", "Add item", "Remember me", "Sign in",
                  "Privacy Policy", "iPhone", "iCloud", "eBay", "Next page", "Zoom in", "Back", "Mute", "Volume", "是", "確定", "Café", "Über uns",
                  "Show menu bar", "Delete all", "Run", "Download.", "Save as…", "Notes.app"] {
            XCTAssertFalse(LabelText.isGeneric(s), s)
        }
    }
}

final class LabelFlaggerTests: XCTestCase {
    func control(_ role: String = "AXButton", subrole: String = "", title: String = "", desc: String = "", help: String = "", titleElement: String = "",
                 enabled: Bool = true, frame: CGRect? = CGRect(x: 10, y: 10, width: 30, height: 24)) -> Control {
        var c = Control(role: role, subrole: subrole, title: title, description: desc, help: help, frame: frame, enabled: enabled)
        c.titleElementText = titleElement
        return c
    }

    func testEmptyIsFlaggedAsEmpty() {
        XCTAssertEqual(LabelFlagger.verdict(control()), .unlabeled(.empty))
    }

    func testGenericTitleOrDescriptionIsFlaggedAsGeneric() {
        XCTAssertEqual(LabelFlagger.verdict(control(title: "button")), .unlabeled(.generic("button")))
        XCTAssertEqual(LabelFlagger.verdict(control(desc: "icon.png")), .unlabeled(.generic("icon.png")))
        XCTAssertEqual(LabelFlagger.verdict(control(title: "X", desc: "image")), .unlabeled(.generic("X")))
    }

    func testAnyRealNameMakesItLabeled() {
        XCTAssertEqual(LabelFlagger.verdict(control(title: "Save")), .labeled)
        XCTAssertEqual(LabelFlagger.verdict(control(desc: "Settings")), .labeled)
        XCTAssertEqual(LabelFlagger.verdict(control(titleElement: "Volume")), .labeled)
        XCTAssertEqual(LabelFlagger.verdict(control(title: "button", desc: "Settings")), .labeled)
        XCTAssertEqual(LabelFlagger.verdict(control("AXCheckBox", title: "Remember me")), .labeled)
    }

    func testHelpAloneDoesNotMakeItLabeled() {
        XCTAssertEqual(LabelFlagger.verdict(control(help: "Opens the settings")), .unlabeled(.empty))
        XCTAssertEqual(LabelFlagger.verdict(control(title: "button", help: "Opens the settings")), .unlabeled(.generic("button")))
    }

    func testRolesThatAreChecked() {
        for role in ["AXButton", "AXCheckBox", "AXLink", "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle"] {
            XCTAssertEqual(LabelFlagger.verdict(control(role)), .unlabeled(.empty), role)
        }
        for role in ["AXStaticText", "AXTextField", "AXGroup", "AXImage", "AXSlider", "AXRadioButton", "AXMenuItem", "AXWindow"] {
            XCTAssertEqual(LabelFlagger.verdict(control(role)), .notChecked, role)
        }
        XCTAssertEqual(LabelFlagger.verdict(control("AXCheckBox", subrole: "AXSwitch")), .unlabeled(.empty))
        XCTAssertEqual(LabelFlagger.verdict(control("AXCheckBox", subrole: "AXToggle")), .unlabeled(.empty))
    }

    func testDisabledHiddenAndZeroSizeAreSkipped() {
        XCTAssertEqual(LabelFlagger.verdict(control(enabled: false)), .skipped(.disabled))
        XCTAssertEqual(LabelFlagger.verdict(control(frame: nil)), .skipped(.hidden))
        XCTAssertEqual(LabelFlagger.verdict(control(frame: .zero)), .skipped(.hidden))
        XCTAssertEqual(LabelFlagger.verdict(control(frame: CGRect(x: 0, y: 0, width: 1, height: 20))), .skipped(.hidden))
        XCTAssertEqual(LabelFlagger.verdict(control(frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))), .skipped(.hidden))
        XCTAssertEqual(LabelFlagger.verdict(control(frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10))), .skipped(.hidden))
    }

    func testSecureControlsAreNeverChecked() {
        XCTAssertEqual(LabelFlagger.verdict(control("AXSecureTextField")), .notChecked)
    }
}

final class LabelScanFixtureTests: XCTestCase {
    func scan() -> (LabelScan, AXReadResult<LabelTestNode>) {
        let result = LabelFixture.controls()!
        return (LabelScanner.scan(controls: result.controls, windowFrame: LabelFixture.windowFrame, truncated: result.truncated), result)
    }

    func identifiers(_ scan: LabelScan, flagged: Bool) -> [String] {
        scan.entries.filter { $0.flagged == flagged }.map { $0.identifier }
    }

    func testAtLeastNinetyPercentOfTheUnlabeledControlsAreFlaggedAndNoLabeledOneIs() {
        let (scan, _) = scan()
        let flagged = Set(identifiers(scan, flagged: true))
        let unlabeled = (1...14).map { $0 == 1 ? "btnPlay" : "u\($0)" }
        let hit = unlabeled.filter { flagged.contains($0) }
        XCTAssertGreaterThanOrEqual(Double(hit.count) / Double(unlabeled.count), 0.9, "missed: \(Set(unlabeled).subtracting(flagged))")
        XCTAssertEqual(flagged.filter { $0.hasPrefix("l") || $0.hasPrefix("s") }, [], "false flags")
        XCTAssertEqual(flagged.count, hit.count, "something unexpected was flagged: \(flagged)")
    }

    func testEveryUnlabeledFixtureControlIsInfactFlagged() {
        let (scan, _) = scan()
        XCTAssertEqual(scan.candidates.count, 14)
        XCTAssertEqual(scan.candidates.map { $0.id }, Array(1...14))
    }

    func testCandidatesCarryRoleHelpIdentifierNearbyTextAndRelativePosition() {
        let (scan, _) = scan()
        let play = scan.candidates.first { $0.identifier == "btnPlay" }!
        XCTAssertEqual(play.role, "AXButton")
        XCTAssertEqual(play.nearbyText, ["Playback"])
        XCTAssertEqual(play.relativeFrame, CGRect(x: 200, y: 20, width: 30, height: 24))
        XCTAssertEqual(play.reason, .empty)
        let help = scan.candidates.first { $0.identifier == "u13" }!
        XCTAssertEqual(help.help, "Opens settings")
        let generic = scan.candidates.first { $0.identifier == "u2" }!
        XCTAssertEqual(generic.reason, .generic("button"))
    }

    func testSkippedControlsAreListedWithTheirReason() {
        let (scan, _) = scan()
        let skipped = scan.entries.filter { $0.verdict.hasPrefix("skipped") }
        XCTAssertEqual(Set(skipped.filter { $0.subrole.isEmpty }.map { $0.identifier }), ["s1", "s2", "s3"])
    }

    func testTheWindowsTrafficLightsAreSkippedNotFlagged() {
        let (scan, _) = scan()
        let lights = scan.entries.filter { LabelFlagger.windowChromeSubroles.contains($0.subrole) }
        XCTAssertEqual(Set(lights.map { $0.subrole }), ["AXCloseButton", "AXMinimizeButton", "AXZoomButton"])
        XCTAssertTrue(lights.allSatisfy { !$0.flagged && $0.verdict == "skipped:chrome" }, "\(lights.map { $0.verdict })")
        XCTAssertFalse(scan.candidates.contains { LabelFlagger.windowChromeSubroles.contains($0.subrole) })
    }

    func testAPopUpIsNamedByTheItemItShows() {
        let (scan, _) = scan()
        let shown = scan.entries.first { $0.identifier == "l7" }!
        XCTAssertEqual(shown.value, "Sort by name")
        XCTAssertFalse(shown.flagged)
        XCTAssertEqual(shown.verdict, "labeled")
        let empty = scan.entries.first { $0.identifier == "u9" }!
        XCTAssertTrue(empty.flagged, "a pop-up that shows nothing is still unlabeled")
    }

    func testOnlyPopUpsAndMenuButtonsTakeTheirNameFromTheValue() {
        func verdict(_ role: String, value: String?) -> LabelVerdict {
            LabelFlagger.verdict(Control(role: role, value: value, frame: CGRect(x: 0, y: 0, width: 30, height: 20)))
        }
        XCTAssertEqual(verdict("AXPopUpButton", value: "Sort by name"), .labeled)
        XCTAssertEqual(verdict("AXMenuButton", value: "Actions"), .labeled)
        XCTAssertEqual(verdict("AXButton", value: "Sort by name"), .unlabeled(.empty))
        XCTAssertEqual(verdict("AXCheckBox", value: "Sort by name"), .unlabeled(.empty))
        XCTAssertEqual(verdict("AXPopUpButton", value: "image"), .unlabeled(.generic("image")))
        XCTAssertEqual(verdict("AXPopUpButton", value: ""), .unlabeled(.empty))
        XCTAssertEqual(verdict("AXPopUpButton", value: nil), .unlabeled(.empty))
    }

    func testEveryWindowChromeSubroleIsSkippedEvenWhenEnabled() {
        for sub in ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"] {
            let c = Control(role: "AXButton", subrole: sub, frame: CGRect(x: 0, y: 0, width: 14, height: 16))
            XCTAssertEqual(LabelFlagger.verdict(c), .skipped(.windowChrome), sub)
        }
    }

    func testTheSyntheticWindowIsScoredLikeTheLiveOne() {
        let (scan, _) = scan()
        let unlabeled = Set((1...14).map { $0 == 1 ? "btnPlay" : "u\($0)" })
        let flagged = Set(scan.entries.filter { $0.flagged }.map { $0.identifier })
        XCTAssertGreaterThanOrEqual(Double(unlabeled.intersection(flagged).count) / Double(unlabeled.count), 0.9)
        XCTAssertEqual(flagged.subtracting(unlabeled), [], "false flags")
    }

    func testScannedEntriesCarryRoleSubroleValueAndFingerprint() {
        let (scan, _) = scan()
        let wifi = scan.entries.first { $0.identifier == "u11" }!
        XCTAssertEqual(wifi.role, "AXCheckBox")
        XCTAssertEqual(wifi.subrole, "AXSwitch")
        XCTAssertFalse(wifi.fingerprint.isEmpty)
        XCTAssertEqual(Set(scan.entries.map { $0.fingerprint }).count, scan.entries.count, "no two checked controls share a fingerprint")
    }

    func testControlsFromOtherWindowsAreNotScanned() {
        var result = LabelFixture.controls()!
        for i in result.nodes.indices { result.nodes[i].control.inTargetWindow = false }
        let scan = LabelScanner.scan(controls: result.controls, windowFrame: LabelFixture.windowFrame, truncated: false)
        XCTAssertTrue(scan.entries.isEmpty)
    }

    func testControlsOutsideTheWindowAreSkipped() {
        var c = Control(role: "AXButton", frame: CGRect(x: 5000, y: 5000, width: 30, height: 30), pathID: "0/1")
        c.inTargetWindow = true
        let root = Control(role: "AXWindow", frame: LabelFixture.windowFrame, pathID: "0")
        let scan = LabelScanner.scan(controls: [root, c], windowFrame: LabelFixture.windowFrame, truncated: false)
        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertEqual(scan.entries.first?.verdict, "skipped:hidden")
    }

    func testSecureFieldValueIsNotCarriedIntoCandidates() {
        var s = Control(role: "AXSecureTextField", value: "hunter2", frame: CGRect(x: 120, y: 120, width: 100, height: 20), pathID: "0/0/0")
        s.inTargetWindow = true
        let group = Control(role: "AXGroup", frame: CGRect(x: 110, y: 110, width: 300, height: 100), pathID: "0/0")
        let b = Control(role: "AXButton", help: "Go on", frame: CGRect(x: 230, y: 120, width: 30, height: 20), pathID: "0/0/1")
        let root = Control(role: "AXWindow", frame: LabelFixture.windowFrame, pathID: "0")
        let scan = LabelScanner.scan(controls: [root, group, s, b], windowFrame: LabelFixture.windowFrame, truncated: false)
        XCTAssertEqual(scan.candidates.count, 1)
        XCTAssertFalse(scan.candidates[0].nearbyText.joined().contains("hunter2"))
    }
}

final class LabelWalkCapTests: XCTestCase {
    func deepChain(_ depth: Int) -> LabelTestNode {
        var node = LabelTestNode(role: "AXButton", frame: CGRect(x: 300, y: 300, width: 30, height: 30), identifier: "deep")
        for _ in 0..<depth { node = LabelTestNode(role: "AXGroup", frame: LabelFixture.windowFrame, kids: [node]) }
        return LabelTestNode(role: "AXWindow", frame: LabelFixture.windowFrame, kids: [node])
    }

    func testTheLabelScanLimitsAreDepth30AndAboutTwoSeconds() {
        XCTAssertEqual(AXWalkLimits.labelScan.maxDepth, 30)
        XCTAssertEqual(AXWalkLimits.labelScan.timeBudget, 2.0)
        XCTAssertGreaterThan(AXWalkLimits.labelScan.maxNodes, AXWalkLimits.standard.maxNodes)
    }

    func testAControlWithinTheDepthCapIsFoundAndNothingIsReportedPartial() {
        let result = LabelFixture.controls(root: deepChain(20))!
        XCTAssertFalse(result.truncated)
        let scan = LabelScanner.scan(controls: result.controls, windowFrame: LabelFixture.windowFrame, truncated: result.truncated || result.depthCut)
        XCTAssertEqual(scan.candidates.map { $0.identifier }, ["deep"])
        XCTAssertFalse(scan.partial)
    }

    func testTheDepthCapCutsTheWalkAndReportsPartial() {
        let result = LabelFixture.controls(root: deepChain(40))!
        XCTAssertFalse(result.truncated, "the depth cap is not the node or time cap; it has its own flag")
        XCTAssertTrue(result.depthCut)
        let scan = LabelScanner.scan(controls: result.controls, windowFrame: LabelFixture.windowFrame, truncated: result.truncated || result.depthCut)
        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.partial)
    }

    func testTheNodeCapStopsTheWalkAndReportsPartial() {
        let limits = AXWalkLimits(maxDepth: 30, maxNodes: 20, timeBudget: 2.0)
        let result = LabelFixture.controls(limits: limits)!
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.nodesVisited, 20)
        let scan = LabelScanner.scan(controls: result.controls, windowFrame: LabelFixture.windowFrame, truncated: result.truncated)
        XCTAssertTrue(scan.partial)
    }

    func testTheTimeCapStopsTheWalkWithAnInjectedClock() {
        var now: TimeInterval = 0
        let limits = AXWalkLimits(maxDepth: 30, maxNodes: 1500, timeBudget: 2.0)
        // Every read of the clock moves it forward 0.5 s: the 2 s deadline passes after a handful of nodes.
        let result = LabelFixture.controls(limits: limits, clock: { now += 0.5; return now })
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.truncated ?? false)
        XCTAssertLessThan(result?.nodesVisited ?? 999, 10)
    }

    func testAFullWalkOfTheFixtureIsNotPartial() {
        let result = LabelFixture.controls()!
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.depthCut)
    }
}
