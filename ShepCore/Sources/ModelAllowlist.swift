import Foundation

// Written for Shep.

/// The models Shep may talk to, as an allowlist: Meta's Muse Glimmer on this Mac, or Meta's Muse Spark at api.meta.ai. A model id that is
/// not one of these is refused with a message, whatever it is called. There is no list of names to avoid, only this list of names to accept.
public enum ModelAllowlist {
    public static let glimmerPrefix = "muse-glimmer"
    public static let sparkPrefix = "muse-spark-"
    public static let cloudHost = "api.meta.ai"

    /// The last path component of a model id, trimmed: "/Users/me/models/Muse-Glimmer-30B-4bit/" -> "Muse-Glimmer-30B-4bit".
    static func lastComponent(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? ""
    }

    /// Muse Glimmer: the model id's last path component, in any case, starts with "muse-glimmer".
    public static func isMuseGlimmer(_ model: String) -> Bool {
        lastComponent(model).lowercased().hasPrefix(glimmerPrefix)
    }

    /// Muse Spark: the model id starts with "muse-spark-" (case does not matter), has something after it, and is not a path.
    public static func isMuseSpark(_ model: String) -> Bool {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id.hasPrefix(sparkPrefix) && id.count > sparkPrefix.count && !id.contains("/")
    }

    /// https, host api.meta.ai, no user name or password, the default port only.
    public static func isCloudEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == cloudHost && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    public static let glimmerRefusal = "Shep's local provider is Muse Glimmer only. Use a Muse Glimmer model (for example Muse-Glimmer-30B-4bit) on this Mac."
    public static let sparkRefusal = "Shep's cloud provider is Muse Spark only: a muse-spark-... model, over HTTPS at api.meta.ai."
}
