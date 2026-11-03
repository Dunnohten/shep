import AppKit
import ShepCore
import WebKit

// Written for Shep.

/// Developer-only: `Shep --ui-snapshot <dir>` renders Shep's own views to PNG files and exits. Nothing is put on screen
/// (the views live in a window that is never ordered in), and nothing is created that listens or watches: no status item,
/// no hotkeys, no microphone, no wake word, no tracker. It never captures the screen. A 20 s timer ends it if a page hangs.
@MainActor
enum UISnapshot {
    static let timeoutSeconds: TimeInterval = 20
    /// Output scale: 2 px per point.
    static let scale: CGFloat = 2

    static func run(outputDirectory: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A material is blended by the window server with what is behind the window; a window that is not on a display has
        // nothing behind it. The snapshots therefore show the solid colours used under Reduce Transparency.
        CardView.forceSolidSurface = true
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            print("[shep] ui-snapshot: timed out after \(Int(timeoutSeconds)) s")
            exit(3)
        }
        Task { @MainActor in
            var failures = 0
            let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                print("[shep] ui-snapshot: cannot create \(outputDirectory): \(error.localizedDescription)")
                exit(1)
            }
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let plain = HomeScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876))
                var made: [(Scene, NSBitmapImageRep?)] = [
                    (.house, renderHome(screen: notchedScreen(), mode: .asleep, appearance: appearance)),
                    (.houseAway, renderHome(screen: notchedScreen(), mode: .away, appearance: appearance)),
                    (.houseNoNotch, renderHome(screen: plain, mode: .asleep, appearance: appearance)),
                ]
                made.append(contentsOf: await renderCards(dark: dark, appearance: appearance))
                for (scene, rep) in made {
                    guard let rep else {
                        print("[shep] ui-snapshot: \(scene.rawValue)-\(mode) failed")
                        failures += 1
                        continue
                    }
                    let url = dir.appendingPathComponent("\(scene.rawValue)-\(mode).png")
                    if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
                        print("[shep] ui-snapshot: wrote \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
                    } else {
                        print("[shep] ui-snapshot: could not write \(url.path)")
                        failures += 1
                    }
                }
            }
            fflush(stdout)
            failures += runChecks()
            exit(failures == 0 ? 0 : 1)
        }
    }

    enum Scene: String, CaseIterable {
        case house, houseAway, houseNoNotch, approval, reply, ask, transcript
    }

    // MARK: scenes

    /// Shep's home on a strip of desktop: the menu bar band, the notch (black, at its real place) when the screen has one, and the
    /// indicator as the app places it.
    private static func renderHome(screen: HomeScreen, mode: HouseMode, appearance: NSAppearance?) -> NSBitmapImageRep? {
        guard let placement = HomeGeometry.place(screens: [screen], statusItem: nil) else { return nil }
        let crop = CGRect(x: (placement.rect.midX - 200).rounded(), y: screen.frame.maxY - 96, width: 400, height: 96)
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        let guides = ProcessInfo.processInfo.environment["SHEP_SNAPSHOT_GUIDES"] == "1"
        let root = SnapshotRoot(frame: CGRect(origin: .zero, size: crop.size), appearance: appearance)
        root.drawBackdrop = { _ in
            NSColor.underPageBackgroundColor.setFill()
            NSRect(origin: .zero, size: crop.size).fill()
            let top = crop.height
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
            NSRect(x: 0, y: top - bar, width: crop.width, height: bar).fill()
            if let n = screen.notch {
                NSColor.black.setFill()
                let r = NSRect(x: n.minX - crop.minX, y: top - (screen.frame.maxY - n.bottom), width: n.maxX - n.minX, height: screen.frame.maxY - n.bottom)
                NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 10), xRadius: 9, yRadius: 9).fill()
                if guides {
                    // The hardware notch's own edge, dashed, so the indicator can be told from it. Off unless SHEP_SNAPSHOT_GUIDES=1.
                    let edge = NSBezierPath(rect: r)
                    edge.setLineDash([3, 3], count: 2, phase: 0)
                    edge.lineWidth = 0.5
                    NSColor.systemRed.withAlphaComponent(0.7).setStroke()
                    edge.stroke()
                }
            }
        }
        let window = SnapshotWindow(size: crop.size, appearance: appearance)
        window.contentView = root
        let indicator = HomeIndicatorView(frame: .zero)
        indicator.setMode(mode)
        indicator.configure(kind: placement.kind, size: placement.rect.size)
        indicator.frame.origin = CGPoint(x: placement.rect.minX - crop.minX, y: placement.rect.minY - crop.minY)
        indicator.alphaValue = HomeGeometry.restingAlpha(for: placement.kind)
        root.addSubview(indicator)
        let rep = root.bitmap(scale: scale)
        window.close()
        return rep
    }

    private static func notchedScreen() -> HomeScreen {
        for s in NSScreen.screens {
            let home = HomeScreen(frame: s.frame, visibleFrame: s.visibleFrame,
                                  auxLeft: HomeScreen.normalizedAux(s.auxiliaryTopLeftArea, in: s.frame),
                                  auxRight: HomeScreen.normalizedAux(s.auxiliaryTopRightArea, in: s.frame))
            if home.notch != nil { return home }
        }
        return .exampleNotched
    }

    private static func renderCards(dark: Bool, appearance: NSAppearance?) async -> [(Scene, NSBitmapImageRep?)] {
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
        let win = CGRect(x: 120, y: 300, width: 720, height: 460)
        guard let tab = TabGeometry.place(window: win, isFullScreen: false, screens: screens, usable: nil).layout else { return [] }
        let layout = PanelGeometry.layout(tab: tab, screens: screens)
        let crop = layout.panelFrame.insetBy(dx: -28, dy: -20)
        let hex = TabAppearance.fallbackFillHex(dark: dark)
        let panelOrigin = CGPoint(x: layout.panelFrame.minX - crop.minX, y: layout.panelFrame.minY - crop.minY)

        // The dog in its tab comes from the page (loaded once, snapshotted once); the cards are the app's own native views.
        let stage = SnapshotWindow(size: layout.panelFrame.size, appearance: appearance)
        let dog = DogWebView()
        dog.frame = CGRect(origin: .zero, size: layout.panelFrame.size)
        stage.contentView = dog
        await pause(1.5)
        dog.setTheme(ShepThemes.defaultTheme.name)
        dog.setBar(hex: hex)
        dog.setActive(true)
        dog.setLayout(layout)
        await pause(0.5)

        let dogImage = await webImage(dog)
        stage.close()

        var out: [(Scene, NSBitmapImageRep?)] = []
        for scene in [Scene.approval, .reply, .ask, .transcript] {
            let model: CardModel
            switch scene {
            case .approval:
                model = CardModel.approval(text: "Press \"Save\"?",
                                           choices: Brief.approvalChoices,
                                           title: "Shep wants to press Save in TextEdit")
            case .reply: model = CardModel.reply(Brief.done, milliseconds: 60_000)
            case .ask: model = CardModel.askField
            case .transcript: model = CardModel.transcript("press save in text edit")
            case .house, .houseAway, .houseNoNotch: continue
            }
            let root = SnapshotRoot(frame: CGRect(origin: .zero, size: crop.size), appearance: appearance)
            root.drawBackdrop = { _ in
                NSColor.underPageBackgroundColor.setFill()
                NSRect(origin: .zero, size: crop.size).fill()
                let w = win.offsetBy(dx: -crop.minX, dy: -crop.minY)
                NSColor.windowBackgroundColor.setFill()
                w.fill()
                let bar = NSRect(x: w.minX, y: w.maxY - DockGeometry.titleBarHeight, width: w.width, height: DockGeometry.titleBarHeight)
                if let c = TabAppearance.rgb(hex: hex) {
                    NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1).setFill()
                    bar.fill()
                }
            }
            let window = SnapshotWindow(size: crop.size, appearance: appearance)
            window.contentView = root
            let tabView = TabShapeView(frame: .zero)
            tabView.update(frame: tab.rect.offsetBy(dx: -crop.minX, dy: -crop.minY), style: tab.style, path: tab.path, fillHex: hex,
                           outline: TabAppearance.outlineRGBA(dark: dark))
            root.addSubview(tabView)
            if let dogImage {
                let view = NSImageView(frame: CGRect(origin: panelOrigin, size: layout.panelFrame.size))
                view.image = dogImage
                root.addSubview(view)
            }
            let card = CardView(frame: .zero)
            let height = card.configure(model, width: layout.bubbleFrame.width, maxHeight: layout.bubbleFrame.height)
            let frame = CardGeometry.frame(in: layout, contentHeight: height)
            card.frame = CGRect(x: frame.minX - crop.minX, y: frame.minY - crop.minY, width: frame.width, height: frame.height)
            root.addSubview(card)
            card.appearance = appearance
            out.append((scene, root.bitmap(scale: scale)))
            window.close()
        }
        return out
    }

    // MARK: checks

    /// AppKit facts the pure tests cannot reach, checked on the real views (never on screen). Returns the number that failed.
    private static func runChecks() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool) {
            print("[shep] ui-snapshot: check \(ok ? "ok" : "FAILED"): \(name)")
            if !ok { failed += 1 }
        }
        // Approval card: no NSButton has a key equivalent and the window has no default button.
        let card = CardView(frame: .zero)
        _ = card.configure(CardModel.approval(text: "Press the checkbox \"Speed Limit\"?", choices: Brief.approvalChoices, title: "t"),
                           width: 300, maxHeight: 150)
        let host = SnapshotWindow(size: CGSize(width: 300, height: 150), appearance: nil)
        host.contentView = card
        var buttons: [NSButton] = []
        func collect(_ v: NSView) { if let b = v as? NSButton { buttons.append(b) }; v.subviews.forEach(collect) }
        collect(card)
        check("approval card has two buttons", buttons.count == 2)
        check("no card button has a key equivalent", buttons.allSatisfy { $0.keyEquivalent.isEmpty })
        check("the card window has no default button", host.defaultButtonCell == nil)
        // VoiceOver: the cursor starts on the text, VO-Right reaches Approve, then Deny; keyboard focus stays on Deny.
        let kids = (card.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        let names = kids.map { ($0 as? NSButton)?.title ?? (($0 as? NSTextField).map { _ in "text" } ?? "other") }
        check("VoiceOver order is text, Approve, Deny", Array(names.prefix(3)) == ["text", "Approve", "Deny"])
        check("VoiceOver starts on the text", card.initialVoiceOverElement is NSTextField)
        check("keyboard focus starts on the text", card.initialFocus is NSTextField && card.initialFocus === card.initialVoiceOverElement)
        check("the text can take keyboard focus", host.makeFirstResponder(card.initialFocus) && host.firstResponder === card.initialFocus)
        let empty = CardView(frame: .zero)
        _ = empty.configure(CardModel.approval(text: "", choices: Brief.approvalChoices, title: "t"), width: 300, maxHeight: 150)
        check("an approval with no text focuses Deny", (empty.initialFocus as? NSButton)?.title == "Deny")
        // A text too long for the card scrolls; VoiceOver still starts on the text field and goes on to Approve.
        let long = CardView(frame: .zero)
        _ = long.configure(CardModel.approval(text: String(repeating: "Press the checkbox \"Speed Limit\"? ", count: 30),
                                              choices: Brief.approvalChoices, title: "t"), width: 300, maxHeight: 150)
        let longKids = (long.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        check("long text: VoiceOver starts on the text field", long.initialVoiceOverElement is NSTextField && long.initialVoiceOverElement?.enclosingScrollView != nil)
        check("long text: order is text, Approve, Deny", longKids.count >= 3 && longKids[0] is NSTextField
              && (longKids[1] as? NSButton)?.title == "Approve" && (longKids[2] as? NSButton)?.title == "Deny")
        check("long text: the scroll view is not a separate VoiceOver stop", long.initialVoiceOverElement?.enclosingScrollView?.isAccessibilityElement() == false)
        // Fix this screen: the label cards at the real bubble size (PanelGeometry, 320 x 150 pt; the card clips there), so every
        // button, including More / Earlier / Back on a picker page of long labels, is on the card, in order for VoiceOver and Tab.
        func labelCardFits(_ card: LabelCard) -> Bool {
            let v = CardView(frame: .zero)
            _ = v.configure(CardModel.approval(text: card.text, choices: card.choices.map { (id: $0.id, label: $0.label) }, title: card.title),
                            width: PanelGeometry.panelWidth, maxHeight: PanelGeometry.bubbleHeight)
            var bs: [NSButton] = []
            func grab(_ x: NSView) { if let b = x as? NSButton { bs.append(b) }; x.subviews.forEach(grab) }
            grab(v)
            let inside = bs.allSatisfy { $0.frame.minX >= CardView.padding - 0.5 && $0.frame.maxX <= v.bounds.width - CardView.padding + 0.5
                && $0.frame.minY >= 0 && $0.frame.maxY <= v.bounds.height + 0.5 }
            let apart = bs.indices.allSatisfy { i in bs.indices.allSatisfy { j in i == j || !bs[i].frame.intersects(bs[j].frame) } }
            let ids = card.choices.map { $0.id }
            // VoiceOver: the text first, then the buttons in the card's order. Tab: the same order, then back round (through the
            // text when the text takes the keyboard first).
            let voButtons = (v.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }.map { $0.identifier?.rawValue ?? "" }
            let byID = Dictionary(uniqueKeysWithValues: bs.map { ($0.identifier?.rawValue ?? "", $0) })
            let first = byID[ids[0]], last = byID[ids[ids.count - 1]]
            let tab = ids.indices.dropLast().allSatisfy { k in byID[ids[k]]?.nextKeyView === byID[ids[k + 1]] }
                && (last?.nextKeyView === first || (last?.nextKeyView === v.initialFocus && v.initialFocus?.nextKeyView === first))
            // Visual order is reading order: row by row, left to right.
            let visual = ids.compactMap { byID[$0]?.frame }
            let reading = zip(visual, visual.dropFirst()).allSatisfy { a, b in b.minY > a.minY + 0.5 || (abs(b.minY - a.minY) <= 0.5 && b.minX > a.minX) }
            return bs.count == ids.count && inside && apart && voButtons == ids && tab && reading
        }
        let longLabels = LabelReview(bundleID: "dev.shep.fixscreen.fixture", appName: "ShepLabelFixture", proposals: (1...13).map {
            LabelProposal(id: $0, fingerprint: "f\($0)", role: "AXButton", kind: "button", context: "Playback / Rename / Picture",
                          label: "Play the current track from the start", confidence: 0.9)
        })
        check("label card at 150 pt: Accept all, Edit, Reject and Cancel are all on the card", labelCardFits(LabelCardBuilder.main(longLabels)))
        check("label picker at 150 pt, first page of long labels: every label and More / Back are on the card",
              labelCardFits(LabelCardBuilder.picker(longLabels, mode: .edit, page: 0)))
        check("label picker at 150 pt, a middle page: every label and More / Earlier / Back are on the card",
              labelCardFits(LabelCardBuilder.picker(longLabels, mode: .reject, page: 1)))
        check("label picker at 150 pt, the last page: its label and Earlier / Back are on the card",
              labelCardFits(LabelCardBuilder.picker(longLabels, mode: .edit, page: 99)))
        host.close()
        // The pill that shows the question never takes key status: VoiceOver's cursor stays put until the approval card.
        let pill = CardPanel()
        pill.takesKey = CardModel.transcript("turn on the speed limit").kind.takesKey
        check("the question's pill cannot become key", !pill.canBecomeKey)
        // The dog crossing the screen is decoration for about a second: VoiceOver must not be pulled into it (a live VoiceOver run: its
        // window appearing and going took the VoiceOver cursor away from the app and back, which read that app again
        // over the caller's question).
        let traveller = TravelPanel()
        check("the travelling dog is not an accessibility element (structural; VoiceOver's cursor is checked live)", !traveller.isAccessibilityElement()
              && (traveller.accessibilityChildren() ?? []).isEmpty)
        // Announcements go on one of these windows (AnnouncementTarget): each must be an accessibility window.
        let announceCard = CardPanel(), announceDock = DockOverlay(), announceHome = HomePanel()
        check("announcement windows are accessibility windows",
              [announceCard as NSWindow, announceDock, announceHome].allSatisfy { $0.accessibilityRole() == .window })
        // Home indicator: click-through and never key, yet still a labelled accessibility button that can be pressed.
        let home = HomePanel()
        if let placement = HomeGeometry.place(screens: [notchedScreen()], statusItem: nil) {
            home.apply(placement)
            var pressed = false
            home.indicator.onPress = { pressed = true }
            check("home panel ignores mouse events", home.ignoresMouseEvents)
            check("home panel cannot become key or main", !home.canBecomeKey && !home.canBecomeMain)
            let ax = home.indicator
            check("indicator is an accessibility element", ax.isAccessibilityElement())
            check("indicator role is button", ax.accessibilityRole() == .button)
            check("indicator has label, value and help", ax.accessibilityLabel() != nil && ax.accessibilityValue() != nil && ax.accessibilityHelp() != nil)
            check("indicator accessibility press calls Shep", ax.accessibilityPerformPress() && pressed)
            check("indicator is the panel's content view", home.contentView === ax)
            // VoiceOver must land on the button itself, not on the paw and status images drawn inside it.
            check("indicator exposes no child accessibility elements", (ax.accessibilityChildren() ?? []).isEmpty)
        } else {
            check("a home placement exists", false)
        }
        return failed
    }

    // MARK: plumbing

    private static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func webImage(_ view: WKWebView) async -> NSImage? {
        let config = WKSnapshotConfiguration()
        config.rect = view.bounds
        config.snapshotWidth = NSNumber(value: Double(view.bounds.width))
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            view.takeSnapshot(with: config) { image, _ in cont.resume(returning: image) }
        }
    }
}

/// A window that exists only to give views an appearance and a backing store. It is never ordered in, so the screen
/// never shows it; it sits far outside every display in case something orders it in anyway.
@MainActor
private final class SnapshotWindow: NSWindow {
    init(size: CGSize, appearance: NSAppearance?) {
        super.init(contentRect: NSRect(x: -40000, y: -40000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        sharingType = .none
        self.appearance = appearance
        // A web page only runs its transitions and paints while its window is ordered in. This one is, but 40000 pt outside
        // every display, so nothing appears.
        orderBack(nil)
    }
}

/// The root of a snapshot: draws the backdrop (desktop, window, notch), holds the subviews, and renders itself to a bitmap.
@MainActor
private final class SnapshotRoot: NSView {
    var drawBackdrop: ((NSRect) -> Void)?
    private let fixedAppearance: NSAppearance?

    init(frame: CGRect, appearance: NSAppearance?) {
        fixedAppearance = appearance
        super.init(frame: frame)
        self.appearance = appearance
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) { drawBackdrop?(dirtyRect) }

    func bitmap(scale: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        layoutSubtreeIfNeeded()
        cacheDisplay(in: bounds, to: rep)
        return rep
    }
}
