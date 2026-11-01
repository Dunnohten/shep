import Foundation

/// Launch flags: `--dock-demo` (or SHEP_DOCK_DEMO=1) shows the overlay immediately, permissions or not, and logs tracker state to stdout.
/// Optional `--theme=Cobalt` and `--state=thinking` (or SHEP_THEME / SHEP_STATE) pick the starting look.
public struct LaunchOptions: Equatable {
    public var dockDemo: Bool
    public var theme: ShepTheme
    public var state: ShepDogState
    /// `--fix-screen-once <png>`: run the Fix-this-screen pipeline once on that file, print the result and timing, exit.
    public var fixScreenOncePath: String?
    /// `--demo-script`: run the timed animation sequence (dock, idle, blink, listening, thinking, drag and snap-back, idle) once.
    public var demoScript = false
    /// `--demo-script=cycle` (or `--demo-script cycle`, SHEP_DEMO_SCRIPT=cycle): asleep 3 s, call, travel to the front window's tab,
    /// listening 2 s, thinking 2 s, dismiss, walk home, asleep 3 s (scripts/record-cycle.sh). Not the same as `demoScript`.
    public var demoCycle = false
    /// `--demo-backdrop` (with `--demo-script=cycle`): Shep draws its own plain backdrop behind everything it shows, so a recording
    /// of that rectangle holds only Shep-owned pixels and the test window.
    public var demoBackdrop = false
    /// `--ui-snapshot <dir>` (or `=<dir>`): developer-only. Render Shep's own views offscreen to PNG files in that directory and exit.
    /// No status item, hotkeys, microphone, tracker or on-screen window. nil without the flag or with an unusable value.
    public var uiSnapshotDir: String?
    /// `--export-bark=<path.wav>`: write the recorded bark (`BarkSound`) as a WAV file and exit.
    public var exportBarkPath: String?
    /// `--ax-read-once <pid|bundle-id>`: read the app's windows through Accessibility, print what was seen, exit. Read-only.
    public var axReadOnceTarget: String?
    /// `--press-demo-once <pid|bundle-id> --match "<text>"`: propose AXPress on the one control whose label or tooltip contains
    /// the text; it presses only with `--approve`.
    public var pressDemoTarget: String?
    public var pressMatch: String?
    /// `--title <text>` and `--frame x,y,w,h` pick the target window for the two flags above.
    public var toolTitle: String?
    public var toolFrame: CGRect?
    /// `--approve`: the operator's explicit yes for the one press of `--press-demo-once`. Nothing else reads it.
    public var approveFlag = false
    /// `--live-request "<text>"` (or `=<text>`, SHEP_LIVE_REQUEST): after Shep has arrived at the front window, submit this text
    /// exactly as the ask field does. It only submits the request; the approval card still needs a person's answer. Trimmed;
    /// nil when empty or when the value looks like another flag.
    public var liveRequest: String?

    /// `--live-record <out.mov>` (or `=<path>`, SHEP_LIVE_RECORD), used with `--live-request`: Shep records the target window (window-bound,
    /// through the capture policy) to that file. nil without `--live-request`; then `liveRecordIgnoredLine` says so.
    public var liveRecordPath: String?
    /// `--live-record-seconds N` (SHEP_LIVE_RECORD_SECONDS): the longest recording, 10 to 600, default 70.
    public var liveRecordSeconds = LaunchOptions.defaultLiveRecordSeconds
    /// The log line to print when `--live-record` was given without `--live-request`.
    public var liveRecordIgnoredLine: String?
    public static let defaultLiveRecordSeconds = 70
    /// `--live-debug-dir <dir>` (or `=<dir>`, SHEP_LIVE_DEBUG_DIR), used with `--live-request`: every live run writes what it handed
    /// the provider and decided into `<dir>/<yyyyMMdd-HHmmss>/` (see `LiveDebug`). nil without the flag, and without `--live-request`
    /// (then `liveDebugIgnoredLine` says so). Nothing is written when this is nil.
    public var liveDebugDir: String?
    /// The log line to print when `--live-debug-dir` was given without `--live-request`.
    public var liveDebugIgnoredLine: String?

    /// `--live-target <bundle-id>` (or `=<id>`, SHEP_LIVE_TARGET), used with `--live-request`: the live request is bound to that app.
    /// Shep activates it, waits for it to be in front (`LiveTargetGate`), and refuses, reading nothing, if it is not. Characters
    /// `[A-Za-z0-9._-]` only. nil without the flag (the front app is the target, and the log says which), when the value is unusable
    /// (then `liveTargetInvalid` says why and the run is refused) or when `--live-request` is missing (then `liveTargetIgnoredLine` says so).
    public var liveTarget: String?
    /// The log line to print when `--live-target` was given but ignored (only: `--live-request` is missing).
    public var liveTargetIgnoredLine: String?
    /// Why the binding is unusable, bundle-id-free (for example "--live-target is not a bundle id"), set when `--live-request` is
    /// present and `--live-target` or SHEP_LIVE_TARGET was supplied but cannot be used: a missing, empty, too long or malformed
    /// value. An explicit binding that cannot be honoured refuses the live run (`LiveRequestStart.decide`); it never falls back to
    /// the front app. If either of the two (flag, environment) is unusable the run is refused, even when the other is valid; when
    /// both are valid the flag wins. nil when nothing was supplied (the default front-app behaviour) or the binding is usable.
    public var liveTargetInvalid: String?

    /// `--live-status <file>` and `--live-nonce <hex>` (or `=<value>`, SHEP_LIVE_STATUS / SHEP_LIVE_NONCE), used with `--live-request`: the
    /// structured status channel scripts classify a run from (`LiveStatus`). Both are needed together: an absolute path, and 16 to 64
    /// characters of [0-9a-f]. nil without the flags, and without `--live-request` (then `liveStatusIgnoredLine` says so).
    public var liveStatusPath: String?
    public var liveNonce: String?
    /// Why the status binding is unusable (never contains the nonce): set with `--live-request` when a value is missing, empty or
    /// malformed, or only one of the two was given. It refuses the live run (`LiveRequestStart.decide`), like `--live-target`.
    public var liveStatusInvalid: String?
    /// The log line to print when the status flags were given without `--live-request`.
    public var liveStatusIgnoredLine: String?

    public init(dockDemo: Bool = false, theme: ShepTheme = ShepThemes.defaultTheme, state: ShepDogState = .idle) {
        self.dockDemo = dockDemo; self.theme = theme; self.state = state
    }

    public static func parse(arguments: [String], environment: [String: String]) -> LaunchOptions {
        var o = LaunchOptions()
        let truthy: Set<String> = ["1", "true", "yes"]
        o.fixScreenOncePath = fixScreenPath(arguments)
        o.axReadOnceTarget = argumentValue("--ax-read-once", in: arguments)
        o.pressDemoTarget = argumentValue("--press-demo-once", in: arguments)
        o.pressMatch = argumentValue("--match", in: arguments)
        o.toolTitle = argumentValue("--title", in: arguments)
        o.toolFrame = argumentValue("--frame", in: arguments).flatMap { CoordinateSpace.parseFrame($0) }
        o.approveFlag = arguments.contains("--approve")
        o.uiSnapshotDir = argumentValue("--ui-snapshot", in: arguments)
        o.liveRequest = liveRequestText(arguments: arguments, environment: environment)
        let wantedRecord = liveRecordValue(arguments: arguments, environment: environment)
        o.liveRecordSeconds = liveRecordSeconds(arguments: arguments, environment: environment)
        if let wantedRecord = wantedRecord {
            if o.liveRequest != nil { o.liveRecordPath = wantedRecord } else { o.liveRecordIgnoredLine = LiveLog.prefix + "ignored: --live-record needs --live-request" }
        }
        if let wantedDebug = liveDebugValue(arguments: arguments, environment: environment) {
            if o.liveRequest != nil { o.liveDebugDir = wantedDebug } else { o.liveDebugIgnoredLine = LiveLog.prefix + "ignored: --live-debug-dir needs --live-request" }
        }
        let target = liveTargetBinding(arguments: arguments, environment: environment)
        if o.liveRequest == nil {
            if target.wanted != nil || target.invalid != nil { o.liveTargetIgnoredLine = LiveLog.prefix + "ignored: --live-target needs --live-request" }
        } else if let why = target.invalid {
            o.liveTargetInvalid = why
        } else {
            o.liveTarget = target.wanted
        }
        let status = liveStatusBinding(arguments: arguments, environment: environment)
        if o.liveRequest == nil {
            if status.supplied { o.liveStatusIgnoredLine = LiveLog.prefix + "ignored: --live-status needs --live-request" }
        } else if let why = status.invalid {
            o.liveStatusInvalid = why
        } else {
            o.liveStatusPath = status.path
            o.liveNonce = status.nonce
        }
        let scriptName = demoScriptName(arguments) ?? (environment["SHEP_DEMO_SCRIPT"] ?? "").lowercased()
        o.demoCycle = scriptName == "cycle"
        o.demoBackdrop = arguments.contains("--demo-backdrop") || truthy.contains((environment["SHEP_DEMO_BACKDROP"] ?? "").lowercased())
        if let a = arguments.first(where: { $0.hasPrefix("--export-bark=") }) {
            let v = String(a.dropFirst("--export-bark=".count))
            o.exportBarkPath = v.isEmpty ? nil : v
        }
        o.demoScript = !o.demoCycle && (arguments.contains("--demo-script") || truthy.contains(scriptName))
        o.dockDemo = arguments.contains("--dock-demo") || truthy.contains((environment["SHEP_DOCK_DEMO"] ?? "").lowercased())
        func value(_ flag: String, env: String) -> String? {
            let prefix = flag + "="
            if let a = arguments.first(where: { $0.hasPrefix(prefix) }) { return String(a.dropFirst(prefix.count)) }
            return environment[env]
        }
        if let t = value("--theme", env: "SHEP_THEME") { o.theme = ShepThemes.find(t) }
        if let s = value("--state", env: "SHEP_STATE"), let st = ShepDogState(rawValue: s) { o.state = st }
        return o
    }

    /// The `--live-request` text: the flag if it has a usable value, else SHEP_LIVE_REQUEST. Trimmed; nil when empty or flag-like.
    static func liveRequestText(arguments: [String], environment: [String: String]) -> String? {
        func usable(_ raw: String?) -> String? {
            guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("--") else { return nil }
            return t
        }
        return usable(argumentValue("--live-request", in: arguments)) ?? usable(environment["SHEP_LIVE_REQUEST"])
    }

    /// The `--live-target` flag and SHEP_LIVE_TARGET together: the usable bundle id (the flag's if both are usable) and the first
    /// reason a supplied value is unusable (the flag's before the environment's). Nothing supplied gives neither.
    static func liveTargetBinding(arguments: [String], environment: [String: String]) -> (wanted: String?, invalid: String?) {
        let flag = "--live-target"
        var wanted: String?
        var invalid: String?
        var supplied: String?
        for (i, a) in arguments.enumerated() {
            if a == flag {
                let next = i + 1 < arguments.count ? arguments[i + 1] : ""
                supplied = next.hasPrefix("--") ? "" : next   // another flag is no value
                break
            }
            if a.hasPrefix(flag + "=") {
                supplied = String(a.dropFirst(flag.count + 1))
                break
            }
        }
        if let value = supplied {
            if let why = LiveTargetGate.invalidReason(value, source: flag) { invalid = why } else { wanted = value }
        }
        if let env = environment["SHEP_LIVE_TARGET"] {
            if let why = LiveTargetGate.invalidReason(env, source: "SHEP_LIVE_TARGET") {
                if invalid == nil { invalid = why }
            } else if wanted == nil {
                wanted = env
            }
        }
        return (invalid == nil ? wanted : nil, invalid)
    }

    /// What was supplied for one option: the flag's value (`--flag v` or `--flag=v`; "" when it has no value or the next argument is
    /// another flag) and the environment variable's value. nil for whichever was not given.
    private static func suppliedValue(flag: String, env: String, arguments: [String], environment: [String: String]) -> (flag: String?, env: String?) {
        var fromFlag: String?
        for (i, a) in arguments.enumerated() {
            if a == flag {
                let next = i + 1 < arguments.count ? arguments[i + 1] : ""
                fromFlag = next.hasPrefix("--") ? "" : next
                break
            }
            if a.hasPrefix(flag + "=") {
                fromFlag = String(a.dropFirst(flag.count + 1))
                break
            }
        }
        return (fromFlag, environment[env])
    }

    /// The status file path and nonce from the flags and the environment. Anything supplied but unusable, or only one of the two,
    /// is invalid (the first reason wins; the flag is judged before the environment). The nonce is never part of a reason.
    static func liveStatusBinding(arguments: [String], environment: [String: String]) -> (path: String?, nonce: String?, invalid: String?, supplied: Bool) {
        let pathValues = suppliedValue(flag: "--live-status", env: "SHEP_LIVE_STATUS", arguments: arguments, environment: environment)
        let nonceValues = suppliedValue(flag: "--live-nonce", env: "SHEP_LIVE_NONCE", arguments: arguments, environment: environment)
        let supplied = pathValues.flag != nil || pathValues.env != nil || nonceValues.flag != nil || nonceValues.env != nil
        guard supplied else { return (nil, nil, nil, false) }
        var invalid: String?
        var path: String?
        var nonce: String?
        let pathCandidates: [(String?, String)] = [(pathValues.flag, "--live-status"), (pathValues.env, "SHEP_LIVE_STATUS")]
        for (value, name) in pathCandidates {
            guard let value = value else { continue }
            if LiveStatus.isUsablePath(value) { if path == nil { path = value } }
            else if invalid == nil { invalid = name + " is not an absolute file path" }
        }
        let nonceCandidates: [(String?, String)] = [(nonceValues.flag, "--live-nonce"), (nonceValues.env, "SHEP_LIVE_NONCE")]
        for (value, name) in nonceCandidates {
            guard let value = value else { continue }
            if LiveStatus.isValidNonce(value) { if nonce == nil { nonce = value } }
            else if invalid == nil { invalid = name + " is not 16 to 64 lowercase hex characters" }
        }
        if invalid == nil && path == nil { invalid = "--live-status is missing (--live-nonce needs it)" }
        if invalid == nil && nonce == nil { invalid = "--live-nonce is missing (--live-status needs it)" }
        if invalid != nil { return (nil, nil, invalid, true) }
        return (path, nonce, nil, true)
    }

    static func liveRecordValue(arguments: [String], environment: [String: String]) -> String? {
        func usable(_ raw: String?) -> String? {
            guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("--") else { return nil }
            return t
        }
        return usable(argumentValue("--live-record", in: arguments)) ?? usable(environment["SHEP_LIVE_RECORD"])
    }

    static func liveDebugValue(arguments: [String], environment: [String: String]) -> String? {
        func usable(_ raw: String?) -> String? {
            guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("--") else { return nil }
            return t
        }
        return usable(argumentValue("--live-debug-dir", in: arguments)) ?? usable(environment["SHEP_LIVE_DEBUG_DIR"])
    }

    /// Whole seconds from the flag, else the environment; anything else (or out of 10...600) is the default.
    static func liveRecordSeconds(arguments: [String], environment: [String: String]) -> Int {
        func parse(_ raw: String?) -> Int? {
            guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), let n = Int(t), n >= 10, n <= 600 else { return nil }
            return n
        }
        return parse(argumentValue("--live-record-seconds", in: arguments)) ?? parse(environment["SHEP_LIVE_RECORD_SECONDS"]) ?? defaultLiveRecordSeconds
    }

    /// The value of `--demo-script=<name>` or `--demo-script <name>`; nil for the bare flag.
    static func demoScriptName(_ arguments: [String]) -> String? {
        let flag = "--demo-script"
        for (i, a) in arguments.enumerated() {
            if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)).lowercased() }
            if a == flag, i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") { return arguments[i + 1].lowercased() }
        }
        return nil
    }

    /// The value of `--flag value` or `--flag=value`; nil when the flag is absent or its value is empty or looks like another flag.
    public static func argumentValue(_ flag: String, in arguments: [String]) -> String? {
        for (i, a) in arguments.enumerated() {
            if a == flag {
                let next = i + 1 < arguments.count ? arguments[i + 1] : ""
                return next.isEmpty || next.hasPrefix("--") ? nil : next
            }
            if a.hasPrefix(flag + "=") {
                let v = String(a.dropFirst(flag.count + 1))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    static func fixScreenPath(_ arguments: [String]) -> String? {
        let flag = "--fix-screen-once"
        for (i, a) in arguments.enumerated() {
            if a == flag {
                let next = i + 1 < arguments.count ? arguments[i + 1] : ""
                return next.isEmpty || next.hasPrefix("--") ? nil : next
            }
            if a.hasPrefix(flag + "=") {
                let v = String(a.dropFirst(flag.count + 1))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }
}

/// An app named on a command line: a process id (digits only) or a bundle identifier.
public enum ProcessTarget: Equatable, Sendable {
    case pid(Int32)
    case bundleID(String)

    public static func parse(_ text: String) -> ProcessTarget? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let digits = t.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
        if digits {
            guard let n = Int32(t), n > 0 else { return nil }
            return .pid(n)
        }
        return .bundleID(t)
    }

    /// For `--fix-screen-once`: SHEP_AX_PID (a pid) wins over SHEP_WINDOW_OWNER (a bundle identifier).
    public static func from(environment: [String: String]) -> ProcessTarget? {
        if let p = environment["SHEP_AX_PID"], let t = parse(p), case .pid = t { return t }
        if let o = environment["SHEP_WINDOW_OWNER"] { return parse(o) }
        return nil
    }
}
