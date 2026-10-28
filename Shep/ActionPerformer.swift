import AppKit
import ApplicationServices
import CoreGraphics
import ShepCore

/// Performs one proposed action on the window an AXSnapshot came from.
/// Accessibility first (AXPress / AXConfirm / AXPick, or AXValue for a text field with explicit text).
/// A synthetic click only ever arrives through `click`. Both entry points demand an `ApprovalToken`, which only
/// ActionRunner can make (after the approval callback said yes) and which works once, for one action.
/// No scripting-bridge automation anywhere: only AX calls and CGEvent.
final class ActionPerformer: ActionExecuting, ClickSceneReading, @unchecked Sendable {
    private let snapshot: AXSnapshot
    /// The window-server number of the window the screenshot (and so the proposals) came from.
    private let windowNumber: CGWindowID?
    private let beforeClick: @Sendable () async -> Void
    private let afterClick: @Sendable () async -> Void

    init(snapshot: AXSnapshot, windowNumber: CGWindowID?, beforeClick: @escaping @Sendable () async -> Void, afterClick: @escaping @Sendable () async -> Void) {
        self.snapshot = snapshot; self.windowNumber = windowNumber; self.beforeClick = beforeClick; self.afterClick = afterClick
    }

    // MARK: Accessibility

    func performAX(_ action: ProposedAction, token: ApprovalToken) async -> AXResult {
        // No token for exactly this action, or one already used: do nothing at all.
        guard token.consume(for: action) else { return .failed }
        if Task.isCancelled { return .failed }
        guard let el = snapshot.elements[action.control.pathID] else { return .failed }
        // Right before acting, read the element again: still enabled, never a secure field, same role, same name, same window.
        let live = AXReader.liveTarget(of: el, in: snapshot.window)
        if case .refuse(let why) = TargetRecheck.verify(listed: action.control, live: live) { return .targetChanged(why) }
        switch action.kind {
        case .axPress:
            return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success ? .performed : .failed
        case .axConfirm:
            return AXUIElementPerformAction(el, kAXConfirmAction as CFString) == .success ? .performed : .failed
        case .axPick:
            return AXUIElementPerformAction(el, kAXPickAction as CFString) == .success ? .performed : .failed
        case .setValue(let text):
            guard action.control.isTextInput else { return .failed }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return .failed }
            return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success ? .performed : .failed
        case .clickPoint:
            return .failed
        }
    }

    // MARK: what is under a click point

    /// Reads the element under the centre of the control's frame, for the approval card. The overlay is hidden for the read
    /// (it would answer the hit test itself) and shown again. nil unless the hit is an element of the approved window of the
    /// approved app that is still in front.
    func hitIdentity(for action: ProposedAction) async -> HitIdentity? {
        guard let frame = action.control.frame, frame.width > 0, frame.height > 0 else { return nil }
        let target = CGPoint(x: frame.midX, y: frame.midY)
        await beforeClick()
        let live = scene(at: target, for: action)
        await afterClick()
        guard live.frontPID == Int32(snapshot.pid), live.focusedWindowIsApproved, live.hitPID == Int32(snapshot.pid), live.hitInApprovedWindow else { return nil }
        return live.hit?.identity
    }

    // MARK: synthetic click

    func click(_ action: ProposedAction, token: ApprovalToken) async -> ClickResult {
        guard token.consume(for: action) else { return .skipped("There is no approval for that click, so I did nothing.") }
        if Task.isCancelled { return .skipped("Cancelled, so I did nothing.") }
        await beforeClick()   // returns only once the overlay is gone from the screen
        let result = await guardedClick(action)
        await afterClick()
        return result
    }

    /// Everything that can fail is checked before the first event is sent, and the last check (the window and the control
    /// under the pointer, `ClickGuard`) runs immediately before the mouse-down with nothing in between (no sleep, no await):
    /// what was approved is what gets clicked, or nothing is. Cancellation is checked at the same point; once the
    /// mouse-down is posted the mouse-up is always posted.
    private func guardedClick(_ action: ProposedAction) async -> ClickResult {
        guard case .clickPoint = action.kind else { return .skipped("Not a click.") }
        guard let frame = action.control.frame, frame.width > 0, frame.height > 0 else { return .skipped("I don't know where that control is.") }
        let target = CGPoint(x: frame.midX, y: frame.midY)

        // Create all three events first: if any is nil nothing happens and nothing is reported as clicked.
        let source = CGEventSource(stateID: .hidSystemState)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left) else {
            return .skipped("I couldn't create the mouse events, so I did nothing.")
        }

        // From here to the mouse-down there is no suspension point.
        if Task.isCancelled { return .skipped("Cancelled, so I did nothing.") }
        if let why = ClickGuard.check(window: approvedWindow, action: action, point: target, reader: self) {
            return .targetChanged(why + " I did nothing; ask me again to approve the new target.")
        }

        let saved = CGEvent(source: nil)?.location
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 40_000_000)   // returns at once if cancelled; the mouse-up below still goes out
        up.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 40_000_000)
        if let saved { CGWarpMouseCursorPosition(saved) }
        return .clicked
    }

    /// The window the snapshot (and the approval) described.
    private var approvedWindow: ApprovedWindow {
        ApprovedWindow(pid: Int32(snapshot.pid), number: windowNumber.map { Int($0) }, frame: snapshot.windowFrame, title: snapshot.windowTitle)
    }

    /// Reads the live scene for `ClickGuard`: the app in front, the very same window element with the same window-server
    /// number, frame and title, an Accessibility hit test that lands in the same app and window, and the element we expect
    /// there (the listed one, or for a control found on the screenshot the deepest listed element at that spot).
    ///
    /// Which apps this reads (live runs included; the approved pid is the bundle-verified target of the run): the focused window is
    /// asked of `snapshot.pid` only, the listed and expected elements come from the approved snapshot, and the window-server lookup is
    /// keyed by that pid. The one read that can land in another app is the system-wide hit test, because another app's window may cover
    /// the point. For a hit in ANOTHER app this reads exactly one thing of that foreign element: its owner pid (`AXUIElementGetPid`),
    /// which is how the owner is known at all. Its window, role, title, actions, frame and identity are inspected only when
    /// `LiveBinding.mayReadHit` says the pid is the approved app's. Otherwise `hit` stays nil and `ClickGuard` refuses ("Something else
    /// covers that spot"). A hit test that never touched a foreign element would need a different strategy (an application-scoped
    /// lookup per approved window); this one does not claim that.
    func scene(at target: CGPoint, for action: ProposedAction) -> LiveClickScene {
        var scene = LiveClickScene()
        if let front = NSWorkspace.shared.frontmostApplication { scene.frontPID = Int32(front.processIdentifier) }
        guard let window = AXReader.focusedWindowElement(pid: snapshot.pid) else { return scene }
        scene.focusedWindowIsApproved = CFEqual(window, snapshot.window)
        let liveFrame = AXReader.frameOf(window)
        scene.windowFrame = liveFrame
        scene.windowTitle = AXReader.titleOf(window)
        if let liveFrame, let found = ScreenCapture.window(pid: snapshot.pid, nearFrame: liveFrame) { scene.windowNumber = Int(found.0) }

        var hitElement: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(target.x), Float(target.y), &hitElement)
        var hitPID: pid_t = 0
        guard err == .success, let hit = hitElement, AXUIElementGetPid(hit, &hitPID) == .success else { return scene }
        scene.hitPID = Int32(hitPID)
        guard LiveBinding.mayReadHit(hitPID: Int32(hitPID), approvedPID: Int32(snapshot.pid)) else { return scene }   // another app's element is not read further: only its pid was read
        if let hitWindow = AXReader.windowContaining(hit) { scene.hitInApprovedWindow = CFEqual(hitWindow, snapshot.window) }

        let expectedPair = expectedTarget(action, at: target)
        if let expectedPair {
            scene.expected = LiveExpectedElement(control: expectedPair.control,
                                                 live: AXReader.liveTarget(of: expectedPair.element, in: snapshot.window),
                                                 frame: AXReader.frameOf(expectedPair.element))
        }
        let node = LiveAXNode(element: hit)
        var isExpected = false
        var isDescendant = false
        var isAncestor = false
        if let expectedPair {
            isExpected = CFEqual(hit, expectedPair.element)
            if !isExpected {
                isDescendant = Self.isAncestor(expectedPair.element, of: hit)
                isAncestor = Self.isAncestor(hit, of: expectedPair.element)
            }
        }
        scene.hit = LiveHitElement(role: node.role, actions: node.actions, frame: node.frame, isExpected: isExpected,
                                   isDescendantOfExpected: isDescendant, isAncestorOfExpected: isAncestor,
                                   identity: AXReader.identity(of: hit))
        return scene
    }

    /// The element the click should land on: the approved control's own element, or (for a control found on the screenshot)
    /// the deepest listed element whose frame contains the point. nil when the snapshot has nothing there.
    private func expectedTarget(_ action: ProposedAction, at point: CGPoint) -> (control: Control, element: AXUIElement)? {
        if !action.control.fromVision, let el = snapshot.elements[action.control.pathID] { return (action.control, el) }
        var best: (control: Control, element: AXUIElement, depth: Int, area: CGFloat)?
        for c in snapshot.controls {
            guard let f = c.frame, f.contains(point), let el = snapshot.elements[c.pathID] else { continue }
            let depth = c.pathID.split(separator: "/").count
            let area = f.width * f.height
            if let b = best, depth < b.depth || (depth == b.depth && area >= b.area) { continue }
            best = (c, el, depth, area)
        }
        guard let b = best else { return nil }
        return (b.control, b.element)
    }

    /// True when `candidate` is one of the (at most 20) ancestors of `element`.
    private static func isAncestor(_ candidate: AXUIElement, of element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<20 {
            guard let up = AXReader.parent(of: current) else { return false }
            if CFEqual(up, candidate) { return true }
            current = up
        }
        return false
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        ClickGuard.sameFrame(a, b, tolerance: tolerance)
    }
}
