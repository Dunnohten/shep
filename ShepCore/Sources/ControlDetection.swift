import CoreGraphics
import Foundation

/// A box a detector found, in pixels of the ORIGINAL screenshot (top-left origin).
public struct DetectedBox: Equatable, Sendable {
    public var box: CGRect
    public var score: Double
    /// "omniparser-v3" or "sam3".
    public var source: String
    /// "icon", "button", "rounded rectangle"...: what the detector thinks it is. Empty when it does not say.
    public var kind: String
    /// A rough caption from the detector (OmniParser's icon_caption), a hint for the namer. Often wrong or empty.
    public var caption: String
    public init(box: CGRect, score: Double = 1, source: String = "", kind: String = "", caption: String = "") {
        self.box = box; self.score = score; self.source = source; self.kind = kind; self.caption = caption
    }
}

/// Finds candidate control boxes on a screenshot. The real one talks to scripts/detector-server.py; tests use `FakeDetector`.
public protocol DetectorProvider: Sendable {
    var name: String { get }
    func detect(png: Data, imageSize: CGSize) async throws -> [DetectedBox]
}

public final class FakeDetector: DetectorProvider, @unchecked Sendable {
    public let name = "fake-detector"
    private let lock = NSLock()
    private var result: Result<[DetectedBox], ProviderError>
    private var count = 0
    public init(boxes: [DetectedBox]) { result = .success(boxes) }
    public init(error: ProviderError) { result = .failure(error) }
    public var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    public func detect(png: Data, imageSize: CGSize) async throws -> [DetectedBox] {
        lock.lock(); count += 1; let r = result; lock.unlock()
        return try r.get()
    }
}

// MARK: sidecar

/// The local detector sidecar (scripts/detector-server.py): OmniParser v3 by default, SAM 3 only when switched on.
public struct DetectorConfig: Equatable, Sendable {
    public var baseURL: URL
    /// SAM 3 is OFF unless the person turns it on (SHEP_SAM3=1) AND started the sidecar with `--sam3` and their own
    /// Hugging Face token. Its weights are never in this repo.
    public var useSAM3: Bool
    public var timeout: TimeInterval

    public static let defaultBaseURL = "http://127.0.0.1:8765"

    public init(baseURL: URL = URL(string: DetectorConfig.defaultBaseURL)!, useSAM3: Bool = false, timeout: TimeInterval = 240) {
        self.baseURL = baseURL; self.useSAM3 = useSAM3; self.timeout = timeout
    }

    public var detectURL: URL { baseURL.appendingPathComponent("detect") }

    /// Local only, and never the port of another local model server.
    public func validate() throws {
        if baseURL.port == 11230 + 4 { throw ProviderError.refusedConfig("That port belongs to a different local model server, not the detector.") }
        guard LoopbackURL.isLoopback(baseURL) else {
            throw ProviderError.refusedConfig("The detector must run on this Mac (127.0.0.1).")
        }
    }
}

public enum DetectorRequests {
    public static func detect(png: Data, config: DetectorConfig) throws -> MetaHTTPRequest {
        let body: [String: Any] = ["image": png.base64EncodedString(), "format": "png", "sam3": config.useSAM3]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return MetaHTTPRequest(url: config.detectURL, method: "POST", headers: ["Content-Type": "application/json"],
                               body: data, timeout: config.timeout, localOnly: true)
    }
}

public enum DetectorResponses {
    /// `{"boxes": [{"box": [x0, y0, x1, y1], "score": 0.9, "source": "...", "kind": "...", "caption": "..."}], "notes": [...]}`
    /// with boxes in pixels of the image that was sent. Unreadable rows are dropped; rows are clipped to the image.
    public static func boxes(_ data: Data, imageSize: CGSize) throws -> (boxes: [DetectedBox], notes: [String]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = obj["boxes"] as? [[String: Any]] else {
            throw ProviderError.malformed("the detector's answer has no \"boxes\" list")
        }
        let image = CGRect(origin: .zero, size: imageSize)
        var out: [DetectedBox] = []
        var dropped = 0
        for row in rows {
            guard let v = MetaResponses.fourNumbers(row["box"]) else { dropped += 1; continue }
            let rect = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
            guard rect.width.isFinite, rect.height.isFinite else { dropped += 1; continue }   // huge exponents overflow the size
            let clipped = rect.intersection(image)
            guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { dropped += 1; continue }
            out.append(DetectedBox(box: clipped, score: MetaResponses.score(row["score"]),
                                   source: (row["source"] as? String) ?? "", kind: (row["kind"] as? String) ?? "",
                                   caption: String(((row["caption"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(60))))
        }
        var notes = (obj["notes"] as? [String] ?? []).map { String($0.prefix(200)) }
        if dropped > 0 { notes.append("dropped \(dropped) unreadable detector box(es)") }
        return (out, notes)
    }
}

public struct SidecarDetector: DetectorProvider {
    public let config: DetectorConfig
    private let transport: any MetaTransport

    public init(config: DetectorConfig = DetectorConfig(), transport: any MetaTransport = URLSessionMetaTransport()) {
        self.config = config; self.transport = transport
    }

    public var name: String { config.useSAM3 ? "omniparser-v3+sam3" : "omniparser-v3" }

    public func detect(png: Data, imageSize: CGSize) async throws -> [DetectedBox] {
        try config.validate()
        let request = try DetectorRequests.detect(png: png, config: config)
        let response: MetaHTTPResponse
        do { response = try await transport.send(request) }
        catch {
            throw ProviderError.unreachable("the detector is not answering at \(config.baseURL.absoluteString) — start it with scripts/detector-server.py (see docs/detector.md)")
        }
        guard (200..<300).contains(response.status) else {
            throw ProviderError.http(response.status, String(Redact.scrub(MetaResponses.errorMessage(response.body)).prefix(200)))
        }
        return try DetectorResponses.boxes(response.body, imageSize: imageSize).boxes
    }
}

// MARK: merge with Accessibility

/// Detector boxes + the Accessibility tree -> the controls that are only on the screenshot. Pure.
public enum ControlMerger {
    /// Detector boxes the AX tree already covers (strong overlap, or inside a comparable-size AX frame) are dropped, boxes
    /// from different detectors that are the same control collapse to the best-scoring one, the rest come back in reading
    /// order, numbered 1...n and capped (`VisionRepair.candidates`).
    public static func candidates(detections: [DetectedBox], geometry: CaptureGeometry, ax: [Control],
                                  limit: Int = VisionRepair.maxVisionControls) -> [VisionCandidate] {
        let regions = detections.map { SAMRegion(box: $0.box, score: $0.score, concept: $0.kind.isEmpty ? "icon" : $0.kind) }
        return VisionRepair.candidates(from: regions, geometry: geometry, ax: ax, limit: limit)
    }

    /// The detector's caption for each candidate, by its box.
    public static func hints(for candidates: [VisionCandidate], detections: [DetectedBox]) -> [Int: String] {
        var out: [Int: String] = [:]
        for c in candidates {
            if let d = detections.first(where: { $0.box == c.pixelBox && !$0.caption.isEmpty }) { out[c.id] = d.caption }
        }
        return out
    }
}
