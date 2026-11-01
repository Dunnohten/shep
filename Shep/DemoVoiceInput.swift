import AVFoundation
import Foundation
import ShepCore

// Written for Shep.

/// The recording aid's voice input (`DemoVoiceConfig`, Debug builds only, off unless all three SHEP_DEMO_* paths are set):
/// instead of the microphone and macOS speech recognition, the talk key plays a voice FILE through the system output and a local
/// `whisper-cli` turns the same file into text. The words appear in the pill as the file reaches them, and the whole text is the
/// final transcript once the file has played and the key is up. Same callbacks as `VoiceInput`, so `VoiceSession` cannot tell.
/// Nothing here touches the microphone or Speech Recognition, so it raises no permission prompt.
@MainActor
final class DemoVoiceInput {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    let config: DemoVoiceConfig
    private var player: AVAudioPlayer?
    private var words: [TimedWord]?
    private var generation = 0
    private var released = false
    private var played = false
    private var startedAt: TimeInterval = 0
    private var lastPartial = ""
    /// The running whisper-cli, terminated by `cancel()` so a dropped run does not keep transcribing.
    private var process: Process?

    init(config: DemoVoiceConfig) { self.config = config }

    /// The config from the launch environment; nil in a Release build or without all three variables.
    static func fromEnvironment() -> DemoVoiceConfig? {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return DemoVoiceConfig.from(environment: ProcessInfo.processInfo.environment, debugBuild: debug,
                                    fileExists: { FileManager.default.isReadableFile(atPath: $0) })
    }

    func start() throws {
        cancel()
        generation += 1
        let mine = generation
        released = false
        played = false
        words = nil
        lastPartial = ""
        let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: config.audioPath))
        guard DemoVoiceLimits.fileAccepted(seconds: p.duration) else { throw DemoVoiceError.tooLong }
        p.prepareToPlay()
        player = p
        print("[shep] demo voice: playing \((config.audioPath as NSString).lastPathComponent) (\(String(format: "%.1f", p.duration)) s), whisper-cli transcribes it")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.whisperPath)
        proc.arguments = config.whisperArguments
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { player = nil; throw DemoVoiceError.couldNotRun }
        process = proc
        // Never longer than the deadline: stopped whisper-cli exits non-zero, which is reported as a failure.
        DispatchQueue.main.asyncAfter(deadline: .now() + DemoVoiceLimits.whisperDeadlineSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine, self.words == nil else { return }
                if proc.isRunning { proc.terminate() }
                // Reported here, not by the reader (which may still be blocked on the pipe): the run is over either way.
                self.transcribed(generation: mine, .failure(.timedOut))
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.collect(proc, out)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.transcribed(generation: mine, result) } }
        }
        guard p.play() else {
            cancel()
            throw DemoVoiceError.couldNotPlay
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        tick(generation: mine)
    }

    /// The key came up: the final text follows once the file has played and the transcript is in.
    func stop() {
        released = true
        finishIfReady()
    }

    func cancel() {
        generation += 1
        player?.stop()
        player = nil
        if let proc = process, proc.isRunning { proc.terminate() }
        process = nil
    }

    private func tick(generation g: Int) {
        guard g == generation, let p = player else { return }
        let ms = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        if let w = words {
            let text = DemoVoiceTranscript.text(w, upTo: ms)
            if !text.isEmpty, text != lastPartial { lastPartial = text; onPartial?(text) }
        }
        if !p.isPlaying, Double(ms) / 1000 >= p.duration - 0.05 {
            played = true
            finishIfReady()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in MainActor.assumeIsolated { self?.tick(generation: g) } }
    }

    private func transcribed(generation g: Int, _ result: Result<[TimedWord], DemoVoiceError>) {
        guard g == generation else { return }
        process = nil
        switch result {
        case .success(let w):
            words = w
            print("[shep] demo voice: whisper heard \(w.count) words")
            finishIfReady()
        case .failure(let e):
            generation += 1
            player?.stop()
            player = nil
            onFailure?(e.localizedDescription)
        }
    }

    private func finishIfReady() {
        guard released, played, let w = words else { return }
        generation += 1
        player = nil
        onFinal?(DemoVoiceTranscript.text(w))
    }

    /// Reads whisper-cli's output to the end (off the main thread) and parses it.
    private nonisolated static func collect(_ proc: Process, _ out: Pipe) -> Result<[TimedWord], DemoVoiceError> {
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return .failure(.exited(proc.terminationStatus)) }
        return .success(DemoVoiceTranscript.parse(String(decoding: data, as: UTF8.self)))
    }
}

enum DemoVoiceError: LocalizedError {
    case couldNotRun
    case couldNotPlay
    case tooLong
    case timedOut
    case exited(Int32)

    var errorDescription: String? {
        switch self {
        case .couldNotRun: return "the demo voice could not start whisper-cli"
        case .couldNotPlay: return "the demo voice file did not play"
        case .timedOut: return "the demo voice's whisper-cli took longer than \(Int(DemoVoiceLimits.whisperDeadlineSeconds)) seconds"
        case .tooLong: return "the demo voice file is longer than \(Int(DemoVoiceLimits.maxFileSeconds)) seconds"
        case .exited(let code): return "the demo voice's whisper-cli stopped with status \(code)"
        }
    }
}
