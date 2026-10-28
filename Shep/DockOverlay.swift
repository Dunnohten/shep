import AppKit
import ShepCore

/// The dog's accessibility face. While the ask field is closed the whole dog is ONE element: a button called
/// "Shep, assistant" that opens the ask field. While it is open the page's own controls (field, buttons) are exposed instead.
@MainActor
final class DogContainerView: NSView {
    var onPress: (() -> Void)?
    /// The dog's frame in screen coordinates, so VoiceOver's cursor sits on the dog and not on the whole panel.
    var dogScreenFrame = NSRect.zero
    var pageControlsExposed = false

    override func isAccessibilityElement() -> Bool { !pageControlsExposed }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Shep, assistant" }
    override func accessibilityHelp() -> String? { "Opens the ask field. Shep's replies are announced." }
    override func accessibilityFrame() -> NSRect { dogScreenFrame == .zero ? super.accessibilityFrame() : dogScreenFrame }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The tab itself, drawn natively behind the dog's web view: a fill in the title bar's colour and a hairline outline
/// that is open along the base, so the tab fuses with the bar and reads as part of the window chrome.
@MainActor
final class TabShapeView: NSView {
    private let fillLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fillLayer.strokeColor = nil
        strokeLayer.fillColor = nil
        strokeLayer.lineJoin = .round
        strokeLayer.lineCap = .butt
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(strokeLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Never takes the mouse: the web view above it and the panel's own hit rules decide.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `frame` is the tab's rectangle in the panel (AppKit coordinates, bottom-left origin).
    /// The fill runs `overlap` points past the base (into the title bar) so the window's own top border does not show
    /// as a line along the base; the hairline outline stays open along the base.
    func update(frame tabFrame: CGRect, style: TabStyle, path: TabPath, fillHex: String, outline: [Double]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = tabFrame
        let bounds = CGRect(origin: .zero, size: tabFrame.size)
        fillLayer.frame = bounds
        strokeLayer.frame = bounds
        let fillPath = Self.cgPath(path.fill, height: tabFrame.height)
        let overlap: CGFloat = 1
        // Layer space is y up: an `.above` tab has its base at y = 0 (overlap goes below), an `.inside` tab at y = height.
        let baseY: CGFloat = style == .above ? 0 : tabFrame.height
        let extra = CGMutablePath()
        extra.addPath(fillPath)
        extra.addRect(CGRect(x: 0, y: style == .above ? baseY - overlap : baseY, width: tabFrame.width, height: overlap))
        fillLayer.path = extra
        strokeLayer.path = Self.cgPath(path.outline, height: tabFrame.height)
        let c = TabAppearance.rgb(hex: fillHex) ?? (r: 0.91, g: 0.91, b: 0.91)
        fillLayer.fillColor = NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1).cgColor
        let o = outline.count == 4 ? outline : [0, 0, 0, 0.18]
        strokeLayer.strokeColor = NSColor(srgbRed: CGFloat(o[0]), green: CGFloat(o[1]), blue: CGFloat(o[2]), alpha: CGFloat(o[3])).cgColor
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        strokeLayer.lineWidth = 1 / scale
        fillLayer.contentsScale = scale
        strokeLayer.contentsScale = scale
        CATransaction.commit()
    }

    /// TabPath has a top-left origin (y down); AppKit layers here are y up, so flip while building.
    private static func cgPath(_ elements: [TabPathElement], height h: CGFloat) -> CGPath {
        let path = CGMutablePath()
        func f(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        for e in elements {
            switch e {
            case .move(let p): path.move(to: f(p))
            case .line(let p): path.addLine(to: f(p))
            case .curve(let to, let c1, let c2): path.addCurve(to: f(to), control1: f(c1), control2: f(c2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// Borderless, non-activating panel that holds the tab on the window's title bar, with the dog in it.
/// It is larger than the tab so the say() card never clips; everything but the tab (and the card while it shows) is
/// click-through (`ignoresMouseEvents`, toggled by OverlayController). It takes key status only while `acceptsTextInput` is true.
@MainActor
final class DockOverlay: NSPanel {
    var acceptsTextInput = false
    /// Set while an approval card shows: Escape cancels it even if the web view does not hand the key to the page.
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { acceptsTextInput }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape {   // 53 = Escape
            onEscape()
            return
        }
        super.sendEvent(event)
    }
    override var canBecomeMain: Bool { false }

    let dogView: DogWebView
    let container: DogContainerView
    let tabView = TabShapeView(frame: .zero)

    init() {
        dogView = DogWebView()
        container = DogContainerView()
        let size = NSSize(width: PanelGeometry.defaultSize.width, height: PanelGeometry.defaultSize.height)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered,
                   defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        sharingType = ScreenPrivacy.sharingType
        container.frame = NSRect(origin: .zero, size: size)
        container.autoresizingMask = [.width, .height]
        dogView.frame = container.bounds
        dogView.autoresizingMask = [.width, .height]
        container.addSubview(tabView)
        container.addSubview(dogView)
        contentView = container
    }
}
