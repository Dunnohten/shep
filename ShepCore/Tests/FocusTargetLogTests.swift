import XCTest
@testable import ShepCore

/// Code review F6: the target line carries the sampled VoiceOver flag, and when the `voiceover` source gave no window, the fixed
/// reason per candidate. A change of any of them (a VoiceOver toggle included) logs again; repeats do not.
final class FocusTargetLogTests: XCTestCase {
    private let fellThrough = [FocusAttemptFailure(.system, .foreignOwner), FocusAttemptFailure(.app, .windowUnavailable)]

    func testTheLineCarriesTheSampledFlag() {
        XCTAssertEqual(FocusTargetPolicy.diagnosticLine(source: .keyboard, voiceOverRunning: false, voiceOverFailures: []),
                       "[shep] target: keyboard (voiceover=off)")
        XCTAssertEqual(FocusTargetPolicy.diagnosticLine(source: .voiceover, voiceOverRunning: true, voiceOverFailures: []),
                       "[shep] target: voiceover (voiceover=on)")
        XCTAssertEqual(FocusTargetPolicy.diagnosticLine(source: nil, voiceOverRunning: false, voiceOverFailures: []),
                       "[shep] target: none (voiceover=off)")
    }

    func testAFallThroughToTheKeyboardSaysWhyPerCandidate() {
        XCTAssertEqual(FocusTargetPolicy.diagnosticLine(source: .keyboard, voiceOverRunning: true, voiceOverFailures: fellThrough),
                       "[shep] target: keyboard (voiceover=on; system=foreign-owner app=window-unavailable)")
        XCTAssertEqual(FocusTargetPolicy.diagnosticLine(source: .voiceover, voiceOverRunning: true,
                                                        voiceOverFailures: [FocusAttemptFailure(.system, .focusedElementUnavailable)]),
                       "[shep] target: voiceover (voiceover=on; system=focused-element-unavailable)", "answered by the app's own element")
    }

    func testWithVoiceOverOffNoFailureIsShown() {
        XCTAssertEqual(FocusTargetPolicy.diagnosticLine(source: .keyboard, voiceOverRunning: false, voiceOverFailures: fellThrough),
                       "[shep] target: keyboard (voiceover=off)")
    }

    func testTheLineKeepsTheOldPrefix() {
        for source in [FocusSource.voiceover, .keyboard, .mouse, nil] {
            XCTAssertTrue(FocusTargetPolicy.diagnosticLine(source: source, voiceOverRunning: true, voiceOverFailures: fellThrough)
                .hasPrefix(FocusTargetPolicy.logLine(source) + " ("))
        }
    }

    func testEveryLineIsBuiltFromFixedTokens() throws {
        let shape = try NSRegularExpression(pattern: "^\\[shep\\] target: (voiceover|keyboard|mouse|none) \\(voiceover=(on|off)(; (system|app)=[a-z-]+( (system|app)=[a-z-]+)?)?\\)$")
        for source in [FocusSource.voiceover, .keyboard, .mouse, nil] {
            for on in [true, false] {
                for a in FocusElementFailure.allCases {
                    for b in FocusElementFailure.allCases {
                        let line = FocusTargetPolicy.diagnosticLine(source: source, voiceOverRunning: on,
                                                                    voiceOverFailures: [FocusAttemptFailure(.system, a), FocusAttemptFailure(.app, b)])
                        XCTAssertEqual(shape.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)), 1, line)
                    }
                }
            }
        }
    }

    func testAToggleOfVoiceOverLogsAgainWithTheSameSource() {
        var log = FocusTargetLogState()
        XCTAssertEqual(log.record(source: .keyboard, voiceOverRunning: false, voiceOverFailures: []), "[shep] target: keyboard (voiceover=off)")
        XCTAssertNil(log.record(source: .keyboard, voiceOverRunning: false, voiceOverFailures: []), "repeats are quiet")
        XCTAssertEqual(log.record(source: .keyboard, voiceOverRunning: true, voiceOverFailures: fellThrough),
                       "[shep] target: keyboard (voiceover=on; system=foreign-owner app=window-unavailable)", "the 11:48 first line, now readable")
        XCTAssertEqual(log.record(source: .voiceover, voiceOverRunning: true, voiceOverFailures: []), "[shep] target: voiceover (voiceover=on)")
        XCTAssertEqual(log.record(source: .voiceover, voiceOverRunning: false, voiceOverFailures: []), "[shep] target: voiceover (voiceover=off)",
                       "a stale source after VoiceOver went off shows the flag that was sampled")
    }

    func testAChangedReasonLogsAgain() {
        var log = FocusTargetLogState()
        _ = log.record(source: .keyboard, voiceOverRunning: true, voiceOverFailures: fellThrough)
        XCTAssertNotNil(log.record(source: .keyboard, voiceOverRunning: true, voiceOverFailures: [FocusAttemptFailure(.system, .windowUnavailable),
                                                                                                    FocusAttemptFailure(.app, .windowUnavailable)]))
    }

    func testAResetLogsTheNextSampleEvenIfUnchanged() {
        var log = FocusTargetLogState()
        _ = log.record(source: .mouse, voiceOverRunning: false, voiceOverFailures: [])
        log.reset()
        XCTAssertEqual(log.record(source: .mouse, voiceOverRunning: false, voiceOverFailures: []), "[shep] target: mouse (voiceover=off)")
    }
}
