import Foundation

/// Written for Shep.
/// Where Shep is in its day: asleep in the doghouse until called, then out of the door, across the screen to the tab of
/// the window in front, working there, and back home to sleep. Pure logic: no AppKit, no clock (the controller owns the
/// timers and reports what happened as events). Every transition returns the effects the controller must carry out.

public enum LifecycleState: String, CaseIterable, Equatable {
    /// In the doghouse, eyes closed. Window tracking is off.
    case asleep
    /// Eyes open, stretching out of the door. The tracker is on so a target is ready when the stretch ends.
    case waking
    /// Crossing the screen to the target.
    case traveling
    /// Docked in the tab, listening / thinking / helping.
    case working
    /// Walking back to the doghouse.
    case returning
}

/// What woke Shep. Every source ends in the same wake.
public enum CallSource: String, Equatable {
    case doghouse, menu, hotkey, pushToTalk, demo

    /// Whether the coordinator brings the previously frontmost app back before Shep looks for a window. Only the doghouse
    /// indicator: VoiceOver reaches it by bringing Shep itself to the front, and with Shep in front the press would find no
    /// window. Push-to-talk and "Hey Shep" refocus in their own call path, before listening starts; the menu, the shortcut and
    /// the demo leave the front app as it is.
    public var refocusesPreviousApp: Bool { self == .doghouse }
}

/// Written for Shep.
/// Activation is asynchronous: after a doghouse press hands focus back to the previous app, the end of the wake must not
/// decide "no window" while that app is still coming to the front. It polls every `pollSeconds` until a target appears or
/// `limitSeconds` have passed since the wake ended; a call with no refocus (or one macOS refused) decides at once. Pure.
public enum RefocusWait {
    public static let limitSeconds: TimeInterval = 1.5
    public static let pollSeconds: TimeInterval = 0.1

    /// A refocus is pending for this call: the source asks for one and `activate()` accepted the request.
    public static func requested(source: CallSource, activationAccepted: Bool) -> Bool {
        source.refocusesPreviousApp && activationAccepted
    }

    public static func keepWaiting(refocusRequested: Bool, hasTarget: Bool, waited: TimeInterval) -> Bool {
        refocusRequested && !hasTarget && waited < limitSeconds
    }
}

public enum LifecycleEvent: Equatable {
    case call(CallSource)
    /// The wake stretch is over. `hasTarget` is false when there is no window to sit on.
    case wakeFinished(hasTarget: Bool)
    /// The traveller reached the target.
    case arrived
    /// The travel could not start: the target went away between the wake and the departure.
    case arrivalFailed
    /// The traveller is back at the doghouse.
    case homeReached
    /// A request is running (listening, thinking, a card waiting): do not time out meanwhile.
    case taskStarted
    /// The request is finished: the idle clock starts.
    case taskDone
    /// Escape, "Send Shep home".
    case dismiss
    case timeout
    /// The window Shep sits on went away (closed, full screen, another Space).
    case windowLost
    case reduceMotion(Bool)
}

public enum LifecycleEffect: Equatable {
    case startTracking
    case stopTracking
    /// Open the eyes and stretch (reduced: fade the sleeping dog out).
    case beginWake(reduced: Bool)
    /// Leave the doghouse for the target (reduced: no travel, the dock fades in at the target).
    case beginTravel(reduced: Bool)
    /// Present the dock panel (the head rises out of the tab; reduced: fades in).
    case dock(reduced: Bool)
    /// Close cards and take the dock panel away.
    case undock
    /// Walk home along the arc, from wherever the dog is (reduced: fade out here, fade in at home).
    case beginReturn(reduced: Bool)
    /// Curl up in the doghouse and sleep.
    case sleep
    case armTimeout(TimeInterval)
    case cancelTimeout
    /// Shep found no window and is going home: end the voice session (capture, transcript, any submit still to come), so
    /// nothing said for this call runs after Shep has left.
    case cancelVoice
    /// Arrival failed (no window, or the trip could not start): cancel the fix task too. A final transcript can already have
    /// submitted one, and the voice session is then idle, so `.cancelVoice` alone would leave it running. Always after `.cancelVoice`.
    case cancelFixTask
}

/// Carries out `.cancelVoice` (the app's `VoiceController`).
public protocol VoiceCancelling: AnyObject {
    func cancelVoice()
}

public enum LifecycleTimings {
    /// No activity for this long while docked: go home.
    public static let idleSeconds: TimeInterval = 20
    /// After a task finishes: go home.
    public static let afterTaskSeconds: TimeInterval = 20
    /// The stretch out of the door.
    public static let wakeSeconds: TimeInterval = 0.6
    public static let reducedWakeSeconds: TimeInterval = 0.3
    /// Curling up after getting home.
    public static let enterSeconds: TimeInterval = 0.8
}

public struct ShepLifecycle: Equatable {
    public private(set) var state: LifecycleState
    public private(set) var reduceMotion: Bool
    /// A request is running, so the idle timeout is held off.
    public private(set) var busy = false

    public init(state: LifecycleState = .asleep, reduceMotion: Bool = false) {
        self.state = state
        self.reduceMotion = reduceMotion
    }

    /// Window events only matter while Shep is awake and heading for, or sitting on, a window.
    public var tracksWindows: Bool { state == .waking || state == .traveling || state == .working }
    /// The dock panel (tab and dog) is on screen.
    public var dockVisible: Bool { state == .working }
    /// The sleeping dog is in the doghouse.
    public var houseHoldsDog: Bool { state == .asleep || state == .waking }

    /// Applies an event; returns what the controller must do. Events that make no sense in the current state return [].
    @discardableResult
    public mutating func handle(_ event: LifecycleEvent) -> [LifecycleEffect] {
        if case .reduceMotion(let on) = event {
            reduceMotion = on
            return []
        }
        let reduced = reduceMotion
        // A request can start before Shep has arrived (push-to-talk from the doghouse): the idle clock then stays off until it is done.
        switch event {
        case .taskStarted where state == .waking || state == .traveling:
            busy = true
            return []
        case .taskDone where state == .waking || state == .traveling || state == .returning:
            busy = false
            return []
        default:
            break
        }
        switch state {
        case .asleep:
            guard case .call = event else { return [] }
            state = .waking
            return [.startTracking, .beginWake(reduced: reduced)]

        case .waking:
            switch event {
            case .wakeFinished(let hasTarget):
                if hasTarget {
                    state = .traveling
                    return [.beginTravel(reduced: reduced)]
                }
                state = .asleep
                return [.cancelVoice, .cancelFixTask, .stopTracking, .sleep]
            case .dismiss:
                state = .asleep
                return [.stopTracking, .sleep]
            default:
                return []
            }

        case .traveling:
            switch event {
            case .arrived:
                state = .working
                return busy ? [.dock(reduced: reduced)] : [.dock(reduced: reduced), .armTimeout(LifecycleTimings.idleSeconds)]
            case .arrivalFailed:
                state = .returning
                return [.cancelVoice, .cancelFixTask, .stopTracking, .beginReturn(reduced: reduced)]
            case .dismiss, .windowLost:
                state = .returning
                return [.stopTracking, .beginReturn(reduced: reduced)]
            default:
                return []
            }

        case .working:
            switch event {
            case .call:
                return busy ? [] : [.armTimeout(LifecycleTimings.idleSeconds)]
            case .taskStarted:
                busy = true
                return [.cancelTimeout]
            case .taskDone:
                busy = false
                return [.armTimeout(LifecycleTimings.afterTaskSeconds)]
            case .dismiss, .windowLost:
                return leaveWork(reduced: reduced)
            case .timeout:
                return busy ? [] : leaveWork(reduced: reduced)
            default:
                return []
            }

        case .returning:
            switch event {
            case .homeReached:
                state = .asleep
                busy = false
                return [.sleep]
            case .call:
                // Called again on the way home: turn around.
                state = .traveling
                return [.startTracking, .beginTravel(reduced: reduced)]
            default:
                return []
            }
        }
    }

    private mutating func leaveWork(reduced: Bool) -> [LifecycleEffect] {
        state = .returning
        busy = false
        return [.cancelTimeout, .stopTracking, .undock, .beginReturn(reduced: reduced)]
    }
}

/// What the doghouse page is showing; the page's own loop rate follows from it.
public enum HouseMode: String, CaseIterable, Equatable {
    /// Dog inside, eyes closed, breathing, a small "z" floating.
    case asleep
    /// Dog inside, eyes open, stretching toward the door.
    case waking
    /// Empty house: the dog is out.
    case away
    /// The dog is back, curling up (then it is `asleep`).
    case entering

    public static func mode(for state: LifecycleState) -> HouseMode {
        switch state {
        case .asleep: return .asleep
        case .waking: return .waking
        case .traveling, .working, .returning: return .away
        }
    }
}

/// Frames per second by state. The house page mirrors the `house` numbers (tools/shep-dog/src/house.ts); the travel
/// page runs at 60 only while a travel is in flight.
public enum LifecycleFramePolicy {
    /// Slow breathing needs very little.
    public static let asleepFPS = 8
    public static let wakeFPS = 30
    public static let travelFPS = 60
    public static let calmFPS = 15

    /// The doghouse page. 0 = no frame is scheduled (a change renders one frame by itself).
    public static func houseFramesPerSecond(mode: HouseMode, reduceMotion: Bool, active: Bool) -> Int {
        guard active else { return 0 }
        switch mode {
        case .away: return 0
        case .asleep: return reduceMotion ? 0 : asleepFPS   // Reduce Motion: closed eyes, a still "z", nothing moves
        case .waking, .entering: return reduceMotion ? calmFPS : wakeFPS
        }
    }

    /// The traveller page, while it exists.
    public static func travelFramesPerSecond(reduceMotion: Bool, active: Bool) -> Int {
        guard active else { return 0 }
        return reduceMotion ? calmFPS : travelFPS
    }

    /// The dock page keeps its own policy.
    public static func dockFramesPerSecond(dock: DogMotionState, reduceMotion: Bool, active: Bool) -> Int {
        FramePolicy.framesPerSecond(state: dock, reduceMotion: reduceMotion, active: active)
    }
}

/// The timed `--demo-script=cycle` run (scripts/record-cycle.sh): asleep 3 s, call, travel to the Shep test window's tab,
/// work (listening 2 s, thinking 2 s), dismiss, walk home, asleep 3 s. Steps are offsets in seconds from the start.
public enum CycleAction: Equatable {
    case call
    case listen
    case think
    /// The fix is done: the finish pose (ears up), later the finish beat (hop and woof).
    case finish
    case dismiss
}

public struct CycleStep: Equatable {
    public var at: TimeInterval
    public var action: CycleAction
}

public enum CycleScript {
    public static let asleepBefore: TimeInterval = 3
    public static let listenSeconds: TimeInterval = 2
    public static let thinkSeconds: TimeInterval = 2
    /// The finish pose is held this long before Shep is sent home.
    public static let finishSeconds: TimeInterval = 2.0
    public static let asleepAfter: TimeInterval = 3
    /// Longest the wake (stretch), the travel and the dock's rise can take: the work starts after this.
    public static var settleSeconds: TimeInterval {
        LifecycleTimings.wakeSeconds + TravelPath.maxDuration + DogMotionMachine.dockDuration + 0.3
    }
    /// Longest the walk home and the curl-up can take.
    public static var homeSeconds: TimeInterval { TravelPath.maxDuration + LifecycleTimings.enterSeconds + 0.3 }

    public static var steps: [CycleStep] {
        let call = asleepBefore
        let listen = call + settleSeconds
        let think = listen + listenSeconds
        let finish = think + thinkSeconds
        let dismiss = finish + finishSeconds
        return [CycleStep(at: call, action: .call), CycleStep(at: listen, action: .listen),
                CycleStep(at: think, action: .think), CycleStep(at: finish, action: .finish),
                CycleStep(at: dismiss, action: .dismiss)]
    }

    /// When everything is over: asleep again for `asleepAfter` seconds.
    public static var duration: TimeInterval {
        (steps.last?.at ?? 0) + homeSeconds + asleepAfter
    }

    public static var isWellFormed: Bool {
        var last = -1.0
        for step in steps {
            if step.at < last || step.at > duration { return false }
            last = step.at
        }
        return true
    }
}
