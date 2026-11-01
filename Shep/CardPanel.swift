import AppKit
import ShepCore

// Written for Shep.

/// The window a card lives in: borderless, floating on every Space, never activates Shep. It becomes key only while the card
/// takes input (an approval, the ask field); a reply and the transcript are click-through and never key.
@MainActor
final class CardPanel: NSPanel {
    var takesKey = false
    /// Escape, wherever the keyboard focus is inside the card.
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { takesKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape {   // 53 = Escape
            onEscape()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? { takesKey ? .dialog : super.accessibilitySubrole() }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelGeometry.panelWidth, height: CardGeometry.minHeight),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        sharingType = ScreenPrivacy.sharingType
    }
}

/// The card's text. On an approval it can hold keyboard focus (`takesFocus`) without being editable or selectable.
@MainActor
final class CardLabel: NSTextField {
    var takesFocus = false
    override var acceptsFirstResponder: Bool { takesFocus || super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { takesFocus || super.canBecomeKeyView }
}

/// The card's face: a material (or a solid colour under Reduce Transparency), a hairline, and the content for one `CardModel`.
/// Frames are laid out by hand, top-down, so the height the card needs is known before it is shown.
@MainActor
final class CardView: NSView, NSTextFieldDelegate {
    static let padding: CGFloat = 14
    static let rowGap: CGFloat = 10
    static let buttonHeight: CGFloat = 28
    static let fieldHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 10
    static let font = NSFont.systemFont(ofSize: 13)

    /// The snapshot harness draws the solid fallback (a material needs a live backdrop).
    static var forceSolidSurface = false

    var onChoice: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// What should hold keyboard focus once the card is key: Cancel on an approval, the field on the ask field.
    private(set) var initialFocus: NSView?
    /// Where the VoiceOver cursor goes once the card shows (`CardModel.initialVoiceOverFocus`): the text of an approval.
    private(set) var initialVoiceOverElement: NSView?
    /// The card's text as VoiceOver meets it: the label, or the scroll view holding it.
    private var textElement: NSView?

    private let effect = NSVisualEffectView()
    private let solid = NSView()
    private let label = CardLabel(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let icon = NSImageView()
    private let field = NSTextField()
    private var buttons: [(id: String, view: NSButton)] = []
    private var model: CardModel?
    /// The kind of card last laid out; nil until the first one.
    var shownKind: CardKind? { model?.kind }
    private var maxHeight: CGFloat = 150

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        solid.wantsLayer = true
        addSubview(effect)
        addSubview(solid)
        label.font = Self.font
        label.textColor = .labelColor
        label.isSelectable = true
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        field.placeholderString = "Ask Shep"
        field.font = Self.font
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.delegate = self
        field.target = self
        field.action = #selector(fieldReturned)
        icon.contentTintColor = .secondaryLabelColor
        updateSurface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: surface

    /// Reduce Transparency: a solid window colour instead of the material. Increase Contrast: a stronger outline.
    func updateSurface() {
        let style = SurfaceStyle.resolve(reduceTransparency: Self.forceSolidSurface || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                                         increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        effect.isHidden = style.solid
        solid.isHidden = !style.solid
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = (style.borderStrength > 0 ? NSColor.labelColor.withAlphaComponent(CGFloat(style.borderStrength)) : NSColor.separatorColor).cgColor
        }
        layer?.borderWidth = style.borderWidth
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    // MARK: content

    /// Lays the card out for `model` at `width` and returns the height it needs, at most `maxHeight` (a longer text scrolls).
    @discardableResult
    func configure(_ model: CardModel, width: CGFloat, maxHeight: CGFloat, keepTyping: Bool = false) -> CGFloat {
        self.model = model
        self.maxHeight = maxHeight
        for sub in subviews where sub !== effect && sub !== solid { sub.removeFromSuperview() }
        buttons.removeAll()
        initialFocus = nil
        initialVoiceOverElement = nil
        textElement = nil
        let pad = Self.padding
        let inner = width - 2 * pad
        var y = pad
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(model.accessibilityTitle)

        switch model.kind {
        case .reply, .approval, .transcript:
            let isTranscript = model.kind == .transcript
            let text = isTranscript && model.text.isEmpty ? "Listening" : model.text
            label.stringValue = text
            // On an approval the text takes keyboard focus (VoiceOver follows it and reads the question). It is not selectable
            // there, so focus stays on the text itself rather than in a field editor, and Return or Space do nothing.
            label.takesFocus = model.initialKeyboardFocus == .text
            label.isSelectable = !label.takesFocus
            label.setAccessibilityHelp(nil)   // VoiceOver already speaks the dialog's name as it enters the card (checked live)
            label.textColor = isTranscript ? .secondaryLabelColor : .labelColor
            var x = pad
            var textWidth = inner
            if isTranscript {
                icon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                icon.frame = NSRect(x: pad, y: y + 1, width: 16, height: 16)
                icon.setAccessibilityElement(false)
                addSubview(icon)
                x += 22
                textWidth -= 22
            }
            let natural = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 16)
            let buttonsHeight: CGFloat = model.buttons.isEmpty ? 0 : Self.rowGap + Self.buttonHeight
            let room = max(maxHeight - 2 * pad - buttonsHeight, 18)
            let textHeight = min(natural, room)
            if natural > room {
                label.frame = NSRect(x: 0, y: 0, width: textWidth - 14, height: natural)
                scroll.frame = NSRect(x: x, y: y, width: textWidth, height: textHeight)
                scroll.documentView = label
                scroll.setAccessibilityLabel(model.accessibilityTitle + ", text")
                // On an approval the text itself is the VoiceOver stop (read first, then VO-Right to Approve), so the scroll
                // view steps out of the way instead of being one more container between them.
                scroll.setAccessibilityElement(model.kind != .approval)
                addSubview(scroll)
                textElement = label
            } else {
                label.frame = NSRect(x: x, y: y, width: textWidth, height: textHeight)
                addSubview(label)
                textElement = label
            }
            y += textHeight
            if !model.buttons.isEmpty {
                y += Self.rowGap
                layoutButtons(model, rightEdge: width - pad, y: y)
                y += Self.buttonHeight
            }
        case .askField:
            if !keepTyping { field.stringValue = "" }
            field.frame = NSRect(x: pad, y: y, width: inner, height: Self.fieldHeight)
            field.setAccessibilityLabel("Ask Shep")
            field.setAccessibilityHelp("Type what you want done in the window in front, then press Return. Escape closes it.")
            addSubview(field)
            initialFocus = field
            y += Self.fieldHeight
        }
        initialVoiceOverElement = element(model.initialVoiceOverFocus)
        if model.initialKeyboardFocus == .text, let text = textElement {
            initialFocus = text
            if let first = buttons.first?.view { text.nextKeyView = first; buttons.last?.view.nextKeyView = text }
        }
        let height = min(max(y + pad, CardGeometry.minHeight), maxHeight)
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        effect.frame = bounds
        solid.frame = bounds
        updateSurface()
        return height
    }

    private func element(_ e: CardElement?) -> NSView? {
        switch e {
        case .text?: return textElement   // the text field itself, also when it sits in a scroll view
        case .button(let id)?: return buttons.first { $0.id == id }?.view
        case nil: return nil
        }
    }

    /// VoiceOver walks the card in `CardModel.accessibilityOrder` (the text, then the buttons left to right), not in the order the
    /// subviews were added, so VO-Right from the text reaches Approve and then Deny.
    override func accessibilityChildren() -> [Any]? {
        guard let order = model?.accessibilityOrder, !order.isEmpty else { return super.accessibilityChildren() }
        let ordered = order.compactMap { element($0) }
        let rest = (super.accessibilityChildren() ?? []).filter { child in !ordered.contains { $0 === (child as AnyObject) } }
        return ordered + rest
    }

    /// The buttons sit at the trailing edge in the order the card gives them. None is the default button: Return does nothing.
    private func layoutButtons(_ model: CardModel, rightEdge: CGFloat, y: CGFloat) {
        var views: [(CardButton, NSButton)] = []
        for b in model.buttons {
            let spec = b.spec
            let button = NSButton(title: spec.title, target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .rounded
            button.keyEquivalent = spec.keyEquivalent
            button.setAccessibilityLabel(spec.accessibilityLabel)
            button.setAccessibilityRole(.button)
            button.identifier = NSUserInterfaceItemIdentifier(spec.id)
            button.sizeToFit()
            views.append((b, button))
        }
        var x = rightEdge
        for (b, button) in views.reversed() {
            let w = max(button.frame.width, 76)
            x -= w
            button.frame = NSRect(x: x, y: y, width: w, height: Self.buttonHeight)
            x -= 8
            addSubview(button)
            buttons.append((b.id, button))
            if b.id == model.initialFocusID { initialFocus = button }
        }
        buttons.reverse()
        // The key-view loop follows the visual order, so Tab goes left to right.
        for i in 0..<buttons.count { buttons[i].view.nextKeyView = buttons[(i + 1) % buttons.count].view }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let id = buttons.first(where: { $0.view === sender })?.id else { return }
        onChoice?(id)
    }

    @objc private func fieldReturned() {
        switch CardModel.submission(from: field.stringValue) {
        case .submit(let text): onSubmit?(text)
        case .cancel: onCancel?()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
