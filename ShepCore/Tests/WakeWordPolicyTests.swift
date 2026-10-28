import XCTest
@testable import ShepCore

final class WakeWordPolicyTests: XCTestCase {
    private let all = WakeWordConditions(enabled: true, authorized: true, onDeviceSupported: true,
                                         pushToTalkActive: false, conversationActive: false, asleep: false)

    func testListensOnlyWhenEverythingAllowsIt() {
        XCTAssertTrue(WakeWordPolicy.shouldListen(all))
        var c = all; c.enabled = false; XCTAssertFalse(WakeWordPolicy.shouldListen(c))
        c = all; c.authorized = false; XCTAssertFalse(WakeWordPolicy.shouldListen(c))
        c = all; c.onDeviceSupported = false; XCTAssertFalse(WakeWordPolicy.shouldListen(c))
        c = all; c.pushToTalkActive = true; XCTAssertFalse(WakeWordPolicy.shouldListen(c))
        c = all; c.conversationActive = true; XCTAssertFalse(WakeWordPolicy.shouldListen(c))
        c = all; c.asleep = true; XCTAssertFalse(WakeWordPolicy.shouldListen(c))
    }

    func testExactlyOneOfSixtyFourCombinationsListens() {
        var listening = 0
        for bits in 0..<64 {
            let c = WakeWordConditions(enabled: bits & 1 != 0, authorized: bits & 2 != 0, onDeviceSupported: bits & 4 != 0,
                                       pushToTalkActive: bits & 8 != 0, conversationActive: bits & 16 != 0, asleep: bits & 32 != 0)
            if WakeWordPolicy.shouldListen(c) { listening += 1 }
        }
        XCTAssertEqual(listening, 1)
    }

    func testTheTaskRestartsBeforeTheOneMinuteLimit() {
        XCTAssertEqual(WakeWordPolicy.restartAfterSeconds, 50)
        XCTAssertFalse(WakeWordPolicy.shouldRestartTask(runningFor: 0))
        XCTAssertFalse(WakeWordPolicy.shouldRestartTask(runningFor: 49.9))
        XCTAssertTrue(WakeWordPolicy.shouldRestartTask(runningFor: 50))
        XCTAssertTrue(WakeWordPolicy.shouldRestartTask(runningFor: 70))
    }

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(WakeWordPolicy.backoff(afterFailures: 1), 1)
        XCTAssertEqual(WakeWordPolicy.backoff(afterFailures: 2), 2)
        XCTAssertEqual(WakeWordPolicy.backoff(afterFailures: 3), 5)
        var last = 0.0
        for n in 1...20 {
            let b = WakeWordPolicy.backoff(afterFailures: n)
            XCTAssertGreaterThanOrEqual(b, last)
            XCTAssertLessThanOrEqual(b, 30)
            last = b
        }
        XCTAssertEqual(WakeWordPolicy.backoff(afterFailures: 1000), 30)
        XCTAssertEqual(WakeWordPolicy.backoff(afterFailures: 0), 1, "no failures yet still waits the first step")
    }

    func testUtteranceEndsOnSilence() {
        XCTAssertFalse(WakeWordPolicy.utteranceEnded(heardText: true, silentFor: 0.5))
        XCTAssertTrue(WakeWordPolicy.utteranceEnded(heardText: true, silentFor: WakeWordPolicy.utteranceSilenceSeconds))
        XCTAssertFalse(WakeWordPolicy.utteranceEnded(heardText: false, silentFor: WakeWordPolicy.utteranceSilenceSeconds))
        XCTAssertTrue(WakeWordPolicy.utteranceEnded(heardText: false, silentFor: WakeWordPolicy.noSpeechGiveUpSeconds))
        XCTAssertGreaterThan(WakeWordPolicy.noSpeechGiveUpSeconds, WakeWordPolicy.utteranceSilenceSeconds)
    }

    // MARK: indicator

    func testTheIconShowsWhenTheMicrophoneIsOpen() {
        let idle = StatusIconState.forMicrophone(open: false)
        let open = StatusIconState.forMicrophone(open: true)
        XCTAssertEqual(idle, StatusIconState(symbolName: "pawprint.fill", accessibilityDescription: "Shep"))
        XCTAssertNotEqual(open.symbolName, idle.symbolName)
        XCTAssertEqual(open.accessibilityDescription, "Listening for Hey Shep")
    }

    // MARK: log

    func testTheLogLinesAreFixedAndCarryNoTranscript() {
        XCTAssertEqual(WakeLog.matched, "[shep] wake: matched")
        XCTAssertEqual(WakeLog.notMatched, "[shep] wake: not matched")
        XCTAssertEqual(WakeLog.unavailable, "[shep] wake: unavailable (on-device recognition not supported)")
        XCTAssertEqual(WakeLog.listeningStarted, "[shep] wake: listening started")
        XCTAssertEqual(WakeLog.listeningStopped, "[shep] wake: listening stopped")
        for kind in WakeErrorKind.allCases {
            XCTAssertEqual(WakeLog.error(kind), "[shep] wake: error (\(kind.rawValue))")
        }
    }

    func testTheLogFormatterCannotTakeText() {
        // Every line comes from a closed set: constants, or an error kind from a closed enum. There is no entry point that
        // accepts a String, so a transcript cannot reach the log; this pins the set and that every line has the prefix.
        var lines = [WakeLog.matched, WakeLog.notMatched, WakeLog.listeningStarted, WakeLog.listeningStopped, WakeLog.unavailable,
                     WakeLog.handoffRequested, WakeLog.handoffConfirmed, WakeLog.handoffFailed, WakeLog.handoffAbandoned]
        lines += WakeErrorKind.allCases.map { WakeLog.error($0) }
        for line in lines {
            XCTAssertTrue(line.hasPrefix("[shep] wake: "), line)
            XCTAssertFalse(line.lowercased().contains("hey shep"), line)
            XCTAssertNil(line.range(of: #"["“”]"#, options: .regularExpression), "no quoted text: \(line)")
        }
        XCTAssertEqual(WakeErrorKind.allCases.count, 4)
    }

    func testAVoiceCallFromShepsOwnWindowGoesBackToTheAppBeforeIt() {
        // The 2026-10-28 10:37 live run: Shep Settings was in front when "Hey Shep" matched, so there was no window to sit on.
        XCTAssertEqual(WakeWordPolicy.pidToRefocus(frontmostPID: 100, ownPID: 100, lastOtherPID: 200), 200)
    }

    func testNothingIsRefocusedWhenAnotherAppIsInFront() {
        XCTAssertNil(WakeWordPolicy.pidToRefocus(frontmostPID: 200, ownPID: 100, lastOtherPID: 300))
        XCTAssertNil(WakeWordPolicy.pidToRefocus(frontmostPID: 200, ownPID: 100, lastOtherPID: nil))
    }

    func testNothingIsRefocusedWithoutAnEarlierAppThatIsNotShep() {
        XCTAssertNil(WakeWordPolicy.pidToRefocus(frontmostPID: 100, ownPID: 100, lastOtherPID: nil))
        XCTAssertNil(WakeWordPolicy.pidToRefocus(frontmostPID: 100, ownPID: 100, lastOtherPID: 100))
        XCTAssertNil(WakeWordPolicy.pidToRefocus(frontmostPID: nil, ownPID: 100, lastOtherPID: 200))
    }
}
