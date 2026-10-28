import Foundation

/// The 12 dog themes from bloub-dog@6b59465 (src/goop/dog.ts PALETTES). Names and ids must match the JS side.
public struct ShepTheme: Equatable, Identifiable {
    public let name: String
    public let bodyHex: String
    public var id: String { ShepThemes.themeID(name) }
}

public enum ShepThemes {
    public static let all: [ShepTheme] = [
        ShepTheme(name: "Tangerine", bodyHex: "#FF7A1A"),
        ShepTheme(name: "Cobalt", bodyHex: "#3D6BFF"),
        ShepTheme(name: "Bubblegum", bodyHex: "#FF4F9A"),
        ShepTheme(name: "Grape", bodyHex: "#8B5CF6"),
        ShepTheme(name: "Beagle Tan", bodyHex: "#D99A4E"),
        ShepTheme(name: "Coral", bodyHex: "#FF5A4E"),
        ShepTheme(name: "Teal", bodyHex: "#0E9AA7"),
        ShepTheme(name: "Lime", bodyHex: "#8BD617"),
        ShepTheme(name: "Sky", bodyHex: "#38B6FF"),
        ShepTheme(name: "Cream", bodyHex: "#FFF1D6"),
        ShepTheme(name: "Charcoal", bodyHex: "#46464E"),
        ShepTheme(name: "Sunflower", bodyHex: "#FFC81A"),
    ]

    public static var defaultTheme: ShepTheme { all[0] }

    /// Same slug rule as themes.ts: lowercase, runs of non [a-z0-9] become one dash, trimmed.
    public static func themeID(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            let isAlnum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlnum {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out
    }

    /// Unknown or empty: the default, never nil (like findTheme in themes.ts).
    public static func find(_ query: String?) -> ShepTheme {
        let key = themeID(query ?? "")
        return all.first { $0.id == key } ?? defaultTheme
    }
}

/// Dog states the renderer understands (shep-dog page `shep.setState`).
public enum ShepDogState: String, CaseIterable {
    case idle
    case lookLeft = "look-left"
    case lookRight = "look-right"
    case thinking
    case listening
    case talking
    case sleeping
}

/// Quoting for JavaScript string literals handed to evaluateJavaScript.
public enum JSLiteral {
    public static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if u.value < 0x20 {
                    out += "\\u" + String(format: "%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}
