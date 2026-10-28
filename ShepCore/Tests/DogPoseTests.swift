import XCTest
@testable import ShepCore

final class DogPoseTests: XCTestCase {
    func testEveryNameHasAPoseWithItsOwnName() {
        for n in PoseName.allCases { XCTAssertEqual(DogPose.pose(n).name, n) }
        XCTAssertEqual(PoseName.allCases.count, 7)
    }

    func testIdleIsNeutral() {
        let p = DogPose.pose(.idle)
        XCTAssertEqual(p.leftEar, EarPose(angle: 0, lift: 0))
        XCTAssertEqual(p.rightEar, EarPose(angle: 0, lift: 0))
        XCTAssertEqual(p.eyeScale, 1); XCTAssertEqual(p.headTilt, 0)
    }

    func testAsleepEarsHangLowerThanIdleButStayVisibleBothSides() {
        let p = DogPose.pose(.asleep)
        XCTAssertLessThan(p.leftEar.angle, 0)
        XCTAssertGreaterThanOrEqual(p.leftEar.angle, DogPose.minVisibleEarAngle)
        XCTAssertEqual(p.leftEar, p.rightEar)
        XCTAssertLessThanOrEqual(p.leftEar.lift, 0)
    }

    func testListeningBothEarsLiftAndPerkEyesWidenThenTilt() {
        let p = DogPose.pose(.listening), idle = DogPose.pose(.idle)
        XCTAssertEqual(p.leftEar, p.rightEar)
        XCTAssertGreaterThan(p.leftEar.angle, idle.leftEar.angle + 30)
        XCTAssertGreaterThan(p.leftEar.lift, 0)
        XCTAssertGreaterThan(p.eyeScale, 1); XCTAssertLessThanOrEqual(p.eyeScale, 1.2)   // slightly
        XCTAssertGreaterThan(abs(p.headTilt), 3); XCTAssertLessThanOrEqual(abs(p.headTilt), 12)   // small
        let t = PoseTransition.to(.listening, reduceMotion: false)
        XCTAssertGreaterThan(p.tiltDelay, t.earDelay.max() ?? 0)   // the tilt comes after the ears
    }

    func testThinkingOneEarTuckedOneCockedAndTheEyesLookUpAndAside() {
        let p = DogPose.pose(.thinking)
        XCTAssertLessThan(p.leftEar.angle, 0)                  // tucked, but not below the visible limit
        XCTAssertGreaterThanOrEqual(p.leftEar.angle, DogPose.minVisibleEarAngle)
        XCTAssertGreaterThanOrEqual(p.rightEar.angle, 10)      // the other is cocked up
        XCTAssertLessThan(p.eyeY, -0.5)       // up
        XCTAssertGreaterThan(abs(p.eyeX), 0.3)   // and aside
    }

    func testFinishEarsAreUpAndHigherThanTalking() {
        XCTAssertGreaterThan(DogPose.pose(.finish).leftEar.angle, DogPose.pose(.talking).leftEar.angle)
        XCTAssertGreaterThan(DogPose.pose(.finish).leftEar.lift, 0)
    }

    func testBothEarsStayVisibleInEveryPose() {
        for n in PoseName.allCases {
            let p = DogPose.pose(n)
            XCTAssertGreaterThanOrEqual(p.leftEar.angle, DogPose.minVisibleEarAngle, "\(n) left ear")
            XCTAssertGreaterThanOrEqual(p.rightEar.angle, DogPose.minVisibleEarAngle, "\(n) right ear")
        }
        XCTAssertEqual(DogPose.minVisibleEarAngle, -20)
    }

    func testThinkingAndAsleepKeepBothEarsOutsideTheHead() {
        let t = DogPose.pose(.thinking), a = DogPose.pose(.asleep)
        XCTAssertEqual(t.leftEar, EarPose(angle: -8, lift: -2))
        XCTAssertEqual(t.rightEar, EarPose(angle: 20, lift: 1.5))
        XCTAssertEqual(a.leftEar, EarPose(angle: -12, lift: -2))
        XCTAssertEqual(a.rightEar, EarPose(angle: -12, lift: -2))
    }

    func testPoseJSONCarriesTheVisibleEarValues() throws {
        for (name, expected) in [(PoseName.thinking, [[-8.0, -2.0], [20.0, 1.5]]), (PoseName.asleep, [[-12.0, -2.0], [-12.0, -2.0]])] {
            let text = PoseBridge.json(for: name, reduceMotion: false)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let ears = try XCTUnwrap(object["ears"] as? [[String: Double]])
            XCTAssertEqual(ears.count, 2)
            for i in 0..<2 {
                XCTAssertEqual(ears[i]["angle"], expected[i][0], "\(name) ear \(i) angle")
                XCTAssertEqual(ears[i]["lift"], expected[i][1], "\(name) ear \(i) lift")
            }
        }
    }

    func testAllValuesAreFiniteAndInRange() {
        for n in PoseName.allCases {
            let p = DogPose.pose(n)
            for e in [p.leftEar, p.rightEar] {
                XCTAssertTrue(e.angle.isFinite && abs(e.angle) <= 90, "\(n)")
                XCTAssertTrue(e.lift.isFinite && abs(e.lift) <= 8, "\(n)")
            }
            XCTAssertTrue(p.eyeScale >= 0.8 && p.eyeScale <= 1.3, "\(n)")
            XCTAssertTrue(abs(p.eyeX) <= 1 && abs(p.eyeY) <= 1, "\(n)")
            XCTAssertTrue(abs(p.headTilt) <= 15 && p.tiltDelay >= 0 && p.tiltDelay <= 1, "\(n)")
        }
    }

    func testStateMapping() {
        XCTAssertEqual(DogPose.name(for: .thinking), .thinking)
        XCTAssertEqual(DogPose.name(for: .listening), .listening)
        XCTAssertEqual(DogPose.name(for: .talking), .talking)
        XCTAssertEqual(DogPose.name(for: .sleeping), .asleep)
        for s in [ShepDogState.idle, .lookLeft, .lookRight] { XCTAssertEqual(DogPose.name(for: s), .idle) }
    }
}

final class PoseTransitionTests: XCTestCase {
    func testSpringyPosesOvershootWithoutReduceMotion() {
        for n in [PoseName.waking, .listening, .thinking, .finish, .idle, .talking] {
            let t = PoseTransition.to(n, reduceMotion: false)
            XCTAssertTrue(t.springs, "\(n)")
            XCTAssertGreaterThan(t.overshoot, 0.05, "\(n) should overshoot")
            XCTAssertLessThan(t.overshoot, 0.6, "\(n) should not wobble wildly")
            XCTAssertGreaterThan(t.stiffness, 0); XCTAssertGreaterThan(t.damping, 0)
        }
    }

    func testListeningIsSpringierThanThinking() {
        XCTAssertGreaterThan(PoseTransition.to(.listening, reduceMotion: false).overshoot, PoseTransition.to(.thinking, reduceMotion: false).overshoot)
    }

    func testReduceMotionIsStatic() {
        for n in PoseName.allCases {
            let t = PoseTransition.to(n, reduceMotion: true)
            XCTAssertFalse(t.springs, "\(n)")
            XCTAssertEqual(t.overshoot, 0, "\(n)")
            XCTAssertEqual(t.earDelay, [0, 0], "\(n)")
            XCTAssertNil(t.twitch, "\(n)")
            XCTAssertEqual(t.settleSeconds, 0, "\(n)")
        }
    }

    func testOvershootFormula() {
        // zeta = 0.5 -> exp(-pi * 0.5 / sqrt(0.75)) = 0.1630...
        let t = PoseTransition(stiffness: 100, damping: 10, earDelay: [0, 0], springs: true, twitch: nil)
        XCTAssertEqual(t.dampingRatio, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.overshoot, 0.16303, accuracy: 1e-4)
        let critical = PoseTransition(stiffness: 100, damping: 20, earDelay: [0, 0], springs: true, twitch: nil)
        XCTAssertEqual(critical.overshoot, 0)
    }

    func testWakeTwitchesOneEarBeforeBothPop() {
        let t = PoseTransition.to(.waking, reduceMotion: false)
        guard let w = t.twitch else { return XCTFail("waking has a twitch") }
        XCTAssertTrue(w.ear == 0 || w.ear == 1)
        XCTAssertGreaterThan(w.kick, 0)
        XCTAssertGreaterThan(w.popDelay, 0)
        XCTAssertLessThan(w.seconds, w.popDelay + 0.001)   // the flick is over (or ending) when the pop starts
        XCTAssertNil(PoseTransition.to(.listening, reduceMotion: false).twitch)
        // The twitch and the pop both fit in the wake stretch.
        XCTAssertLessThan(w.popDelay, LifecycleTimings.wakeSeconds)
    }

    func testJSONCarriesThePoseAndTheTransition() throws {
        let text = PoseBridge.json(for: .listening, reduceMotion: false)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(o["name"] as? String, "listening")
        let ears = try XCTUnwrap(o["ears"] as? [[String: Double]])
        XCTAssertEqual(ears.count, 2)
        XCTAssertEqual(ears[0]["angle"], 52); XCTAssertEqual(ears[1]["lift"], 4)
        XCTAssertEqual(o["eyeScale"] as? Double, 1.12)
        XCTAssertEqual(o["tilt"] as? Double, 7); XCTAssertEqual(o["tiltDelay"] as? Double, 0.35)
        let tr = try XCTUnwrap(o["transition"] as? [String: Any])
        XCTAssertEqual(tr["springs"] as? Bool, true)
        XCTAssertEqual(tr["earDelay"] as? [Double], [0, 0.05])
        XCTAssertNil(tr["twitch"])
        let wake = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PoseBridge.json(for: .waking, reduceMotion: false).utf8)) as? [String: Any])
        let tw = try XCTUnwrap((wake["transition"] as? [String: Any])?["twitch"] as? [String: Any])
        XCTAssertEqual(tw["popDelay"] as? Double, 0.24)
    }

    func testJSONInReduceMotionHasNoSpringsOrDelays() throws {
        for n in PoseName.allCases {
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PoseBridge.json(for: n, reduceMotion: true).utf8)) as? [String: Any])
            let tr = try XCTUnwrap(o["transition"] as? [String: Any])
            XCTAssertEqual(tr["springs"] as? Bool, false, "\(n)")
            XCTAssertEqual(o["tiltDelay"] as? Double, 0, "\(n)")
            XCTAssertNil(tr["twitch"], "\(n)")
        }
    }
}
