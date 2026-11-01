import Foundation

// Written for Shep.

/// Which of Shep's windows a VoiceOver announcement is posted on. VoiceOver does not speak an announcement posted on the
/// application element while its cursor is in another app (seen in a live run); a visible window of Shep's carries it.
public enum AnnouncementTarget: Equatable, Sendable {
    case card, dock, home, application

    /// The card when it shows (the line is on it), else the dog's dock, else the doghouse; the application only when Shep
    /// has no window on screen at all.
    public static func choose(cardVisible: Bool, dockVisible: Bool, homeVisible: Bool) -> AnnouncementTarget {
        if cardVisible { return .card }
        if dockVisible { return .dock }
        if homeVisible { return .home }
        return .application
    }
}

/// What kind of line an announcement is.
public enum AnnouncementKind: Equatable, Sendable {
    /// Where Shep is ("Shep is here.", "Shep went home to sleep."): stale once the moment has passed.
    case status
    /// Something the user needs to hear ("On it.", "Done.", a reply, an error).
    case line
}

/// When Shep's VoiceOver announcements go out. Nothing is said while the caller is speaking their question (push-to-talk or
/// "Hey Shep", until the final transcript): a status line from that time is dropped, and only the newest other line is said
/// once the question is over (a high-priority announcement cuts off the one before it anyway). Every other line is said when
/// asked; the finish beat's "Done." is the one exception (`requestUnlessLast`): it is not said again right after the walk's
/// own "Done." card. Pure: the app passes the clock and posts what comes back.
public struct AnnouncementGate: Sendable {
    /// How recent the walk's "Done." must be for the finish beat to time the bark from it (`FinishBeat.voiceOverStart`).
    public static let repeatWindow: TimeInterval = 2
    public private(set) var callerSpeaking = false
    /// The last line posted and when.
    public private(set) var lastLine: (text: String, at: TimeInterval)?
    private var held: (text: String, unlessLast: Bool)?

    public init() {}

    /// The lines to post now (none, or this one).
    public mutating func request(_ text: String, kind: AnnouncementKind, at now: TimeInterval) -> [String] {
        if callerSpeaking {
            if kind == .line { held = (text, false) }
            return []
        }
        return post(text, at: now)
    }

    /// Like `request` for a line, but nothing when the last line posted is this same text (the finish beat's "Done." after
    /// the walk's "Done." card).
    public mutating func requestUnlessLast(_ text: String, at now: TimeInterval) -> [String] {
        if callerSpeaking { held = (text, true); return [] }
        if let l = lastLine, l.text == text, abs(now - l.at) < Self.repeatWindow { return [] }
        return post(text, at: now)
    }

    /// A line to post `delay` from now (the app posts it then). It counts as posted at that time. While the caller speaks
    /// it is held like `request`'s and nothing is returned.
    public mutating func schedule(_ text: String, after delay: TimeInterval, at now: TimeInterval) -> [String] {
        if callerSpeaking { held = (text, false); return [] }
        return post(text, at: now + delay)
    }

    /// The scheduled line will not go out (its card went first): it no longer counts as said.
    public mutating func unschedule(at now: TimeInterval) {
        if let l = lastLine, l.at > now { lastLine = nil }
    }

    /// The question started (true) or ended (false). Returns the held line to post now, if any.
    public mutating func setCallerSpeaking(_ speaking: Bool, at now: TimeInterval) -> [String] {
        let wasSpeaking = callerSpeaking
        callerSpeaking = speaking
        guard wasSpeaking, !speaking, let line = held else { return [] }
        held = nil
        return line.unlessLast ? requestUnlessLast(line.text, at: now) : post(line.text, at: now)
    }

    /// Value-change notifications (the home indicator's "Shep is waking up") are posted only outside the question:
    /// VoiceOver speaks them, from Shep's window, over the caller.
    public var allowsStateNotifications: Bool { !callerSpeaking }

    /// When `text` was posted, if it is the last line and that was within `window` before `now`.
    public func lastPosted(of text: String, within window: TimeInterval, at now: TimeInterval) -> TimeInterval? {
        guard let l = lastLine, l.text == text, abs(now - l.at) < window else { return nil }   // later: scheduled
        return l.at
    }

    private mutating func post(_ text: String, at now: TimeInterval) -> [String] {
        lastLine = (text, now)
        return [text]
    }
}

extension FinishBeat {
    /// How long after it is posted VoiceOver has said "Done." (measured in a live VoiceOver run: it reads the dialog's name first,
    /// then "Done.", about 1.5 s in all). The VoiceOver woof never comes sooner.
    public static let doneSpokenSeconds: TimeInterval = 1.6

    /// Quiet kept between VoiceOver finishing "Done." and the bark (VoiceOver lowers other sound while it speaks).
    public static let quietAfterVoiceOver: TimeInterval = 0.4

    /// VoiceOver finished an announcement `elapsed` seconds into the beat: when the bark may come, or nil when it was not
    /// "Done." (another line finishing says nothing about "Done.").
    public static func voiceOverFinished(announcement: String?, elapsed: TimeInterval) -> TimeInterval? {
        guard announcement == FinishBeat.announcement else { return nil }
        return elapsed + quietAfterVoiceOver
    }

    /// The moment the beat's VoiceOver timing counts from: when "Done." was posted (with the walk's card, just before the
    /// beat) or will be (the held result card's, `AnnouncementGate.schedule`), or the beat's own start when it posts "Done."
    /// itself. A time further away than `AnnouncementGate.repeatWindow` is not this beat's.
    public static func voiceOverStart(beatStartedAt: TimeInterval, donePostedAt: TimeInterval?) -> TimeInterval {
        guard let t = donePostedAt, abs(beatStartedAt - t) < AnnouncementGate.repeatWindow else { return beatStartedAt }
        return t
    }
}

/// How a call behaves while VoiceOver runs. Found live (a live VoiceOver run): VoiceOver speaks Shep's announcements only while its cursor
/// is in one of Shep's windows; it moves its cursor into a Shep window that appears and back to the app (reading it again)
/// when that window goes; it speaks the home indicator's value changes.
/// Whether Shep says "Shep is here." when it docks. Not after a call made for a question the caller has just asked (the
/// talk key or "Hey Shep" under VoiceOver, where Shep stays home until the question is over): they know they called, and
/// "On it." follows (a live VoiceOver run). Any other call says it, including the talk key going down before anything is asked (the
/// question may still be cancelled or empty). Only the call that sets Shep off decides: from home, or turning it around on
/// the way home; a call while it is waking, crossing or docked changes nothing, as in the lifecycle. Pure.
public struct ArrivalAnnouncement: Equatable {
    private var quiet = false

    public init() {}

    public mutating func call(from state: LifecycleState, forQuestion: Bool) {
        if state == .asleep || state == .returning { quiet = forQuestion }
    }

    /// Shep docked: whether to say "Shep is here."; the next trip starts fresh.
    public mutating func docked() -> Bool {
        defer { quiet = false }
        return !quiet
    }
}

public enum VoiceOverFlow {
    /// The read-only pill with the question as it is heard. Not under VoiceOver: it would pull the cursor away while the
    /// caller is still speaking (they know what they said). The first card after the question is "On it.".
    public static func showsQuestionPill(voiceOverRunning: Bool) -> Bool { !voiceOverRunning }

    /// Whether Shep wakes and comes out while the caller is still asking. Not under VoiceOver: each Shep window that appears
    /// (the doghouse waking, the dock) pulls the VoiceOver cursor and is read, over the caller. Shep comes out with the request.
    public static func wakesDuringQuestion(voiceOverRunning: Bool) -> Bool { !voiceOverRunning }

    /// After Approve, with VoiceOver, the card keeps the keyboard (and so the VoiceOver cursor) and shows the result there:
    /// VoiceOver says "Done." where it already is, the bark follows in the quiet after it, and focus goes back to the app
    /// when Shep walks home (or after `resultHoldSeconds`). Deny, Escape and a replaced card give focus back at once.
    public static func holdsCardForResult(voiceOverRunning: Bool, choice: String?) -> Bool {
        voiceOverRunning && choice == "approve"
    }

    /// The longest the card keeps the keyboard after Approve.
    public static let resultHoldSeconds: TimeInterval = 5

    /// How long after the held card shows its result the line is posted. VoiceOver first reads the card's changed content
    /// as the dialog's name ("Shep, Dialog"); a line posted at once was lost under it (a live VoiceOver run). It counts as said
    /// from when it goes out (`AnnouncementGate.schedule`), and the bark is timed from then (`FinishBeat.voiceOverStart`).
    public static let heldResultPostDelay: TimeInterval = 0.9
}
