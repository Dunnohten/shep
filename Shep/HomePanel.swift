import AppKit
import ShepCore

// Written for Shep.

/// Shep's home: a slim chin under the menu bar exactly as wide as the notch, or a small pill hanging from the menu bar at the
/// top centre of a screen without a notch. It shows a paw and one status mark (asleep, waking, out, heading to sleep). It is
/// click-through: it never takes a click from the window or title bar under it. Shep is called from the status item menu, the
/// shortcut and the other call inputs; for VoiceOver the indicator is still a button whose press calls Shep.
@MainActor
final class HomeIndicatorView: NSView {
    var onPress: (() -> Void)?
    static let label = "Shep's home"

    private let effect = NSVisualEffectView()
    private let solid = NSView()
    private let paw = NSImageView()
    private let status = NSImageView()
    private let outline = CAShapeLayer()
    private var kind = HomeKind.notch
    private var mode = HouseMode.asleep
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var fullStrengthSymbols = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        solid.wantsLayer = true
        outline.fillColor = nil
        for icon in [paw, status] {
            icon.imageScaling = .scaleProportionallyDown
            icon.contentTintColor = .white
            icon.wantsLayer = true
            icon.setAccessibilityElement(false)
            icon.cell?.setAccessibilityElement(false)
        }
        addSubview(effect)
        addSubview(solid)
        addSubview(paw)
        addSubview(status)
        layer?.addSublayer(outline)
        applyMode(animated: false)
        updateSurface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: state

    /// Whether a change of state is posted to VoiceOver now (set by ShepCoordinator from `AnnouncementGate`).
    var postsChanges: () -> Bool = { true }

    func setMode(_ new: HouseMode) {
        guard new != mode else { return }
        mode = new
        applyMode(animated: true)
        // VoiceOver speaks this from the doghouse even while its cursor is elsewhere: not over the caller's question.
        if postsChanges() { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    func setReduceMotion(_ on: Bool) { reduceMotion = on }

    /// The shape and the icon slots for a placement: the chin is solid black (it has to match the hardware above it),
    /// a pill under the menu bar is a dark material, or solid dark under Reduce Transparency.
    func configure(kind: HomeKind, size: CGSize) {
        self.kind = kind
        frame.size = size
        let r = kind == .notch ? HomeGeometry.notchCornerRadius : HomeGeometry.topCenterCornerRadius
        let path = Self.shape(size: size, cornerRadius: r)
        let mask = CAShapeLayer()
        mask.path = path
        layer?.mask = mask
        outline.path = path
        outline.frame = bounds
        effect.frame = bounds
        solid.frame = bounds
        let slots = HomeGeometry.iconSlots(kind: kind, size: size)
        paw.frame = slots.left
        status.frame = slots.right
        applyMode(animated: false)
        updateSurface()
    }

    /// Flat top (it is flush with the bar or the notch), rounded lower corners only. y runs down in this view, like the hit shape.
    private static func shape(size: CGSize, cornerRadius r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: size.width, y: 0))
        p.addLine(to: CGPoint(x: size.width, y: size.height - r))
        p.addQuadCurve(to: CGPoint(x: size.width - r, y: size.height), control: CGPoint(x: size.width, y: size.height))
        p.addLine(to: CGPoint(x: r, y: size.height))
        p.addQuadCurve(to: CGPoint(x: 0, y: size.height - r), control: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }

    /// Reduce Transparency: solid. Increase Contrast: a stronger outline and full-strength symbols.
    func updateSurface() {
        let style = SurfaceStyle.resolve(reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                                         increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let notch = kind == .notch
        effect.isHidden = notch || style.solid
        solid.isHidden = !(notch || style.solid)
        solid.layer?.backgroundColor = (notch ? NSColor.black : NSColor(white: 0.11, alpha: 1)).cgColor
        outline.isHidden = notch && style.borderStrength == 0
        outline.strokeColor = NSColor.white.withAlphaComponent(style.borderStrength > 0 ? CGFloat(style.borderStrength) : 0.14).cgColor
        outline.lineWidth = style.borderWidth
        fullStrengthSymbols = style.fullStrengthSymbols
        applyMode(animated: false)
    }

    private func applyMode(animated: Bool) {
        let state = HomeIndicatorState.state(for: mode)
        let size = kind == .notch ? HomeGeometry.notchIconSize : HomeGeometry.topCenterIconSize
        let config = NSImage.SymbolConfiguration(pointSize: size - 3, weight: .medium)
        if animated {
            let t = CATransition()
            t.type = .fade
            t.duration = state.fadeSeconds(reduceMotion: reduceMotion)
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            paw.layer?.add(t, forKey: "fade")
            status.layer?.add(t, forKey: "fade")
        }
        paw.image = NSImage(systemSymbolName: state.pawSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        status.image = NSImage(systemSymbolName: state.statusSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        paw.alphaValue = fullStrengthSymbols ? 1 : state.pawAlpha
        status.alphaValue = fullStrengthSymbols ? 1 : max(state.pawAlpha - 0.1, 0.5)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    // MARK: accessibility (the panel ignores the mouse; VoiceOver reaches the indicator through the accessibility tree)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { Self.label }
    override func accessibilityValue() -> Any? { HomeIndicatorState.state(for: mode).accessibilityValue }
    override func accessibilityHelp() -> String? { "Press to call Shep and send it to the window in front. The shortcut and the Call Shep menu item do the same." }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
    /// A leaf: the paw and status images are drawing only. Without this VoiceOver lands on "Pawprint, image" inside the button.
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityChildrenInNavigationOrder() -> [NSAccessibilityElementProtocol]? { [] }
}

/// Small, non-activating panel that holds the indicator, just under the menu bar (the chin under the notch, or the pill at the
/// top centre). On every Space; click-through, never key, never main.
@MainActor
final class HomePanel: NSPanel {
    let indicator = HomeIndicatorView(frame: .zero)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The chin must be exactly as black as the hardware above it; a pill under the bar is a little dimmer.
    static func restingAlpha(for kind: HomeKind) -> CGFloat { HomeGeometry.restingAlpha(for: kind) }

    /// A borderless panel is not nudged back below the menu bar: the indicator sits in it on purpose.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    init() {
        let size = NSSize(width: HomeGeometry.topCenterSize.width, height: HomeGeometry.topCenterSize.height)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .floating
        // No fullScreenAuxiliary: in a full-screen Space there is no menu bar, and the indicator stays out of the app's way.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = !HomeGeometry.takesMouse(kind: .notch)
        sharingType = ScreenPrivacy.sharingType
        indicator.frame = NSRect(origin: .zero, size: size)
        indicator.autoresizingMask = [.width, .height]
        contentView = indicator
        setAccessibilityLabel(HomeIndicatorView.label)
    }

    /// Takes a placement: its frame, its kind's level and strength, and the indicator's shape.
    func apply(_ placement: HomePlacement) {
        ignoresMouseEvents = !HomeGeometry.takesMouse(kind: placement.kind)
        alphaValue = Self.restingAlpha(for: placement.kind)
        if frame != placement.rect { setFrame(placement.rect, display: true) }
        indicator.configure(kind: placement.kind, size: placement.rect.size)
    }
}
