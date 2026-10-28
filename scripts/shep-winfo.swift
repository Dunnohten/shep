// Prints "id x y w h title" (global points, top-left origin; the title, when readable, is the rest of the line) of the
// frontmost on-screen window of an app.
//   xcrun swift scripts/shep-winfo.swift TextEdit "Shep test"
// Arguments: owner app name, then an optional title fragment. Window titles of other apps are only visible with
// Screen Recording allowed; when no window of that app has a title, the frontmost window of the app is used.
// Exit status: 0 found, 1 not found, 2 bad usage, 3 move failed.
//
// Frontmost mode: succeeds only when the app is frontmost AND its focused window's title contains the fragment:
//   xcrun swift scripts/shep-winfo.swift --frontmost TextEdit "Shep test"
// Uses NSWorkspace.frontmostApplication and the app's AXFocusedWindow (the terminal needs Accessibility access). Prints
// "frontmost=<app> focused=<title>" and exits 0 (yes) or 1 (no); it never changes focus.
//
// Pid mode: prints only the process id of the window that the normal mode would print (same owner and title matching):
//   xcrun swift scripts/shep-winfo.swift --pid TextEdit "Shep test"
// The normal "id x y w h title" line is unchanged; scripts that need the pid ask with --pid. Used by scripts/e2e-glimmer.sh
// so `Shep --fix-screen-once` can read the same app through Accessibility (SHEP_AX_PID).
//
// Bundle mode: prints the bundle identifier of the application that owns the window the normal mode would print (same owner and
// title matching, then NSRunningApplication(processIdentifier:)?.bundleIdentifier). Exits 1 and prints nothing when the window or
// the identifier cannot be resolved; callers must treat that as a refusal:
//   xcrun swift scripts/shep-winfo.swift --bundle TextEdit "Shep test"
// Used by scripts/e2e-glimmer.sh to apply the never-capture list before anything is captured.
//
// Record mode: prints ONE line, `id pid bundle x y w h title`, for the one window selected from ONE window-list snapshot; the
// bundle is NSRunningApplication(processIdentifier: pid)?.bundleIdentifier of THAT window's owner pid, so the three always describe
// the same window. Matching is the owner name (layer 0, larger than 50 x 50) plus the title fragment (empty matches all); there is
// no untitled fallback. Exit 4 with a message on stderr (and nothing on stdout) when nothing matches, when several windows match
// from different processes, when several windows of one process match and that process is not the frontmost application
// (z-order is trusted only for the frontmost app), or when the pid has no usable bundle identifier ([A-Za-z0-9._-]):
//   xcrun swift scripts/shep-winfo.swift --record TextEdit "Shep test"
// Verify mode: `--verify <window id> <pid> <bundle id> <x> <y> <w> <h> <title>` takes a fresh snapshot and exits 0 only if that exact
// window id is on screen, at layer 0, owned by that pid, that pid's bundle identifier is exactly <bundle>, the title is the same
// (the title is ONE argument and may be empty; newlines count as spaces and the ends are trimmed, as `--record` prints it) and the
// frame is the same in integer points, exactly (rounded the way `--record` prints it). Otherwise it exits 1 with a one-line reason on
// stderr (it never prints a title). Used by scripts/e2e-glimmer.sh before AND after screencapture:
//   xcrun swift scripts/shep-winfo.swift --verify 4711 321 com.apple.TextEdit 200 200 640 480 "Shep test"
// This narrows window churn between the record and the capture; no capture API binds the selected object, so it is not atomic.
// Exit status of the other modes: 0 found, 1 not found, 2 bad usage, 3 move failed.
//
// Move mode: moves that one window (matched by owner and title fragment) with the Accessibility API, nothing else:
//   xcrun swift scripts/shep-winfo.swift --move TextEdit "Shep test" 200 200
// sets kAXPositionAttribute (global points, top-left origin) on the matching AX window only. The terminal running it needs
// Accessibility access. Prints the window's new "id x y w h title" line.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

var args = CommandLine.arguments
let moveMode = args.count > 1 && args[1] == "--move"
if moveMode { args.remove(at: 1) }
let frontMode = !moveMode && args.count > 1 && args[1] == "--frontmost"
if frontMode { args.remove(at: 1) }
let pidMode = !moveMode && !frontMode && args.count > 1 && args[1] == "--pid"
if pidMode { args.remove(at: 1) }
let bundleMode = !moveMode && !frontMode && !pidMode && args.count > 1 && args[1] == "--bundle"
if bundleMode { args.remove(at: 1) }
let recordMode = !moveMode && !frontMode && !pidMode && !bundleMode && args.count > 1 && args[1] == "--record"
if recordMode { args.remove(at: 1) }
let verifyMode = !moveMode && !frontMode && !pidMode && !bundleMode && !recordMode && args.count > 1 && args[1] == "--verify"
if verifyMode { args.remove(at: 1) }
guard args.count >= 2, !moveMode || args.count >= 5, !verifyMode || args.count >= 9 else {
    FileHandle.standardError.write(Data("usage: shep-winfo.swift <owner name> [title fragment]\n       shep-winfo.swift --move <owner name> <title fragment> <x> <y>\n       shep-winfo.swift --frontmost <owner name> [title fragment]\n       shep-winfo.swift --pid <owner name> [title fragment]\n       shep-winfo.swift --bundle <owner name> [title fragment]\n       shep-winfo.swift --record <owner name> [title fragment]\n       shep-winfo.swift --verify <window id> <pid> <bundle id> <x> <y> <w> <h> <title>\n".utf8))
    exit(2)
}
let owner = args[1]
let fragment = args.count > 2 ? args[2] : ""

/// Moves the one window of `pid` whose AX title contains `fragment`. Returns false when no such window or the call failed.
func moveWindow(pid: pid_t, fragment: String, to point: CGPoint) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return false }
    for window in windows {
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        guard let name = title as? String, name.contains(fragment) else { continue }
        var p = point
        guard let axValue = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue) == .success
    }
    return false
}

/// The frontmost application and the title of its focused window, and whether they are the ones asked for.
func frontmostReport(owner: String, fragment: String) -> (ok: Bool, text: String) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))   // let a fresh process learn the current state
    guard let app = NSWorkspace.shared.frontmostApplication else { return (false, "frontmost=none focused=") }
    let name = app.localizedName ?? "?"
    var focused = ""
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
       let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() {
        let window = v as! AXUIElement
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        focused = (title as? String) ?? ""
    }
    let appMatches = name == owner || app.bundleIdentifier == owner
    let titleMatches = fragment.isEmpty || focused.contains(fragment)
    return (appMatches && titleMatches, "frontmost=\(name) focused=\(focused)")
}

/// What a match prints: the line, the pid (`--pid`) or the owner's bundle identifier (`--bundle`; exits 1 when it cannot be resolved).
func emitMatch(line: String, pid: Int) -> Never {
    if bundleMode {
        guard pid > 0, let id = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier, !id.isEmpty else { exit(1) }
        print(id)
        exit(0)
    }
    print(pidMode ? String(pid) : line)
    exit(0)
}

func windowList() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
}

/// One window of an owner that matches, from a single snapshot.
struct RecordCandidate {
    var number: Int
    var pid: Int
    var frame: CGRect
    var title: String
}

/// The one window `--record` reports, or the reason there is none. Pure over the snapshot: no second lookup, no untitled fallback.
func recordSelect(list: [[String: Any]], owner: String, fragment: String, frontPID: Int?) -> (candidate: RecordCandidate?, error: String?) {
    var matches: [RecordCandidate] = []
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String) == owner,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let number = w[kCGWindowNumber as String] as? Int,
              let pid = w[kCGWindowOwnerPID as String] as? Int,
              let dict = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict as CFDictionary), r.width > 50, r.height > 50 else { continue }
        let name = (w[kCGWindowName as String] as? String) ?? ""
        if !fragment.isEmpty && !name.contains(fragment) { continue }
        matches.append(RecordCandidate(number: number, pid: pid, frame: r, title: name))
    }
    guard let first = matches.first else { return (nil, "no on-screen window of \(owner) matches") }
    if matches.count == 1 { return (first, nil) }
    let pids = Set(matches.map { $0.pid })
    if pids.count > 1 { return (nil, "ambiguous: \(matches.count) windows of \(owner) from \(pids.count) different processes match") }
    if let front = frontPID, front == first.pid { return (first, nil) }
    return (nil, "ambiguous: \(matches.count) windows of \(owner) match and it is not the frontmost application")
}

func complainAndExit4(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("shep-winfo: " + message + "\n").utf8))
    exit(4)
}

/// A title the way `--record` prints it: on one line, ends trimmed.
func oneLineTitle(_ title: String) -> String {
    title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
}

func verifyMismatch(_ why: String) -> Never {
    FileHandle.standardError.write(Data(("shep-winfo: verify: " + why + "\n").utf8))
    exit(1)
}

if recordMode {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))   // let a fresh process learn which application is frontmost
    var frontPID: Int?
    if let front = NSWorkspace.shared.frontmostApplication { frontPID = Int(front.processIdentifier) }
    let chosen = recordSelect(list: windowList(), owner: owner, fragment: fragment, frontPID: frontPID)
    guard let c = chosen.candidate else { complainAndExit4(chosen.error ?? "no window") }
    guard let id = NSRunningApplication(processIdentifier: pid_t(c.pid))?.bundleIdentifier, !id.isEmpty,
          id.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0.value == 46 || $0.value == 45 || $0.value == 95 }) else {
        complainAndExit4("process \(c.pid) has no usable bundle identifier")
    }
    let printedTitle = oneLineTitle(c.title)
    print("\(c.number) \(c.pid) \(id) \(Int(c.frame.minX.rounded())) \(Int(c.frame.minY.rounded())) \(Int(c.frame.width.rounded())) \(Int(c.frame.height.rounded()))" + (printedTitle.isEmpty ? "" : " " + printedTitle))
    exit(0)
}

if verifyMode {
    // args[1] = window id, args[2] = pid, args[3] = bundle identifier, args[4...7] = x y w h (integer points), args[8] = title (may be empty).
    // A fresh snapshot, no matching by name.
    guard let wantedID = Int(args[1]), let wantedPID = Int(args[2]), wantedID > 0, wantedPID > 0, !args[3].isEmpty,
          let wantedX = Int(args[4]), let wantedY = Int(args[5]), let wantedW = Int(args[6]), let wantedH = Int(args[7]) else {
        verifyMismatch("the arguments are not a window record")
    }
    let wantedTitle = oneLineTitle(args[8])
    for w in windowList() where (w[kCGWindowNumber as String] as? Int) == wantedID {
        guard (w[kCGWindowOwnerPID as String] as? Int) == wantedPID else { verifyMismatch("window \(wantedID) has another owner now") }
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { verifyMismatch("window \(wantedID) is not an ordinary window now") }
        guard let running = NSRunningApplication(processIdentifier: pid_t(wantedPID)), running.bundleIdentifier == args[3] else {
            verifyMismatch("process \(wantedPID) is not \(args[3]) now")
        }
        guard let dict = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else {
            verifyMismatch("window \(wantedID) has no readable frame")
        }
        let now = (Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.width.rounded()), Int(r.height.rounded()))
        guard now.0 == wantedX, now.1 == wantedY, now.2 == wantedW, now.3 == wantedH else {
            verifyMismatch("window \(wantedID) moved or resized (\(wantedX),\(wantedY),\(wantedW),\(wantedH) -> \(now.0),\(now.1),\(now.2),\(now.3))")
        }
        let nowTitle = oneLineTitle((w[kCGWindowName as String] as? String) ?? "")
        guard nowTitle == wantedTitle else { verifyMismatch("window \(wantedID) has another title now") }
        exit(0)
    }
    verifyMismatch("window \(wantedID) is not on screen")
}

if frontMode {
    let report = frontmostReport(owner: owner, fragment: fragment)
    print(report.text)
    exit(report.ok ? 0 : 1)
}

if moveMode {
    // The AX title is readable without Screen Recording, so the owner's pid is all the window list is needed for.
    guard let pid = windowList().first(where: { ($0[kCGWindowOwnerName as String] as? String) == owner })?[kCGWindowOwnerPID as String] as? Int32,
          let x = Double(args[3]), let y = Double(args[4]),
          moveWindow(pid: pid, fragment: fragment, to: CGPoint(x: x, y: y)) else {
        FileHandle.standardError.write(Data("could not move the window (Accessibility allowed for this terminal? window titled \"\(fragment)\" open?)\n".utf8))
        exit(3)
    }
    Thread.sleep(forTimeInterval: 0.5)   // let the window server catch up; then fall through and print the new frame
}

let list = windowList()
var firstOfOwner: String?
var firstPid = 0
var untitledSeen = true
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == owner,
          (w[kCGWindowLayer as String] as? Int) == 0,
          let number = w[kCGWindowNumber as String] as? Int,
          let dict = w[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: dict as CFDictionary), r.width > 50, r.height > 50 else { continue }
    let name = (w[kCGWindowName as String] as? String) ?? ""
    let line = "\(number) \(Int(r.minX.rounded())) \(Int(r.minY.rounded())) \(Int(r.width.rounded())) \(Int(r.height.rounded()))" + (name.isEmpty ? "" : " " + name)
    let ownerPid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
    if firstOfOwner == nil { firstOfOwner = line; firstPid = ownerPid }
    if !name.isEmpty { untitledSeen = false }
    if fragment.isEmpty || name.contains(fragment) {
        emitMatch(line: line, pid: ownerPid)
    }
}
if untitledSeen, let line = firstOfOwner {
    emitMatch(line: line, pid: firstPid)
}
exit(1)
