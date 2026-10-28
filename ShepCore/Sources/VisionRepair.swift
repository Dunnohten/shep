import CoreGraphics
import Foundation

// Provenance: written on 2026-10-26 at about 11:44 AM CT (after the 11:00 AM CT start of the hackathon) on the author's earlier
// working branch for this same hackathon, reviewed at 11:52 AM CT, and carried into this repository.

// "Fix this screen" (Meta hackathon, 2026-10-26): controls an app's Accessibility tree doesn't expose (unlabeled icon
// buttons, custom-drawn controls) are found on a screenshot of its window by SAM 3.1, named by Muse Spark, mapped to
// screen points, merged with the AX list (duplicates removed by overlap) and numbered for speech. Pure logic: capture,
// the network and the click live in the app layer. Nothing is sent unless the owner switched it on (MetaVisionSettings).

/// The owner's opt-in. Off until switched on in Settings: no screenshot leaves the Mac before that.
public enum MetaVisionSettings {
    public static let sendScreenshotsKey = "shep.meta.sendScreenshots"
    public static func sendScreenshots(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: sendScreenshotsKey) }
    public static func setSendScreenshots(_ on: Bool, _ defaults: UserDefaults = .standard) { defaults.set(on, forKey: sendScreenshotsKey) }

    /// Apps whose windows are never captured for Meta, whatever the setting (see ControlPolicy).
    public static func mayCapture(bundleID: String) -> Bool { ControlPolicy.mayCapture(bundleID: bundleID) }
}

/// How a window screenshot lines up with the screen. `windowFrame` is the window's bounds in global points with a
/// top-left origin (CGWindowList's kCGWindowBounds; CGEvent uses the same space). The PNG is the window alone, captured
/// without its shadow (`screencapture -o -l <id>`), so its pixels cover exactly `windowFrame` at the backing scale.
public struct CaptureGeometry: Equatable, Sendable {
    public var windowFrame: CGRect
    public var imageSize: CGSize
    /// The display's backing scale (2 on Retina), used only when a size is missing.
    public var scale: Double
    public init(windowFrame: CGRect, imageSize: CGSize, scale: Double) {
        self.windowFrame = windowFrame; self.imageSize = imageSize; self.scale = scale
    }

    /// Pixels per point, per axis: measured from the image when both sizes are known (a window on a 1x display next to
    /// a Retina one, or a scaled display mode), else the backing scale.
    public var scaleX: Double { windowFrame.width > 0 && imageSize.width > 0 ? Double(imageSize.width / windowFrame.width) : max(scale, 1) }
    public var scaleY: Double { windowFrame.height > 0 && imageSize.height > 0 ? Double(imageSize.height / windowFrame.height) : max(scale, 1) }

    /// The conversions between pixels, normalized and points live in CoordinateSpace.
    public var space: CoordinateSpace {
        let known = windowFrame.width > 0 && windowFrame.height > 0 && imageSize.width > 0 && imageSize.height > 0
        if known { return CoordinateSpace(windowFrame: windowFrame, imageSize: imageSize) }
        // A missing size: fall back to the backing scale, as scaleX / scaleY do.
        let frame = CGRect(x: windowFrame.minX, y: windowFrame.minY, width: imageSize.width / CGFloat(scaleX), height: imageSize.height / CGFloat(scaleY))
        return CoordinateSpace(windowFrame: frame, imageSize: imageSize)
    }

    /// A box in screenshot pixels as a rectangle in global screen points.
    public func screenRect(forPixels px: CGRect) -> CGRect { space.screenRect(fromPixels: px) }
}

/// A control SAM found, numbered for Muse Spark, before it is merged.
public struct VisionCandidate: Equatable, Sendable {
    public var id: Int
    public var pixelBox: CGRect
    public var screenFrame: CGRect
    public var concept: String
    public var score: Double
    public init(id: Int, pixelBox: CGRect, screenFrame: CGRect, concept: String, score: Double) {
        self.id = id; self.pixelBox = pixelBox; self.screenFrame = screenFrame; self.concept = concept; self.score = score
    }
    public var center: CGPoint { CGPoint(x: screenFrame.midX, y: screenFrame.midY) }
}

public struct VisionRepairResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case ok, notAllowed, failed(String) }
    public var status: Status
    /// The merged list, numbered 1...n: the app's own controls first, then the ones found on screen in reading order.
    public var items: [Control]
    public var visionCount: Int { items.filter(\.fromVision).count }
    /// Plain notes for the log (never screenshot content): failed concepts, dropped controls.
    public var notes: [String]
}

public enum VisionRepair {
    /// SAM concept prompts, one request each.
    public static let defaultConcepts = ["button", "text field", "checkbox", "icon"]
    /// Overlap at or above this is the same control.
    public static let sameControlIoU = 0.5
    /// More than this many found controls is too many to read out; the highest-scoring ones are kept.
    public static let maxVisionControls = 24

    /// A box mostly inside a comparable-size one (an icon inside its button's frame) is the same control.
    public static let nestedFraction = 0.8
    public static let nestedMaxAreaRatio = 3.0

    /// The same control seen twice: strong overlap, or one box sitting inside a similar-sized other (not inside a big
    /// container such as a window or scroll area, which contains everything).
    public static func sameControl(_ a: CGRect, _ b: CGRect, iouThreshold: Double = sameControlIoU) -> Bool {
        if iou(a, b) >= iouThreshold { return true }
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return false }
        let inter = Double(i.width * i.height)
        let areaA = Double(a.width * a.height), areaB = Double(b.width * b.height)
        let small = min(areaA, areaB), big = max(areaA, areaB)
        return small > 0 && inter / small >= nestedFraction && big <= small * nestedMaxAreaRatio
    }

    public static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    /// The AX role a found control is listed with, from Muse's role or SAM's concept.
    public static func axRole(for kind: String) -> String {
        if let role = ControlRole.recognized(kind) { return role.axRole }
        switch kind.lowercased() {
        case "text field", "textfield", "field", "search field", "input": return "AXTextField"
        default: return "AXButton"   // buttons, icons and anything else that looks pressable
        }
    }

    /// A box that overlaps an enabled, pressable AX control this much, or whose centre is inside its frame grown by
    /// `duplicateSlop` points, is that control (a detector box around the same icon is usually a different size).
    public static let duplicateIoU = 0.3
    public static let duplicateSlop: CGFloat = 4
    /// The centre rule ignores AX frames much bigger than the box: a large pressable row holds many things.
    public static let duplicateMaxAreaRatio = 9.0

    /// What `axDuplicate` found for a box.
    public enum DuplicateResolution: Equatable {
        case none
        case one(Control)
        /// Two or more controls fit equally well; the box is neither merged into a guessed one nor offered on its own.
        case ambiguous
    }

    /// The enabled AX control with a press action that `screen` is the same as, if any. A better overlap (IoU) wins; among
    /// equal scores (all centre-only matches score the same) the nearer centre wins, then the smaller area, in any array order;
    /// a tie that remains is `.ambiguous`.
    public static func axDuplicateResolution(of screen: CGRect, ax: [Control]) -> DuplicateResolution {
        guard screen.width > 0, screen.height > 0 else { return .none }
        let centre = CGPoint(x: screen.midX, y: screen.midY)
        var fits: [DuplicateFit] = []
        for c in ax {
            guard c.enabled, !c.fromVision, c.actions.contains("AXPress"), let f = c.frame, f.width > 0, f.height > 0,
                  !RoleResolver.containerRoles.contains(c.role) else { continue }
            let overlap = iou(f, screen)
            var score = overlap >= duplicateIoU ? 1 + overlap : 0
            if score == 0 {
                let grown = f.insetBy(dx: -duplicateSlop, dy: -duplicateSlop)
                let ratio = Double(f.width * f.height) / Double(screen.width * screen.height)
                if grown.contains(centre), ratio <= duplicateMaxAreaRatio { score = 0.5 }
            }
            guard score > 0 else { continue }
            let dx = Double(f.midX - centre.x)
            let dy = Double(f.midY - centre.y)
            fits.append(DuplicateFit(control: c, score: score, distance: (dx * dx + dy * dy).squareRoot(), area: Double(f.width * f.height)))
        }
        guard var best = fits.first else { return .none }
        var tied = false
        for fit in fits.dropFirst() {
            if fit.isBetter(than: best) { best = fit; tied = false }
            else if !best.isBetter(than: fit) { tied = true }
        }
        return tied ? .ambiguous : .one(best.control)
    }

    /// One AX control that fits a box, with what ranks the fits.
    struct DuplicateFit {
        var control: Control
        var score: Double
        var distance: Double
        var area: Double

        /// Higher score, else nearer centre, else smaller area. Equal on all three is not better either way.
        func isBetter(than other: DuplicateFit) -> Bool {
            if score != other.score { return score > other.score }
            if abs(distance - other.distance) > 1e-6 { return distance < other.distance }
            if abs(area - other.area) > 1e-6 { return area < other.area }
            return false
        }
    }

    /// The control `screen` is the same as, or nil when there is none or the choice is ambiguous.
    public static func axDuplicate(of screen: CGRect, ax: [Control]) -> Control? {
        if case .one(let c) = axDuplicateResolution(of: screen, ax: ax) { return c }
        return nil
    }

    /// True when the box is (or may be) a control the app lists, so it must not become a second, click-only control.
    /// An ambiguous box counts: it is dropped rather than guessed.
    public static func isAXDuplicate(_ screen: CGRect, ax: [Control]) -> Bool { axDuplicateResolution(of: screen, ax: ax) != .none }

    /// Far taller than wide and tall in absolute terms (more than 3x its width and more than 100 pt): a strip of toolbar
    /// or title area, not a control.
    public static func isImplausibleShape(_ r: CGRect) -> Bool {
        r.width > 0 && r.height > 100 && r.height > 3 * r.width
    }

    /// SAM regions as numbered candidates: on-screen, not already in the AX list (overlap, or the same name when the AX
    /// list has no frames), one per control (non-maximum suppression across concepts), in reading order, capped.
    public static func candidates(from regions: [SAMRegion], geometry: CaptureGeometry, ax: [Control],
                                  iouThreshold: Double = sameControlIoU, limit: Int = maxVisionControls) -> [VisionCandidate] {
        let axFrames = ax.compactMap(\.frame)
        var kept: [(SAMRegion, CGRect)] = []
        for r in regions.sorted(by: { $0.score > $1.score }) {
            let screen = geometry.screenRect(forPixels: r.box)
            guard screen.width >= 1, screen.height >= 1 else { continue }
            if isImplausibleShape(screen) { continue }
            if isAXDuplicate(screen, ax: ax) { continue }
            if axFrames.contains(where: { sameControl($0, screen, iouThreshold: iouThreshold) }) { continue }
            if kept.contains(where: { sameControl($0.1, screen, iouThreshold: iouThreshold) }) { continue }
            kept.append((r, screen))
            if kept.count == limit { break }
        }
        let ordered = readingOrder(kept.map { $0.1 }).map { kept[$0] }
        return ordered.enumerated().map { i, k in
            VisionCandidate(id: i + 1, pixelBox: k.0.box, screenFrame: k.1, concept: k.0.concept, score: k.0.score)
        }
    }

    /// Indexes of `frames` top-to-bottom, then left-to-right within a row (rows: centres within half a typical height).
    /// Rows are built first (walking down by centre, a new row when a centre is more than the tolerance below the row's
    /// first one), then each row is sorted by x: a deterministic order, unlike a pairwise "close enough" comparator.
    public static func readingOrder(_ frames: [CGRect]) -> [Int] {
        let heights = frames.map(\.height).sorted()
        let rowTolerance = max(4, (heights.isEmpty ? 20 : heights[heights.count / 2]) / 2)
        let byY = frames.indices.sorted { (frames[$0].midY, frames[$0].minX, $0) < (frames[$1].midY, frames[$1].minX, $1) }
        var rows: [[Int]] = []
        for i in byY {
            if let first = rows.last?.first, frames[i].midY - frames[first].midY <= rowTolerance { rows[rows.count - 1].append(i) }
            else { rows.append([i]) }
        }
        return rows.flatMap { $0.sorted { (frames[$0].minX, $0) < (frames[$1].minX, $1) } }
    }

    /// The found controls as list items, named by Muse Spark (or "unlabeled <concept>" when it gave no usable name).
    public static func visionItems(_ candidates: [VisionCandidate], labels: [Int: MuseLabel], window: String) -> [Control] {
        candidates.map { c in
            let muse = labels[c.id]
            let raw = muse?.name ?? ""
            let name = raw.isEmpty || raw.lowercased() == "unlabeled" ? "unlabeled \(c.concept)" : raw
            return Control(index: c.id, role: axRole(for: muse?.role ?? c.concept), title: name, window: window, value: nil,
                    frame: c.screenFrame, actions: [], pathID: "v\(c.id)", fromVision: true)
        }
    }

    /// AX controls first (their order), then found ones; renumbered 1...n. A found control whose name matches an AX
    /// control's label is dropped when the AX list carries no frames to compare (it is the same control).
    public static func merge(ax: [Control], vision: [Control]) -> [Control] {
        let axHasFrames = ax.contains { $0.frame != nil }
        let axNames = Set(ax.map { $0.label.lowercased().trimmingCharacters(in: .whitespaces) })
        let extra = vision.filter { axHasFrames || !axNames.contains($0.label.lowercased().trimmingCharacters(in: .whitespaces)) }
        return (ax + extra).enumerated().map { $1.renumbered($0 + 1) }
    }

    /// The whole repair. Never throws: on any failure the AX list comes back unchanged with the reason.
    public static func run(png: Data, geometry: CaptureGeometry, ax: [Control], bundleID: String, window: String,
                           request: String?, vision: (any MetaVisioning)?, sendAllowed: Bool,
                           concepts: [String] = defaultConcepts) async -> VisionRepairResult {
        await run(png: png, geometry: geometry, ax: ax, bundleID: bundleID, window: window, request: request, vision: vision,
                  allowed: { sendAllowed }, concepts: concepts)
    }

    /// `allowed` is asked again before every upload, so switching the setting off mid-repair stops the next request.
    public static func run(png: Data, geometry: CaptureGeometry, ax: [Control], bundleID: String, window: String,
                           request: String?, vision: (any MetaVisioning)?, allowed: @Sendable () -> Bool,
                           concepts: [String] = defaultConcepts) async -> VisionRepairResult {
        let unchanged = ax.enumerated().map { $1.renumbered($0 + 1) }
        let off = VisionRepairResult(status: .notAllowed, items: unchanged, notes: ["screenshots are off"])
        guard allowed(), MetaVisionSettings.mayCapture(bundleID: bundleID) else {
            return VisionRepairResult(status: .notAllowed, items: unchanged, notes: ["screenshots are off"])
        }
        guard let vision else { return VisionRepairResult(status: .failed(MetaError.noKey.localizedDescription), items: unchanged, notes: []) }
        var notes: [String] = []
        var regions: [SAMRegion] = []
        var failures = 0
        for concept in concepts {
            guard allowed() else { return off }
            do { regions += try await vision.segment(png: png, imageSize: geometry.imageSize, concept: concept) }
            catch { failures += 1; notes.append("SAM \(concept): \(Redact.scrub(error.localizedDescription))") }
        }
        if failures == concepts.count, !concepts.isEmpty {
            return VisionRepairResult(status: .failed(notes.first ?? "SAM failed"), items: unchanged, notes: notes)
        }
        let found = candidates(from: regions, geometry: geometry, ax: ax)
        var labels: [Int: MuseLabel] = [:]
        if !found.isEmpty {
            guard allowed() else { return off }
            do { labels = try await vision.name(png: png, candidates: found, request: request) }
            catch { notes.append("Muse names: \(Redact.scrub(error.localizedDescription))") }
            if labels.isEmpty { notes.append("no usable names from Muse; found controls are listed as unlabeled") }
        }
        var items = visionItems(found, labels: labels, window: window)
        let before = items.count
        items = items.filter { ControlPolicy.refusal($0, bundleID: bundleID) == nil }
        if items.count < before { notes.append("left out \(before - items.count) found control(s) Shep never presses (money, sign-in, delete…)") }
        return VisionRepairResult(status: .ok, items: merge(ax: ax, vision: items), notes: notes)
    }

    /// The numbered list Shep reads out. Found-on-screen controls say so; long lists stop at `limit` and say how many more.
    public static func spokenList(_ items: [Control], limit: Int = 15) -> String {
        guard !items.isEmpty else { return "I can't find any controls I can use in this window." }
        let shown = items.prefix(limit).map { "\($0.index): \($0.label), \($0.kind)\($0.fromVision ? ", found on screen" : "")." }
        let more = items.count > limit ? " And \(items.count - limit) more." : ""
        return shown.joined(separator: " ") + more
    }

    /// One sentence: what's here and what can be done.
    public static func summary(_ items: [Control], appName: String) -> String {
        let n = items.count, v = items.filter(\.fromVision).count
        guard n > 0 else { return "I can't find any controls I can use in \(appName)." }
        let found = v == 0 ? "" : (v == n ? ", all found on the screen" : ", \(v) of them found on the screen")
        return "\(appName) has \(n) control\(n == 1 ? "" : "s") I can use\(found); say “press” and a number."
    }
}
