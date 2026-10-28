import Foundation

/// Written for Shep.
/// When the wake-word listener may hold the microphone, when it restarts, how it backs off, what the menu bar icon shows,
/// and what it may log. Pure.

public struct WakeWordConditions: Equatable, Sendable {
    public var enabled: Bool
    public var authorized: Bool
    public var onDeviceSupported: Bool
    public var pushToTalkActive: Bool
    /// A voice session or reply is going on, a fix is running, or Shep is out of its doghouse.
    public var conversationActive: Bool
    /// The Mac is asleep (not the dog: the dog sleeping in its doghouse is exactly when the wake word listens).
    public var asleep: Bool

    public init(enabled: Bool, authorized: Bool, onDeviceSupported: Bool, pushToTalkActive: Bool, conversationActive: Bool, asleep: Bool) {
        self.enabled = enabled; self.authorized = authorized; self.onDeviceSupported = onDeviceSupported
        self.pushToTalkActive = pushToTalkActive; self.conversationActive = conversationActive; self.asleep = asleep
    }
}

public enum WakeWordPolicy {
    /// A recognition task is replaced this long after it started: the recogniser ends a session at about a minute.
    public static let restartAfterSeconds: TimeInterval = 50
    /// Wait after the 1st, 2nd, 3rd... failure in a row; the last step is the cap.
    public static let backoffSeconds: [TimeInterval] = [1, 2, 5, 10, 30]
    /// After a wake, the request is over when this long has passed with no new words...
    public static let utteranceSilenceSeconds: TimeInterval = 1.5
    /// ...or, if nothing at all was heard after the wake, when this long has passed.
    public static let noSpeechGiveUpSeconds: TimeInterval = 6

    /// The only case in which the microphone is open for the wake word: the owner turned it on, both permissions are granted,
    /// the recogniser can work on the Mac (never the server), and Shep is not already being talked to or put to sleep.
    public static func shouldListen(_ c: WakeWordConditions) -> Bool {
        c.enabled && c.authorized && c.onDeviceSupported && !c.pushToTalkActive && !c.conversationActive && !c.asleep
    }

    public static func shouldRestartTask(runningFor seconds: TimeInterval) -> Bool { seconds >= restartAfterSeconds }

    public static func backoff(afterFailures count: Int) -> TimeInterval {
        backoffSeconds[min(max(count, 1), backoffSeconds.count) - 1]
    }

    public static func utteranceEnded(heardText: Bool, silentFor seconds: TimeInterval) -> Bool {
        seconds >= (heardText ? utteranceSilenceSeconds : noSpeechGiveUpSeconds)
    }

    /// A voice call (the wake word or the talk key) that comes while Shep's own window is in front (Settings, Setup) has no
    /// window to go to: Shep would wake and go straight back to sleep. The app that was in front before Shep is handed the focus
    /// back first, so the call lands on it. Returns that app's pid, or nil when nothing should change (another app is already
    /// in front, or there is no earlier app that is not Shep).
    public static func pidToRefocus(frontmostPID: Int32?, ownPID: Int32, lastOtherPID: Int32?) -> Int32? {
        guard frontmostPID == ownPID, let other = lastOtherPID, other != ownPID else { return nil }
        return other
    }
}

/// What the menu bar icon shows. Driven by whether the microphone is open (the listener's own state), so the icon cannot
/// disagree with what the engine is doing.
public struct StatusIconState: Equatable, Sendable {
    public var symbolName: String
    public var accessibilityDescription: String
    public init(symbolName: String, accessibilityDescription: String) {
        self.symbolName = symbolName; self.accessibilityDescription = accessibilityDescription
    }

    public static func forMicrophone(open: Bool) -> StatusIconState {
        open ? StatusIconState(symbolName: "mic.fill", accessibilityDescription: "Listening for Hey Shep")
             : StatusIconState(symbolName: "pawprint.fill", accessibilityDescription: "Shep")
    }
}

public enum WakeErrorKind: String, CaseIterable, Sendable {
    case microphone, engine, recognizer, authorization
}

/// The only lines the wake word may print. Every line is a constant or built from a closed enum: nothing here takes a
/// String, so what was heard cannot reach the log.
public enum WakeLog {
    public static let prefix = "[shep] wake: "
    public static let matched = prefix + "matched"
    public static let notMatched = prefix + "not matched"
    public static let listeningStarted = prefix + "listening started"
    public static let listeningStopped = prefix + "listening stopped"
    public static let unavailable = prefix + "unavailable (on-device recognition not supported)"
    /// A call came while Shep's own window was in front; the previous app was asked to come to the front (`FocusHandoff`).
    public static let handoffRequested = prefix + "Shep was in front; focus handoff requested"
    /// ... and it is confirmed in front.
    public static let handoffConfirmed = prefix + "focus handed back to the previous app"
    /// ... and it did not come to the front within `FocusHandoff.timeoutSeconds`.
    public static let handoffFailed = prefix + "focus handoff failed (timeout)"
    /// ... or another app came to the front instead: the user left, so no call is made.
    public static let handoffAbandoned = prefix + "focus handoff abandoned (another app came to the front)"
    public static func error(_ kind: WakeErrorKind) -> String { prefix + "error (\(kind.rawValue))" }
}
