import AppKit
import Carbon.HIToolbox
import ShepCore

// Written for Shep.
// The ways to call Shep besides a click: a global shortcut (Carbon, no permission needed), a held modifier key
// (push-to-talk), and Escape while Shep is out. The rules live in ShepCore (HotKeySpec, PushToTalkDetector).

/// Carbon's hot-key callback: a C function pointer, so no captures. The centre travels through `refcon`.
private func shepHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let refcon else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { center.fire() } }
    return noErr
}

/// One global shortcut through RegisterEventHotKey. Needs no Accessibility or Input Monitoring permission.
@MainActor
final class HotKeyCenter {
    var onPress: (() -> Void)?
    private(set) var registered: HotKeySpec?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers `spec` (replacing the earlier one). False when the spec has no modifier or another app already owns the shortcut.
    @discardableResult
    func register(_ spec: HotKeySpec) -> Bool {
        unregister()
        guard spec.isValid, installHandler() else { return false }
        var rawRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x53484550), id: 1)   // 'SHEP'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &rawRef)
        guard status == noErr, let ref = rawRef else { return false }
        hotKeyRef = ref
        registered = spec
        return true
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        registered = nil
    }

    private func installHandler() -> Bool {
        if handlerRef != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var rawHandler: EventHandlerRef?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), shepHotKeyCallback, 1, &type, refcon, &rawHandler)
        guard status == noErr, let handler = rawHandler else { return false }
        handlerRef = handler
        return true
    }

    fileprivate func fire() { onPress?() }
}

/// Hold a modifier key to talk: NSEvent global + local flagsChanged monitors (global ones need Accessibility, which Shep
/// already asks for). The hold rule (0.25 s, no other key meanwhile) is `PushToTalkDetector`'s.
@MainActor
final class PushToTalkMonitor {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?
    var onCancelled: (() -> Void)?

    private var detector: PushToTalkDetector
    private var monitors: [Any] = []
    private var tickWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(key: PushToTalkKey = .default) { detector = PushToTalkDetector(key: key) }

    var key: PushToTalkKey { detector.key }
    var isListening: Bool { detector.isListening }

    func setKey(_ key: PushToTalkKey) {
        guard key != detector.key else { return }
        if detector.isListening { onCancelled?() }
        detector = PushToTalkDetector(key: key)
    }

    func start() {
        guard monitors.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupted() }
            })
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            let code = event.keyCode, raw = event.modifierFlags.rawValue
            Task { @MainActor in self?.flags(code, raw) }
        }) { monitors.append(g) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] _ in
            Task { @MainActor in self?.keyDown() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            self?.flags(event.keyCode, event.modifierFlags.rawValue)
            return event
        }) { monitors.append(l) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            self?.keyDown()
            return event
        }) { monitors.append(l) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        tickWork?.cancel()
        tickWork = nil
        if detector.isListening { onCancelled?() }
        detector.reset()
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func flags(_ keyCode: UInt16, _ raw: UInt) {
        let out = detector.flagsChanged(keyCode: keyCode, rawFlags: raw, at: now)
        dispatch(out)
        scheduleTick()
    }

    /// The input stream was interrupted (sleep, the session switched away): a listening call is thrown away.
    private func interrupted() {
        dispatch(detector.interrupted())
        scheduleTick()
    }

    private func keyDown() {
        // A key-up that never arrived: the real modifier state says the talk key is not down.
        dispatch(detector.reconcile(rawFlags: NSEvent.modifierFlags.rawValue))
        dispatch(detector.keyDown(at: now))
    }

    private func scheduleTick() {
        tickWork?.cancel()
        tickWork = nil
        guard let due = detector.nextTick else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dispatch(self.detector.reconcile(rawFlags: NSEvent.modifierFlags.rawValue))
                self.dispatch(self.detector.tick(at: self.now))
                self.scheduleTick()   // while listening the next tick is the listening limit
            }
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now) + 0.01, execute: work)
    }

    private func dispatch(_ output: PushToTalkDetector.Output?) {
        switch output {
        case .began: onBegan?()
        case .ended: onEnded?()
        case .cancelled: onCancelled?()
        case nil: break
        }
    }
}

/// Escape while Shep is out: a global monitor (Accessibility) and a local one (Shep's own panel is key). The key still reaches
/// the app in front; Shep only goes home.
@MainActor
final class EscapeMonitor {
    var onEscape: (() -> Void)?
    private var monitors: [Any] = []
    private static let escapeKeyCode: UInt16 = 53

    func start() {
        guard monitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            Task { @MainActor in self?.onEscape?() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == Self.escapeKeyCode { self?.onEscape?() }
            return event
        }) { monitors.append(l) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }
}
