import XCTest
@testable import ShepCore

final class ShepThemesTests: XCTestCase {
    func testTwelveThemesTangerineFirst() {
        XCTAssertEqual(ShepThemes.all.count, 12)
        XCTAssertEqual(ShepThemes.defaultTheme.name, "Tangerine")
        XCTAssertEqual(ShepThemes.defaultTheme.bodyHex, "#FF7A1A")
        XCTAssertEqual(Set(ShepThemes.all.map(\.id)).count, 12)
    }

    func testIDsMatchTheJSSlugRule() {
        XCTAssertEqual(ShepThemes.themeID("Beagle Tan"), "beagle-tan")
        XCTAssertEqual(ShepThemes.themeID("  --Cobalt!! "), "cobalt")
        XCTAssertEqual(ShepThemes.themeID(""), "")
    }

    func testFindFallsBackToDefault() {
        XCTAssertEqual(ShepThemes.find("cobalt").name, "Cobalt")
        XCTAssertEqual(ShepThemes.find("BEAGLE TAN").name, "Beagle Tan")
        XCTAssertEqual(ShepThemes.find("nope").name, "Tangerine")
        XCTAssertEqual(ShepThemes.find(nil).name, "Tangerine")
    }

    func testStateRawValuesMatchTheRenderer() {
        XCTAssertEqual(ShepDogState.lookLeft.rawValue, "look-left")
        XCTAssertEqual(ShepDogState.allCases.count, 7)
    }

    func testJSLiteralEscapes() {
        XCTAssertEqual(JSLiteral.string("hi"), "\"hi\"")
        XCTAssertEqual(JSLiteral.string("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(JSLiteral.string("x\ny"), "\"x\\ny\"")
        XCTAssertEqual(JSLiteral.string("\u{01}"), "\"\\u0001\"")
        XCTAssertEqual(JSLiteral.string("\u{2028}"), "\"\\u2028\"")
        XCTAssertEqual(JSLiteral.string("héllo 🐕"), "\"héllo 🐕\"")
    }
}
