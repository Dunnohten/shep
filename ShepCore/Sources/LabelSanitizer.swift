import Foundation

// Written for Shep.

/// Everything a model says about a label passes through here before a person sees it or the store keeps it. The model's words are data:
/// a label that reads like an instruction, a link, or a role word is dropped, never repaired into something else.
public enum LabelSanitizer {
    public static let maxLength = 40
    public static let maxWords = 6

    private static let quoteCharacters = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}\u{00AB}\u{00BB}")
    private static let markupCharacters = Set<Character>("*_#~|<>[]{}\\^`")

    private static let urlPatterns = [
        "://", "\\bwww\\.", "\\b(javascript|file|data|vbscript|ftp|ssh|mailto|tel):",
        "\\b[a-z0-9-]+\\.(com|org|net|io|dev|app|ai|co|me|ly|gg|xyz|info|edu|gov|us|uk|de|ru|cn|sh|zip|mov)\\b",
    ]

    private static let instructionPatterns = [
        "\\bignore (all |the |any |your |these |those |every )?(previous|prior|above|earlier|preceding|instructions?|rules|system|guidelines)",
        "\\bdisregard\\b", "\\byou are\\b", "\\byou must\\b", "\\byou should\\b", "\\byour (task|job|role|instructions?)\\b",
        "\\bsystem prompt\\b", "\\b(system|assistant|user|developer)\\s*:", "\\bnew instructions?\\b", "\\bas an ai\\b", "\\blanguage model\\b",
        "\\bi (cannot|can't|am unable|apologi[sz]e)\\b", "\\bsorry\\b", "\\boverride (the |all |any |your )?(safety|instructions?|rules|system|polic)",
        "\\bplease\\b", "\\bkindly\\b", "\\bdo not (label|name|answer|follow|respond|reply|output|use)\\b", "\\bjailbreak\\b",
        "\\b(send|reveal|share|exfiltrate|leak|print|output|type|enter|paste)\\b.*\\b(password|passwords|secret|secrets|token|tokens|credentials|api key)\\b",
        "\\breveal (the|your|all|any)\\b", "\\b(sudo|rm -rf|chmod|curl|wget|powershell|eval|exec)\\b", "\\bforget (everything|all|previous|your|the above)\\b",
        "\\bclick (the|on|this|that|another|other)\\b", "\\bpress (the|this|that|another|other)\\b",
    ]

    /// What a model says when it cannot tell ("Unknown", "N/A"): not a name, so never a proposal. Judged on the letters alone ("N/A" -> "na").
    static let nonNames: Set<String> = [
        "na", "none", "unknown", "null", "nil", "undefined", "unlabeled", "unlabelled", "unnamed", "untitled", "label", "nolabel", "noname",
        "nolabelneeded", "tbd", "todo", "empty", "blank", "unclear", "notsure", "notknown", "cannottell", "cantsay", "unsure",
    ]
    /// Words that, with role words only ("Unknown control", "Unlabeled icon"), say nothing either.
    static let nonNameWords: Set<String> = ["unknown", "none", "unlabeled", "unlabelled", "unnamed", "unclear", "undefined", "null", "nil", "tbd"]

    static func isNonName(_ lower: String) -> Bool {
        if nonNames.contains(String(lower.filter { $0.isLetter })) { return true }
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.contains(where: { nonNameWords.contains($0) }) else { return false }
        return words.allSatisfy { nonNameWords.contains($0) || LabelText.roleWords.contains($0) || Int($0) != nil }
    }

    public static func clean(_ raw: String) -> String? {
        if raw.contains("$(") || raw.contains("${") { return nil }
        // Newlines and tabs are separators; every other control or format character (bell, NUL, bidi overrides) is dropped.
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                if u == "\n" || u == "\t" || u == "\r" || u.properties.generalCategory == .lineSeparator || u.properties.generalCategory == .paragraphSeparator {
                    scalars.append(" ")
                }
            default:
                scalars.append(u)
            }
        }
        var text = String(scalars)
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        text = String(text.map { markupCharacters.contains($0) || $0 == "(" || $0 == ")" ? " " : $0 })
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = text.trimmingCharacters(in: quoteCharacters.union(.whitespaces))
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty, text.count <= maxLength else { return nil }
        guard text.split(separator: " ").count <= maxWords else { return nil }
        let lower = text.lowercased()
        for p in urlPatterns where lower.range(of: p, options: .regularExpression) != nil { return nil }
        for p in instructionPatterns where lower.range(of: p, options: .regularExpression) != nil { return nil }
        if isNonName(lower) { return nil }
        // Judged as written too: stripping "_" would turn "btn_close" into two ordinary words.
        if LabelText.isGeneric(text) || LabelText.isGeneric(raw.trimmingCharacters(in: quoteCharacters.union(.whitespacesAndNewlines))) { return nil }
        return text
    }

    /// A confidence from a decoded reply: a number (not a boolean), finite, clamped to 0...1. Anything else is nil.
    public static func confidence(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite else { return nil }
        return min(1, max(0, d))
    }
}
