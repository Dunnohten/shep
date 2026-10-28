import AppKit
import CoreGraphics
import ShepCore

// Written during the Meta hackathon.
// Window lookup, screencapture call and pixel size. The key lookup, the sensitive-app lists and the approval card live
// in ShepCore (ProviderFactory, ControlPolicy, ApprovalPolicy); a small Process wrapper below runs screencapture.

/// Window screenshots for "Fix this screen". Needs Screen Recording permission.
enum ScreenCapture {
    struct Shot {
        let png: Data
        let geometry: CaptureGeometry
        let windowTitle: String
        /// The window-server number of the captured window; the click guard compares against it later.
        let windowNumber: CGWindowID
    }

    enum Failure: Error, Equatable {
        case noPermission
        case noWindow
        /// The app is on a never-capture list (or its identity is unknown): nothing was captured.
        case notAllowed
        case captureFailed
    }

    /// One PNG of the app's frontmost normal window, without its shadow (`-o`), so its pixels cover exactly the window's
    /// bounds. The file lives in the temp folder for the length of the call.
    static func captureWindow(pid: pid_t, nearFrame hint: CGRect?) async -> Result<Shot, Failure> {
        // Every capture goes through the sensitive-app policy here, whoever calls (Fix this screen, the tab tint).
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        guard ControlPolicy.mayCapture(bundleID: bundleID) else { return .failure(.notAllowed) }
        guard CGPreflightScreenCaptureAccess() else { return .failure(.noPermission) }
        guard let (id, bounds, title) = window(pid: pid, nearFrame: hint) else { return .failure(.noWindow) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shep-fix-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let status = await run("/usr/sbin/screencapture", ["-x", "-o", "-t", "png", "-l", String(id), file.path], timeout: 15)
        guard status == 0, let png = try? Data(contentsOf: file), let size = ImageIOPreparer.pixelSize(of: png) else { return .failure(.captureFailed) }
        let scale = 2.0   // only a fallback: CaptureGeometry measures the real scale from the image
        return .success(Shot(png: png, geometry: CaptureGeometry(windowFrame: bounds, imageSize: size, scale: scale), windowTitle: title, windowNumber: id))
    }

    /// The app's frontmost layer-0 window (CGWindowList is front to back): id, bounds in global points (top-left origin), title.
    /// With a hint (the AX window frame) the first window whose bounds match it wins; with none that matches there is no
    /// answer (never a different window of the same app, whose pixels would not belong to the hinted window's controls).
    static func window(pid: pid_t, nearFrame hint: CGRect?) -> (CGWindowID, CGRect, String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int, pid_t(owner) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            let found = (CGWindowID(number), rect, (w[kCGWindowName as String] as? String) ?? "")
            guard let hint else { return found }
            if ActionPerformer.sameFrame(rect, hint, tolerance: 3) { return found }
        }
        return nil
    }

    /// Runs a command with a timeout; returns the exit status, or -1 when it could not start.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { cont.resume(returning: -1); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }
}
