import AppKit
import Combine
import ShepCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = LaunchOptions.parse(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    private let permissions = PermissionModel()
    private var overlay: OverlayController?
    private var fixScreen: FixScreenCoordinator?
    private var fixTask: Task<Void, Never>?
    private var coordinator: ShepCoordinator?
    private let hotKeys = HotKeyCenter()
    private let pushToTalk = PushToTalkMonitor()
    private var voice: VoiceController?
    private let wake = WakeWordListener()
    /// The Mac is asleep (between willSleep and didWake): the wake word does not listen.
    private var systemAsleep = false
    /// The permission prompts for "Hey Shep" are on screen; the refresh must not read "not yet allowed" as a refusal.
    private var wakeRequesting = false
    private var wakeObservers: [NSObjectProtocol] = []
    /// The last app other than Shep that came to the front: a voice call made while Shep's own window is in front goes back to it.
    private var lastOtherFront: NSRunningApplication?
    private var frontObserver: NSObjectProtocol?
    /// The focus handoff of the last voice call made from Shep's own window (`FocusHandoff`).
    private var focusHandoff: FocusHandoffWaiter?
    private var permissionSink: AnyCancellable?
    private let settings = SettingsModel()
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var currentTheme = ShepThemes.defaultTheme
    private var currentState = ShepDogState.idle
    /// `--live-request`: the one submission has been used (made, or given up on). Never reset: the request is submitted once.
    private var liveConsumed = false
    private var liveTimeout: DispatchWorkItem?
    /// The live run is over for good (refused, the target left, or `finished` printed): nothing ends it a second time.
    private var liveEnded = false
    /// `live: finished` has been printed (and its status event written), once.
    private var liveFinishedPrinted = false
    /// The run ended because the target left the front: what the coordinator still reports is dropped. A thread-safe latch (the
    /// debug dump's log callback reads it off the main actor), shared with the coordinator.
    private let liveGate = LiveRunGate()
    /// `--live-record` was refused before a recorder existed (the status event was written once).
    private var liveRecordRefusalReported = false
    /// The run reported its outcome (the last thing it says); a look that finds the target gone after that has nothing to end.
    private var liveOutcomeSeen = false
    /// `--live-target`: from `target-ok` until `live: finished` the run stays bound to this app. An activation observer plus a
    /// 0.25 s poll (the backup) look at the front app; both stop at `finished`.
    private var liveBoundTarget: String?
    private var liveActivationToken: NSObjectProtocol?
    private var livePollTimer: DispatchSourceTimer?
    /// `--live-status`: the structured status file of this run (created exclusively at launch), or why it could not be made.
    private var liveStatus: LiveStatusFile?
    private var liveStatusFailure: String?
    /// The `LiveRecorder` of `--live-record` (macOS 15 and later), held as AnyObject so this class needs no availability.
    private var liveRecorder: AnyObject?
    private static let liveSettleSeconds = 1.5       // after shep.start(), before Shep is called
    private static let liveArrivalTimeoutSeconds = 25.0
    private static let liveRecordLeadSeconds = 3.0   // with a backdrop: time for the recorder to start before the request goes in
    private static let liveBackdropLingerSeconds = 5.0
    private static let liveRecordStartLeadSeconds = 1.0   // after the recording started, before the request goes in
    private static let liveRecordTailSeconds = 3.0        // after `live: finished`, before the recording stops

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let path = options.fixScreenOncePath {
            // Headless one-shot: run the pipeline on a PNG, print the report, exit. No overlay, no status item.
            setvbuf(stdout, nil, _IOLBF, 0)
            let environment = ProcessInfo.processInfo.environment
            Task {
                let code = await FixScreenCLI.run(path: path, environment: environment)
                fflush(stdout)
                exit(code)
            }
            return
        }
        if let target = options.axReadOnceTarget {
            // Headless, read-only: print what Accessibility shows for the app's windows, exit.
            setvbuf(stdout, nil, _IOLBF, 0)
            let environment = ProcessInfo.processInfo.environment
            let title = options.toolTitle, frame = options.toolFrame
            Task {
                let code = AXCommandLine.readOnce(target: target, title: title, frame: frame, environment: environment)
                fflush(stdout)
                exit(code)
            }
            return
        }
        if let target = options.pressDemoTarget {
            // Headless: propose AXPress on one control and stop at the approval card, unless the operator typed --approve.
            setvbuf(stdout, nil, _IOLBF, 0)
            let environment = ProcessInfo.processInfo.environment
            let title = options.toolTitle, frame = options.toolFrame, approve = options.approveFlag
            let match = options.pressMatch ?? ""
            Task {
                var code: Int32 = 2
                if match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("press-demo-once: --match \"<text>\" is required")
                } else {
                    code = await AXCommandLine.pressDemo(target: target, match: match, title: title, frame: frame, approve: approve, environment: environment)
                }
                fflush(stdout)
                exit(code)
            }
            return
        }
        if let path = options.exportBarkPath {
            // Headless: write the synthesized woof (default volume) as a WAV file and exit. Used by scripts/record-cycle.sh.
            let data = WavWriter.data(samples: BarkSynth.samples(volume: ShepSettings.defaultBarkVolume))
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print("[shep] wrote bark \(path) (\(data.count) bytes)")
                exit(0)
            } catch {
                print("[shep] could not write \(path): \(error.localizedDescription)")
                exit(1)
            }
        }
        if options.dockDemo || options.demoScript || options.demoCycle || options.liveRequest != nil || options.liveRecordIgnoredLine != nil || options.liveDebugIgnoredLine != nil || options.liveTargetIgnoredLine != nil || options.liveStatusIgnoredLine != nil {
            setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so a redirected log (scripts/record-*.sh) shows state live
        }
        if let ignored = options.liveRecordIgnoredLine { print(ignored) }
        if let ignored = options.liveDebugIgnoredLine { print(ignored) }
        if let ignored = options.liveTargetIgnoredLine { print(ignored) }
        if let ignored = options.liveStatusIgnoredLine { print(ignored) }
        if options.liveRequest != nil, let statusPath = options.liveStatusPath, let nonce = options.liveNonce {
            // Exclusive create (O_CREAT | O_EXCL | O_NOFOLLOW, 0600): anything already there refuses the run (startLiveRequest).
            switch LiveStatusFile.create(path: statusPath, nonce: nonce) {
            case .success(let file): liveStatus = file
            case .failure(let refusal): liveStatusFailure = refusal.reason
            }
        }
        if options.dockDemo {
            print("[shep] dock demo: AX trusted=\(permissions.accessibility) screen=\(permissions.screenRecording)")
        }

        // An explicit --theme wins; otherwise the saved choice (Settings); otherwise Tangerine.
        currentTheme = options.theme != ShepThemes.defaultTheme ? options.theme : settings.settings.theme
        currentState = options.state
        settings.onChange = { [weak self] old, new in self?.settingsChanged(old, new) }

        // The always-docked demo flags keep the old behaviour (no doghouse, the dog on the front window from the start).
        let lifecycleEnabled = !(options.dockDemo || options.demoScript)
        let verbose = options.dockDemo || options.demoScript || options.demoCycle
        let controller = OverlayController(demo: options.dockDemo, verbose: verbose, theme: currentTheme, state: currentState, demoScript: options.demoScript)
        overlay = controller
        let fix = FixScreenCoordinator(overlay: controller, environment: { [weak self] in
            self?.settings.environment() ?? ProcessInfo.processInfo.environment
        })
        fixScreen = fix
        let shep = ShepCoordinator(overlay: controller, enabled: lifecycleEnabled, verbose: verbose, theme: currentTheme,
                                   statusItemFrame: { [weak self] in self?.statusItem?.button?.window?.frame })
        coordinator = shep
        shep.onStateChange = { [weak self] in self?.refreshMenu(); self?.refreshWakeWord() }
        shep.finishSettings = { [weak self] in
            let s = self?.settings.settings ?? ShepSettings.defaults
            return (s.barkWhenDone, s.barkVolume)
        }
        fix.onFinished = { [weak shep] in shep?.finishBeat() }
        if options.liveRequest != nil {
            // The `[shep] live:` lines (reporting only) and the structured status channel (no text). Once the target has left, the run
            // that is being stopped says nothing more: the left path wrote the reason, the outcome and `finished` itself.
            let gate = liveGate
            fix.externalGate = gate
            fix.onLive = { line in   // captures only the Sendable gate: it runs off the main actor too (the debug dump's log callback)
                if gate.isLeft { return }
                print(line)
            }
            fix.onLiveEvent = { [weak self] event in
                guard let self = self, !self.liveGate.isLeft else { return }
                if case .outcome = event { self.liveOutcomeSeen = true }
                self.liveEvent(event)
            }
            fix.onTargetLeft = { [weak self] why in self?.liveTargetLeft(why) }
        }
        fix.debugDirectory = options.liveDebugDir   // nil unless --live-debug-dir came with --live-request: then nothing is written
        // The ask field's text becomes the request for the same pipeline; Shep stays out until it is done.
        controller.onSubmit = { [weak self] text in self?.runFixScreen(request: text) }
        // Voice: hold the talk key, speak, let go; the final transcript is the request. Replies are spoken (unless muted or VoiceOver is on).
        let talk = VoiceController(permissions: permissions, overlay: controller)
        talk.onSubmit = { [weak self] text in self?.runFixScreen(request: text) }
        talk.showSetup = { [weak self] in self?.showOnboarding() }
        talk.speakReplies = { [weak self] in self?.settings.settings.speakReplies ?? true }
        controller.onReply = { [weak talk] text in talk?.reply(text) }
        voice = talk
        shep.voice = talk
        shep.onStopSpeaking = { [weak self, weak talk] in
            talk?.stopSpeaking()
            self?.fixTask?.cancel()   // sent home or dismissed: a running fix stops before its next step or event
        }

        shep.onCancelFixTask = { [weak self] in self?.fixTask?.cancel() }   // arrival failed: a fix already submitted must not run on

        buildStatusItem()
        if lifecycleEnabled {
            shep.start()
            installCallInputs(shep)
            installWakeWord()
            if options.demoCycle {
                shep.demoBackdropEnabled = options.demoBackdrop
                shep.armCycleDemo()
            }
            if let request = options.liveRequest { startLiveRequest(request, shep: shep) }
        } else {
            controller.start()
            if options.liveRequest != nil { print(LiveLog.prefix + "ignored: --live-request needs a normal launch (no --dock-demo or --demo-script)") }
        }
        if !options.dockDemo && !permissions.accessibility { showOnboarding() }
    }

    /// Global shortcut and push-to-talk key: both call Shep from the doghouse.
    private func installCallInputs(_ shep: ShepCoordinator) {
        hotKeys.onPress = { [weak shep] in shep?.call(.hotkey) }
        registerCallShortcut(settings.settings.callShortcut)
        pushToTalk.setKey(settings.settings.pushToTalkKey)
        // Holding the key starts listening at once (nothing said while Shep crosses the screen is lost) and wakes Shep from the doghouse.
        pushToTalk.onBegan = { [weak self] in self?.beginTalk(fromWakeWord: false) }
        pushToTalk.onEnded = { [weak self] in self?.voice?.release(); self?.refreshWakeWord() }
        pushToTalk.onCancelled = { [weak self] in self?.voice?.cancel(); self?.refreshWakeWord() }
        pushToTalk.start()
        watchFrontApp()
    }

    /// The voice call path: start listening at once (nothing said while Shep crosses the screen is lost) and wake Shep from the
    /// doghouse. Holding the talk key and "Hey Shep" both come here; only the wake word has no key to let go of.
    /// From Shep's own window the call waits for the focus handoff (`FocusHandoff`), so the dock check sees the previous app.
    private func beginTalk(fromWakeWord: Bool) {
        voice?.press(endOnSilence: fromWakeWord)
        if let waiting = focusHandoff, !waiting.isDone {
            refreshWakeWord()   // the handoff in flight makes the call
            return
        }
        if let waiter = focusHandoffIfShepIsInFront() {
            focusHandoff = waiter
            waiter.start()
        } else {
            coordinator?.call(.pushToTalk)
        }
        refreshWakeWord()
    }

    /// Keeps `lastOtherFront` current. Installed once with the call inputs.
    private func watchFrontApp() {
        guard frontObserver == nil else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own { lastOtherFront = front }
        frontObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app.processIdentifier != own else { return }
                self?.lastOtherFront = app
            }
        }
    }

    /// A call made while Shep's own window (Settings, Setup) is in front would find no window and send Shep straight back to
    /// sleep (`frontmost is Shep itself`). The app that was in front before Shep gets the focus back first (`WakeWordPolicy`).
    private func focusHandoffIfShepIsInFront() -> FocusHandoffWaiter? {
        let own = ProcessInfo.processInfo.processIdentifier
        let other = lastOtherFront.flatMap { $0.isTerminated ? nil : $0 }
        guard let pid = WakeWordPolicy.pidToRefocus(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                    ownPID: own, lastOtherPID: other?.processIdentifier),
              let app = other, app.processIdentifier == pid else { return nil }
        return FocusHandoffWaiter(app: app) { [weak self] effect in
            switch effect {
            case .log(let line): print(line)
            case .refreshTracker: self?.overlay?.refreshTracking()
            case .call:
                self?.coordinator?.call(.pushToTalk)
                self?.refreshWakeWord()
            case .cancelVoice:   // the user left: the voice session opened for this call ends with it
                self?.voice?.cancel()
                self?.refreshWakeWord()
            case .activate: break   // done by the waiter
            }
        }
    }

    // MARK: Hey Shep

    /// The wake word: the listener, its icon, and the events that decide whether the microphone may be open. The decision is
    /// `WakeWordPolicy.shouldListen`; `refreshWakeWord` feeds it the current facts and hands the answer to the listener.
    private func installWakeWord() {
        wake.onWake = { [weak self] in self?.beginTalk(fromWakeWord: true) }
        wake.onMicrophoneChange = { [weak self] open in self?.updateStatusIcon(microphoneOpen: open) }
        voice?.onActivityChange = { [weak self] in self?.refreshWakeWord() }
        permissionSink = permissions.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshWakeWord() } }
        }
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemAsleep = true; self?.refreshWakeWord() }
        })
        wakeObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemAsleep = false; self?.refreshWakeWord() }
        })
        refreshWakeWord()
    }

    private func wakeConditions() -> WakeWordConditions {
        let enabled = settings.settings.wakeWord && coordinator?.enabled == true
        return WakeWordConditions(enabled: enabled,
                           authorized: permissions.microphoneGranted && permissions.speechGranted,
                           onDeviceSupported: !enabled || wake.onDeviceSupported,   // the recogniser is only probed when the feature is on
                           pushToTalkActive: pushToTalk.isListening,
                           conversationActive: (voice?.isActive ?? false) || fixTask != nil || (coordinator?.state ?? .asleep) != .asleep,
                           asleep: systemAsleep)
    }

    private func refreshWakeWord() {
        permissions.refresh()
        let c = wakeConditions()
        if c.enabled, !c.authorized, !wakeRequesting {
            // Never listen without both permissions, and never leave the toggle claiming it does.
            turnWakeWordOff("Hey Shep is off: allow Microphone and Speech Recognition in System Settings > Privacy & Security, then turn it on again.")
            return
        }
        if c.enabled, c.authorized, !c.onDeviceSupported {
            wake.reportUnavailable()
            settings.wakeWordNote = "Hey Shep needs on-device speech recognition, which this Mac does not offer for your language. It stays off; nothing is sent to a server."
        }
        wake.setListening(WakeWordPolicy.shouldListen(c))
    }

    private func turnWakeWordOff(_ note: String) {
        wake.setListening(false)
        if settings.settings.wakeWord { settings.settings.wakeWord = false }   // clears the note (the toggle went off) ...
        settings.wakeWordNote = note                                           // ... so it is set after
    }

    /// The toggle went on: ask for the two permissions now (and only now), then start; a refusal turns it back off with the reason.
    private func wakeWordToggled(on: Bool) {
        settings.wakeWordNote = nil
        guard on else { refreshWakeWord(); return }
        wakeRequesting = true
        WakeWordListener.requestAuthorization { [weak self] problem in
            guard let self else { return }
            self.wakeRequesting = false
            self.permissions.refresh()
            if let problem { self.turnWakeWordOff(problem) } else { self.refreshWakeWord() }
        }
    }

    private func updateStatusIcon(microphoneOpen: Bool) {
        let state = StatusIconState.forMicrophone(open: microphoneOpen)
        statusItem?.button?.image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: state.accessibilityDescription)
        statusItem?.button?.toolTip = microphoneOpen ? state.accessibilityDescription : nil
    }

    private func registerCallShortcut(_ spec: HotKeySpec) {
        if !hotKeys.register(spec) {
            print("[shep] could not register the shortcut \(spec.name) (another app may own it); use the menu or the doghouse")
        }
    }

    /// A setting changed in the Settings window (or the menu): apply it now.
    private func settingsChanged(_ old: ShepSettings, _ new: ShepSettings) {
        if old.themeName != new.themeName {
            currentTheme = new.theme
            overlay?.setTheme(currentTheme)
            coordinator?.setTheme(currentTheme)
        }
        if old.pushToTalkKey != new.pushToTalkKey { pushToTalk.setKey(new.pushToTalkKey) }
        if old.wakeWord != new.wakeWord { wakeWordToggled(on: new.wakeWord) }
        if old.callShortcutID != new.callShortcutID, coordinator?.enabled == true { registerCallShortcut(new.callShortcut) }
        if old.speakReplies != new.speakReplies, !new.speakReplies { voice?.stopSpeaking() }
        if old.hideFromCapture != new.hideFromCapture { ScreenPrivacy.set(new.hideFromCapture) }
        refreshMenu()
    }

    /// Runs Fix This Screen and keeps Shep from timing out while it works. `completion` runs when the task has ended.
    private func runFixScreen(request: String?, completion: (() -> Void)? = nil) {
        guard let fix = fixScreen else { completion?(); return }
        let shep = coordinator
        fixTask = Task { [weak self] in
            shep?.taskStarted()
            await fix.run(request: request)
            shep?.taskDone()
            self?.fixTask = nil
            self?.refreshWakeWord()
            completion?()
        }
    }

    // MARK: --live-request

    /// Calls Shep like the shortcut does, waits until it is working at the front window, then submits `request` once, by the
    /// same path as the ask field (`runFixScreen`). It only submits: the approval card is answered by the person, and nothing
    /// here (or anywhere) approves for them. Without `--live-target` the frontmost app is the target (the log says which; if that
    /// is Shep itself, nothing happens). With it, the wanted app is activated and waited for, and the run is refused, reading
    /// nothing, if it is not in front at each look (`LiveTargetGate`).
    private func startLiveRequest(_ request: String, shep: ShepCoordinator) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveSettleSeconds) { [weak self, weak shep] in
            MainActor.assumeIsolated {
                guard let self, let shep, !self.liveConsumed else { return }
                // An explicit --live-target / SHEP_LIVE_TARGET that cannot be used refuses the run: Shep is not called, nothing is
                // read, captured, recorded or sent, and the front app is never used instead.
                if case .refuse(let why) = LiveRequestStart.decide(options: self.options) {
                    self.refuseLive(why, overlayLine: LiveRequestStart.overlayLine)
                    return
                }
                if let why = self.liveStatusFailure {
                    self.refuseLive("status: " + why, overlayLine: LiveRequestStart.overlayLine)
                    return
                }
                if let wanted = self.options.liveTarget {
                    self.waitForLiveTarget(wanted, since: ProcessInfo.processInfo.systemUptime) { [weak self, weak shep] in
                        guard let self, let shep, !self.liveConsumed else { return }
                        self.callShepForLive(request, shep: shep)
                    }
                    return
                }
                guard let front = NSWorkspace.shared.frontmostApplication,
                      front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    self.liveConsumed = true
                    print(LiveLog.noTargetInFront)
                    self.liveEvent(.reason(.noTarget))
                    self.liveFinished()
                    return
                }
                print(LiveLog.targetFront(front.bundleIdentifier))
                self.liveEvent(.targetOK)
                self.callShepForLive(request, shep: shep)
            }
        }
    }

    /// Starts the arrival timeout and calls Shep to the front window; `liveArrived` follows.
    private func callShepForLive(_ request: String, shep: ShepCoordinator) {
        print(LiveLog.waitingForArrival)
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.liveConsumed else { return }
                self.liveConsumed = true
                print(LiveLog.arrivalTimedOut)
                self.liveEvent(.reason(.arrival))
                self.liveFinished()
            }
        }
        liveTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveArrivalTimeoutSeconds, execute: timeout)
        shep.call(.hotkey) { [weak self, weak shep] in
            guard let self, let shep else { return }
            self.liveArrived(request, shep: shep)
        }
    }

    /// `--live-target`: looks at the front app every `LiveTargetGate.pollSeconds`, activating the wanted app, until it is in front
    /// (then `proceed` runs) or the budget is spent or the app cannot be used (then the run is refused).
    private func waitForLiveTarget(_ wanted: String, since start: TimeInterval, proceed: @escaping () -> Void) {
        guard !liveConsumed else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: wanted).filter { !$0.isTerminated }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        switch LiveTargetGate.decide(wanted: wanted, front: front, wantedRunning: !running.isEmpty, elapsed: elapsed, budget: LiveTargetGate.arrivalBudgetSeconds) {
        case .proceed:
            print(LiveLog.targetFront(wanted))
            liveEvent(.targetOK)
            startLiveBinding(wanted)   // from here to `finished` the run stays bound to this app
            proceed()
        case .refuse(let why):
            refuseLive(why)
        case .activateAndWait:
            _ = running.first?.activate()   // no scripting bridge; the next look says whether it worked
            DispatchQueue.main.asyncAfter(deadline: .now() + LiveTargetGate.pollSeconds) { [weak self] in
                MainActor.assumeIsolated { self?.waitForLiveTarget(wanted, since: start, proceed: proceed) }
            }
        }
    }

    /// The text of the refusal if the wanted app is not in front at this instant, else nil. Never waits.
    private func liveTargetRefusal(_ wanted: String) -> String? {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: wanted).filter { !$0.isTerminated }.isEmpty
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if case .refuse(let why) = LiveTargetGate.recheck(wanted: wanted, front: front, wantedRunning: running) { return why }
        return nil
    }

    /// The live run ends here: reason, outcome `refused`, one short line from Shep, `finished`. Nothing was read, captured or sent.
    private func refuseLive(_ why: String, overlayLine: String = LiveTargetGate.overlayLine) {
        guard !liveEnded else { return }   // a run ends once: a refusal after a left (or the other way round) does not run twice
        liveEnded = true
        liveConsumed = true
        liveTimeout?.cancel()
        liveTimeout = nil
        print(LiveLog.reason(why))
        liveEvent(.reason(LiveStatus.stage(forReasonText: why)))
        print(LiveLog.outcome(.refused))
        liveEvent(.outcome(.refused))
        overlay?.say(overlayLine)
        liveFinished()
        finishLiveRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.liveBackdropLingerSeconds) { [weak self] in
            MainActor.assumeIsolated { self?.coordinator?.hideLiveBackdrop() }
        }
    }

    /// One event on the structured status channel (`--live-status`); nothing when the channel is off. Never carries text.
    private func liveEvent(_ event: LiveStatusEvent) { liveStatus?.append(event) }

    private func liveFinished() {
        guard !liveFinishedPrinted else { return }
        liveFinishedPrinted = true
        liveEnded = true
        stopLiveBinding()   // the binding lasts exactly until `finished`
        print(LiveLog.finished)
        liveEvent(.finished)
    }

    // MARK: staying bound to the target

    /// Binds the run to `wanted` (at `target-ok`): the overlay's tracker, planner and tint refuse every other app, and the front app
    /// is watched until `finished` by NSWorkspace's activation notification and, as a backup, a repeating 0.25 s poll.
    private func startLiveBinding(_ wanted: String) {
        stopLiveBinding()
        liveBoundTarget = wanted
        overlay?.boundTarget = wanted
        liveActivationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // The app the notification names, read here: not whatever is in front when the callback finally runs.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid: Int32? = app?.processIdentifier
            let bundleID: String? = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.liveActivated(bundleID: bundleID, pid: pid) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + LiveTargetGate.pollSeconds, repeating: LiveTargetGate.pollSeconds)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkLiveBinding() }
        }
        timer.resume()
        livePollTimer = timer
    }

    /// Stops both watchers and unbinds the overlay. Safe to call again.
    private func stopLiveBinding() {
        if let token = liveActivationToken { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        liveActivationToken = nil
        livePollTimer?.cancel()
        livePollTimer = nil
        liveBoundTarget = nil
        overlay?.boundTarget = nil
    }

    /// An activation notification: the app it names decides (see `LiveTargetGate.activationLeft`), so a leave-and-return that was queued
    /// while the main thread was busy is still a leave.
    private func liveActivated(bundleID: String?, pid: Int32?) {
        guard !liveEnded, let wanted = liveBoundTarget else { return }
        guard let why = LiveTargetGate.activationLeft(wanted: wanted, activatedBundleID: bundleID, activatedPID: pid,
                                                      ownPID: ProcessInfo.processInfo.processIdentifier) else { return }
        liveTargetLeft(why)
    }

    /// One look at the front app. Shep itself in front (its card can take key status) is still bound; any other app that is not the
    /// target ends the run. No front app at all (a moment during a switch) is not a look.
    private func checkLiveBinding() {
        guard !liveEnded, let wanted = liveBoundTarget, let front = NSWorkspace.shared.frontmostApplication else { return }
        let frontIsShep = front.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard let why = LiveTargetGate.focusLeft(wanted: wanted, front: front.bundleIdentifier, frontIsShep: frontIsShep) else { return }
        liveTargetLeft(why)
    }

    /// The target is no longer in front (or is gone) while the run is bound: the run ends here, once. A waiting approval card is
    /// closed and answers "cancel" (so nothing that waited for approval is performed; a click already in progress is ClickGuard's
    /// to refuse), a model answer still on its way is dropped, and a recording is stopped and discarded. The discard is AWAITED: only
    /// when it has ended (the clip removed, or the failure reported as `discard-failed`, or the clip found already published) are the
    /// status event `target-left`, the reason line, outcome `refused`, one short line from Shep and `finished` written, so a script
    /// that stops Shep at `target-left` or `finished` cannot cut the cleanup short. What already happened (a screenshot already sent
    /// to the provider, an action already done) is not undone.
    private func liveTargetLeft(_ why: String) {
        guard !liveEnded, !liveOutcomeSeen else { return }
        liveEnded = true
        liveGate.latchLeft()
        liveConsumed = true
        liveTimeout?.cancel()
        liveTimeout = nil
        fixScreen?.targetWasLeft()
        fixTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.discardLiveRecording("the target left the front")
            self.liveEvent(.targetLeft)
            print(LiveLog.reason(why))
            self.liveEvent(.reason(LiveStatus.stage(forReasonText: why)))
            print(LiveLog.outcome(.refused))
            self.liveEvent(.outcome(.refused))
            self.overlay?.say(LiveTargetGate.leftOverlayLine)
            self.liveFinished()
            DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.liveBackdropLingerSeconds) { [weak self] in
                MainActor.assumeIsolated { self?.coordinator?.hideLiveBackdrop() }
            }
        }
    }

    /// Stops the recording and discards the clip (our own partial clip and directory only, through the recorder's slot rules), and
    /// returns when that has ended. The recorder writes the outcome event (`recording-discarded`, `discard-failed`,
    /// `recording-already-published`); without a recorder, a recording that was asked for and never started is reported here, once.
    private func discardLiveRecording(_ why: String) async {
        guard options.liveRecordPath != nil else { return }
        if #available(macOS 15.0, *), let recorder = liveRecorder as? LiveRecorder {
            _ = await recorder.requestDiscard(because: why)
            return
        }
        if !liveRecordRefusalReported {
            liveRecordRefusalReported = true
            liveEvent(.recordingDiscarded(refused: true))
        }
    }

    /// A recording that never started: the human line and the status event.
    private func liveRecordRefused(_ why: String) {
        liveRecordRefusalReported = true
        print(LiveLog.recordRefused(why))
        liveEvent(.recordingDiscarded(refused: true))
    }

    /// Shep is working at the front window: show the backdrop (if asked), then submit the request, once.
    private func liveArrived(_ request: String, shep: ShepCoordinator) {
        guard !liveConsumed else { return }
        liveConsumed = true
        liveTimeout?.cancel()
        liveTimeout = nil
        // Bound to an app: it must still be the one in front before anything is recorded, and again at the instant of submission.
        if let wanted = options.liveTarget, let why = liveTargetRefusal(wanted) { liveTargetLeft(why); return }
        let submit: () -> Void = { [weak self, weak shep] in
            if self?.liveEnded == true { return }   // the target left (or the run was refused) while the recorder or backdrop started
            if let wanted = self?.options.liveTarget, let why = self?.liveTargetRefusal(wanted) { self?.liveTargetLeft(why); return }
            self?.fixScreen?.requiredBundleID = self?.options.liveTarget   // the coordinator looks once more before it reads
            print(LiveLog.requestSubmitted(request))
            self?.liveEvent(.requestSubmitted)
            self?.runFixScreen(request: request) {
                self?.fixScreen?.requiredBundleID = nil
                if self?.liveEnded == true { return }   // the left path (or a refusal) owns the end of the run: no second `finished`, no second stop
                self?.liveFinished()
                self?.finishLiveRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.liveBackdropLingerSeconds) {
                    MainActor.assumeIsolated { shep?.hideLiveBackdrop() }
                }
            }
        }
        if let path = options.liveRecordPath {
            // Window-bound recording first (refused quietly when the policy says no: the fix still runs), then the request.
            startLiveRecording(path: path, shep: shep) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveRecordStartLeadSeconds) { MainActor.assumeIsolated { submit() } }
            }
        } else if options.demoBackdrop, shep.showLiveBackdrop() != nil {
            // The rectangle is logged: give the recorder a moment to start before the request goes in.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveRecordLeadSeconds) { MainActor.assumeIsolated { submit() } }
        } else {
            submit()
        }
    }

    /// `--live-record`: starts the window-bound recording of the front window Shep is working at, then calls `proceed` (also when
    /// the recording is refused or cannot start; the fix itself does not depend on it).
    private func startLiveRecording(path: String, shep: ShepCoordinator, then proceed: @escaping () -> Void) {
        guard #available(macOS 15.0, *) else {
            liveRecordRefused("window-bound recording needs macOS 15 or later")
            proceed()
            return
        }
        guard let seen = overlay?.observedWindow, let cocoa = shep.liveRecordRect() else {
            liveRecordRefused("no front window seen")
            proceed()
            return
        }
        let height = NSScreen.screens.first?.frame.height ?? 0
        print(LiveLog.recordRect(cocoa, primaryScreenHeight: height))
        let crop = CGRect(x: cocoa.minX, y: height - cocoa.maxY, width: cocoa.width, height: cocoa.height)   // global top-left points
        let recorder = LiveRecorder(outputURL: URL(fileURLWithPath: path), maxSeconds: options.liveRecordSeconds,
                                    overlayWindowNumbers: { AppDelegate.overlayWindowNumbers() }, log: { print($0) },
                                    onEvent: { [weak self] event in self?.liveEvent(event) })
        liveRecorder = recorder
        // The recorder keeps the start task: a discard requested later awaits it (bounded) and never answers `neverStarted` for a start that
        // was launched. A target that left while it started is handled by the recorder itself (the latch is checked after each await).
        let started = recorder.launchStart(pid: seen.pid, frame: seen.frame, crop: crop)
        Task { @MainActor in
            _ = await started.value
            proceed()
        }
    }

    /// The request finished: the recording gets a few more seconds of the end state, then stops and is written.
    private func finishLiveRecording() {
        guard #available(macOS 15.0, *), let recorder = liveRecorder as? LiveRecorder else { return }
        recorder.requestStop(afterSeconds: Self.liveRecordTailSeconds)
    }

    /// Shep's own overlay windows that are on screen: the dog tab and panel, the travelling dog, the doghouse. Not the backdrop,
    /// the setup or the settings window.
    private static func overlayWindowNumbers() -> Set<Int> {
        var numbers = Set<Int>()
        for window in NSApp.windows where window.isVisible && (window is DockOverlay || window is TravelPanel || window is HomePanel) {
            numbers.insert(window.windowNumber)
        }
        return numbers
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Shep")
        statusItem = item
        item.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false   // the items below set isEnabled themselves
        menu.addItem(withTitle: "Shep Setup…", action: #selector(showSetup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self

        let lifecycle = coordinator?.enabled ?? false
        let call = NSMenuItem(title: "Call Shep", action: #selector(callShep), keyEquivalent: " ")
        call.keyEquivalentModifierMask = [.control, .shift, .command]   // shown beside the item; the global shortcut is the same
        call.target = self
        call.isEnabled = lifecycle
        call.toolTip = "Wakes Shep and sends it to the window in front. Shortcut: \(HotKeySpec.call.name), or hold Right Option."
        menu.addItem(call)

        menu.addItem(withTitle: "Fix This Screen", action: #selector(fixThisScreen), keyEquivalent: "").target = self

        let home = NSMenuItem(title: "Send Shep Home", action: #selector(sendShepHome), keyEquivalent: "")
        home.target = self
        home.isEnabled = lifecycle && (coordinator?.state ?? .asleep) != .asleep
        menu.addItem(home)

        let toggle = NSMenuItem(title: (coordinator?.isHouseHidden ?? false) ? "Show Doghouse" : "Hide Doghouse", action: #selector(toggleDoghouse), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = lifecycle
        menu.addItem(toggle)

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for t in ShepThemes.all {
            let mi = NSMenuItem(title: t.name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = t.name
            mi.state = (t == currentTheme) ? .on : .off
            themeMenu.addItem(mi)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        let stateItem = NSMenuItem(title: "State", action: nil, keyEquivalent: "")
        let stateMenu = NSMenu()
        for s in ShepDogState.allCases {
            let mi = NSMenuItem(title: s.rawValue, action: #selector(pickState(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s.rawValue
            mi.state = (s == currentState) ? .on : .off
            stateMenu.addItem(mi)
        }
        stateItem.submenu = stateMenu
        menu.addItem(stateItem)

        let speak = NSMenuItem(title: "Speak Replies", action: #selector(toggleSpeakReplies), keyEquivalent: "")
        speak.target = self
        speak.state = settings.settings.speakReplies ? .on : .off
        menu.addItem(speak)

        let cloud = NSMenuItem(title: "Allow Screenshots to Meta Cloud", action: #selector(toggleCloud), keyEquivalent: "")
        cloud.target = self
        cloud.state = MetaVisionSettings.sendScreenshots() ? .on : .off
        menu.addItem(cloud)

        let hide = NSMenuItem(title: "Hide Shep from Screen Sharing", action: #selector(toggleHideFromCapture), keyEquivalent: "")
        hide.target = self
        hide.state = settings.settings.hideFromCapture ? .on : .off
        menu.addItem(hide)

        // TODO(later milestones): Settings…, voice on/off, brain choice.
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shep", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    private func refreshMenu() { statusItem?.menu = makeMenu() }

    @objc private func showSetup() { showOnboarding() }

    @objc private func showSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settings)))
        w.title = "Shep Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.sharingType = ScreenPrivacy.sharingType
        w.center()
        settingsWindow = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.settingsWindow = nil }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func callShep() { coordinator?.call(.menu) }

    @objc private func sendShepHome() { coordinator?.sendHome() }

    /// Wakes Shep if it is asleep and runs the pipeline once it is on the window.
    @objc private func fixThisScreen() {
        guard let coordinator else { return }
        coordinator.call(.menu) { [weak self] in self?.runFixScreen(request: nil) }
    }

    @objc private func toggleSpeakReplies() {
        settings.settings.speakReplies.toggle()   // saved and applied by settingsChanged
    }

    @objc private func toggleCloud() {
        MetaVisionSettings.setSendScreenshots(!MetaVisionSettings.sendScreenshots())
        refreshMenu()
    }

    @objc private func toggleHideFromCapture() {
        settings.settings.hideFromCapture.toggle()   // saved and applied by settingsChanged
    }

    @objc private func toggleDoghouse() {
        guard let coordinator else { return }
        coordinator.setHouseHidden(!coordinator.isHouseHidden)
        refreshMenu()
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        settings.settings.themeName = ShepThemes.find(name).name   // saved and applied by settingsChanged
    }

    @objc private func pickState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = ShepDogState(rawValue: raw) else { return }
        currentState = s
        overlay?.setState(s)
        refreshMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: onboarding

    private func showOnboarding() {
        if let w = onboardingWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = OnboardingView(model: permissions, onDone: { [weak self] in self?.onboardingWindow?.close() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Shep Setup"
        w.sharingType = ScreenPrivacy.sharingType   // a reopened Setup window follows the saved privacy choice too
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        onboardingWindow = w
        // Drop the window (and the doghouse page in its header) once it is closed; it is rebuilt when Setup is opened again.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onboardingWindow = nil }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
