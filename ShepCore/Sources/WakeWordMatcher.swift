import Foundation

/// Written for Shep.
/// The "Hey Shep" wake word, as text rules. Pure: the app's listener feeds recogniser transcripts in.
///
/// The rule. The transcript is lowercased, accents are folded, and every run of anything that is not a letter or digit is a
/// word break (so case, punctuation and spacing do not matter). A match is two neighbouring words:
///   - a greeting: hey, hay, hei, eh, or "a" (what recognisers often hear for the first half), then
///   - the name: shep, shepp, sheppe, or shap (the vowel it mishears).
/// Both must be whole words, so "shepherd", "sheep", "hey chef", "they shepherd" and "shep" alone do not match. A greeting and
/// name run together ("heyshep", "heyshepp") count as well. "hi" is deliberately not a greeting: it is an everyday word and
/// "hi shep" is not the phrase the owner chose. The match is looked for anywhere in the transcript.
public enum WakeWordMatcher {
    static let greetings: Set<String> = ["hey", "hay", "hei", "eh", "a"]
    static let names: Set<String> = ["shep", "shepp", "sheppe", "shap"]
    static let fused: Set<String> = Set(greetings.filter { $0.count > 1 }.flatMap { g in names.map { g + $0 } })

    /// Lowercase words with accents folded; anything that is not a letter or digit separates words.
    public static func tokens(_ transcript: String) -> [String] {
        let folded = transcript.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var words: [String] = []
        var current = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber { current.append(ch) }
            else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// How many separate occurrences the transcript holds (a name already used by an earlier match is not reused).
    public static func matchCount(in transcript: String) -> Int {
        let words = tokens(transcript)
        var count = 0
        var i = 0
        while i < words.count {
            if fused.contains(words[i]) { count += 1; i += 1; continue }
            if greetings.contains(words[i]), i + 1 < words.count, names.contains(words[i + 1]) { count += 1; i += 2; continue }
            i += 1
        }
        return count
    }

    public static func matches(_ transcript: String) -> Bool { matchCount(in: transcript) > 0 }
}

/// Reports a match once. A recogniser's partial transcript keeps growing and is sometimes revised, so the same "hey shep" is
/// seen again and again; the detector remembers how many occurrences it has already reported in the current recognition task
/// (a high-water mark: a revision that drops the match and brings it back is not new) and says true only for one beyond that.
/// Reset it when a recognition task starts.
public struct WakeWordDetector: Equatable, Sendable {
    public private(set) var reportedCount = 0
    public init() {}

    public mutating func consume(_ transcript: String) -> Bool {
        let n = WakeWordMatcher.matchCount(in: transcript)
        guard n > reportedCount else { return false }
        reportedCount = n
        return true
    }

    public mutating func reset() { reportedCount = 0 }
}
