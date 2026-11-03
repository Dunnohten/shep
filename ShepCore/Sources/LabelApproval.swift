import CoreGraphics
import Foundation

// Written for Shep.
// The approval gate for label repair. The overlay store accepts only an `ApprovedLabels` (or `ApprovedClear`), and the only place in
// the code that can build one is this file, from the answer to a card. Proposals alone, a rejected card, a dismissed card: no token.

/// One label the model proposed, with what the card shows about it.
public struct LabelProposal: Equatable, Sendable {
    public var id: Int
    public var fingerprint: String
    public var role: String
    public var kind: String
    /// Nearby text, or a place in the window ("the top left").
    public var context: String
    public var label: String
    public var confidence: Double
    /// What the stored label is checked against when it is shown again.
    public var anchor: LabelAnchor
    public init(id: Int, fingerprint: String, role: String, kind: String, context: String, label: String, confidence: Double,
                anchor: LabelAnchor = .empty) {
        self.id = id; self.fingerprint = fingerprint; self.role = role; self.kind = kind; self.context = context
        self.label = label; self.confidence = confidence; self.anchor = anchor
    }
}

public struct ApprovedLabel: Equatable, Sendable {
    public let fingerprint: String
    public let label: String
    public let role: String
    public let edited: Bool
    public let anchor: LabelAnchor
}

/// What the person approved. Cannot be built outside LabelApproval.swift (the initializer is file-private; a test checks the sources).
public struct ApprovedLabels: Equatable, Sendable {
    public let bundleID: String
    public let items: [ApprovedLabel]
    fileprivate init(bundleID: String, items: [ApprovedLabel]) { self.bundleID = bundleID; self.items = items }
}

/// The person's yes to "forget every label Shep added in this app".
public struct ApprovedClear: Equatable, Sendable {
    public let bundleID: String
    fileprivate init(bundleID: String) { self.bundleID = bundleID }
}

public enum LabelCardAnswer: Equatable, Sendable {
    case acceptAll, cancel
}

public enum ClearAnswer: Equatable, Sendable {
    case confirm, keep
}

public enum LabelApproval {
    /// The approval, or nil. Only "Accept all" approves; anything else (cancel, Escape, no answer) approves nothing. Rejected items are
    /// never part of it; edited items carry the edited text.
    public static func resolve(_ review: LabelReview, answer: LabelCardAnswer?) -> ApprovedLabels? {
        guard answer == .acceptAll else { return nil }
        // A label that cannot be told apart from another control of its role (no identifier, no nearby text, no help) is never stored.
        let items = review.activeProposals.filter { p in p.anchor.hasStableIdentity }.map { p in
            ApprovedLabel(fingerprint: p.fingerprint, label: p.label, role: p.role, edited: review.isEdited(p.id), anchor: p.anchor)
        }
        guard !items.isEmpty, !review.bundleID.isEmpty else { return nil }
        return ApprovedLabels(bundleID: review.bundleID, items: items)
    }

    public static func confirmClear(bundleID: String, answer: ClearAnswer?) -> ApprovedClear? {
        guard answer == .confirm, !bundleID.isEmpty else { return nil }
        return ApprovedClear(bundleID: bundleID)
    }
}

// MARK: review

/// The proposals on one card and what the person did to them. Pure; nothing here writes anything.
public struct LabelReview: Equatable, Sendable {
    public let bundleID: String
    public let appName: String
    public private(set) var proposals: [LabelProposal]
    private var rejected: Set<Int> = []
    private var edited: Set<Int> = []

    public init(bundleID: String, appName: String, proposals: [LabelProposal]) {
        self.bundleID = bundleID; self.appName = appName; self.proposals = proposals
    }

    public var activeProposals: [LabelProposal] { proposals.filter { !rejected.contains($0.id) } }

    func isEdited(_ id: Int) -> Bool { edited.contains(id) }

    public mutating func reject(_ id: Int) {
        if proposals.contains(where: { $0.id == id }) { rejected.insert(id) }
    }

    /// Replaces the label with the person's text, after the same checks the model's labels get. False (nothing changed) when the text
    /// is not a usable label or the id is unknown.
    @discardableResult
    public mutating func edit(_ id: Int, to text: String) -> Bool {
        guard let i = proposals.firstIndex(where: { $0.id == id }), !rejected.contains(id), let clean = LabelSanitizer.clean(text) else { return false }
        proposals[i].label = clean
        edited.insert(id)
        return true
    }

    func line(_ p: LabelProposal) -> String {
        let tail = edited.contains(p.id) ? "edited" : String(format: "%.2f", p.confidence)
        return "\(p.id). \(p.kind) near \(p.context): \(p.label) (\(tail))"
    }

    static func countText(_ n: Int) -> String { "\(n) label\(n == 1 ? "" : "s")" }

    public var cardText: String {
        let active = activeProposals
        var s = "Shep would add \(LabelReview.countText(active.count)) in \(appName). Nothing is saved until you accept.\n"
        s += active.map { line($0) }.joined(separator: "\n")
        return s
    }
}

// MARK: the card

public struct LabelCardChoice: Equatable, Sendable {
    public var id: String
    public var label: String
}

public struct LabelCard: Equatable, Sendable {
    public var title: String
    public var text: String
    public var choices: [LabelCardChoice]
}

public enum LabelPick: Equatable, Sendable {
    case reject, edit
    var prefix: String { self == .reject ? "reject" : "edit" }
}

public enum LabelCardAction: Equatable, Sendable {
    case answer(LabelCardAnswer)
    case pick(LabelPick)
    case reject(Int)
    case edit(Int)
    case back
    case page(Int)

    /// A card button's id back to what it means. Anything else (including the old "approve") is nil.
    public static func parse(_ id: String?) -> LabelCardAction? {
        guard let id = id else { return nil }
        switch id {
        case "accept-all": return .answer(.acceptAll)
        case "cancel": return .answer(.cancel)
        case "reject-one": return .pick(.reject)
        case "edit-one": return .pick(.edit)
        case "back": return .back
        default: break
        }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let n = Int(parts[1]), n >= 0 else { return nil }
        switch parts[0] {
        case "reject": return .reject(n)
        case "edit": return .edit(n)
        case "page": return .page(n)
        default: return nil
        }
    }
}

public enum LabelCardBuilder {
    /// Labels per picker page. The card is 320 x 150 pt and clips there (PanelGeometry): a long label takes a row of its own,
    /// so two labels plus one row for More / Earlier / Back is what fits under the text. More labels per page would push the
    /// last ones and the page buttons off the card (checked at the real size by `Shep --ui-snapshot`).
    public static let pageSize = 2

    public static func main(_ review: LabelReview) -> LabelCard {
        let n = review.activeProposals.count
        let title = "Shep wants to add \(LabelReview.countText(n)) in \(review.appName)"
        if n == 0 {
            return LabelCard(title: title, text: "Every label was rejected. Nothing will be saved.", choices: [LabelCardChoice(id: "cancel", label: "Close")])
        }
        return LabelCard(title: title, text: review.cardText, choices: [
            LabelCardChoice(id: "accept-all", label: "Accept all (\(n))"),
            LabelCardChoice(id: "edit-one", label: "Edit one\u{2026}"),
            LabelCardChoice(id: "reject-one", label: "Reject one\u{2026}"),
            LabelCardChoice(id: "cancel", label: "Cancel"),
        ])
    }

    public static func picker(_ review: LabelReview, mode: LabelPick, page: Int) -> LabelCard {
        let active = review.activeProposals
        let pages = max(1, (active.count + pageSize - 1) / pageSize)
        let p = max(0, min(pages - 1, page))
        let slice = Array(active.dropFirst(p * pageSize).prefix(pageSize))
        let verb = mode == .reject ? "reject" : "edit"
        var choices = slice.map { LabelCardChoice(id: "\(mode.prefix):\($0.id)", label: String("\($0.id). \($0.kind) near \($0.context): \($0.label)".prefix(60))) }
        if p + 1 < pages { choices.append(LabelCardChoice(id: "page:\(p + 1)", label: "More\u{2026}")) }
        if p > 0 { choices.append(LabelCardChoice(id: "page:\(p - 1)", label: "Earlier\u{2026}")) }
        choices.append(LabelCardChoice(id: "back", label: "Back"))
        let text = "Which one do you want to \(verb)? (page \(p + 1) of \(pages))\n" + slice.map { review.line($0) }.joined(separator: "\n")
        return LabelCard(title: "Shep: choose a label to \(verb)", text: text, choices: choices)
    }
}

public enum LabelFlowResult: Equatable, Sendable {
    case stay, main, picker(LabelPick), page(Int), needsText(Int), finish(LabelCardAnswer)
}

public enum LabelCardFlow {
    /// What a button press does to the review and where the card goes next.
    public static func apply(_ action: LabelCardAction, to review: inout LabelReview) -> LabelFlowResult {
        switch action {
        case .answer(let a): return .finish(a)
        case .pick(let m): return .picker(m)
        case .reject(let id): review.reject(id); return .stay
        case .edit(let id): return .needsText(id)
        case .back: return .main
        case .page(let n): return .page(n)
        }
    }
}
