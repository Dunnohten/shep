import AppKit
import ShepCore

// Written for Shep.

/// Shows one card at a time beside Shep's tab. OverlayController owns the meaning of what is on it (an approval waits for an
/// answer, the ask field waits for a request); this class owns the window: placing it from the dog panel's layout, fading it in
/// and out, the reply's timer, and keyboard focus.
@MainActor
final class CardController {
    let panel = CardPanel()
    private let view = CardView(frame: .zero)
    private(set) var model: CardModel?
    private var layout: PanelLayout?
    private var expiry: DispatchWorkItem?
    private var generation = 0
    /// True from the start of a fade-out until it ends or is overtaken; the window still says it is visible meanwhile.
    private var fadingOut = false
    /// The height the current card needs, measured when it was shown; a move of the dock only moves the card.
    private var contentHeight: CGFloat = CardGeometry.minHeight
    private var observer: NSObjectProtocol?
    /// The current card keeps the keyboard although its kind does not take it (`show(_:layout:keepKey:)`).
    private var keepKey = false

    /// An approval button was pressed.
    var onChoice: ((String) -> Void)? { didSet { view.onChoice = onChoice } }
    /// The ask field sent a request (trimmed, never empty).
    var onSubmit: ((String) -> Void)? { didSet { view.onSubmit = onSubmit } }
    /// Escape, or Return on an empty ask field.
    var onCancel: (() -> Void)? {
        didSet {
            view.onCancel = onCancel
            panel.onEscape = { [weak self] in
                guard let self, self.model?.kind.escapeResult != CardEscapeResult.none else { return }
                self.onCancel?()
            }
        }
    }
    /// A reply's time ran out.
    var onExpired: (() -> Void)?

    init() {
        panel.contentView = view
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAfterAccessibilityChange() }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var isShown: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    /// Fade and slide times for the current Reduce Motion setting.
    private var timing: CardTiming { CardTiming.resolve(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }

    /// Shows `model`, replacing whatever card is up. Without a layout (no dock yet) the card is kept and appears with the dock.
    /// `keepKey`: the card keeps the keyboard even though this kind does not take it (the result after Approve, under VoiceOver).
    func show(_ model: CardModel, layout: PanelLayout?, keepKey: Bool = false) {
        expiry?.cancel()
        expiry = nil
        generation += 1
        self.model = model
        self.layout = layout
        self.keepKey = keepKey
        panel.takesKey = model.kind.takesKey || keepKey
        panel.ignoresMouseEvents = !model.kind.takesKey   // a reply never swallows a click meant for the window under it
        panel.title = model.accessibilityTitle
        panel.setAccessibilityLabel(model.accessibilityTitle)
        if let seconds = model.autoHideSeconds {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hide(animated: true)
                    self.onExpired?()
                }
            }
            expiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        present(isRefresh: false)
    }

    /// The dock moved, or came back: the card follows its layout. `nil` (no dock) takes the card off screen but keeps it.
    func place(_ layout: PanelLayout?) {
        self.layout = layout
        guard model != nil else { return }
        if layout == nil { panel.orderOut(nil); return }
        if panel.isVisible && !fadingOut { reposition() } else { present(isRefresh: true) }
    }

    /// Closes the card. A card that took the keyboard goes at once (so key status leaves with it); a reply and the transcript fade.
    func hide(animated: Bool = false) {
        expiry?.cancel()
        expiry = nil
        generation += 1
        let wasKey = (model?.kind.takesKey ?? false) || keepKey
        model = nil
        keepKey = false
        guard panel.isVisible else { fadingOut = false; return }
        if animated, !wasKey {
            let mine = generation
            fadingOut = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = timing.fadeOut
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == mine else { return }
                    self.fadingOut = false
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                }
            })
        } else {
            fadingOut = false
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    // MARK: placing

    /// `isRefresh`: the same card laid out again (the dock came back), as opposed to a new one.
    private func present(isRefresh: Bool) {
        guard let model, let layout else { return }
        let keepTyping = CardModel.keepsTyping(previous: view.shownKind, next: model.kind, isRefresh: isRefresh)
        contentHeight = view.configure(model, width: layout.bubbleFrame.width, maxHeight: layout.bubbleFrame.height, keepTyping: keepTyping)
        let target = CardGeometry.frame(in: layout, contentHeight: contentHeight)
        // A window that is fading out still reports itself visible: it arrives fresh (alpha 0, then a fade-in that replaces the fade-out).
        let fresh = CardPresence.resolve(isVisible: panel.isVisible, fadingOut: fadingOut).arrivesFresh
        fadingOut = false
        if fresh {
            let t = timing
            let toward: CGFloat = layout.bubbleBelow ? -t.slide : t.slide   // from the tab, toward its place
            panel.setFrame(t.slide == 0 ? target : target.offsetBy(dx: 0, dy: -toward), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = t.fadeIn
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
                if t.slide != 0 { panel.animator().setFrame(target, display: true) }
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.invalidateShadow()
        if model.kind.takesKey || keepKey {
            panel.makeKey()
            if let focus = view.initialFocus { panel.makeFirstResponder(focus) }
        }
    }

    /// Moves the card with its dock. The content is left alone, so a request being typed survives a move of the window.
    private func reposition() {
        guard model != nil, let layout else { return }
        let target = CardGeometry.frame(in: layout, contentHeight: contentHeight)
        if panel.frame != target { panel.setFrame(target, display: true) }
    }

    private func refreshAfterAccessibilityChange() {
        view.updateSurface()
    }
}
