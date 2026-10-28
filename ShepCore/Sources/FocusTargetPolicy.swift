import CoreGraphics
import Foundation

/// Written for Shep.
/// Which focus decides the window Shep goes to. Shep's users may not see the screen, so the mouse is the last thing to trust:
/// with VoiceOver running, the window of the focused element comes first; then the keyboard focus (the front app's focused
/// window); the mouse pointer only when neither gives a window. Pure.
///
/// `voiceover` is not the VoiceOver cursor. There is no public API for that cursor; `voiceover` is the ordinary Accessibility
/// focused element (`kAXFocusedUIElementAttribute`, system-wide, then the front app's own: `FocusedWindowResolver`) and its
/// window, read only while VoiceOver is running. With VoiceOver's default cursor tracking the cursor and that focus move
/// together, so it is usually where the VoiceOver cursor is; with tracking turned off or the cursor moved on its own, it can be
/// somewhere else, and Shep cannot tell. VoiceOver's own scripting bridge is not used (no scripting automation in this repo,
/// and it needs a hardened VoiceOver Utility setting plus an Automation prompt). The source name stays `voiceover` for the logs.
public enum FocusSource: String, CaseIterable, Equatable, Sendable {
    case voiceover, keyboard, mouse
}

public enum FocusTargetPolicy {
    /// The order the sources are tried in.
    public static func order(voiceOverRunning: Bool) -> [FocusSource] {
        voiceOverRunning ? [.voiceover, .keyboard, .mouse] : [.keyboard, .mouse]
    }

    /// The first source in `order` that gives a window, or nil when none does.
    public static func choose(voiceOverRunning: Bool, available: (FocusSource) -> Bool) -> FocusSource? {
        order(voiceOverRunning: voiceOverRunning).first(where: available)
    }

    /// The mouse fallback: the first of the front app's windows (front to back, AX coordinates) that holds the pointer.
    public static func windowIndex(containing point: CGPoint, frames: [CGRect?]) -> Int? {
        frames.firstIndex { $0?.contains(point) == true }
    }

    /// The source part of the target line (`diagnosticLine`). Built from a closed enum: no title or text can reach it.
    public static func logLine(_ source: FocusSource?) -> String {
        "[shep] target: " + (source?.rawValue ?? "none")
    }

    /// `logLine` plus the VoiceOver flag as sampled for this choice and, with VoiceOver running, why each focused-element candidate
    /// gave no window (`system=foreign-owner app=window-unavailable`). Fixed tokens only: no title, label or pid.
    public static func diagnosticLine(source: FocusSource?, voiceOverRunning: Bool, voiceOverFailures: [FocusAttemptFailure]) -> String {
        var detail = "voiceover=" + (voiceOverRunning ? "on" : "off")
        if voiceOverRunning, !voiceOverFailures.isEmpty {
            detail += "; " + voiceOverFailures.map { "\($0.candidate.rawValue)=\($0.failure.rawValue)" }.joined(separator: " ")
        }
        return logLine(source) + " (" + detail + ")"
    }
}

/// One sample of how the target window was chosen, for the debug dump (`LiveDebug.traceText`): the source, the VoiceOver flag as
/// sampled for that choice and, with VoiceOver running, why each focused-element candidate gave no window. Fixed tokens only.
public struct FocusTargetSample: Equatable, Sendable {
    public var source: FocusSource?
    public var voiceOverRunning: Bool
    public var voiceOverFailures: [FocusAttemptFailure]

    public init(source: FocusSource?, voiceOverRunning: Bool, voiceOverFailures: [FocusAttemptFailure]) {
        self.source = source
        self.voiceOverRunning = voiceOverRunning
        self.voiceOverFailures = voiceOverFailures
    }

    /// The same text as the log's `diagnosticLine`, without its `[shep] ` prefix.
    public var traceLine: String {
        String(FocusTargetPolicy.diagnosticLine(source: source, voiceOverRunning: voiceOverRunning, voiceOverFailures: voiceOverFailures)
            .dropFirst("[shep] ".count))
    }
}

/// When the tracker prints its target line: the first sample, then whenever the line changes (source, sampled VoiceOver flag or
/// reasons), so a VoiceOver toggle is logged even when the source stays the same.
public struct FocusTargetLogState: Equatable, Sendable {
    public private(set) var last: String?
    public init() {}

    /// The line to print for this sample, or nil when it is the same as the last one.
    public mutating func record(source: FocusSource?, voiceOverRunning: Bool, voiceOverFailures: [FocusAttemptFailure]) -> String? {
        let line = FocusTargetPolicy.diagnosticLine(source: source, voiceOverRunning: voiceOverRunning, voiceOverFailures: voiceOverFailures)
        guard line != last else { return nil }
        last = line
        return line
    }

    /// Tracking stopped: the next sample is logged whatever it is.
    public mutating func reset() { last = nil }
}
