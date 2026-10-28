import CoreGraphics
import Foundation

// Written for Shep.

/// Who is under a click point: the Accessibility element a hit test answers with, reduced to plain values. It is captured
/// when the approval card is built, travels in the `ProposedAction` (so the approval token is bound to it) and is compared
/// with the live element right before the mouse event.
public struct HitIdentity: Equatable, Sendable {
    public var role: String
    public var subrole: String
    /// The resolved name (title, else description, else static text's value, else tooltip), as `Control.label` resolves it.
    public var label: String
    public var labelSource: Control.LabelSource
    public var enabled: Bool
    public var secure: Bool
    /// Global screen points, top-left origin.
    public var frame: CGRect

    public init(role: String, subrole: String = "", label: String, labelSource: Control.LabelSource, enabled: Bool, secure: Bool, frame: CGRect) {
        self.role = role; self.subrole = subrole; self.label = label; self.labelSource = labelSource
        self.enabled = enabled; self.secure = secure; self.frame = frame
    }

    /// Builds the identity from raw attributes with the same label resolution `Control` uses.
    public static func resolved(role: String, subrole: String = "", title: String = "", description: String = "", value: String? = nil,
                                help: String = "", enabled: Bool = true, frame: CGRect) -> HitIdentity {
        let c = Control(role: role, subrole: subrole, title: title, description: description, value: value, help: help, enabled: enabled)
        return HitIdentity(role: role, subrole: subrole, label: c.label, labelSource: c.labelSource, enabled: enabled, secure: c.isSecure, frame: frame)
    }

    /// The resolved label with whitespace collapsed; empty means nobody can say what this element is.
    public var hasName: Bool { !TargetRecheck.normalise(label).isEmpty }

    /// An identity a click may be bound to: a real role, a non-blank resolved name, enabled, not a password field, a finite
    /// non-empty frame. An unnamed element is refused at the card and again at the live check, because the sensitive-word
    /// policy cannot judge a label that is not there.
    public var isUsable: Bool {
        guard hasName else { return false }
        guard !role.isEmpty, enabled, !secure, role != "AXSecureTextField", subrole != "AXSecureTextField" else { return false }
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return false }
        return frame.width > 0 && frame.height > 0
    }

    /// The element as a Control, so `ControlPolicy.refusal` judges its label and role like any other control.
    public func asControl(window: String) -> Control {
        Control(role: role, subrole: subrole, title: label, window: window, frame: frame, enabled: enabled)
    }

    /// True when `live` is the element this identity was captured from: role, subrole, label and where it came from, enabled
    /// and secure flags equal (labels ignore case and spacing), frame within the click guard's tolerance.
    public func matches(_ live: HitIdentity) -> Bool {
        role == live.role && subrole == live.subrole && labelSource == live.labelSource
            && enabled == live.enabled && secure == live.secure
            && TargetRecheck.normalise(label).lowercased() == TargetRecheck.normalise(live.label).lowercased()
            && ClickGuard.sameFrame(frame, live.frame)
    }

    /// For the approval card: `button "Gear"`.
    public var cardText: String {
        let kind = Control(role: role, subrole: subrole).kind
        let name = TargetRecheck.normalise(label)
        return name.isEmpty ? "\(kind) (no name)" : "\(kind) \"\(name)\""
    }
}
