import XCTest
@testable import ShepCore

final class HotKeySpecTests: XCTestCase {
    func testDefaultIsNotASystemShortcutAndIsValid() {
        XCTAssertEqual(HotKeySpec.call.keyCode, 49)
        XCTAssertEqual(HotKeySpec.call.modifiers, 0x1300)   // control + shift + command
        XCTAssertNil(HotKeySpec.call.systemConflict)
        XCTAssertTrue(HotKeySpec.call.isValid)
    }

    func testTheOriginalChoiceIsFlaggedWithItsConflicts() {
        let original = HotKeySpec.presets.first { $0.modifiers == HotKeyModifier.control | HotKeyModifier.option }
        XCTAssertNotNil(original)
        XCTAssertTrue(original?.systemConflict?.contains("VoiceOver") ?? false)
        XCTAssertTrue(original?.systemConflict?.contains("input source") ?? false)
        XCTAssertEqual(HotKeySpec.presets.first, HotKeySpec.call)
        // Only the first preset is conflict-free in the known list or at least the default is.
        XCTAssertNil(HotKeySpec.presets.first?.systemConflict)
    }

    func testKnownSystemShortcutsAreFlagged() {
        XCTAssertEqual(HotKeySpec(keyCode: 49, modifiers: HotKeyModifier.command, name: "x").systemConflict, "Spotlight")
        XCTAssertEqual(HotKeySpec(keyCode: 49, modifiers: HotKeyModifier.control | HotKeyModifier.command, name: "x").systemConflict, "emoji and symbols")
    }

    func testAShortcutNeedsAModifier() {
        XCTAssertFalse(HotKeySpec(keyCode: 49, modifiers: 0, name: "bare").isValid)
        XCTAssertTrue(HotKeySpec(keyCode: 1, modifiers: HotKeyModifier.shift, name: "s").isValid)
    }

    func testModifierMasksAreCarbons() {
        XCTAssertEqual(HotKeyModifier.command, 256)
        XCTAssertEqual(HotKeyModifier.shift, 512)
        XCTAssertEqual(HotKeyModifier.option, 2048)
        XCTAssertEqual(HotKeyModifier.control, 4096)
    }
}

final class PushToTalkTests: XCTestCase {
    func testRightOptionIsTheDefaultAndReadsItsOwnBit() {
        XCTAssertEqual(PushToTalkKey.default, .rightOption)
        XCTAssertEqual(PushToTalkKey.rightOption.keyCode, 61)
        XCTAssertTrue(PushToTalkKey.rightOption.isDown(rawFlags: 0x80140))      // option (0x80000) + right-option device bit
        XCTAssertFalse(PushToTalkKey.rightOption.isDown(rawFlags: 0x80120))     // left option's device bit only
        XCTAssertFalse(PushToTalkKey.rightOption.isDown(rawFlags: 0))
        XCTAssertEqual(Set(PushToTalkKey.allCases.map(\.keyCode)).count, PushToTalkKey.allCases.count)
    }

    private let down: UInt = 0x80140
    private let up: UInt = 0

    func testAHoldBeginsAfterTheThresholdAndEndsOnRelease() {
        var d = PushToTalkDetector()
        XCTAssertNil(d.flagsChanged(keyCode: 61, rawFlags: down, at: 10))
        XCTAssertTrue(d.isHeld)
        XCTAssertEqual(d.nextTick ?? 0, 10 + PushToTalkDetector.holdSeconds, accuracy: 1e-9)
        XCTAssertNil(d.tick(at: 10.1))
        XCTAssertEqual(d.tick(at: 10.3), .began)
        XCTAssertTrue(d.isListening)
        XCTAssertNil(d.tick(at: 10.4))   // only once
        XCTAssertEqual(d.nextTick ?? 0, 10 + PushToTalkDetector.maxListenSeconds, accuracy: 1e-9, "while listening only the listening limit is pending")
        XCTAssertEqual(d.flagsChanged(keyCode: 61, rawFlags: up, at: 12), .ended)
        XCTAssertFalse(d.isHeld)
        XCTAssertFalse(d.isListening)
    }

    func testATapIsNotACall() {
        var d = PushToTalkDetector()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 0)
        XCTAssertNil(d.flagsChanged(keyCode: 61, rawFlags: up, at: 0.1))
        XCTAssertNil(d.tick(at: 1))   // nothing pending any more
    }

    func testTypingAnOptionCharacterIsNotACall() {
        var d = PushToTalkDetector()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 0)
        XCTAssertNil(d.keyDown(at: 0.1))
        XCTAssertNil(d.tick(at: 0.5))
        XCTAssertNil(d.nextTick)
        XCTAssertNil(d.flagsChanged(keyCode: 61, rawFlags: up, at: 0.6))
    }

    func testAKeyAfterTheHoldBeganCancels() {
        var d = PushToTalkDetector()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 0)
        XCTAssertEqual(d.tick(at: 0.3), .began)
        XCTAssertEqual(d.keyDown(at: 0.5), .cancelled)
        XCTAssertNil(d.flagsChanged(keyCode: 61, rawFlags: up, at: 1))
        XCTAssertFalse(d.isListening)
    }

    func testOtherModifiersAndKeysWithoutAPressAreIgnored() {
        var d = PushToTalkDetector()
        XCTAssertNil(d.flagsChanged(keyCode: 58, rawFlags: 0x80020, at: 0))   // left option
        XCTAssertNil(d.keyDown(at: 1))
        XCTAssertNil(d.tick(at: 2))
        XCTAssertFalse(d.isHeld)
    }

    func testAnotherChosenKey() {
        var d = PushToTalkDetector(key: .rightCommand)
        XCTAssertNil(d.flagsChanged(keyCode: 61, rawFlags: down, at: 0))
        XCTAssertFalse(d.isHeld)
        XCTAssertNil(d.flagsChanged(keyCode: 54, rawFlags: 0x100110, at: 0))
        XCTAssertTrue(d.isHeld)
        d.reset()
        XCTAssertFalse(d.isHeld)
    }

    // MARK: chords and lost input

    /// (key code, raw flags with that modifier down) for the modifiers that are not any of the three talk keys, plus the twins.
    private let otherModifiers: [(code: UInt16, flags: UInt)] = [
        (55, 0x100008), (56, 0x20002), (60, 0x20004), (59, 0x40001), (58, 0x80020), (63, 0x800000),
    ]

    func testAnotherModifierBeforeTheHoldTimeSpoilsThePress() {
        for key in PushToTalkKey.allCases {
            for other in otherModifiers where other.code != key.keyCode {
                var d = PushToTalkDetector(key: key)
                _ = d.flagsChanged(keyCode: key.keyCode, rawFlags: key.deviceMask | key.genericMask, at: 0)
                XCTAssertNil(d.flagsChanged(keyCode: other.code, rawFlags: key.deviceMask | other.flags, at: 0.1), "\(key) + \(other.code)")
                XCTAssertNil(d.tick(at: 1), "\(key) + \(other.code): a chord never begins a call")
                XCTAssertNil(d.nextTick)
                XCTAssertNil(d.flagsChanged(keyCode: key.keyCode, rawFlags: 0, at: 1.1))
                XCTAssertFalse(d.isHeld)
            }
        }
    }

    func testAnotherModifierAfterTheCallBeganCancelsIt() {
        for key in PushToTalkKey.allCases {
            for other in otherModifiers where other.code != key.keyCode {
                var d = PushToTalkDetector(key: key)
                _ = d.flagsChanged(keyCode: key.keyCode, rawFlags: key.deviceMask | key.genericMask, at: 0)
                XCTAssertEqual(d.tick(at: 0.3), .began)
                XCTAssertEqual(d.flagsChanged(keyCode: other.code, rawFlags: key.deviceMask | other.flags, at: 0.5), .cancelled, "\(key) + \(other.code)")
                XCTAssertFalse(d.isListening); XCTAssertFalse(d.isHeld)
                XCTAssertNil(d.flagsChanged(keyCode: key.keyCode, rawFlags: 0, at: 1), "the release after a cancel ends nothing")
            }
        }
    }

    func testLeftOptionPressedAndReleasedWhileHoldingRightOptionSpoilsIt() {
        var d = PushToTalkDetector()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 0)
        XCTAssertNil(d.flagsChanged(keyCode: 58, rawFlags: down | 0x20, at: 0.05))
        XCTAssertNil(d.flagsChanged(keyCode: 58, rawFlags: down, at: 0.1))
        XCTAssertNil(d.tick(at: 0.5))
    }

    func testAPressThatStartsWithAnotherModifierAlreadyDownIsNotACall() {
        for key in PushToTalkKey.allCases {
            for other in otherModifiers where other.code != key.keyCode && other.code != 63 {   // the fn bit is not a chord
                var d = PushToTalkDetector(key: key)
                XCTAssertNil(d.flagsChanged(keyCode: key.keyCode, rawFlags: key.deviceMask | key.genericMask | other.flags, at: 0), "\(key) + \(other.code)")
                XCTAssertTrue(d.isHeld)
                XCTAssertNil(d.tick(at: 1), "\(key) + \(other.code)")
            }
        }
    }

    func testTheTalkKeyAloneStillBeginsForEveryKey() {
        for key in PushToTalkKey.allCases {
            var d = PushToTalkDetector(key: key)
            _ = d.flagsChanged(keyCode: key.keyCode, rawFlags: key.deviceMask | key.genericMask, at: 0)
            XCTAssertEqual(d.tick(at: 0.3), .began, "\(key)")
            XCTAssertEqual(d.flagsChanged(keyCode: key.keyCode, rawFlags: 0, at: 1), .ended)
        }
    }

    func testOtherModifiersAreDetectedFromDeviceAndGenericBits() {
        let key = PushToTalkKey.rightOption
        XCTAssertFalse(key.otherModifiersDown(rawFlags: 0x80140))
        XCTAssertTrue(key.otherModifiersDown(rawFlags: 0x80140 | 0x20), "the left option")
        XCTAssertTrue(key.otherModifiersDown(rawFlags: 0x80140 | 0x100008), "left command")
        XCTAssertTrue(key.otherModifiersDown(rawFlags: 0x80140 | 0x20000), "a generic shift bit alone")
        XCTAssertFalse(key.otherModifiersDown(rawFlags: 0x80140 | 0x10000), "caps lock is not a chord")
    }

    func testAnInterruptionCancelsAListeningCallAndForgetsAPendingPress() {
        var d = PushToTalkDetector()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 0)
        XCTAssertEqual(d.tick(at: 0.3), .began)
        XCTAssertEqual(d.interrupted(), .cancelled)
        XCTAssertFalse(d.isHeld); XCTAssertFalse(d.isListening)
        XCTAssertNil(d.flagsChanged(keyCode: 61, rawFlags: up, at: 5), "the late key-up does nothing")

        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 10)
        XCTAssertNil(d.interrupted(), "a press that had not begun is just forgotten")
        XCTAssertFalse(d.isHeld)
        XCTAssertNil(d.tick(at: 11))
    }

    func testALostKeyUpIsFoundByComparingWithTheRealModifierState() {
        var d = PushToTalkDetector()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 0)
        XCTAssertNil(d.reconcile(rawFlags: down), "still down: nothing to do")
        XCTAssertNil(d.reconcile(rawFlags: 0x80000), "a polled state with only the generic option bit still counts as down")
        XCTAssertEqual(d.tick(at: 0.3), .began)
        XCTAssertEqual(d.reconcile(rawFlags: 0), .cancelled, "the key is up but we never heard it")
        XCTAssertFalse(d.isListening)
        XCTAssertNil(d.reconcile(rawFlags: 0), "idle: nothing")
    }

    func testAListeningCallEndsAtTheLimitWhenTheKeyUpNeverComes() {
        var d = PushToTalkDetector()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 0)
        XCTAssertEqual(d.tick(at: 0.3), .began)
        XCTAssertNil(d.tick(at: PushToTalkDetector.maxListenSeconds - 1))
        XCTAssertEqual(d.tick(at: PushToTalkDetector.maxListenSeconds), .cancelled)
        XCTAssertFalse(d.isHeld); XCTAssertFalse(d.isListening)
        XCTAssertNil(d.nextTick)
    }

    func testANewPressAfterALostReleaseStartsClean() {
        var d = PushToTalkDetector()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 0)
        _ = d.tick(at: 0.3)
        _ = d.interrupted()
        _ = d.flagsChanged(keyCode: 61, rawFlags: down, at: 20)
        XCTAssertEqual(d.tick(at: 20.3), .began)
    }
}
