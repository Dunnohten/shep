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
