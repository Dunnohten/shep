import CryptoKit
import XCTest
@testable import ShepCore

/// The finish bark is one recorded bark (CC0, see NOTICE), stored in the source, played at a capped, scaled level.
final class BarkSoundTests: XCTestCase {
    func testTheStoredWAVIsTheOneInNOTICE() {
        let hex = SHA256.hash(data: BarkSound.wav).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "1ab91f4eb6d4fbbf7eb43079bea2f49b106e2186662a4dad790328596bcf50cc")
    }

    func testItDecodesToOneShortBark() {
        XCTAssertEqual(BarkSound.unitSamples.count, 5733)
        XCTAssertEqual(BarkSound.duration, 0.26, accuracy: 0.001)
        XCTAssertLessThan(BarkSound.duration, 0.5)   // short: one bark, not a fit of barking
        let peak = BarkSound.unitSamples.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 0.8)
        XCTAssertLessThanOrEqual(peak, 1)
    }

    func testVolumeScalesThePeakUpToTheCap() {
        func peak(_ v: Double) -> Float { BarkSound.samples(volume: v).reduce(Float(0)) { max($0, abs($1)) } }
        XCTAssertEqual(peak(1), BarkSound.maxPeak, accuracy: 0.0001)
        XCTAssertEqual(peak(0.5), BarkSound.maxPeak * 0.5, accuracy: 0.0001)
        XCTAssertEqual(peak(7), BarkSound.maxPeak, accuracy: 0.0001)   // clamped
        XCTAssertEqual(peak(0), 0)
        XCTAssertEqual(peak(.nan), 0)
        XCTAssertEqual(BarkSound.samples(volume: 0.6).count, BarkSound.unitSamples.count)
    }

    func testTheDecoderRefusesWhatItCannotRead() {
        XCTAssertEqual(BarkSound.decodePCM16(Data()), [])
        XCTAssertEqual(BarkSound.decodePCM16(Data("RIFF....WAVEjunk".utf8)), [])
        // Stereo 16-bit is not taken.
        var stereo = BarkSound.wav
        stereo[22] = 2
        XCTAssertEqual(BarkSound.decodePCM16(stereo), [])
        // A data chunk that claims more than the file has is not read past the end.
        var short = BarkSound.wav
        short.removeLast(100)
        XCTAssertEqual(BarkSound.decodePCM16(short), [])
    }

    func testTheExportedWAVRoundTrips() {
        let samples = BarkSound.samples(volume: 1)
        let wav = WavWriter.data(samples: samples, sampleRate: BarkSound.sampleRate)
        let back = BarkSound.decodePCM16(wav)
        XCTAssertEqual(back.count, samples.count)
    }
}

final class BarkPolicyTests: XCTestCase {
    func testOnByDefaultAtTheSettingsVolume() {
        let d = ShepSettings.defaults
        XCTAssertTrue(d.barkWhenDone)
        XCTAssertEqual(BarkPolicy.volume(barkWhenDone: d.barkWhenDone, barkVolume: d.barkVolume, speakReplies: d.speakReplies, systemSoundEffects: true),
                       ShepSettings.defaultBarkVolume)
    }

    func testTheSwitchTurnsItOff() {
        XCTAssertNil(BarkPolicy.volume(barkWhenDone: false, barkVolume: 1, speakReplies: true, systemSoundEffects: true))
    }

    func testNoInterfaceSoundsMeansNoBark() {
        XCTAssertNil(BarkPolicy.volume(barkWhenDone: true, barkVolume: 1, speakReplies: true, systemSoundEffects: false))
    }

    func testRepliesOffMakesItQuieter() {
        XCTAssertEqual(BarkPolicy.volume(barkWhenDone: true, barkVolume: 0.8, speakReplies: false, systemSoundEffects: true)!, 0.4, accuracy: 1e-9)
    }

    func testZeroOrNonsenseVolumeIsNoBark() {
        XCTAssertNil(BarkPolicy.volume(barkWhenDone: true, barkVolume: 0, speakReplies: true, systemSoundEffects: true))
        XCTAssertNil(BarkPolicy.volume(barkWhenDone: true, barkVolume: .nan, speakReplies: true, systemSoundEffects: true))
        XCTAssertEqual(BarkPolicy.volume(barkWhenDone: true, barkVolume: 3, speakReplies: true, systemSoundEffects: true), 1)
    }

    func testTheSystemSettingReadsAbsentAsOn() {
        XCTAssertTrue(BarkPolicy.systemSoundEffects(globalValue: nil))
        XCTAssertTrue(BarkPolicy.systemSoundEffects(globalValue: NSNumber(value: 1)))
        XCTAssertFalse(BarkPolicy.systemSoundEffects(globalValue: NSNumber(value: 0)))
        XCTAssertFalse(BarkPolicy.systemSoundEffects(globalValue: false))
    }

    func testDoneIsShortWhenSpoken() {
        XCTAssertEqual(Brief.done, "Done.")
    }
}

final class FinishBeatReplyTests: XCTestCase {
    func testTheBarkWaitsForTheSpokenDone() {
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: false, replySpeaking: true, replyFinishedAt: 0.7), 0.7)
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: false, replySpeaking: true), FinishBeat.replyTimeout)   // not over yet: the timeout
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: false, replySpeaking: true, replyFinishedAt: 9), FinishBeat.replyTimeout)
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: false, replySpeaking: true, replyFinishedAt: 0), FinishBeat.woofDelay)
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: false, replySpeaking: false, replyFinishedAt: 0.7), FinishBeat.woofDelay)
    }

    func testVoiceOverRulesWhenBothAreSet() {
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: true, voiceOverFinishedAt: 0.5, replySpeaking: true, replyFinishedAt: 2), 0.5)
    }

    func testStepsFollowTheReply() {
        let s = FinishBeat.steps(reduceMotion: false, barkEnabled: true, voiceOverRunning: false, replySpeaking: true, replyFinishedAt: 0.9)
        XCTAssertEqual(s.first { $0.action == .woof }?.at, 0.9)
        XCTAssertEqual(s.first { $0.action == .hop }?.at, 0.9)
        XCTAssertEqual(s.last?.action, .goHome)
        XCTAssertGreaterThanOrEqual(s.last!.at, 0.9 + max(FinishBeat.hopSeconds, BarkSound.duration) + FinishBeat.holdAfterWoof - 0.0001)
    }

    func testReduceMotionWithoutBarkStillGoesHome() {
        let s = FinishBeat.steps(reduceMotion: true, barkEnabled: false, voiceOverRunning: false)
        XCTAssertEqual(s.map(\.action), [.earsUp, .announceDone, .goHome])
        XCTAssertEqual(s.last!.at, FinishBeat.woofDelay + FinishBeat.holdAfterWoof, accuracy: 1e-9)
    }
}

/// The approval card's ordinary case carries no "Shep asks before every action" line; Setup explains that once.
final class ApprovalReasonTests: XCTestCase {
    private let button = Control(role: "AXButton", title: "Save", actions: ["AXPress"])

    func testThePlainCaseHasNoReasonLine() {
        let action = ProposedAction(control: button, kind: .axPress, bundleID: "com.apple.TextEdit")
        guard case .required(let why) = ApprovalPolicy.requirement(for: action) else { return XCTFail("still asks") }
        XCTAssertEqual(why, "")
        let card = ApprovalRequest(action: action, reason: why).cardText
        XCTAssertFalse(card.contains("\n"))
        XCTAssertFalse(card.lowercased().contains("asks"))
        XCTAssertTrue(card.hasSuffix("?"))
    }

    func testACommandRunnerSaysWhyWithoutTheAsksLine() {
        let action = ProposedAction(control: button, kind: .axPress, bundleID: "com.apple.Terminal")
        guard case .required(let why) = ApprovalPolicy.requirement(for: action) else { return XCTFail("still asks") }
        XCTAssertEqual(why, "This app can run commands.")
    }

    func testNoReasonAnywhereSaysShepAsks() {
        let kinds: [ProposedAction] = [
            ProposedAction(control: button, kind: .axPress, bundleID: "com.apple.TextEdit"),
            ProposedAction(control: button, kind: .clickPoint, bundleID: "com.apple.TextEdit"),
            ProposedAction(control: button, kind: .axPress, bundleID: "com.apple.Terminal"),
        ]
        for a in kinds {
            for after in [false, true] {
                if case .required(let why) = ApprovalPolicy.requirement(for: a, afterAXFailure: after) {
                    XCTAssertFalse(why.lowercased().contains("asks"), why)
                }
            }
        }
    }
}

final class OnboardingCopyTests: XCTestCase {
    func testSetupExplainsTheApprovalOnce() {
        XCTAssertTrue(OnboardingCopy.asksFirst.hasPrefix("Shep asks before every action."))
        XCTAssertTrue(OnboardingCopy.asksFirst.contains("Approve"))
        XCTAssertTrue(OnboardingCopy.asksFirst.contains("Cancel"))
    }
}
