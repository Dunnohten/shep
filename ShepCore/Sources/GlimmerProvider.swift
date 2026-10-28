import CoreGraphics
import Foundation

/// Local Muse Glimmer behind an OpenAI-compatible server: `mlx_vlm.server` (scripts/glimmer-server.sh) or an
/// already-running llama-server, picked with SHEP_GLIMMER_URL. Nothing leaves the Mac. Glimmer only names controls
/// (see `GlimmerNamer`); finding them is the detector's job.
public struct GlimmerConfig: Equatable, Sendable {
    public var baseURL: URL
    /// What the server was started with. mlx_vlm loads whatever model a request names, so this MUST equal the
    /// `--model` path scripts/glimmer-server.sh uses, or the server may load a second copy. llama-server ignores it.
    public var model: String
    public var maxTokens: Int
    public var temperature: Double
    /// Longest side of the screenshot sent (a ~4x downscale of a Retina capture).
    public var longestSide: CGFloat
    public var jpegQuality: CGFloat
    public var timeout: TimeInterval

    /// scripts/glimmer-server.sh starts mlx_vlm.server here by default.
    public static let defaultBaseURL = "http://127.0.0.1:8080/v1"
    /// Glimmer's thinking is off ONLY with this request field set to this value (measured; enable_thinking and
    /// chat_template_kwargs have no effect).
    public static let reasoningStrengthField = "reasoning_strength"
    public static let reasoningOff = "none"
    public static let maxAllowedTokens = 2000

    public init(baseURL: URL = URL(string: GlimmerConfig.defaultBaseURL)!, model: String = "Muse-Glimmer-30B-4bit",
                maxTokens: Int = 1500, temperature: Double = 0, longestSide: CGFloat = 960, jpegQuality: CGFloat = 0.7,
                timeout: TimeInterval = 180) {
        self.baseURL = baseURL; self.model = model; self.maxTokens = maxTokens; self.temperature = temperature
        self.longestSide = longestSide; self.jpegQuality = jpegQuality; self.timeout = timeout
    }

    public static func defaultModelPath(home: String) -> String {
        (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/models/Muse-Glimmer-30B-4bit"
    }

    public var chatURL: URL { baseURL.appendingPathComponent("chat/completions") }

    /// Only Glimmer, only a local server. Refuses the port of another local model server.
    public func validate() throws {
        let forbiddenPort = 11230 + 4   // another local model server lives here
        if baseURL.port == forbiddenPort { throw ProviderError.refusedConfig("That port belongs to a different local model server. Shep only talks to Glimmer.") }
        guard LoopbackURL.isLoopback(baseURL) else {
            throw ProviderError.refusedConfig("The local provider must be on this Mac (127.0.0.1).")
        }
        guard maxTokens > 0, maxTokens <= GlimmerConfig.maxAllowedTokens else {
            throw ProviderError.refusedConfig("max_tokens must be 1...\(GlimmerConfig.maxAllowedTokens).")
        }
    }
}

/// Glimmer's box format: `[x0, y0, x1, y1]` on a 0...1000 scale relative to the image it was shown (measured), so
/// pixels of the ORIGINAL screenshot are `x / 1000 * originalWidth`, whatever size was actually sent.
public enum GlimmerBoxes {
    public static let scale = 1000.0

    /// Pixel rectangle in the original image, or nil for anything that is not four finite numbers, is empty, or lies off the image.
    public static func pixelRect(fromThousandths v: [Double], imageSize: CGSize) -> CGRect? {
        CoordinateSpace(windowFrame: CGRect(origin: .zero, size: imageSize), imageSize: imageSize).pixelRect(fromNormalized: v)
    }

    /// The same box on the 0...1000 scale, rounded, for showing a candidate to the model.
    public static func thousandths(forPixelRect r: CGRect, imageSize: CGSize) -> [Int] {
        CoordinateSpace(windowFrame: CGRect(origin: .zero, size: imageSize), imageSize: imageSize).normalized(fromPixels: r)
    }
}

public enum GlimmerResponses {
    /// choices[0].message.content as a string, or the text parts of a content array.
    public static func content(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["choices"] as? [[String: Any]])?.first,
              let message = first["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }
}
