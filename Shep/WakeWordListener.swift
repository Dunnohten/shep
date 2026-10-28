import AVFoundation
import Foundation
import ShepCore
import Speech

// Written for Shep.

/// Holds the latest recognition request for the audio tap. The tap runs on the audio thread; swapping the request here lets
/// the recognition task be replaced without stopping the engine.
final class WakeRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }
}

/// Listens for "Hey Shep" with the microphone open, only while `setListening(true)` is in force. Recognition is on-device
/// always: if the recogniser cannot do that here, nothing is opened and nothing falls back to a server. Audio goes from the
/// tap to the recogniser and nowhere else (never to disk); the transcript is read by `WakeWordDetector` and dropped, and only
/// the fixed `WakeLog` lines are printed. The decision of when to listen is `WakeWordPolicy`'s; this class carries it out.
///
/// A recognition task is replaced every `WakeWordPolicy.restartAfterSeconds` (the recogniser stops at about a minute) and when
/// it ends; errors back off (`WakeWordPolicy.backoff`); a configuration change of the audio engine rebuilds the run. The menu bar
/// icon follows `isMicOpen`, which changes in exactly one place (`setMic`), next to the engine start and stop.
@MainActor
final class WakeWordListener {
    /// "Hey Shep" was heard. The microphone is already closed when this runs.
    var onWake: (() -> Void)?
    /// The microphone opened or closed for the wake word (drives the menu bar icon).
    var onMicrophoneChange: ((Bool) -> Void)?
    var log: (String) -> Void = { print($0) }

    private(set) var isMicOpen = false

    private let engine = AVAudioEngine()
    private let box = WakeRequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var detector = WakeWordDetector()
    private var taskStartedAt: TimeInterval = 0
    private var wanted = false
    private var failures = 0
    private var restartWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?
    private var loggedUnavailable = false

    private static func makeRecognizer() -> SFSpeechRecognizer? { SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer() }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Whether the recogniser can work on this Mac without a server. Asked fresh each time (it depends on the language).
    var onDeviceSupported: Bool { Self.makeRecognizer()?.supportsOnDeviceRecognition ?? false }

    /// The one entry: listen or do not. Safe to call again with the same value.
    func setListening(_ want: Bool) {
        if want {
            guard !wanted else { return }
            wanted = true
            failures = 0
            begin()
        } else {
            loggedUnavailable = false
            guard wanted else { return }
            wanted = false
            retryWork?.cancel()
            retryWork = nil
            stopRun()
        }
    }

    /// Says once (until the next time listening is turned off) that on-device recognition is not supported.
    func reportUnavailable() {
        guard !loggedUnavailable else { return }
        loggedUnavailable = true
        log(WakeLog.unavailable)
    }

    /// Asks for Speech Recognition and then Microphone, in that order; `done(nil)` when both are allowed, else a sentence for Settings.
    static func requestAuthorization(_ done: @escaping @MainActor (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                Task { @MainActor in done("Speech Recognition is off for Shep. Allow it in System Settings > Privacy & Security > Speech Recognition, then turn this on again.") }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    done(granted ? nil : "Microphone is off for Shep. Allow it in System Settings > Privacy & Security > Microphone, then turn this on again.")
                }
            }
        }
    }

    // MARK: running

    private func begin() {
        guard wanted, !isMicOpen else { return }
        retryWork?.cancel()
        retryWork = nil
        guard let recognizer = Self.makeRecognizer(), recognizer.supportsOnDeviceRecognition else { reportUnavailable(); return }
        guard recognizer.isAvailable else { fail(.recognizer); return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail(.microphone); return }
        Self.installTap(on: input, format: format, box: box)
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            fail(.engine)
            return
        }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        setMic(open: true)
        log(WakeLog.listeningStarted)
        self.recognizer = recognizer
        startTask()
    }

    /// A new recognition task on the open engine. The old one is cancelled after the new request is in place, so no audio is dropped.
    private func startTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // always: audio never goes to a server
        generation += 1
        let mine = generation
        detector.reset()
        let old = task
        box.set(request)
        task = Self.startRecognition(recognizer: recognizer, request: request) { [weak self] text, isFinal, code in
            Task { @MainActor in self?.deliver(generation: mine, text: text, isFinal: isFinal, errorCode: code) }
        }
        old?.cancel()
        taskStartedAt = now
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.cycleTask() } }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WakeWordPolicy.restartAfterSeconds + 0.01, execute: work)
    }

    private func cycleTask() {
        guard wanted, isMicOpen, WakeWordPolicy.shouldRestartTask(runningFor: now - taskStartedAt) else { return }
        log(WakeLog.notMatched)
        startTask()
    }

    private func deliver(generation g: Int, text: String?, isFinal: Bool, errorCode: Int?) {
        guard g == generation, wanted else { return }
        if let text, detector.consume(text) { matched(); return }
        guard isFinal || errorCode != nil else { return }
        taskEnded(errorCode: errorCode)
    }

    private func matched() {
        wanted = false
        failures = 0
        retryWork?.cancel()
        retryWork = nil
        log(WakeLog.matched)
        stopRun()   // the microphone is closed before the call path opens its own capture
        onWake?()
    }

    private func taskEnded(errorCode: Int?) {
        log(WakeLog.notMatched)
        if errorCode != nil {
            log(WakeLog.error(.recognizer))
            failures += 1
            retryAfterBackoff()
        } else if now - taskStartedAt < 2 {
            failures += 1   // ended at once with nothing wrong: do not spin
            retryAfterBackoff()
        } else {
            failures = 0
            startTask()
        }
    }

    private func configurationChanged() {
        guard wanted, isMicOpen else { return }
        stopRun()
        begin()
    }

    private func fail(_ kind: WakeErrorKind) {
        log(WakeLog.error(kind))
        failures += 1
        retryAfterBackoff()
    }

    private func retryAfterBackoff() {
        stopRun()
        guard wanted else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.begin() } }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WakeWordPolicy.backoff(afterFailures: failures), execute: work)
    }

    /// Closes everything the run opened: stale callbacks are dropped, the task is cancelled, the engine and tap are stopped.
    private func stopRun() {
        generation += 1
        restartWork?.cancel()
        restartWork = nil
        task?.cancel()
        task = nil
        box.set(nil)
        recognizer = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        if isMicOpen {
            setMic(open: false)
            log(WakeLog.listeningStopped)
        }
    }

    /// The only place the microphone state changes.
    private func setMic(open: Bool) {
        guard isMicOpen != open else { return }
        isMicOpen = open
        onMicrophoneChange?(open)
    }

    // The tap and the result handler are formed outside the main actor: they run on audio and recogniser threads.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, box: WakeRequestBox) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
        }
    }

    private nonisolated static func startRecognition(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                                     report: @escaping @Sendable (String?, Bool, Int?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            // 1110 is "no speech detected": a finished run with nothing in it, not a failure.
            let code = (error as NSError?)?.code
            let noSpeech = code == 1110
            report(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || noSpeech, noSpeech ? nil : code)
        }
    }
}
