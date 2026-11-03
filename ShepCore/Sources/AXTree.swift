import CoreGraphics
import Foundation

// Pure Accessibility tree reading: no AppKit, no AX calls. The app layer adapts live AXUIElements to `AXNodeSource`;
// tests use plain structs. Written for Shep.

/// One node of an Accessibility tree, read lazily. Each property may cost an AX call in the app, so the walker reads each once.
public protocol AXNodeSource {
    var role: String { get }
    var subrole: String { get }
    var title: String { get }
    /// AXDescription.
    var descriptionText: String { get }
    /// AXHelp: the tooltip.
    var help: String { get }
    /// The value when it is text (never read for secure fields by the walker).
    var valueText: String? { get }
    var frame: CGRect? { get }
    var isEnabled: Bool { get }
    var actions: [String] { get }
    /// AXIdentifier. Read only for the controls the label scan looks at; "" when the adapter does not read it.
    var identifier: String { get }
    /// The text of AXTitleUIElement, for the same controls; "" when none.
    var titleElementText: String { get }
    func children() -> [Self]
    /// At most `limit` children, in order. The walker only ever asks for this: a node with a hundred thousand children costs `limit`
    /// reads, not a hundred thousand. The default asks for them all and cuts the list, so an adapter should implement it.
    func children(limit: Int) -> [Self]
    /// Like `children(limit:)`, but says when the read itself failed (a timeout, a busy or vanished element, an unexpected reply), which is
    /// not the same as an element with no children. The walker asks for this, and treats a failure as a part of the tree it did not read.
    /// The default trusts `children(limit:)`; an adapter over a call that can fail must implement it.
    func readChildren(limit: Int) -> AXChildRead<Self>
}

public extension AXNodeSource {
    var identifier: String { "" }
    var titleElementText: String { "" }
    func children(limit: Int) -> [Self] { Array(children().prefix(max(0, limit))) }
    func readChildren(limit: Int) -> AXChildRead<Self> { AXChildRead(children: children(limit: limit)) }
}

/// The outcome of one child read. `failed` is false for an element that has no children (including one the app says has no such
/// attribute or no value); it is true only when the answer is unknown.
public struct AXChildRead<N> {
    public var children: [N]
    public var failed: Bool
    public init(children: [N], failed: Bool = false) { self.children = children; self.failed = failed }
}

public struct AXWalkLimits: Equatable, Sendable {
    public var maxDepth: Int
    public var maxNodes: Int
    public var timeBudget: TimeInterval
    /// Children read from any one node. A wider node is cut here and the read is reported as partial.
    public var maxChildrenPerNode: Int
    public init(maxDepth: Int, maxNodes: Int, timeBudget: TimeInterval, maxChildrenPerNode: Int = 400) {
        self.maxDepth = maxDepth; self.maxNodes = maxNodes; self.timeBudget = timeBudget; self.maxChildrenPerNode = maxChildrenPerNode
    }
    /// The caps the app has always used.
    public static let standard = AXWalkLimits(maxDepth: 8, maxNodes: 400, timeBudget: 2.0)
    /// The label scan walks deeper and wider (about 2 s all the same); a cap that is hit is reported as a partial result.
    public static let labelScan = AXWalkLimits(maxDepth: 30, maxNodes: 1500, timeBudget: 2.0, maxChildrenPerNode: 300)
}

/// Node and time caps shared by every window of one read. The clock is injected (seconds, any origin).
public final class AXWalkBudget {
    public let limits: AXWalkLimits
    private let clock: () -> TimeInterval
    private let deadline: TimeInterval
    public private(set) var visited = 0

    public init(limits: AXWalkLimits = .standard, clock: @escaping () -> TimeInterval) {
        self.limits = limits; self.clock = clock
        self.deadline = clock() + limits.timeBudget
    }

    /// True once no further node may be read.
    public var exhausted: Bool { visited >= limits.maxNodes || expired }

    /// True once the shared time budget is used up. Checked between windows and between property reads while the windows are listed.
    public var expired: Bool { clock() > deadline }

    func spend() { visited += 1 }
}

public struct WalkedNode<N: AXNodeSource> {
    public var node: N
    public var control: Control
}

public struct AXWalkResult<N: AXNodeSource> {
    public var nodes: [WalkedNode<N>]
    /// True when the walk stopped with nodes still waiting (a cap was hit).
    public var truncated: Bool
    /// True when the depth cap stopped the walk from descending into a node that has children.
    public var depthCut: Bool = false
}

public enum AXTreeWalker {
    public static let maxValueLength = 200

    public static func isMenuBar(_ role: String) -> Bool { role == "AXMenuBar" }

    /// Roles that hold nothing below them. A node of any other role at the depth cap is assumed to have children without asking for them.
    static let leafRoles: Set<String> = [
        "AXStaticText", "AXImage", "AXSecureTextField", "AXCheckBox", "AXRadioButton", "AXSlider", "AXScrollBar", "AXValueIndicator",
        "AXBusyIndicator", "AXProgressIndicator", "AXIncrementor", "AXSplitter", "AXDisclosureTriangle",
    ]

    /// The Control for one node. A secure field's value is never read into it. Outside the target window (`inTargetWindow`
    /// false: a dialog or sheet in front of it) only static text is read for its value, because that is how a label names itself;
    /// the value of a field or text area there is never read.
    public static func control<N: AXNodeSource>(from node: N, path: String, window: String, windowSubrole: String,
                                                inTargetWindow: Bool = true, windowIdentifier: String = "") -> Control {
        let role = node.role
        let subrole = node.subrole
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        var value: String?
        if !secure, inTargetWindow || role == "AXStaticText", let v = node.valueText, !v.isEmpty { value = String(v.prefix(maxValueLength)) }
        var c = Control(role: role, subrole: subrole, title: node.title, description: node.descriptionText,
                        window: window, value: value, help: node.help, frame: node.frame, enabled: node.isEnabled,
                        actions: node.actions, pathID: path)
        c.windowSubrole = windowSubrole
        c.windowIdentifier = windowIdentifier
        c.inTargetWindow = inTargetWindow
        if inTargetWindow, LabelFlagger.isCandidateRole(role: role, subrole: subrole) {
            c.identifier = String(node.identifier.prefix(maxValueLength))
            c.titleElementText = String(node.titleElementText.prefix(maxValueLength))
        }
        return c
    }

    /// Breadth first from `root`. Stops (truncated) when the shared budget runs out. Secure text fields and menu bars are
    /// listed but not descended into. `rootPath` prefixes every path id ("0", "0/3", "0/3/1").
    public static func walk<N: AXNodeSource>(root: N, rootPath: String, windowTitle: String, windowSubrole: String,
                                             budget: AXWalkBudget, inTargetWindow: Bool = true, windowIdentifier: String = "") -> AXWalkResult<N> {
        var queue: [(node: N, path: String, depth: Int)] = [(root, rootPath, 0)]
        var head = 0
        var out: [WalkedNode<N>] = []
        var truncated = false
        var depthCut = false
        while head < queue.count {
            if budget.exhausted { truncated = true; break }
            let item = queue[head]
            head += 1
            budget.spend()
            let control = AXTreeWalker.control(from: item.node, path: item.path, window: windowTitle, windowSubrole: windowSubrole,
                                               inTargetWindow: inTargetWindow, windowIdentifier: windowIdentifier)
            out.append(WalkedNode(node: item.node, control: control))
            if !control.isSecure, !isMenuBar(control.role) {
                if item.depth >= budget.limits.maxDepth {
                    // At the depth cap nothing is fetched. The cut is reported for any node that could hold children (not the node or
                    // time cap: `truncated` stays as it was).
                    if !leafRoles.contains(control.role) { depthCut = true }
                } else if budget.expired {
                    truncated = true
                    break
                } else {
                    // Only as many children as could still be visited: the nodes left in the budget less those already waiting.
                    let room = min(budget.limits.maxChildrenPerNode, max(0, budget.limits.maxNodes - budget.visited - (queue.count - head)))
                    if room > 0 {
                        // One more than fits, to learn whether the list was cut.
                        let read = item.node.readChildren(limit: room + 1)
                        let kids = read.children
                        // A read that failed hides whatever is below this node, a twin included: the walk is partial.
                        if read.failed || kids.count > room { truncated = true }
                        for (i, kid) in kids.prefix(room).enumerated() { queue.append((kid, "\(item.path)/\(i)", item.depth + 1)) }
                    } else {
                        let probe = item.node.readChildren(limit: 1)
                        if probe.failed || !probe.children.isEmpty { truncated = true }   // no room left for what is below this node
                    }
                }
            }
        }
        return AXWalkResult(nodes: out, truncated: truncated, depthCut: depthCut)
    }
}

// MARK: windows

public struct AXWindowInfo: Equatable, Sendable {
    public var title: String
    public var subrole: String
    public var frame: CGRect?
    public var isMain: Bool
    public var isFocused: Bool
    /// AXModal.
    public var modalFlag: Bool
    /// Position in the app's window list, front first (0 is the frontmost). nil when unknown.
    public var zOrder: Int?
    /// AXIdentifier of the window; "" when the app sets none.
    public var identifier: String

    public init(title: String = "", subrole: String = "", frame: CGRect? = nil, isMain: Bool = false, isFocused: Bool = false,
                modalFlag: Bool = false, zOrder: Int? = nil, identifier: String = "") {
        self.title = title; self.subrole = subrole; self.frame = frame
        self.isMain = isMain; self.isFocused = isFocused; self.modalFlag = modalFlag; self.zOrder = zOrder; self.identifier = identifier
    }

    public static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog", "AXSheet"]

    /// A dialog, system dialog or sheet, or a window the app marks modal.
    public var isModal: Bool { modalFlag || AXWindowInfo.dialogSubroles.contains(subrole) }

    /// This window may be in front of `target`: it is higher in the window list, or either position is unknown (a modal is
    /// in front of what it blocks unless the list says otherwise).
    func mayBeInFront(of target: AXWindowInfo) -> Bool {
        guard let mine = zOrder, let theirs = target.zOrder else { return true }
        return mine < theirs
    }

    /// Content of this window may be read for the target `target`: it is a dialog, sheet or modal window, in front of it, and
    /// its frame (known) overlaps the target's (known). Everything else is rejected before any child or value getter runs.
    func contentMayBeRead(forTarget target: AXWindowInfo) -> Bool {
        guard isModal, mayBeInFront(of: target), let mine = frame, let theirs = target.frame else { return false }
        return mine.intersects(theirs)
    }
}

public struct WindowSelection: Equatable, Sendable {
    /// Index into the window list of the "target window": the one the screenshot shows.
    public var target: Int
    /// Walk order: the target first, then the others in list order.
    public var order: [Int]
    /// A dialog or sheet (not the target itself) that overlaps the target window is open.
    public var modalInFront: Bool
}

public enum WindowSelector {
    /// How far (points) each edge of a window may differ from SHEP_WINDOW_FRAME and still be "that window".
    public static let frameTolerance: CGFloat = 4

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }

    /// Target frame (within 4 pt; several matches are narrowed by title), then title (exact, else contains), else the main
    /// window, else the focused non-modal window, else the first non-modal window, else the first. With `preferFocused` the focused
    /// non-modal window comes before the main one: the window the keyboard (or VoiceOver) is in is the one the person means.
    public static func select(_ windows: [AXWindowInfo], targetFrame: CGRect?, targetTitle: String?, preferFocused: Bool = false) -> WindowSelection? {
        guard !windows.isEmpty else { return nil }
        let wanted = (targetTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func titleMatches(_ i: Int) -> Bool {
            let t = windows[i].title.lowercased()
            return !wanted.isEmpty && (t == wanted || t.contains(wanted))
        }
        // Several windows tie (same frame, or same title): the focused one that is not a dialog is the one meant, else the first listed.
        func focusedFirst(_ tied: [Int]) -> Int? {
            tied.first(where: { windows[$0].isFocused && !windows[$0].isModal }) ?? tied.first
        }
        var target: Int?
        if let f = targetFrame {
            let byFrame = windows.indices.filter { i in windows[i].frame.map { sameFrame($0, f) } ?? false }
            if byFrame.count > 1 { target = focusedFirst(byFrame.filter(titleMatches)) ?? focusedFirst(byFrame) }
            else { target = byFrame.first }
        }
        if target == nil, !wanted.isEmpty {
            // Exact title matches come before "contains" matches.
            target = focusedFirst(windows.indices.filter { windows[$0].title.lowercased() == wanted }) ?? focusedFirst(windows.indices.filter(titleMatches))
        }
        if target == nil, preferFocused { target = windows.indices.first(where: { windows[$0].isFocused && !windows[$0].isModal }) }
        if target == nil { target = windows.indices.first(where: { windows[$0].isMain }) }
        if target == nil { target = windows.indices.first(where: { windows[$0].isFocused && !windows[$0].isModal }) }
        if target == nil { target = windows.indices.first(where: { !windows[$0].isModal }) }
        let chosen = target ?? 0
        let targetRect = windows[chosen].frame
        var modalInFront = false
        for i in windows.indices where i != chosen && windows[i].isModal && windows[i].mayBeInFront(of: windows[chosen]) {
            if let a = targetRect, let b = windows[i].frame, !a.intersects(b) { continue }
            modalInFront = true
        }
        let order = [chosen] + windows.indices.filter { $0 != chosen }
        return WindowSelection(target: chosen, order: order, modalInFront: modalInFront)
    }
}

// MARK: whole read

public struct AXWindowEntry<N: AXNodeSource> {
    public var info: AXWindowInfo
    public var root: N
    public init(info: AXWindowInfo, root: N) { self.info = info; self.root = root }
}

public struct AXWindowSummary: Equatable, Sendable {
    public var info: AXWindowInfo
    public var isTarget: Bool
    public var nodesVisited: Int
    /// False when the shared deadline passed before this window's metadata was read; its info is then empty.
    public var examined: Bool = true
}

/// One window of an app as the reader meets it: the root node, and a way to read its metadata (title, subrole, frame, flags;
/// never content) that stops, returning nil, as soon as `expired` says the shared deadline has passed.
public struct AXWindowCandidate<N: AXNodeSource> {
    public var root: N
    public var readInfo: (_ expired: () -> Bool) -> AXWindowInfo?
    public init(root: N, readInfo: @escaping (_ expired: () -> Bool) -> AXWindowInfo?) {
        self.root = root; self.readInfo = readInfo
    }
}

public struct AXReadResult<N: AXNodeSource> {
    /// Index of the target window in `windows` (the order the caller listed them).
    public var target: Int
    public var windows: [AXWindowSummary]
    /// The target window's nodes, then other windows' nodes that overlap the target window's frame.
    public var nodes: [WalkedNode<N>]
    public var nodesVisited: Int
    public var truncated: Bool
    /// The depth cap cut off a subtree of some window that was read. The label scan counts this as a partial result; other readers ignore it.
    public var depthCut: Bool = false
    public var modalInFront: Bool
    public var controls: [Control] { nodes.map { $0.control } }
}

public enum AXTreeReader {
    /// Reads the target window and the dialogs or sheets in front of it, the target first, under one shared budget so the target
    /// cannot be starved by a dialog. No other window is touched: a window that is not the target and not a modal in front of it
    /// that overlaps it is rejected before any child, value, title or description getter runs. A dialog's controls are kept only
    /// when their frame intersects the target window's frame.
    public static func read<N: AXNodeSource>(windows: [AXWindowEntry<N>], targetFrame: CGRect?, targetTitle: String?,
                                             limits: AXWalkLimits = .standard, clock: @escaping () -> TimeInterval,
                                             preferFocused: Bool = false) -> AXReadResult<N>? {
        let budget = AXWalkBudget(limits: limits, clock: clock)
        return read(roots: windows.map { $0.root }, infos: windows.map { Optional($0.info) }, targetFrame: targetFrame,
                    targetTitle: targetTitle, budget: budget, preferFocused: preferFocused)
    }

    /// Same, but the windows' metadata is read here, one window at a time, under the same deadline as the walk: the deadline
    /// starts before the first window is listed (pass the `budget` made at the start of the whole read, or one is made now) and
    /// is checked between windows and, through `expired`, between property reads. Windows not examined in time are listed as
    /// such and are never read.
    public static func read<N: AXNodeSource>(candidates: [AXWindowCandidate<N>], targetFrame: CGRect?, targetTitle: String?,
                                             limits: AXWalkLimits = .standard, clock: @escaping () -> TimeInterval,
                                             budget: AXWalkBudget? = nil, preferFocused: Bool = false) -> AXReadResult<N>? {
        let shared = budget ?? AXWalkBudget(limits: limits, clock: clock)
        var infos: [AXWindowInfo?] = []
        for candidate in candidates {
            if shared.expired { infos.append(nil); continue }
            infos.append(candidate.readInfo { shared.expired })
        }
        return read(roots: candidates.map { $0.root }, infos: infos, targetFrame: targetFrame, targetTitle: targetTitle, budget: shared,
                    preferFocused: preferFocused)
    }

    private static func read<N: AXNodeSource>(roots: [N], infos: [AXWindowInfo?], targetFrame: CGRect?, targetTitle: String?,
                                              budget: AXWalkBudget, preferFocused: Bool) -> AXReadResult<N>? {
        let examined = infos.indices.filter { infos[$0] != nil }
        let examinedInfos = examined.compactMap { infos[$0] }
        guard let selection = WindowSelector.select(examinedInfos, targetFrame: targetFrame, targetTitle: targetTitle,
                                                    preferFocused: preferFocused) else { return nil }
        let target = examined[selection.target]
        let order = selection.order.map { examined[$0] }
        guard let targetInfo = infos[target] else { return nil }
        let targetRect = targetInfo.frame
        var kept: [WalkedNode<N>] = []
        var summaries = infos.map { AXWindowSummary(info: $0 ?? AXWindowInfo(), isTarget: false, nodesVisited: 0, examined: $0 != nil) }
        summaries[target].isTarget = true
        var truncated = false
        var depthCut = false
        for index in order {
            guard let info = infos[index] else { continue }
            let isTarget = index == target
            // Rejected here, before the first getter of any node of that window.
            if !isTarget, !info.contentMayBeRead(forTarget: targetInfo) { continue }
            let before = budget.visited
            let walked = AXTreeWalker.walk(root: roots[index], rootPath: String(index), windowTitle: info.title,
                                           windowSubrole: info.subrole, budget: budget, inTargetWindow: isTarget,
                                           windowIdentifier: info.identifier)
            summaries[index].nodesVisited = budget.visited - before
            if walked.truncated { truncated = true }
            if walked.depthCut { depthCut = true }
            if isTarget {
                kept.append(contentsOf: walked.nodes)
            } else if let rect = targetRect {
                kept.append(contentsOf: walked.nodes.filter { n in n.control.frame.map { rect.intersects($0) } ?? false })
            }
        }
        return AXReadResult(target: target, windows: summaries, nodes: kept, nodesVisited: budget.visited,
                            truncated: truncated, depthCut: depthCut, modalInFront: selection.modalInFront)
    }
}
