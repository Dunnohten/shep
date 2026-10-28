import Foundation

/// Written for Shep.
/// The window of the focused element, for the `voiceover` focus source (`FocusTargetPolicy`). Two candidates are asked in
/// order: the system-wide focused element, then the front app's own focused element (the system-wide query failed live,
/// 2026-10-28 11:07 CT, kAXErrorCannotComplete, while the app's own answered). Each is checked on its own: queried, its owner
/// pid must be the front app's, its window resolved, and that window's owner pid must be the front app's too. Any failure
/// moves on to the next candidate; nothing of an element owned by another process is read beyond its pid. Pure: the AX calls
/// are behind `FocusedElementReading`.

public enum FocusCandidate: String, CaseIterable, Equatable, Sendable {
    case system, app
}

/// Why a candidate gave no window. Fixed tokens, safe to log.
public enum FocusElementFailure: String, CaseIterable, Equatable, Sendable {
    /// The query gave no element.
    case focusedElementUnavailable = "focused-element-unavailable"
    /// The element's owner pid could not be read.
    case ownerUnavailable = "owner-unavailable"
    /// The element belongs to another process.
    case foreignOwner = "foreign-owner"
    /// The element has no window.
    case windowUnavailable = "window-unavailable"
    /// The element's window is not confirmed as the front app's (another owner, or the owner could not be read).
    case windowForeignOwner = "window-foreign-owner"
}

public struct FocusAttemptFailure: Equatable, Sendable {
    public var candidate: FocusCandidate
    public var failure: FocusElementFailure
    public init(_ candidate: FocusCandidate, _ failure: FocusElementFailure) {
        self.candidate = candidate; self.failure = failure
    }
}

/// The AX reads the resolver needs. `Element` is an AXUIElement in the app, a name in tests.
public protocol FocusedElementReading {
    associatedtype Element
    func focusedElement(from candidate: FocusCandidate) -> Element?
    /// nil when the pid could not be read.
    func ownerPID(of element: Element) -> Int32?
    /// The element is a window itself (role AXWindow).
    func isWindow(_ element: Element) -> Bool
    /// The element's AXWindow.
    func window(of element: Element) -> Element?
}

public struct FocusedWindowResolution<Element> {
    /// The window, owned by the front app; nil when no candidate gave one.
    public var window: Element?
    /// The candidate it came from.
    public var candidate: FocusCandidate?
    /// Every candidate tried before (or instead of) the one that answered, in order.
    public var failures: [FocusAttemptFailure]
}

public enum FocusedWindowResolver {
    public static func resolve<R: FocusedElementReading>(frontPID: Int32, reader: R) -> FocusedWindowResolution<R.Element> {
        var failures: [FocusAttemptFailure] = []
        for candidate in FocusCandidate.allCases {
            switch window(of: candidate, frontPID: frontPID, reader: reader) {
            case .success(let win): return FocusedWindowResolution(window: win, candidate: candidate, failures: failures)
            case .failure(let why): failures.append(FocusAttemptFailure(candidate, why))
            }
        }
        return FocusedWindowResolution(window: nil, candidate: nil, failures: failures)
    }

    private enum Step<Element> {
        case success(Element)
        case failure(FocusElementFailure)
    }

    private static func window<R: FocusedElementReading>(of candidate: FocusCandidate, frontPID: Int32, reader: R) -> Step<R.Element> {
        guard let focused = reader.focusedElement(from: candidate) else { return .failure(.focusedElementUnavailable) }
        guard let owner = reader.ownerPID(of: focused) else { return .failure(.ownerUnavailable) }
        guard owner == frontPID else { return .failure(.foreignOwner) }
        if reader.isWindow(focused) { return .success(focused) }
        guard let win = reader.window(of: focused) else { return .failure(.windowUnavailable) }
        guard reader.ownerPID(of: win) == frontPID else { return .failure(.windowForeignOwner) }
        return .success(win)
    }
}
