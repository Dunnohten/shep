import Foundation

// Written for Shep.

/// What a typed or spoken request is asking for, when it is one of the two label-repair requests. Everything else is `.other`
/// and goes to the existing request pipeline unchanged.
public enum ScreenIntent: Equatable, Sendable {
    /// "fix this screen", "label this window", "find unlabeled buttons": find controls with no real name and propose labels.
    case fixScreen
    /// "clear labels for this app": remove Shep's stored labels for the front app.
    case clearLabels
    case other
}

/// Pure. A request routes only when the WHOLE sentence is one of the known phrasings (after dropping case, punctuation, a leading
/// "Shep," / "hey shep" and a "please"), so "fix this screen so the text is bigger" is not a label request.
public enum ScreenIntentRouter {
    public static func route(_ request: String?) -> ScreenIntent {
        guard let request = request else { return .other }
        var words = tokens(request)
        words = strippedPoliteness(words)
        if words.isEmpty { return .other }
        if isClear(words) { return .clearLabels }
        if isFix(words) { return .fixScreen }
        return .other
    }

    static func tokens(_ text: String) -> [String] {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" { continue }
            if CharacterSet.alphanumerics.contains(scalar) { out.unicodeScalars.append(scalar) } else { out += " " }
        }
        return out.split(separator: " ").map(String.init)
    }

    private static func strippedPoliteness(_ input: [String]) -> [String] {
        var w = input
        // Leading: "hey shep", "ok shep", "okay shep", "shep", then "please".
        if w.count >= 2, ["hey", "ok", "okay"].contains(w[0]), w[1] == "shep" { w.removeFirst(2) }
        else if w.first == "shep" { w.removeFirst() }
        if w.first == "please" { w.removeFirst() }
        if w.last == "please" { w.removeLast() }
        return w
    }

    private static let determiners: Set<String> = ["the", "this", "these", "my", "all", "any", "those"]
    private static let missingWords: Set<String> = ["unlabeled", "unlabelled", "unnamed", "missing"]

    private static func isFix(_ input: [String]) -> Bool {
        var w = input
        // Optional trailing place: "on this screen", "in this window", "on this page".
        if w.count >= 4, ["on", "in"].contains(w[w.count - 3]), w[w.count - 2] == "this", ["screen", "window", "page"].contains(w[w.count - 1]) {
            w.removeLast(3)
        }
        guard let verb = w.first else { return false }
        var rest = Array(w.dropFirst())
        if let d = rest.first, determiners.contains(d) { rest.removeFirst() }
        var hadMissing = false
        if let m = rest.first, missingWords.contains(m) { rest.removeFirst(); hadMissing = true }
        guard rest.count == 1, let noun = rest.first else { return false }
        switch verb {
        case "fix", "label", "repair", "relabel":
            if hadMissing { return ["buttons", "controls", "labels", "elements"].contains(noun) }
            if noun == "screen" || noun == "window" { return true }
            return ["labels", "buttons", "controls"].contains(noun)
        case "find":
            return hadMissing && ["buttons", "controls", "labels", "elements"].contains(noun)
        default:
            return false
        }
    }

    private static func isClear(_ input: [String]) -> Bool {
        var w = input
        guard let verb = w.first, ["clear", "remove", "reset", "forget", "erase"].contains(verb) else { return false }
        w.removeFirst()
        // "clear this app's labels" / "clear this apps labels"
        if w.count >= 3, w[0] == "this", ["app", "apps", "application"].contains(w[1]), w.last == "labels" {
            return w.count == 3 || (w.count == 4 && w[2] == "s")
        }
        // Optional trailing place: "for/in/on/from this|the|current app|application".
        if w.count >= 3, ["for", "in", "on", "from"].contains(w[w.count - 3]), ["this", "the", "current", "front"].contains(w[w.count - 2]),
           ["app", "application"].contains(w[w.count - 1]) {
            w.removeLast(3)
        }
        if let d = w.first, determiners.contains(d) { w.removeFirst() }
        return w == ["labels"]
    }
}
