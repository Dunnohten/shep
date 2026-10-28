import CoreGraphics
import Foundation

// Written for Shep.

/// Why one target-alive check of a running recording came out as it did. A closed set of short tokens: a watch line carries one
/// of these and nothing else of the world (no title, path, pid or bundle id).
public enum WatchReason: String, CaseIterable, Sendable {
    case ok
    /// Alive; the target window moved or resized since the last check.
    case moved
    /// The target window is not listed on screen (closed or minimised).
    case windowMissing = "window-missing"
    /// Another process owns the target window number now.
    case ownerChanged = "owner-changed"
    /// No bundle id came back for the target's pid, by either lookup, and the process is not confirmed gone.
    case bundleEmpty = "bundle-empty"
    /// The target's process is confirmed terminated (`ProcessFact.terminated`).
    case pidGone = "pid-gone"
    /// Another app now runs under the target's pid.
    case bundleMismatch = "bundle-mismatch"
    /// The target app may no longer be recorded.
    case notAllowed = "not-allowed"
    /// The target is in front and is a forbidden app.
    case forbiddenFront = "forbidden-front"
    /// The capture stream reported an error.
    case streamError = "stream-error"
    /// The recording's private folder or clip is not the one it made.
    case slotProblem = "slot-problem"
}

/// `[shep] live: watch ...` lines. Pure: the formatters take numbers, a Bool and a `WatchReason`, so a line cannot hold anything else.
public enum RecordingWatchLog {
    /// A summary line at most this often while nothing changes.
    public static let summaryInterval = 5.0

    /// `[shep] live: watch t=1.25 alive=yes reason=ok`. `t` is seconds since the recording started, two decimals.
    public static func line(t: Double, alive: Bool, reason: WatchReason) -> String {
        LiveLog.prefix + "watch t=\(seconds(t)) alive=\(alive ? "yes" : "no") reason=\(reason.rawValue)"
    }

    /// `[shep] live: watch: 20 checks, all alive (t=5.00)` or `..., 3 not alive (t=...)`.
    public static func summaryLine(t: Double, checks: Int, notAlive: Int) -> String {
        let n = max(0, checks), bad = max(0, notAlive)
        return LiveLog.prefix + "watch: \(n) checks, " + (bad == 0 ? "all alive" : "\(bad) not alive") + " (t=\(seconds(t)))"
    }

    /// Two decimals, clamped to 0...999999 (NaN is 0), so the field always has one shape.
    static func seconds(_ t: Double) -> String {
        let v = t.isNaN ? 0 : min(max(t, 0), 999_999)
        return String(format: "%.2f", v)
    }

    /// The reason for one check, in the order `RecordingWatch.verdict` decides (the first failing check names it).
    /// A confirmed exit comes first: its window goes with it, and `window-missing` would hide why.
    public static func reason(target: RecordingTarget, now: RecordingObservation, moved: Bool) -> WatchReason {
        if now.process == .terminated { return .pidGone }
        guard now.windowOnScreen else { return .windowMissing }
        guard now.windowOwnerPID == target.pid else { return .ownerChanged }
        let current = (now.bundleIDForTargetPID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty { return .bundleEmpty }
        if current.lowercased() != target.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() { return .bundleMismatch }
        if !RecordingPolicy.allowed(bundleID: target.bundleID) || !RecordingPolicy.allowed(bundleID: current) { return .notAllowed }
        if now.frontPID == target.pid, !RecordingPolicy.allowed(bundleID: now.frontBundleID ?? "") { return .forbiddenFront }
        return moved ? .moved : .ok
    }
}

/// Collapses repeats: the first check, every change of alive or reason, and a summary every `summaryInterval` seconds.
public struct RecordingWatchLogState: Equatable, Sendable {
    public private(set) var last: WatchReason?
    public private(set) var lastAlive: Bool?
    public private(set) var checksSinceSummary = 0
    public private(set) var notAliveSinceSummary = 0
    public private(set) var lastSummaryAt = 0.0
    public init() {}

    /// The lines to log for this check (none, one or two).
    public mutating func record(t: Double, alive: Bool, reason: WatchReason) -> [String] {
        var out: [String] = []
        if last != reason || lastAlive != alive {
            out.append(RecordingWatchLog.line(t: t, alive: alive, reason: reason))
            if last == nil { lastSummaryAt = t }
            last = reason
            lastAlive = alive
        }
        checksSinceSummary += 1
        if !alive { notAliveSinceSummary += 1 }
        if t - lastSummaryAt >= RecordingWatchLog.summaryInterval {
            out.append(RecordingWatchLog.summaryLine(t: t, checks: checksSinceSummary, notAlive: notAliveSinceSummary))
            checksSinceSummary = 0
            notAliveSinceSummary = 0
            lastSummaryAt = t
        }
        return out
    }
}
