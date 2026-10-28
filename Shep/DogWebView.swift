import AppKit
import ShepCore
import WebKit

/// Receives `webkit.messageHandlers.shep` posts. Held weakly by the web view so the controller is not retained by WebKit.
@MainActor
private final class DogMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: DogWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let parsed = DogMessage.parse(message.body) else { return }
        if parsed == .ready { owner?.pageBecameReady(); return }
        owner?.onMessage?(parsed)
    }
}

/// The bloub goop dog in a transparent WKWebView. Swift talks to the page through the `shep` JS bridge
/// (Resources/shep-dog/index.html): setTheme, setState, say, ask, openPill, closeCard, setLayout, setBar.
@MainActor
final class DogWebView: WKWebView, WKNavigationDelegate {
    var onClick: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    /// The pointer pulled the head out (true) and let it go (false); the page does the stretch and the snap-back.
    var onDrag: ((Bool) -> Void)?
    var onMessage: ((DogMessage) -> Void)?
    /// The tab's rectangle in view coordinates (top-left origin). Only clicks here count as "the dog was clicked";
    /// everything else goes to the page (card buttons, the ask field).
    var dogRect = CGRect.zero

    private let proxy: DogMessageProxy
    /// True once the page has defined `window.shep` (announced by the page with `{ready:true}`, or found by the probe after didFinish).
    private var pageLoaded = false
    private var pendingScripts: [String] = []
    private var lastLayout: PanelLayout?
    private var pressStart: NSPoint?
    private var pulling = false

    init() {
        let config = WKWebViewConfiguration()
        let proxy = DogMessageProxy()
        config.userContentController.add(proxy, name: "shep")
        self.proxy = proxy
        super.init(frame: .zero, configuration: config)
        proxy.owner = self
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
        navigationDelegate = self
        loadDog()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func loadDog() {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "shep-dog") else {
            print("[shep] ERROR: Resources/shep-dog/index.html is missing from the app bundle")
            return
        }
        loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: JS bridge

    func setTheme(_ name: String) { run("shep.setTheme(\(JSLiteral.string(name)))") }
    func setState(_ state: ShepDogState) { run("shep.setState(\(JSLiteral.string(state.rawValue)))") }
    /// Ears, eyes and head tilt: the pose table is ShepCore's `DogPose`; the page springs toward it (static under Reduce Motion).
    func setPose(_ name: PoseName, reduceMotion: Bool) { run("shep.setPose(\(PoseBridge.json(for: name, reduceMotion: reduceMotion)))") }
    func say(_ text: String, milliseconds: Int = 3000) { run("shep.say(\(JSLiteral.string(text)), \(milliseconds))") }
    func setBar(hex: String?) { run("shep.setBar(\(hex.map(JSLiteral.string) ?? "null"))") }
    func openPill() { run("shep.openPill()") }
    /// The pill, read-only, with what push-to-talk has heard so far.
    func showTranscript(_ text: String) { run("shep.showTranscript(\(JSLiteral.string(text)))") }

    // Motion: the page runs one animation loop; these pause it, switch it to the calm fallback, and feed it events.
    func setActive(_ on: Bool) { run("shep.setActive(\(on ? "true" : "false"))") }
    func setReduceMotion(_ on: Bool) { run("shep.setReduceMotion(\(on ? "true" : "false"))") }
    func sendMotion(_ event: DogMotionEvent) { run("shep.send(\(JSLiteral.string(event.rawValue)))") }
    func setPointer(x: Double, y: Double) { run("shep.setPointer(\(String(format: "%.3f", x)), \(String(format: "%.3f", y)))") }
    func drag(dx: Double, dy: Double) { run("shep.drag(\(String(format: "%.1f", dx)), \(String(format: "%.1f", dy)))") }
    func dragEnd() { run("shep.dragEnd()") }
    func pulse() { run("shep.pulse()") }
    /// A little hop: the page lifts the dog `points` and sets it down again over `seconds` (nothing under Reduce Motion).
    func hop(points: Double, seconds: Double) { run("shep.hop(\(String(format: "%.1f", points)), \(String(format: "%.3f", seconds * 1000)))") }
    func blink() { run("shep.blink()") }
    func closeCard() { run("shep.closeCard()") }

    /// The traveller: where the dog sits in this view (top-left origin), with no card.
    func setDogBox(x: Int, y: Int, width: Int, height: Int) {
        run("shep.setLayout(\(x), \(y), \(width), \(height), true)")
    }

    /// Goo-stretch travel: the page stretches the dog along its velocity and fades it, frame by frame, while Swift moves the panel.
    func travel(_ samples: [TravelSample]) {
        guard samples.count >= 2, let last = samples.last else { return }
        let rows = samples.map { s in
            String(format: "[%.4f,%.3f,%.3f,%.2f,%.3f]", s.time, s.along, s.across, s.angleDegrees, s.opacity)
        }.joined(separator: ",")
        run("shep.travel([\(rows)], \(String(format: "%.4f", last.time)))")
    }

    func endTravel() { run("shep.endTravel()") }

    /// A card with buttons; the page posts `{choice: id}` when one is clicked.
    /// `title` names the dialog for VoiceOver ("Shep wants to press Save in TextEdit"); the page moves focus to Approve.
    func ask(_ text: String, choices: [(id: String, label: String)], title: String) {
        let items = choices.map { "{id:\(JSLiteral.string($0.id)),label:\(JSLiteral.string($0.label))}" }.joined(separator: ",")
        run("shep.ask(\(JSLiteral.string(text)), [\(items)], \(JSLiteral.string(title)))")
    }

    func setLayout(_ l: PanelLayout) {
        lastLayout = l
        dogRect = l.tabInPanel   // a click anywhere on the tab counts as a click on the dog
        let r = l.dogInPanel
        // The card hangs from the bottom of the title bar (or sits above the tab when there was no room below).
        let anchor = l.panelFrame.maxY - (l.bubbleBelow ? l.bubbleFrame.maxY : l.bubbleFrame.minY)
        run("shep.setLayout(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height)), \(l.bubbleBelow ? "true" : "false"), \(Int(anchor)))")
    }

    /// Asks the page where it put the dog and compares that with the layout: the page must report `placed` and the dog's
    /// box must be where the layout says (not merely the right size). Anything else re-sends the layout and looks again
    /// (up to 3 times); `report` gets one line per look.
    func verifyLayout(_ l: PanelLayout, after delay: TimeInterval = 1.0, attempt: Int = 1, report: @escaping (String) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.pageLoaded else {
                report("page not ready after \(delay) s (attempt \(attempt))")
                if attempt < 3 { self.probeReady(); self.verifyLayout(l, after: 1.0, attempt: attempt + 1, report: report) }
                return
            }
            self.evaluateJavaScript("window.shep ? JSON.stringify(shep.metrics()) : 'no bridge'") { [weak self] value, error in
                guard let self else { return }
                guard let text = value as? String, let data = text.data(using: .utf8),
                      let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let w = m["dogW"] as? Double, let h = m["dogH"] as? Double,
                      let x = m["dogX"] as? Double, let y = m["dogY"] as? Double else {
                    report("no metrics (\(String(describing: value)) \(error.map { "\($0)" } ?? ""))")
                    return
                }
                let placed = m["placed"] as? Bool ?? false
                let e = l.dogInPanel
                let ok = placed && abs(w - Double(e.width)) < 1.5 && abs(h - Double(e.height)) < 1.5
                    && abs(x - Double(e.minX)) < 2.5 && abs(y - Double(e.minY)) < 2.5   // the page may be mid-spring: a few points slack
                if !ok { self.setLayout(l) }
                report("\(text) expectedDog=\(Int(e.minX)),\(Int(e.minY)) \(Int(e.width))x\(Int(e.height)) "
                    + "dogInTab=\(PanelGeometry.dogIsInsideTab(l) ? "yes" : "NO") \(ok ? "ok" : "MISMATCH, layout re-sent (attempt \(attempt))")")
                if !ok && attempt < 3 { self.verifyLayout(l, after: 0.6, attempt: attempt + 1, report: report) }
            }
        }
    }

    private func run(_ js: String) {
        let guarded = "if (window.shep) { \(js) }"
        if pageLoaded {
            evaluateJavaScript(guarded, completionHandler: nil)
        } else {
            pendingScripts.append(guarded)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        probeReady()
    }

    /// The module script normally runs before didFinish, but a missed `ready` must not leave the dog unplaced: ask.
    private func probeReady() {
        evaluateJavaScript("!!window.shep") { [weak self] value, _ in
            if value as? Bool == true { self?.pageBecameReady() }
        }
    }

    /// Flushes everything that was queued, then sends the newest layout (the page has no layout until it gets one).
    fileprivate func pageBecameReady() {
        let first = !pageLoaded
        pageLoaded = true
        for js in pendingScripts { evaluateJavaScript(js, completionHandler: nil) }
        pendingScripts.removeAll()
        if let l = lastLayout, first { setLayout(l) }
    }

    // MARK: input (the panel never activates the app, so the first click must count)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func isOnDog(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? p.y : bounds.height - p.y
        return dogRect.contains(CGPoint(x: p.x, y: y))
    }

    /// A press on the tab is a click when it ends where it began, a pull of the head when the pointer moves (4 pt or more).
    override func mouseDown(with event: NSEvent) {
        if isOnDog(event) {
            pressStart = event.locationInWindow
            pulling = false
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart else { super.mouseDragged(with: event); return }
        let dx = Double(event.locationInWindow.x - start.x)
        let dy = Double(event.locationInWindow.y - start.y)   // window coordinates point up; the page's y points down
        if !pulling {
            if (dx * dx + dy * dy).squareRoot() < 4 { return }
            pulling = true
            onDrag?(true)
        }
        drag(dx: dx, dy: -dy)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressStart != nil else { super.mouseUp(with: event); return }
        pressStart = nil
        if pulling {
            pulling = false
            dragEnd()
            onDrag?(false)
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if isOnDog(event) { onSecondaryClick?() } else { super.rightMouseDown(with: event) }
    }
}
