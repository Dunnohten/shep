import Foundation

/// Written for Shep.
/// A voice call made while Shep's own window is in front (Settings, Setup) gives the focus back to the app that was in front
/// before, and waits for it: activation is asynchronous, and the wake stretch (0.6 s, 0.3 s with Reduce Motion) checks for a
/// window to sit on only once. So the call is made after the previous app is confirmed in front (and the tracker has looked
/// again), or after a bounded wait, whichever comes first. Only a confirmation is logged as "handed back". Pure: the app
/// feeds in what it sees (activation notes and a short poll of the front app) with the time since the request.

public enum FocusHandoffOutcome: String, Equatable, Sendable {
    case confirmed, timedOut
    /// Another app (not the target, not Shep) came to the front: the user left, and no call is made.
    case abandoned
}

public enum FocusHandoffEffect: Equatable, Sendable {
    case log(String)
    /// Ask the app with this pid to come to the front.
    case activate(Int32)
    /// Look at the front window again now, so the dock check sees the app that was just activated.
    case refreshTracker
    /// Wake Shep (`ShepCoordinator.call`).
    case call
    /// The handoff was abandoned: end the voice session that was opened for this call (`VoiceController.cancel`).
    case cancelVoice
}

public struct FocusHandoff: Equatable, Sendable {
    /// The longest Shep waits for the previous app to come to the front. Longer than the wake stretch, short enough not to
    /// feel stuck; on timeout the call is made anyway (and ends at "no window" if Shep is still in front).
    public static let timeoutSeconds: TimeInterval = 1.0
    public let pid: Int32
    /// Shep's own pid: it is in front when the handoff starts, and being in front is not leaving.
    public let ownPID: Int32
    public private(set) var outcome: FocusHandoffOutcome?

    public init(pid: Int32, ownPID: Int32) {
        self.pid = pid
        self.ownPID = ownPID
    }

    public mutating func start() -> [FocusHandoffEffect] {
        [.log(WakeLog.handoffRequested), .activate(pid)]
    }

    /// One look at the front app, read at the moment of the look (never taken from an activation note, which may be stale),
    /// `elapsed` seconds after `start`. Returns the effects once, when the outcome is known. Only the target in front confirms;
    /// a third app in front is the user leaving, at any time including the timeout, and nothing is called.
    public mutating func observe(frontmostPID: Int32?, elapsed: TimeInterval) -> [FocusHandoffEffect] {
        guard outcome == nil else { return [] }
        if frontmostPID == pid {
            outcome = .confirmed
            return [.log(WakeLog.handoffConfirmed), .refreshTracker, .call]
        }
        if let front = frontmostPID, front != ownPID {
            outcome = .abandoned
            return [.log(WakeLog.handoffAbandoned), .cancelVoice]
        }
        guard elapsed >= Self.timeoutSeconds else { return [] }
        outcome = .timedOut
        return [.log(WakeLog.handoffFailed), .call]
    }
}
