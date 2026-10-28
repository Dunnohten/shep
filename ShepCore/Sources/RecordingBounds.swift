import Foundation

// Written for Shep.

/// The result of waiting for an operation for at most some seconds. A separate enum (not an optional), so an operation whose own
/// result is nil is not mistaken for a timeout.
public enum BoundedResult<T: Sendable>: Sendable {
    case value(T)
    case timedOut

    public var didTimeOut: Bool { if case .timedOut = self { return true }; return false }
}

/// Resumes its continuation exactly once, from whichever of the operation and the timer gets there first.
private final class BoundedOneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BoundedResult<T>, Never>?

    init(_ continuation: CheckedContinuation<BoundedResult<T>, Never>) { self.continuation = continuation }

    func finish(_ result: BoundedResult<T>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

/// Waits for `operation` for at most `seconds`. Unlike a task group, it does not wait for the operation after the time is up: an
/// operation that never returns (a stream stop that hangs) is abandoned, not waited for, and the caller goes on with `.timedOut`.
public enum BoundedAwait {
    public static func run<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> BoundedResult<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<BoundedResult<T>, Never>) in
            let shot = BoundedOneShot<T>(continuation)
            Task {
                let value = await operation()
                shot.finish(.value(value))
            }
            Task {
                let nanos = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                shot.finish(.timedOut)
            }
        }
    }
}

public enum RecordingWaitResult: Equatable, Sendable {
    case completed
    case timedOut
}

/// What a requested discard may do after it has waited for a start (or an end) that was in flight.
public enum RecordingDiscardPlan: Equatable, Sendable {
    /// Nothing is in flight any more: go on and discard what exists.
    case proceed
    /// No start was ever launched: there is provably nothing to discard.
    case neverStarted
    /// A start or an end did not finish within its bound: nothing may be claimed.
    case unknown(String)
}

/// The decisions that keep a discard honest (code review of d8213e1, N1). `recording-discarded` and "never started" are claimed only
/// when they are true. A start that is still running, an end that has not finished or a stream that did not stop may still be writing a
/// clip, so the answer is `unknown` (event `discard-unknown`) and the script says a clip may remain.
public enum RecordingDiscardPlanner {
    /// How long a requested discard waits for a start that is in flight.
    public static let startBoundSeconds: Double = 30
    /// How long a requested discard waits for an end (stop, movie, removal) that is already under way.
    public static let endBoundSeconds: Double = 25
    /// How long the stream's stop may take before the end gives up on it.
    public static let stopBoundSeconds: Double = 10
    /// How long the end waits for the recording output to say the movie is finished (after a completed stop).
    public static let movieWaitSeconds: Double = 5

    public static let startInFlightText = "a recording start was still running after \(Int(startBoundSeconds)) s, so a clip may be written or remain"
    public static let endNotFinishedText = "the recording was still being stopped after \(Int(endBoundSeconds)) s, so a clip may remain"
    public static let stopTimedOutText = "the stream did not stop within \(Int(stopBoundSeconds)) s, so it may still be writing and a clip may remain"
    public static let noOutcomeText = "the recording ended without reporting an outcome, so a clip may remain"

    /// After waiting for the start. `neverStarted` only when no start was ever launched; a launched start that is still running
    /// after the bound is unknown, never a discard.
    public static func afterStartWait(startLaunched: Bool, wait: RecordingWaitResult) -> RecordingDiscardPlan {
        if !startLaunched { return .neverStarted }
        switch wait {
        case .completed: return .proceed
        case .timedOut: return .unknown(startInFlightText)
        }
    }

    /// After waiting for an end that was already under way.
    public static func afterEndWait(wait: RecordingWaitResult) -> RecordingDiscardPlan {
        switch wait {
        case .completed: return .proceed
        case .timedOut: return .unknown(endNotFinishedText)
        }
    }

    /// The outcome once the removal has been tried. A stream whose stop did not complete may still write, so even a removal that worked
    /// is only `unknown`; otherwise the removal's own result stands (`removed`, `failed`, ...).
    public static func finalOutcome(removal: RecordingDiscardOutcome, stopCompleted: Bool) -> RecordingDiscardOutcome {
        if !stopCompleted { return .unknown(stopTimedOutText) }
        return removal
    }
}

/// The sequence of a requested discard, apart from the recorder: wait for the start that was launched (bounded), then perform the
/// discard. It is generic over nothing and takes closures, so a test can suspend the start on a continuation it controls.
public enum RecordingDiscardFlow {
    @MainActor
    public static func resolve(startLaunched: Bool, awaitStart: @escaping @Sendable () async -> Void, startBoundSeconds: Double,
                               perform: () async -> RecordingDiscardOutcome) async -> RecordingDiscardOutcome {
        var wait = RecordingWaitResult.completed
        if startLaunched {
            let result = await BoundedAwait.run(seconds: startBoundSeconds) { await awaitStart() }
            if result.didTimeOut { wait = .timedOut }
        }
        switch RecordingDiscardPlanner.afterStartWait(startLaunched: startLaunched, wait: wait) {
        case .neverStarted: return .neverStarted
        case .unknown(let text): return .unknown(text)
        case .proceed: return await perform()
        }
    }
}
