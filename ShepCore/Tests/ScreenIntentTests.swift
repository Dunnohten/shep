import XCTest
@testable import ShepCore

final class ScreenIntentTests: XCTestCase {
    func testFixScreenPhrasesRoute() {
        let phrases = [
            "fix this screen", "Fix this screen.", "FIX THIS SCREEN!", "fix the screen", "fix this window", "fix the window",
            "label this screen", "label this window", "fix labels", "fix the labels", "fix these labels",
            "find unlabeled buttons", "Find unlabelled buttons", "find the unlabeled buttons", "find unlabeled controls",
            "find missing labels", "label unlabeled buttons", "fix unlabeled buttons",
            "Shep, fix this screen", "hey shep fix this screen", "Hey Shep, label this screen.", "ok shep fix labels",
            "okay shep, find unlabeled buttons", "please fix this screen", "shep please fix this screen", "fix this screen please",
            "  fix   this\nscreen  ", "find unlabeled buttons on this screen", "find unlabeled buttons in this window",
        ]
        for p in phrases { XCTAssertEqual(ScreenIntentRouter.route(p), .fixScreen, p) }
    }

    func testClearLabelsPhrasesRoute() {
        let phrases = [
            "clear labels for this app", "Clear labels for this app.", "clear the labels for this app", "clear all labels for this app",
            "clear my labels for this app", "remove labels for this app", "reset labels for this app", "forget labels for this app",
            "clear labels for this application", "clear labels in this app", "clear this app's labels", "clear this apps labels",
            "Shep, clear labels for this app", "hey shep clear the labels for this app", "clear labels",
        ]
        for p in phrases { XCTAssertEqual(ScreenIntentRouter.route(p), .clearLabels, p) }
    }

    func testEverythingElseStaysOnTheExistingPipeline() {
        let phrases = [
            "", "   ", "click the save button", "press save", "what is on this screen", "fix this screen so the text is bigger",
            "fix the typo in this window", "label the red button as danger", "find the save button", "find unlabeled",
            "clear the cache", "clear this field", "clear labels and quit", "clear labels for every app on the machine",
            "delete this file", "fix", "screen", "fix this", "unlabeled buttons", "where are the unlabeled buttons and what do they do",
            "tell me about this window", "fix my email", "scan the screen for malware",
        ]
        for p in phrases { XCTAssertEqual(ScreenIntentRouter.route(p), .other, p) }
    }

    func testNilAndMenuRequestsAreOther() {
        XCTAssertEqual(ScreenIntentRouter.route(nil), .other)
    }

    func testRoutingIsPureAndRepeatable() {
        for _ in 0..<3 { XCTAssertEqual(ScreenIntentRouter.route("fix this screen"), .fixScreen) }
    }
}
