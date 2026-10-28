import Foundation

/// A permission's state in words the setup window can show and VoiceOver can read.
public enum PermissionState: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
    case restricted

    public var isGranted: Bool { self == .granted }

    public var label: String {
        switch self {
        case .granted: return "Granted"
        case .notDetermined: return "Not asked yet"
        case .denied: return "Denied: turn it on in System Settings"
        case .restricted: return "Restricted by this Mac's settings"
        }
    }

    /// Button title: "Grant" the first time, "Retry" after a refusal (then it opens System Settings).
    public var requestTitle: String { self == .notDetermined ? "Grant" : "Open Settings" }
}
