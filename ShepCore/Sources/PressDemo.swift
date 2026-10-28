import Foundation

/// Which control `Shep --press-demo-once --match <text>` would press.
public enum PressDemoSelection: Equatable, Sendable {
    case one(Control)
    case none
    /// More than one enabled control matches: nothing is pressed.
    case ambiguous([Control])
    /// Every match is disabled.
    case disabledOnly([Control])
}

/// The press demo's pure logic. It never performs anything itself: the press goes through `ActionRunner`, so it needs the
/// same approval as every other action. There is no auto-approve here: the only "yes" is a flag an operator typed on the
/// command line for this one control, handed to the runner as its approval callback's answer.
public enum PressDemo {
    /// Controls whose label, title, description or tooltip contains `match` (case-insensitive). Secure fields never match.
    public static func matches(_ controls: [Control], match: String) -> [Control] {
        let needle = match.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return controls.filter { c in
            if c.isSecure { return false }
            return [c.label, c.title, c.description, c.help].contains { $0.lowercased().contains(needle) }
        }
    }

    public static func select(_ controls: [Control], match: String) -> PressDemoSelection {
        let found = matches(controls, match: match)
        let enabled = found.filter { $0.enabled }
        if enabled.count == 1 { return .one(enabled[0]) }
        if enabled.count > 1 { return .ambiguous(enabled) }
        if !found.isEmpty { return .disabledOnly(found) }
        return .none
    }

    /// Why nothing will be pressed, or nil for a single usable match.
    public static func refusal(_ selection: PressDemoSelection, match: String) -> String? {
        switch selection {
        case .one: return nil
        case .none: return "no control matches \"\(match)\""
        case .ambiguous(let list): return "\(list.count) controls match \"\(match)\"; use a more exact match"
        case .disabledOnly: return "the control matching \"\(match)\" is disabled"
        }
    }

    /// The proposal for a control, exactly as the app makes it.
    public static func proposal(for control: Control, bundleID: String) -> ProposedAction {
        ApprovalPolicy.defaultAction(for: control, bundleID: bundleID)
    }

    /// What the approval card says (summary as a question, then the reason), or the refusal when policy refuses.
    public static func preview(_ action: ProposedAction) -> String {
        switch ApprovalPolicy.requirement(for: action) {
        case .refused(let why): return "refused: \(why)"
        case .required(let why): return ApprovalRequest(action: action, reason: why).cardText
        }
    }

    /// Answers the runner's approval question once. With no flag it says no; with the flag it says yes to the first question
    /// only, so a click fallback after a failed press is declined.
    final class Approval: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private let flag: Bool
        private let log: @Sendable (String) -> Void
        init(flag: Bool, log: @escaping @Sendable (String) -> Void) { self.flag = flag; self.log = log }

        func answer(_ request: ApprovalRequest) -> Bool {
            lock.lock(); asked += 1; let n = asked; lock.unlock()
            guard flag else { log("declined: no --approve given"); return false }
            guard n == 1 else { log("declined: a second approval was asked (only the one press was approved)"); return false }
            log("approved by explicit --approve flag")
            return true
        }
    }

    /// Proposes AXPress for `control` and runs it through `ActionRunner`. Only an AXPress is ever performed.
    public static func run(control: Control, bundleID: String, approveFlag: Bool, executor: any ActionExecuting,
                           log: @escaping @Sendable (String) -> Void) async -> ActionOutcome {
        let action = proposal(for: control, bundleID: bundleID)
        guard action.kind == .axPress else { return .refused("that control offers no AXPress, and the demo only presses") }
        let approval = Approval(flag: approveFlag, log: log)
        let runner = ActionRunner(executor: executor, approve: { request in approval.answer(request) })
        return await runner.run(action)
    }

    public static func changed(before: String?, after: String?) -> Bool { before != after }
}
