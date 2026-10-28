import Foundation

// Written for Shep.

/// Where the docked tab's colour comes from. Reading the title bar means capturing the window, so it follows the same
/// rule as "Fix this screen": an app on the never-capture lists (mail, messaging, command runners, security) or one whose
/// identity is unknown is never captured, not even for one pixel row, and the tab uses the appearance fallback colour.
public enum TabTintPolicy {
    public enum Source: Equatable, Sendable {
        /// Capture the window and read one row of its title bar.
        case sample
        /// The fixed light or dark appearance colour.
        case fallback
    }

    public static func source(bundleID: String?, screenRecordingAllowed: Bool, liveTarget: String? = nil) -> Source {
        skipReason(docked: true, bundleID: bundleID, screenRecordingAllowed: screenRecordingAllowed, liveTarget: liveTarget) == nil ? .sample : .fallback
    }

    /// Why the tint is not sampled. The raw values are what the `[shep] tint: skipped` line prints.
    public enum SkipReason: String, Equatable, Sendable {
        case notDocked = "not-docked"
        case noPermission = "no-permission"
        case neverCapture = "never-capture"
        case liveBoundOtherApp = "live-bound-other-app"
    }

    /// Why no sample is taken, or nil when one is. A live run bound to an app never captures another app's window, not even one
    /// pixel row (`liveTarget`); otherwise the screen-recording permission and the never-capture lists decide.
    public static func skipReason(docked: Bool, bundleID: String?, screenRecordingAllowed: Bool, liveTarget: String?) -> SkipReason? {
        guard docked else { return .notDocked }
        if let target = liveTarget, !LiveBinding.mayRead(bundleID: bundleID, target: target, ownBundleID: nil) { return .liveBoundOtherApp }
        guard screenRecordingAllowed else { return .noPermission }
        guard let bundleID, ControlPolicy.mayCapture(bundleID: bundleID) else { return .neverCapture }
        return nil
    }

    /// `[shep] tint: sampled <bundle id>` or `[shep] tint: skipped <bundle id or (none)> (<reason>)`. Nothing but a bundle id goes
    /// in: anything that is not one (a title, a path, a line break, an overlong value) prints as `(none)`.
    public static func logLine(bundleID: String?, skip: SkipReason?) -> String {
        let trimmed = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = LiveTargetGate.isBundleID(trimmed) ? trimmed : "(none)"
        guard let skip = skip else { return "[shep] tint: sampled \(id)" }
        return "[shep] tint: skipped \(id) (\(skip.rawValue))"
    }
}
