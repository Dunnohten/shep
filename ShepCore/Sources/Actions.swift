import CoreGraphics
import Foundation

public enum ActionKind: Equatable, Sendable {
    case axPress
    case axConfirm
    case axPick
    /// Set a text field's value to exactly this text (never invented: the caller supplies it).
    case setValue(String)
    /// Synthetic mouse click at the centre of the control. Only ever after an explicit approval.
    case clickPoint

    public var verb: String {
        switch self {
        case .axPress: return "Press"
        case .axConfirm: return "Confirm"
        case .axPick: return "Pick"
        case .setValue: return "Type into"
        case .clickPoint: return "Click"
        }
    }
}

/// One thing Shep proposes to do. It is only a description: performing it goes through ApprovalPolicy and ActionRunner.
public struct ProposedAction: Equatable, Sendable {
    public var control: Control
    public var kind: ActionKind
    public var bundleID: String
    /// Who was under the click point when the approval card was built. Part of the action, so an approval token (and the
    /// guard that checks the live element against it) is bound to exactly that element. nil for actions that are not clicks.
    public var hitIdentity: HitIdentity?
    public init(control: Control, kind: ActionKind, bundleID: String, hitIdentity: HitIdentity? = nil) {
        self.control = control; self.kind = kind; self.bundleID = bundleID; self.hitIdentity = hitIdentity
    }

    /// The same action as a mouse click (keeping the identity it was approved with).
    func asClick() -> ProposedAction {
        ProposedAction(control: control, kind: .clickPoint, bundleID: bundleID, hitIdentity: hitIdentity)
    }

    /// The sentence on the approval card.
    public var summary: String {
        var s = "\(kind.verb) the \(control.kind) \"\(control.label)\""
        if case .setValue(let t) = kind { s += " with \"\(t.prefix(60))\"" }
        if control.labelSource == .tooltip { s += " (named by its tooltip)" }
        if control.fromVision { s += " (found on screen)" }
        return s
    }
}

public enum ApprovalRequirement: Equatable, Sendable {
    /// Never performed, not even with approval.
    case refused(String)
    /// The user must say yes first. The reason is shown on the card.
    case required(String)
}

/// Decides when an action needs the user's yes. There is deliberately no "auto-approve" outcome at all: every action that
/// is not refused needs a yes, whether it is a click, typing, a vision-found control, a command-running app or a plain
/// Accessibility press.
public enum ApprovalPolicy {
    public static func requirement(for action: ProposedAction, afterAXFailure: Bool = false) -> ApprovalRequirement {
        if let why = ControlPolicy.refusal(action.control, bundleID: action.bundleID) { return .refused(why) }
        if !action.control.enabled { return .refused("\"\(action.control.label)\" is disabled.") }
        if case .setValue = action.kind {
            if !action.control.isTextInput { return .refused("That control isn't a text field.") }
            if action.control.fromVision { return .refused("Shep can't type into a control it only found on the screenshot.") }
        }
        if case .clickPoint = action.kind { return .required("This uses the mouse pointer: after you approve, Shep clicks once at that spot.") }
        if afterAXFailure { return .required("The control didn't respond to Accessibility, so the only option left is a mouse click.") }
        if action.control.fromVision { return .required("Found on the screenshot, not in the app's own controls, so it can only be clicked with the mouse.") }
        if case .setValue = action.kind { return .required("Typing changes what's in the field.") }
        if ControlPolicy.isCommandRunner(action.bundleID) { return .required("This app can run commands, so Shep asks every time.") }
        return .required("Shep asks before every action.")
    }

    /// The action that proposing a control starts with: AX press when the app offers one, otherwise a click (which asks).
    public static func defaultAction(for control: Control, bundleID: String) -> ProposedAction {
        let kind: ActionKind
        if control.fromVision { kind = .clickPoint }
        else if control.actions.contains("AXPress") { kind = .axPress }
        else if control.actions.contains("AXConfirm") { kind = .axConfirm }
        else if control.actions.contains("AXPick") { kind = .axPick }
        else { kind = .clickPoint }
        return ProposedAction(control: control, kind: kind, bundleID: bundleID)
    }
}

public struct ApprovalRequest: Equatable, Sendable {
    public var action: ProposedAction
    public var reason: String

    /// The text of the approval card: the sentence as a question, then the reason.
    public var cardText: String {
        var text = "\(action.summary)?\n\(reason)"
        if let id = action.hitIdentity { text += " (what is under that spot: \(id.cardText))" }
        return text
    }
}

public enum ActionOutcome: Equatable, Sendable {
    case done(String)
    case refused(String)
    case declined
    case failed(String)
    /// The target changed between the approval and the action. Nothing was done; ask again before trying anything.
    case needsFreshApproval(String)
    /// The task was cancelled before the action (or the next step) started. Nothing was done.
    case cancelled
}

/// Proof that the user said yes to exactly one action. Only `ActionRunner` can make one (the initialiser is internal to
/// ShepCore), after its approval callback answered yes, so an executor that demands a token for every Accessibility call
/// and every synthetic event cannot be reached without an approval. Single use: the first `consume` for the same action
/// wins; a replay, or a different action, fails.
public final class ApprovalToken: @unchecked Sendable {
    public let action: ProposedAction
    private let lock = NSLock()
    private var used = false

    init(action: ProposedAction) { self.action = action }

    /// True once, for the action this token was issued for.
    public func consume(for other: ProposedAction) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used, other == action else { return false }
        used = true
        return true
    }
}

/// What the app layer does for real (Accessibility calls, synthetic events). Faked in tests.
/// Every entry point takes the approval token for the action and must call `token.consume(for: action)` before it
/// touches anything; without a successful consume it does nothing.
public protocol ActionExecuting: Sendable {
    /// AXPress / AXConfirm / AXPick / AXSetValue. `.failed` when the element rejected it, is gone or the token does not
    /// match; `.targetChanged` when the live element no longer matches what the user approved (nothing was done, and no
    /// click may follow).
    func performAX(_ action: ProposedAction, token: ApprovalToken) async -> AXResult
    /// Synthetic click. The implementation must check the window has not moved and the point is not covered, and
    /// returns a reason when it did nothing.
    func click(_ action: ProposedAction, token: ApprovalToken) async -> ClickResult
    /// Who is under the click point of `action` right now (read before the approval card is built), or nil when that cannot
    /// be told: no element, another app's window, a password field, a disabled control. Reads only; it presses nothing.
    func hitIdentity(for action: ProposedAction) async -> HitIdentity?
}

extension ActionExecuting {
    /// An executor that cannot name what is under a spot never gets a click approved.
    public func hitIdentity(for action: ProposedAction) async -> HitIdentity? { nil }
}

public enum AXResult: Equatable, Sendable {
    case performed
    case failed
    case targetChanged(String)
}

public enum ClickResult: Equatable, Sendable {
    case clicked
    case skipped(String)
    /// The window or the control under the pointer is not what the user approved. Nothing was clicked; the old
    /// approval is void and the user has to be asked again about the new target.
    case targetChanged(String)
}

public typealias ApprovalCallback = @Sendable (ApprovalRequest) async -> Bool

/// Runs one proposed action: AX first; a click only after `approve` said yes. Nothing else can reach the executor's click.
public struct ActionRunner: Sendable {
    public let executor: any ActionExecuting
    public let approve: ApprovalCallback
    public init(executor: any ActionExecuting, approve: @escaping ApprovalCallback) {
        self.executor = executor; self.approve = approve
    }

    /// Every action that is not refused asks first; the executor only ever sees an `ApprovalToken` made after a yes.
    /// Cancellation is checked before the question, after the answer and before each executor call.
    public func run(_ proposed: ProposedAction) async -> ActionOutcome {
        if Task.isCancelled { return .cancelled }
        var action = proposed
        let willClick: Bool
        if case .clickPoint = action.kind { willClick = true } else { willClick = action.control.fromVision }
        let requirement = ApprovalPolicy.requirement(for: action)
        if case .refused(let why) = requirement { return .refused(why) }
        if willClick {
            // A click is bound to whatever is under the spot right now; nothing nameable there means no card and no event.
            switch await bindIdentity(action) {
            case .refused(let why): return .refused(why)
            case .bound(let bound): action = bound
            }
            if Task.isCancelled { return .cancelled }
        }
        if case .required(let why) = requirement {
            guard await approve(ApprovalRequest(action: action, reason: why)) else { return .declined }
        }
        if Task.isCancelled { return .cancelled }
        if willClick { return await clickWithApproval(action.asClick(), alreadyApproved: true) }
        switch await executor.performAX(action, token: ApprovalToken(action: action)) {
        case .performed: return .done(action.summary)
        case .targetChanged(let why): return .needsFreshApproval(why)
        case .failed: break
        }
        if Task.isCancelled { return .cancelled }
        if case .setValue = action.kind { return .failed("The field didn't accept the text.") }
        // AX failed: the click needs its own approval.
        return await clickWithApproval(action.asClick(), alreadyApproved: false, afterAXFailure: true)
    }

    private enum Binding { case bound(ProposedAction), refused(String) }

    /// Attaches the identity of the element under the click point. An identity the action already carries is checked, not
    /// replaced; one the executor reports must be usable and must not be something ControlPolicy refuses.
    private func bindIdentity(_ action: ProposedAction) async -> Binding {
        var bound = action
        if bound.hitIdentity == nil { bound.hitIdentity = await executor.hitIdentity(for: action) }
        guard let id = bound.hitIdentity, id.isUsable else { return .refused(ClickGuard.unidentified) }
        if let why = ControlPolicy.refusal(id.asControl(window: action.control.window), bundleID: action.bundleID) { return .refused(why) }
        return .bound(bound)
    }

    private func clickWithApproval(_ action: ProposedAction, alreadyApproved: Bool, afterAXFailure: Bool = false) async -> ActionOutcome {
        var action = action
        if !alreadyApproved {
            let why: String
            switch ApprovalPolicy.requirement(for: action, afterAXFailure: afterAXFailure) {
            case .refused(let r): return .refused(r)
            case .required(let r): why = r
            }
            switch await bindIdentity(action) {
            case .refused(let r): return .refused(r)
            case .bound(let bound): action = bound
            }
            if Task.isCancelled { return .cancelled }
            guard await approve(ApprovalRequest(action: action, reason: why)) else { return .declined }
            if Task.isCancelled { return .cancelled }
        }
        switch await executor.click(action, token: ApprovalToken(action: action)) {
        case .clicked: return .done(action.summary)
        case .skipped(let r): return Task.isCancelled ? .cancelled : .failed(r)
        case .targetChanged(let r): return .needsFreshApproval(r)
        }
    }
}

extension ProposedAction {
    /// The name of the approval dialog for assistive technology: "Shep wants to press Save in TextEdit".
    public func dialogTitle(appName: String) -> String {
        let verb: String
        switch kind {
        case .axPress: verb = "press"
        case .axConfirm: verb = "confirm"
        case .axPick: verb = "pick"
        case .setValue: verb = "type into"
        case .clickPoint: verb = "click"
        }
        let name = control.label.isEmpty ? "a \(control.kind)" : control.label
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Shep wants to \(verb) \(name)" + (app.isEmpty ? "" : " in \(app)")
    }
}
