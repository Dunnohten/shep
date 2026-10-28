import CoreGraphics
import Foundation

/// One control in the front window, as read from Accessibility or found on a screenshot.
/// Frames are global screen points with a top-left origin (the space AX, CGWindowList and CGEvent share).
public struct Control: Equatable, Sendable {
    public var index: Int
    public var role: String
    public var subrole: String
    public var title: String
    public var description: String
    public var value: String?
    public var help: String
    public var frame: CGRect?
    public var enabled: Bool
    public var actions: [String]
    /// Stable id inside one snapshot: child indexes from the window, e.g. "0/3/1". Vision-found controls use "v<n>".
    public var pathID: String
    public var window: String
    /// Subrole of the window this control was read from (AXDialog, AXSheet, AXStandardWindow...); empty when unknown.
    public var windowSubrole: String = ""
    /// False for a control read from a dialog or sheet in front of the target window. Its value never goes into a model prompt.
    public var inTargetWindow: Bool = true
    /// True when found on the screenshot, not in the app's Accessibility tree. Such a control can only be clicked by
    /// coordinates, and that always waits for an explicit approval.
    public var fromVision: Bool

    public init(index: Int = 0, role: String, subrole: String = "", title: String = "", description: String = "",
                window: String = "", value: String? = nil, help: String = "", frame: CGRect? = nil, enabled: Bool = true,
                actions: [String] = [], pathID: String = "", fromVision: Bool = false) {
        self.index = index; self.role = role; self.subrole = subrole; self.title = title; self.description = description
        self.value = value; self.help = help; self.frame = frame; self.enabled = enabled; self.actions = actions
        self.pathID = pathID; self.window = window; self.fromVision = fromVision
    }

    /// Where `label` comes from.
    public enum LabelSource: String, Equatable, Sendable {
        case title, description, value, tooltip, none
    }

    private static func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "" : String(t.replacingOccurrences(of: "\n", with: " ").prefix(80))
    }

    /// Title, else description, else (plain text only) its value, else the tooltip (AXHelp), lowest priority.
    private var resolvedLabel: (text: String, source: LabelSource) {
        let t = Control.clean(title)
        if !t.isEmpty { return (t, .title) }
        let d = Control.clean(description)
        if !d.isEmpty { return (d, .description) }
        // A checkbox's value is "0" or "1", so only static text is named by what it says.
        if role == "AXStaticText", !isSecure, let v = value {
            let x = Control.clean(v)
            if !x.isEmpty { return (x, .value) }
        }
        let h = Control.clean(help)
        if !h.isEmpty { return (h, .tooltip) }
        return ("", .none)
    }

    /// The name a person would use: title, else description, else the value of a short text, else the tooltip.
    public var label: String { resolvedLabel.text }

    /// Which attribute `label` came from; `.tooltip` means the control has no name of its own and a hover tip names it.
    public var labelSource: LabelSource { resolvedLabel.source }

    public func renumbered(_ n: Int) -> Control {
        var c = self
        c.index = n
        return c
    }

    public var kind: String {
        switch role {
        case "AXButton": return "button"
        case "AXMenuItem", "AXMenuBarItem": return "menu item"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "option"
        case "AXPopUpButton", "AXMenuButton": return "pop-up"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return "text field"
        case "AXTab", "AXTabGroup": return "tab"
        case "AXLink": return "link"
        case "AXSlider": return "slider"
        case "AXStaticText": return "text"
        default: return role.replacingOccurrences(of: "AX", with: "").lowercased()
        }
    }

    public var isSecure: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
    public var isTextInput: Bool { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) && !isSecure }

    /// One line for lists and prompts. Never includes the value of a secure field.
    public var line: String {
        var s = "#\(index) \(kind) \"\(label)\""
        if !window.isEmpty { s += " in window \"\(window)\"" }
        if !isSecure, inTargetWindow, let v = value, !v.isEmpty { s += " value=\"\(v.prefix(40))\"" }
        if !enabled { s += " (disabled)" }
        if labelSource == .tooltip { s += " (named by its tooltip)" }
        if fromVision { s += " (found on screen)" }
        return s
    }
}
