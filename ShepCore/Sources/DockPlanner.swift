import CoreGraphics
import Foundation

/// What the window tracker saw about the frontmost app, before any decision.
public struct WindowObservation: Equatable {
    public var pid: Int32
    public var bundleID: String?
    /// Focused window frame in AX coordinates (top-left origin); nil when the app has no focused window.
    public var axFrame: CGRect?
    public var isFullScreen: Bool
    public var subrole: String?
    /// The window's title, when readable. Used to estimate where the title text sits.
    public var title: String?
    /// Frames (AX coordinates) of what lives in the title bar band: title text, toolbar buttons, fields.
    public var titleBarFrames: [CGRect]
    /// True when `titleBarFrames` already holds the title text itself, so no estimate is needed.
    public var titleMeasured: Bool
    /// Which focus picked the window (`FocusTargetPolicy`); nil when there is no window.
    public var source: FocusSource?

    public init(pid: Int32, bundleID: String?, axFrame: CGRect?, isFullScreen: Bool = false, subrole: String? = nil,
                title: String? = nil, titleBarFrames: [CGRect] = [], titleMeasured: Bool = false, source: FocusSource? = nil) {
        self.pid = pid; self.bundleID = bundleID; self.axFrame = axFrame
        self.isFullScreen = isFullScreen; self.subrole = subrole
        self.title = title; self.titleBarFrames = titleBarFrames; self.titleMeasured = titleMeasured
        self.source = source
    }
}

public struct DockPlan: Equatable {
    public var placement: TabPlacement
    /// Short human reason, for the --dock-demo log.
    public var note: String
    public init(placement: TabPlacement, note: String) { self.placement = placement; self.note = note }
}

public enum DockPlanner {
    /// System UI that can be frontmost without being a window worth docking to.
    public static let ignoredBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.loginwindow", "com.apple.WindowManager", "com.apple.notificationcenterui",
        "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight",
    ]

    /// Standard windows and dialogs only; apps that report no subrole are allowed (some Electron apps).
    public static func isDockableSubrole(_ subrole: String?) -> Bool {
        guard let s = subrole, !s.isEmpty else { return true }
        return s == "AXStandardWindow" || s == "AXDialog"
    }

    public static func plan(_ obs: WindowObservation?, ownPID: Int32, screens: [CGRect], usable: [CGRect]? = nil, primaryScreenHeight: CGFloat,
                            liveTarget: String? = nil) -> DockPlan {
        guard let obs else { return DockPlan(placement: .hidden, note: "no frontmost app") }
        if obs.pid == ownPID { return DockPlan(placement: .hidden, note: "frontmost is Shep itself") }
        // A live run bound to an app (`--live-target`) never follows another one. The note names at most that app's bundle id.
        if let target = liveTarget, !LiveBinding.mayRead(bundleID: obs.bundleID, target: target, ownBundleID: nil) {
            return DockPlan(placement: .hidden, note: "live run bound to \(LiveTargetGate.shown(target)): front app is \(LiveTargetGate.shown(obs.bundleID))")
        }
        if let id = obs.bundleID, ignoredBundleIDs.contains(id) { return DockPlan(placement: .hidden, note: "ignored system app \(id)") }
        guard let ax = obs.axFrame else { return DockPlan(placement: .hidden, note: "no focused window (desktop?)") }
        guard isDockableSubrole(obs.subrole) else { return DockPlan(placement: .hidden, note: "subrole \(obs.subrole ?? "?") not dockable") }
        let cocoa = AXCoordinates.cocoaRect(fromAX: ax, primaryScreenHeight: primaryScreenHeight)
        var obstacles = obs.titleBarFrames.map { AXCoordinates.cocoaRect(fromAX: $0, primaryScreenHeight: primaryScreenHeight) }
        if !obs.titleMeasured, let title = obs.title, let guess = DockGeometry.estimatedTitleExtent(title: title, window: cocoa) {
            obstacles.append(guess)
        }
        if obs.isFullScreen { return DockPlan(placement: .hidden, note: "full screen: no title bar, no tab") }
        let placement = TabGeometry.place(window: cocoa, isFullScreen: false, screens: screens, usable: usable, obstacles: obstacles)
        switch placement {
        case .tab(let l):
            let how = l.style == .above ? "tab above the title bar" : "tab inside the title bar (no room above)"
            return DockPlan(placement: placement, note: obstacles.isEmpty ? how : "\(how), clear of \(obstacles.count) title-bar item(s)")
        case .hidden: return DockPlan(placement: placement, note: "window too small or off-screen")
        }
    }
}
