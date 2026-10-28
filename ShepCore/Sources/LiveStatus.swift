import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Written for Shep.

/// Where a live run ended or stopped, by stage name only. Never free text.
public enum LiveStatusStage: String, CaseIterable, Sendable {
    case target
    case noTarget = "no-target"
    case arrival
    case backdrop
    case status
    case accessibility
    case read
    case capture
    case provider
    case policy
    case picker
    case ranking
    case namer
    case action
    case run
    case busy
    case other

    /// Stages that end a run before anything is read (scripts treat them as a refusal).
    public var endsEarly: Bool {
        switch self {
        case .target, .noTarget, .arrival, .backdrop, .status: return true
        default: return false
        }
    }
}

/// One event of the structured status channel (`--live-status`). A closed set: no event carries the request, the card text or any
/// other user text.
public enum LiveStatusEvent: Equatable, Sendable {
    case targetOK
    case requestSubmitted
    case cardShown
    case answered(approved: Bool)
    case outcome(LiveOutcome)
    case reason(LiveStatusStage)
    /// The target left the front during the run (bound runs only). Scripts treat it as exit 3, before or after the card.
    case targetLeft
    case recordingWritten
    /// `refused`: the recording never started (a `record refused` line); false: it started and its clip and directory were removed
    /// (a failed removal is `recordingDiscardFailed`, a clip already published is `recordingAlreadyPublished`).
    case recordingDiscarded(refused: Bool)
    /// A discard was requested (the target left) and the clip or its working directory could not be removed. Never `recording-discarded`.
    case recordingDiscardFailed
    /// A discard was requested after the clip had already been published to its final path: it stays, and this says so.
    case recordingAlreadyPublished
    /// A discard was requested but could not be confirmed within Shep's bounds (a start still in flight, a stream that did not stop): a
    /// clip or its working directory MAY remain. Never `recording-discarded`.
    case recordingDiscardUnknown
    case finished
}

/// `--live-status <file>` and `--live-nonce <hex>`: the channel scripts classify a run from. One line per event:
/// `<nonce> <event> [<token>]`. The human `[shep] live:` log is for people; it carries the request text and can be forged by it.
public enum LiveStatus {
    public static let nonceLengths = 16...64

    public static func isValidNonce(_ text: String) -> Bool {
        guard nonceLengths.contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// An absolute path, one line, no NUL, no trailing slash.
    public static func isUsablePath(_ text: String) -> Bool {
        guard text.hasPrefix("/"), !text.hasSuffix("/"), text.utf8.count <= 1024 else { return false }
        return !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    static func name(of event: LiveStatusEvent) -> String {
        switch event {
        case .targetOK: return "target-ok"
        case .requestSubmitted: return "request-submitted"
        case .cardShown: return "card-shown"
        case .answered(let approved): return approved ? "answered-approve" : "answered-cancel"
        case .outcome(let outcome): return "outcome-" + outcome.rawValue
        case .reason(let stage): return "reason-" + stage.rawValue
        case .targetLeft: return "target-left"
        case .recordingWritten: return "recording-written"
        case .recordingDiscarded(let refused): return refused ? "recording-discarded refused" : "recording-discarded"
        case .recordingDiscardFailed: return "discard-failed"
        case .recordingAlreadyPublished: return "recording-already-published"
        case .recordingDiscardUnknown: return "discard-unknown"
        case .finished: return "finished"
        }
    }

    /// The line (no newline), or nil when the nonce is unusable.
    public static func line(nonce: String, event: LiveStatusEvent) -> String? {
        guard isValidNonce(nonce) else { return nil }
        return nonce + " " + name(of: event)
    }

    /// The stage named by a `LiveReason` text (`<stage>: <cause>`): only the word before the first colon, only when it is a known
    /// stage. Anything else is `other`, so free text can never become an event.
    public static func stage(forReasonText text: String) -> LiveStatusStage {
        guard let colon = text.firstIndex(of: ":") else { return .other }
        let word = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
        guard let stage = LiveStatusStage(rawValue: word), stage != .other else { return .other }
        return stage
    }
}

/// The open status file. Created exclusively (`ExclusiveFile`), appended to one whole line per `write`.
public final class LiveStatusFile: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private let nonce: String

    private init(fd: Int32, nonce: String) { self.fd = fd; self.nonce = nonce }

    deinit { if fd >= 0 { close(fd) } }

    public static func create(path: String, nonce: String) -> Result<LiveStatusFile, RecordingSlotRefusal> {
        guard LiveStatus.isValidNonce(nonce) else { return .failure(RecordingSlotRefusal(reason: "the nonce is not 16 to 64 lowercase hex characters")) }
        switch ExclusiveFile.create(path: path) {
        case .success(let fd): return .success(LiveStatusFile(fd: fd, nonce: nonce))
        case .failure(let refusal): return .failure(refusal)
        }
    }

    public func append(_ event: LiveStatusEvent) {
        guard let text = LiveStatus.line(nonce: nonce, event: event) else { return }
        let bytes = Array((text + "\n").utf8)
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { if written < 0 && errno == EINTR { continue }; return }
            offset += written
        }
    }
}
