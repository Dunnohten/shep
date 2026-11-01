import XCTest
@testable import ShepCore

final class SurfaceStyleTests: XCTestCase {
    func testDefaultIsAMaterialWithAHairline() {
        let s = SurfaceStyle.resolve(reduceTransparency: false, increaseContrast: false)
        XCTAssertFalse(s.solid)
        XCTAssertEqual(s.borderWidth, 0.5)
        XCTAssertEqual(s.borderStrength, 0)   // the system separator colour
        XCTAssertFalse(s.fullStrengthSymbols)
    }

    func testReduceTransparencyMakesTheSurfaceSolidAndNothingElse() {
        let s = SurfaceStyle.resolve(reduceTransparency: true, increaseContrast: false)
        XCTAssertTrue(s.solid)
        XCTAssertEqual(s.borderWidth, 0.5)
    }

    func testIncreaseContrastDrawsAStrongerOutlineAndFullStrengthSymbols() {
        let s = SurfaceStyle.resolve(reduceTransparency: false, increaseContrast: true)
        XCTAssertFalse(s.solid)
        XCTAssertEqual(s.borderWidth, 1)
        XCTAssertGreaterThanOrEqual(s.borderStrength, 0.6)
        XCTAssertTrue(s.fullStrengthSymbols)
    }

    func testBothTogether() {
        let s = SurfaceStyle.resolve(reduceTransparency: true, increaseContrast: true)
        XCTAssertTrue(s.solid)
        XCTAssertEqual(s.borderWidth, 1)
    }

    func testCardMotionIsASubtleEaseOfAboutAQuarterSecond() {
        let t = CardTiming.resolve(reduceMotion: false)
        XCTAssertTrue((0.2...0.3).contains(t.fadeIn))
        XCTAssertTrue((0.1...0.2).contains(t.fadeOut))
        XCTAssertTrue((1...8).contains(t.slide))
    }

    func testReduceMotionIsAPlainShortFadeWithNoSlide() {
        let t = CardTiming.resolve(reduceMotion: true)
        XCTAssertEqual(t.slide, 0)
        XCTAssertGreaterThan(t.fadeIn, 0)
        XCTAssertLessThanOrEqual(t.fadeIn, CardTiming.resolve(reduceMotion: false).fadeIn)
        XCTAssertGreaterThan(t.fadeOut, 0)
    }
}
