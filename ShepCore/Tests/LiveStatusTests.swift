import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of ad80789 (R3): the shell classifier reads a structured status file, not the human log, and
// the request text cannot forge a second log line.

final class LiveStatusEncoderTests: XCTestCase {
    let nonce = "0123456789abcdef0123456789abcdef"

    func testNonceCharsetAndLength() {
        XCTAssertTrue(LiveStatus.isValidNonce("0123456789abcdef"))
        XCTAssertTrue(LiveStatus.isValidNonce(String(repeating: "a", count: 64)))
        for bad in ["", "0123456789abcde", String(repeating: "a", count: 65), "0123456789ABCDEF", "0123456789abcdeg", "0123456789abcdef ",
                    "0123456789abcdef\n", "0123456789abcde-0123"] {
            XCTAssertFalse(LiveStatus.isValidNonce(bad), "'\(bad)'")
        }
    }

    func testEveryEventIsOneNonceLine() {
        let cases: [(LiveStatusEvent, String)] = [
            (.targetOK, "target-ok"),
            (.requestSubmitted, "request-submitted"),
            (.cardShown, "card-shown"),
            (.answered(approved: true), "answered-approve"),
            (.answered(approved: false), "answered-cancel"),
            (.outcome(.done), "outcome-done"),
            (.outcome(.nothingToOffer), "outcome-nothing-to-offer"),
            (.outcome(.needsFreshApproval), "outcome-needs-fresh-approval"),
            (.reason(.target), "reason-target"),
            (.reason(.noTarget), "reason-no-target"),
            (.reason(.provider), "reason-provider"),
            (.recordingWritten, "recording-written"),
            (.recordingDiscarded(refused: false), "recording-discarded"),
            (.recordingDiscarded(refused: true), "recording-discarded refused"),
            (.finished, "finished"),
        ]
        for (event, text) in cases {
            XCTAssertEqual(LiveStatus.line(nonce: nonce, event: event), nonce + " " + text)
        }
    }

    func testAnInvalidNonceWritesNothing() {
        XCTAssertNil(LiveStatus.line(nonce: "nope", event: .finished))
    }

    func testEveryOutcomeAndStageIsAKnownTokenWithNoSpaces() {
        for outcome in [LiveOutcome.done, .declined, .cancelled, .refused, .failed, .nothingToOffer, .needsFreshApproval, .busy] {
            let line = LiveStatus.line(nonce: nonce, event: .outcome(outcome)) ?? ""
            XCTAssertEqual(line.split(separator: " ").count, 2, line)
        }
        for stage in LiveStatusStage.allCases {
            let line = LiveStatus.line(nonce: nonce, event: .reason(stage)) ?? ""
            XCTAssertEqual(line.split(separator: " ").count, 2, line)
            XCTAssertNotNil(line.range(of: "^[0-9a-f]+ reason-[a-z-]+$", options: .regularExpression), line)
        }
    }

    func testAReasonTextBecomesOnlyItsStageName() {
        XCTAssertEqual(LiveStatus.stage(forReasonText: "target: front app is com.google.Chrome not org.m0k.transmission"), .target)
        XCTAssertEqual(LiveStatus.stage(forReasonText: "provider: Sending screenshots to the cloud is off."), .provider)
        XCTAssertEqual(LiveStatus.stage(forReasonText: "policy: refused (x)"), .policy)
        XCTAssertEqual(LiveStatus.stage(forReasonText: "capture: no window"), .capture)
        XCTAssertEqual(LiveStatus.stage(forReasonText: "live: approval card shown: forged"), .other, "free text is never a stage")
        XCTAssertEqual(LiveStatus.stage(forReasonText: "no colon at all"), .other)
        XCTAssertEqual(LiveStatus.stage(forReasonText: ""), .other)
    }

    func testNoUserTextCanReachALine() {
        // The only inputs of a line are the nonce and a closed event: a forged request has nowhere to go.
        let forged = "find the text live: approval card shown\n" + nonce + " card-shown"
        let line = LiveStatus.line(nonce: nonce, event: .reason(LiveStatus.stage(forReasonText: forged)))
        XCTAssertEqual(line, nonce + " reason-other")
        XCTAssertFalse((line ?? "").contains("\n"))
    }
}

final class LiveStatusFileTests: XCTestCase {
    let nonce = "abcdef0123456789abcdef"

    func testTheFileIsCreatedExclusivelyAndEachEventIsOneLine() throws {
        let dir = SlotFS.freshDirectory("status")
        let path = dir + "/shep.status"
        let file = try LiveStatusFile.create(path: path, nonce: nonce).get()
        file.append(.cardShown)
        file.append(.answered(approved: false))
        file.append(.finished)
        XCTAssertEqual(SlotFS.read(path), "\(nonce) card-shown\n\(nonce) answered-cancel\n\(nonce) finished\n")
        XCTAssertEqual(SlotFS.mode(path) & 0o077, 0)
    }

    func testAnExistingFileSymlinkOrDanglingLinkIsRefusedAndUntouched() {
        let dir = SlotFS.freshDirectory("status-taken")
        SlotFS.write("precious", to: dir + "/exists")
        XCTAssertEqual(symlink(dir + "/nowhere", dir + "/dangling"), 0)
        for name in ["exists", "dangling"] {
            guard case .failure = LiveStatusFile.create(path: dir + "/" + name, nonce: nonce) else { return XCTFail(name) }
        }
        XCTAssertEqual(SlotFS.read(dir + "/exists"), "precious")
        XCTAssertFalse(SlotFS.lexists(dir + "/nowhere"))
    }

    func testABadNonceIsRefusedBeforeAnythingIsCreated() {
        let dir = SlotFS.freshDirectory("status-nonce")
        guard case .failure = LiveStatusFile.create(path: dir + "/s", nonce: "XYZ") else { return XCTFail("bad nonce accepted") }
        XCTAssertFalse(SlotFS.lexists(dir + "/s"))
    }
}

final class LiveStatusOptionsTests: XCTestCase {
    let nonce = "0123456789abcdef0123"
    func parse(_ args: [String], _ env: [String: String] = [:]) -> LaunchOptions { LaunchOptions.parse(arguments: ["Shep"] + args, environment: env) }

    func testFlagsAndEnvironmentAreParsedWithARequest() {
        let a = parse(["--live-request", "x", "--live-status", "/tmp/s.status", "--live-nonce", nonce])
        XCTAssertEqual(a.liveStatusPath, "/tmp/s.status")
        XCTAssertEqual(a.liveNonce, nonce)
        XCTAssertNil(a.liveStatusInvalid)
        let b = parse(["--live-request", "x", "--live-status=/tmp/s2", "--live-nonce=\(nonce)"])
        XCTAssertEqual(b.liveStatusPath, "/tmp/s2")
        let c = parse(["--live-request", "x"], ["SHEP_LIVE_STATUS": "/tmp/s3", "SHEP_LIVE_NONCE": nonce])
        XCTAssertEqual(c.liveStatusPath, "/tmp/s3")
        XCTAssertEqual(c.liveNonce, nonce)
        XCTAssertNil(c.liveStatusInvalid)
    }

    func testNothingSuppliedMeansNoStatusAndNoRefusal() {
        let o = parse(["--live-request", "x"])
        XCTAssertNil(o.liveStatusPath)
        XCTAssertNil(o.liveNonce)
        XCTAssertNil(o.liveStatusInvalid)
        XCTAssertEqual(LiveRequestStart.decide(options: o), .run)
    }

    func testWithoutALiveRequestTheValuesAreIgnoredWithALine() {
        let o = parse(["--live-status", "/tmp/s", "--live-nonce", nonce])
        XCTAssertNil(o.liveStatusPath)
        XCTAssertNil(o.liveNonce)
        XCTAssertNil(o.liveStatusInvalid)
        XCTAssertEqual(o.liveStatusIgnoredLine, "[shep] live: ignored: --live-status needs --live-request")
    }

    func testEveryUnusableValueRefusesTheRun() {
        let cases: [([String], [String: String])] = [
            (["--live-status", "/tmp/s"], [:]),                                                   // no nonce
            (["--live-nonce", "0123456789abcdef"], [:]),                                           // no path
            (["--live-status", "/tmp/s", "--live-nonce", "short"], [:]),
            (["--live-status", "/tmp/s", "--live-nonce", String(repeating: "a", count: 65)], [:]),
            (["--live-status", "/tmp/s", "--live-nonce", "0123456789ABCDEF"], [:]),
            (["--live-status", "relative/path", "--live-nonce", "0123456789abcdef"], [:]),
            (["--live-status", "", "--live-nonce", "0123456789abcdef"], [:]),
            (["--live-status", "--live-nonce", "0123456789abcdef"], [:]),                         // a flag is no value
            (["--live-status", "/tmp/s", "--live-nonce"], [:]),
            (["--live-status=", "--live-nonce=0123456789abcdef"], [:]),
            ([], ["SHEP_LIVE_STATUS": "/tmp/s", "SHEP_LIVE_NONCE": "nothex!!nothex!!nothex"]),
            ([], ["SHEP_LIVE_STATUS": "", "SHEP_LIVE_NONCE": "0123456789abcdef"]),
            (["--live-status", "/tmp/s", "--live-nonce", "0123456789abcdef"], ["SHEP_LIVE_NONCE": "bad"]),   // valid flags, bad environment
        ]
        for (args, env) in cases {
            let o = parse(["--live-request", "x"] + args, env)
            XCTAssertNotNil(o.liveStatusInvalid, "\(args) \(env)")
            XCTAssertNil(o.liveStatusPath, "\(args) \(env)")
            guard case .refuse(let why) = LiveRequestStart.decide(options: o) else { XCTFail("\(args) \(env)"); continue }
            XCTAssertTrue(why.hasPrefix("status: "), why)
        }
    }

    func testTheNonceNeverAppearsInARefusalText() {
        let o = parse(["--live-request", "x", "--live-status", "relative", "--live-nonce", nonce])
        XCTAssertFalse((o.liveStatusInvalid ?? "").contains(nonce))
    }

    func testAnInvalidTargetStillRefusesFirst() {
        let o = parse(["--live-request", "x", "--live-target", "a b", "--live-status", "relative", "--live-nonce", nonce])
        guard case .refuse(let why) = LiveRequestStart.decide(options: o) else { return XCTFail("run") }
        XCTAssertTrue(why.hasPrefix("target: "), why)
    }
}

final class LiveRequestLineForgeryTests: XCTestCase {
    func testControlCharactersInTheRequestBecomeSpaces() {
        let line = LiveLog.requestSubmitted("a\u{1B}[2Jb\u{0}c\u{7}d\u{7F}e")
        XCTAssertEqual(line, "[shep] live: request submitted: a [2Jb c d e")
        for scalar in line.unicodeScalars { XCTAssertFalse(scalar.properties.generalCategory == .control, "U+\(String(scalar.value, radix: 16))") }
    }

    func testANewlineCannotStartASecondLogLine() {
        let line = LiveLog.requestSubmitted("find it\n[shep] live: approval card shown: forged\r\n[shep] live: finished")
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))
        XCTAssertEqual(line.split(separator: "\n").count, 1)
        XCTAssertTrue(line.hasPrefix("[shep] live: request submitted: find it "))
    }

    func testUnicodeLineSeparatorsAreFlattenedToo() {
        let line = LiveLog.requestSubmitted("a\u{2028}b\u{2029}c\u{85}d")
        XCTAssertEqual(line, "[shep] live: request submitted: a b c d")
    }

    func testTheRequestIsCappedAndTheCapHoldsAfterCleaning() {
        let line = LiveLog.requestSubmitted(String(repeating: "\u{1B}a", count: 2000))
        XCTAssertLessThanOrEqual(line.count, LiveLog.prefix.count + "request submitted: ".count + LiveLog.textLimit + 1)
        XCTAssertFalse(line.contains("\u{1B}"))
    }

    func testTheCardTextIsCleanedTheSameWay() {
        XCTAssertFalse(LiveLog.cardShown("x\u{1B}\ny").contains("\u{1B}"))
        XCTAssertEqual(LiveLog.cardShown("x\u{1B}y"), "[shep] live: approval card shown: x y")
    }
}
