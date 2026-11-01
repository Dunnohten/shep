import XCTest
@testable import ShepCore

/// The recording aid that feeds a voice FILE through a local whisper-cli: off unless a Debug build gets all three paths.
final class DemoVoiceTests: XCTestCase {
    private let env = [DemoVoiceConfig.fileKey: "/tmp/v.wav", DemoVoiceConfig.whisperKey: "/opt/w/whisper-cli",
                       DemoVoiceConfig.modelKey: "/opt/w/model.bin"]
    private let exists: (String) -> Bool = { _ in true }

    func testOffByDefault() {
        XCTAssertNil(DemoVoiceConfig.from(environment: [:], debugBuild: true, fileExists: exists))
        XCTAssertNil(DemoVoiceConfig.from(environment: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SHEP_DEMO_") },
                                          debugBuild: true, fileExists: exists))
    }

    func testNeverInARelease() {
        XCTAssertNil(DemoVoiceConfig.from(environment: env, debugBuild: false, fileExists: exists))
    }

    func testAllThreeAbsoluteExistingPathsAreNeeded() {
        XCTAssertEqual(DemoVoiceConfig.from(environment: env, debugBuild: true, fileExists: exists),
                       DemoVoiceConfig(audioPath: "/tmp/v.wav", whisperPath: "/opt/w/whisper-cli", modelPath: "/opt/w/model.bin"))
        for key in [DemoVoiceConfig.fileKey, DemoVoiceConfig.whisperKey, DemoVoiceConfig.modelKey] {
            var e = env; e[key] = nil
            XCTAssertNil(DemoVoiceConfig.from(environment: e, debugBuild: true, fileExists: exists), key)
            e[key] = "relative/path"
            XCTAssertNil(DemoVoiceConfig.from(environment: e, debugBuild: true, fileExists: exists), key)
        }
        XCTAssertNil(DemoVoiceConfig.from(environment: env, debugBuild: true, fileExists: { $0 != "/opt/w/model.bin" }))
    }

    func testWhisperArgumentsAskForOneWordPerLine() {
        let a = DemoVoiceConfig(audioPath: "/tmp/v.wav", whisperPath: "/w", modelPath: "/m").whisperArguments
        XCTAssertEqual(a, ["-m", "/m", "-f", "/tmp/v.wav", "-l", "en", "-ml", "1", "-sow", "-np"])
    }

    func testParsesWhisperLines() {
        let out = """

        [00:00:00.000 --> 00:00:00.420]   Shep,
        [00:00:00.420 --> 00:00:00.700]   turn
        [00:00:00.700 --> 00:00:00.810]   on
        [00:00:00.810 --> 00:00:00.950]   the
        [00:00:00.950 --> 00:00:01.300]   speed
        [00:00:01.300 --> 00:00:01.900]   limit.
        [00:00:01.900 --> 00:00:02.000]   [BLANK_AUDIO]
        not a result line
        """
        let w = DemoVoiceTranscript.parse(out)
        XCTAssertEqual(w.map(\.text), ["Shep,", "turn", "on", "the", "speed", "limit."])
        XCTAssertEqual(w.map(\.ms), [0, 420, 700, 810, 950, 1300])
        XCTAssertEqual(DemoVoiceTranscript.text(w), "Shep, turn on the speed limit.")
        XCTAssertEqual(DemoVoiceTranscript.text(w, upTo: 750), "Shep, turn on")
        XCTAssertEqual(DemoVoiceTranscript.text(w, upTo: -1), "")
    }

    func testTimestamps() {
        XCTAssertEqual(DemoVoiceTranscript.milliseconds("01:02:03.045"), 3_723_045)
        XCTAssertNil(DemoVoiceTranscript.milliseconds("02:03.045"))
        XCTAssertNil(DemoVoiceTranscript.milliseconds("00:00:01.5"))
    }

    func testPunctuationTokensJoin() {
        let w = [TimedWord(ms: 0, text: "Shep"), TimedWord(ms: 10, text: ","), TimedWord(ms: 20, text: "go"), TimedWord(ms: 30, text: ".")]
        XCTAssertEqual(DemoVoiceTranscript.text(w), "Shep, go.")
    }
}

/// The recording aid's final text can come later than the microphone's: the session's wait after the key comes up is longer for it.
final class DemoVoiceSessionWaitTests: XCTestCase {
    func testTheDefaultWaitIsUnchanged() {
        var s = VoiceSession()
        _ = s.handle(.press(microphone: .granted, speech: .granted))
        XCTAssertTrue(s.handle(.release).contains(.armTimeout(VoiceTimings.finalWaitSeconds)))
    }

    func testTheDemoWaitIsUsedWhenSet() {
        var s = VoiceSession()
        s.finalWaitSeconds = VoiceTimings.demoFinalWaitSeconds
        _ = s.handle(.press(microphone: .granted, speech: .granted))
        let effects = s.handle(.release)
        XCTAssertTrue(effects.contains(.armTimeout(VoiceTimings.demoFinalWaitSeconds)))
        XCTAssertFalse(effects.contains(.armTimeout(VoiceTimings.finalWaitSeconds)))
        // A final that arrives late (well past the microphone's 2 s) is still the request.
        XCTAssertTrue(s.handle(.final("hey Shep, turn on the speed limit")).contains(.submit("hey Shep, turn on the speed limit")))
    }

    func testTheDemoWaitCoversAFileAndATranscription() {
        XCTAssertGreaterThanOrEqual(VoiceTimings.demoFinalWaitSeconds, 10)
        XCTAssertLessThan(VoiceTimings.demoFinalWaitSeconds, VoiceTimings.maxHoldSeconds)
    }
}

final class DemoVoiceLimitsTests: XCTestCase {
    func testTheAidAlwaysAnswersInsideTheSessionWait() {
        // The final text comes when the file has played and whisper-cli is done; both are bounded from the start.
        XCTAssertLessThanOrEqual(DemoVoiceLimits.maxFileSeconds, DemoVoiceLimits.whisperDeadlineSeconds)
        XCTAssertLessThan(DemoVoiceLimits.whisperDeadlineSeconds, VoiceTimings.demoFinalWaitSeconds)
    }

    func testFileLength() {
        XCTAssertTrue(DemoVoiceLimits.fileAccepted(seconds: 4.5))
        XCTAssertTrue(DemoVoiceLimits.fileAccepted(seconds: DemoVoiceLimits.maxFileSeconds))
        XCTAssertFalse(DemoVoiceLimits.fileAccepted(seconds: DemoVoiceLimits.maxFileSeconds + 0.1))
        XCTAssertFalse(DemoVoiceLimits.fileAccepted(seconds: 0))
        XCTAssertFalse(DemoVoiceLimits.fileAccepted(seconds: .nan))
    }
}
