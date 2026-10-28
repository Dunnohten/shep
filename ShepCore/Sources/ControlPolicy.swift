import Foundation

/// What Shep refuses to touch or capture. Shep-owned lists, written for this app.
public enum ControlPolicy {
    /// Apps Shep never drives: security, passwords, system settings, logs.
    public static let deniedBundleIDs: Set<String> = [
        "com.apple.systempreferences", "com.apple.settings", "com.apple.keychainaccess", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.passwords", "com.lastpass.lastpass", "com.apple.console",
    ]
    /// Apps whose windows are never sent to a model: messaging, mail, wallet, call apps.
    public static let neverCaptureIDs: Set<String> = [
        "com.apple.mobilesms", "com.apple.mail", "com.apple.facetime", "com.apple.passbook", "com.apple.passwords",
        "com.tinyspeck.slackmacgap", "com.hnc.discord", "net.whatsapp.whatsapp", "ru.keepcoder.telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop", "com.microsoft.teams2", "com.microsoft.outlook", "us.zoom.xos", "com.skype.skype",
        "com.viber.osx", "com.apple.keychainaccess",
    ]
    /// Apps that run commands: Shep does nothing in them without an approval, and never captures them.
    public static let commandRunnerIDs: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "com.mitchellh.ghostty", "com.microsoft.vscode", "dev.zed.zed",
        "com.apple.dt.xcode", "com.apple.shortcuts", "com.apple.automator",
    ]
    public static let deniedWords = [
        "pay", "buy", "purchase", "subscribe", "checkout", "check out", "order", "send money", "transfer", "delete account",
        "erase", "format", "shut down", "restart", "log out", "sign in", "log in", "password", "empty trash", "factory reset",
        "uninstall", "remove account", "delete",
    ]

    static func normalized(_ id: String) -> String { id.trimmingCharacters(in: .whitespaces).lowercased() }

    public static func isCommandRunner(_ bundleID: String) -> Bool {
        let id = normalized(bundleID)
        return commandRunnerIDs.contains(id) || id.hasPrefix("com.jetbrains.") || id.hasPrefix("dev.warp.")
    }

    public static func mayCapture(bundleID: String) -> Bool {
        let id = normalized(bundleID)
        guard !id.isEmpty else { return false }
        return !neverCaptureIDs.contains(id) && !deniedBundleIDs.contains(id) && !isCommandRunner(id)
    }

    /// Why this control is off-limits, or nil if Shep may offer it.
    public static func refusal(_ c: Control, bundleID: String) -> String? {
        if deniedBundleIDs.contains(normalized(bundleID)) { return "Shep doesn't control this app (security or passwords)." }
        if c.isSecure { return "Shep never touches password fields." }
        let haystack = (c.label + " " + c.window).lowercased()
        for w in deniedWords {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b"
            if haystack.range(of: pattern, options: .regularExpression) != nil {
                return "Shep won't press \"\(c.label)\": it involves \(w). Do that one yourself."
            }
        }
        return nil
    }
}

// Written for Shep.

/// Keeps API keys out of error text, logs and the dog's card.
public enum Redact {
    public static let mask = "[key hidden]"

    private static let lock = NSLock()
    private static var secrets = Set<String>()

    /// Secrets shorter than this are ignored: masking them would mangle ordinary text.
    static let minimumLength = 8

    /// Remembers an exact secret (for example the API key in use) so `scrub` can mask it anywhere.
    public static func register(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return }
        lock.lock()
        secrets.insert(trimmed)
        lock.unlock()
    }

    /// Masks registered secrets first (longest first), then anything shaped like a key.
    public static func scrub(_ text: String) -> String {
        lock.lock()
        let known = secrets.sorted { $0.count > $1.count }
        lock.unlock()
        var out = text
        for secret in known { out = out.replacingOccurrences(of: secret, with: mask) }
        for (pattern, template) in patterns {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    /// Order matters: header and query forms keep their label and mask the value, then bare shapes.
    private static let patterns: [(String, String)] = [
        ("(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]{8,}", "$1" + mask),
        ("(?i)((?:api[_-]?key|access[_-]?token|token|key|secret|password)=)[^&\\s\"']{6,}", "$1" + mask),
        ("\\b(?:sk|hf|pk|ghp|gho|xox[bap])[-_][A-Za-z0-9_-]{12,}", mask),
        ("\\b[A-Fa-f0-9]{32,}\\b", mask),
        ("(?=[A-Za-z0-9+/_-]*[0-9])(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{40,}={0,2}", mask),
    ]
}
