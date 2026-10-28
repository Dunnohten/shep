import CoreGraphics
import Foundation

/// Written for Shep.
/// What kind of control a box is. One vocabulary for Accessibility roles, the model's answer and the detector's guess, so
/// "is this worth proposing?" has one answer: static text, images and "other" are never proposed.

public enum ControlRole: String, CaseIterable, Equatable, Sendable {
    case button
    case link
    case tab
    case checkbox
    case textField = "text field"
    case menuItem = "menu item"
    case icon
    case staticText = "static text"
    case image
    case other

    /// The enum the model must pick from (JSON schema), in this order.
    public static var schemaNames: [String] { allCases.map(\.rawValue) }

    /// Static text, images and "other" are context, not something to click.
    public var isProposable: Bool {
        switch self {
        case .staticText, .image, .other: return false
        default: return true
        }
    }

    /// The Accessibility role a found control of this kind is listed with (`VisionRepair.axRole(for:)` goes the same way).
    public var axRole: String {
        switch self {
        case .button, .icon: return "AXButton"
        case .link: return "AXLink"
        case .tab: return "AXTab"
        case .checkbox: return "AXCheckBox"
        case .textField: return "AXTextField"
        case .menuItem: return "AXMenuItem"
        case .staticText: return "AXStaticText"
        case .image: return "AXImage"
        case .other: return "AXUnknown"
        }
    }

    /// From an Accessibility role; nil for roles that say nothing about the kind (groups, windows, scroll areas...).
    public init?(axRole: String) {
        switch axRole {
        case "AXButton", "AXPopUpButton": self = .button
        case "AXLink": self = .link
        case "AXTab": self = .tab
        case "AXCheckBox", "AXRadioButton", "AXSwitch": self = .checkbox
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": self = .textField
        case "AXMenuItem", "AXMenuBarItem", "AXMenuButton": self = .menuItem
        case "AXStaticText": self = .staticText
        case "AXImage": self = .image
        case "AXSlider", "AXUnknown": self = .other
        default: return nil
        }
    }

    /// From the model's (or detector's) words; nil when they are not a role Shep knows. Case, spacing and hyphens are
    /// forgiven and a few synonyms are understood.
    public static func recognized(_ text: String?) -> ControlRole? {
        let t = (text ?? "").lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let exact = ControlRole(rawValue: t) { return exact }
        switch t.replacingOccurrences(of: " ", with: "") {
        case "textfield", "textinput", "input", "field", "searchfield", "textbox", "textarea": return .textField
        case "statictext", "text", "label", "paragraph", "heading", "caption", "title": return .staticText
        case "menu", "menuitem", "popup", "dropdown": return .menuItem
        case "switch", "toggle", "radio", "radiobutton", "checkbox", "checkmark": return .checkbox
        case "picture", "photo", "logo", "illustration", "avatar", "thumbnail": return .image
        case "btn", "pushbutton": return .button
        default: return nil
        }
    }

    /// Anything unrecognised (or missing) is `.other`.
    public init(modelText: String?) {
        self = Self.recognized(modelText) ?? .other
    }
}

public enum RoleSource: String, Equatable, Sendable {
    /// Taken from an Accessibility element the box overlaps.
    case ax
    /// The model's answer, accepted.
    case model
    /// The model's answer, corrected by a rule below.
    case heuristic
}

public struct ResolvedRole: Equatable, Sendable {
    public var role: ControlRole
    public var source: RoleSource
    /// The Accessibility control the box overlaps, when `source == .ax`.
    public var axMatch: Control?
    public init(role: ControlRole, source: RoleSource, axMatch: Control? = nil) {
        self.role = role; self.source = source; self.axMatch = axMatch
    }
}

/// Decides the role of a box the detector found. Pure; frames are global screen points, top-left origin.
public enum RoleResolver {
    /// A box overlapping an Accessibility element at least this much is that element.
    public static let axOverlapIoU = 0.3
    /// Or it sits inside it: this share of the box, with the element no more than `maxContainerRatio` times its area.
    public static let containedFraction = 0.8
    public static let maxContainerRatio = 4.0
    /// Roles that only hold other things: a box inside one is not "that" control.
    public static let containerRoles: Set<String> = [
        "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXToolbar", "AXList", "AXTable", "AXOutline", "AXSheet",
        "AXLayoutArea", "AXWebArea", "AXTabGroup", "AXBrowser", "AXDrawer", "AXRow", "AXColumn",
    ]
    /// Words in a name that say "this is text on the page, not a control".
    public static let staticWords: Set<String> = ["text", "paragraph", "label", "caption", "heading", "title", "description", "body", "copy"]
    /// Words that say "this is an input".
    public static let fieldWords: Set<String> = ["field", "input", "search", "textbox", "editor", "entry", "box", "address", "url", "email", "password", "username"]

    /// The Accessibility control a box stands for: the best overlap (IoU) among non-container elements, or the smallest
    /// element that contains it closely enough.
    public static func axMatch(for frame: CGRect, in ax: [Control]) -> Control? {
        var best: (control: Control, iou: Double)?
        for c in ax {
            guard let f = c.frame, !containerRoles.contains(c.role), f.width > 0, f.height > 0 else { continue }
            let iou = VisionRepair.iou(f, frame)
            var score = iou >= axOverlapIoU ? iou : 0
            if score == 0 {
                let i = f.intersection(frame)
                if !i.isNull, i.width > 0, i.height > 0, frame.width * frame.height > 0 {
                    let inside = Double(i.width * i.height) / Double(frame.width * frame.height)
                    let ratio = Double(f.width * f.height) / Double(frame.width * frame.height)
                    if inside >= containedFraction, ratio <= maxContainerRatio { score = inside * 0.3 }   // contained: below any real IoU match
                }
            }
            if score > 0, score > (best?.iou ?? 0) { best = (c, score) }
        }
        return best?.control
    }

    /// Wide and short: a line of text, a label, a caption.
    public static func isWideShort(_ r: CGRect) -> Bool {
        r.height > 0 && r.width / r.height >= 3.5 && r.height <= 40
    }

    /// Shaped like a text field: one input line tall, clearly wider than tall, not a hairline.
    public static func isFieldLike(_ r: CGRect) -> Bool {
        r.height >= 18 && r.height <= 56 && r.width >= 60 && r.width / r.height >= 2.5 && r.width / r.height <= 30
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    public static func nameLooksStatic(_ name: String) -> Bool { words(name).contains { staticWords.contains($0) } }
    public static func nameHasFieldWord(_ name: String) -> Bool { words(name).contains { fieldWords.contains($0) } }

    /// - Parameters:
    ///   - frame: the box in screen points.
    ///   - modelText: the role the model gave (one of `ControlRole.schemaNames`), if any.
    ///   - name: the name the model gave.
    ///   - ax: the app's own useful controls.
    public static func resolve(frame: CGRect, modelText: String?, name: String, ax: [Control]) -> ResolvedRole {
        // 1. It is an element the app already lists: that element's role wins over any guess.
        if let m = axMatch(for: frame, in: ax), let role = ControlRole(axRole: m.role) {
            return ResolvedRole(role: role, source: .ax, axMatch: m)
        }
        // 2. Vision only: the model's role, then the guards.
        // No role from the model (naming failed or skipped): the detector found something pressable-looking, so call it an icon.
        let trimmed = (modelText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let said: ControlRole = trimmed.isEmpty ? .icon : ControlRole(modelText: trimmed)
        let staticName = nameLooksStatic(name)
        switch said {
        case .textField:
            // Only a field-shaped box that is not described as text on the page is a text field.
            if isFieldLike(frame) && (nameHasFieldWord(name) || !staticName) { return ResolvedRole(role: .textField, source: .model) }
            if isWideShort(frame) || staticName { return ResolvedRole(role: .staticText, source: .heuristic) }
            return ResolvedRole(role: .other, source: .heuristic)
        case .icon, .other, .staticText:
            // A wide, short box the model calls text, a paragraph or a label is static text, not a control.
            if isWideShort(frame) && staticName { return ResolvedRole(role: .staticText, source: said == .staticText ? .model : .heuristic) }
            return ResolvedRole(role: said, source: .model)
        default:
            return ResolvedRole(role: said, source: .model)
        }
    }
}
