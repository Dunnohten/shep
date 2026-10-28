import Foundation

/// Written for Shep.
/// The dog's face and ear poses: one table (ears, eyes, head tilt) per named pose, and how the page moves between them
/// (spring stiffness and damping, per-ear delays, the wake twitch). Pure data and arithmetic: the page
/// (tools/shep-dog/src/poses.ts) receives a pose as JSON through `shep.setPose(json)` / `house.setPose(json)` and animates it.
/// Angles are degrees about each ear's attach point, positive = the ear swings outward and up (the page mirrors the right ear),
/// negative = it droops. Lift is in head units (the dog's own drawing space), positive = up.

public enum PoseName: String, CaseIterable, Equatable, Sendable {
    case asleep, waking, idle, listening, thinking, talking, finish
}

public struct EarPose: Equatable, Sendable {
    public var angle: Double
    public var lift: Double
    public init(angle: Double, lift: Double) { self.angle = angle; self.lift = lift }
}

public struct DogPose: Equatable, Sendable {
    public var name: PoseName
    public var leftEar: EarPose
    public var rightEar: EarPose
    /// 1 = normal; listening widens the eyes a little.
    public var eyeScale: Double
    /// Where the eyes look, -1...1 (x: right is +, y: up is -), on top of the pointer and the blink.
    public var eyeX: Double
    public var eyeY: Double
    /// Head tilt in degrees (positive = clockwise).
    public var headTilt: Double
    /// The tilt starts this long after the ears move ("ears first, then a small tilt").
    public var tiltDelay: Double

    public init(name: PoseName, leftEar: EarPose, rightEar: EarPose, eyeScale: Double = 1, eyeX: Double = 0, eyeY: Double = 0,
                headTilt: Double = 0, tiltDelay: Double = 0) {
        self.name = name; self.leftEar = leftEar; self.rightEar = rightEar; self.eyeScale = eyeScale
        self.eyeX = eyeX; self.eyeY = eyeY; self.headTilt = headTilt; self.tiltDelay = tiltDelay
    }

    /// The lowest ear angle (degrees) any pose may use. The ear is drawn behind the head with its inner edge buried in it and
    /// already hangs down the cheek, so a strongly negative angle swings the flap inward until it is completely hidden behind
    /// the head: the dog then shows one ear or none. The page clamps incoming angles to this value as well
    /// (tools/shep-dog/src/poses.ts `parsePose`).
    public static let minVisibleEarAngle: Double = -20

    public static func pose(_ name: PoseName) -> DogPose {
        switch name {
        case .asleep:
            // Ears hang a little lower than idle (never below minVisibleEarAngle), eyes a touch narrower (the house closes them), head level.
            return DogPose(name: name, leftEar: EarPose(angle: -12, lift: -2), rightEar: EarPose(angle: -12, lift: -2),
                           eyeScale: 0.95, eyeX: 0, eyeY: 0.3)
        case .waking:
            // The pop that follows the twitch: both ears up past neutral, eyes wide open.
            return DogPose(name: name, leftEar: EarPose(angle: 22, lift: 2.5), rightEar: EarPose(angle: 22, lift: 2.5), eyeScale: 1.1)
        case .idle:
            return DogPose(name: name, leftEar: EarPose(angle: 0, lift: 0), rightEar: EarPose(angle: 0, lift: 0))
        case .listening:
            // Both ears lift and perk forward, eyes widen slightly, then a small head tilt.
            return DogPose(name: name, leftEar: EarPose(angle: 52, lift: 4), rightEar: EarPose(angle: 52, lift: 4),
                           eyeScale: 1.12, headTilt: 7, tiltDelay: 0.35)
        case .thinking:
            // One ear tucked, the other cocked up; both stay visible. the eyes look up and to the side.
            return DogPose(name: name, leftEar: EarPose(angle: -8, lift: -2), rightEar: EarPose(angle: 20, lift: 1.5),
                           eyeX: 0.6, eyeY: -0.85, headTilt: -4, tiltDelay: 0.2)
        case .talking:
            return DogPose(name: name, leftEar: EarPose(angle: 10, lift: 1), rightEar: EarPose(angle: 10, lift: 1), eyeScale: 1.04)
        case .finish:
            // Happy: ears up high, eyes wide.
            return DogPose(name: name, leftEar: EarPose(angle: 40, lift: 5), rightEar: EarPose(angle: 40, lift: 5), eyeScale: 1.18)
        }
    }

    /// The pose behind a dog state (the menu, the pipeline and the voice session speak in `ShepDogState`).
    public static func name(for state: ShepDogState) -> PoseName {
        switch state {
        case .idle, .lookLeft, .lookRight: return .idle
        case .thinking: return .thinking
        case .listening: return .listening
        case .talking: return .talking
        case .sleeping: return .asleep
        }
    }
}

/// The wake twitch: one ear flicks first, and only after `popDelay` do both ears pop up.
public struct WakeTwitch: Equatable, Sendable {
    /// 0 = left ear, 1 = right ear.
    public var ear: Int
    /// Degrees the twitching ear lifts above where it hangs.
    public var kick: Double
    public var seconds: Double
    /// When the pop starts, counted from the start of the wake. Always after the twitch has begun.
    public var popDelay: Double

    public init(ear: Int, kick: Double, seconds: Double, popDelay: Double) {
        self.ear = ear; self.kick = kick; self.seconds = seconds; self.popDelay = popDelay
    }

    public static let standard = WakeTwitch(ear: 0, kick: 24, seconds: 0.18, popDelay: 0.24)
}

/// How the page moves to a pose: a damped spring per value, an optional delay per ear, and the wake twitch.
public struct PoseTransition: Equatable, Sendable {
    public var stiffness: Double
    public var damping: Double
    /// Delay before the [left, right] ear starts moving (seconds).
    public var earDelay: [Double]
    /// False = a static change (Reduce Motion): the values jump to the pose, with no spring, no delay and no overshoot.
    public var springs: Bool
    public var twitch: WakeTwitch?

    /// Damping ratio of the spring: below 1 it overshoots ("goop").
    public var dampingRatio: Double { springs && stiffness > 0 ? damping / (2 * stiffness.squareRoot()) : 1 }

    /// Fraction of the step the spring overshoots by: exp(-pi z / sqrt(1 - z^2)) for z < 1, 0 otherwise.
    public var overshoot: Double {
        let z = dampingRatio
        guard springs, z > 0, z < 1 else { return 0 }
        return exp(-Double.pi * z / (1 - z * z).squareRoot())
    }

    /// Roughly when the motion has settled to within 2 % (4 / (z w0)), plus the longest delay; 0 for a static change.
    public var settleSeconds: Double {
        guard springs, stiffness > 0 else { return 0 }
        let z = max(dampingRatio, 0.05)
        return 4 / (z * stiffness.squareRoot()) + (earDelay.max() ?? 0) + (twitch?.popDelay ?? 0)
    }

    public static let immediate = PoseTransition(stiffness: 0, damping: 0, earDelay: [0, 0], springs: false, twitch: nil)

    public static func to(_ name: PoseName, reduceMotion: Bool) -> PoseTransition {
        if reduceMotion { return .immediate }
        switch name {
        case .asleep:
            return PoseTransition(stiffness: 90, damping: 14, earDelay: [0, 0.08], springs: true, twitch: nil)   // sinks and settles
        case .waking:
            return PoseTransition(stiffness: 200, damping: 9, earDelay: [0, 0], springs: true, twitch: .standard)
        case .idle:
            return PoseTransition(stiffness: 150, damping: 12, earDelay: [0, 0.04], springs: true, twitch: nil)
        case .listening:
            return PoseTransition(stiffness: 190, damping: 9.5, earDelay: [0, 0.05], springs: true, twitch: nil)
        case .thinking:
            return PoseTransition(stiffness: 120, damping: 11, earDelay: [0, 0.12], springs: true, twitch: nil)
        case .talking:
            return PoseTransition(stiffness: 170, damping: 11, earDelay: [0, 0], springs: true, twitch: nil)
        case .finish:
            return PoseTransition(stiffness: 220, damping: 8, earDelay: [0, 0.04], springs: true, twitch: nil)
        }
    }
}

public enum PoseBridge {
    /// The JSON the page takes: `shep.setPose(<this>)`. Numbers only, so there is nothing to escape.
    public static func json(for name: PoseName, reduceMotion: Bool) -> String {
        let pose = DogPose.pose(name)
        let t = PoseTransition.to(name, reduceMotion: reduceMotion)
        var transition: [String: Any] = [
            "stiffness": t.stiffness, "damping": t.damping, "earDelay": t.earDelay, "springs": t.springs,
        ]
        if let w = t.twitch {
            transition["twitch"] = ["ear": w.ear, "kick": w.kick, "seconds": w.seconds, "popDelay": w.popDelay] as [String: Any]
        }
        let object: [String: Any] = [
            "name": name.rawValue,
            "ears": [["angle": pose.leftEar.angle, "lift": pose.leftEar.lift], ["angle": pose.rightEar.angle, "lift": pose.rightEar.lift]],
            "eyeScale": pose.eyeScale, "eyeX": pose.eyeX, "eyeY": pose.eyeY,
            "tilt": pose.headTilt, "tiltDelay": reduceMotion ? 0 : pose.tiltDelay,
            "transition": transition,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
