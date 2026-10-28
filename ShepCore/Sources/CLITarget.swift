import CoreGraphics
import Foundation

// Written for Shep.

/// What the command line may ask the system about running apps. The app implements it with NSRunningApplication and the
/// Accessibility trust check; tests use a fake.
public protocol CLIAppLookup {
    /// Accessibility is allowed for this process.
    var accessibilityAllowed: Bool { get }
    /// The bundle identifier of the running app with this process id (what the system says, not what the caller claims).
    /// nil when no such process runs.
    func bundleID(ofPID pid: Int32) -> String?
    /// Process ids of the running apps with this bundle identifier.
    func runningPIDs(forBundleID id: String) -> [Int32]
}

/// Who a `--fix-screen-once` screenshot belongs to, decided BEFORE any provider work.
///
/// If SHEP_AX_PID or SHEP_WINDOW_OWNER names an app, its bundle identifier must be resolved independently of the caller's
/// words and pass `ControlPolicy.mayCapture`; anything unresolved, stale, empty or disagreeing refuses. Nothing falls back to
/// a made-up identifier. A bare image with neither variable is an explicitly unattested, user-supplied file.
public enum CLITarget {
    /// The bundle identifier used for a bare image. It says nothing about the app the pixels came from.
    public static let unattestedBundleID = "cli.fix-screen-once"
    public static let unattestedNotice = "note: unattested image: no SHEP_AX_PID or SHEP_WINDOW_OWNER names the app it came from, "
        + "so Shep cannot check that app against its capture policy; you are responsible for what you hand it"

    public enum Decision: Equatable, Sendable {
        case app(pid: Int32, bundleID: String)
        case unattestedFile
        case refused(String)
    }

    /// The decision as the run uses it.
    public struct Resolved: Equatable, Sendable {
        public var pid: Int32?
        public var bundleID: String
        public var attested: Bool
        public init(pid: Int32?, bundleID: String, attested: Bool) { self.pid = pid; self.bundleID = bundleID; self.attested = attested }
    }

    static func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    public static func resolve(environment: [String: String], lookup: any CLIAppLookup) -> Decision {
        let ownerText = trimmed(environment["SHEP_WINDOW_OWNER"])
        let pidText = trimmed(environment["SHEP_AX_PID"])
        if ownerText.isEmpty, pidText.isEmpty {
            // A frame says where the pixels sit; a frame AND a title say a live window was captured. A capture that lost its
            // owner (the script could not resolve the pid) must not pass as a bare file.
            if !trimmed(environment["SHEP_WINDOW_FRAME"]).isEmpty, !trimmed(environment["SHEP_WINDOW_TITLE"]).isEmpty {
                return .refused("SHEP_WINDOW_FRAME and SHEP_WINDOW_TITLE describe a captured window, but neither SHEP_AX_PID nor "
                                + "SHEP_WINDOW_OWNER says which app it belongs to, so I can't check it against the capture policy. I did nothing.")
            }
            return .unattestedFile
        }
        guard lookup.accessibilityAllowed else {
            return .refused("Accessibility is not allowed for this process, so I can't tell which app the image came from. I did nothing.")
        }
        var suppliedPID: Int32?
        if !pidText.isEmpty {
            let digits = pidText.unicodeScalars.allSatisfy { scalar in scalar.value >= 48 && scalar.value <= 57 }
            guard digits, let n = Int32(pidText), n > 0 else {
                return .refused("SHEP_AX_PID \"\(pidText.prefix(20))\" is not a process id. I did nothing.")
            }
            suppliedPID = n
        }
        let pid: Int32
        if let given = suppliedPID {
            pid = given
        } else {
            guard let first = lookup.runningPIDs(forBundleID: ownerText).first else {
                return .refused("No running app has the bundle identifier \"\(ownerText.prefix(80))\", so I can't tell which app the image came from. I did nothing.")
            }
            pid = first
        }
        let resolved = trimmed(lookup.bundleID(ofPID: pid))
        guard !resolved.isEmpty else {
            return .refused("I can't resolve process \(pid) to an app (it may have quit), so I can't tell which app the image came from. I did nothing.")
        }
        if !ownerText.isEmpty, ownerText.lowercased() != resolved.lowercased() {
            return .refused("SHEP_WINDOW_OWNER says \"\(ownerText.prefix(80))\" but process \(pid) is \"\(resolved)\". I did nothing.")
        }
        guard ControlPolicy.mayCapture(bundleID: resolved) else {
            return .refused("Shep never looks at \"\(resolved)\" windows, so I did nothing.")
        }
        return .app(pid: pid, bundleID: resolved)
    }
}

/// The whole `--fix-screen-once` decision and run, apart from reading pixels and Accessibility (the caller's closure).
public enum CLIFixScreen {
    public struct Outcome: Sendable {
        /// A one-line notice to print before the result (the unattested-image note).
        public var notice: String?
        /// Set when nothing was sent anywhere; the caller exits non-zero with this message.
        public var refusal: String?
        public var result: FixScreenResult?
        public init(notice: String? = nil, refusal: String? = nil, result: FixScreenResult? = nil) {
            self.notice = notice; self.refusal = refusal; self.result = result
        }
    }

    /// `makeInput` builds the provider input for the resolved target (reading its controls) and returns nil when that read
    /// fails; a named target that cannot be read is refused. The provider is reached only through the pipeline, after the
    /// target was resolved, and the input's bundle identifier is always the resolved one.
    public static func run(environment: [String: String], lookup: any CLIAppLookup, pipeline: FixScreenPipeline,
                           makeInput: (CLITarget.Resolved) -> VisionInput?) async -> Outcome {
        let resolved: CLITarget.Resolved
        var notice: String?
        switch CLITarget.resolve(environment: environment, lookup: lookup) {
        case .refused(let why):
            return Outcome(refusal: why)
        case .unattestedFile:
            resolved = CLITarget.Resolved(pid: nil, bundleID: CLITarget.unattestedBundleID, attested: false)
            notice = CLITarget.unattestedNotice
        case .app(let pid, let bundleID):
            resolved = CLITarget.Resolved(pid: pid, bundleID: bundleID, attested: true)
        }
        guard var input = makeInput(resolved) else {
            return Outcome(notice: notice, refusal: "I could not read a window of that app, so I can't tell what the image shows. I did nothing.")
        }
        input.bundleID = resolved.bundleID
        let result = await pipeline.run(input)
        return Outcome(notice: notice, result: result)
    }
}
