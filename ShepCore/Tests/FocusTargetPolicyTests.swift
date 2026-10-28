import XCTest
@testable import ShepCore

final class FocusTargetPolicyTests: XCTestCase {
    func testVoiceOverFocusComesFirstWhenVoiceOverIsRunning() {
        XCTAssertEqual(FocusTargetPolicy.order(voiceOverRunning: true), [.voiceover, .keyboard, .mouse])
        XCTAssertEqual(FocusTargetPolicy.choose(voiceOverRunning: true) { _ in true }, .voiceover)
    }

    func testWithoutVoiceOverTheKeyboardFocusComesFirstAndVoiceOverIsNeverAsked() {
        XCTAssertEqual(FocusTargetPolicy.order(voiceOverRunning: false), [.keyboard, .mouse])
        var asked: [FocusSource] = []
        let s = FocusTargetPolicy.choose(voiceOverRunning: false) { asked.append($0); return true }
        XCTAssertEqual(s, .keyboard)
        XCTAssertEqual(asked, [.keyboard])
    }

    func testTheMouseIsOnlyTheLastFallback() {
        XCTAssertEqual(FocusTargetPolicy.choose(voiceOverRunning: true) { $0 != .voiceover }, .keyboard)
        XCTAssertEqual(FocusTargetPolicy.choose(voiceOverRunning: true) { $0 == .mouse }, .mouse)
        XCTAssertEqual(FocusTargetPolicy.choose(voiceOverRunning: false) { $0 == .mouse }, .mouse)
        XCTAssertNil(FocusTargetPolicy.choose(voiceOverRunning: true) { _ in false })
        // A VoiceOver window is never chosen when VoiceOver is off, even if one were reported.
        XCTAssertNil(FocusTargetPolicy.choose(voiceOverRunning: false) { $0 == .voiceover })
    }

    func testTheMouseFallbackPicksTheFrontmostWindowUnderThePointer() {
        let frames: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 100), nil, CGRect(x: 50, y: 50, width: 200, height: 200)]
        XCTAssertEqual(FocusTargetPolicy.windowIndex(containing: CGPoint(x: 60, y: 60), frames: frames), 0)
        XCTAssertEqual(FocusTargetPolicy.windowIndex(containing: CGPoint(x: 200, y: 200), frames: frames), 2)
        XCTAssertNil(FocusTargetPolicy.windowIndex(containing: CGPoint(x: 500, y: 500), frames: frames))
        XCTAssertNil(FocusTargetPolicy.windowIndex(containing: .zero, frames: []))
    }

    func testTheLogLineNamesOnlyTheSource() {
        XCTAssertEqual(FocusTargetPolicy.logLine(.voiceover), "[shep] target: voiceover")
        XCTAssertEqual(FocusTargetPolicy.logLine(.keyboard), "[shep] target: keyboard")
        XCTAssertEqual(FocusTargetPolicy.logLine(.mouse), "[shep] target: mouse")
        XCTAssertEqual(FocusTargetPolicy.logLine(nil), "[shep] target: none")
    }

    func testAnObservationCarriesItsSource() {
        var a = WindowObservation(pid: 1, bundleID: nil, axFrame: .zero)
        XCTAssertNil(a.source)
        let b = a
        a.source = .voiceover
        XCTAssertNotEqual(a, b)
    }
}
