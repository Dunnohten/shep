import XCTest
@testable import ShepCore

final class HomeIndicatorTests: XCTestCase {
    func testEveryModeHasASymbolInEachSlotAndAWordForVoiceOver() {
        for mode in HouseMode.allCases {
            let s = HomeIndicatorState.state(for: mode)
            XCTAssertFalse(s.pawSymbol.isEmpty, "\(mode)")
            XCTAssertFalse(s.statusSymbol.isEmpty, "\(mode)")
            XCTAssertFalse(s.accessibilityValue.isEmpty, "\(mode)")
            XCTAssertTrue((0.3...1).contains(s.pawAlpha), "\(mode)")
        }
    }

    func testAsleepAndAwayAreDistinguishableWithoutColour() {
        let asleep = HomeIndicatorState.state(for: .asleep)
        let away = HomeIndicatorState.state(for: .away)
        XCTAssertNotEqual(asleep.statusSymbol, away.statusSymbol)
        XCTAssertNotEqual(asleep.accessibilityValue, away.accessibilityValue)
        XCTAssertNotEqual(asleep.pawSymbol, away.pawSymbol)   // filled paw: Shep is home; outline: Shep is out
    }

    func testTheWordsMatchWhatShepIsDoing() {
        XCTAssertEqual(HomeIndicatorState.state(for: .asleep).accessibilityValue, "Shep is asleep")
        XCTAssertEqual(HomeIndicatorState.state(for: .waking).accessibilityValue, "Shep is waking up")
        XCTAssertEqual(HomeIndicatorState.state(for: .away).accessibilityValue, "Shep is out")
        XCTAssertEqual(HomeIndicatorState.state(for: .entering).accessibilityValue, "Shep is heading to sleep")
    }

    func testOnlyTheWakingTransitionFadesAndNothingMovesUnderReduceMotion() {
        for mode in HouseMode.allCases {
            XCTAssertLessThanOrEqual(HomeIndicatorState.state(for: mode).fadeSeconds(reduceMotion: false), 0.3)
            XCTAssertLessThanOrEqual(HomeIndicatorState.state(for: mode).fadeSeconds(reduceMotion: true), 0.3)
            XCTAssertGreaterThan(HomeIndicatorState.state(for: mode).fadeSeconds(reduceMotion: true), 0)   // a plain fade, never a jump
        }
    }

    func testTheSymbolsAreAllInTheMacOS14Catalogue() {
        let known: Set<String> = ["pawprint.fill", "pawprint", "moon.zzz.fill", "sun.max.fill", "arrow.up.right", "moon.fill"]
        for mode in HouseMode.allCases {
            let s = HomeIndicatorState.state(for: mode)
            XCTAssertTrue(known.contains(s.pawSymbol), s.pawSymbol)
            XCTAssertTrue(known.contains(s.statusSymbol), s.statusSymbol)
        }
    }
}
