import AppKit
import ShepCore

// Written for Shep.

/// Keeps Shep's own windows out of screenshots, screen sharing and recordings.
/// On by default. For demo videos, either untick "Hide Shep from Screen Sharing" in the menu or launch with `--capturable`.
enum ScreenPrivacy {
    static let settingKey = "shep.hideFromCapture"
    static let capturableFlag = "--capturable"

    private static var saved: Bool? {
        UserDefaults.standard.object(forKey: settingKey) == nil ? nil : UserDefaults.standard.bool(forKey: settingKey)
    }

    /// The saved choice; true until the owner changes it.
    static var hidden: Bool { SharingPolicy.hidden(saved: saved, capturableLaunch: false) }

    /// `--capturable` on the command line wins over the saved choice, for this launch only.
    static var capturableLaunch: Bool {
        CommandLine.arguments.contains(capturableFlag)
    }

    static var sharingType: NSWindow.SharingType {
        SharingPolicy.hidden(saved: saved, capturableLaunch: capturableLaunch) ? .none : .readOnly
    }

    /// Saves the choice and applies it to every window and panel Shep owns.
    @MainActor static func set(_ hide: Bool) {
        UserDefaults.standard.set(hide, forKey: settingKey)
        for window in NSApp.windows { window.sharingType = sharingType }
    }
}
