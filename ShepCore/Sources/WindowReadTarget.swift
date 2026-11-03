import CoreGraphics
import Foundation

// Written for Shep.

/// Which window of an app a read means: the one the dog sits on (VoiceOver's focus first, then the keyboard), by its frame and title, with the
/// focused window preferred over the app's "main" one when the frame and title match nothing. Label repair and every later read of the same
/// window (Fix this screen applying stored labels) build their target here, so both ask the reader the same question.
public struct WindowReadTarget: Equatable, Sendable {
    public var frame: CGRect?
    public var title: String?
    public var preferFocused: Bool

    public init(frame: CGRect?, title: String?, preferFocused: Bool) {
        self.frame = frame; self.title = title; self.preferFocused = preferFocused
    }

    /// From the focused window's frame and title (both nil when no window has the focus). The focused window is always preferred.
    public static func focused(frame: CGRect?, title: String?) -> WindowReadTarget {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WindowReadTarget(frame: frame, title: (cleanTitle?.isEmpty ?? true) ? nil : cleanTitle, preferFocused: true)
    }

    /// The window the reader picks for this target out of `windows`: its index, or nil when there are none.
    public func selection(in windows: [AXWindowInfo]) -> Int? {
        WindowSelector.select(windows, targetFrame: frame, targetTitle: title, preferFocused: preferFocused)?.target
    }
}
