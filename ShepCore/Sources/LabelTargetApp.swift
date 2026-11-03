import Foundation

// Written for Shep.

/// Which app "fix this screen" and "clear labels for this app" mean. Both ask here, so they never disagree: the app owning the window the
/// dog sits on comes first (the tracker's window, which follows VoiceOver's focus and the keyboard, see `FocusTargetPolicy`); the front app
/// only when the dog has no window. Shep itself is never the target.
public enum LabelTargetApp {
    public static func choose(dogPID: Int32?, frontPID: Int32?, ownPID: Int32) -> Int32? {
        if let dog = dogPID, dog != ownPID { return dog }
        if let front = frontPID, front != ownPID { return front }
        return nil
    }
}
