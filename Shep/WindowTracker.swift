import AppKit
import ApplicationServices
import ShepCore

/// AXObserver callback: a C function pointer, so no captures. The tracker travels through `refcon` (Unmanaged).
/// The observer's run-loop source is on the main run loop, so this always runs on the main thread.
private func shepAXCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                            _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { tracker.axEvent(notification as String) }
}

/// Follows the focused window of the frontmost app. Event-driven (AXObserver + NSWorkspace activation)
/// with a 0.25 s polling fallback, because apps deliver AX notifications unreliably.
@MainActor
final class WindowTracker {
    /// Called whenever what the tracker sees changes (nil: no frontmost app).
    var onUpdate: ((WindowObservation?) -> Void)?
    /// Demo mode: when Accessibility is not granted yet, fall back to CGWindowList bounds so the dog can still be shown.
    var demo = false
    /// A live run bound to an app (`--live-target`): the bundle id of that app, nil when nothing is bound. While set, the window of
    /// any other app (Shep itself excepted) is not read: no Accessibility attach, no frame, title or title-bar items, no observers.
    /// What is published for it is only its pid and bundle id (`axFrame` nil), so the dock planner hides the dock.
    var boundBundleID: String? {
        didSet {
            guard boundBundleID != oldValue, timer != nil else { return }
            refresh()
        }
    }

    private var timer: Timer?
    private var activationToken: NSObjectProtocol?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var appElement: AXUIElement?
    private var observedWindow: AXUIElement?
    private var lastObservation: WindowObservation?
    private var hasPublished = false
    private var targetLog = FocusTargetLogState()
    /// The VoiceOver flag and the focused-element reasons of the last sample, for the target line.
    private var sampledVoiceOver = false
    private var voiceOverFailures: [FocusAttemptFailure] = []
    private var voiceOverObservation: NSKeyValueObservation?
    /// How the last sample chose its window, for the debug dump (`LiveDebug.traceText`).
    private(set) var focusSample = FocusTargetSample(source: nil, voiceOverRunning: false, voiceOverFailures: [])
    private var titleBarCache: (key: String, time: Date, frames: [CGRect], measured: Bool)?

    func start() {
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // VoiceOver turned on or off: look again now, so the source (and the flag in its log line) follows at once.
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let token = activationToken { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        activationToken = nil
        voiceOverObservation?.invalidate()
        voiceOverObservation = nil
        detach()
        // A later start() must publish again even if the window is unchanged: the owner has dropped what it knew.
        hasPublished = false
        targetLog.reset()
        lastObservation = nil
    }

    fileprivate func axEvent(_ name: String) { refresh() }

    // MARK: sampling

    func refresh() {
        sampledVoiceOver = NSWorkspace.shared.isVoiceOverEnabled
        voiceOverFailures = []
        guard let app = NSWorkspace.shared.frontmostApplication else { publish(nil); return }
        let pid = app.processIdentifier
        var obs = WindowObservation(pid: pid, bundleID: app.bundleIdentifier, axFrame: nil)
        if let bound = boundBundleID, pid != ProcessInfo.processInfo.processIdentifier,
           !LiveBinding.mayRead(bundleID: app.bundleIdentifier, target: bound, ownBundleID: Bundle.main.bundleIdentifier) {
            // Bound to another app: look at nothing of this one. Its AX observers (if we held any) go too.
            detach()
            publish(obs)
            return
        }

        if AXIsProcessTrusted() {
            attach(to: pid)
            if let appEl = appElement { read(appElement: appEl, into: &obs) }
        } else {
            detach()
            if demo, let cg = Self.cgFallbackWindow(excludingPID: ProcessInfo.processInfo.processIdentifier) {
                obs = WindowObservation(pid: cg.pid, bundleID: NSRunningApplication(processIdentifier: cg.pid)?.bundleIdentifier,
                                        axFrame: cg.frame)
            }
        }
        publish(obs)
    }

    private func publish(_ obs: WindowObservation?) {
        focusSample = FocusTargetSample(source: obs?.source, voiceOverRunning: sampledVoiceOver, voiceOverFailures: voiceOverFailures)
        // Logged before the equality check: a VoiceOver toggle or a new reason changes the line, not the observation.
        if let line = targetLog.record(source: obs?.source, voiceOverRunning: sampledVoiceOver, voiceOverFailures: voiceOverFailures) {
            print(line)
        }
        if hasPublished, obs == lastObservation { return }
        hasPublished = true
        lastObservation = obs
        onUpdate?(obs)
    }

    private func read(appElement appEl: AXUIElement, into obs: inout WindowObservation) {
        // The window comes from the first focus that gives one: the focused element (while VoiceOver runs), the keyboard, the mouse.
        var found: AXUIElement?
        let source = FocusTargetPolicy.choose(voiceOverRunning: sampledVoiceOver) { s in
            found = self.window(from: s, appElement: appEl, pid: obs.pid)
            return found != nil
        }
        guard let source, let win = found else {
            watchWindow(nil)
            return
        }
        obs.source = source
        watchWindow(win)
        obs.axFrame = Self.frame(of: win)
        obs.subrole = Self.copy(win, kAXSubroleAttribute) as? String
        obs.title = Self.copy(win, kAXTitleAttribute) as? String
        if let fs = Self.copy(win, "AXFullScreen"), CFGetTypeID(fs) == CFBooleanGetTypeID() {
            obs.isFullScreen = CFBooleanGetValue((fs as! CFBoolean))
        }
        if !obs.isFullScreen, let f = obs.axFrame {
            let info = titleBar(of: win, frame: f, title: obs.title ?? "")
            obs.titleBarFrames = info.frames
            obs.titleMeasured = info.measured
        }
    }

    // MARK: focus sources

    private func window(from source: FocusSource, appElement appEl: AXUIElement, pid: pid_t) -> AXUIElement? {
        switch source {
        case .voiceover:
            let resolution = FocusedWindowResolver.resolve(frontPID: pid, reader: FocusReader(appElement: appEl))
            voiceOverFailures = resolution.failures
            return resolution.window
        case .keyboard: return Self.element(Self.copy(appEl, kAXFocusedWindowAttribute))
        case .mouse: return Self.windowUnderPointer(appElement: appEl)
        }
    }

    nonisolated private static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// The AX side of `FocusedWindowResolver`: the window of the ordinary focused element (not the VoiceOver cursor, which has no
    /// public API; see `FocusTargetPolicy`), only when that element and its window belong to the front app: Shep docks on the
    /// front app, the app the fix pipeline reads.
    private struct FocusReader: FocusedElementReading {
        let appElement: AXUIElement

        func focusedElement(from candidate: FocusCandidate) -> AXUIElement? {
            switch candidate {
            case .system:
                let system = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(system, 0.25)
                return WindowTracker.element(WindowTracker.copy(system, kAXFocusedUIElementAttribute))
            case .app:
                return WindowTracker.element(WindowTracker.copy(appElement, kAXFocusedUIElementAttribute))
            }
        }

        func ownerPID(of element: AXUIElement) -> Int32? {
            var owner: pid_t = 0
            return AXUIElementGetPid(element, &owner) == .success ? owner : nil
        }

        func isWindow(_ element: AXUIElement) -> Bool {
            (WindowTracker.copy(element, kAXRoleAttribute) as? String) == (kAXWindowRole as String)
        }

        func window(of element: AXUIElement) -> AXUIElement? {
            WindowTracker.element(WindowTracker.copy(element, kAXWindowAttribute))
        }
    }

    /// The last fallback: the front app's frontmost window under the mouse pointer.
    private static func windowUnderPointer(appElement appEl: AXUIElement) -> AXUIElement? {
        guard let list = copy(appEl, kAXWindowsAttribute) as? [AXUIElement], !list.isEmpty else { return nil }
        let p = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: p.x, y: height - p.y)
        guard let i = FocusTargetPolicy.windowIndex(containing: axPoint, frames: list.map { frame(of: $0) }) else { return nil }
        return list[i]
    }

    // MARK: title-bar contents

    /// Tree walk limits: the title bar is shallow, and this runs on the main thread.
    private static let barMaxDepth = 3
    private static let barMaxNodes = 60
    private static let barRecheck: TimeInterval = 2
    /// Containers worth looking into; anything else that overlaps the bar is an obstacle itself.
    private static let barContainers: Set<String> = ["AXToolbar", "AXGroup", "AXSplitGroup", "AXTabGroup", "AXScrollArea", "AXLayoutArea"]
    private static let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// Frames (AX coordinates) of the window's title text, toolbar buttons and fields inside the top title-bar band, so the
    /// dog can sit clear of them. Cached for two seconds per window frame and title: the walk costs several AX calls.
    private func titleBar(of win: AXUIElement, frame: CGRect, title: String) -> (frames: [CGRect], measured: Bool) {
        let key = "\(observedPID)|\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)|\(title)"
        if let c = titleBarCache, c.key == key, Date().timeIntervalSince(c.time) < Self.barRecheck { return (c.frames, c.measured) }
        let band = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: DockGeometry.titleBarHeight)
        var frames: [CGRect] = []
        var measured = false
        var queue: [(el: AXUIElement, depth: Int)] = [(win, 0)]
        var head = 0
        while head < queue.count, head < Self.barMaxNodes {
            let item = queue[head]
            head += 1
            guard let kids = Self.copy(item.el, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for kid in kids.prefix(40) {
                guard let f = Self.frame(of: kid), f.width > 0, f.height > 0, f.intersects(band) else { continue }
                let role = (Self.copy(kid, kAXRoleAttribute) as? String) ?? ""
                let subrole = (Self.copy(kid, kAXSubroleAttribute) as? String) ?? ""
                if Self.windowButtons.contains(subrole) { continue }
                if Self.barContainers.contains(role), item.depth + 1 < Self.barMaxDepth {
                    queue.append((kid, item.depth + 1))
                    continue
                }
                if f.width > frame.width * 0.7 { continue }   // a background or container, not a control
                frames.append(f)
                if role == "AXStaticText", !title.isEmpty {
                    let text = (Self.copy(kid, kAXValueAttribute) as? String) ?? (Self.copy(kid, kAXTitleAttribute) as? String) ?? ""
                    if text == title { measured = true }
                }
            }
        }
        titleBarCache = (key, Date(), frames, measured)
        return (frames, measured)
    }

    // MARK: AX plumbing

    nonisolated private static func copy(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let p = copy(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = copy(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func attach(to pid: pid_t) {
        if pid == observedPID, observer != nil { return }
        detach()
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        appElement = appEl
        observedPID = pid

        var created: AXObserver?
        guard AXObserverCreate(pid, shepAXCallback, &created) == .success, let obs = created else { return }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification, kAXApplicationActivatedNotification] {
            _ = AXObserverAddNotification(obs, appEl, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    private func detach() {
        watchWindow(nil)
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        appElement = nil
        observedPID = 0
        titleBarCache = nil
    }

    /// Moved/resized/destroyed are delivered by the window element, so re-register when the focused window changes.
    private func watchWindow(_ win: AXUIElement?) {
        if let new = win, let old = observedWindow, CFEqual(new, old) { return }
        let names = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification]
        if let obs = observer, let old = observedWindow {
            for n in names { _ = AXObserverRemoveNotification(obs, old, n as CFString) }
        }
        observedWindow = nil
        guard let obs = observer, let new = win else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in names { _ = AXObserverAddNotification(obs, new, n as CFString, refcon) }
        observedWindow = new
    }

    // MARK: demo fallback (no Accessibility yet)

    /// Frontmost ordinary on-screen window of another process, bounds in the same top-left space as AX.
    private static func cgFallbackWindow(excludingPID own: pid_t) -> (pid: pid_t, frame: CGRect)? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pidNum = w[kCGWindowOwnerPID as String] as? Int, pid_t(pidNum) != own,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 200, rect.height >= 100 else { continue }
            return (pid_t(pidNum), rect)
        }
        return nil
    }
}
