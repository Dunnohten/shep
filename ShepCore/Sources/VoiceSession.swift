import Foundation

/// Written for Shep.
/// Push-to-talk as a state machine: the key goes down, audio is captured and recognised while it is held, partial text
/// shows in the pill, and on release the final text becomes the request. Pure: no audio, no recogniser, no clock; the app
/// feeds events in and carries out the effects. Replies are spoken by the app (interruptible, can be muted).

public enum VoicePermission: String, Equatable, Sendable {
    case microphone = "Microphone"
    case speech = "Speech Recognition"
}

public enum VoiceState: Equatable, Sendable {
    case idle
    /// The key is held and audio is being recognised.
    case listening
    /// The key came up; waiting for the recogniser's final text.
    case finishing
}

public enum VoiceEvent: Equatable, Sendable {
    /// The talk key went down (held long enough), with the two permission states at that moment.
    case press(microphone: PermissionState, speech: PermissionState)
    /// Partial or revised text from the recogniser.
    case partial(String)
    /// The recogniser's final text (possibly empty).
    case final(String)
    /// The talk key came up.
    case release
    /// The key was held too long, or the final text never came.
    case timeout
    /// Something else happened while held (another key, focus lost): throw the audio away.
    case cancel
    /// The recogniser or the audio engine failed.
    case failed(String)
    case speechStarted
    case speechEnded
}

public enum VoiceEffect: Equatable, Sendable {
    case startCapture
    /// Stop the audio and ask the recogniser to finish; its final text arrives as `.final`.
    case stopCapture
    /// Stop the audio and drop whatever the recogniser has.
    case cancelCapture
    case showPartial(String)
    case clearPartial
    case dogListening
    case dogIdle
    /// The request: hand it to Fix This Screen. The dog goes to "thinking" while that runs.
    case submit(String)
    case say(String)
    case requestPermissions([VoicePermission])
    case showSetup
    case stopSpeaking
    case armTimeout(TimeInterval)
    case cancelTimeout
}

public enum VoiceTimings {
    /// A key held this long is let go for the person: the recogniser has a limit too.
    public static let maxHoldSeconds: TimeInterval = 30
    /// After release, how long to wait for the final text before using the last partial.
    public static let finalWaitSeconds: TimeInterval = 2
    /// The recording aid's wait (`DemoVoiceInput`): its final text comes once the file has played and whisper-cli is done.
    public static let demoFinalWaitSeconds: TimeInterval = 20
    /// The most text that becomes a request.
    public static let maxRequestCharacters = 500
}

public struct VoiceSession: Equatable, Sendable {
    public private(set) var state: VoiceState = .idle
    /// The latest text heard in this session.
    public private(set) var transcript = ""
    public private(set) var speaking = false

    /// How long the session waits for the final text after the key comes up.
    public var finalWaitSeconds: TimeInterval = VoiceTimings.finalWaitSeconds

    public init() {}

    @discardableResult
    public mutating func handle(_ event: VoiceEvent) -> [VoiceEffect] {
        switch event {
        case .speechStarted:
            speaking = true
            return []
        case .speechEnded:
            speaking = false
            return []
        case .press(let mic, let speech):
            return press(mic: mic, speech: speech)
        case .partial(let text):
            guard state != .idle else { return [] }
            transcript = Self.clean(text)
            return [.showPartial(transcript)]
        case .release:
            guard state == .listening else { return [] }
            return beginFinishing()
        case .timeout:
            switch state {
            case .listening: return beginFinishing()
            case .finishing: return finish(with: transcript)
            case .idle: return []
            }
        case .final(let text):
            guard state != .idle else { return [] }
            let heard = Self.clean(text)
            return finish(with: heard.isEmpty ? transcript : heard)
        case .cancel:
            guard state != .idle else { return [] }
            return drop([])
        case .failed(let why):
            guard state != .idle else { return [] }
            if state == .finishing, !transcript.isEmpty { return finish(with: transcript) }
            return drop([.say("I couldn\u{2019}t listen: \(String(why.prefix(120)))")])
        }
    }

    private mutating func press(mic: PermissionState, speech: PermissionState) -> [VoiceEffect] {
        var effects: [VoiceEffect] = []
        if speaking { effects.append(.stopSpeaking); speaking = false }
        if state != .idle { effects += [.cancelCapture, .cancelTimeout] }   // a new press while the last one is finishing
        transcript = ""
        // Both permissions are needed. Ask for the ones never asked; point at Setup for the ones refused.
        var missing: [VoicePermission] = []
        var refused: [VoicePermission] = []
        for (permission, s) in [(VoicePermission.microphone, mic), (VoicePermission.speech, speech)] {
            switch s {
            case .granted: break
            case .notDetermined: missing.append(permission)
            case .denied, .restricted: refused.append(permission)
            }
        }
        if !refused.isEmpty {
            state = .idle
            let names = refused.map(\.rawValue).joined(separator: " and ")
            let verb = refused.count > 1 ? "are" : "is"
            return effects + [.clearPartial, .dogIdle, .say("\(names) \(verb) off for Shep. Turn it on in Setup to talk to me."), .showSetup]
        }
        if !missing.isEmpty {
            state = .idle
            return effects + [.clearPartial, .dogIdle, .requestPermissions(missing), .say("Allow the prompt, then hold the key again.")]
        }
        state = .listening
        return effects + [.dogListening, .startCapture, .armTimeout(VoiceTimings.maxHoldSeconds)]
    }

    private mutating func beginFinishing() -> [VoiceEffect] {
        state = .finishing
        return [.cancelTimeout, .stopCapture, .armTimeout(finalWaitSeconds)]
    }

    /// Ends the session with `text` as the request, or with an apology when there is nothing.
    private mutating func finish(with text: String) -> [VoiceEffect] {
        let wasListening = state == .listening
        state = .idle
        transcript = ""
        var effects: [VoiceEffect] = [.cancelTimeout]
        if wasListening { effects.append(.stopCapture) }   // the recogniser ended by itself while the key was still down
        effects.append(.clearPartial)
        if text.isEmpty {
            effects += [.dogIdle, .say("I didn\u{2019}t catch that.")]
        } else {
            effects.append(.submit(text))
        }
        return effects
    }

    private mutating func drop(_ extra: [VoiceEffect]) -> [VoiceEffect] {
        state = .idle
        transcript = ""
        return [.cancelTimeout, .cancelCapture, .clearPartial, .dogIdle] + extra
    }

    static func clean(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(VoiceTimings.maxRequestCharacters))
    }
}

/// Whether a reply is spoken aloud.
public enum VoiceReplyPolicy {
    /// Replies are spoken when the owner wants them, unless VoiceOver is running (it announces every reply already, and two
    /// voices at once help nobody).
    public static func shouldSpeak(text: String, enabled: Bool, voiceOverRunning: Bool) -> Bool {
        enabled && !voiceOverRunning && !utterance(text).isEmpty
    }

    /// What is actually said: one line, no more than 400 characters.
    public static func utterance(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(400))
    }
}
