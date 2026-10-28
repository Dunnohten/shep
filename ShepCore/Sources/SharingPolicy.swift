import Foundation

// Written for Shep.

/// Whether Shep's own windows are hidden from screenshots, screen sharing and recordings. On until the owner turns it off;
/// `--capturable` on the command line wins for that launch. Every window Shep creates reads this when it is created
/// (Setup, Settings, the dock, the doghouse, the traveller), and `ScreenPrivacy.set` updates the ones already open.
public enum SharingPolicy {
    public static func hidden(saved: Bool?, capturableLaunch: Bool) -> Bool {
        if capturableLaunch { return false }
        return saved ?? true
    }
}
