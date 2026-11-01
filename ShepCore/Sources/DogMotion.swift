import CoreGraphics
import Foundation

/// Written for Shep.
/// The dog's motion state machine, the frame-rate policy and the activity rule. Pure logic, no AppKit, no clock of its
/// own (callers pass `now` in seconds). The dog page (tools/shep-dog/src/motion.ts) mirrors the same rules, driven by
/// the same names through `shep.setState(name)`; the two are kept in step by tests on both sides.

public enum DogMotionState: String, CaseIterable, Equatable {
    case idle, docking, listening, thinking, speaking, dragging, hidden
}

/// Raw values are the event names the dog page's `shep.send(name)` takes.
public enum DogMotionEvent: String, Equatable {
    /// The tab (re)appeared or jumped: the head rises out of it.
    case dock
    case rest, listen, think, speak
    case dragBegan, dragEnded
    case hide, show
}

public struct DogMotionMachine: Equatable {
    /// Rise out of the tab (spring with overshoot), seconds. Reduce Motion: a plain fade.
    public static let dockDuration: TimeInterval = 0.9
    public static let reducedDockDuration: TimeInterval = 0.35
    /// Spring back after a drag, seconds.
    public static let snapBackDuration: TimeInterval = 0.8

    public private(set) var state: DogMotionState
    /// What the dog returns to once docking or a drag is over.
    public private(set) var resting: DogMotionState
    public private(set) var reduceMotion: Bool
    /// When the current timed state (docking) ends; nil when the state is not timed.
    public private(set) var endsAt: TimeInterval?

    public init(state: DogMotionState = .idle, reduceMotion: Bool = false) {
        self.state = state
        self.resting = (state == .idle || state == .listening || state == .thinking || state == .speaking) ? state : .idle
        self.reduceMotion = reduceMotion
        self.endsAt = nil
    }

    /// True while a spring is running: the frame rate goes up for it.
    public var isSpringing: Bool { !reduceMotion && (state == .docking || state == .dragging) }

    public mutating func setReduceMotion(_ on: Bool) {
        reduceMotion = on
    }

    public mutating func send(_ event: DogMotionEvent, at now: TimeInterval) {
        switch event {
        case .hide:
            state = .hidden
            endsAt = nil
        case .show:
            if state == .hidden { beginDocking(at: now, duration: dockLength) }
        case .dock:
            if state != .hidden { beginDocking(at: now, duration: dockLength) }
        case .rest, .listen, .think, .speak:
            let target = Self.resting(for: event)
            resting = target
            // Docking and dragging finish first; a hidden dog stays hidden. The new state shows when they end.
            if state != .hidden && state != .docking && state != .dragging {
                state = target
                endsAt = nil
            }
        case .dragBegan:
            if state != .hidden && state != .dragging {
                state = .dragging
                endsAt = nil
            }
        case .dragEnded:
            if state == .dragging {
                if reduceMotion {
                    state = resting
                    endsAt = nil
                } else {
                    beginDocking(at: now, duration: Self.snapBackDuration)
                }
            }
        }
    }

    /// Ends timed states. Call it when `endsAt` has passed (or often; it is cheap).
    public mutating func tick(at now: TimeInterval) {
        if state == .docking, let end = endsAt, now >= end {
            state = resting
            endsAt = nil
        }
    }

    private var dockLength: TimeInterval { reduceMotion ? Self.reducedDockDuration : Self.dockDuration }

    private mutating func beginDocking(at now: TimeInterval, duration: TimeInterval) {
        state = .docking
        endsAt = now + duration
    }

    static func resting(for event: DogMotionEvent) -> DogMotionState {
        switch event {
        case .listen: return .listening
        case .think: return .thinking
        case .speak: return .speaking
        default: return .idle
        }
    }
}

/// Whether the page should be animating at all: not while the panel is hidden, fully covered, or the screen sleeps.
public struct DogActivity: Equatable {
    public var panelVisible: Bool
    public var occluded: Bool
    public var screenAsleep: Bool

    public init(panelVisible: Bool = true, occluded: Bool = false, screenAsleep: Bool = false) {
        self.panelVisible = panelVisible; self.occluded = occluded; self.screenAsleep = screenAsleep
    }

    public var isActive: Bool { panelVisible && !occluded && !screenAsleep }
}

public enum FramePolicy {
    public static let idleFPS = 30
    public static let springFPS = 60
    /// Reduce Motion: blinks and fades only, so a low rate is plenty.
    public static let calmFPS = 15

    /// 0 means the loop is paused (no frame is scheduled at all).
    public static func framesPerSecond(state: DogMotionState, reduceMotion: Bool, active: Bool) -> Int {
        guard active, state != .hidden else { return 0 }
        if reduceMotion { return state == .docking ? idleFPS : calmFPS }
        return (state == .docking || state == .dragging) ? springFPS : idleFPS
    }
}

/// How the dog moves when the tab goes to a new place.
public enum DockMove: Equatable {
    /// Nothing to do.
    case none
    /// A small move of a window the dog was already on: slide, no teleport.
    case slide(duration: TimeInterval)
    /// A new window, a screen change, a big jump or a size change: jump the panel, the head rises out of the tab again.
    case rise
}

public enum DockMotionPlanner {
    /// Moves up to this many points (either axis, Euclidean) slide; further ones jump.
    public static let slideLimit: CGFloat = 160
    public static let slideSeconds: TimeInterval = 0.22

    public static func plan(from old: CGRect?, to new: CGRect?, sameWindow: Bool, reduceMotion: Bool) -> DockMove {
        guard let new = new else { return .none }
        guard let old = old else { return .rise }   // first appearance: rise out of the tab
        if old == new { return .none }
        let sizeChanged = abs(old.width - new.width) > 0.5 || abs(old.height - new.height) > 0.5
        let dx = new.minX - old.minX, dy = new.minY - old.minY
        let distance = (dx * dx + dy * dy).squareRoot()
        if !sameWindow || sizeChanged || distance > slideLimit { return .rise }
        return reduceMotion ? .none : .slide(duration: slideSeconds)   // calm: no animation, the panel just moves
    }
}

/// The timed `--demo-script` run (scripts/record-demo.sh): dock, idle, blink, listening, thinking, a programmatic drag
/// out and snap-back, idle. Steps are offsets in seconds from the start of the script.
public enum DemoAction: Equatable {
    case dock
    case rest
    case blink
    case listen
    case think
    case dragTo(dx: Double, dy: Double)   // head pulled to this offset (points, web coordinates)
    case dragEnd
}

public struct DemoStep: Equatable {
    public var at: TimeInterval
    public var action: DemoAction
}

public enum DemoScript {
    public static let steps: [DemoStep] = {
        var s: [DemoStep] = [
            DemoStep(at: 0, action: .dock),
            DemoStep(at: 1.5, action: .rest),
            DemoStep(at: 4.5, action: .blink),     // after 3 s of idle
            DemoStep(at: 5.5, action: .listen),
            DemoStep(at: 8.0, action: .think),     // listening 2.5 s
        ]
        // Thinking 2.5 s (8.0 ... 10.5), then a drag out over 1.2 s in 12 steps, held 0.3 s, released.
        for i in 1...12 {
            let k = Double(i) / 12
            s.append(DemoStep(at: 10.5 + 1.2 * k, action: .dragTo(dx: 26 * k, dy: -22 * k)))
        }
        s.append(DemoStep(at: 12.0, action: .dragEnd))
        s.append(DemoStep(at: 12.1, action: .rest))
        return s
    }()

    /// When the whole sequence is done, including the snap-back and a last idle stretch for the recording.
    public static let duration: TimeInterval = 14

    /// Order and bounds check, used by the tests and by the runner before it schedules anything.
    public static var isWellFormed: Bool {
        var last = -1.0
        for step in steps {
            if step.at < last || step.at > duration { return false }
            last = step.at
        }
        return true
    }
}

extension ShepDogState {
    /// The machine event behind a dog state (the menu and the pipeline still speak in `ShepDogState`).
    public var motionEvent: DogMotionEvent {
        switch self {
        case .thinking: return .think
        case .listening: return .listen
        case .talking: return .speak
        case .idle, .lookLeft, .lookRight, .sleeping: return .rest
        }
    }
}

/// Eye tracking: where the pointer is relative to the dog, as the -1...1 pair the page takes.
public enum DogGaze {
    /// Points from the dog over which the gaze goes from centred to full.
    public static let range: CGFloat = 300

    /// Cocoa screen coordinates (y up). Result y is page-style: -1 looks up, 1 looks down.
    public static func normalised(pointer: CGPoint, dogCenter: CGPoint) -> (x: Double, y: Double) {
        guard pointer.x.isFinite, pointer.y.isFinite, dogCenter.x.isFinite, dogCenter.y.isFinite else { return (0, 0) }
        func clamp(_ v: CGFloat) -> Double { Double(max(-1, min(1, v))) }
        return (clamp((pointer.x - dogCenter.x) / range), clamp(-(pointer.y - dogCenter.y) / range))
    }
}
