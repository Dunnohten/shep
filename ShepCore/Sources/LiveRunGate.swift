import Foundation

// Written for Shep.

/// What happens to a model result (or any later step of a run) when it arrives. One decision, read at every point after an await.
/// Once the target has left, a result is dropped as a whole: not written to the debug dump, not offered on a card, not sent further.
public struct LiveResultDecision: Equatable, Sendable {
    /// The debug dump (`--live-debug-dir`) may record the result (its trace and announcement).
    public var writeDump: Bool
    /// The result may be turned into a card, an overlay line or an action.
    public var offer: Bool
    /// The result may be handed to the next stage (ranking, the walk, the action runner).
    public var forward: Bool

    public init(writeDump: Bool, offer: Bool, forward: Bool) {
        self.writeDump = writeDump; self.offer = offer; self.forward = forward
    }

    public static let accept = LiveResultDecision(writeDump: true, offer: true, forward: true)
    public static let drop = LiveResultDecision(writeDump: false, offer: false, forward: false)
}

/// The one latch of "the target left", shared by the run, its reporters and the owner of the live run. It is read from the main actor
/// and from the pipeline's background sink, so it is a lock-protected final class (Sendable), not a flag on a main-actor object.
/// The latch only ever goes one way; exactly one caller of `latchLeft()` gets `true`.
public final class LiveRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var left = false

    public init() {}

    public var isLeft: Bool {
        lock.lock(); defer { lock.unlock() }
        return left
    }

    /// Latches "the target left". True for the first call only (the winner); later calls, from any thread, get false.
    @discardableResult
    public func latchLeft() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if left { return false }
        left = true
        return true
    }

    /// What to do with a result that arrives now: accepted before the latch, dropped as a whole after it.
    public func decideResult() -> LiveResultDecision {
        isLeft ? .drop : .accept
    }
}
