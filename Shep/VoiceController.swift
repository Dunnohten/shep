import AppKit
import ShepCore

// Written for Shep.

/// Push-to-talk end to end: the talk key drives a `VoiceSession` (ShepCore), whose effects start and stop the recogniser,
/// show the partial text in the pill, hand the final text to Fix This Screen as the request, and speak replies.
@MainActor
final class VoiceController: VoiceCancelling {
    /// The final transcript, as the request.
    var onSubmit: ((String) -> Void)?
    /// The Setup window (Microphone and Speech Recognition rows live there).
    var showSetup: (() -> Void)?
    /// Whether replies are spoken (Settings). Defaults to on.
    var speakReplies: () -> Bool = { true }

    private var session = VoiceSession()
    private let input = VoiceInput()
    /// The recording aid (Debug builds, SHEP_DEMO_* set): a voice file and a local whisper-cli instead of the microphone. Nil normally.
    private let demoInput: DemoVoiceInput? = DemoVoiceInput.fromEnvironment().map { DemoVoiceInput(config: $0) }
    private let speaker = ReplySpeaker()
    private let permissions: PermissionModel
    private unowned let overlay: OverlayController
    private var timeoutWork: DispatchWorkItem?
    /// Something changed in whether a talk session or a spoken reply is going on (the wake-word listener watches this).
    var onActivityChange: (() -> Void)?
    /// A call that started from "Hey Shep" has no key to let go of: it ends when the speaker stops (`WakeWordPolicy`).
    private var endOnSilence = false
    private var heardText = false
    private var lastHeard: TimeInterval = 0

    init(permissions: PermissionModel, overlay: OverlayController) {
        self.permissions = permissions
        self.overlay = overlay
        input.onPartial = { [weak self] text in self?.send(.partial(text)) }
        input.onFinal = { [weak self] text in self?.send(.final(text)) }
        input.onFailure = { [weak self] message in self?.send(.failed(message)) }
        demoInput?.onPartial = { [weak self] text in self?.send(.partial(text)) }
        demoInput?.onFinal = { [weak self] text in self?.send(.final(text)) }
        demoInput?.onFailure = { [weak self] message in self?.send(.failed(message)) }
        if demoInput != nil { session.finalWaitSeconds = VoiceTimings.demoFinalWaitSeconds }
        speaker.onStart = { [weak self] in self?.send(.speechStarted) }
        speaker.onEnd = { [weak self] in self?.send(.speechEnded) }
    }

    // MARK: the talk key

    /// A talk session is open, or a reply is being spoken.
    var isActive: Bool { session.state != .idle || session.speaking }

    /// The same entry as the talk key. `endOnSilence` is for a call started by the wake word, where no key is held.
    func press(endOnSilence: Bool = false) {
        if demoInput != nil {
            // The demo voice uses neither the microphone nor Speech Recognition: nothing to check, nothing to ask for.
            send(.press(microphone: .granted, speech: .granted))
        } else {
            permissions.refresh()
            send(.press(microphone: permissions.microphoneState, speech: permissions.speechState))
        }
        if endOnSilence, session.state == .listening {
            self.endOnSilence = true
            heardText = false
            lastHeard = ProcessInfo.processInfo.systemUptime
            pollSilence()
        }
    }

    func release() { send(.release) }
    func cancel() { send(.cancel) }
    /// Shep found no window and went home (`LifecycleEffect.cancelVoice`).
    func cancelVoice() { cancel() }

    // MARK: replies

    /// Called for everything Shep says on its card.
    func reply(_ text: String) {
        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        guard VoiceReplyPolicy.shouldSpeak(text: text, enabled: speakReplies(), voiceOverRunning: voiceOver) else { return }
        speaker.speak(text)
    }

    /// A reply is being spoken right now (the finish bark waits for it).
    var isSpeakingReply: Bool { speaker.isSpeaking }

    /// Silence now: the mute toggle, and Shep going home (ShepCoordinator.onStopSpeaking: sendHome, any dismiss, undock).
    func stopSpeaking() { speaker.stop() }

    // MARK: effects

    private func send(_ event: VoiceEvent) {
        if case .partial(let text) = event, !text.isEmpty {
            heardText = true
            lastHeard = ProcessInfo.processInfo.systemUptime
        }
        let effects = session.handle(event)
        // Shep keeps its VoiceOver announcements back while the question is being asked (until the final transcript).
        overlay.setCallerSpeaking(session.state != .idle)
        for effect in effects { perform(effect) }
        onActivityChange?()
    }

    /// Releases a wake-word call when the speaker has stopped (the same `release` the talk key sends).
    private func pollSilence() {
        guard endOnSilence, session.state == .listening else { endOnSilence = false; return }
        let silent = ProcessInfo.processInfo.systemUptime - lastHeard
        if WakeWordPolicy.utteranceEnded(heardText: heardText, silentFor: silent) {
            endOnSilence = false
            release()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in MainActor.assumeIsolated { self?.pollSilence() } }
    }

    private func perform(_ effect: VoiceEffect) {
        switch effect {
        case .startCapture:
            do {
                if let demo = demoInput { try demo.start() } else { try input.start() }
            } catch { send(.failed(error.localizedDescription)) }
        case .stopCapture:
            if let demo = demoInput { demo.stop() } else { input.stop() }
        case .cancelCapture:
            if let demo = demoInput { demo.cancel() } else { input.cancel() }
        case .showPartial(let text):
            overlay.showTranscript(text)
        case .clearPartial:
            overlay.clearTranscript()
        case .dogListening:
            overlay.setState(.listening)
        case .dogIdle:
            overlay.setState(.idle)
        case .submit(let text):
            onSubmit?(text)   // the pipeline sets the dog to thinking
        case .say(let text):
            overlay.say(text)
        case .requestPermissions(let list):
            for p in list {
                switch p {
                case .microphone: permissions.requestMicrophone()
                case .speech: permissions.requestSpeech()
                }
            }
        case .showSetup:
            showSetup?()
        case .stopSpeaking:
            speaker.stop()
        case .armTimeout(let seconds):
            timeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.send(.timeout) } }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        case .cancelTimeout:
            timeoutWork?.cancel()
            timeoutWork = nil
        }
    }
}
