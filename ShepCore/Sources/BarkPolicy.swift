import Foundation

// Written for Shep.

/// Whether the finish bark plays, and how loud. The bark has its own switch ("Bark when done", on by default) and volume.
/// Two quieter settings are honoured on top of that:
/// - macOS "Play user interface sound effects" off: no bark at all (the bark is an interface sound).
/// - Shep's "Speak replies" off: the bark still plays (it is the only sign that a task is done without looking), at half volume.
/// The result is the player's volume; the system output volume applies after it.
public enum BarkPolicy {
    public static let quietFactor = 0.5

    /// nil means no bark.
    public static func volume(barkWhenDone: Bool, barkVolume: Double, speakReplies: Bool, systemSoundEffects: Bool) -> Double? {
        guard barkWhenDone, systemSoundEffects, barkVolume.isFinite else { return nil }
        let v = min(1, max(0, barkVolume)) * (speakReplies ? 1 : quietFactor)
        return v > 0 ? v : nil
    }

    /// The macOS "Play user interface sound effects" setting (global key `com.apple.sound.uiaudio.enabled`); absent means on.
    public static func systemSoundEffects(globalValue: Any?) -> Bool {
        if let n = globalValue as? NSNumber { return n.intValue != 0 }
        if let b = globalValue as? Bool { return b }
        return true
    }
}

/// Setup's words for what used to be said on every approval card.
public enum OnboardingCopy {
    public static let asksFirst = "Shep asks before every action. It shows you what it wants to press, click or type, and does it only when you choose Approve. Cancel, or Escape, and nothing happens."
}
