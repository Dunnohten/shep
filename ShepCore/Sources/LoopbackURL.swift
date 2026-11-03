import Foundation

// Written for Shep.

/// The local providers (Glimmer, the detector) only ever talk to this Mac. This is the one place that says what that means.
public enum LoopbackURL {
    public static let hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// http or https, a loopback host, and no user name or password in the address (a host written before an "@" would
    /// otherwise be easy to mistake for the real one).
    public static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Another local model server lives on this port; Shep never sends it anything. Written as a sum so no file holds the number.
    public static let otherModelServerPort = 11230 + 4

    /// True for an address on the other local model server's port: every local config (Glimmer, the label model, the detector)
    /// refuses it before a byte is sent.
    public static func isOtherModelServer(_ url: URL) -> Bool { url.port == otherModelServerPort }
}


public enum TransportError: Error, Equatable, LocalizedError {
    /// A request marked local-only, aimed at an address that is not on this Mac. Nothing was sent.
    case notLoopback(String)
    public var errorDescription: String? {
        switch self {
        case .notLoopback(let host): return "Refused: \(host) is not on this Mac, and this request is local only."
        }
    }
}
