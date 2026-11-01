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
/// Only the setup window's header uses it now; Shep's home in the menu bar is the native HomePanel.
/// Swift talks to the page through the `house` bridge: setTheme, setMode, setActive, setReduceMotion.
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

/// The doghouse as a header inside a SwiftUI window (setup), with Shep asleep in it. Decorative for VoiceOver: the label says
/// what it is and the window's own controls carry the meaning.
struct HouseHeaderView: NSViewRepresentable {
    var themeName: String

    func makeNSView(context: Context) -> NSView {
        let view = HouseWebView()
        view.setTheme(themeName)
        view.setMode(.asleep)
        view.frame = NSRect(x: 0, y: 0, width: HomeGeometry.headerSize.width, height: HomeGeometry.headerSize.height)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Shep's doghouse, with Shep asleep inside")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HouseWebView)?.setTheme(themeName)
    }
}
