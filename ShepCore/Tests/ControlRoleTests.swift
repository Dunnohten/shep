import CoreGraphics
import XCTest
@testable import ShepCore

final class ControlRoleTests: XCTestCase {
    func testTheSchemaEnumIsTheBriefsList() {
        XCTAssertEqual(ControlRole.schemaNames, ["button", "link", "tab", "checkbox", "text field", "menu item", "icon", "static text", "image", "other"])
        XCTAssertEqual(GlimmerNaming.roles, ControlRole.schemaNames)
    }

    func testStaticTextImagesAndOtherAreNeverProposable() {
        for r in ControlRole.allCases {
            XCTAssertEqual(r.isProposable, ![.staticText, .image, .other].contains(r), "\(r)")
        }
    }

    func testAccessibilityRolesMapToKinds() {
        let table: [(String, ControlRole?)] = [
            ("AXButton", .button), ("AXPopUpButton", .button), ("AXLink", .link), ("AXTab", .tab), ("AXCheckBox", .checkbox),
            ("AXRadioButton", .checkbox), ("AXTextField", .textField), ("AXTextArea", .textField), ("AXComboBox", .textField),
            ("AXSearchField", .textField), ("AXMenuItem", .menuItem), ("AXMenuBarItem", .menuItem), ("AXStaticText", .staticText),
            ("AXImage", .image), ("AXSlider", .other), ("AXGroup", nil), ("AXWindow", nil), ("", nil),
        ]
        for (ax, role) in table { XCTAssertEqual(ControlRole(axRole: ax), role, ax) }
    }

    func testTheModelsWordsAreForgivenButUnknownWordsAreNil() {
        XCTAssertEqual(ControlRole.recognized("Button"), .button)
        XCTAssertEqual(ControlRole.recognized("Text-Field"), .textField)
        XCTAssertEqual(ControlRole.recognized("static_text"), .staticText)
        XCTAssertEqual(ControlRole.recognized("  menu item "), .menuItem)
        XCTAssertEqual(ControlRole.recognized("Label"), .staticText)
        XCTAssertEqual(ControlRole.recognized("paragraph"), .staticText)
        XCTAssertEqual(ControlRole.recognized("toggle"), .checkbox)
        XCTAssertEqual(ControlRole.recognized("photo"), .image)
        XCTAssertNil(ControlRole.recognized("Wobbly"))
        XCTAssertNil(ControlRole.recognized(""))
        XCTAssertNil(ControlRole.recognized(nil))
        XCTAssertEqual(ControlRole(modelText: "Wobbly"), .other)
        XCTAssertEqual(ControlRole(modelText: nil), .other)
    }

    func testAxRoleRoundTripsExceptIconWhichIsAButton() {
        for r in ControlRole.allCases where r != .icon {
            XCTAssertEqual(ControlRole(axRole: r.axRole), r, "\(r)")
        }
        XCTAssertEqual(ControlRole(axRole: ControlRole.icon.axRole), .button)
    }

    func testFoundControlsAreListedWithTheMatchingAccessibilityRole() {
        let table: [(String, String)] = [
            ("text field", "AXTextField"), ("field", "AXTextField"), ("search field", "AXTextField"), ("checkbox", "AXCheckBox"),
            ("switch", "AXCheckBox"), ("tab", "AXTab"), ("menu", "AXMenuItem"), ("menu item", "AXMenuItem"), ("link", "AXLink"),
            ("icon", "AXButton"), ("button", "AXButton"), ("rounded rectangle", "AXButton"), ("", "AXButton"),
            ("static text", "AXStaticText"), ("text", "AXStaticText"), ("image", "AXImage"), ("other", "AXUnknown"),
        ]
        for (kind, ax) in table { XCTAssertEqual(VisionRepair.axRole(for: kind), ax, kind) }
    }
}

final class RoleResolverTests: XCTestCase {
    let sendAX = Control(index: 1, role: "AXButton", title: "Send", frame: CGRect(x: 200, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/1")
    let searchAX = Control(index: 2, role: "AXSearchField", title: "Search", frame: CGRect(x: 100, y: 20, width: 200, height: 28), pathID: "0/2")
    let groupAX = Control(index: 3, role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 400, height: 300), pathID: "0")
    var ax: [Control] { [sendAX, searchAX, groupAX] }

    func resolve(_ frame: CGRect, _ model: String?, _ name: String, ax list: [Control]? = nil) -> ResolvedRole {
        RoleResolver.resolve(frame: frame, modelText: model, name: name, ax: list ?? ax)
    }

    // MARK: Accessibility wins

    func testAnOverlappingAXElementGivesItsRoleWhateverTheModelSaid() {
        let r = resolve(CGRect(x: 210, y: 104, width: 40, height: 20), "text field", "Message")   // IoU 0.43 with Send
        XCTAssertEqual(r.role, .button)
        XCTAssertEqual(r.source, .ax)
        XCTAssertEqual(r.axMatch?.title, "Send")
        let field = resolve(CGRect(x: 110, y: 22, width: 180, height: 24), "static text", "Search")   // IoU 0.77 with the search field
        XCTAssertEqual(field.role, .textField)
        XCTAssertEqual(field.source, .ax)
    }

    func testAnIconInsideAComparableAXElementIsThatElement() {
        let r = resolve(CGRect(x: 205, y: 104, width: 18, height: 12), "icon", "")   // IoU 0.27, fully inside, element 3.7x its area
        XCTAssertEqual(r.source, .ax)
        XCTAssertEqual(r.role, .button)
    }

    func testASmallBoxInsideALargeElementOrAContainerIsNotThatElement() {
        let tiny = resolve(CGRect(x: 205, y: 104, width: 10, height: 6), "icon", "Gear")   // element would be 13x its area
        XCTAssertEqual(tiny.source, .model)
        let inGroup = resolve(CGRect(x: 50, y: 150, width: 40, height: 30), "button", "Gear")   // only the window-sized group holds it
        XCTAssertEqual(inGroup.source, .model)
        XCTAssertEqual(inGroup.role, .button)
    }

    // MARK: vision-only boxes

    func testATextFieldNeedsAFieldShapeAndAFieldNotAParagraphName() {
        let wide = CGRect(x: 50, y: 200, width: 200, height: 28)
        XCTAssertEqual(resolve(wide, "text field", "Search").role, .textField)
        XCTAssertEqual(resolve(wide, "text field", "Email field").role, .textField)
        XCTAssertEqual(resolve(wide, "text field", "Body text").role, .staticText, "called text, shaped like a line")
        XCTAssertEqual(resolve(wide, "text field", "Body text").source, .heuristic)
        XCTAssertEqual(resolve(CGRect(x: 50, y: 200, width: 300, height: 16), "text field", "Paragraph").role, .staticText)
        XCTAssertEqual(resolve(CGRect(x: 50, y: 200, width: 200, height: 120), "text field", "Notes").role, .other, "a big block is not a field")
    }

    func testWideShortBoxesNamedLikeTextAreStaticText() {
        let line = CGRect(x: 10, y: 10, width: 120, height: 14)
        XCTAssertEqual(resolve(line, "icon", "Text size").role, .staticText)
        XCTAssertEqual(resolve(line, "other", "Caption").role, .staticText)
        XCTAssertEqual(resolve(line, "static text", "Total").role, .staticText)
        XCTAssertEqual(resolve(line, "button", "Text").role, .button, "a real button is not demoted by its name")
        XCTAssertEqual(resolve(CGRect(x: 10, y: 10, width: 30, height: 30), "icon", "Text").role, .icon, "not wide and short")
    }

    func testImagesOtherAndMissingRoles() {
        XCTAssertEqual(resolve(CGRect(x: 10, y: 10, width: 60, height: 60), "image", "Logo").role, .image)
        XCTAssertEqual(resolve(CGRect(x: 10, y: 10, width: 60, height: 60), "Wobbly", "Thing").role, .other)
        let none = resolve(CGRect(x: 10, y: 10, width: 60, height: 60), nil, "")
        XCTAssertEqual(none.role, .icon, "no role at all: something pressable-looking")
        XCTAssertTrue(none.role.isProposable)
        XCTAssertFalse(resolve(CGRect(x: 10, y: 10, width: 60, height: 60), "image", "Logo").role.isProposable)
    }

    func testShapePredicatesAndNameWords() {
        XCTAssertTrue(RoleResolver.isWideShort(CGRect(x: 0, y: 0, width: 100, height: 20)))
        XCTAssertFalse(RoleResolver.isWideShort(CGRect(x: 0, y: 0, width: 100, height: 50)))
        XCTAssertFalse(RoleResolver.isWideShort(CGRect(x: 0, y: 0, width: 40, height: 40)))
        XCTAssertTrue(RoleResolver.isFieldLike(CGRect(x: 0, y: 0, width: 200, height: 28)))
        XCTAssertFalse(RoleResolver.isFieldLike(CGRect(x: 0, y: 0, width: 50, height: 28)))
        XCTAssertFalse(RoleResolver.isFieldLike(CGRect(x: 0, y: 0, width: 200, height: 10)))
        XCTAssertFalse(RoleResolver.isFieldLike(CGRect(x: 0, y: 0, width: 1000, height: 30)))
        XCTAssertTrue(RoleResolver.nameLooksStatic("Paragraph"))
        XCTAssertTrue(RoleResolver.nameLooksStatic("Page caption"))
        XCTAssertFalse(RoleResolver.nameLooksStatic("Send"))
        XCTAssertTrue(RoleResolver.nameHasFieldWord("Search box"))
        XCTAssertFalse(RoleResolver.nameHasFieldWord("Save"))
    }
}
