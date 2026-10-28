import XCTest
@testable import ShepCore

final class WakeWordMatcherTests: XCTestCase {
    func testPositives() {
        for t in ["hey shep", "Hey Shep", "HEY SHEP", "hey shep!", "Hey, Shep", "hey... shep", "  hey   shep  ",
                  "okay hey shep what is this", "so, hey shep, fix this", "hey shep.", "\"Hey Shep\"", "hey-shep"] {
            XCTAssertTrue(WakeWordMatcher.matches(t), t)
        }
    }

    func testNearMissesTheRecogniserProduces() {
        for t in ["hey shepp", "hey sheppe", "hay shep", "hei shep", "a shep", "eh shep", "hey shap", "heyshep", "Hey Shép"] {
            XCTAssertTrue(WakeWordMatcher.matches(t), t)
        }
    }

    func testNegatives() {
        for t in ["hey chef", "shepherd's pie", "shepherd", "sheep", "hey sheep", "shep", "hey", "they shepherd",
                  "hey shepherd", "hi shep", "hey sheppard", "", "   ", "hey, hey", "the shep", "ashep", "hey shaped"] {
            XCTAssertFalse(WakeWordMatcher.matches(t), t)
        }
    }

    func testHiIsDeliberatelyOut() {
        XCTAssertFalse(WakeWordMatcher.matches("hi shep"), "'hi' is an everyday word; only the greetings in the rule count")
    }

    func testCountsOccurrences() {
        XCTAssertEqual(WakeWordMatcher.matchCount(in: "hey shep"), 1)
        XCTAssertEqual(WakeWordMatcher.matchCount(in: "hey shep hey shep"), 2)
        XCTAssertEqual(WakeWordMatcher.matchCount(in: "hey shep shep"), 1)
        XCTAssertEqual(WakeWordMatcher.matchCount(in: "hey hey shep"), 1)
        XCTAssertEqual(WakeWordMatcher.matchCount(in: "hey chef"), 0)
    }

    func testTokensAreNormalised() {
        XCTAssertEqual(WakeWordMatcher.tokens("Hey, SHEP!  it's"), ["hey", "shep", "it", "s"])
    }

    // MARK: detector

    func testDetectorFiresOnceWhileTheTranscriptKeepsGrowing() {
        var d = WakeWordDetector()
        XCTAssertFalse(d.consume("hey"))
        XCTAssertTrue(d.consume("hey shep"))
        XCTAssertFalse(d.consume("hey shep what"))
        XCTAssertFalse(d.consume("hey shep what is on"))
        XCTAssertFalse(d.consume("hey shep what is on screen"))
        XCTAssertEqual(d.reportedCount, 1)
    }

    func testDetectorFiresForASecondOccurrence() {
        var d = WakeWordDetector()
        XCTAssertTrue(d.consume("hey shep"))
        XCTAssertFalse(d.consume("hey shep and"))
        XCTAssertTrue(d.consume("hey shep and hey shep"))
        XCTAssertFalse(d.consume("hey shep and hey shep please"))
        XCTAssertEqual(d.reportedCount, 2)
    }

    func testDetectorResetsPerRecognitionTask() {
        var d = WakeWordDetector()
        XCTAssertTrue(d.consume("hey shep"))
        d.reset()
        XCTAssertEqual(d.reportedCount, 0)
        XCTAssertTrue(d.consume("hey shep"), "a new task starts from zero")
    }

    func testDetectorIgnoresNonMatches() {
        var d = WakeWordDetector()
        for t in ["hey", "hey chef", "shepherd's pie", "they shepherd"] { XCTAssertFalse(d.consume(t), t) }
        XCTAssertEqual(d.reportedCount, 0)
    }

    func testARevisedTranscriptDoesNotRefireAnOldMatch() {
        var d = WakeWordDetector()
        XCTAssertTrue(d.consume("hey shep"))
        XCTAssertFalse(d.consume("hey chef"), "the recogniser changed its mind")
        XCTAssertFalse(d.consume("hey shep"), "the same single occurrence is not new")
    }
}
