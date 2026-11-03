import CoreGraphics
import Foundation

// Written for Shep.

/// The key a label is stored under, so a label stored for a control can be found again in a later window of the same app.
/// Built from stable attributes only: role, subrole, AXIdentifier (when the app sets one it decides alone), the roles of the ancestors with
/// the sibling index among same-role siblings, the nearby static text (digits blurred) and the help text (digits kept: "Open account 1234" and "Open account 5678" are two controls). Never the position (a resized or
/// moved window must not lose its labels), the checkbox value, focus, selection, the window title, or the control's own (generic or
/// empty) title. The key alone is not trusted: the label's `LabelAnchor` must also agree with the live control before it is shown.
public enum LabelFingerprint {

    public struct Input: Equatable, Sendable {
        public var role: String
        public var subrole: String
        public var identifier: String
        public var ancestorPath: [String]
        public var nearbyText: [String]
        public var help: String
        public var windowSize: CGSize
        /// Window-relative center, in points. Goes into the anchor only, never into the fingerprint.
        public var relativeCenter: CGPoint
        /// Children of the control's parent that have the control's role (itself included).
        public var siblingCount: Int
        public init(role: String, subrole: String = "", identifier: String = "", ancestorPath: [String] = [], nearbyText: [String] = [],
                    help: String = "", windowSize: CGSize, relativeCenter: CGPoint, siblingCount: Int = 1) {
            self.role = role; self.subrole = subrole; self.identifier = identifier; self.ancestorPath = ancestorPath
            self.nearbyText = nearbyText; self.help = help; self.windowSize = windowSize; self.relativeCenter = relativeCenter
            self.siblingCount = siblingCount
        }
    }

    public static func make(_ input: Input) -> String {
        let id = input.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty {
            return "i1-" + hash([input.role, input.subrole, id])
        }
        var parts = [input.role, input.subrole]
        parts.append(input.ancestorPath.joined(separator: ">"))
        parts.append(input.nearbyText.prefix(2).map(normalizedText).joined(separator: "|"))
        parts.append(normalizedHelp(input.help))
        // "p3-": help is compared with its digits. A key from an earlier build ("p2-", help digits folded) is never produced again, so a
        // label stored under it is not found and is not shown; the person labels the control again.
        return "p3-" + hash(parts)
    }

    /// What the label is remembered against: the attributes above, the sibling count, and the coarse place in the window.
    public static func anchor(_ input: Input) -> LabelAnchor {
        func fraction(_ v: CGFloat, _ extent: CGFloat) -> Double {
            guard v.isFinite, extent.isFinite, extent > 0 else { return 0 }
            return Double(max(0, min(1, v / extent)))
        }
        return LabelAnchor(role: input.role, subrole: input.subrole, identifier: input.identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                           nearbyText: Array(input.nearbyText.prefix(2)), help: input.help, path: input.ancestorPath.joined(separator: ">"),
                           siblingCount: input.siblingCount, x: fraction(input.relativeCenter.x, input.windowSize.width),
                           y: fraction(input.relativeCenter.y, input.windowSize.height),
                           windowWidth: input.windowSize.width.isFinite ? Double(max(0, input.windowSize.width)) : 0,
                           windowHeight: input.windowSize.height.isFinite ? Double(max(0, input.windowSize.height)) : 0)
    }

    /// Lower case, whitespace collapsed, every run of digits replaced by "#": "3 items" and "4 items" are the same text.
    static func normalizedText(_ s: String) -> String {
        var out = ""
        var inDigits = false
        for ch in s.lowercased() {
            if ch.isNumber { if !inDigits { out.append("#"); inDigits = true }; continue }
            inDigits = false
            out.append(ch)
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Help text as identity: lower case and whitespace collapsed, digits kept. A tooltip that names an account, a row or a count tells
    /// controls apart by that number, so it must not be folded the way nearby text is.
    static func normalizedHelp(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// FNV-1a, 64 bit, over the parts joined with a separator no part contains. Same on every run (Swift's own hashing is seeded per process).
    static func hash(_ parts: [String]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
