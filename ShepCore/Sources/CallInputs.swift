import Foundation

/// Written for Shep.
/// The ways to call Shep that are not a click: a global shortcut (Carbon RegisterEventHotKey, no extra permission) and a
/// push-to-talk modifier key. Pure descriptions and rules; the app registers and listens.

/// Carbon modifier masks (the values of cmdKey, shiftKey, optionKey, controlKey).
public enum HotKeyModifier {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
}

public struct HotKeySpec: Equatable {
    /// Virtual key code (kVK_*).
    public var keyCode: UInt32
    /// Carbon modifier mask.
    public var modifiers: UInt32
    public var name: String

    public init(keyCode: UInt32, modifiers: UInt32, name: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.name = name
    }

    public static let keyCodeSpace: UInt32 = 49

    /// Stable id for storing the choice (key code and modifier mask).
    public var id: String { "\(keyCode)-\(modifiers)" }

    /// Control-Shift-Command-Space. The first choice, Control-Option-Space, is taken: it is the Input Sources "select next
    /// source" shortcut and Control-Option is VoiceOver's own modifier (VO-Space presses the item under the VoiceOver cursor),
    /// so it would break VoiceOver users. Control-Command-Space is the emoji picker, so Shift is added. Settings can change it later.
    public static let call = HotKeySpec(keyCode: keyCodeSpace,
                                        modifiers: HotKeyModifier.control | HotKeyModifier.shift | HotKeyModifier.command,
                                        name: "Control-Shift-Command-Space")

    /// Offered in Settings. The second one is the originally requested shortcut, with its conflicts spelled out.
    public static let presets: [HotKeySpec] = [
        call,
        HotKeySpec(keyCode: keyCodeSpace, modifiers: HotKeyModifier.control | HotKeyModifier.option,
                   name: "Control-Option-Space (clashes with Input Sources and VoiceOver)"),
        HotKeySpec(keyCode: keyCodeSpace, modifiers: HotKeyModifier.control | HotKeyModifier.shift, name: "Control-Shift-Space"),
    ]

    /// System shortcuts a spec must not silently collide with, by key code and modifiers (what the check below knows).
    /// Not exhaustive: the usual suspects around the space bar.
    public static let knownSystemShortcuts: [(keyCode: UInt32, modifiers: UInt32, what: String)] = [
        (keyCodeSpace, HotKeyModifier.command, "Spotlight"),
        (keyCodeSpace, HotKeyModifier.command | HotKeyModifier.option, "Finder search"),
        (keyCodeSpace, HotKeyModifier.control, "previous input source"),
        (keyCodeSpace, HotKeyModifier.control | HotKeyModifier.option, "next input source, and VoiceOver's VO-Space"),
        (keyCodeSpace, HotKeyModifier.control | HotKeyModifier.command, "emoji and symbols"),
    ]

    /// What this shortcut collides with, if it is one of the known ones.
    public var systemConflict: String? {
        HotKeySpec.knownSystemShortcuts.first(where: { $0.keyCode == keyCode && $0.modifiers == modifiers })?.what
    }

    /// A shortcut needs at least one modifier, or every press of the key would call Shep.
    public var isValid: Bool {
        modifiers & (HotKeyModifier.command | HotKeyModifier.shift | HotKeyModifier.option | HotKeyModifier.control) != 0
    }
}

/// The key held to talk. Raw values are what Settings stores.
public enum PushToTalkKey: String, CaseIterable, Equatable {
    case rightOption, rightCommand, rightControl

    public static let `default` = PushToTalkKey.rightOption

    public var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    /// The device-dependent flag bit for this physical key (NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK, NX_DEVICERCTLKEYMASK):
    /// set in `NSEvent.modifierFlags.rawValue` while that exact key is down, unlike the generic `.option` flag, which
    /// also reads true for the left key.
    public var deviceMask: UInt {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        }
    }

    public var title: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        }
    }

    public func isDown(rawFlags: UInt) -> Bool { rawFlags & deviceMask != 0 }

    /// Every device-dependent modifier bit (left and right control, shift, command, option).
    static let allDeviceBits: UInt = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x2000
    /// The generic shift, control, option and command bits.
    static let allGenericBits: UInt = 0x20000 | 0x40000 | 0x80000 | 0x100000

    var genericMask: UInt {
        switch self {
        case .rightOption: return 0x80000
        case .rightCommand: return 0x100000
        case .rightControl: return 0x40000
        }
    }

    /// Any modifier other than this physical key is down (the left twin of the same modifier counts).
    public func otherModifiersDown(rawFlags: UInt) -> Bool {
        (rawFlags & Self.allDeviceBits & ~deviceMask) != 0 || (rawFlags & Self.allGenericBits & ~genericMask) != 0
    }
}

/// Turns raw modifier and key events into "the talk key was held" decisions. A tap shorter than `holdSeconds`, a hold
/// during which any other key was pressed (typing Option-characters), another modifier pressed or released (a chord such
/// as Option-Shift, a VoiceOver or system shortcut), or a press that started with another modifier already down, is not
/// a call. A hold that never gets its key-up (sleep, session switch, a lost event) is dropped by `interrupted`,
/// `reconcile` or after `maxListenSeconds`.
public struct PushToTalkDetector: Equatable {
    public static let holdSeconds: TimeInterval = 0.25
    /// Longest a single call may listen: the key-up is assumed lost after this.
    public static let maxListenSeconds: TimeInterval = 60

    public enum Output: Equatable {
        /// The key has been held long enough: wake Shep, start listening.
        case began
        /// The key came up after `began`: stop listening, use what was heard.
        case ended
        /// Something else happened while it was held after `began` (another key or modifier, lost input): throw the audio away.
        case cancelled
    }

    public var key: PushToTalkKey
    private var pressedAt: TimeInterval?
    private var began = false
    private var spoiled = false

    public init(key: PushToTalkKey = .default) { self.key = key }

    public var isHeld: Bool { pressedAt != nil }
    public var isListening: Bool { began }

    /// A modifier-change event: the event's key code and raw modifier flags.
    public mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt, at now: TimeInterval) -> Output? {
        guard keyCode == key.keyCode else {
            // Some other modifier went down or up. While the talk key is held that makes it a chord.
            guard pressedAt != nil else { return nil }
            if began { reset(); return .cancelled }
            spoiled = true
            return nil
        }
        if key.isDown(rawFlags: rawFlags) {
            if pressedAt == nil { pressedAt = now; began = false; spoiled = key.otherModifiersDown(rawFlags: rawFlags) }
            return nil
        }
        defer { pressedAt = nil; began = false; spoiled = false }
        return began ? .ended : nil
    }

    /// Any ordinary key pressed. Before the hold time it spoils the press (it was a modified keystroke); after, it cancels.
    public mutating func keyDown(at now: TimeInterval) -> Output? {
        guard pressedAt != nil else { return nil }
        if began {
            reset()
            return .cancelled
        }
        spoiled = true
        return nil
    }

    /// Call it when the hold time may have passed, or the listening limit (a timer set at the press).
    public mutating func tick(at now: TimeInterval) -> Output? {
        guard let t = pressedAt else { return nil }
        if began {
            guard now - t >= Self.maxListenSeconds else { return nil }
            reset()
            return .cancelled   // the key-up never arrived
        }
        guard !spoiled, now - t >= Self.holdSeconds else { return nil }
        began = true
        return .began
    }

    /// When `tick` should next be called: the end of the hold time for a waiting press, the listening limit while listening.
    public var nextTick: TimeInterval? {
        guard let t = pressedAt else { return nil }
        if began { return t + Self.maxListenSeconds }
        return spoiled ? nil : t + Self.holdSeconds
    }

    /// The input was interrupted (sleep, the user session switched away, the monitor was restarted): a listening call is
    /// cancelled, a pending press is forgotten.
    public mutating func interrupted() -> Output? {
        let wasListening = began
        reset()
        return wasListening ? .cancelled : nil
    }

    /// Compares what the detector believes with the keyboard's actual modifier state (`NSEvent.modifierFlags.rawValue`).
    /// If the talk key is believed held but is not down, the key-up was lost.
    public mutating func reconcile(rawFlags: UInt) -> Output? {
        // Device bits can be missing from a polled state, so a set generic bit counts as still down (the safe direction).
        guard pressedAt != nil, !key.isDown(rawFlags: rawFlags), rawFlags & key.genericMask == 0 else { return nil }
        return interrupted()
    }

    public mutating func reset() { pressedAt = nil; began = false; spoiled = false }
}
