import AppKit

// A tiny window for trying Shep's "fix this screen" label repair. Source only: scripts/fixscreen-fixture.sh builds it into build/.
// Left column: controls with no usable name (every line marked "unlabeled:"). Right column: controls that are named properly
// (every line marked "labeled:"). The accessibility identifiers are u2...u14 and btnPlay (unlabeled) and l1...l12 (labeled), so a
// scan can be scored: every u* / btnPlay should be flagged, no l* should be. Nothing here talks to a network or writes a file.

/// A link-like element: AppKit has no plain link control, so this one says it is a link to Accessibility and can be pressed.
final class LinkLike: NSView {
    var name: String?
    override var intrinsicContentSize: NSSize { NSSize(width: 70, height: 18) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .link }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityPerformPress() -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.linkColor.setFill()
        NSRect(x: 0, y: 2, width: bounds.width, height: 1).fill()
    }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    /// An image drawn in code. AppKit gives a system symbol an automatic accessibility description (so a button holding one is
    /// not really unnamed); an image drawn like this has none, which is what an app that ships an unlabeled icon looks like.
    func drawnIcon() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
    }

    func iconButton(_ symbolName: String, id: String, unnamedImage: Bool = false) -> NSButton {
        let b = NSButton(image: unnamedImage ? drawnIcon() : symbol(symbolName), target: nil, action: nil)
        b.bezelStyle = .regularSquare
        b.setAccessibilityIdentifier(id)
        return b
    }

    func titled(_ title: String, id: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.setAccessibilityIdentifier(id)
        return b
    }

    func row(_ context: String, _ control: NSView) -> NSStackView {
        let text = NSTextField(labelWithString: context)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [text, control])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }

    func unlabeledRows() -> [NSStackView] {
        var rows: [NSStackView] = []
        // unlabeled: image-only button (an image drawn in code), no title, no description, identifier btnPlay
        rows.append(row("Playback", iconButton("play.fill", id: "btnPlay", unnamedImage: true)))
        // unlabeled: a button titled with a role word
        rows.append(row("Rename", titled("button", id: "u2")))
        // unlabeled: a button titled with a file name
        rows.append(row("Picture", titled("icon.png", id: "u3")))
        // unlabeled: a single character
        rows.append(row("Close", titled("X", id: "u4")))
        // unlabeled: a checkbox with no title
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        box.setAccessibilityIdentifier("u5")
        rows.append(row("Remember", box))
        // unlabeled: a link with no text
        let link = LinkLike()
        link.setAccessibilityIdentifier("u6")
        rows.append(row("More", link))
        // unlabeled: a pull-down menu button with no title
        let menu = NSPopUpButton(frame: .zero, pullsDown: true)
        menu.addItems(withTitles: ["", "One", "Two"])
        menu.setAccessibilityIdentifier("u7")
        rows.append(row("Options", menu))
        // unlabeled: a description that is a role word
        let described = iconButton("photo", id: "u8", unnamedImage: true)
        described.setAccessibilityLabel("image")
        rows.append(row("Photo", described))
        // unlabeled: a pop-up button with nothing to say
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [""])
        popup.setAccessibilityIdentifier("u9")
        rows.append(row("Sort", popup))
        // unlabeled: an asset name as the title
        rows.append(row("Asset", titled("btn_close@2x", id: "u10")))
        // unlabeled: a switch with no label
        let toggle = NSSwitch()
        toggle.setAccessibilityIdentifier("u11")
        rows.append(row("Wi-Fi", toggle))
        // unlabeled: a class name as the title
        rows.append(row("Class", titled("NSButton", id: "u12")))
        // unlabeled: only a tooltip (help is a hint, not a name)
        let tip = iconButton("gearshape", id: "u13", unnamedImage: true)
        tip.toolTip = "Opens settings"
        rows.append(row("Help only", tip))
        // unlabeled: a disclosure triangle with no title
        let triangle = NSButton(title: "", target: nil, action: nil)
        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.pushOnPushOff)
        triangle.setAccessibilityIdentifier("u14")
        rows.append(row("Details", triangle))
        return rows
    }

    func labeledRows() -> [NSStackView] {
        var rows: [NSStackView] = []
        // labeled: a titled button
        rows.append(row("File", titled("Save", id: "l1")))
        // labeled: another titled button
        rows.append(row("File", titled("Cancel", id: "l2")))
        // labeled: a checkbox with a title
        let remember = NSButton(checkboxWithTitle: "Remember me", target: nil, action: nil)
        remember.setAccessibilityIdentifier("l3")
        rows.append(row("Login", remember))
        // labeled: an image button WITH an accessibility label
        let settings = iconButton("gearshape.fill", id: "l4")
        settings.setAccessibilityLabel("Settings")
        rows.append(row("Prefs", settings))
        // labeled: a second image button with an accessibility label
        let share = iconButton("square.and.arrow.up", id: "l5")
        share.setAccessibilityLabel("Share")
        rows.append(row("Send", share))
        // labeled: a link with a name
        let policy = LinkLike()
        policy.name = "Privacy Policy"
        policy.setAccessibilityIdentifier("l6")
        rows.append(row("Legal", policy))
        // labeled: a pop-up with a real title
        let sort = NSPopUpButton(frame: .zero, pullsDown: false)
        sort.addItems(withTitles: ["Sort by name", "Sort by date"])
        sort.setAccessibilityIdentifier("l7")
        rows.append(row("List", sort))
        // labeled: a menu button with a title
        let actions = NSPopUpButton(frame: .zero, pullsDown: true)
        actions.addItems(withTitles: ["Actions", "Copy", "Paste"])
        actions.setAccessibilityIdentifier("l8")
        rows.append(row("Edit", actions))
        // labeled: a switch with a label
        let wifi = NSSwitch()
        wifi.setAccessibilityLabel("Wi-Fi")
        wifi.setAccessibilityIdentifier("l9")
        rows.append(row("Net", wifi))
        // labeled: a second titled checkbox
        let notify = NSButton(checkboxWithTitle: "Notifications", target: nil, action: nil)
        notify.setAccessibilityIdentifier("l10")
        rows.append(row("Alerts", notify))
        // labeled: a button with a title and a tooltip
        let signIn = titled("Sign in", id: "l11")
        signIn.toolTip = "Sign in to your account"
        rows.append(row("Account", signIn))
        // labeled: an image button with the label "Close"
        let close = iconButton("xmark", id: "l12")
        close.setAccessibilityLabel("Close")
        rows.append(row("Window", close))
        return rows
    }

    func column(_ title: String, _ rows: [NSStackView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.boldSystemFont(ofSize: 13)
        let stack = NSStackView(views: [heading] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let columns = NSStackView(views: [column("Needs labels", unlabeledRows()), column("Already labeled", labeledRows())])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 48
        columns.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        content.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            columns.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Shep Label Fixture"
        window.contentView = content
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
