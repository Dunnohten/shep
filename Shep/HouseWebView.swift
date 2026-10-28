import AppKit
import ShepCore
import SwiftUI
import WebKit

/// Receives `webkit.messageHandlers.house` posts from the doghouse page.
@MainActor
private final class HouseMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: HouseWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["ready"] as? Bool == true { owner?.pageBecameReady() }
        if let error = body["error"] as? String { print("[shep] house page error: \(error)") }
    }
}

/// The doghouse in a transparent WKWebView (Resources/shep-dog/house.html): a goop-style house with Shep asleep in the door.
/// Swift talks to the page through the `house` bridge: setTheme, setMode, setActive, setReduceMotion. The page itself runs
/// at 8 fps asleep, 30 while waking or curling up, and not at all when away or paused.
@MainActor
final class HouseWebView: WKWebView, WKNavigationDelegate {
    private let proxy: HouseMessageProxy
    private var pageLoaded = false
    private var pending: [String] = []

    init() {
        let config = WKWebViewConfiguration()
        let proxy = HouseMessageProxy()
        config.userContentController.add(proxy, name: "house")
        self.proxy = proxy
        super.init(frame: .zero, configuration: config)
        proxy.owner = self
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
        navigationDelegate = self
        if let url = Bundle.main.url(forResource: "house", withExtension: "html", subdirectory: "shep-dog") {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            print("[shep] ERROR: Resources/shep-dog/house.html is missing from the app bundle")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTheme(_ name: String) { run("house.setTheme(\(JSLiteral.string(name)))") }
    func setMode(_ mode: HouseMode) { run("house.setMode(\(JSLiteral.string(mode.rawValue)))") }
    func setPose(_ name: PoseName, reduceMotion: Bool) { run("house.setPose(\(PoseBridge.json(for: name, reduceMotion: reduceMotion)))") }
    func setActive(_ on: Bool) { run("house.setActive(\(on ? "true" : "false"))") }
    func setReduceMotion(_ on: Bool) { run("house.setReduceMotion(\(on ? "true" : "false"))") }

    private func run(_ js: String) {
        let guarded = "if (window.house) { \(js) }"
        if pageLoaded { evaluateJavaScript(guarded, completionHandler: nil) } else { pending.append(guarded) }
    }

    fileprivate func pageBecameReady() {
        guard !pageLoaded else { return }
        pageLoaded = true
        for js in pending { evaluateJavaScript(js, completionHandler: nil) }
        pending.removeAll()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        evaluateJavaScript("!!window.house") { [weak self] value, _ in
            if value as? Bool == true { self?.pageBecameReady() }
        }
    }
}

/// The doghouse's accessibility face and hit shape. One element: a button. Only the house itself (roof and body) takes the
/// mouse; the transparent rest of the panel returns nil from the hit test, so it never swallows a click meant for the app below.
@MainActor
final class HouseContainerView: NSView {
    var onPress: (() -> Void)?
    static let label = "Shep's doghouse, click to call Shep"

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { Self.label }
    override func accessibilityHelp() -> String? { "Wakes Shep and sends it to the window in front. The shortcut and the Call Shep menu item do the same." }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `point` is in the superview's coordinates; the art's space is top-left origin.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let art = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        return HomeGeometry.isOnHouse(art) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }
}

/// The doghouse as a header inside a SwiftUI window (setup), with Shep asleep in it. Decorative for VoiceOver: the label says
/// what it is and the window's own controls carry the meaning.
struct HouseHeaderView: NSViewRepresentable {
    var themeName: String

    func makeNSView(context: Context) -> NSView {
        let view = HouseWebView()
        view.setTheme(themeName)
        view.setMode(.asleep)
        view.frame = NSRect(x: 0, y: 0, width: HomeGeometry.size.width, height: HomeGeometry.size.height)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Shep's doghouse, with Shep asleep inside")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HouseWebView)?.setTheme(themeName)
    }
}

/// Small, dim, non-activating panel that holds the doghouse: below the notch, or under Shep's status item, on every Space.
@MainActor
final class HomePanel: NSPanel {
    let house = HouseWebView()
    let container = HouseContainerView()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Out of the way: the doghouse is at 70 % until it is needed.
    static let dimAlpha: CGFloat = 0.7

    init() {
        let size = NSSize(width: HomeGeometry.size.width, height: HomeGeometry.size.height)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .floating
        // No fullScreenAuxiliary: in a full-screen Space there is no menu bar, and the house stays out of the app's way.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        alphaValue = Self.dimAlpha
        sharingType = ScreenPrivacy.sharingType
        container.frame = NSRect(origin: .zero, size: size)
        container.autoresizingMask = [.width, .height]
        house.frame = container.bounds
        house.autoresizingMask = [.width, .height]
        container.addSubview(house)
        contentView = container
        setAccessibilityLabel(HouseContainerView.label)
    }
}
