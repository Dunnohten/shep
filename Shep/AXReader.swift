import AppKit
import ApplicationServices
import ShepCore

/// What AXReader saw in an app. `elements` maps `Control.pathID` back to the live AX element for ActionPerformer.
/// `window`, `windowTitle` and `windowFrame` describe the target window (the one a screenshot shows); `controls` hold that
/// window's nodes first, then nodes of the app's other windows that overlap it (a dialog or sheet in front), tagged with
/// their own window title and subrole.
struct AXSnapshot {
    var pid: pid_t
    var bundleID: String
    var appName: String
    var windowTitle: String
    /// AX coordinates (top-left origin, global points), like every Control frame.
    var windowFrame: CGRect
    /// The window element the controls were read from; its identity (CFEqual) is rechecked before anything is pressed or clicked.
    var window: AXUIElement
    var controls: [Control]
    var elements: [String: AXUIElement]
    var truncated: Bool
    /// The depth cap cut off a subtree (only the label scan treats this as a partial result).
    var depthCut: Bool = false
    /// Every window of the app that was read, in AX order, with the target marked.
    var windows: [AXWindowSummary] = []
    var nodesVisited: Int = 0
    /// A dialog or sheet is open over the target window.
    var modalInFront: Bool = false
}

/// A live AX element seen through the pure walker's protocol. Each property is one AX call.
struct LiveAXNode: AXNodeSource {
    let element: AXUIElement

    var role: String { AXReader.string(element, kAXRoleAttribute) }
    var subrole: String { AXReader.string(element, kAXSubroleAttribute) }
    var title: String { AXReader.string(element, kAXTitleAttribute) }
    var descriptionText: String { AXReader.string(element, kAXDescriptionAttribute) }
    var help: String { AXReader.string(element, kAXHelpAttribute) }
    var valueText: String? { AXReader.copy(element, kAXValueAttribute) as? String }
    var frame: CGRect? { AXReader.frame(of: element) }
    var identifier: String { AXReader.string(element, kAXIdentifierAttribute) }
    /// The text of the element that names this one (AXTitleUIElement): its title, else its text value.
    var titleElementText: String {
        guard let ref = AXReader.copy(element, kAXTitleUIElementAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return "" }
        let titleElement = ref as! AXUIElement
        let t = AXReader.string(titleElement, kAXTitleAttribute)
        if !t.isEmpty { return t }
        return (AXReader.copy(titleElement, kAXValueAttribute) as? String) ?? ""
    }
    var isEnabled: Bool { AXReader.bool(element, kAXEnabledAttribute, default: true) }
    var actions: [String] {
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] { return list }
        return []
    }
    func children() -> [LiveAXNode] { readChildren(limit: Int.max).children }
    func children(limit: Int) -> [LiveAXNode] { readChildren(limit: limit).children }
    /// One call that asks Accessibility for at most `limit` children, so a node with a huge list is never fetched whole.
    /// "No children" and "could not read them" are different answers. An element with no children, or one that says it has no value for
    /// AXChildren or does not support the attribute (a leaf such as a static text), is a leaf. Any other error (a timeout from a busy app,
    /// a vanished element, a disabled API, an unexpected reply) means the children are unknown, and the walk is then marked partial.
    func readChildren(limit: Int) -> AXChildRead<LiveAXNode> {
        guard limit > 0 else { return AXChildRead(children: []) }
        var values: CFArray?
        let err = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(limit, Int(Int32.max)), &values)
        switch err {
        case .success:
            guard let kids = values as? [AXUIElement] else { return AXChildRead(children: [], failed: true) }
            return AXChildRead(children: kids.prefix(limit).map { LiveAXNode(element: $0) })
        case .noValue, .attributeUnsupported:
            return AXChildRead(children: [])
        case .illegalArgument:
            // The indexed read answers "illegal argument" for an element that holds no child list at all (static texts, menu
            // items, links, check boxes: seen on the fixture window). Ask once more with the plain read, which tells a leaf
            // (no value, or an empty list) from a real failure.
            var whole: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &whole) {
            case .success:
                guard let kids = whole as? [AXUIElement] else { return AXChildRead(children: [], failed: true) }
                return AXChildRead(children: kids.prefix(limit).map { LiveAXNode(element: $0) })
            case .noValue, .attributeUnsupported:
                return AXChildRead(children: [])
            default:
                return AXChildRead(children: [], failed: true)
            }
        default:
            return AXChildRead(children: [], failed: true)
        }
    }
}

/// Reads an app's Accessibility trees through `AXTreeReader` (breadth first, caps on depth, node count and time, shared by all
/// windows, the target window first). Reading only: nothing here presses or changes anything. Secure text fields are never
/// read for their value.
enum AXReader {
    /// Per AX call. A hung app answers "timeout" instead of freezing Shep.
    static let messagingTimeout: Float = 0.2
    /// Windows listed per app; the focused and main windows are always added.
    private static let maxWindows = 16

    /// Reads every window of the app. The target window is chosen by `targetFrame` (within 4 pt), then `targetTitle`, else the
    /// app's main window, else its focused non-modal window, else the first.
    static func read(pid: pid_t, targetFrame: CGRect? = nil, targetTitle: String? = nil, limits: AXWalkLimits = .standard,
                     preferFocused: Bool = false) -> AXSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        // The shared deadline starts here, before the app's windows are listed or any window's metadata is read.
        let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        let budget = AXWalkBudget(limits: limits, clock: clock)
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let mainWindow = windowElement(app, kAXMainWindowAttribute)
        let focusedWindow = windowElement(app, kAXFocusedWindowAttribute)
        var elements: [AXUIElement] = []
        if let listed = copy(app, kAXWindowsAttribute) as? [AXUIElement] { elements = Array(listed.prefix(maxWindows)) }
        // AXWindows lists the windows front to back; the focused and main windows added below have no known position.
        let listedCount = elements.count
        for extra in [focusedWindow, mainWindow] {
            if let e = extra, !elements.contains(where: { CFEqual($0, e) }) { elements.append(e) }
        }
        guard !elements.isEmpty, !budget.expired else { return nil }

        // Only window metadata (title, subrole, frame, modal flag, position) is read here, one property at a time with the
        // deadline checked between them. No window's children, values, descriptions or tooltips are read until the reader
        // has decided that window is the target or a dialog in front of it.
        var candidates: [AXWindowCandidate<LiveAXNode>] = []
        for (position, w) in elements.enumerated() {
            let z: Int? = position < listedCount ? position : nil
            let isMain = mainWindow.map { CFEqual($0, w) } ?? false
            let isFocused = focusedWindow.map { CFEqual($0, w) } ?? false
            candidates.append(AXWindowCandidate(root: LiveAXNode(element: w), readInfo: { expired in
                _ = AXUIElementSetMessagingTimeout(w, messagingTimeout)
                if expired() { return nil }
                let title = string(w, kAXTitleAttribute)
                if expired() { return nil }
                let subrole = string(w, kAXSubroleAttribute)
                if expired() { return nil }
                let rect = frame(of: w)
                if expired() { return nil }
                let modal = bool(w, "AXModal", default: false)
                if expired() { return nil }
                let identifier = string(w, kAXIdentifierAttribute)
                return AXWindowInfo(title: title, subrole: subrole, frame: rect, isMain: isMain, isFocused: isFocused, modalFlag: modal, zOrder: z,
                                    identifier: identifier)
            }))
        }
        guard let result = AXTreeReader.read(candidates: candidates, targetFrame: targetFrame, targetTitle: targetTitle,
                                             limits: limits, clock: clock, budget: budget, preferFocused: preferFocused),
              let windowFrame = result.windows[result.target].info.frame else { return nil }

        let running = NSRunningApplication(processIdentifier: pid)
        var live: [String: AXUIElement] = [:]
        for n in result.nodes { live[n.control.pathID] = n.node.element }
        return AXSnapshot(pid: pid, bundleID: running?.bundleIdentifier ?? "", appName: running?.localizedName ?? "this app",
                          windowTitle: result.windows[result.target].info.title, windowFrame: windowFrame, window: elements[result.target],
                          controls: result.controls, elements: live, truncated: result.truncated, depthCut: result.depthCut,
                          windows: result.windows, nodesVisited: result.nodesVisited, modalInFront: result.modalInFront)
    }

    /// The window the dog sits on for `pid` (VoiceOver's focus first, then the keyboard, then the pointer) as a read target.
    @MainActor static func focusedReadTarget(pid: pid_t) -> WindowReadTarget {
        let focus = WindowTracker.focusedTargetWindow(pid: pid)
        return WindowReadTarget.focused(frame: focus.flatMap { frameOf($0) }, title: focus.map { titleOf($0) })
    }

    static func read(pid: pid_t, target: WindowReadTarget, limits: AXWalkLimits = .standard) -> AXSnapshot? {
        read(pid: pid, targetFrame: target.frame, targetTitle: target.title, limits: limits, preferFocused: target.preferFocused)
    }

    /// The process id of a running app by bundle identifier (first match), for the command-line tools.
    static func pid(forBundleID id: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier
    }

    /// An element's value as text, whatever its type (a checkbox answers with a number). nil when it has none.
    static func valueDescription(of el: AXUIElement) -> String? {
        guard let ref = copy(el, kAXValueAttribute) else { return nil }
        if let s = ref as? String { return s }
        if CFGetTypeID(ref) == CFBooleanGetTypeID() { return CFBooleanGetValue((ref as! CFBoolean)) ? "1" : "0" }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }

    /// Current frame of the app's focused window (for "has the window moved since the screenshot?").
    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let window = focusedWindow(of: app) else { return nil }
        return frame(of: window)
    }

    /// The app's focused (else main) window element right now.
    static func focusedWindowElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return focusedWindow(of: app)
    }

    static func frameOf(_ el: AXUIElement) -> CGRect? { frame(of: el) }

    static func titleOf(_ el: AXUIElement) -> String { string(el, kAXTitleAttribute) }

    /// The window that contains `el` (its AXWindow attribute); a window answers with itself on most apps, so fall back to walking up.
    static func windowContaining(_ el: AXUIElement) -> AXUIElement? {
        if let ref = copy(el, kAXWindowAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() { return (ref as! AXUIElement) }
        var current = el
        for _ in 0..<20 {
            guard let up = parent(of: current) else { return nil }
            if string(up, kAXRoleAttribute) == (kAXWindowRole as String) { return up }
            current = up
        }
        return nil
    }

    static func parent(of el: AXUIElement) -> AXUIElement? {
        if let ref = copy(el, kAXParentAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() { return (ref as! AXUIElement) }
        return nil
    }

    /// What the element says now, for TargetRecheck. `window` is the window the snapshot was read from.
    static func liveTarget(of el: AXUIElement, in window: AXUIElement) -> LiveTarget {
        let role = string(el, kAXRoleAttribute)
        var enabled = true
        if let e = copy(el, kAXEnabledAttribute), CFGetTypeID(e) == CFBooleanGetTypeID() { enabled = CFBooleanGetValue((e as! CFBoolean)) }
        var value: String?
        // A button's value can name it (the old rule), and static text is named by its value (the label resolver's rule).
        if role == "AXButton" || role == "AXStaticText", let v = copy(el, kAXValueAttribute) as? String { value = v }
        var inWindow = false
        if let w = windowContaining(el) { inWindow = CFEqual(w, window) }
        return LiveTarget(role: role, subrole: string(el, kAXSubroleAttribute), title: string(el, kAXTitleAttribute),
                          description: string(el, kAXDescriptionAttribute), value: value, help: string(el, kAXHelpAttribute),
                          enabled: enabled, inSnapshotWindow: inWindow)
    }

    /// Who an element is, for binding a click to it: role, subrole, the label `Control` would resolve, enabled, secure, frame.
    /// nil when its frame cannot be read. A password field is reported as secure and its value is never read.
    static func identity(of el: AXUIElement) -> HitIdentity? {
        guard let f = frame(of: el) else { return nil }
        let role = string(el, kAXRoleAttribute)
        let subrole = string(el, kAXSubroleAttribute)
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        var value: String?
        if role == "AXStaticText", !secure { value = copy(el, kAXValueAttribute) as? String }
        return HitIdentity.resolved(role: role, subrole: subrole, title: string(el, kAXTitleAttribute),
                                    description: string(el, kAXDescriptionAttribute), value: value,
                                    help: string(el, kAXHelpAttribute), enabled: bool(el, kAXEnabledAttribute, default: true), frame: f)
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let ref = copy(app, attribute), CFGetTypeID(ref) == AXUIElementGetTypeID() { return (ref as! AXUIElement) }
        }
        return nil
    }

    private static func windowElement(_ app: AXUIElement, _ attribute: String) -> AXUIElement? {
        if let ref = copy(app, attribute), CFGetTypeID(ref) == AXUIElementGetTypeID() { return (ref as! AXUIElement) }
        return nil
    }

    fileprivate static func bool(_ el: AXUIElement, _ attribute: String, default fallback: Bool) -> Bool {
        if let ref = copy(el, attribute), CFGetTypeID(ref) == CFBooleanGetTypeID() { return CFBooleanGetValue((ref as! CFBoolean)) }
        return fallback
    }

    fileprivate static func copy(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    fileprivate static func string(_ el: AXUIElement, _ attribute: String) -> String {
        (copy(el, attribute) as? String) ?? ""
    }

    fileprivate static func frame(of el: AXUIElement) -> CGRect? {
        guard let p = copy(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = copy(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
