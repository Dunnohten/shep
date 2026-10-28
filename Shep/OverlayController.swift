import AppKit
import ShepCore

/// Owns the tab overlay (the tab on the window's title bar, with the dog in it) and the window tracker; turns
/// observations into a placement and moves the panel.
/// Also owns the card (say / ask / ask field), click-through, and re-docking on screen or Space changes.
@MainActor
final class OverlayController {
    private let overlay = DockOverlay()
    private let tracker = WindowTracker()
    private let demo: Bool
    /// Log tracker, activity and travel lines to stdout (the demo flags, and the cycle script).
    private let verbose: Bool
    /// False while Shep is not on a window (asleep, waking, travelling, returning): the tracker may still be placing the
    /// tab, but nothing is shown until the coordinator lets the dock appear.
    private(set) var presentationAllowed = true
    private var trackingActive = false
    private var userHidden = false
    private var hiddenForClick = false
    private var lastPlacement: TabPlacement = .hidden
    private var lastObservation: WindowObservation?
    private var currentLayout: PanelLayout?
    private var sampledFill: String?
    private var tintKey = ""
    private var tintTask: Task<Void, Never>?
    /// The last `[shep] tint:` line printed for a window that is not docked to (so a hidden dock does not repeat it every poll).
    private var lastNotDockedTintLine = ""
    private var appliedFill = ""
    private var cardVisible = false
    private var pillOpen = false
    /// What push-to-talk has heard so far; shown in the pill as soon as the dock is up.
    private var transcript = ""
    private var pendingChoice: CheckedContinuation<String?, Never>?
    /// The app that was in front when an approval card took key status; it gets focus back when the card closes.
    private var previousFront: NSRunningApplication?
    private var approvalKeyed = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var mouseMonitors: [Any] = []

    // Motion: a mirror of the page's state machine (events go to both), the activity rule that pauses the page's loop,
    // the last tab shown (to choose between a slide and a rise), and the optional timed demo.
    private var motion: DogMotionMachine
    private var activity = DogActivity()
    private var sentActive: Bool?
    private var shownTab: CGRect?
    private var shownPID: pid_t?
    private var currentPID: pid_t?
    private var everDocked = false
    private var lastPointerSent = Date.distantPast
    private var lastGaze = (x: 9.0, y: 9.0)
    private var demoScriptArmed: Bool
    private var demoSignal: DispatchSourceSignal?

    /// Text typed into the ask field.
    var onSubmit: ((String) -> Void)?
    /// The ask field opened (true) or closed (false): a request is being made, so Shep must not time out meanwhile.
    var onPillChanged: ((Bool) -> Void)?
    /// The user touched the dog or its card.
    var onActivity: (() -> Void)?
    /// Reduce Motion was switched in System Settings.
    var onReduceMotionChanged: ((Bool) -> Void)?
    /// Everything Shep says on its card (replies are spoken from this; see VoiceController).
    var onReply: ((String) -> Void)?
    /// While the dock may be shown: true when the tracker has no window to put the tab on, false when it has one again.
    var onWindowLost: ((Bool) -> Void)?

    init(demo: Bool, verbose: Bool? = nil, theme: ShepTheme, state: ShepDogState, demoScript: Bool = false) {
        self.demo = demo
        self.verbose = verbose ?? demo
        self.demoScriptArmed = demoScript
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.motion = DogMotionMachine(reduceMotion: reduce)
        overlay.dogView.setReduceMotion(reduce)
        overlay.dogView.onDrag = { [weak self] began in self?.motionSend(began ? .dragBegan : .dragEnded, toPage: false) }
        overlay.dogView.setTheme(theme.name)
        overlay.dogView.setState(state)
        overlay.dogView.onClick = { [weak self] in self?.dogClicked() }
        overlay.dogView.onMessage = { [weak self] message in self?.handle(message) }
        overlay.container.onPress = { [weak self] in self?.dogClicked() }
        tracker.demo = demo
        tracker.onUpdate = { [weak self] obs in self?.handle(obs) }
    }

    /// A live run bound to an app (`--live-target`), from `target-ok` until `live: finished`: the app's bundle id, nil when none.
    /// While set, the tracker reads no other app's window, the planner hides the dock for any other app (the panel is not shown
    /// over it) and the tab tint captures nothing of it. Setting or clearing it makes the tracker look again at once.
    var boundTarget: String? {
        didSet {
            guard boundTarget != oldValue else { return }
            tracker.boundBundleID = boundTarget
            tintKey = ""
        }
    }

    var isVisible: Bool { !userHidden }
    var isPillOpen: Bool { pillOpen }

    /// `tracking: false` starts asleep: no window tracking and no mouse monitor until `beginTracking()`.
    func start(tracking: Bool = true) {
        observeScreens()
        observeActivity()
        if tracking { beginTracking() }
    }

    /// Starts following the front window (AX observers, polling) and the mouse-moved monitors for click-through.
    func beginTracking() {
        guard !trackingActive else { return }
        trackingActive = true
        tracker.start()
        startMouseTracking()
    }

    /// Stops all of it: no AX observers, no polling, no mouse monitors. The next `beginTracking()` publishes afresh.
    func endTracking() {
        guard trackingActive else { return }
        trackingActive = false
        tracker.stop()
        stopMouseTracking()
        lastObservation = nil
        lastPlacement = .hidden
    }

    /// The dock appears (the head rises out of the tab) at the placement the tracker last found.
    func allowPresentation() {
        presentationAllowed = true
        apply(lastPlacement)
        if !transcript.isEmpty { showTranscript(transcript) }
    }

    /// Push-to-talk's partial text, read-only in the pill. Kept while the dock is not up and shown when it arrives.
    func showTranscript(_ text: String) {
        transcript = text
        guard presentationAllowed, overlay.isVisible, !pillOpen, pendingChoice == nil else { return }
        cardVisible = true
        overlay.dogView.showTranscript(text)
        updateClickThrough()
    }

    func clearTranscript() {
        guard !transcript.isEmpty else { return }
        transcript = ""
        guard !pillOpen, pendingChoice == nil else { return }
        overlay.dogView.closeCard()
        cardVisible = false
    }

    /// The dock goes away: cards closed, the head sinks into the tab, the panel leaves the screen. With `fade` (Reduce Motion)
    /// the panel fades out instead.
    func disallowPresentation(fade: Bool = false) {
        prepareToLeave()
        presentationAllowed = false
        if fade, overlay.isVisible {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                overlay.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.presentationAllowed { self.apply(self.lastPlacement) }
                    self.overlay.alphaValue = 1
                }
            })
        } else {
            apply(lastPlacement)
        }
    }

    /// Closes the ask field, any card and a waiting choice (the panel itself is left for the caller to hide).
    func prepareToLeave() {
        resolveChoice(nil, restoreKey: false)
        if pillOpen {
            pillOpen = false
            onPillChanged?(false)
            overlay.acceptsTextInput = false
            overlay.container.pageControlsExposed = false
        }
        overlay.dogView.closeCard()
        cardVisible = false
    }

    /// Where the dog's head is now (Cocoa), docked or about to be; nil when there is no tab.
    var dogCenter: CGPoint? {
        guard let tab = lastPlacement.layout else { return nil }
        return CGPoint(x: tab.dogFrame.midX, y: tab.dogFrame.midY)
    }

    /// The front window the tracker last saw: its process and its frame in global top-left points (the Accessibility space).
    var observedWindow: (pid: pid_t, frame: CGRect)? {
        guard let o = lastObservation, let f = o.axFrame else { return nil }
        return (o.pid, f)
    }

    /// How the tracker's last sample chose the target window (source, sampled VoiceOver flag, fall-through reasons).
    var focusSample: FocusTargetSample { tracker.focusSample }

    /// The overlay panel as last laid out (Cocoa coordinates): the tab, and the card and speech bubble below or above it.
    var panelFrame: CGRect? { currentLayout?.panelFrame }

    /// The tab the tracker last placed (Cocoa coordinates), whether or not it is shown.
    var tabRect: CGRect? { lastPlacement.layout?.rect }

    /// What the dog should travel to: the tab on the front window, as the tracker last placed it.
    func travelTarget() -> TravelTarget? {
        guard let tab = lastPlacement.layout, let ax = lastObservation?.axFrame else { return nil }
        let height = NSScreen.screens.first?.frame.height ?? 0
        return .tab(windowFrame: AXCoordinates.cocoaRect(fromAX: ax, primaryScreenHeight: height), placed: tab)
    }

    func setTheme(_ theme: ShepTheme) { overlay.dogView.setTheme(theme.name) }
    func setState(_ state: ShepDogState) {
        overlay.dogView.setState(state)   // the page maps the name to its machine; the mirror gets the same event
        overlay.dogView.setPose(DogPose.name(for: state), reduceMotion: motion.reduceMotion)
        motion.send(state.motionEvent, at: Self.now)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// "Done." for VoiceOver (the finish beat's announcement).
    func announceDone() { announce(FinishBeat.announcement) }

    func hop() { overlay.dogView.hop(points: FinishBeat.hopHeight, seconds: FinishBeat.hopSeconds) }

    /// A named pose (ears, eyes, tilt) on the docked dog, e.g. the finish pose.
    func setPose(_ name: PoseName) { overlay.dogView.setPose(name, reduceMotion: motion.reduceMotion) }

    /// The Reduce Motion setting, as the page sees it.
    var reduceMotion: Bool { motion.reduceMotion }

    func setUserHidden(_ hidden: Bool) {
        userHidden = hidden
        apply(lastPlacement)
    }

    // MARK: motion

    /// Sends a machine event to the mirror and (unless the page produced it) to the page, and ticks the mirror when a timed state ends.
    private func motionSend(_ event: DogMotionEvent, toPage: Bool = true) {
        motion.send(event, at: Self.now)
        if toPage { overlay.dogView.sendMotion(event) }
        if let end = motion.endsAt {
            let wait = max(0, end - Self.now) + 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.motion.tick(at: Self.now) }
        }
    }

    /// The page animates only while the panel is on screen, not covered, and the display is awake.
    private func observeActivity() {
        let center = NotificationCenter.default
        let t1 = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: overlay, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateActivity() }
        }
        observers.append((center, t1))
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            let t = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.activity.screenAsleep = true; self?.updateActivity() }
            }
            observers.append((ws, t))
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            let t = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.activity.screenAsleep = false; self?.updateActivity() }
            }
            observers.append((ws, t))
        }
        let t3 = ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reduceMotionChanged() }
        }
        observers.append((ws, t3))
        updateActivity()
    }

    private func reduceMotionChanged() {
        let on = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        motion.setReduceMotion(on)
        overlay.dogView.setReduceMotion(on)
        onReduceMotionChanged?(on)
    }

    /// Tells the page to pause or resume (only when the answer changed).
    private func updateActivity() {
        activity.panelVisible = overlay.isVisible
        activity.occluded = !overlay.occlusionState.contains(.visible)
        let on = activity.isActive
        if sentActive != on {
            sentActive = on
            if verbose { print("[shep] motion \(on ? "active" : "paused") (visible=\(activity.panelVisible) occluded=\(activity.occluded) asleep=\(activity.screenAsleep))") }
            overlay.dogView.setActive(on)
        }
    }

    /// Eye tracking: the page is told where the pointer is, relative to the dog, at most about 15 times a second, and only
    /// while the dog is idle or listening and the pointer moved enough to matter.
    private func feedPointer() {
        guard activity.isActive, let layout = currentLayout, !motion.reduceMotion else { return }
        guard motion.state == .idle || motion.state == .listening || motion.state == .speaking else { return }
        let nowDate = Date()
        guard nowDate.timeIntervalSince(lastPointerSent) >= 0.066 else { return }
        let d = PanelGeometry.dogScreenRect(layout)
        let g = DogGaze.normalised(pointer: NSEvent.mouseLocation, dogCenter: CGPoint(x: d.midX, y: d.midY))
        guard abs(g.x - lastGaze.x) > 0.03 || abs(g.y - lastGaze.y) > 0.03 else { return }
        lastPointerSent = nowDate
        lastGaze = g
        overlay.dogView.setPointer(x: g.x, y: g.y)
    }

    // MARK: re-docking

    /// Monitors plugged in or removed, resolution changes, and Space switches all move where the dog belongs.
    private func observeScreens() {
        let center = NotificationCenter.default
        let t1 = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.redock() }
        }
        observers.append((center, t1))
        let ws = NSWorkspace.shared.notificationCenter
        let t2 = ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.redock() }
        }
        observers.append((ws, t2))
    }

    /// Looks at the front window now (while tracking), instead of at the next poll.
    func refreshTracking() {
        guard trackingActive else { return }
        tracker.refresh()
    }

    /// Recompute the placement from the last observation against the current screens. Spaces animate, so look again shortly after.
    func redock() {
        guard trackingActive else { return }
        tracker.refresh()
        handle(lastObservation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.trackingActive else { return }
            self.tracker.refresh()
            self.handle(self.lastObservation)
        }
    }

    // MARK: click-through

    /// The panel is mostly transparent and sits over other apps' content, so it ignores the mouse except over the tab
    /// (and over the card while one is showing). A mouse-moved monitor flips `ignoresMouseEvents` as the pointer moves.
    private func startMouseTracking() {
        guard mouseMonitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            Task { @MainActor in self?.updateClickThrough(); self?.feedPointer() }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.updateClickThrough()
            self?.feedPointer()
            return event
        }) { mouseMonitors.append(l) }
    }

    private func stopMouseTracking() {
        for m in mouseMonitors { NSEvent.removeMonitor(m) }
        mouseMonitors.removeAll()
    }

    private func updateClickThrough() {
        guard let layout = currentLayout, overlay.isVisible else { return }
        let rects = PanelGeometry.interactiveRects(layout, bubbleVisible: cardVisible || pillOpen)
        let capture = PanelGeometry.shouldCapture(point: NSEvent.mouseLocation, rects: rects)
        if overlay.ignoresMouseEvents == capture { overlay.ignoresMouseEvents = !capture }
    }

    // MARK: card, pill, choices

    private func dogClicked() {
        onActivity?()
        overlay.dogView.pulse()
        if pendingChoice != nil { return }   // an Approve / Cancel card is waiting: answer that first
        if pillOpen { closePill() } else { openPill() }
    }

    /// The run behind a waiting approval card ended (the target left the front): the card closes, the waiting `ask` resumes with nil
    /// exactly once (so nothing is approved), and the app that was in front is NOT activated again (the person went elsewhere on
    /// purpose). Nothing happens when no card is waiting.
    func cancelPendingCard() {
        resolveChoice(nil, restoreKey: false)
    }

    func openPill() {
        resolveChoice(nil)
        transcript = ""
        pillOpen = true
        cardVisible = true
        onPillChanged?(true)
        overlay.acceptsTextInput = true
        overlay.container.pageControlsExposed = true
        overlay.ignoresMouseEvents = false
        overlay.makeKey()
        overlay.dogView.openPill()
        overlay.makeFirstResponder(overlay.dogView)
    }

    private func closePill() {
        guard pillOpen else { return }
        pillOpen = false
        onPillChanged?(false)
        overlay.acceptsTextInput = false
        overlay.container.pageControlsExposed = false
        overlay.dogView.closeCard()
        // Hand key status back: re-ordering a non-activating panel drops it without activating Shep.
        overlay.orderOut(nil)
        if presentationAllowed, !userHidden, lastPlacement.layout != nil { overlay.orderFrontRegardless() }
        updateActivity()
    }

    func say(_ text: String, milliseconds: Int = 4000) {
        resolveChoice(nil)
        transcript = ""
        onReply?(text)
        cardVisible = true
        overlay.dogView.say(text, milliseconds: milliseconds)
        announce(text)
    }

    /// Shows `text` with buttons and waits. Returns the chosen id, or nil if the card was dismissed (Escape) or replaced.
    /// While the card shows the panel is the key window (and only then), the page focuses Approve, the card is a dialog named
    /// `title` ("Shep wants to press Save in TextEdit"), and Escape cancels. When it closes, the app that was in front gets focus back.
    func ask(_ text: String, choices: [(id: String, label: String)], title: String) async -> String? {
        resolveChoice(nil, restoreKey: false)
        transcript = ""
        onReply?(text)
        // The one announcement for this card (the page has no live region): the dialog's name and the way out.
        announce(title + ". " + choices.map(\.label).joined(separator: " or ") + "?")
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            pendingChoice = cont
            cardVisible = true
            if !approvalKeyed {
                let front = NSWorkspace.shared.frontmostApplication
                previousFront = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? nil : front
            }
            approvalKeyed = true
            overlay.acceptsTextInput = true
            overlay.onEscape = { [weak self] in self?.resolveChoice(nil) }   // fallback when the page does not get the key
            overlay.container.pageControlsExposed = true
            overlay.ignoresMouseEvents = false
            overlay.makeKey()
            overlay.makeFirstResponder(overlay.dogView)
            overlay.dogView.ask(text, choices: choices, title: title)
        }
    }

    private func resolveChoice(_ id: String?, restoreKey: Bool = true) {
        guard let c = pendingChoice else { return }
        pendingChoice = nil
        c.resume(returning: id)
        endApproval(restoreKey: restoreKey)
    }

    /// The card is gone: stop being the key window, close the card in the page, give the previous app its focus back.
    private func endApproval(restoreKey: Bool) {
        overlay.onEscape = nil
        if !pillOpen { overlay.container.pageControlsExposed = false }
        guard approvalKeyed else { return }
        approvalKeyed = false
        if !pillOpen { overlay.acceptsTextInput = false }
        overlay.dogView.closeCard()
        cardVisible = pillOpen
        guard restoreKey, !pillOpen else { previousFront = nil; return }
        // Re-ordering a non-activating panel drops its key status without activating Shep.
        if overlay.isVisible && !hiddenForClick {
            overlay.orderOut(nil)
            if presentationAllowed, !userHidden, lastPlacement.layout != nil { overlay.orderFrontRegardless() }
        }
        if let app = previousFront, !app.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate(options: [])
        }
        previousFront = nil
        updateActivity()
    }

    private func handle(_ message: DogMessage) {
        switch message {
        case .submit(let text):
            closePill()
            onSubmit?(text)
        case .cancel:
            if pendingChoice != nil { resolveChoice(nil) } else { closePill() }   // Escape on an approval card, or on the ask field
        case .activate:
            dogClicked()
        case .choice(let id):
            resolveChoice(id)
        case .cardShown:
            cardVisible = true
        case .cardHidden:
            cardVisible = pillOpen
            resolveChoice(nil)
        case .ready:
            break   // DogWebView answers it itself: it sends the newest layout
        case .pageError(let text):
            print("[shep] dog page error: \(text)")
        case .said:
            break
        }
        updateClickThrough()
    }

    /// VoiceOver speaks this; with it off nothing happens (the card is on screen anyway).
    /// This is the only announcement mechanism for replies and approval cards: the dog page has no aria-live region.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: clicking on the user's behalf

    /// The panel would sit over the target (and answer the hit test), so it steps aside for the click.
    func hideForClick() async {
        hiddenForClick = true
        resolveChoice(nil, restoreKey: false)
        overlay.dogView.closeCard()
        cardVisible = false
        let number = overlay.windowNumber
        overlay.orderOut(nil)
        updateActivity()
        // Wait until the window server no longer lists the panel (at most 0.6 s), then a short settle: the caller validates
        // the target right after this returns and clicks immediately, so nothing may sleep after that.
        for _ in 0..<20 {
            if !Self.windowIsOnScreen(number) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private static func windowIsOnScreen(_ number: Int) -> Bool {
        guard number > 0, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { entry in (entry[kCGWindowNumber as String] as? Int) == number }
    }

    func showAfterClick() {
        hiddenForClick = false
        apply(lastPlacement)
    }

    // MARK: placement

    private func handle(_ obs: WindowObservation?) {
        lastObservation = obs
        currentPID = obs?.pid
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let usable = NSScreen.screens.map(\.visibleFrame)
        var plan = DockPlanner.plan(obs, ownPID: ProcessInfo.processInfo.processIdentifier,
                                    screens: screens, usable: usable, primaryScreenHeight: primaryHeight, liveTarget: boundTarget)
        if demo, plan.placement == .hidden, let first = screens.first {
            // Demo must show the dog even with nothing to dock to: sit on an imaginary window in the middle of the main screen.
            let fake = CGRect(x: first.midX - 400, y: first.midY - 250, width: 800, height: 500)
            plan = DockPlan(placement: TabGeometry.place(window: fake, isFullScreen: false, screens: screens, usable: usable),
                            note: "demo fallback (\(plan.note))")
        }
        if verbose { log(obs, plan) }
        refreshTint(obs, docked: plan.placement != .hidden)
        apply(plan.placement)
    }

    private func apply(_ placement: TabPlacement) {
        lastPlacement = placement
        if presentationAllowed && !hiddenForClick { onWindowLost?(placement.layout == nil) }
        guard presentationAllowed, !userHidden, !hiddenForClick, let tab = placement.layout else {
            if overlay.isVisible { overlay.orderOut(nil) }
            if shownTab != nil { motionSend(.hide) }   // the head goes back into the tab; it rises again when the tab returns
            shownTab = nil
            shownPID = nil
            updateActivity()
            return
        }
        let screens = NSScreen.screens.map(\.frame)
        let layout = PanelGeometry.layout(tab: tab, screens: screens)
        let changed = layout != currentLayout
        let move = DockMotionPlanner.plan(from: shownTab, to: tab.rect, sameWindow: currentPID == shownPID, reduceMotion: motion.reduceMotion)
        let wasShown = shownTab != nil
        shownTab = tab.rect
        shownPID = currentPID
        let old = currentLayout
        currentLayout = layout
        if changed || overlay.frame != layout.panelFrame {
            // A small move of the same window slides (the panel's size and the tab's place in it unchanged); anything else jumps.
            var slide: TimeInterval?
            if case .slide(let d) = move, let o = old, o.panelFrame.size == layout.panelFrame.size,
               o.tabInPanel == layout.tabInPanel, o.bubbleBelow == layout.bubbleBelow, overlay.isVisible {
                slide = d
            }
            if let d = slide {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = d
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    overlay.animator().setFrame(layout.panelFrame, display: true)
                }
            } else {
                overlay.setFrame(layout.panelFrame, display: true)
            }
            overlay.dogView.frame = overlay.container.bounds   // the web view is exactly the panel; the page positions the dog in it
            overlay.dogView.setLayout(layout)
            logDock(layout)
            overlay.container.dogScreenFrame = tab.dogFrame
            drawTab(layout)
        }
        let wasVisible = overlay.isVisible
        if !wasVisible { overlay.orderFrontRegardless() }
        updateClickThrough()
        updateActivity()
        // The head rises out of the tab when it appears or jumps; the very first time the page does that itself on placement.
        if everDocked && (move == .rise || !wasVisible || !wasShown) && motion.state != .dragging {
            motionSend(motion.state == .hidden ? .show : .dock)
        }
        if !everDocked { motionSend(.dock, toPage: false) }   // the page started its own first rise when it placed the dog
        everDocked = true
        if demoScriptArmed { armDemoScript() }
    }

    // MARK: demo script

    /// `--demo-script`: once the tab is up the dog goes back into it and waits for SIGUSR1 (scripts/record-demo.sh sends it
    /// once the recorder runs; SHEP_DEMO_AUTOSTART=1 starts after 3 s instead). Then the timed sequence plays once.
    private func armDemoScript() {
        demoScriptArmed = false
        motionSend(.hide)
        print("[shep] demo-script armed")
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.runDemoScript() }
        source.resume()
        demoSignal = source
        if ProcessInfo.processInfo.environment["SHEP_DEMO_AUTOSTART"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.runDemoScript() }
        }
    }

    private var demoRunning = false

    private func runDemoScript() {
        guard !demoRunning else { return }
        demoRunning = true
        print("[shep] demo-script start")
        var dragging = false
        for step in DemoScript.steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.at) { [weak self] in
                guard let self else { return }
                switch step.action {
                case .dock: self.motionSend(self.motion.state == .hidden ? .show : .dock)
                case .rest: self.motionSend(.rest)
                case .listen: self.motionSend(.listen)
                case .think: self.motionSend(.think)
                case .blink: self.overlay.dogView.blink()
                case .dragTo(let dx, let dy):
                    if !dragging { dragging = true; self.motionSend(.dragBegan, toPage: false) }
                    self.overlay.dogView.drag(dx: dx, dy: dy)
                case .dragEnd:
                    dragging = false
                    self.overlay.dogView.dragEnd()
                    self.motionSend(.dragEnded, toPage: false)
                }
                print("[shep] demo-script \(step.action)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + DemoScript.duration) {
            print("[shep] demo-script done")
        }
    }

    // MARK: tab colours

    private var fillHex: String {
        sampledFill ?? TabTint.fallbackHex(dark: TabTint.isDark)
    }

    /// Paints the native tab (fill, hairline, no base segment) behind the dog and tells the dog what it sits on.
    private func drawTab(_ layout: PanelLayout) {
        let frame = layout.tab.rect.offsetBy(dx: -layout.panelFrame.minX, dy: -layout.panelFrame.minY)
        let fill = fillHex
        overlay.tabView.update(frame: frame, style: layout.tab.style, path: layout.tab.path, fillHex: fill,
                               outline: TabAppearance.outlineRGBA(dark: TabTint.isDark))
        if fill != appliedFill {
            appliedFill = fill
            overlay.dogView.setBar(hex: fill)
        }
    }

    /// Samples the window's title-bar colour when the frontmost app or the appearance changes (not per title: browsers retitle constantly). Without Screen
    /// Recording the fixed light / dark fallback stays in force.
    private func refreshTint(_ obs: WindowObservation?, docked: Bool) {
        let live = boundTarget
        guard docked, let obs else {
            // Always logged (bundle id only), once per change: whether a sample ran is part of what a live run must be able to show.
            var why = TabTintPolicy.SkipReason.notDocked
            if let target = live, let other = obs,
               !LiveBinding.mayRead(bundleID: other.bundleID, target: target, ownBundleID: Bundle.main.bundleIdentifier) { why = .liveBoundOtherApp }
            let line = TabTintPolicy.logLine(bundleID: obs?.bundleID, skip: why)
            if line != lastNotDockedTintLine { lastNotDockedTintLine = line; print(line) }
            return
        }
        // Refused apps are never captured; a live run bound to an app captures no other one.
        let skip = TabTintPolicy.skipReason(docked: true, bundleID: obs.bundleID, screenRecordingAllowed: CGPreflightScreenCaptureAccess(), liveTarget: live)
        let canSample = skip == nil
        let key = "\(obs.pid)|\(TabTint.isDark)|\(skip?.rawValue ?? "sample")"   // granting Screen Recording later triggers a sample
        guard key != tintKey else { return }
        tintKey = key
        lastNotDockedTintLine = ""
        print(TabTintPolicy.logLine(bundleID: obs.bundleID, skip: skip))
        tintTask?.cancel()
        sampledFill = nil
        if let layout = currentLayout { drawTab(layout) }
        guard canSample else { return }
        let pid = obs.pid
        let frame = obs.axFrame
        tintTask = Task { [weak self] in
            let hex = await TabTint.sampleBarColor(pid: pid, nearFrame: frame, liveTarget: live)
            guard !Task.isCancelled, let self else { return }
            self.sampledFill = hex
            if let layout = self.currentLayout { self.drawTab(layout) }
        }
    }

    /// Logged at dock time (always, not only in the demo): the computed rectangles, then what the page measured.
    private func logDock(_ layout: PanelLayout) {
        print("[shep] dock \(layout.logDescription) webviewActual=\(NSStringFromRect(overlay.dogView.frame))")
        overlay.dogView.verifyLayout(layout) { report in print("[shep] dock page \(report)") }
    }

    private func log(_ obs: WindowObservation?, _ plan: DockPlan) {
        func r(_ f: CGRect) -> String { "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))" }
        let app = obs.map { "\($0.bundleID ?? "?")[\($0.pid)]" } ?? "none"
        let win = obs?.axFrame.map { "ax=\(r($0))" } ?? "ax=nil"
        let fs = (obs?.isFullScreen ?? false) ? " fullscreen" : ""
        // The tab in the same top-left space as `ax=` (what scripts/capture-lib.sh expects), not Cocoa's bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func topLeft(_ f: CGRect) -> CGRect { CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height) }
        let dock = plan.placement.layout.map { "tab \($0.style == .above ? "above" : "inside") \(r(topLeft($0.rect)))" } ?? "hidden"
        print("[shep] tracker app=\(app) \(win)\(fs) -> \(dock) (\(plan.note))")
    }
}
