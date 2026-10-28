import Foundation

// Written for Shep.

/// How a requested discard ended, as the run reports it. Removal must have succeeded for `removed`; every other result of the slot is
/// a failure, never a quiet success. Each maps to its own status event.
public enum RecordingDiscardOutcome: Equatable, Sendable {
    /// Our clip and our working directory were removed.
    case removed
    /// Something of ours could not be removed, or the slot could not vouch for what it holds (the text says what and where).
    case failed(String)
    /// The clip had already been published to its final path before the discard was requested; it stays there.
    case alreadyPublished
    /// No recording was ever started (or it was refused): there is nothing to discard.
    case neverStarted
    /// A discard was requested but could not be confirmed (a start still in flight past its bound, a stream that did not stop in time):
    /// the clip or its working directory may remain. Never reported as a discard.
    case unknown(String)

    /// `.removed` only for a real removal. `identityMismatch`, `clipReplaced`, `leftBehind` and `alreadyFinished` (the slot ended some
    /// other way, so this call removed nothing) are failures.
    public init(slotResult: RecordingDiscardResult) {
        switch slotResult {
        case .removed: self = .removed
        case .identityMismatch: self = .failed("the working directory is not the one I made; I removed nothing")
        case .clipReplaced(let text): self = .failed(text)
        case .leftBehind(let text): self = .failed(text)
        case .alreadyFinished: self = .failed("the recording slot had already ended; I removed nothing")
        }
    }

    /// The status event for this outcome. `recording-discarded` appears only for `removed` (and, with `refused`, for a recording that
    /// never started).
    public var statusEvent: LiveStatusEvent {
        switch self {
        case .removed: return .recordingDiscarded(refused: false)
        case .failed: return .recordingDiscardFailed
        case .alreadyPublished: return .recordingAlreadyPublished
        case .neverStarted: return .recordingDiscarded(refused: true)
        case .unknown: return .recordingDiscardUnknown
        }
    }
}

public enum RecordingEndDecision: Equatable, Sendable {
    case discard(String)
    case publish
}

/// The one decision at the end of a recording, taken AFTER every await (the stream stop, the wait for the movie): a discard that was
/// requested while a keep was finalising is already known by then and wins over a good clip. Precedence: an explicit request, a pending
/// request, a stream that did not stop in time, a slot problem, a failure, an unfinished or empty movie; only then is the clip
/// published.
public enum RecordingEndPlanner {
    public static func decide(requested: String?, pendingDiscard: String?, slotProblem: String?, failure: String?,
                              clipSize: Int, movieFinished: Bool, stopCompleted: Bool = true) -> RecordingEndDecision {
        if let why = requested { return .discard(why) }
        if let why = pendingDiscard { return .discard(why) }
        if !stopCompleted { return .discard(RecordingDiscardPlanner.stopTimedOutText) }
        if let why = slotProblem { return .discard(why) }
        if let failed = failure { return .discard("the recording failed: \(failed)") }
        if clipSize <= 0 || !movieFinished { return .discard("the movie was not finished") }
        return .publish
    }
}
