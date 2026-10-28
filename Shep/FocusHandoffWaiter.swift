import AppKit
import ShepCore

// Written for Shep.

/// Carries out one `FocusHandoff` (ShepCore): asks the previous app to come to the front, then feeds the handoff what it sees
/// (activation notes and a 50 ms poll of the front app) until it decides. `perform` gets every effect except `activate`.
@MainActor
final class FocusHandoffWaiter {
    private var handoff: FocusHandoff
    private let app: NSRunningApplication
    private let perform: (FocusHandoffEffect) -> Void
    private var startedAt: TimeInterval = 0
    private var token: NSObjectProtocol?
    private var timer: Timer?

    /// The handoff has decided (and its call has been made).
    var isDone: Bool { handoff.outcome != nil }

    init(app: NSRunningApplication, perform: @escaping (FocusHandoffEffect) -> Void) {
        self.app = app
        self.handoff = FocusHandoff(pid: app.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier)
        self.perform = perform
    }

    func start() {
        startedAt = ProcessInfo.processInfo.systemUptime
        // An activation note only says "look now": the note may be stale by the time it is handled, so the front app is re-read.
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.look(NSWorkspace.shared.frontmostApplication?.processIdentifier) }
        }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look(NSWorkspace.shared.frontmostApplication?.processIdentifier) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        run(handoff.start())
    }

    private func look(_ frontmostPID: pid_t?) {
        run(handoff.observe(frontmostPID: frontmostPID, elapsed: ProcessInfo.processInfo.systemUptime - startedAt))
    }

    private func run(_ effects: [FocusHandoffEffect]) {
        if isDone { stopWatching() }
        for effect in effects {
            if case .activate = effect { app.activate(options: []) } else { perform(effect) }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }
}
