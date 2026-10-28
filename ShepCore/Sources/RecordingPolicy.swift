import CoreGraphics
import Foundation

// Written for Shep.

/// `--live-record`: what may be recorded, which windows go into the movie, and when a running recording must be discarded.
/// All plain values, so the decisions are testable without a screen. The app (Shep/LiveRecorder.swift) feeds them.
public enum RecordingPolicy {
    /// The same rule as `ScreenCapture.captureWindow` and `TabTintPolicy`: an app on a never-capture list, or one whose
    /// bundle id is unknown, is never recorded.
    public static func allowed(bundleID: String) -> Bool { ControlPolicy.mayCapture(bundleID: bundleID) }

    /// Why a recording must not start, or nil. Checked before anything is captured; the fix itself still runs.
    public static func refusal(bundleID: String?, screenRecordingAllowed: Bool, targetWindowFound: Bool) -> String? {
        let id = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return "the target app's bundle id is unknown" }
        if !allowed(bundleID: id) { return "\(id) is on the never-capture list" }
        if !screenRecordingAllowed { return "Screen Recording is not allowed (for the terminal that launched Shep, or for Shep)" }
        if !targetWindowFound { return "the target window was not found" }
        return nil
    }
}

/// One window the window server lists, reduced to what the selection needs.
public struct RecordingWindow: Equatable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var layer: Int
    public var onScreen: Bool
    /// One of Shep's own overlay windows (the dog tab / panel, the speech and approval cards), not its backdrop or setup window.
    public var isShepOverlay: Bool

    public init(id: UInt32, pid: Int32, layer: Int, onScreen: Bool, isShepOverlay: Bool) {
        self.id = id; self.pid = pid; self.layer = layer; self.onScreen = onScreen; self.isShepOverlay = isShepOverlay
    }
}

/// The windows the content filter draws. Everything else (another app's window, however it overlaps or sits on top) is never
/// listed, so it is never in the movie.
public enum RecordingWindowSelection {
    public static func select(windows: [RecordingWindow], targetPID: Int32, targetWindowID: UInt32, ownPID: Int32) -> [UInt32] {
        var chosen: [UInt32] = []
        for w in windows where w.onScreen {
            let isTarget = w.id == targetWindowID && w.pid == targetPID && targetPID != ownPID && w.layer == 0
            let isOverlay = w.pid == ownPID && w.isShepOverlay
            if (isTarget || isOverlay) && !chosen.contains(w.id) { chosen.append(w.id) }
        }
        return chosen
    }
}

/// The target as it was when the recording started.
public struct RecordingTarget: Equatable, Sendable {
    public var pid: Int32
    public var windowID: UInt32
    public var bundleID: String
    public var frame: CGRect

    public init(pid: Int32, windowID: UInt32, bundleID: String, frame: CGRect) {
        self.pid = pid; self.windowID = windowID; self.bundleID = bundleID; self.frame = frame
    }
}

/// What is known about the target's process. Only `terminated` says it is gone; an empty bundle lookup alone is `unknown`
/// or `alive`, never `terminated` (LESSONS: one failed sample is not an absence).
public enum ProcessFact: String, CaseIterable, Equatable, Sendable {
    case alive
    /// Confirmed: `NSRunningApplication.isTerminated`, or no process with that pid (`kill(pid, 0)` failed with ESRCH).
    case terminated
    case unknown

    /// - Parameters:
    ///   - runningIsTerminated: `NSRunningApplication(processIdentifier:)?.isTerminated`; nil when the lookup gave nothing.
    ///   - killResult, killErrno: `kill(pid, 0)` and errno after it, asked when the lookup gave nothing.
    public static func classify(runningIsTerminated: Bool?, killResult: Int32, killErrno: Int32) -> ProcessFact {
        if let terminated = runningIsTerminated { return terminated ? .terminated : .alive }
        if killResult == 0 { return .alive }
        switch killErrno {
        case ESRCH: return .terminated
        case EPERM: return .alive   // the process exists; it is just not ours to signal
        default: return .unknown
        }
    }
}

/// What the app sees right now.
public struct RecordingObservation: Equatable, Sendable {
    /// The target window's number is still listed as an on-screen window (false once it is closed or minimised).
    public var windowOnScreen: Bool
    /// The process that owns that window number now.
    public var windowOwnerPID: Int32?
    /// The bundle id of the process now running under the target's pid; nil when there is none.
    public var bundleIDForTargetPID: String?
    public var frontPID: Int32?
    public var frontBundleID: String?
    public var frame: CGRect?
    /// What is known about the target's process (`ProcessFact`).
    public var process: ProcessFact

    public init(windowOnScreen: Bool, windowOwnerPID: Int32?, bundleIDForTargetPID: String?, frontPID: Int32? = nil,
                frontBundleID: String? = nil, frame: CGRect? = nil, process: ProcessFact = .unknown) {
        self.windowOnScreen = windowOnScreen; self.windowOwnerPID = windowOwnerPID; self.bundleIDForTargetPID = bundleIDForTargetPID
        self.frontPID = frontPID; self.frontBundleID = frontBundleID; self.frame = frame; self.process = process
    }
}

public enum RecordingVerdict: Equatable, Sendable {
    case keep
    /// Stop the stream and delete the partial file.
    case stop(String)
}

public enum RecordingWatch {
    public static let moveTolerance: CGFloat = 2
    /// The stop reason for a confirmed exit (`ProcessFact.terminated`).
    public static let processEnded = "the target app quit (its process ended)"

    /// Polled every 0.25 s while recording. Window-bound capture does not care which app is in front, so an app switch is not a
    /// stop; the target itself leaving, changing hands or becoming forbidden is.
    public static func verdict(target: RecordingTarget, now: RecordingObservation) -> RecordingVerdict {
        guard now.windowOnScreen else { return .stop("the target window closed or was minimised") }
        guard now.windowOwnerPID == target.pid else { return .stop("the target window changed owner") }
        guard let current = now.bundleIDForTargetPID?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty else {
            return .stop("the target app is gone")
        }
        if current.lowercased() != target.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return .stop("another app now has the target's process id")
        }
        guard RecordingPolicy.allowed(bundleID: target.bundleID), RecordingPolicy.allowed(bundleID: current) else {
            return .stop("the target app is no longer allowed to be recorded")
        }
        if now.frontPID == target.pid, !RecordingPolicy.allowed(bundleID: now.frontBundleID ?? "") {
            return .stop("the app in front is a forbidden app and it is the target")
        }
        return .keep
    }

    /// A log line when the target moved or resized (not a stop: the capture is bound to the window, not to a screen area); nil when it did not.
    public static func movement(from old: CGRect, to new: CGRect?) -> String? {
        guard let new = new, new.minX.isFinite, new.minY.isFinite, new.width.isFinite, new.height.isFinite else { return nil }
        let same = abs(old.minX - new.minX) <= moveTolerance && abs(old.minY - new.minY) <= moveTolerance
            && abs(old.width - new.width) <= moveTolerance && abs(old.height - new.height) <= moveTolerance
        guard !same else { return nil }
        let x = Int(new.minX.rounded()), y = Int(new.minY.rounded()), w = Int(new.width.rounded()), h = Int(new.height.rounded())
        return "target window moved to \(x),\(y),\(w),\(h)"
    }
}

// MARK: the watch over a running recording

/// One window as the window server lists it (CGWindowList), reduced to what the recording watch needs.
public struct RecordingWindowEntry: Equatable, Sendable {
    public var id: UInt32
    public var ownerPID: Int32
    public var bounds: CGRect?
    public init(id: UInt32, ownerPID: Int32, bounds: CGRect?) { self.id = id; self.ownerPID = ownerPID; self.bounds = bounds }
}

/// Watches a running recording tick by tick. The window server's answer (the window is listed, owned by the target's pid) is
/// immediate and decides alone. Who the process is comes from a separate lookup (NSRunningApplication) that can come back empty
/// for one tick while the window is plainly there; that is tolerated for `unresolvedLimit` ticks in a row (1.5 s at the 0.25 s
/// poll), then stops the recording with its own reason. The process is never called "gone" on that evidence.
public struct RecordingWatchState: Equatable, Sendable {
    public static let unresolvedLimit = 6
    public private(set) var unresolvedTicks = 0
    public init() {}

    public mutating func verdict(target: RecordingTarget, now: RecordingObservation) -> RecordingVerdict {
        if now.process == .terminated {
            unresolvedTicks = 0
            return .stop(RecordingWatch.processEnded)
        }
        let bundle = (now.bundleIDForTargetPID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if now.windowOnScreen, now.windowOwnerPID == target.pid, bundle.isEmpty {
            unresolvedTicks += 1
            if unresolvedTicks >= Self.unresolvedLimit {
                return .stop("could not confirm which app owns the target window for \(unresolvedTicks) checks in a row")
            }
            return .keep
        }
        unresolvedTicks = 0
        return RecordingWatch.verdict(target: target, now: now)
    }
}

extension RecordingWatch {
    /// What the app sees right now, from the window server's list and two lookups of the target's bundle id: by pid, and when that
    /// comes back empty, by bundle id (the running instances of the id the target had, which must include the target's own pid).
    public static func observe(target: RecordingTarget, windows: [RecordingWindowEntry], bundleForPID: (Int32) -> String?,
                               pidsForBundle: (String) -> [Int32], frontPID: Int32?, frontBundleID: String?,
                               processFact: (Int32) -> ProcessFact = { _ in .unknown }) -> RecordingObservation {
        let entry = windows.first { $0.id == target.windowID }
        var bundle = bundleForPID(target.pid)
        if (bundle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pidsForBundle(target.bundleID).contains(target.pid) {
            bundle = target.bundleID
        }
        return RecordingObservation(windowOnScreen: entry != nil, windowOwnerPID: entry?.ownerPID, bundleIDForTargetPID: bundle,
                                    frontPID: frontPID, frontBundleID: frontBundleID, frame: entry?.bounds, process: processFact(target.pid))
    }
}
