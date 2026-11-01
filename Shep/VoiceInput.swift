import AVFoundation
import Foundation
import ShepCore
import Speech

// Written for Shep.

enum VoiceInputError: LocalizedError {
    case unavailable
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .unavailable: return "speech recognition is not available right now"
        case .noMicrophone: return "no microphone input"
        }
    }
}

/// One speech recognition run at a time: the microphone through an AVAudioEngine tap into an SFSpeechRecognizer request.
/// On-device recognition is required whenever the recogniser supports it, so audio stays on the Mac.
/// The audio tap and the recogniser callback run on other threads; both are set up in nonisolated helpers and hop to the
/// main actor with a generation number, so a result from a run that was cancelled is dropped.
@MainActor
final class VoiceInput {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private(set) var isRunning = false

    func start() throws {
        cancel()
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { throw VoiceInputError.unavailable }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceInputError.noMicrophone }
        Self.installTap(on: input, format: format, request: req)
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        generation += 1
        let mine = generation
        request = req
        isRunning = true
        task = Self.startTask(recognizer: recognizer, request: req) { [weak self] text, isFinal, failure in
            Task { @MainActor in self?.deliver(generation: mine, text: text, isFinal: isFinal, failure: failure) }
        }
    }

    /// The key came up: stop the microphone and let the recogniser finish; its final text arrives through `onFinal`.
    func stop() {
        guard isRunning else { return }
        stopEngine()
        request?.endAudio()
    }

    /// Drop the run: nothing more is delivered for it.
    func cancel() {
        generation += 1
        stopEngine()
        task?.cancel()
        task = nil
        request = nil
        isRunning = false
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func deliver(generation g: Int, text: String?, isFinal: Bool, failure: String?) {
        guard g == generation else { return }
        if isFinal {
            finishRun()
            onFinal?(text ?? "")
        } else if let failure {
            finishRun()
            onFailure?(failure)
        } else if let text, !text.isEmpty {
            onPartial?(text)
        }
    }

    private func finishRun() {
        stopEngine()
        task = nil
        request = nil
        isRunning = false
        generation += 1   // anything else this run reports is stale
    }

    // The tap and the result handler are formed outside the main actor: they run on audio and recogniser threads.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func startTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              report: @escaping @Sendable (String?, Bool, String?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            // 1110 is "no speech detected": a finished run with nothing in it, not a failure.
            let noSpeech = (error as NSError?)?.code == 1110
            report(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || noSpeech, noSpeech ? nil : error?.localizedDescription)
        }
    }
}

/// Speaks replies with the system voice. Interruptible (`stop()`), and reports when it starts and ends so a new press can cut it off.
@MainActor
final class ReplySpeaker: NSObject, AVSpeechSynthesizerDelegate {
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// True from `speak` until the utterance finishes or is cancelled (set at once, not when the delegate hears it start).
    var isSpeaking: Bool { !pending.isEmpty }
    /// The utterances spoken and not yet finished. A late callback for one dropped by `stop()` finds nothing to remove.
    /// Held strongly, so an identity can never be reused while it is listed.
    private var pending: [AVSpeechUtterance] = []

    /// The newest reply replaces any still playing ("On it." never delays "Done.", so the finish wait covers the line it
    /// is waiting for). Speech is continuous across the swap: `onEnd` is not reported for the dropped line, and its late
    /// cancel callback finds nothing in `pending`.
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: VoiceReplyPolicy.utterance(text))
        if !pending.isEmpty {
            pending.removeAll()
            synthesizer.stopSpeaking(at: .immediate)
        }
        pending.append(utterance)
        synthesizer.speak(utterance)   // no voice set: the system voice
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let wasSpeaking = !pending.isEmpty
        pending.removeAll()
        if wasSpeaking { onEnd?() }   // reported here, once: the late callbacks for these utterances are ignored
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.pending.contains(where: { $0 === utterance }) else { return }   // dropped by stop() before this arrived
            self.onStart?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance) }
    }

    private func ended(_ utterance: AVSpeechUtterance) {
        guard pending.contains(where: { $0 === utterance }) else { return }   // dropped by stop(): already reported
        pending.removeAll { $0 === utterance }
        if pending.isEmpty { onEnd?() }   // the end of speech, not of one queued utterance while another still plays
    }
}
