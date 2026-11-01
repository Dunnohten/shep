import CoreGraphics
import Foundation

/// Written for Shep.
/// The cards Shep shows beside its tab: a reply, an approval (Approve / Cancel), the ask field, and what push-to-talk has heard.
/// This is the whole state a card view needs; the view draws it and reports back, nothing else decides what a card says.

public enum CardKind: Equatable {
    case reply, approval, askField, transcript

    /// An approval and the ask field take typed or keyboard input, so their window may become key. A reply and the transcript never do.
    public var takesKey: Bool { self == .approval || self == .askField }

    /// What Escape does on this card.
    public var escapeResult: CardEscapeResult {
        switch self {
        case .approval: return .cancelChoice
        case .askField: return .closeField
        case .reply, .transcript: return .none
        }
    }
}

public enum CardEscapeResult: Equatable {
    case cancelChoice, closeField, none
}

public enum CardButtonRole: Equatable {
    case action, cancel
}

public struct CardButton: Equatable {
    public var id: String
    public var label: String
    public var role: CardButtonRole
    public var accessibilityLabel: String { label }
    public var spec: CardButtonSpec { CardButtonSpec(title: label, id: id, keyEquivalent: CardButtonSpec.keyEquivalent, accessibilityLabel: accessibilityLabel) }
}

/// Everything the card view may use to build one button. The key equivalent is always empty: no card button is the default
/// button, so Return does not approve anything. The view reads this and nothing else.
public struct CardButtonSpec: Equatable {
    public static let keyEquivalent = ""
    public var title: String
    public var id: String
    public var keyEquivalent: String
    public var accessibilityLabel: String
}

/// One thing VoiceOver can land on inside a card: its text, or a button by id.
public enum CardElement: Equatable {
    case text
    case button(String)
}

public enum CardSubmission: Equatable {
    case submit(String)
    case cancel
}

public struct CardModel: Equatable {
    public var kind: CardKind
    public var text: String
    /// The name VoiceOver gives the card ("Shep wants to press Save in TextEdit").
    public var accessibilityTitle: String
    public var buttons: [CardButton]
    /// The safe button (Cancel / Deny): it holds keyboard focus when an approval has no text. Without one it is nil, never Approve.
    public var initialFocusID: String?
    public var autoHideSeconds: Double?
    /// What VoiceOver is told once when the card appears; nil when nothing should be announced.
    public var announcement: String?
    /// Where the VoiceOver cursor goes when the card appears (separate from keyboard focus): the text of an approval, so the
    /// question is read first; the safe button when there is no text; never Approve. Nil: VoiceOver is not moved.
    public var initialVoiceOverFocus: CardElement? = nil
    /// What takes keyboard focus when the card opens: the text of an approval (VoiceOver follows keyboard focus, so it reads
    /// the question first; Return and Space do nothing on text), else the safe button `initialFocusID`. Never Approve.
    public var initialKeyboardFocus: CardElement? = nil
    /// The order VoiceOver walks the card's elements (VO-Right): the text, then the buttons as shown, left to right.
    public var accessibilityOrder: [CardElement] = []

    public static let fallbackTitle = "Shep needs your approval"
    public static let minimumReplySeconds = 1.5
    public static let maxTextLength = 2000

    public static func approval(text: String, choices: [(id: String, label: String)], title: String) -> CardModel {
        let shown = String(text.prefix(maxTextLength))
        let buttons = choices.compactMap { c -> CardButton? in
            let label = c.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            return CardButton(id: c.id, label: label, role: c.id == "cancel" ? .cancel : .action)
        }
        let name = nonEmpty(title) ?? nonEmpty(shown.components(separatedBy: "\n").first ?? "") ?? fallbackTitle
        let focus = buttons.first(where: { $0.role == .cancel })?.id
        let hasText = nonEmpty(shown) != nil
        let order: [CardElement] = (hasText ? [.text] : []) + buttons.map { .button($0.id) }
        // The VoiceOver cursor lands on the text and reads it; that is the card's one spoken line (no second announcement
        // talking over it). Keyboard focus stays on the cancel button, so a stray Return or Space never approves.
        let voiceOverFocus: CardElement? = hasText ? .text : focus.map { .button($0) }
        return CardModel(kind: .approval, text: shown, accessibilityTitle: name, buttons: buttons, initialFocusID: focus,
                         autoHideSeconds: nil, announcement: nil, initialVoiceOverFocus: voiceOverFocus,
                         initialKeyboardFocus: voiceOverFocus, accessibilityOrder: order)
    }

    public static func reply(_ text: String, milliseconds: Int) -> CardModel {
        let shown = String(text.prefix(maxTextLength))
        return CardModel(kind: .reply, text: shown, accessibilityTitle: "Shep", buttons: [], initialFocusID: nil,
                         autoHideSeconds: max(Double(milliseconds) / 1000, minimumReplySeconds), announcement: shown,
                         accessibilityOrder: [.text])
    }

    public static var askField: CardModel {
        CardModel(kind: .askField, text: "", accessibilityTitle: "Ask Shep", buttons: [], initialFocusID: nil, autoHideSeconds: nil, announcement: nil)
    }

    public static func transcript(_ text: String) -> CardModel {
        CardModel(kind: .transcript, text: String(text.prefix(maxTextLength)), accessibilityTitle: "What Shep heard", buttons: [], initialFocusID: nil,
                  autoHideSeconds: nil, announcement: nil)
    }

    /// What the ask field sends on Return: the trimmed text, or a cancel when it is empty.
    public static func submission(from text: String) -> CardSubmission {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? .cancel : .submit(t)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Where a card goes, from the dog panel's layout: the card keeps the bubble area's near edge (under the title bar, or on top
/// of the tab when there was no room below) and is only as tall as its content, inside the room the layout reserved.
public enum CardGeometry {
    public static let minHeight: CGFloat = 36

    public static func frame(in layout: PanelLayout, contentHeight: CGFloat) -> CGRect {
        let area = layout.bubbleFrame
        let wanted = contentHeight.isFinite ? contentHeight : minHeight
        let height = min(max(wanted, minHeight), area.height)
        let y = layout.bubbleBelow ? area.maxY - height : area.minY
        return CGRect(x: area.minX, y: y, width: area.width, height: height)
    }
}

/// Whether a card window is on screen, on its way out, or gone. A window that is fading out still reports itself visible, so a
/// card shown during the fade has to be treated as arriving fresh (alpha back up through a fade-in), or it would stay invisible.
public enum CardPresence: Equatable {
    case hidden, shown, fadingOut

    public static func resolve(isVisible: Bool, fadingOut: Bool) -> CardPresence {
        guard isVisible else { return .hidden }
        return fadingOut ? .fadingOut : .shown
    }

    /// True when a card that is about to show must start from alpha 0 and fade in.
    public var arrivesFresh: Bool { self != .shown }
}

extension CardModel {
    /// Typing survives a re-layout of the same ask field (its window was lost and found again), never a new card.
    public static func keepsTyping(previous: CardKind?, next: CardKind, isRefresh: Bool) -> Bool {
        isRefresh && next == .askField && previous == .askField
    }
}
