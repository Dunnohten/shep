import CoreGraphics
import Foundation

/// Written for Shep.
/// Which controls are worth proposing, best first. Pure and deterministic: request words (with a small synonym table),
/// the control's kind, whether the app itself lists it (Accessibility), and size and position sanity. The model then picks
/// among the top few by mark number (`ProposalPicking`); this ranking is also the fallback when the model is not there.

public struct RankedControl: Equatable, Sendable {
    public var control: Control
    public var score: Double
    /// How well the control's words match the request (0 without a request or without a match).
    public var matchScore: Double
}

public enum ProposalRanker {
    /// How many go to the model, and how many are ever proposed.
    public static let topK = 12
    public static let maxProposals = 3

    /// Words that mean the same thing for a request. A request word and a control word in one group match.
    public static let synonymGroups: [[String]] = [
        ["close", "quit", "exit"], ["save", "store"], ["send", "submit"], ["search", "find"],
        ["settings", "preferences", "options", "gear", "config", "configure"], ["back", "previous", "prev"],
        ["next", "forward"], ["add", "new", "plus", "create"], ["delete", "remove", "trash", "discard"],
        ["open", "launch"], ["cancel", "dismiss", "stop"], ["share", "export"], ["refresh", "reload"],
        ["help", "support"], ["more", "menu"], ["attach", "attachment", "paperclip"], ["download", "get"],
        ["upload", "import"], ["edit", "modify", "change"], ["copy", "duplicate"], ["print", "printer"],
    ]

    /// Words that are about asking, not about the control.
    static let stopWords: Set<String> = [
        "the", "a", "an", "to", "please", "button", "click", "press", "tap", "hit", "on", "my", "this", "that", "it", "me", "for", "of",
        "and", "can", "you", "i", "want", "need", "would", "like", "just", "now", "then", "with", "in", "into", "at", "so", "do",
        "let", "lets", "is", "are", "be", "icon", "unlabeled",
    ]

    /// Window chrome and quitting: never proposed unless the request is about them.
    static let riskyGroup: Set<String> = ["close", "quit", "exit", "minimize", "zoom"]
    static let riskySubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
    static let typingWords: Set<String> = ["type", "write", "enter", "input", "search", "find", "fill", "email", "name", "text"]

    private static let groupIndex: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, g) in synonymGroups.enumerated() { for w in g { m[w] = i } }
        return m
    }()

    // MARK: words

    /// Lower-case words of `s` without stop words.
    public static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stopWords.contains($0) && !$0.isEmpty }
    }

    /// Plural and -ing / -ed forms reduced to something the synonym table may know.
    static func variants(_ w: String) -> [String] {
        var out = [w]
        if w.count > 3, w.hasSuffix("s") { out.append(String(w.dropLast())) }
        if w.count > 5, w.hasSuffix("ing") { let b = String(w.dropLast(3)); out += [b, b + "e"] }
        if w.count > 4, w.hasSuffix("ed") { let b = String(w.dropLast(2)); out += [b, b + "e"] }
        if w.count > 4, w.hasSuffix("es") { out.append(String(w.dropLast(2))) }
        return out
    }

    static func group(of w: String) -> Int? {
        for v in variants(w) { if let g = groupIndex[v] { return g } }
        return nil
    }

    /// 10 for a shared word, 6 for a shared synonym group, summed over the request's words; +4 when the control's whole label
    /// appears in the request.
    public static func match(request: [String], rawRequest: String, label: [String], rawLabel: String) -> Double {
        var score = 0.0
        let labelVariants = Set(label.flatMap(variants))
        let labelGroups = Set(label.compactMap(group))
        for r in request {
            if !labelVariants.isDisjoint(with: variants(r)) { score += 10 }
            else if let g = group(of: r), labelGroups.contains(g) { score += 6 }
        }
        let l = rawLabel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if l.count >= 3, rawRequest.lowercased().contains(l) { score += 4 }
        return score
    }

    // MARK: panes and the request

    /// A box covering this share of the window or more is a pane (a list, a sidebar, the content), not a control. The ranking
    /// scores it down, the pipeline never takes it as the model's pick, and a click at its centre would land on nothing nameable.
    public static let paneFraction = 0.35

    public static func isPaneSized(_ frame: CGRect, window: CGRect) -> Bool {
        let windowArea = Double(window.width * window.height)
        guard windowArea > 0, frame.width.isFinite, frame.height.isFinite else { return false }
        return Double(frame.width * frame.height) > windowArea * paneFraction
    }

    /// How well a control's own words match the request (the number `rank` calls `matchScore`).
    public static func requestMatch(_ c: Control, request: String) -> Double {
        let raw = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = tokens(raw)
        return words.isEmpty ? 0 : match(request: words, rawRequest: raw, label: tokens(c.label), rawLabel: c.label)
    }

    // MARK: one strong match

    /// A match score of two shared request words (10 each). Below it a control is not a strong match.
    public static let strongMatchScore = 20.0
    /// No other control's match score may come within this of the strong one's.
    public static let strongMatchGap = 0.15
    /// Distinct request words that must appear (or have a synonym) in the control's label or tooltip.
    public static let strongMatchMinWords = 2

    /// The one control that clearly answers `request` by its words, for when the model chose nothing: exactly one ranked control has
    /// `matchScore >= strongMatchScore` and at least `strongMatchMinWords` distinct request words in its label or tooltip, and no
    /// other ranked control's match score is within `strongMatchGap` of its own. nil otherwise, and for an empty request.
    /// `ranked` comes from `rank`, so refused, disabled and secure controls are not in it.
    public static func uniqueStrongMatch(in ranked: [RankedControl], request: String) -> Control? {
        let words = Array(Set(tokens(request)))
        guard !words.isEmpty else { return nil }
        var strongIndexes: [Int] = []
        for (i, r) in ranked.enumerated() where r.matchScore >= strongMatchScore {
            let text = tokens(r.control.label + " " + r.control.help)
            let textVariants = Set(text.flatMap(variants))
            let textGroups = Set(text.compactMap(group))
            var shared = 0
            for w in words {
                if !textVariants.isDisjoint(with: variants(w)) { shared += 1 }
                else if let g = group(of: w), textGroups.contains(g) { shared += 1 }
            }
            if shared >= strongMatchMinWords { strongIndexes.append(i) }
        }
        guard strongIndexes.count == 1, let best = strongIndexes.first else { return nil }
        let bestScore = ranked[best].matchScore
        for (i, other) in ranked.enumerated() where i != best {
            if other.matchScore > bestScore - strongMatchGap { return nil }
        }
        return ranked[best].control
    }

    // MARK: ranking

    static func role(of c: Control) -> ControlRole {
        if let r = ControlRole(axRole: c.role) { return r }
        return c.actions.contains(where: { ControlFilter.pressActions.contains($0) }) ? .button : .other
    }

    static func prior(_ r: ControlRole, typing: Bool) -> Double {
        switch r {
        case .button: return 3
        case .link: return 2.5
        case .menuItem, .tab, .checkbox: return 2
        case .icon: return 1.5
        case .textField: return typing ? 3.5 : 0.5
        case .staticText, .image, .other: return 0
        }
    }

    /// The request is about closing, quitting, minimizing or zooming (by those words or a synonym of them).
    static func mentionsRisky(_ words: [String]) -> Bool {
        var riskyGroups = Set<Int>()
        for w in riskyGroup { if let g = group(of: w) { riskyGroups.insert(g) } }
        for w in words {
            if riskyGroup.contains(w) { return true }
            if let g = group(of: w), riskyGroups.contains(g) { return true }
        }
        return false
    }

    static func isRisky(_ c: Control) -> Bool {
        if riskySubroles.contains(c.subrole) { return true }
        return tokens(c.label).contains { riskyGroup.contains($0) }
    }

    /// The best `limit` proposable controls for `request`, best first. Excluded outright: text, pictures and "other",
    /// secure and disabled controls, anything policy refuses, and window-chrome or quit controls unless the request is about them.
    /// - Parameter window: the window's frame in screen points (for the size and position checks).
    public static func rank(_ controls: [Control], request: String?, bundleID: String, window: CGRect?, limit: Int = topK) -> [RankedControl] {
        let raw = (request ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = tokens(raw)
        let typing = words.contains { typingWords.contains($0) }
        let askedRisky = mentionsRisky(words)
        let windowArea = window.map { Double($0.width * $0.height) } ?? 0

        var scored: [(control: Control, score: Double, match: Double, order: Int)] = []
        for (order, c) in controls.enumerated() {
            let r = role(of: c)
            guard r.isProposable, !c.isSecure, c.enabled, ControlPolicy.refusal(c, bundleID: bundleID) == nil else { continue }
            if isRisky(c), !askedRisky { continue }
            let m = words.isEmpty ? 0 : match(request: words, rawRequest: raw, label: tokens(c.label), rawLabel: c.label)
            var s = prior(r, typing: typing) + m
            if !c.fromVision { s += 2 }                       // the app lists it: pressable without the mouse
            s += c.label.isEmpty ? -1 : (c.label.lowercased().hasPrefix("unlabeled") ? -1 : 1.5)
            if let f = c.frame, f.width.isFinite, f.height.isFinite {
                if min(f.width, f.height) < 6 { s -= 1.5 }    // too small to be meant
                if let w = window, windowArea > 0 {
                    if !w.intersects(f) { s -= 3 }            // outside the window
                    else if isPaneSized(f, window: w) { s -= 3 }   // a whole pane, not a control
                }
            }
            scored.append((c, s, m, order))
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.order < b.order }
        return scored.prefix(limit).map { RankedControl(control: $0.control, score: $0.score, matchScore: $0.match) }
    }
}
