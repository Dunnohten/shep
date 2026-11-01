import Foundation

// Written for Shep.

/// Everything Shep says or shows in the flow, kept to the essentials: a word or two when speaking, one short line on a card.
/// Errors and refusals keep their own sentences (they say what to do next); narration and status text are gone.
public enum Brief {
    /// Said and shown once a request is accepted and Shep starts looking.
    public static let onIt = "On it."
    /// Said and shown when a step is done (the bark follows).
    public static let done = "Done."
    public static let cancelled = "Cancelled."
    /// A look that found nothing to do.
    public static let nothing = "Nothing to do."
    /// A request while the last one still runs.
    public static let busy = "Still busy."

    /// Said instead of a card whose text the card could not show whole (nothing is asked, nothing is done).
    public static let tooLong = "Too long to show, so I didn't ask."
    /// A card line is only shown when the card shows all of it (`CardModel.approval` cuts at `maxTextLength`).
    public static func cardFits(_ text: String) -> Bool { text.count <= CardModel.maxTextLength }

    public static let approveLabel = "Approve"
    /// The cancel choice's label. Its id stays "cancel": it holds the focus, Escape picks it, and it is never the default.
    public static let denyLabel = "Deny"
    public static var approvalChoices: [(id: String, label: String)] {
        [(id: "approve", label: approveLabel), (id: "cancel", label: denyLabel)]
    }

    /// The pause between two approved steps of one request (was 1.2 s): long enough to see the first one land.
    public static let stepGapSeconds: TimeInterval = 0.5

    /// The longest name a card line shows before it is cut with an ellipsis.
    public static let maxNameCharacters = 28

    /// The approval card's one line: the verb, the control's kind and a short name, as a question, e.g.
    /// `Press the checkbox "Speed Limit"?`. Typed text is always shown whole (it is what gets written). A reason that
    /// changes the decision follows as a short tag (a mouse click, an app that runs commands; see `reasonTag`), and a
    /// mouse click whose spot was checked names what is under it. `peers` are the window's other controls: a name is only
    /// shortened when no other control would show the same short name.
    public static func approvalLine(_ request: ApprovalRequest, peers: [Control] = []) -> String {
        let action = request.action
        let name = displayName(action.control, peers: peers)
        var line: String
        if case .setValue(let t) = action.kind {
            line = "Type \"\(t)\" in the \(action.control.kind) \"\(name)\"?"
        } else {
            line = "\(action.kind.verb) the \(action.control.kind) \"\(name)\"?"
        }
        let tag = reasonTag(request.reason)
        if !tag.isEmpty { line += " " + tag }
        if let id = action.hitIdentity { line += " Under it: \(id.cardText)." }
        return line
    }

    /// The short form of an `ApprovalPolicy` reason. Typing says nothing more (the line already shows the text); any reason
    /// not listed here is shown whole, so a new reason can never be dropped from the card by accident.
    public static func reasonTag(_ reason: String) -> String {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return "" }
        if r.hasPrefix("This uses the mouse pointer") { return "With the mouse." }
        if r.hasPrefix("The control didn't respond to Accessibility") { return "With the mouse: it ignored Accessibility." }
        if r.hasPrefix("Found on the screenshot") { return "With the mouse: seen only on screen." }
        if r.hasPrefix("Typing changes") { return "" }
        if r == "This app can run commands." { return "This app runs commands." }
        return r
    }

    /// The name the card shows: `shortName` when that is unambiguous among `peers`, otherwise the full label.
    public static func displayName(_ control: Control, peers: [Control]) -> String {
        let full = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = shortName(control)
        guard short != full else { return full }
        let clash = peers.contains { p in
            p.label.trimmingCharacters(in: .whitespacesAndNewlines) != full && (shortName(p) == short || p.label == short)
        }
        return clash ? full : short
    }

    /// A control's name, short: a tooltip used as the name keeps its leading capitalised words ("Speed Limit overrides the
    /// total..." becomes "Speed Limit"); any other name is cut at a word boundary to `maxNameCharacters`.
    public static func shortName(_ control: Control) -> String {
        let label = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if control.labelSource == .tooltip {
            let words = label.split(separator: " ")
            var lead: [Substring] = []
            for w in words {
                guard let first = w.first, first.isUppercase || first.isNumber, lead.count < 4 else { break }
                lead.append(w)
            }
            if !lead.isEmpty, lead.count < words.count {
                return lead.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            }
        }
        return clip(label)
    }

    /// `text` cut at a word boundary to `maxNameCharacters`, with an ellipsis when cut.
    public static func clip(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxNameCharacters else { return t }
        var out = ""
        for w in t.split(separator: " ") {
            let next = out.isEmpty ? String(w) : out + " " + w
            if next.count > maxNameCharacters - 1 { break }
            out = next
        }
        if out.isEmpty { out = String(t.prefix(maxNameCharacters - 1)) }
        return out + "…"
    }
}
