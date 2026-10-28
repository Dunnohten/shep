import CoreGraphics
import Foundation

/// Everything a provider is given about the front window.
public struct VisionInput: Sendable {
    public var png: Data
    public var geometry: CaptureGeometry
    /// Controls already read from Accessibility (prepared and numbered). The provider looks for what is missing.
    public var axControls: [Control]
    public var bundleID: String
    public var windowTitle: String
    public var request: String?
    /// A dialog or sheet of the app is open over the window the screenshot shows.
    public var modalInFront: Bool
    public init(png: Data, geometry: CaptureGeometry, axControls: [Control], bundleID: String, windowTitle: String, request: String? = nil,
                modalInFront: Bool = false) {
        self.png = png; self.geometry = geometry; self.axControls = axControls
        self.bundleID = bundleID; self.windowTitle = windowTitle; self.request = request; self.modalInFront = modalInFront
    }
}

/// A control a provider located, with its box in pixels of the ORIGINAL screenshot (top-left origin).
public struct LocatedControl: Equatable, Sendable {
    public var name: String
    /// "button", "text field", "checkbox", "tab", "menu", "link" or "" when unknown.
    public var role: String
    public var box: CGRect
    public var score: Double
    public init(name: String, role: String = "", box: CGRect, score: Double = 1) {
        self.name = name; self.role = role; self.box = box; self.score = score
    }
}

public struct ScreenAnalysis: Equatable, Sendable {
    public var summary: String
    public var controls: [LocatedControl]
    public var notes: [String]
    /// The box (original screenshot pixels) the person's request points at, when the provider could tell.
    public var targetBox: CGRect?
    /// For the debug dump: the detector's boxes and where the pick came from (detector-based providers only).
    public var debug = AnalysisDebug()
    public init(summary: String, controls: [LocatedControl], notes: [String] = [], targetBox: CGRect? = nil) {
        self.summary = summary; self.controls = controls; self.notes = notes; self.targetBox = targetBox
    }
}

/// Swappable vision backend: describes the screen and locates controls in one structured result.
public protocol VisionProvider: Sendable {
    var name: String { get }
    /// True when the screenshot leaves this Mac (cloud). Those need the owner's opt-in; local providers do not.
    var sendsOffDevice: Bool { get }
    func analyze(_ input: VisionInput) async throws -> ScreenAnalysis
}

public enum ProviderError: Error, Equatable, LocalizedError {
    case unreachable(String)
    case http(Int, String)
    case malformed(String)
    case imageUnreadable
    case refusedConfig(String)
    public var errorDescription: String? {
        switch self {
        case .unreachable(let w): return "Couldn't reach the model server (\(w))."
        case .http(let c, let m): return "The model server answered \(c): \(m)"
        case .malformed(let w): return "The model's answer wasn't in the expected form (\(w))."
        case .imageUnreadable: return "I couldn't read the screenshot."
        case .refusedConfig(let w): return w
        }
    }
}

// MARK: fake (tests)

public final class FakeProvider: VisionProvider, @unchecked Sendable {
    public let name = "fake"
    public let sendsOffDevice: Bool
    private let lock = NSLock()
    private var result: Result<ScreenAnalysis, ProviderError>
    private var seen: [VisionInput] = []

    public init(analysis: ScreenAnalysis, sendsOffDevice: Bool = false) {
        self.result = .success(analysis); self.sendsOffDevice = sendsOffDevice
    }
    public init(error: ProviderError, sendsOffDevice: Bool = false) {
        self.result = .failure(error); self.sendsOffDevice = sendsOffDevice
    }
    public var calls: [VisionInput] { lock.lock(); defer { lock.unlock() }; return seen }
    public func analyze(_ input: VisionInput) async throws -> ScreenAnalysis {
        lock.lock(); seen.append(input); let r = result; lock.unlock()
        switch r {
        case .success(let a): return a
        case .failure(let e): throw e
        }
    }
}

// MARK: image preparation

public struct PreparedImage: Equatable, Sendable {
    public var jpeg: Data
    /// Pixel size of the JPEG that is sent.
    public var size: CGSize
    /// Pixel size of the screenshot it came from.
    public var originalSize: CGSize
    /// True when the numbered candidate boxes were drawn onto the image (set-of-marks), so the model can read ids off it.
    public var marked: Bool
    public init(jpeg: Data, size: CGSize, originalSize: CGSize, marked: Bool = false) {
        self.jpeg = jpeg; self.size = size; self.originalSize = originalSize; self.marked = marked
    }
}

/// A numbered box to draw onto the image the model is shown. `box` is in pixels of the ORIGINAL screenshot, top-left origin.
public struct ImageMark: Equatable, Sendable {
    public var id: Int
    public var box: CGRect
    public init(id: Int, box: CGRect) { self.id = id; self.box = box }
}

public protocol ImagePreparing: Sendable {
    func prepare(png: Data, longestSide: CGFloat, quality: CGFloat) -> PreparedImage?
    /// Same, with numbered boxes drawn on. A preparer that cannot draw may ignore the marks (the default does).
    func prepare(png: Data, longestSide: CGFloat, quality: CGFloat, marks: [ImageMark]) -> PreparedImage?
}

public extension ImagePreparing {
    func prepare(png: Data, longestSide: CGFloat, quality: CGFloat, marks: [ImageMark]) -> PreparedImage? {
        prepare(png: png, longestSide: longestSide, quality: quality)
    }
}
