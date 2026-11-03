import CoreGraphics
import Foundation

// Written for Shep.

/// What a label is remembered against, so it can be found again only when the same control is really there. Stored with the label next
/// to the fingerprint (the key). A fingerprint says "same kind of thing in the same place in the tree"; the anchor is the second opinion
/// that must agree before a stored label is shown on a live control. A vanished label is better than one on the wrong control.
public struct LabelAnchor: Codable, Equatable, Sendable {
    public var role: String
    public var subrole: String
    public var identifier: String
    /// Up to two static texts near the control, as the scan saw them.
    public var nearbyText: [String]
    public var help: String
    /// Ancestor roles from the window down, each step with the count of earlier same-role siblings: "AXWindow>AXGroup[0]>AXButton[2]".
    public var path: String
    /// How many children of the control's parent have the control's role. An inserted or removed sibling changes it.
    public var siblingCount: Int
    /// Window-relative center as a fraction of the window (0...1). A guard, not a key: a window that was moved or resized does not break a
    /// match, a control that is somewhere else entirely does.
    public var x: Double
    public var y: Double
    /// The window's size when the label was approved (0 when unknown). In a window of about the same size the control must also be about
    /// where it was; in a resized one only gross displacement counts.
    public var windowWidth: Double
    public var windowHeight: Double
    /// The kind of window the label was approved in. nil for a label saved by an older build, or from a window nothing identified.
    public var window: WindowSignature?

    public init(role: String, subrole: String = "", identifier: String = "", nearbyText: [String] = [], help: String = "", path: String = "",
                siblingCount: Int = 1, x: Double = 0, y: Double = 0, windowWidth: Double = 0, windowHeight: Double = 0,
                window: WindowSignature? = nil) {
        self.role = role; self.subrole = subrole; self.identifier = identifier; self.nearbyText = nearbyText; self.help = help
        self.path = path; self.siblingCount = siblingCount; self.x = x; self.y = y
        self.windowWidth = windowWidth; self.windowHeight = windowHeight; self.window = window
    }

    public static let empty = LabelAnchor(role: "")

    public var isEmpty: Bool { role.isEmpty }

    /// The anchor carries something the control itself owns that tells it from the others of its role: an identifier, or help text.
    /// Place in the tree, place in the window and the text near the control never count: they stay put when two controls swap. (Whether the
    /// identifier or help is also unique is the scan's check.) A label an earlier build stored on nearby text alone fails this and is not applied.
    public var hasStableIdentity: Bool {
        if !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !LabelFingerprint.normalizedHelp(help).isEmpty
    }

    /// The farthest, as a fraction of the window, a control may have moved and still be the same one in a window that was resized.
    public static let maxDrift = 0.45
    /// The same, in a window whose size did not change (within 2%, at least 4 points): a layout shift, not a different control.
    public static let maxDriftSameSize = 0.08

    /// True when the stored anchor describes the live control. Role and subrole must agree. A control the app gave an identifier is
    /// matched on it (and its help text); any other control must agree on the roles above it, its place among same-role siblings, the
    /// text near it and its help.
    public static func agrees(stored: LabelAnchor, live: LabelAnchor) -> Bool {
        guard !stored.isEmpty, stored.role == live.role, stored.subrole == live.subrole else { return false }
        guard stored.hasStableIdentity, live.hasStableIdentity else { return false }
        let storedID = stored.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveID = live.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storedID == liveID else { return false }
        guard LabelFingerprint.normalizedHelp(stored.help) == LabelFingerprint.normalizedHelp(live.help) else { return false }
        let limit = sameWindowSize(stored, live) ? maxDriftSameSize : maxDrift
        guard abs(stored.x - live.x) <= limit, abs(stored.y - live.y) <= limit else { return false }
        if !storedID.isEmpty { return true }
        guard stored.path == live.path, stored.siblingCount == live.siblingCount else { return false }
        return normalizedNearby(stored.nearbyText) == normalizedNearby(live.nearbyText)
    }

    static func sameWindowSize(_ a: LabelAnchor, _ b: LabelAnchor) -> Bool {
        guard a.windowWidth > 0, a.windowHeight > 0, b.windowWidth > 0, b.windowHeight > 0 else { return false }
        return abs(a.windowWidth - b.windowWidth) <= max(4, 0.02 * a.windowWidth) && abs(a.windowHeight - b.windowHeight) <= max(4, 0.02 * a.windowHeight)
    }

    static func normalizedNearby(_ texts: [String]) -> [String] {
        texts.prefix(2).map(LabelFingerprint.normalizedText)
    }
}

/// One label as the store holds it for an app: the fingerprint it is keyed by, the text, and the anchor it was approved against
/// (nil for a label saved by an older build, which can only be trusted when the app named the control with an identifier).
public struct StoredLabel: Equatable, Sendable {
    public var fingerprint: String
    public var label: String
    public var anchor: LabelAnchor?
    public init(fingerprint: String, label: String, anchor: LabelAnchor? = nil) {
        self.fingerprint = fingerprint; self.label = label; self.anchor = anchor
    }
}
