import Foundation

// Written for Shep.

/// What `--live-target` decides at each look: go on, activate the wanted app and look again, or stop.
public enum LiveTargetDecision: Equatable, Sendable {
    case proceed
    case activateAndWait
    /// The run ends here, reading and capturing nothing. The text is the `reason:` line's, bundle ids only.
    case refuse(String)
}

/// `--live-target <bundle-id>`: a live request is bound to the app it was meant for. Measured on the Mac: the front app at the moment
/// of submission decided what Shep read, so a browser the person switched to was read instead of the app asked about. Pure: the
/// caller (AppDelegate) supplies the facts and does the activating; this only decides. Never names a window title.
public enum LiveTargetGate {
    /// How long Shep waits for the wanted app to come to the front, and how often it looks again.
    public static let arrivalBudgetSeconds = 5.0
    public static let pollSeconds = 0.25
    /// The longest bundle id accepted.
    public static let maxLength = 255
    /// Said in the overlay when a run is refused (the log line has the details).
    public static let overlayLine = "I wasn't on the app I was asked to read, so I read nothing."

    /// `[A-Za-z0-9._-]`, 1 to `maxLength` characters.
    public static func isBundleID(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxLength else { return false }
        return text.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) || (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
                || s == "." || s == "_" || s == "-"
        }
    }

    /// Why a supplied `--live-target` / SHEP_LIVE_TARGET value cannot be used, or nil when it can. `source` names where it came from.
    /// The text never repeats the value.
    public static func invalidReason(_ value: String, source: String) -> String? {
        if value.isEmpty { return source + " needs a value" }
        if value.count > maxLength { return source + " is too long" }
        if value.hasPrefix("-") || !isBundleID(value) { return source + " is not a bundle id" }
        return nil
    }

    /// A bundle id for a log line: whitespace-free, or `(none)` when the app has none.
    public static func shown(_ bundleID: String?) -> String {
        let t = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(none)" : LiveReason.clean(t)
    }

    public static func neverLookText(_ wanted: String) -> String { "target: \(shown(wanted)) is on the never-look list" }
    public static func notRunningText(_ wanted: String) -> String { "target: \(shown(wanted)) is not running" }
    public static func wrongFrontText(front: String?, wanted: String) -> String {
        "target: front app is \(shown(front)) not \(shown(wanted))"
    }

    static func same(_ a: String?, _ b: String) -> Bool {
        ControlPolicy.normalized(a ?? "") == ControlPolicy.normalized(b)
    }

    /// - wanted: the bundle id from `--live-target`.
    /// - front: the frontmost app's bundle id (nil when it has none).
    /// - wantedRunning: a running process has the wanted bundle id.
    /// - elapsed / budget: seconds spent waiting for the wanted app to come to the front, and the most to wait.
    public static func decide(wanted: String, front: String?, wantedRunning: Bool, elapsed: Double, budget: Double) -> LiveTargetDecision {
        guard ControlPolicy.mayCapture(bundleID: wanted) else { return .refuse(neverLookText(wanted)) }
        guard wantedRunning else { return .refuse(notRunningText(wanted)) }
        if same(front, wanted) { return .proceed }
        if elapsed >= budget { return .refuse(wrongFrontText(front: front, wanted: wanted)) }
        return .activateAndWait
    }

    /// The look while the run is going on, from `target-ok` until `live: finished` (after the request was submitted, while a card
    /// waits, while the model is asked). When the wanted app is no longer in front the run ends with this refusal text (the same
    /// one-line `target: front app is X not Y`, bundle ids only); nil means "carry on". Case-insensitive; a front app with no
    /// bundle id is not the wanted app. Judges the front app alone; Shep's own card taking focus is `focusLeft(wanted:front:frontIsShep:)`.
    public static func focusLeft(wanted: String, front: String?) -> String? {
        focusLeft(wanted: wanted, front: front, frontIsShep: false)
    }

    /// The same look when the caller knows the front app is Shep itself (its approval card can take key status): Shep in front is
    /// "still bound", never "left". The caller decides `frontIsShep` from the process id, not from a name.
    public static func focusLeft(wanted: String, front: String?, frontIsShep: Bool) -> String? {
        if frontIsShep { return nil }
        if same(front, wanted) { return nil }
        return wrongFrontText(front: front, wanted: wanted)
    }

    /// The look the activation notification makes. The decision is taken on the app the NOTIFICATION names (its pid and bundle id from
    /// `NSWorkspace.applicationUserInfoKey`), not on whatever is in front when the callback finally runs: two queued activations (away,
    /// then back) both find the target in front by then, and the departure would be lost. The pid decides "Shep itself" (its card taking
    /// focus is not leaving), the bundle id decides "the wanted app". A notification that names no app is not a look (nil): the 0.25 s
    /// poll and the rechecks before the card and after the approval still read the live front app.
    public static func activationLeft(wanted: String, activatedBundleID: String?, activatedPID: Int32?, ownPID: Int32) -> String? {
        if activatedPID == nil && activatedBundleID == nil { return nil }
        if let pid = activatedPID, pid == ownPID { return nil }
        if same(activatedBundleID, wanted) { return nil }
        return wrongFrontText(front: activatedBundleID, wanted: wanted)
    }

    /// Said in the overlay when the person leaves the target during a run.
    public static let leftOverlayLine = "You left the app, so I stopped."

    /// The last look, right before the Accessibility read and the screenshot: never waits. Anything but the wanted app in front
    /// refuses, and the other app is not read.
    public static func recheck(wanted: String, front: String?, wantedRunning: Bool) -> LiveTargetDecision {
        decide(wanted: wanted, front: front, wantedRunning: wantedRunning, elapsed: arrivalBudgetSeconds, budget: arrivalBudgetSeconds)
    }
}

/// Whether a `--live-request` may start at all. An explicitly supplied `--live-target` that cannot be used refuses the run, so the
/// request never goes to whatever app happens to be in front. Pure: AppDelegate acts on the answer and does nothing else when it is
/// `.refuse` (no arrival call, no capture, no Accessibility read, no provider, no recording).
public enum LiveRequestStart {
    public enum Decision: Equatable, Sendable {
        case run
        /// The `reason:` line's text (starts with `target: `).
        case refuse(String)
    }

    /// Said in the overlay when the binding is unusable.
    public static let overlayLine = "I couldn't tell which app to read, so I read nothing."

    public static func decide(options: LaunchOptions) -> Decision {
        guard options.liveRequest != nil else { return .run }
        if let why = options.liveTargetInvalid { return .refuse("target: " + why) }
        if let why = options.liveStatusInvalid { return .refuse("status: " + why) }
        return .run
    }

    /// The three log lines of a refused start, in order: reason, outcome, finished.
    public static func refusalLines(_ why: String) -> [String] {
        [LiveLog.reason(why), LiveLog.outcome(.refused), LiveLog.finished]
    }
}
