import Foundation

/// Written for Shep.
/// What the owner can change in Settings, where it is stored, what it defaults to, and what counts as valid. Pure apart from
/// UserDefaults (tests use their own suite). The Settings window and the rest of the app read and write only through here.

public struct ShepSettings: Equatable, Sendable {
    public var themeName: String
    public var pushToTalkKey: PushToTalkKey
    /// `HotKeySpec.id` of one of `HotKeySpec.presets`.
    public var callShortcutID: String
    public var speakReplies: Bool
    /// The local Glimmer server's base URL (OpenAI-compatible, ends in /v1).
    public var glimmerURL: String
    /// Opt in to SAM 3 (SAM License; weights are downloaded with the owner's own Hugging Face token).
    public var sam3: Bool
    public var hideFromCapture: Bool
    /// One short synthesized woof when a fix finishes.
    public var barkWhenDone: Bool
    /// 0...1, the peak level of that woof.
    public var barkVolume: Double
    /// Listen for "Hey Shep" with the microphone open in the background (on-device recognition only). Off until the owner turns it on.
    public var wakeWord: Bool = false

    public static let defaultBarkVolume = 0.6
    public static let defaultGlimmerURL = GlimmerConfig.defaultBaseURL

    public static let defaults = ShepSettings(
        themeName: ShepThemes.defaultTheme.name, pushToTalkKey: .default, callShortcutID: HotKeySpec.call.id,
        speakReplies: true, glimmerURL: defaultGlimmerURL, sam3: false, hideFromCapture: true,
        barkWhenDone: true, barkVolume: defaultBarkVolume)

    public var theme: ShepTheme { ShepThemes.find(themeName) }
    public var callShortcut: HotKeySpec { HotKeySpec.presets.first { $0.id == callShortcutID } ?? .call }

    /// Why the Glimmer URL cannot be used, or nil. Local servers only, never another model server's port.
    public var glimmerURLIssue: String? { Self.glimmerURLIssue(glimmerURL) }

    public static func glimmerURLIssue(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Enter the server address, for example \(defaultGlimmerURL)." }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            return "That is not a web address (http://127.0.0.1:8080/v1)."
        }
        do { try GlimmerConfig(baseURL: url).validate(); return nil }
        catch { return error.localizedDescription }
    }

    /// The same settings with every field forced valid: unknown theme -> Tangerine, bad URL -> the default, and so on.
    public func sanitized() -> ShepSettings {
        var s = self
        s.themeName = ShepThemes.find(themeName).name
        s.callShortcutID = HotKeySpec.presets.contains { $0.id == callShortcutID } ? callShortcutID : HotKeySpec.call.id
        let url = glimmerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        s.glimmerURL = Self.glimmerURLIssue(url) == nil ? url : Self.defaultGlimmerURL
        s.barkVolume = barkVolume.isFinite ? min(1, max(0, barkVolume)) : Self.defaultBarkVolume
        return s
    }
}

public enum SettingsKey {
    /// Kept from earlier versions: the theme and the capture-hiding choice already lived under these names.
    public static let theme = "shep.theme"
    public static let hideFromCapture = "shep.hideFromCapture"
    public static let speakReplies = "shep.speakReplies"
    public static let pushToTalkKey = "shep.pushToTalkKey"
    public static let callShortcut = "shep.callShortcut"
    public static let glimmerURL = "shep.glimmerURL"
    public static let sam3 = "shep.sam3"
    public static let barkWhenDone = "shep.barkWhenDone"
    public static let barkVolume = "shep.barkVolume"
    public static let wakeWord = "shep.wakeWord"
}

public struct SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// What is stored, with anything missing or invalid replaced by its default.
    public func load() -> ShepSettings {
        var s = ShepSettings.defaults
        if let v = defaults.string(forKey: SettingsKey.theme) { s.themeName = v }
        if let v = defaults.string(forKey: SettingsKey.pushToTalkKey), let k = PushToTalkKey(rawValue: v) { s.pushToTalkKey = k }
        if let v = defaults.string(forKey: SettingsKey.callShortcut) { s.callShortcutID = v }
        if let v = defaults.object(forKey: SettingsKey.speakReplies) as? Bool { s.speakReplies = v }
        if let v = defaults.string(forKey: SettingsKey.glimmerURL) { s.glimmerURL = v }
        if let v = defaults.object(forKey: SettingsKey.sam3) as? Bool { s.sam3 = v }
        if let v = defaults.object(forKey: SettingsKey.hideFromCapture) as? Bool { s.hideFromCapture = v }
        if let v = defaults.object(forKey: SettingsKey.barkWhenDone) as? Bool { s.barkWhenDone = v }
        if let v = defaults.object(forKey: SettingsKey.barkVolume) as? Double { s.barkVolume = v }
        if let v = defaults.object(forKey: SettingsKey.wakeWord) as? Bool { s.wakeWord = v }
        return s.sanitized()
    }

    /// Stores the sanitized settings (an invalid field is stored as its default, never as what was typed).
    public func save(_ settings: ShepSettings) {
        let s = settings.sanitized()
        defaults.set(s.themeName, forKey: SettingsKey.theme)
        defaults.set(s.pushToTalkKey.rawValue, forKey: SettingsKey.pushToTalkKey)
        defaults.set(s.callShortcutID, forKey: SettingsKey.callShortcut)
        defaults.set(s.speakReplies, forKey: SettingsKey.speakReplies)
        defaults.set(s.glimmerURL, forKey: SettingsKey.glimmerURL)
        defaults.set(s.sam3, forKey: SettingsKey.sam3)
        defaults.set(s.hideFromCapture, forKey: SettingsKey.hideFromCapture)
        defaults.set(s.barkWhenDone, forKey: SettingsKey.barkWhenDone)
        defaults.set(s.barkVolume, forKey: SettingsKey.barkVolume)
        defaults.set(s.wakeWord, forKey: SettingsKey.wakeWord)
    }

    /// The environment the providers read: what the process was launched with, plus the settings where the launch said nothing.
    /// A variable set at launch (SHEP_GLIMMER_URL, SHEP_SAM3) wins, so scripts can still point Shep elsewhere.
    public func effectiveEnvironment(_ base: [String: String]) -> [String: String] {
        let s = load()
        var env = base
        if (env["SHEP_GLIMMER_URL"] ?? "").isEmpty, s.glimmerURL != ShepSettings.defaultGlimmerURL { env["SHEP_GLIMMER_URL"] = s.glimmerURL }
        if (env["SHEP_SAM3"] ?? "").isEmpty, s.sam3 { env["SHEP_SAM3"] = "1" }
        return env
    }
}

/// What Settings says about the optional providers.
public enum ProviderAvailability {
    /// Meta's cloud provider is offered only when MODEL_API_KEY is set; Settings shows it read-only and never shows the key.
    public static func metaAvailable(environment: [String: String]) -> Bool {
        !(environment["MODEL_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func metaStatus(environment: [String: String]) -> String {
        metaAvailable(environment: environment)
            ? "Available: MODEL_API_KEY is set. Screenshots still go to the cloud only when you allow it in the menu."
            : "Not available: set MODEL_API_KEY in the environment Shep is launched from."
    }

    public static let sam3Note = "SAM 3 by Meta, under the SAM License; weights download with your own Hugging Face token."
}

/// The Settings window's "Test" button: ask the local server for its model list.
public enum GlimmerPing {
    public struct Outcome: Equatable, Sendable {
        public var ok: Bool
        public var message: String
        public var models: [String]
    }

    public static func request(baseURL: URL, timeout: TimeInterval = 5) -> MetaHTTPRequest {
        MetaHTTPRequest(url: baseURL.appendingPathComponent("models"), method: "GET", headers: [:], body: Data(), timeout: timeout, localOnly: true)
    }

    /// Reads a `/v1/models` answer: `{"data": [{"id": "..."}]}`.
    public static func interpret(status: Int, body: Data) -> Outcome {
        guard (200..<300).contains(status) else {
            return Outcome(ok: false, message: "The server answered \(status).", models: [])
        }
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let ids = ((obj?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        if ids.isEmpty { return Outcome(ok: true, message: "The server answered, but listed no models.", models: []) }
        let first = ids[0].split(separator: "/").last.map(String.init) ?? ids[0]
        let more = ids.count > 1 ? " (and \(ids.count - 1) more)" : ""
        return Outcome(ok: true, message: "Glimmer is answering: \(first)\(more).", models: ids)
    }

    public static func run(urlText: String, transport: any MetaTransport = URLSessionMetaTransport()) async -> Outcome {
        if let issue = ShepSettings.glimmerURLIssue(urlText) { return Outcome(ok: false, message: issue, models: []) }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return Outcome(ok: false, message: "That is not a web address.", models: [])
        }
        do {
            let response = try await transport.send(request(baseURL: url))
            return interpret(status: response.status, body: response.body)
        } catch {
            return Outcome(ok: false, message: "Nothing is answering at \(url.absoluteString). Start it with scripts/glimmer-server.sh.", models: [])
        }
    }
}
