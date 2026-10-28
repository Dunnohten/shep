import AppKit
import ShepCore

// Written for Shep.

/// `--demo-backdrop`: a plain, soft-coloured, borderless window behind everything Shep shows, so a recording of its rectangle
/// holds only Shep-owned pixels and the test window. It sits at the normal window level directly below the test window (so
/// above the desktop and every other app's window, below the test window and below all of Shep's floating panels), under the
/// menu bar, ignores the mouse, and is visible to screen recording (it is not excluded from anything).
@MainActor
final class DemoBackdrop {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A calm light lavender-grey; the dog's palettes and the test window both read well on it.
    static let color = NSColor(srgbRed: 0.90, green: 0.89, blue: 0.94, alpha: 1)

    private let panel: NSPanel

    init() {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = true
        panel.backgroundColor = Self.color
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .readOnly   // recorded: never hidden from capture, whatever the privacy setting says
    }

    var isShown: Bool { panel.isVisible }

    /// Covers `rect` (Cocoa coordinates) and sits directly below the window numbered `windowNumber`; without a window number
    /// it does not show at all (it would cover the test window).
    @discardableResult
    func show(rect: CGRect, belowWindow windowNumber: Int?) -> Bool {
        guard let windowNumber else { return false }
        panel.setFrame(rect, display: true)
        panel.order(.below, relativeTo: windowNumber)
        return panel.isVisible
    }

    func hide() { panel.orderOut(nil) }

    /// The window server's number for `pid`'s on-screen window at `frame` (global top-left points, like AX), if there is one.
    /// Needs no permission: owner, bounds and number are public; only window titles are withheld.
    static func windowNumber(pid: pid_t, frame: CGRect, tolerance: CGFloat = 3) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in list {
            guard (entry[kCGWindowOwnerPID as String] as? Int) == Int(pid), (entry[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(rect.minX - frame.minX) <= tolerance, abs(rect.minY - frame.minY) <= tolerance,
                  abs(rect.width - frame.width) <= tolerance, abs(rect.height - frame.height) <= tolerance,
                  let number = entry[kCGWindowNumber as String] as? Int else { continue }
            return number
        }
        return nil
    }
}
