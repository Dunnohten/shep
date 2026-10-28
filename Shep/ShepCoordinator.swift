import AppKit
import ApplicationServices
import ShepCore

/// Shep's day: asleep in the doghouse until called, then out of the door, across the screen to the tab of the window in
/// front, working there, and home again. Owns the doghouse panel, the traveller panel, the timers and the call inputs'
/// target; the rules are ShepCore's `ShepLifecycle`, and this class carries out its effects. Written for Shep.
@MainActor
final class ShepCoordinator {
    let overlay: OverlayController
    /// False for the always-docked demo flags: Shep then behaves as before (no house, always on the front window).
    let enabled: Bool

    private var lifecycle: ShepLifecycle
    private let home = HomePanel()
    private let traveller = TravelPanel()
    private let escape = EscapeMonitor()
    private let verbose: Bool
    private let statusItemFrame: () -> CGRect?
    private var placement: HomePlacement?
    private var loggedPlacement: HomePlacement?
    /// Bumped whenever a new phase begins, so a timer from an earlier phase does nothing when it fires.
    private var epoch = 0
    private var timeoutWork: DispatchWorkItem?
    private var lostWork: DispatchWorkItem?
    private var pendingAfterArrival: (() -> Void)?
    /// The dog is outside the house (travelling, working, or on its way back).
    private var dogIsOut = false
    private var leavePoint: CGPoint?
    private var houseHidden = false
    private var screenAsleep = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var cycleSignals: [DispatchSourceSignal] = []
    private var cycleRunning = false
    /// `--demo-backdrop`: a plain backdrop behind the cycle (see DemoBackdrop); set before `armCycleDemo`.
    var demoBackdropEnabled = false
    private let backdrop = DemoBackdrop()
    private var cycleStart: TimeInterval = 0

    /// The state changed: the menu refreshes its items.
    var onStateChange: (() -> Void)?
    /// "Bark when done" and its volume, read when the finish beat starts.
    var finishSettings: () -> (barkWhenDone: Bool, volume: Double) = { (true, ShepSettings.defaultBarkVolume) }
    private let barkPlayer = BarkPlayer()
    private var finishToken = 0

    /// Shep is leaving (sent home, undocked, dismissed): whatever is being spoken stops. Wired to VoiceController.stopSpeaking.
    var onStopSpeaking: (() -> Void)?
    /// Ends the voice session when Shep finds no window (`LifecycleEffect.cancelVoice`).
    weak var voice: VoiceCancelling?
    /// Cancels the running fix task when arrival fails (`LifecycleEffect.cancelFixTask`).
    var onCancelFixTask: (() -> Void)?

    var state: LifecycleState { lifecycle.state }
    var isHouseHidden: Bool { houseHidden }

    init(overlay: OverlayController, enabled: Bool, verbose: Bool, theme: ShepTheme, statusItemFrame: @escaping () -> CGRect?) {
        self.overlay = overlay
        self.enabled = enabled
        self.verbose = verbose
        self.statusItemFrame = statusItemFrame
        self.lifecycle = ShepLifecycle(state: .asleep, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard enabled else { return }
        home.container.onPress = { [weak self] in self?.call(.doghouse) }
        home.house.setTheme(theme.name)
        home.house.setReduceMotion(lifecycle.reduceMotion)
        home.house.setMode(.asleep)
        home.house.setPose(.asleep, reduceMotion: lifecycle.reduceMotion)
        traveller.setTheme(theme.name)
        traveller.setBar(hex: TabTint.fallbackHex(dark: TabTint.isDark))
        escape.onEscape = { [weak self] in
            guard let self, !self.overlay.isPillOpen else { return }   // the ask field takes Escape itself
            self.send(.dismiss)
        }
        overlay.onWindowLost = { [weak self] lost in self?.windowLostChanged(lost) }
        overlay.onPillChanged = { [weak self] open in self?.send(open ? .taskStarted : .taskDone) }
        overlay.onActivity = { [weak self] in self?.send(.call(.doghouse)) }
    }

    // MARK: start, theme, house

    /// Puts the doghouse up and starts listening for what changes the screens. Nothing is tracked yet: Shep is asleep.
    func start() {
        guard enabled else { return }
        overlay.start(tracking: false)
        overlay.disallowPresentation()
        placeHome()
        observe()
        // The status item gets its window a moment after launch; place the house again once it exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.placeHome() }
    }

    func setTheme(_ theme: ShepTheme) {
        home.house.setTheme(theme.name)
        traveller.setTheme(theme.name)
    }

    func setHouseHidden(_ hidden: Bool) {
        houseHidden = hidden
        if hidden { home.orderOut(nil) } else if placement != nil { home.orderFrontRegardless() }
        updateHouseActivity()
    }

    private func placeHome() {
        let screens = NSScreen.screens.map { s in
            HomeScreen(frame: s.frame, visibleFrame: s.visibleFrame,
                       auxLeft: HomeScreen.normalizedAux(s.auxiliaryTopLeftArea, in: s.frame),
                       auxRight: HomeScreen.normalizedAux(s.auxiliaryTopRightArea, in: s.frame))
        }
        guard let p = HomeGeometry.place(screens: screens, statusItem: statusItemFrame()) else { return }
        placement = p
        if home.frame != p.rect { home.setFrame(p.rect, display: true) }
        if !houseHidden && !home.isVisible { home.orderFrontRegardless() }
        updateHouseActivity()
        if verbose, p != loggedPlacement {
            loggedPlacement = p
            print("[shep] home \(p.logDescription(primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0))")
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        let t1 = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.placeHome() }
        }
        observers.append((center, t1))
        let t2 = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: home, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateHouseActivity() }
        }
        observers.append((center, t2))
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            let t = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenAsleep = true; self?.updateHouseActivity() }
            }
            observers.append((ws, t))
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            let t = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenAsleep = false; self?.updateHouseActivity() }
            }
            observers.append((ws, t))
        }
        let t3 = ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                let on = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.home.house.setReduceMotion(on)
                self?.send(.reduceMotion(on))
            }
        }
        observers.append((ws, t3))
    }

    /// Nothing is rendered while the house is hidden, covered, or the screen sleeps.
    private func updateHouseActivity() {
        let on = !houseHidden && home.isVisible && home.occlusionState.contains(.visible) && !screenAsleep
        home.house.setActive(on)
    }

    // MARK: calling and sending home

    /// Wakes Shep (from any source). `then` runs once Shep is on the window; at once if it already is.
    func call(_ source: CallSource, then action: (() -> Void)? = nil) {
        guard enabled else { action?(); return }
        if lifecycle.state == .working {
            send(.call(source))
            action?()
            return
        }
        if let action { pendingAfterArrival = action }
        send(.call(source))
    }

    /// "Send Shep Home": a dismiss, which also stops any speech (see `send`).
    func sendHome() { send(.dismiss) }

    func taskStarted() { send(.taskStarted) }
    func taskDone() { send(.taskDone) }

    /// Applies an event and carries out what the lifecycle asks for.
    func send(_ event: LifecycleEvent) {
        guard enabled else { return }
        if event == .dismiss || event == .arrivalFailed { onStopSpeaking?() }
        if lifecycle.state == .working, let p = overlay.dogCenter { leavePoint = p }   // where the walk home starts
        let before = lifecycle.state
        let effects = lifecycle.handle(event)
        if verbose, before != lifecycle.state || !effects.isEmpty {
            print("[shep] lifecycle \(before.rawValue) -> \(lifecycle.state.rawValue) on \(event)")
        }
        for effect in effects { perform(effect) }
        if before != lifecycle.state { onStateChange?() }
    }

    private func perform(_ effect: LifecycleEffect) {
        switch effect {
        case .startTracking: overlay.beginTracking()
        case .stopTracking: overlay.endTracking()
        case .beginWake(let reduced): beginWake(reduced: reduced)
        case .beginTravel(let reduced): beginTravel(reduced: reduced)
        case .dock: dock()
        case .undock: undock()
        case .beginReturn(let reduced): beginReturn(reduced: reduced)
        case .sleep: sleep()
        case .armTimeout(let seconds): armTimeout(seconds)
        case .cancelTimeout:
            timeoutWork?.cancel()
            timeoutWork = nil
        case .cancelVoice: voice?.cancelVoice()
        case .cancelFixTask: onCancelFixTask?()
        }
    }

    /// Runs `block` after `seconds`, unless a newer phase has begun by then.
    private func after(_ seconds: TimeInterval, epoch mine: Int, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.epoch == mine else { return }
                block()
            }
        }
    }

    // MARK: phases

    private func beginWake(reduced: Bool) {
        epoch += 1
        let mine = epoch
        dogIsOut = false
        leavePoint = nil   // the walk home must not start from an earlier visit
        home.house.setMode(.waking)
        home.house.setPose(.waking, reduceMotion: reduced)   // one ear twitches, then both pop up
        demoState("wake")
        after(reduced ? LifecycleTimings.reducedWakeSeconds : LifecycleTimings.wakeSeconds, epoch: mine) { [weak self] in
            guard let self else { return }
            let hasTarget = self.overlay.travelTarget() != nil
            if !hasTarget {
                self.pendingAfterArrival = nil
                self.announce(AXIsProcessTrusted() ? "There is no window for me to sit on." : "I need Accessibility permission to find your window. Open Shep Setup from the menu.")
            }
            self.send(.wakeFinished(hasTarget: hasTarget))
        }
    }

    private func beginTravel(reduced: Bool) {
        epoch += 1
        let mine = epoch
        let screens = NSScreen.screens.map(\.frame)
        guard let target = overlay.travelTarget(), let dest = target.destination(screens: screens), let door = placement?.door else {
            send(.arrivalFailed)
            return
        }
        // From the door, or, when called again on the way home, from wherever the dog is.
        demoState("travel")
        traveller.dog.setPose(.idle, reduceMotion: reduced)
        let from: CGPoint = dogIsOut ? (traveller.center ?? leavePoint ?? door) : door
        traveller.cancel()
        dogIsOut = true
        if reduced {
            // Reduce Motion: no travel. The sleeping dog has faded out at the door; the dock fades in at the target.
            home.house.setMode(.away)
            after(0.05, epoch: mine) { [weak self] in self?.send(.arrived) }
            return
        }
        let path = TravelPath.arc(from: from, to: dest, screens: screens)
        let duration = path.duration
        logTravel("tab", path)
        traveller.fly(path.samples(duration: duration, screens: screens)) {}
        // The house's dog hands over to the traveller (which fades in over its first tenth); the dock starts rising a tenth
        // before the traveller lands, so the two cross-fade.
        after(0.1, epoch: mine) { [weak self] in self?.home.house.setMode(.away) }
        after(duration * (1 - TravelPath.fadeShare), epoch: mine) { [weak self] in self?.send(.arrived) }
    }

    private func dock() {
        overlay.allowPresentation()
        overlay.setPose(.idle)
        demoState("docked")
        escape.start()
        announce("Shep is here.")
        if let action = pendingAfterArrival {
            pendingAfterArrival = nil
            after(0.5, epoch: epoch) { action() }   // let the head finish rising first
        }
    }

    private func undock() {
        onStopSpeaking?()
        escape.stop()
        lostWork?.cancel()
        overlay.disallowPresentation(fade: lifecycle.reduceMotion)
    }

    private func beginReturn(reduced: Bool) {
        epoch += 1
        let mine = epoch
        pendingAfterArrival = nil
        demoState("return")
        let screens = NSScreen.screens.map(\.frame)
        let from: CGPoint? = traveller.isFlying ? traveller.center : leavePoint
        traveller.cancel()
        guard let door = placement?.door, let start = from, !reduced else {
            // Reduce Motion (or nowhere to start from): the dock fades out here, the dog fades in at home.
            after(reduced ? 0.3 : 0, epoch: mine) { [weak self] in self?.send(.homeReached) }
            return
        }
        let path = TravelPath.arc(from: start, to: door, screens: screens)
        let duration = path.duration
        logTravel("home", path)
        traveller.fly(path.samples(duration: duration, screens: screens)) {}
        after(duration * (1 - TravelPath.fadeShare), epoch: mine) { [weak self] in self?.send(.homeReached) }
    }

    private func sleep() {
        epoch += 1   // a wake timer still pending (dismissed while waking) must not look for a window
        escape.stop()
        pendingAfterArrival = nil
        if dogIsOut {
            dogIsOut = false
            home.house.setMode(.entering)   // appears, turns round, curls up, eyes close
            home.house.setPose(.asleep, reduceMotion: lifecycle.reduceMotion)   // ears droop flat
            after(LifecycleTimings.enterSeconds, epoch: epoch) { [weak self] in self?.home.house.setMode(.asleep) }
        } else {
            home.house.setMode(.asleep)
        }
        demoState("asleep")
        announce("Shep went home to sleep.")
    }

    private func armTimeout(_ seconds: TimeInterval) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.send(.timeout) } }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The tab has no window for 1.5 s straight (closed, full screen, an app Shep does not dock to): go home.
    private func windowLostChanged(_ lost: Bool) {
        guard lost, lifecycle.state == .working || lifecycle.state == .traveling else {
            lostWork?.cancel()
            lostWork = nil
            return
        }
        if lostWork != nil { return }   // already counting: repeated reports must not push the deadline out
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.lostWork = nil
                self?.send(.windowLost)
            }
        }
        lostWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func logTravel(_ to: String, _ path: TravelPath) {
        guard verbose else { return }
        print("[shep] travel to=\(to) \(path.logDescription(primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0))")
    }

    /// VoiceOver speaks this; with it off nothing happens.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: the finish beat

    /// A fix finished: ears up and "Done." for VoiceOver, then one hop and one woof together, a moment's hold, then home.
    /// With VoiceOver running the woof waits until VoiceOver has finished speaking (or 1.5 s). Reduce Motion: no hop.
    func finishBeat() {
        guard enabled, lifecycle.state == .working else { return }
        finishToken += 1
        let started = ProcessInfo.processInfo.systemUptime
        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        timeoutWork?.cancel()
        timeoutWork = nil
        demoState("finish")
        overlay.setPose(.finish)
        overlay.announceDone()
        planFinish(started: started, voiceOver: voiceOver, voiceOverFinishedAt: nil)
        if voiceOver {
            let token = finishToken
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: Notification.Name("NSAccessibilityAnnouncementDidFinishNotification"),
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let o = observer { NotificationCenter.default.removeObserver(o) }
                    observer = nil
                    guard let self, self.finishToken == token else { return }
                    self.planFinish(started: started, voiceOver: true, voiceOverFinishedAt: ProcessInfo.processInfo.systemUptime - started)
                }
            }
            // The notification may never come: stop listening after the timeout (the planned steps already ran).
            DispatchQueue.main.asyncAfter(deadline: .now() + FinishBeat.voiceOverTimeout + 0.5) {
                if let o = observer { NotificationCenter.default.removeObserver(o) }
                observer = nil
            }
        }
    }

    /// Schedules hop, woof and the walk home from the steps; a new plan (VoiceOver finished early) replaces the old one.
    private func planFinish(started: TimeInterval, voiceOver: Bool, voiceOverFinishedAt: TimeInterval?) {
        finishToken += 1
        let token = finishToken
        let cfg = finishSettings()
        let steps = FinishBeat.steps(reduceMotion: lifecycle.reduceMotion, barkEnabled: cfg.barkWhenDone,
                                     voiceOverRunning: voiceOver, voiceOverFinishedAt: voiceOverFinishedAt)
        for step in steps where step.action != .earsUp && step.action != .announceDone {
            let wait = max(0, step.at - (ProcessInfo.processInfo.systemUptime - started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.finishToken == token, self.lifecycle.state == .working else { return }
                    switch step.action {
                    case .hop: self.overlay.hop()
                    case .woof: self.barkPlayer.play(volume: cfg.volume)
                    case .goHome: self.send(.dismiss)
                    case .earsUp, .announceDone: break
                    }
                }
            }
        }
    }

    // MARK: --demo-script=cycle (scripts/record-cycle.sh)

    /// Waits asleep. SIGUSR2 looks at the front window and logs the planned travel (so a recording can keep its corridor);
    /// SIGUSR1 plays the cycle once. SHEP_DEMO_AUTOSTART=1 starts it after 3 s instead.
    func armCycleDemo() {
        guard enabled else { return }
        print("[shep] cycle armed duration=\(String(format: "%.1f", CycleScript.duration))")
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        let start = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        start.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.runCycle() } }
        start.resume()
        let plan = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        plan.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.planCycle() } }
        plan.resume()
        cycleSignals = [start, plan]
        if ProcessInfo.processInfo.environment["SHEP_DEMO_AUTOSTART"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.runCycle() }
        }
    }

    /// Tracks the front window for a moment and logs where the cycle would go, in top-left screen coordinates:
    /// the house, the window, the tab and the arc's corridor. Does not wake Shep.
    private func planCycle() {
        guard lifecycle.state == .asleep else { print("[shep] cycle plan skipped (not asleep)"); return }
        overlay.beginTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            defer { if self.lifecycle.state == .asleep { self.overlay.endTracking() } }
            let h = NSScreen.screens.first?.frame.height ?? 0
            func topLeft(_ f: CGRect) -> String {
                "\(Int(f.minX.rounded())),\(Int((h - f.maxY).rounded())),\(Int(f.width.rounded())),\(Int(f.height.rounded()))"
            }
            guard let target = self.overlay.travelTarget(), case .tab(let window, _) = target,
                  let tab = self.overlay.tabRect, let dest = target.destination(screens: NSScreen.screens.map(\.frame)),
                  let door = self.placement?.door else {
                print("[shep] cycle plan failed: no window to sit on (keep the Shep test window in front)")
                return
            }
            let path = TravelPath.arc(from: door, to: dest, screens: NSScreen.screens.map(\.frame))
            print("[shep] cycle plan window=\(topLeft(window)) tab=\(topLeft(tab)) \(path.logDescription(primaryScreenHeight: h))")
            if self.demoBackdropEnabled { self.showBackdrop(window: window, tab: tab, path: path, screens: NSScreen.screens.map(\.frame), height: h) }
        }
    }

    // MARK: --live-request (scripts/record-fix-demo.sh)

    /// `--live-request` with `--demo-backdrop`: a plain backdrop window directly below the target app's front window, covering
    /// the window plus a margin and the overlay panel (tab, dog's head, speech bubble, approval card). Logs
    /// `[shep] live: record-rect x,y,w,h` (global top-left points) and returns the Cocoa rectangle; nil (and a logged reason)
    /// when it cannot be placed safely. It changes nothing about which app is targeted.
    @discardableResult
    func showLiveBackdrop() -> CGRect? {
        guard let seen = overlay.observedWindow else { print(LiveLog.backdropFailed("no front window seen")); return nil }
        let height = NSScreen.screens.first?.frame.height ?? 0
        guard let rect = liveRecordRect() else {
            print(LiveLog.backdropFailed("nothing to cover"))
            return nil
        }
        guard let number = DemoBackdrop.windowNumber(pid: seen.pid, frame: seen.frame) else {
            print(LiveLog.backdropFailed("could not find the target window's number"))
            return nil
        }
        guard backdrop.show(rect: rect, belowWindow: number) else {
            print(LiveLog.backdropFailed("the backdrop did not show"))
            return nil
        }
        print(LiveLog.recordRect(rect, primaryScreenHeight: height))
        return rect
    }

    /// The window plus the margins that hold the tab, the dog's head, the speech bubble and the approval card (Cocoa
    /// coordinates, clamped to the usable screen area). The backdrop and the window-bound recording crop use the same rectangle.
    func liveRecordRect() -> CGRect? {
        guard let seen = overlay.observedWindow else { return nil }
        let height = NSScreen.screens.first?.frame.height ?? 0
        let window = AXCoordinates.cocoaRect(fromAX: seen.frame, primaryScreenHeight: height)
        return LiveBackdropGeometry.rect(window: window, panel: overlay.panelFrame, usable: NSScreen.screens.map { $0.visibleFrame })
    }

    func hideLiveBackdrop() { backdrop.hide() }

    /// `[shep] demo-state <name> t=<seconds>` at each change of the cycle demo, seconds from its start.
    private func demoState(_ name: String) {
        guard cycleRunning else { return }
        print("[shep] demo-state \(name) t=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - cycleStart))")
    }

    /// Paints the backdrop over the house, the travel corridor, the tab and the test window, and logs its rectangle
    /// (`[shep] backdrop rect=x,y,w,h`, global top-left points) for scripts/record-cycle.sh --backdrop to record.
    private func showBackdrop(window: CGRect, tab: CGRect, path: TravelPath, screens: [CGRect], height: CGFloat) {
        guard let house = placement?.rect, let seen = overlay.observedWindow else { print("[shep] backdrop failed: no house or window"); return }
        var parts: [CGRect] = [house, window, tab.insetBy(dx: 0, dy: -12)]   // 12 pt of headroom above the tab for the dog's head
        parts.append(contentsOf: path.corridor(margin: 40))
        let usable = NSScreen.screens.map(\.visibleFrame)
        guard let rect = BackdropGeometry.rect(covering: parts, usable: usable) else { print("[shep] backdrop failed: nothing to cover"); return }
        let number = DemoBackdrop.windowNumber(pid: seen.pid, frame: seen.frame)
        guard backdrop.show(rect: rect, belowWindow: number) else {
            print("[shep] backdrop failed: could not find the test window's window number")
            return
        }
        print("[shep] backdrop rect=\(BackdropGeometry.logString(rect, primaryScreenHeight: height))")
    }

    private func runCycle() {
        guard !cycleRunning else { return }
        cycleRunning = true
        cycleStart = ProcessInfo.processInfo.systemUptime
        print("[shep] cycle start")
        demoState("asleep")
        for step in CycleScript.steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.at) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch step.action {
                    case .call: self.call(.demo)
                    case .listen: self.taskStarted(); self.overlay.setState(.listening); self.demoState("listening")
                    case .think: self.overlay.setState(.thinking); self.demoState("thinking")
                    case .finish: self.finishBeat()
                    case .dismiss: self.overlay.setState(.idle); self.send(.dismiss)
                    }
                    print("[shep] cycle \(step.action)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CycleScript.duration) { [weak self] in
            MainActor.assumeIsolated {
                self?.backdrop.hide()
                print("[shep] cycle done")
            }
        }
    }
}
