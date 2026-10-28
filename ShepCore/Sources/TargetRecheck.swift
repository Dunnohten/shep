import Foundation

/// What the live Accessibility element reports right before Shep acts on it. Plain values, so the comparison is testable.
public struct LiveTarget: Equatable, Sendable {
    public var role: String
    public var subrole: String
    public var title: String
    public var description: String
    public var value: String?
    /// AXHelp, the tooltip: it names a control that has no title or description.
    public var help: String
    public var enabled: Bool
    /// True when the element's containing window is the very window (same AX element) the snapshot was read from.
    public var inSnapshotWindow: Bool

    public init(role: String, subrole: String = "", title: String = "", description: String = "", value: String? = nil,
                help: String = "", enabled: Bool = true, inSnapshotWindow: Bool = true) {
        self.role = role; self.subrole = subrole; self.title = title; self.description = description
        self.value = value; self.help = help; self.enabled = enabled; self.inSnapshotWindow = inSnapshotWindow
    }
}

public enum TargetVerdict: Equatable, Sendable {
    case ok
    case refuse(String)
}

/// Compares the control Shep listed (and the user approved) with what is there now. Any doubt refuses.
public enum TargetRecheck {
    /// The name that identifies a control: its title, else its description, else (buttons only) its value.
    /// Whitespace is collapsed and the ends trimmed; comparison ignores case.
    public static func identifyingLabel(role: String, title: String, description: String, value: String?) -> String {
        var candidates = [title, description]
        if role == "AXButton" { candidates.append(value ?? "") }
        for c in candidates {
            let t = normalise(c)
            if !t.isEmpty { return t }
        }
        return ""
    }

    /// The name a person would use and where it comes from, resolved exactly as `Control.label` / `Control.labelSource` do
    /// (title, description, static text's value, tooltip), so the live element and the listed one are named by one resolver.
    public static func effectiveLabel(role: String, subrole: String = "", title: String, description: String, value: String?,
                                      help: String) -> (text: String, source: Control.LabelSource) {
        let c = Control(role: role, subrole: subrole, title: title, description: description, value: value, help: help)
        return (c.label, c.labelSource)
    }

    public static func normalise(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    public static func verify(listed control: Control, live: LiveTarget) -> TargetVerdict {
        if control.isSecure || live.role == "AXSecureTextField" || live.subrole == "AXSecureTextField" {
            return .refuse("That is a password field, so I did nothing.")
        }
        if !live.inSnapshotWindow { return .refuse("The control is no longer in the window I read, so I did nothing.") }
        if !live.enabled { return .refuse("The control is disabled now, so I did nothing.") }
        if live.role != control.role { return .refuse("The control is not the same kind of control any more, so I did nothing.") }
        if live.subrole != control.subrole { return .refuse("The control changed its kind, so I did nothing.") }
        let was = identifyingLabel(role: control.role, title: control.title, description: control.description, value: control.value)
        let now = identifyingLabel(role: live.role, title: live.title, description: live.description, value: live.value)
        if !was.isEmpty && now.isEmpty { return .refuse("The control has lost its name, so I did nothing.") }
        if was.lowercased() != now.lowercased() { return .refuse("The control's name changed, so I did nothing.") }
        // The same resolver on both sides, tooltip included: a control named only by its tooltip is renamed when the tooltip
        // changes, and the same words from another source (a tooltip that became a title) are a change too.
        let listedName = effectiveLabel(role: control.role, subrole: control.subrole, title: control.title, description: control.description,
                                        value: control.value, help: control.help)
        let liveName = effectiveLabel(role: live.role, subrole: live.subrole, title: live.title, description: live.description,
                                      value: live.value, help: live.help)
        if !listedName.text.isEmpty && liveName.text.isEmpty { return .refuse("The control has lost its name, so I did nothing.") }
        if listedName.source != liveName.source
            || normalise(listedName.text).lowercased() != normalise(liveName.text).lowercased() {
            return .refuse("The control's name changed, so I did nothing.")
        }
        return .ok
    }
}
