import CoreGraphics
import Foundation

// Written for Shep.

/// The window the user approved an action in: who owns it, which on-screen window it was, where it was and what it was called.
public struct ApprovedWindow: Equatable, Sendable {
    public var pid: Int32
    /// The window-server number of the window when the screenshot was taken. Nil means identity is unknown: every check fails.
    public var number: Int?
    public var frame: CGRect
    public var title: String

    public init(pid: Int32, number: Int?, frame: CGRect, title: String) {
        self.pid = pid; self.number = number; self.frame = frame; self.title = title
    }
}

/// The control a click should land on, read again from the live app.
public struct LiveExpectedElement: Equatable, Sendable {
    /// The control from the snapshot that this element stands for (the approved one, or for a control found on the
    /// screenshot the deepest listed control at that spot).
    public var control: Control
    public var live: LiveTarget
    public var frame: CGRect?

    public init(control: Control, live: LiveTarget, frame: CGRect?) {
        self.control = control; self.live = live; self.frame = frame
    }
}

/// The element an Accessibility hit test answers with at the click point, as the guard needs to judge it.
public struct LiveHitElement: Equatable, Sendable {
    public var role: String
    public var actions: [String]
    /// Its frame now; nil when it cannot be read.
    public var frame: CGRect?
    /// It is the very element of the expected control.
    public var isExpected: Bool
    public var isDescendantOfExpected: Bool
    public var isAncestorOfExpected: Bool
    /// Who the element is (role, label, state); nil when it could not be read.
    public var identity: HitIdentity?

    public init(role: String, actions: [String] = [], frame: CGRect? = nil, isExpected: Bool = false,
                isDescendantOfExpected: Bool = false, isAncestorOfExpected: Bool = false, identity: HitIdentity? = nil) {
        self.role = role; self.actions = actions; self.frame = frame; self.isExpected = isExpected
        self.isDescendantOfExpected = isDescendantOfExpected; self.isAncestorOfExpected = isAncestorOfExpected
        self.identity = identity
    }
}

/// Everything read from the live app for one check. Plain values, so the decision is testable with a fake Accessibility layer.
public struct LiveClickScene: Equatable, Sendable {
    public var frontPID: Int32?
    /// The app's focused window is the very window element (same AX element) the snapshot was read from.
    public var focusedWindowIsApproved: Bool
    public var windowNumber: Int?
    public var windowFrame: CGRect?
    public var windowTitle: String
    /// Owner of the element an Accessibility hit test finds at the click point.
    public var hitPID: Int32?
    public var hitInApprovedWindow: Bool
    /// Nil when the snapshot lists nothing at the point.
    public var expected: LiveExpectedElement?
    /// The element the hit test found. Nil means it could not be read, and the click is refused.
    public var hit: LiveHitElement?

    public init(frontPID: Int32? = nil, focusedWindowIsApproved: Bool = false, windowNumber: Int? = nil, windowFrame: CGRect? = nil,
                windowTitle: String = "", hitPID: Int32? = nil, hitInApprovedWindow: Bool = false, expected: LiveExpectedElement? = nil,
                hit: LiveHitElement? = nil) {
        self.frontPID = frontPID; self.focusedWindowIsApproved = focusedWindowIsApproved; self.windowNumber = windowNumber
        self.windowFrame = windowFrame; self.windowTitle = windowTitle; self.hitPID = hitPID
        self.hitInApprovedWindow = hitInApprovedWindow; self.expected = expected; self.hit = hit
    }
}

/// Reads the live scene. The app implements it with real Accessibility calls; tests with a fake.
/// Deliberately synchronous: a check that cannot suspend cannot be overtaken between the read and the event.
public protocol ClickSceneReading {
    func scene(at point: CGPoint, for action: ProposedAction) -> LiveClickScene
}

/// The last check before a synthetic click: is the window, and the control under the pointer, what the user approved?
/// Any doubt refuses, and a refusal means no event is posted.
public enum ClickGuard {
    public static let frameTolerance: CGFloat = 2

    public static func sameFrame(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = frameTolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Reads the scene and decides in one synchronous call. nil means the click may be posted right now, with no await first.
    public static func check(window: ApprovedWindow, action: ProposedAction, point: CGPoint, reader: ClickSceneReading) -> String? {
        verify(window: window, action: action, point: point, scene: reader.scene(at: point, for: action))
    }

    public static func verify(window: ApprovedWindow, action: ProposedAction, point: CGPoint, scene: LiveClickScene) -> String? {
        guard scene.frontPID == window.pid else { return "The app is no longer in front." }
        guard scene.focusedWindowIsApproved else { return "A different window is in front now." }
        guard let approvedNumber = window.number, scene.windowNumber == approvedNumber else {
            return "I can't tell that it is the same window any more."
        }
        guard let frame = scene.windowFrame, sameFrame(frame, window.frame) else { return "The window moved or changed size." }
        if TargetRecheck.normalise(scene.windowTitle).lowercased() != TargetRecheck.normalise(window.title).lowercased() {
            return "The window's title changed."
        }
        guard window.frame.contains(point) else { return "That spot is outside the window." }
        guard scene.hitPID == window.pid else { return "Something else covers that spot." }
        guard scene.hitInApprovedWindow else { return "Another window covers that spot." }

        guard let expected = scene.expected else {
            // Nothing listed at the spot. A listed control must always be found again; a control found on the screenshot
            // is clicked only when the live hit element is a concrete, matching, actionable element.
            guard action.control.fromVision else { return "I can't find that control any more." }
            if let why = visionHitRefusal(hit: scene.hit, box: action.control.frame, point: point) { return why }
            return identityBindingRefusal(action: action, hit: scene.hit)
        }
        if !action.control.fromVision, expected.control.pathID != action.control.pathID {
            return "Something different is under that spot now."
        }
        if let listed = expected.control.frame {
            guard let now = expected.frame, sameFrame(now, listed) else { return "The control moved or changed size." }
            guard now.contains(point) else { return "The control is no longer under that spot." }
        }
        if case .refuse(let why) = TargetRecheck.verify(listed: expected.control, live: expected.live) { return why }
        guard let hit = scene.hit else { return unidentified }
        if let why = identityRefusal(hit: hit, expected: expected, point: point) { return why }
        if action.control.fromVision {
            // A listed element stands in for the box: it must still look like a control of that size, not a broad container.
            if let why = visionShapeRefusal(role: expected.control.role, frame: expected.frame ?? expected.control.frame,
                                            box: action.control.frame, point: point) { return why }
        }
        return identityBindingRefusal(action: action, hit: hit)
    }

    /// The element under the point right now must be the one that was under it when the card was built: same role, subrole,
    /// label, label source, enabled and secure flags, and (within tolerance) frame. A click on a control found on the
    /// screenshot has nothing else to go on, so it needs an approved identity; an action that carries one is always compared.
    /// ControlPolicy judges the live label and role again, so a swapped-in "Delete account" is refused even if it was approved.
    static func identityBindingRefusal(action: ProposedAction, hit: LiveHitElement?) -> String? {
        guard action.control.fromVision || action.hitIdentity != nil else { return nil }
        guard let approved = action.hitIdentity, approved.isUsable else { return unidentified }
        guard let live = hit?.identity, live.isUsable else { return unidentified }
        guard approved.matches(live) else { return different }
        if let why = ControlPolicy.refusal(live.asControl(window: action.control.window), bundleID: action.bundleID) { return why }
        return nil
    }

    /// The one refusal text for a spot nobody can name; the implementation and the tests both use it.
    public static let cannotIdentifyMessage = "I can't identify what is under that spot, so I did nothing. Ask me again and I'll take a fresh look."
    public static let unidentified = cannotIdentifyMessage
    static let different = "Something different is under that spot now."
    /// A vision box may be answered by an element up to this many times its area.
    static let maxVisionAreaRatio: CGFloat = 9

    static func isActionable(role: String, actions: [String]) -> Bool {
        ControlFilter.actionableRoles.contains(role) || actions.contains(where: { ControlFilter.pressActions.contains($0) })
    }

    /// The hit element must be the approved control's own element, or a non-actionable descendant of it (an image or label
    /// inside the button). An ancestor, a container, a stranger or another actionable descendant never is.
    static func identityRefusal(hit: LiveHitElement, expected: LiveExpectedElement, point: CGPoint) -> String? {
        guard hit.isExpected || hit.isDescendantOfExpected else { return different }
        guard let hitFrame = hit.frame, hitFrame.minX.isFinite, hitFrame.minY.isFinite, hitFrame.width.isFinite, hitFrame.height.isFinite,
              hitFrame.contains(point) else { return unidentified }
        if hit.isExpected {
            if let listed = expected.control.frame, !sameFrame(hitFrame, listed) { return "The control moved or changed size." }
            return nil
        }
        if isActionable(role: hit.role, actions: hit.actions) { return different }
        if let live = expected.frame, !live.intersects(hitFrame) { return different }
        return nil
    }

    /// Nothing is listed at the spot: only a small, actionable, non-container element that contains the point and matches
    /// the approved box may receive the click.
    static func visionHitRefusal(hit: LiveHitElement?, box: CGRect?, point: CGPoint) -> String? {
        guard let hit = hit, let hitFrame = hit.frame, let box = box else { return unidentified }
        guard !RoleResolver.containerRoles.contains(hit.role), isActionable(role: hit.role, actions: hit.actions) else { return unidentified }
        guard hitFrame.contains(point) else { return unidentified }
        return visionShapeRefusal(role: hit.role, frame: hitFrame, box: box, point: point)
    }

    /// Size and overlap of an element standing in for a vision box.
    static func visionShapeRefusal(role: String, frame: CGRect?, box: CGRect?, point: CGPoint) -> String? {
        guard let f = frame, let box = box, !RoleResolver.containerRoles.contains(role) else { return unidentified }
        let finite = f.minX.isFinite && f.minY.isFinite && f.width.isFinite && f.height.isFinite
            && box.minX.isFinite && box.minY.isFinite && box.width.isFinite && box.height.isFinite
        guard finite, f.width > 0, f.height > 0, box.width > 0, box.height > 0 else { return unidentified }
        guard f.width * f.height <= maxVisionAreaRatio * box.width * box.height else { return unidentified }
        let centre = CGPoint(x: box.midX, y: box.midY)
        guard VisionRepair.iou(f, box) >= RoleResolver.axOverlapIoU || f.contains(centre) else { return unidentified }
        return nil
    }
}
