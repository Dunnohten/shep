import Foundation

// Written for Shep.

/// Which kind of window a label was approved in. Labels are kept per app, and two windows of one app can have the same layout, so a label
/// also records the window it belongs to and is shown only in a window with the same signature.
///
/// The signature is the window's AX identifier when the app sets one. Otherwise it is the window's subrole plus a title class: the title with
/// the parts that name a document left out (a file name, "Untitled 2", "Edited"), digits blurred, and a title that is still long after that
/// counted as content rather than a window type. A window with a plain title ("Settings", "Inspector") keeps it; two document windows of one
/// app share the class "", which is why a signature never settles a question alone: when more than one open window of the app matches, nothing
/// is applied (see `LabelOverlayResolver`). The raw title is not stored, only its class.
public struct WindowSignature: Codable, Equatable, Hashable, Sendable {
    public var identifier: String
    public var subrole: String
    public var titleClass: String

    public init(identifier: String = "", subrole: String = "", titleClass: String = "") {
        self.identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subrole = subrole; self.titleClass = titleClass
    }

    /// From what the window shows: its AX identifier, subrole and title.
    public init(identifier: String, subrole: String, title: String) {
        self.init(identifier: identifier, subrole: subrole, titleClass: WindowSignature.titleClass(of: title))
    }

    public static let empty = WindowSignature()

    /// Nothing identifies the window (no identifier, no subrole, no title class).
    public var isEmpty: Bool { identifier.isEmpty && subrole.isEmpty && titleClass.isEmpty }

    /// A normal document or app window; the only kind a label saved with no window signature may be shown in.
    public var isStandard: Bool { subrole == "AXStandardWindow" }

    /// Whether `live` is the kind of window this signature was made for. An identifier, when there is one, decides alone.
    public func matches(_ live: WindowSignature) -> Bool {
        guard !isEmpty, !live.isEmpty else { return false }
        if !identifier.isEmpty { return identifier == live.identifier }
        return subrole == live.subrole && titleClass == live.titleClass
    }

    // MARK: title class

    static let maxClassWords = 4
    static let separators = [" \u{2014} ", " \u{2013} ", " - ", " | ", " \u{00B7} "]
    static let documentMarkers: Set<String> = ["edited", "locked", "modified", "saved", "read-only", "read only"]

    /// "Report.docx - Edited" -> "", "Untitled 3" -> "", "Settings" -> "settings", "Notes \u{2014} Inbox 12" -> "inbox #", a long page title -> "long".
    public static func titleClass(of title: String) -> String {
        var segments = [title.lowercased()]
        for sep in separators { segments = segments.flatMap { $0.components(separatedBy: sep) } }
        let kept = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !isDocumentLike($0) }
        guard let last = kept.last else { return "" }
        let normalized = LabelFingerprint.normalizedText(last)
        return normalized.split(separator: " ").count > maxClassWords ? "long" : normalized
    }

    static func isDocumentLike(_ segment: String) -> Bool {
        if documentMarkers.contains(segment) { return true }
        if segment == "untitled" || segment.hasPrefix("untitled ") { return true }
        if segment.contains("/") || segment.contains("~") { return true }
        // "name.ext": a dot inside a word, followed by a short alphanumeric ending.
        if segment.range(of: "[^\\s]\\.[a-z0-9]{1,5}$", options: .regularExpression) != nil { return true }
        return false
    }
}

public extension AXWindowInfo {
    var signature: WindowSignature { WindowSignature(identifier: identifier, subrole: subrole, title: title) }
}
