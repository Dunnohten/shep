import XCTest
@testable import ShepCore

final class TargetRecheckTests: XCTestCase {
    let save = Control(index: 1, role: "AXButton", title: "Save", pathID: "0/1")

    func live(_ role: String = "AXButton", subrole: String = "", title: String = "Save", description: String = "",
              value: String? = nil, help: String = "", enabled: Bool = true, inWindow: Bool = true) -> LiveTarget {
        LiveTarget(role: role, subrole: subrole, title: title, description: description, value: value, help: help, enabled: enabled, inSnapshotWindow: inWindow)
    }

    func testUnchangedTargetPasses() {
        XCTAssertEqual(TargetRecheck.verify(listed: save, live: live()), .ok)
    }

    func testLabelComparisonIgnoresCaseAndWhitespace() {
        XCTAssertEqual(TargetRecheck.verify(listed: save, live: live(title: "  save ")), .ok)
        var long = save; long.title = "Save  As\n"
        XCTAssertEqual(TargetRecheck.verify(listed: long, live: live(title: "save as")), .ok)
    }

    func testSecureFieldIsRefusedWhateverTheSnapshotSaid() {
        guard case .refuse = TargetRecheck.verify(listed: save, live: live(subrole: "AXSecureTextField")) else { return XCTFail() }
        guard case .refuse = TargetRecheck.verify(listed: save, live: live("AXSecureTextField")) else { return XCTFail() }
        var secureListed = save; secureListed.subrole = "AXSecureTextField"
        guard case .refuse = TargetRecheck.verify(listed: secureListed, live: live(subrole: "AXSecureTextField")) else { return XCTFail() }
    }

    func testDisabledNowIsRefusedEvenIfEnabledInTheSnapshot() {
        XCTAssertTrue(save.enabled)
        guard case .refuse = TargetRecheck.verify(listed: save, live: live(enabled: false)) else { return XCTFail() }
    }

    func testRoleAndSubroleChangesAreRefused() {
        guard case .refuse = TargetRecheck.verify(listed: save, live: live("AXCheckBox")) else { return XCTFail() }
        guard case .refuse = TargetRecheck.verify(listed: save, live: live(subrole: "AXCloseButton")) else { return XCTFail() }
    }

    func testDifferentWindowIsRefused() {
        guard case .refuse = TargetRecheck.verify(listed: save, live: live(inWindow: false)) else { return XCTFail() }
    }

    func testLabelChangedIsRefused() {
        guard case .refuse = TargetRecheck.verify(listed: save, live: live(title: "Delete")) else { return XCTFail() }
    }

    func testMissingLiveLabelIsRefusedWhenTheSnapshotHadOne() {
        guard case .refuse = TargetRecheck.verify(listed: save, live: live(title: "")) else { return XCTFail() }
    }

    func testDescriptionIsTheLabelWhenThereIsNoTitle() {
        let icon = Control(index: 2, role: "AXButton", description: "Share", pathID: "0/2")
        XCTAssertEqual(TargetRecheck.verify(listed: icon, live: live(title: "", description: "Share")), .ok)
        guard case .refuse = TargetRecheck.verify(listed: icon, live: live(title: "", description: "")) else { return XCTFail() }
        guard case .refuse = TargetRecheck.verify(listed: icon, live: live(title: "", description: "Delete")) else { return XCTFail() }
    }

    func testButtonValueIsTheLabelOfLastResortButNotForOtherRoles() {
        let b = Control(index: 3, role: "AXButton", value: "Next", pathID: "0/3")
        XCTAssertEqual(TargetRecheck.verify(listed: b, live: live(title: "", value: "Next")), .ok)
        guard case .refuse = TargetRecheck.verify(listed: b, live: live(title: "", value: "Back")) else { return XCTFail() }
        // A text field's value is what the user typed, not its name.
        let field = Control(index: 4, role: "AXTextField", value: "hello", pathID: "0/4")
        XCTAssertEqual(TargetRecheck.identifyingLabel(role: field.role, title: "", description: "", value: field.value), "")
        XCTAssertEqual(TargetRecheck.verify(listed: field, live: live("AXTextField", title: "", value: "something else")), .ok)
    }

    func testUnnamedControlThatGainedANameIsRefused() {
        let plain = Control(index: 5, role: "AXButton", pathID: "0/5")
        guard case .refuse = TargetRecheck.verify(listed: plain, live: live(title: "Delete all")) else { return XCTFail() }
        XCTAssertEqual(TargetRecheck.verify(listed: plain, live: live(title: "")), .ok)
    }

    func testDialogTitleNamesTheActionAndTheApp() {
        let press = ProposedAction(control: save, kind: .axPress, bundleID: "com.apple.TextEdit")
        XCTAssertEqual(press.dialogTitle(appName: "TextEdit"), "Shep wants to press Save in TextEdit")
        let click = ProposedAction(control: save, kind: .clickPoint, bundleID: "b")
        XCTAssertEqual(click.dialogTitle(appName: ""), "Shep wants to click Save")
        let unnamed = ProposedAction(control: Control(role: "AXButton"), kind: .clickPoint, bundleID: "b")
        XCTAssertEqual(unnamed.dialogTitle(appName: "Notes"), "Shep wants to click a button in Notes")
        let type = ProposedAction(control: Control(role: "AXTextField", title: "Search"), kind: .setValue("x"), bundleID: "b")
        XCTAssertEqual(type.dialogTitle(appName: "Notes"), "Shep wants to type into Search in Notes")
    }

    // MARK: P2-3 tooltip-only controls

    let turtle = Control(index: 1, role: "AXCheckBox", help: "Speed Limit overrides the total bandwidth limits", actions: ["AXPress"], pathID: "0/9")

    func turtleLive(help: String, title: String = "", description: String = "") -> LiveTarget {
        LiveTarget(role: "AXCheckBox", title: title, description: description, help: help)
    }

    func testATooltipOnlyControlThatIsUnchangedPasses() {
        XCTAssertEqual(turtle.labelSource, .tooltip)
        XCTAssertEqual(TargetRecheck.verify(listed: turtle, live: turtleLive(help: "  speed limit overrides the total bandwidth limits ")), .ok)
    }

    func testATooltipOnlyRenameRefuses() {
        guard case .refuse = TargetRecheck.verify(listed: turtle, live: turtleLive(help: "Delete all downloads")) else { return XCTFail("renamed tooltip passed") }
    }

    func testATooltipThatDisappearedRefuses() {
        guard case .refuse = TargetRecheck.verify(listed: turtle, live: turtleLive(help: "")) else { return XCTFail("lost its name") }
    }

    func testTheSameWordsFromADifferentSourceRefuses() {
        // Approved: named by its tooltip. Now the same words are its title: still a change that needs a fresh approval.
        guard case .refuse = TargetRecheck.verify(listed: turtle, live: turtleLive(help: "", title: "Speed Limit overrides the total bandwidth limits")) else { return XCTFail("source changed") }
        var titled = turtle; titled.title = "Info"; titled.help = ""
        guard case .refuse = TargetRecheck.verify(listed: titled, live: turtleLive(help: "Info")) else { return XCTFail("title became tooltip") }
    }

    func testATooltipThatAppearsOnANamedControlDoesNotChangeItsName() {
        var named = save; named.help = ""
        XCTAssertEqual(TargetRecheck.verify(listed: named, live: live(help: "A new tip")), .ok)
    }

    func testAStaticTextNamedByItsValueIsComparedByTheSameResolver() {
        let text = Control(index: 1, role: "AXStaticText", value: "Hello", actions: ["AXPress"], pathID: "0/2")
        XCTAssertEqual(TargetRecheck.verify(listed: text, live: LiveTarget(role: "AXStaticText", value: "Hello")), .ok)
        guard case .refuse = TargetRecheck.verify(listed: text, live: LiveTarget(role: "AXStaticText", value: "Goodbye")) else { return XCTFail("value text renamed") }
    }

    func testTheControlsOwnLabelAndTheLiveLabelUseOneResolver() {
        let c = Control(role: "AXButton", title: "", description: "", value: "ignored", help: "Tip text")
        XCTAssertEqual(TargetRecheck.effectiveLabel(role: "AXButton", title: "", description: "", value: "ignored", help: "Tip text").text, c.label)
        XCTAssertEqual(TargetRecheck.effectiveLabel(role: "AXButton", title: "", description: "", value: "ignored", help: "Tip text").source, c.labelSource)
    }
}
