import Foundation

/// Written for Shep.
/// One voice call: when Shep wakes and when the spoken request is handed to the pipeline. Two things can be outstanding at once:
/// the focus handoff (`FocusHandoff`, only when Shep's own window was in front) and the end of the question (the final
/// transcript). They can finish in either order, so both are joined here:
/// - without VoiceOver, Shep wakes as soon as the target app is in front (at once when there is no handoff), as before;
/// - with VoiceOver, Shep stays home until the question is over (`VoiceOverFlow.wakesDuringQuestion`) AND the target is in front;
/// - the request is submitted once, and never before the handoff has finished: a request sent while Shep is still in front is
///   refused ("Bring the window you want fixed to the front first"). A handoff that timed out still calls, and the pipeline
///   then refuses with that sentence (Shep's own window is never a target); an abandoned handoff drops the held request.
/// Pure: the app feeds events in and runs the effects. Each call has a generation; events from an older call are ignored.
public enum TalkCallEffect: Equatable, Sendable {
    /// `ShepCoordinator.call(.pushToTalk, forQuestion:)`. `forQuestion` is true once the question is over ("On it." follows).
    case call(forQuestion: Bool)
    /// Hand the request to the fix pipeline.
    case submit(String)
}

public struct TalkCallGate: Equatable, Sendable {
    public private(set) var generation = 0
    private var voiceOver = false
    /// A focus handoff for this call has started and not finished.
    private var handoffPending = false
    /// Shep was woken for this call.
    private var called = false
    /// The question is over and its request waits for the handoff (or for the wake under VoiceOver).
    private var heldText: String?
    /// The call is over (submitted or dropped): late events do nothing.
    private var closed = true

    public init() {}

    /// A new call. `handoff`: Shep's own window is in front and the previous app was asked to come back.
    /// Returns the new generation (stamp the handoff's callbacks with it) and the effects.
    public mutating func begin(handoff: Bool, voiceOverRunning: Bool) -> (generation: Int, effects: [TalkCallEffect]) {
        generation += 1
        voiceOver = voiceOverRunning
        handoffPending = handoff
        called = false
        heldText = nil
        closed = false
        if !handoff && VoiceOverFlow.wakesDuringQuestion(voiceOverRunning: voiceOverRunning) {
            called = true
            return (generation, [.call(forQuestion: false)])
        }
        return (generation, [])
    }

    /// The handoff finished with a call (`FocusHandoffEffect.call`: confirmed, or timed out).
    public mutating func handoffCalled(generation g: Int) -> [TalkCallEffect] {
        guard g == generation, !closed, handoffPending else { return [] }
        handoffPending = false
        if let text = heldText { return finish(text) }
        if VoiceOverFlow.wakesDuringQuestion(voiceOverRunning: voiceOver) {
            called = true
            return [.call(forQuestion: false)]
        }
        return []   // under VoiceOver: Shep comes out with the request
    }

    /// The handoff was abandoned (another app came to the front): nothing is called and a held request is dropped.
    public mutating func handoffAbandoned(generation g: Int) {
        guard g == generation else { return }
        cancel()
    }

    /// The question is over with this request (the final transcript).
    public mutating func questionEnded(_ text: String) -> [TalkCallEffect] {
        guard !closed else { return [] }   // no open call (cancelled, finished, or never begun): a late transcript is dropped
        if handoffPending {
            heldText = text
            return []
        }
        return finish(text)
    }

    /// The call ended without a request, or was cancelled: everything held is dropped.
    public mutating func cancel() {
        handoffPending = false
        heldText = nil
        closed = true
    }

    public var isHolding: Bool { heldText != nil }

    private mutating func finish(_ text: String) -> [TalkCallEffect] {
        var out: [TalkCallEffect] = []
        if !called {
            called = true
            out.append(.call(forQuestion: true))
        }
        out.append(.submit(text))
        heldText = nil
        closed = true
        return out
    }
}
