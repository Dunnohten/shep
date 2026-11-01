import Foundation

// Written for Shep.

/// A recording aid, off unless asked for: the talk key's voice comes from an audio FILE instead of the microphone, and is turned
/// into text by a local whisper.cpp run (`whisper-cli`) instead of macOS speech recognition. The file plays through the system
/// output while it is recognised, so the voice is heard (and recorded with Shep's window) exactly as it drives Shep.
/// Neither the microphone nor macOS Speech Recognition is touched, so no permission is asked for.
/// It needs all three environment variables (absolute paths to existing files), and only a Debug build reads them:
///   SHEP_DEMO_VOICE_FILE      the voice (any format AVAudioPlayer and whisper-cli read; 16 kHz WAV is safest)
///   SHEP_DEMO_WHISPER         the whisper-cli binary
///   SHEP_DEMO_WHISPER_MODEL   a ggml model for it
/// A Release build, or a launch without them, never uses this path.
public struct DemoVoiceConfig: Equatable, Sendable {
    public static let fileKey = "SHEP_DEMO_VOICE_FILE"
    public static let whisperKey = "SHEP_DEMO_WHISPER"
    public static let modelKey = "SHEP_DEMO_WHISPER_MODEL"

    public var audioPath: String
    public var whisperPath: String
    public var modelPath: String

    public static func from(environment: [String: String], debugBuild: Bool, fileExists: (String) -> Bool) -> DemoVoiceConfig? {
        guard debugBuild else { return nil }
        var paths: [String] = []
        for key in [fileKey, whisperKey, modelKey] {
            guard let p = environment[key], p.hasPrefix("/"), !p.contains("\n"), fileExists(p) else { return nil }
            paths.append(p)
        }
        return DemoVoiceConfig(audioPath: paths[0], whisperPath: paths[1], modelPath: paths[2])
    }

    /// whisper-cli arguments: one word per segment (so each word has its own time), English, results only on stdout.
    public var whisperArguments: [String] {
        ["-m", modelPath, "-f", audioPath, "-l", "en", "-ml", "1", "-sow", "-np"]
    }
}

/// Bounds that make the recording aid always answer inside the session's wait (`VoiceTimings.demoFinalWaitSeconds`, counted from
/// the key coming up, which is never before the start): the file is at most `maxFileSeconds` long, and whisper-cli is stopped
/// (a failure) `whisperDeadlineSeconds` after the start. The final text or the failure therefore arrives at most that long after
/// the start.
public enum DemoVoiceLimits {
    public static let maxFileSeconds: TimeInterval = 12
    public static let whisperDeadlineSeconds: TimeInterval = 15

    /// Whether a file of this length may be used.
    public static func fileAccepted(seconds: TimeInterval) -> Bool { seconds.isFinite && seconds > 0 && seconds <= maxFileSeconds }
}

public struct TimedWord: Equatable, Sendable {
    /// When the word starts, in milliseconds from the start of the file.
    public var ms: Int
    public var text: String
}

/// whisper-cli's result lines, `[00:00:01.230 --> 00:00:01.560]   word`, as timed words.
public enum DemoVoiceTranscript {
    public static func parse(_ output: String) -> [TimedWord] {
        var words: [TimedWord] = []
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = line[line.index(after: line.startIndex)..<close]
            guard let arrow = stamp.range(of: " --> "), let ms = milliseconds(String(stamp[stamp.startIndex..<arrow.lowerBound])) else { continue }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if text.isEmpty || (text.hasPrefix("[") && text.hasSuffix("]")) { continue }   // [BLANK_AUDIO] and the like
            words.append(TimedWord(ms: ms, text: text))
        }
        return words
    }

    /// `hh:mm:ss.mmm` in milliseconds.
    public static func milliseconds(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let sec = parts[2].split(separator: ".")
        guard sec.count == 2, let whole = Int(sec[0]), let frac = Int(sec[1]), sec[1].count == 3 else { return nil }
        return ((h * 60 + m) * 60 + whole) * 1000 + frac
    }

    /// The words heard by `ms` (all of them when nil), as one line.
    public static func text(_ words: [TimedWord], upTo ms: Int? = nil) -> String {
        words.filter { ms == nil || $0.ms <= ms! }.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
    }
}
