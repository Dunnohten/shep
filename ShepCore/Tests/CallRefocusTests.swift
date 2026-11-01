import XCTest
@testable import ShepCore

/// Which calls bring the previously frontmost app back before Shep looks for a window. A VoiceOver user reaches the doghouse
/// indicator by bringing Shep itself to the front, so its press must not find "Shep itself" and go back to sleep.
final class CallRefocusTests: XCTestCase {
    func testDoghousePressRefocusesThePreviousApp() {
        XCTAssertTrue(CallSource.doghouse.refocusesPreviousApp)
    }

    func testOtherSourcesDoNotRefocusThroughTheCoordinator() {
        // Push-to-talk and "Hey Shep" refocus in their own call path (before listening starts); the menu, the shortcut and
        // the demo do not change the front app.
        for source in [CallSource.menu, .hotkey, .pushToTalk, .demo] {
            XCTAssertFalse(source.refocusesPreviousApp, source.rawValue)
        }
    }

    func testDoghousePressWithShepInFrontPicksTheLastOtherApp() {
        // The decision used for the press: Shep (100) in front, Transmission (200) was before it.
        XCTAssertEqual(WakeWordPolicy.pidToRefocus(frontmostPID: 100, ownPID: 100, lastOtherPID: 200), 200)
        // Another app already in front: nothing to do.
        XCTAssertNil(WakeWordPolicy.pidToRefocus(frontmostPID: 200, ownPID: 100, lastOtherPID: 300))
    }
}
