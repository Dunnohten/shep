import CoreGraphics
import Foundation

// Written for Shep.
// "Fix this screen" label repair, the pure part: which controls have no real name, and the context a model needs to propose one.
// No AppKit, no Accessibility calls: the app layer reads the window with AXReader (deeper caps, `AXWalkLimits.labelScan`) and hands
// the controls here.

/// What counts as "not a name": empty text, role words, file names, single characters or only symbols and digits, and machine identifiers.
/// The same rule judges the app's own names (is this control unlabeled?) and the model's proposals (is this label worth storing?).
public enum LabelText {
    /// Words a screen reader would say anyway ("button"), alone or in any mix ("image button", "Button 3").
    static let roleWords: Set<String> = [
        "button", "buttons", "checkbox", "check", "box", "link", "icon", "image", "img", "graphic", "toggle", "menu", "switch", "popup", "pop",
        "up", "radio", "disclosure", "triangle", "untitled", "unnamed", "label", "item", "view", "picture", "glyph", "symbol", "control", "text",
    ]
    static let fileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "pdf", "tif", "tiff", "bmp", "heic", "webp", "icns", "ico", "eps", "ai", "pict", "car", "xib", "nib",
        "storyboard", "plist", "json", "txt", "mov", "mp4", "mp3", "wav", "ttf", "otf", "xcassets", "imageset",
    ]
    /// Prefixes developers put on asset and view names: "btnPlay", "ic_close", "imgLogo".
    static let machinePrefixes: Set<String> = ["btn", "button", "ic", "icon", "img", "image", "iv", "tb", "cb", "lbl", "bt", "act", "action", "bar", "nav"]

    public static func isGeneric(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if isMachineIdentifier(t) || isFileName(t) { return true }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.isEmpty { return true }   // only symbols, digits, punctuation
        if t.count == 1 { return !isIdeograph(t.unicodeScalars.first!) }
        if !t.contains(" ") && t.contains("_") { return true }   // snake_case token
        let words = t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { Int($0) == nil }
        if !words.isEmpty && words.allSatisfy({ roleWords.contains($0) }) { return true }
        return false
    }

    /// One CJK ideograph, kana or hangul syllable is a whole word.
    private static func isIdeograph(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    static func isFileName(_ t: String) -> Bool {
        let lower = t.lowercased()
        for scale in ["@1x", "@2x", "@3x"] where lower.contains(scale) { return true }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return false }
        let ext = String(lower[lower.index(after: dot)...])
        return fileExtensions.contains(ext)
    }

    static func isMachineIdentifier(_ t: String) -> Bool {
        if t.contains(" ") { return false }
        if t.hasPrefix("_") { return true }
        let patterns = [
            "^NS[A-Z][a-z]", "^AX[A-Z][A-Za-z]*$", "^UI[A-Z][a-z]", "^SwiftUI[.:]", "^NS:", "^(com|org|net|io)\\.[A-Za-z0-9-]+\\.[A-Za-z0-9.-]+$",
            "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", "^0[xX][0-9A-Fa-f]+$",
        ]
        for p in patterns where t.range(of: p, options: .regularExpression) != nil { return true }
        // "btnPlay" / "imgLogo": a known prefix in lower case, then an upper-case letter, a digit, "-", "_" or ".".
        if let cut = t.firstIndex(where: { !$0.isLowercase }), cut != t.startIndex {
            let prefix = String(t[t.startIndex..<cut])
            let next = t[cut]
            if machinePrefixes.contains(prefix), next.isUppercase || next.isNumber || "-_.".contains(next), t.count > prefix.count + 1 { return true }
        }
        return false
    }
}

public enum UnlabeledReason: Equatable, Sendable {
    /// No title, description or label text at all.
    case empty
    /// A name that is not a name; the first generic text found.
    case generic(String)

    public var summary: String {
        switch self {
        case .empty: return "empty"
        case .generic: return "generic"
        }
    }
}

public enum SkipReason: String, Equatable, Sendable {
    case disabled, hidden
    /// The window's own close, minimize, zoom and full-screen buttons: the system names them, not the app.
    case windowChrome = "chrome"
}

public enum LabelVerdict: Equatable, Sendable {
    case labeled
    case unlabeled(UnlabeledReason)
    case skipped(SkipReason)
    /// Not a role the label scan looks at.
    case notChecked

    public var text: String {
        switch self {
        case .labeled: return "labeled"
        case .unlabeled(let r): return "unlabeled:" + r.summary
        case .skipped(let r): return "skipped:" + r.rawValue
        case .notChecked: return "not-checked"
        }
    }
}

public enum LabelFlagger {
    public static let candidateRoles: Set<String> = ["AXButton", "AXCheckBox", "AXLink", "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle"]

    /// Subroles of the traffic-light buttons. They have no title or description in the tree, and are never worth a label.
    public static let windowChromeSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// A pop-up or menu button shows the item it has selected; that text is its name when it has no title of its own.
    static let valueNamedRoles: Set<String> = ["AXPopUpButton", "AXMenuButton"]

    /// Buttons, checkboxes (the switch and toggle subroles are checkboxes), links, menu buttons, pop-up buttons, disclosure triangles.
    public static func isCandidateRole(role: String, subrole: String) -> Bool { candidateRoles.contains(role) }

    /// True for a control that is visible enough to be looked at: enabled is judged separately; a frame that is missing, not a number,
    /// or smaller than 2 points counts as hidden.
    static func isVisible(_ frame: CGRect?) -> Bool {
        guard let f = frame, f.minX.isFinite, f.minY.isFinite, f.width.isFinite, f.height.isFinite else { return false }
        return f.width >= 2 && f.height >= 2
    }

    /// The verdict from the control's own attributes. A name given by a child (a button that contains a text) is judged by `LabelScanner`,
    /// which can see the children. Help text alone never makes a control labeled: it is a hint, not a name.
    public static func verdict(_ c: Control) -> LabelVerdict {
        guard !c.isSecure, isCandidateRole(role: c.role, subrole: c.subrole) else { return .notChecked }
        if windowChromeSubroles.contains(c.subrole) { return .skipped(.windowChrome) }
        if !c.enabled { return .skipped(.disabled) }
        if !isVisible(c.frame) { return .skipped(.hidden) }
        var firstGeneric: String?
        var names = [c.title, c.description, c.titleElementText]
        // Kept on purpose (by design): VoiceOver speaks a pop-up's selected value as its name, so a pop-up showing "Sort by name"
        // is named, not unlabeled (l7 in the fixture). The trade-off: a pop-up whose shown value is user data ("Untitled", a chosen file) counts
        // as named even though that value says nothing about what the pop-up does. Missing that case is chosen over flagging every pop-up.
        if valueNamedRoles.contains(c.role), let shown = c.value { names.append(shown) }
        for name in names {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if !LabelText.isGeneric(t) { return .labeled }
            if firstGeneric == nil { firstGeneric = t }
        }
        if let g = firstGeneric { return .unlabeled(.generic(String(g.prefix(60)))) }
        return .unlabeled(.empty)
    }

    public static func isUnlabeled(_ c: Control) -> Bool {
        if case .unlabeled = verdict(c) { return true }
        return false
    }
}

// MARK: the tree of one window

/// The target window's controls as a tree, rebuilt from their path ids ("2/3/1" is the second... child "1" of "2/3").
struct LabelTree {
    struct Node {
        var control: Control
        var parent: Int?
        var children: [Int]
    }
    var nodes: [Node] = []

    init(controls: [Control]) {
        let inWindow = controls.filter { $0.inTargetWindow }
        var indexOf: [String: Int] = [:]
        for (i, c) in inWindow.enumerated() { indexOf[c.pathID] = i }
        nodes = inWindow.map { Node(control: $0, parent: nil, children: []) }
        for (i, c) in inWindow.enumerated() {
            guard let slash = c.pathID.lastIndex(of: "/") else { continue }
            let parentPath = String(c.pathID[c.pathID.startIndex..<slash])
            if let p = indexOf[parentPath], p != i {
                nodes[i].parent = p
                nodes[p].children.append(i)
            }
        }
    }

    static let maxNearbyStrings = 3
    static let maxNearbyLength = 40
    static let maxNearbyTotal = 100

    func staticText(_ i: Int) -> String? {
        let c = nodes[i].control
        guard c.role == "AXStaticText", !c.isSecure else { return nil }
        for raw in [c.value ?? "", c.title, c.description] {
            let t = LabelTree.clean(raw)
            if !t.isEmpty { return t }
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(maxNearbyLength))
    }

    /// The control's own subtree, to leave out of "nearby".
    private func subtree(of i: Int) -> Set<Int> {
        var out: Set<Int> = [i]
        var stack = [i]
        while let n = stack.popLast() { for k in nodes[n].children { out.insert(k); stack.append(k) } }
        return out
    }

    /// Static texts near node `i`: those in its parent's group (two levels), nearest sibling first; else those in the grandparent's group.
    func nearbyText(of i: Int) -> [String] {
        let own = subtree(of: i)
        var up = nodes[i].parent
        var levels = 0
        while let group = up, levels < 2 {
            var found: [String] = []
            let kids = nodes[group].children
            let position = kids.firstIndex(of: i)
            let ordered = kids.enumerated().sorted { a, b in
                let da = position.map { abs(a.offset - $0) } ?? a.offset
                let db = position.map { abs(b.offset - $0) } ?? b.offset
                return da != db ? da < db : a.offset < b.offset
            }.map { $0.element }
            for k in ordered where !own.contains(k) {
                if let t = staticText(k) { found.append(t) }
                for g in nodes[k].children where !own.contains(g) { if let t = staticText(g) { found.append(t) } }
            }
            var out: [String] = []
            var total = 0
            for t in found where !out.contains(t) {
                if out.count >= LabelTree.maxNearbyStrings || total + t.count > LabelTree.maxNearbyTotal { break }
                out.append(t); total += t.count
            }
            if !out.isEmpty { return out }
            up = nodes[group].parent
            levels += 1
        }
        return []
    }

    /// How many children of the control's parent have the control's role (the control included). 1 for a control with no parent.
    func siblingCount(of i: Int) -> Int {
        guard let parent = nodes[i].parent else { return 1 }
        let role = nodes[i].control.role
        return nodes[parent].children.filter { nodes[$0].control.role == role }.count
    }

    /// Roles from the window down to the control; each step after the window carries the number of earlier siblings of the same role.
    func ancestorPath(of i: Int) -> [String] {
        var chain: [Int] = []
        var cur: Int? = i
        while let n = cur { chain.append(n); cur = nodes[n].parent }
        chain.reverse()
        var steps: [String] = []
        for (depth, n) in chain.enumerated() {
            let role = nodes[n].control.role
            if depth == 0 { steps.append(role); continue }
            let siblings = nodes[chain[depth - 1]].children
            var before = 0
            for s in siblings { if s == n { break }; if nodes[s].control.role == role { before += 1 } }
            steps.append("\(role)[\(before)]")
        }
        return steps
    }

    /// A descendant (up to two levels down) whose text or name is real: the way a button that holds a text is named.
    func hasNamedDescendant(of i: Int) -> Bool {
        var frontier = nodes[i].children
        for _ in 0..<2 {
            var next: [Int] = []
            for k in frontier {
                let c = nodes[k].control
                if c.role == "AXStaticText", let t = staticText(k), !LabelText.isGeneric(t) { return true }
                for name in [c.title, c.description, c.titleElementText] where !name.isEmpty && !LabelText.isGeneric(name) {
                    if c.role == "AXImage" || c.role == "AXStaticText" || c.role == "AXGroup" { return true }
                }
                next.append(contentsOf: nodes[k].children)
            }
            frontier = next
        }
        return false
    }
}

// MARK: scan

public struct LabelCandidate: Equatable, Sendable, Codable {
    /// 1, 2, 3...: what the model and the card call it.
    public var id: Int
    public var pathID: String
    public var role: String
    public var subrole: String
    /// The word for the role in speech: "button", "checkbox", "pop-up", "link".
    public var kind: String
    public var title: String
    public var descriptionText: String
    public var help: String
    public var identifier: String
    public var nearbyText: [String]
    /// Window-relative, in points.
    public var relativeFrame: CGRect
    public var reason: UnlabeledReason
    public var fingerprint: String
    /// What the label is checked against when it is shown again.
    public var anchor: LabelAnchor = .empty
}

extension UnlabeledReason: Codable {
    private enum CodingKeys: String, CodingKey { case kind, text }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        self = kind == "generic" ? .generic(try c.decode(String.self, forKey: .text)) : .empty
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty: try c.encode("empty", forKey: .kind)
        case .generic(let t): try c.encode("generic", forKey: .kind); try c.encode(t, forKey: .text)
        }
    }
}

/// One checked control, flagged or not, for `--fix-screen-scan` and the tests.
public struct LabelScanEntry: Equatable, Sendable {
    public var pathID: String
    public var role: String
    public var subrole: String
    public var title: String
    public var descriptionText: String
    public var help: String
    public var identifier: String
    /// The value the scan read (the item a pop-up shows), cut short. Empty for a secure control.
    public var value: String
    public var fingerprint: String
    public var verdict: String
    public var flagged: Bool
    /// Flagged, but another flagged control has the same fingerprint, so a label could not tell them apart: not proposed, not stored.
    public var duplicate: Bool = false
    /// Flagged and also safe to offer: it can be told apart from every other control of its role in the window (see `LabelScanner`).
    public var offerable: Bool = false
}

public struct LabelScan: Equatable, Sendable {
    public var entries: [LabelScanEntry]
    /// The flagged controls that can be told apart. Ids run 1, 2, 3... over these.
    public var candidates: [LabelCandidate]
    /// A cap (depth, nodes, time or children) ended the walk early. A duplicate identifier or help text may sit in the part not read, so a
    /// partial scan offers nothing: `candidates` is empty and no entry is `offerable`.
    public var partial: Bool
    /// Flagged controls left out because their fingerprint is shared with another flagged control (a subset of `unstableSkipped`).
    public var duplicatesSkipped: Int = 0
    /// Flagged controls left out because nothing the control itself owns tells it from another control of its role: no identifier, or one
    /// another control shares, and no help text, or help another same-role control shares. Nearby text does not count: it stays put when two
    /// controls swap. Never offered, stored or shown. (Zero when the walk was partial: see `partial`.)
    public var unstableSkipped: Int = 0
    /// Which kind of window this is (`.empty` when nothing identifies it). Every candidate's anchor carries it.
    public var window: WindowSignature = .empty
}

public enum LabelScanner {
    /// What tells a control from the others of its role must belong to the control, not to its place: its identifier, when no other control in
    /// the window has the same one; else its own help text, when it is not empty and no other control of that role has the same. Nearby text is
    /// sent to the model and checked when a label is shown, but never makes a control safe to label: it stays put when two controls trade
    /// places. A control with neither is flagged but never offered, stored or shown. A partial walk (`truncated`) offers nothing at all,
    /// because what it did not read may hold the control's twin.
    public static func scan(controls: [Control], windowFrame: CGRect, truncated: Bool) -> LabelScan {
        let tree = LabelTree(controls: controls)
        let signature = tree.nodes.first.map { n in
            WindowSignature(identifier: n.control.windowIdentifier, subrole: n.control.windowSubrole, title: n.control.window)
        } ?? .empty
        var entries: [LabelScanEntry] = []
        var candidates: [LabelCandidate] = []
        // For every checked control, in entry order: its role, its trimmed identifier and its normalized help text (digits kept).
        var identities: [(role: String, identifier: String, help: String)] = []
        var candidateEntry: [Int] = []
        for (i, node) in tree.nodes.enumerated() {
            let c = node.control
            var verdict = LabelFlagger.verdict(c)
            if case .notChecked = verdict { continue }
            if case .unlabeled = verdict {
                if let f = c.frame, !windowFrame.intersects(f) { verdict = .skipped(.hidden) }
                else if tree.hasNamedDescendant(of: i) { verdict = .labeled }
            }
            let frame = c.frame ?? .zero
            let relative = CGRect(x: frame.minX - windowFrame.minX, y: frame.minY - windowFrame.minY, width: frame.width, height: frame.height)
            let nearby = tree.nearbyText(of: i)
            let fingerprintInput = LabelFingerprint.Input(
                role: c.role, subrole: c.subrole, identifier: c.identifier, ancestorPath: tree.ancestorPath(of: i), nearbyText: nearby,
                help: c.help, windowSize: windowFrame.size, relativeCenter: CGPoint(x: relative.midX, y: relative.midY),
                siblingCount: tree.siblingCount(of: i))
            let fingerprint = LabelFingerprint.make(fingerprintInput)
            identities.append((c.role, c.identifier.trimmingCharacters(in: .whitespacesAndNewlines), LabelFingerprint.normalizedHelp(c.help)))
            var flagged = false
            if case .unlabeled(let reason) = verdict {
                flagged = true
                var anchor = LabelFingerprint.anchor(fingerprintInput)
                anchor.window = signature.isEmpty ? nil : signature
                candidateEntry.append(entries.count)
                candidates.append(LabelCandidate(
                    id: candidates.count + 1, pathID: c.pathID, role: c.role, subrole: c.subrole, kind: c.kind,
                    title: String(c.title.prefix(60)), descriptionText: String(c.description.prefix(60)), help: String(c.help.prefix(120)),
                    identifier: String(c.identifier.prefix(80)), nearbyText: nearby, relativeFrame: relative, reason: reason, fingerprint: fingerprint,
                    anchor: anchor))
            }
            entries.append(LabelScanEntry(pathID: c.pathID, role: c.role, subrole: c.subrole, title: c.title, descriptionText: c.description,
                                          help: c.help, identifier: c.identifier, value: c.isSecure ? "" : String((c.value ?? "").prefix(60)),
                                          fingerprint: fingerprint, verdict: verdict.text, flagged: flagged))
        }
        var identifierCount: [String: Int] = [:]
        var helpCount: [String: Int] = [:]
        for id in identities {
            if !id.identifier.isEmpty { identifierCount[id.identifier, default: 0] += 1 }
            if !id.help.isEmpty { helpCount[id.role + "\u{1F}" + id.help, default: 0] += 1 }
        }
        func stable(_ entryIndex: Int) -> Bool {
            let id = identities[entryIndex]
            if !id.identifier.isEmpty { return identifierCount[id.identifier] == 1 }
            return !id.help.isEmpty && helpCount[id.role + "\u{1F}" + id.help] == 1
        }
        if truncated {
            return LabelScan(entries: entries, candidates: [], partial: true, duplicatesSkipped: 0, unstableSkipped: 0, window: signature)
        }
        // Flagged controls sharing one fingerprint (counted on their own for the scan tool).
        var seen: [String: Int] = [:]
        for c in candidates { seen[c.fingerprint, default: 0] += 1 }
        let shared = Set(seen.filter { $0.value > 1 }.keys)
        var kept: [LabelCandidate] = []
        var unstable = 0
        for (k, c) in candidates.enumerated() {
            // `identities` has one row per entry, in the same order as `entries`.
            if stable(candidateEntry[k]) && !shared.contains(c.fingerprint) {
                entries[candidateEntry[k]].offerable = true
                kept.append(c)
            } else {
                unstable += 1
                if shared.contains(c.fingerprint) { entries[candidateEntry[k]].duplicate = true }
            }
        }
        for k in kept.indices { kept[k].id = k + 1 }
        return LabelScan(entries: entries, candidates: kept, partial: truncated,
                         duplicatesSkipped: candidates.filter { shared.contains($0.fingerprint) }.count, unstableSkipped: unstable, window: signature)
    }
}

// MARK: overlay resolution

/// Gives the controls that still have no real name the label the person approved earlier, so every later read of the window names them
/// (and "click <that label>" matches them through the same matching as any other name). A control the app names is never touched.
/// A stored label is applied only to ONE live control, only when that control still looks like the one it was approved for (the
/// `LabelAnchor` agrees), and only in a window of the kind it was approved in (the `WindowSignature` matches). The live control must also be
/// one the scan can tell apart from the others of its role (`LabelScanner`): a stored label never lands on whatever now fills a slot.
/// When the window changed enough to leave any doubt the label is not shown: nothing is better than a wrong name.
public enum LabelOverlayResolver {
    /// `openWindows` is the signature of every window of the app the reader listed, the target included; nil for a window the reader did not
    /// get to examine. Left out, the target window is taken to be the app's only window. Shep reads no window but the target, so it cannot
    /// tell whether a control would also resolve in another window of the same kind: when more than one window matches, nothing is applied.
    /// `partial`: the read was cut short by a cap (depth, nodes, time or children). A twin of a control may sit in the part not read, so
    /// nothing is resolved from the store.
    public static func apply(to controls: [Control], windowFrame: CGRect, labels: [StoredLabel], openWindows: [WindowSignature?]? = nil,
                             partial: Bool = false) -> [Control] {
        guard !labels.isEmpty, !partial else { return controls }
        let scan = LabelScanner.scan(controls: controls, windowFrame: windowFrame, truncated: false)
        let liveWindow = scan.window
        let open: [WindowSignature?] = openWindows ?? [liveWindow]
        var byFingerprint: [String: [StoredLabel]] = [:]
        for l in labels { byFingerprint[l.fingerprint, default: []].append(l) }
        var byPath: [String: String] = [:]
        for c in scan.candidates {
            let usable = (byFingerprint[c.fingerprint] ?? []).filter { s in trusted(s, for: c, liveWindow: liveWindow, openWindows: open) }
            if usable.count == 1 { byPath[c.pathID] = usable[0].label }
        }
        guard !byPath.isEmpty else { return controls }
        return controls.map { original in
            var c = original
            if c.inTargetWindow, let l = byPath[c.pathID] { c.overlayLabel = l }
            return c
        }
    }

    static func trusted(_ stored: StoredLabel, for live: LabelCandidate, liveWindow: WindowSignature, openWindows: [WindowSignature?]) -> Bool {
        guard let anchor = stored.anchor else {
            // A label saved by the first build has no anchor: only when the app named the control with an identifier (the key is then the
            // identifier itself, and the scan has already left out a control that shares it), and only in an app with one standard window.
            return stored.fingerprint.hasPrefix("i1-") && !live.identifier.isEmpty && legacyWindowAllowed(liveWindow, openWindows)
        }
        guard LabelAnchor.agrees(stored: anchor, live: live.anchor) else { return false }
        guard let window = anchor.window else { return legacyWindowAllowed(liveWindow, openWindows) }
        guard window.matches(liveWindow) else { return false }
        // A window the reader could not examine might match too.
        let matching = openWindows.filter { other in other.map { window.matches($0) } ?? true }.count
        return matching <= 1
    }

    /// A label with no window signature (saved before windows were told apart) is shown only when every window of the app was examined,
    /// exactly one of them is a standard window, and the live window is that one.
    static func legacyWindowAllowed(_ live: WindowSignature, _ open: [WindowSignature?]) -> Bool {
        guard live.isStandard, !open.contains(where: { $0 == nil }) else { return false }
        return open.compactMap { $0 }.filter { $0.isStandard }.count == 1
    }
}

/// What VoiceOver is told when Shep reads, proposes or presses a control that carries one of its own labels.
public enum LabelAnnouncement {
    public static func text(for c: Control) -> String? {
        guard c.labelSource == .overlay else { return nil }
        return "\(c.label), a label Shep added."
    }
}
