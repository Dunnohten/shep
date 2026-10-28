import CoreGraphics
import Foundation

/// Written for Shep.
/// The way Shep crosses the screen: a cubic Bezier arc between two points (the doghouse's door and the target), eased in
/// and out, with the dog stretched along its velocity and squashed across it, like a drop of goo being thrown.
/// Pure geometry in Cocoa screen coordinates (bottom-left origin, y up), no AppKit.

/// Where Shep is going. `.control` is the hook for pointing at a control later.
public enum TravelTarget: Equatable {
    /// The tab on a window's title bar. `placed` is the live dock placement when the caller has it (so the traveller lands
    /// exactly where the dock will appear); without it the tab is computed from the window frame alone.
    case tab(windowFrame: CGRect, placed: TabLayout? = nil)
    /// Beside a control: just above its top edge, centred.
    case control(CGRect)

    /// Where the dog's centre ends up (Cocoa), or nil when there is nowhere to go (the tab is hidden, the rect is empty).
    public func destination(screens: [CGRect], usable: [CGRect]? = nil) -> CGPoint? {
        switch self {
        case .tab(let window, let placed):
            if let l = placed {
                return CGPoint(x: l.dogFrame.midX, y: l.dogFrame.midY)
            }
            guard let l = TabGeometry.place(window: window, isFullScreen: false, screens: screens, usable: usable).layout else { return nil }
            return CGPoint(x: l.dogFrame.midX, y: l.dogFrame.midY)
        case .control(let r):
            guard r.width > 0, r.height > 0, !r.isNull, r.midX.isFinite, r.maxY.isFinite else { return nil }
            let p = CGPoint(x: r.midX, y: r.maxY + TravelPath.controlHover)
            return TravelPath.clamp(p, toScreens: screens)
        }
    }
}

/// One frame of a travel. `position` is where the dog's centre is (Cocoa).
public struct TravelSample: Equatable {
    /// Seconds from the start.
    public var time: TimeInterval
    public var position: CGPoint
    /// Points per second.
    public var speed: Double
    /// Direction of travel in CSS convention (degrees, 0 = right, positive = clockwise on screen, y down), for the page's rotate().
    public var angleDegrees: Double
    /// Scale along the direction of travel (>= 1) and across it (<= 1).
    public var along: Double
    public var across: Double
    /// 0...1: fades in over the first and out over the last few percent, so the hand-offs with the doghouse and the dock cross-fade.
    public var opacity: Double
}

public struct TravelPath: Equatable {
    public static let minDuration: TimeInterval = 0.9
    public static let maxDuration: TimeInterval = 1.2
    /// Length (points) at which the duration reaches the maximum.
    static let longPath: CGFloat = 1200
    /// How far the control points leave the chord, as a share of its length.
    public static let bulge: CGFloat = 0.35
    /// Keeps control points and samples this far inside a screen's edge.
    public static let edgeInset: CGFloat = 8
    /// How far above a control the dog hovers.
    public static let controlHover: CGFloat = 20
    /// Squash and stretch: stretch 1 at rest, up to `maxStretch` at `fullSpeed` points per second.
    public static let fullSpeed: Double = 1400
    public static let maxStretch: Double = 1.75
    /// Share of the travel (each end) over which the opacity ramps.
    public static let fadeShare: Double = 0.1

    public var start: CGPoint
    public var control1: CGPoint
    public var control2: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start; self.control1 = control1; self.control2 = control2; self.end = end
    }

    // MARK: building the arc

    /// An arc from `start` to `end` that bows to the side facing the middle of the screens, with the control points
    /// (and so the whole curve, which lies inside their hull) kept on screen, across any number of monitors.
    public static func arc(from start: CGPoint, to end: CGPoint, screens: [CGRect]) -> TravelPath {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length.isFinite, length > 0.5 else {
            return TravelPath(start: start, control1: start, control2: end, end: end)
        }
        let nx = -dy / length, ny = dx / length   // the chord turned a quarter turn counter-clockwise
        // Bow toward the middle of all screens: the arc stays on the desktop and tends to sweep through it.
        var side: CGFloat = 1
        if let b = boundingBox(screens) {
            let mx = (start.x + end.x) / 2, my = (start.y + end.y) / 2
            let dot = nx * (b.midX - mx) + ny * (b.midY - my)
            if dot < 0 { side = -1 }
        }
        let h = bulge * length * side
        let c1 = CGPoint(x: start.x + dx * 0.25 + nx * h, y: start.y + dy * 0.25 + ny * h)
        let c2 = CGPoint(x: start.x + dx * 0.75 + nx * h, y: start.y + dy * 0.75 + ny * h)
        return TravelPath(start: start, control1: clamp(c1, toScreens: screens), control2: clamp(c2, toScreens: screens), end: end)
    }

    /// The same arc walked the other way (the walk home).
    public var reversed: TravelPath {
        TravelPath(start: end, control1: control2, control2: control1, end: start)
    }

    // MARK: the curve

    public func point(at t: Double) -> CGPoint {
        let u = CGFloat(Self.unit(t)), v = 1 - u
        let a: CGFloat = v * v * v, b: CGFloat = 3 * v * v * u, c: CGFloat = 3 * v * u * u, d: CGFloat = u * u * u
        let x: CGFloat = a * start.x + b * control1.x + c * control2.x + d * end.x
        let y: CGFloat = a * start.y + b * control1.y + c * control2.y + d * end.y
        return CGPoint(x: x, y: y)
    }

    /// dB/dt (not normalised).
    public func derivative(at t: Double) -> CGPoint {
        let u = CGFloat(Self.unit(t)), v = 1 - u
        let a: CGFloat = 3 * v * v, b: CGFloat = 6 * v * u, c: CGFloat = 3 * u * u
        let x: CGFloat = a * (control1.x - start.x) + b * (control2.x - control1.x) + c * (end.x - control2.x)
        let y: CGFloat = a * (control1.y - start.y) + b * (control2.y - control1.y) + c * (end.y - control2.y)
        return CGPoint(x: x, y: y)
    }

    /// Arc length by summing `steps` straight pieces.
    public func length(steps: Int = 64) -> Double {
        let n = max(1, steps)
        var total = 0.0
        var previous = point(at: 0)
        for i in 1...n {
            let p = point(at: Double(i) / Double(n))
            total += Double(((p.x - previous.x) * (p.x - previous.x) + (p.y - previous.y) * (p.y - previous.y)).squareRoot())
            previous = p
        }
        return total
    }

    /// 0.9 s for a short hop up to 1.2 s for a long crossing.
    public var duration: TimeInterval {
        let share = min(1, max(0, length() / Double(Self.longPath)))
        return Self.minDuration + (Self.maxDuration - Self.minDuration) * share
    }

    // MARK: motion along the curve

    /// Ease in and out (smoothstep): progress along the curve for time share `u`.
    public static func ease(_ u: Double) -> Double {
        let x = unit(u)
        return x * x * (3 - 2 * x)
    }

    /// d ease / du.
    public static func easeRate(_ u: Double) -> Double {
        let x = unit(u)
        return 6 * x * (1 - x)
    }

    /// Stretch along the velocity for a speed: 1 at rest, `maxStretch` at `fullSpeed` and beyond.
    public static func stretch(speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return 1 }
        return 1 + (maxStretch - 1) * min(1, speed / fullSpeed)
    }

    /// Squash across the velocity: keeps the area (along * across == 1).
    public static func squash(stretch: Double) -> Double {
        stretch > 0 ? 1 / stretch.squareRoot() : 1
    }

    /// Opacity for time share `u`: ramps up over the first `fadeShare`, down over the last.
    public static func opacity(at u: Double) -> Double {
        let x = unit(u)
        if x < fadeShare { return x / fadeShare }
        if x > 1 - fadeShare { return (1 - x) / fadeShare }
        return 1
    }

    /// The frames of a travel taking `duration` seconds at `fps` (both ends included). Positions are clamped onto the screens.
    public func samples(duration: TimeInterval, fps: Int = LifecycleFramePolicy.travelFPS, screens: [CGRect] = []) -> [TravelSample] {
        let d = duration.isFinite && duration > 0 ? duration : Self.minDuration
        let n = max(2, Int((d * Double(max(1, fps))).rounded(.up)))
        var out: [TravelSample] = []
        out.reserveCapacity(n + 1)
        for i in 0...n {
            let u = Double(i) / Double(n)
            let s = Self.ease(u)
            var p = point(at: s)
            if !screens.isEmpty { p = Self.clamp(p, toScreens: screens) }
            let v = derivative(at: s)
            let rate = Self.easeRate(u) / d
            let vx = Double(v.x) * rate, vy = Double(v.y) * rate
            let speed = (vx * vx + vy * vy).squareRoot()
            // Cocoa has y up, the page y down: flip the vertical component for a CSS angle.
            let angle = speed > 1e-6 ? atan2(-vy, vx) * 180 / Double.pi : 0
            let st = Self.stretch(speed: speed)
            out.append(TravelSample(time: d * u, position: p, speed: speed, angleDegrees: angle,
                                    along: st, across: Self.squash(stretch: st), opacity: Self.opacity(at: u)))
        }
        return out
    }

    /// Where the dog is at `time` seconds: linear between the two samples around it, clamped to the first and last.
    public static func position(in samples: [TravelSample], at time: TimeInterval) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if !(time > first.time) { return first.position }
        if time >= last.time { return last.position }
        for i in 1..<samples.count where time <= samples[i].time {
            let a = samples[i - 1], b = samples[i]
            let span = b.time - a.time
            let k = span > 0 ? CGFloat((time - a.time) / span) : 1
            return CGPoint(x: a.position.x + (b.position.x - a.position.x) * k, y: a.position.y + (b.position.y - a.position.y) * k)
        }
        return last.position
    }

    /// Rectangles that together cover the arc, each padded by `margin`: what must stay visible in a recording of the
    /// travel. Consecutive pieces overlap by construction (they share a sample).
    public func corridor(margin: CGFloat, pieces: Int = 12) -> [CGRect] {
        let n = max(1, pieces)
        var rects: [CGRect] = []
        var previous = point(at: 0)
        for i in 1...n {
            let p = point(at: Double(i) / Double(n))
            let r = CGRect(x: min(previous.x, p.x), y: min(previous.y, p.y), width: abs(p.x - previous.x), height: abs(p.y - previous.y))
            rects.append(r.insetBy(dx: -margin, dy: -margin))
            previous = p
        }
        return rects
    }

    // MARK: screens

    /// The point itself when it is inside a screen (inset by `edgeInset`); otherwise the nearest point that is.
    /// With no screens the point is returned unchanged.
    public static func clamp(_ p: CGPoint, toScreens screens: [CGRect]) -> CGPoint {
        guard p.x.isFinite, p.y.isFinite else { return screens.first.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero }
        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for s in screens where s.width > 0 && s.height > 0 {
            let inset = min(edgeInset, s.width / 2, s.height / 2)
            let r = s.insetBy(dx: inset, dy: inset)
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
            if q == p { return p }
            let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            if d < bestDistance { bestDistance = d; best = q }
        }
        return best ?? p
    }

    static func boundingBox(_ rects: [CGRect]) -> CGRect? {
        let valid = rects.filter { $0.width > 0 && $0.height > 0 }
        guard var box = valid.first else { return nil }
        for r in valid.dropFirst() { box = box.union(r) }
        return box
    }

    static func unit(_ t: Double) -> Double {
        t.isFinite ? min(1, max(0, t)) : 0
    }

    /// One line for the log, in top-left screen coordinates (what the capture scripts use): control points, duration, corridor.
    public func logDescription(primaryScreenHeight h: CGFloat, corridorMargin: CGFloat = 40) -> String {
        func p(_ q: CGPoint) -> String { "\(Int(q.x.rounded())),\(Int((h - q.y).rounded()))" }
        func r(_ f: CGRect) -> String { "\(Int(f.minX.rounded())),\(Int((h - f.maxY).rounded())),\(Int(f.width.rounded())),\(Int(f.height.rounded()))" }
        let corridor = self.corridor(margin: corridorMargin).map(r).joined(separator: ";")
        return "path=\(p(start)) \(p(control1)) \(p(control2)) \(p(end)) duration=\(String(format: "%.2f", duration)) corridor=\(corridor)"
    }
}
