import CryptoKit
import Foundation

/// The banned-token check, as the tests run it. Mirrors scripts/check-banned-tokens.py: a token is a run of letters, a run of digits,
/// or a camel-case part of a letter run, lowercased; it is banned when the SHA-256 of its text is on the list. The list holds hashes only.
enum BannedTokenScan {
    struct Entry: Hashable { var length: Int; var digest: String }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// "<length> <hex>" lines; blank lines and "#" lines are ignored.
    static func hashes(inListing text: String) -> Set<Entry> {
        var out = Set<Entry>()
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ").map(String.init)
            if parts.count == 2, let n = Int(parts[0]) { out.insert(Entry(length: n, digest: parts[1].lowercased())) }
        }
        return out
    }

    static func tokens(_ text: String) -> Set<String> {
        var found = Set<String>()
        var run = ""
        var kind = 0   // 1 letters, 2 digits
        func flush() {
            guard !run.isEmpty else { return }
            found.insert(run.lowercased())
            if kind == 1 { for part in camelParts(run) { found.insert(part.lowercased()) } }
            run = ""; kind = 0
        }
        for ch in text {
            let k = ch.isLetter ? 1 : (ch.isNumber && ch.isASCII ? 2 : 0)
            if k == 0 || k != kind { flush() }
            if k != 0 { run.append(ch); kind = k }
        }
        flush()
        return found
    }

    /// "GiggleVL" -> ["Giggle", "VL"]; "HTTPServer" -> ["HTTP", "Server"]; "plain" -> ["plain"].
    static func camelParts(_ run: String) -> [String] {
        let chars = Array(run)
        var parts: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            if !current.isEmpty, ch.isUppercase {
                let prevLower = chars[i - 1].isLowercase
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prevLower || (chars[i - 1].isUppercase && nextLower) { parts.append(current); current = "" }
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func contains(_ text: String, hashes: Set<Entry>) -> Bool {
        let lengths = Set(hashes.map { $0.length })
        for token in tokens(text) where lengths.contains(token.count) {
            if hashes.contains(Entry(length: token.count, digest: sha256Hex(token))) { return true }
        }
        return false
    }
}
