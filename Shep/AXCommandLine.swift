import AppKit
import ApplicationServices
import Foundation
import ShepCore

/// Headless tools that read an app through Accessibility, for scripts and for checking what Shep sees:
///   `Shep --ax-read-once <pid|bundle-id> [--title t] [--frame x,y,w,h]`  prints what was read. Reads only.
///   `Shep --press-demo-once <pid|bundle-id> --match "<text>" [--title t] [--frame f] [--approve]`
///       proposes AXPress on the one matching control. It goes through ApprovalPolicy and ActionRunner like every action;
///       without --approve it stops at the approval card and does nothing. --approve is the operator's explicit yes for that
///       one control, typed on the command line. The app itself has no such mode: its approval card always asks.
enum AXCommandLine {
    /// How many controls the app's own flow keeps (FixScreenCoordinator).
    static let appControlLimit = 60

    static func processID(for target: ProcessTarget) -> pid_t? {
        switch target {
        case .pid(let p):
            return NSRunningApplication(processIdentifier: pid_t(p)) == nil ? nil : pid_t(p)
        case .bundleID(let id):
            return AXReader.pid(forBundleID: id)
        }
    }

    /// What `--fix-screen-once` gets from Accessibility.
    struct FixScreenAX {
        var controls: [Control] = []
        var modalInFront = false
        /// One line for the report: what was read.
        var note = ""
    }

    /// The system's answers about running apps, for `CLITarget`: the bundle identifier comes from the process itself.
    struct SystemLookup: CLIAppLookup {
        var accessibilityAllowed: Bool { AXIsProcessTrusted() }
        func bundleID(ofPID pid: Int32) -> String? { NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier }
        func runningPIDs(forBundleID id: String) -> [Int32] {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).map { app in Int32(app.processIdentifier) }
        }
    }

    /// Reads the window of the already resolved app (`CLITarget`), targeting SHEP_WINDOW_FRAME / SHEP_WINDOW_TITLE.
    /// nil when no window could be read: the caller refuses, it never carries on without the controls.
    static func fixScreenControls(pid: Int32, environment: [String: String], frame: CGRect?) -> FixScreenAX? {
        let title = (environment["SHEP_WINDOW_TITLE"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot = AXReader.read(pid: pid_t(pid), targetFrame: frame, targetTitle: title.isEmpty ? nil : title) else {
            print("ax: could not read a window of pid \(pid)")
            return nil
        }
        var result = FixScreenAX()
        result.controls = ControlFilter.prepare(snapshot.controls, limit: appControlLimit, window: snapshot.windowFrame)
        result.modalInFront = snapshot.modalInFront
        result.note = "ax: read \(result.controls.count) controls from window \"\(snapshot.windowTitle)\" of \(snapshot.appName) "
            + "(pid \(pid), frame \(AXReadReport.frameText(snapshot.windowFrame)); "
            + "\(snapshot.nodesVisited) nodes\(snapshot.truncated ? ", truncated" : ""))"
        return result
    }

    private static func openSnapshot(_ tool: String, target: String, title: String?, frame: CGRect?) -> AXSnapshot? {
        guard AXIsProcessTrusted() else {
            print("\(tool): Accessibility is not allowed for this process (System Settings > Privacy & Security > Accessibility)")
            return nil
        }
        guard let parsed = ProcessTarget.parse(target), let pid = processID(for: parsed) else {
            print("\(tool): no running app for \"\(target)\"")
            return nil
        }
        guard let snapshot = AXReader.read(pid: pid, targetFrame: frame, targetTitle: title) else {
            print("\(tool): could not read a window of pid \(pid)")
            return nil
        }
        print("app: pid=\(pid) bundle=\(snapshot.bundleID) name=\(snapshot.appName)")
        return snapshot
    }

    // MARK: --ax-read-once

    static func readOnce(target: String, title: String?, frame: CGRect?, environment: [String: String]) -> Int32 {
        let wantedFrame = frame ?? environment["SHEP_WINDOW_FRAME"].flatMap { CoordinateSpace.parseFrame($0) }
        let wantedTitle = title ?? environment["SHEP_WINDOW_TITLE"]
        guard let snapshot = openSnapshot("ax-read-once", target: target, title: wantedTitle, frame: wantedFrame) else { return 3 }
        let kept = ControlFilter.prepare(snapshot.controls, limit: appControlLimit, window: snapshot.windowFrame)
        print(AXReadReport.render(windows: snapshot.windows, nodesVisited: snapshot.nodesVisited, kept: kept,
                                  truncated: snapshot.truncated, modalInFront: snapshot.modalInFront))
        return 0
    }

    // MARK: --press-demo-once

    static func pressDemo(target: String, match: String, title: String?, frame: CGRect?, approve: Bool,
                          environment: [String: String]) async -> Int32 {
        let wantedFrame = frame ?? environment["SHEP_WINDOW_FRAME"].flatMap { CoordinateSpace.parseFrame($0) }
        let wantedTitle = title ?? environment["SHEP_WINDOW_TITLE"]
        guard let snapshot = openSnapshot("press-demo-once", target: target, title: wantedTitle, frame: wantedFrame) else { return 3 }
        print("window: \"\(snapshot.windowTitle)\" frame=\(AXReadReport.frameText(snapshot.windowFrame)) modal_in_front=\(AXReadReport.yesNo(snapshot.modalInFront))")

        let controls = ControlFilter.prepare(snapshot.controls, limit: 200, window: snapshot.windowFrame)
        let selection = PressDemo.select(controls, match: match)
        if let why = PressDemo.refusal(selection, match: match) {
            print("refused: \(why)")
            switch selection {
            case .ambiguous(let list), .disabledOnly(let list):
                for c in list { print(AXReadReport.controlLine(c)) }
            default:
                break
            }
            return 4
        }
        guard case .one(let control) = selection, let element = snapshot.elements[control.pathID] else {
            print("refused: the matching control has no live element")
            return 4
        }
        print("match: \"\(match)\" -> 1 control")
        print(AXReadReport.controlLine(control))
        let before = AXReader.valueDescription(of: element)
        print("value_before: \(before ?? "(none)")")

        let action = PressDemo.proposal(for: control, bundleID: snapshot.bundleID)
        print("approval card:")
        print(PressDemo.preview(action))
        let performer = ActionPerformer(snapshot: snapshot, windowNumber: nil, beforeClick: {}, afterClick: {})
        let outcome = await PressDemo.run(control: control, bundleID: snapshot.bundleID, approveFlag: approve, executor: performer,
                                          log: { line in print(line) })
        switch outcome {
        case .done(let what):
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let after = AXReader.valueDescription(of: element)
            print("outcome: pressed (\(what))")
            print("value_after: \(after ?? "(none)")")
            print("changed: \(AXReadReport.yesNo(PressDemo.changed(before: before, after: after)))")
            return 0
        case .declined:
            print("outcome: nothing done")
            return 0
        case .refused(let why):
            print("refused: \(why)")
            return 4
        case .failed(let why), .needsFreshApproval(let why):
            print("failed: \(why)")
            return 5
        case .cancelled:
            print("failed: cancelled")
            return 5
        }
    }
}
