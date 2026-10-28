import CoreGraphics
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux check build (LinuxCheck/) only
#endif

// Provenance: written on 2026-10-26 at about 11:44 AM CT (after the 11:00 AM CT start of the hackathon) on the author's earlier
// working branch for this same hackathon, reviewed at 11:52 AM CT, and carried into this repository.
// The key comes from the environment only (MODEL_API_KEY, then META_API_KEY).

// Meta Model API client for "Fix this screen" (Meta hackathon, 2026-10-26): SAM 3.1 finds controls on a screenshot from
// a concept prompt ("button", "text field"); Muse Spark names them. Pure request builders and parsers, plus an injectable
// transport, so every part is unit-tested without the network. The key is passed in by the app layer (environment); it is
// never read, stored or logged here.
//
// ASSUMED SCHEMAS, UNVERIFIED: the endpoint, model names and request shape mirror the author's hackathon probe script (a Responses
// API at https://api.meta.ai/v1/responses, models `sam-3.1` and `muse-spark-1.3`, taken from the dev.meta.ai docs as
// summarised in our prep notes). No call has been made with a real key; the probe reports "blocked: no key". The SAM
// response parser therefore accepts several plausible shapes (a structured output item, or JSON in the output text;
// boxes as [x0, y0, x1, y1] or {x, y, width, height}, in pixels or normalised 0...1). Check against a real response and
// narrow it once a key exists.

public struct MetaConfig: Equatable, Sendable {
    public var baseURL: URL
    public var samModel: String
    public var museModel: String
    public var timeout: TimeInterval
    public init(baseURL: URL = URL(string: "https://api.meta.ai/v1")!, samModel: String = "sam-3.1",
                museModel: String = "muse-spark-1.3", timeout: TimeInterval = 60) {
        self.baseURL = baseURL; self.samModel = samModel; self.museModel = museModel; self.timeout = timeout
    }
    public var responsesURL: URL { baseURL.appendingPathComponent("responses") }
}

/// One HTTP exchange, without URLSession types, so tests (and Linux) can stub it.
public struct MetaHTTPRequest: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data
    public var timeout: TimeInterval
    /// A request to a local provider (Glimmer, the detector). The transport sends it only to a loopback address.
    public var localOnly: Bool = false
}

public struct MetaHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol MetaTransport: Sendable {
    func send(_ request: MetaHTTPRequest) async throws -> MetaHTTPResponse
}

/// Never follows a redirect, for any provider: the 3xx answer comes back as the response (and is an error to the caller),
/// and the request body (a screenshot) and headers (the key) are not forwarded to another address.
public final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    public override init() { super.init() }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The real transport. Ephemeral session: no cookies, no cache on disk. A request marked `localOnly` is refused before
/// anything is sent unless its address is loopback; redirects are never followed.
public struct URLSessionMetaTransport: MetaTransport {
    public init() {}
    public func send(_ request: MetaHTTPRequest) async throws -> MetaHTTPResponse {
        if request.localOnly, !LoopbackURL.isLoopback(request.url) {
            throw TransportError.notLoopback(request.url.host ?? "that address")
        }
        var r = URLRequest(url: request.url, timeoutInterval: request.timeout)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: r, delegate: NoRedirectDelegate())
        return MetaHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

public enum MetaError: Error, Equatable, LocalizedError {
    case noKey
    case http(Int, String)
    case malformed(String)
    public var errorDescription: String? {
        switch self {
        case .noKey: return "No Meta API key is set. Set MODEL_API_KEY."
        case let .http(code, message): return "Meta's API answered \(code): \(message)"
        case let .malformed(why): return "Meta's answer wasn't in the expected form (\(why))."
        }
    }
}

/// A region SAM found, in screenshot pixels (top-left origin).
public struct SAMRegion: Equatable, Sendable {
    public var box: CGRect
    public var score: Double
    public var concept: String
    public init(box: CGRect, score: Double, concept: String) { self.box = box; self.score = score; self.concept = concept }
}

/// Muse Spark's name for one numbered candidate.
public struct MuseLabel: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var role: String?
    public init(id: Int, name: String, role: String? = nil) { self.id = id; self.name = name; self.role = role }
}

/// What VisionRepair needs from the models (the real client, or a stub in tests).
public protocol MetaVisioning: Sendable {
    func segment(png: Data, imageSize: CGSize, concept: String) async throws -> [SAMRegion]
    func name(png: Data, candidates: [VisionCandidate], request: String?) async throws -> [Int: MuseLabel]
}

public struct MetaClient: MetaVisioning {
    public let config: MetaConfig
    private let apiKey: String
    private let transport: any MetaTransport

    public init(apiKey: String, config: MetaConfig = MetaConfig(), transport: any MetaTransport = URLSessionMetaTransport()) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.config = config
        self.transport = transport
        Redact.register(self.apiKey)   // never in a log line or an error from here on
    }

    public func segment(png: Data, imageSize: CGSize, concept: String) async throws -> [SAMRegion] {
        let request = try MetaRequests.segment(png: png, concept: concept, key: apiKey, config: config)
        return try MetaResponses.regions(try await send(request), concept: concept, imageSize: imageSize)
    }

    public func name(png: Data, candidates: [VisionCandidate], request: String?) async throws -> [Int: MuseLabel] {
        guard !candidates.isEmpty else { return [:] }
        let req = try MetaRequests.name(png: png, candidates: candidates, request: request, key: apiKey, config: config)
        return MetaResponses.labels(MetaResponses.outputText(try await send(req)), ids: Set(candidates.map(\.id)))
    }

    private func send(_ request: MetaHTTPRequest) async throws -> Data {
        let r = try await transport.send(request)
        guard (200..<300).contains(r.status) else {
            throw MetaError.http(r.status, String(Redact.scrub(MetaResponses.errorMessage(r.body)).prefix(200)))
        }
        return r.body
    }
}

/// Request builders (Responses API shape, ASSUMED: see the note at the top of this file).
public enum MetaRequests {
    public static func segment(png: Data, concept: String, key: String, config: MetaConfig) throws -> MetaHTTPRequest {
        try make(model: config.samModel, text: concept, png: png, key: key, config: config)
    }

    public static func name(png: Data, candidates: [VisionCandidate], request: String?, key: String, config: MetaConfig) throws -> MetaHTTPRequest {
        try make(model: config.museModel, text: namingPrompt(candidates: candidates, request: request), png: png, key: key, config: config)
    }

    /// Muse Spark sees the screenshot and the numbered boxes; it answers JSON only. Box numbers are pixels on the image.
    public static func namingPrompt(candidates: [VisionCandidate], request: String?) -> String {
        let rows = candidates.map { c in
            "\(c.id): \(c.concept) at x=\(Int(c.pixelBox.minX)) y=\(Int(c.pixelBox.minY)) w=\(Int(c.pixelBox.width)) h=\(Int(c.pixelBox.height))"
        }.joined(separator: "\n")
        return """
        You help a blind person use this app window. Each numbered box below is a control on the screenshot (pixels, \
        top-left origin). Name each one the way a screen reader would: 1 to 4 words, what it does ("Send", "Search \
        field", "Bold"), never a description of how it looks. Use the visible text or icon meaning only; if you can't \
        tell, use "unlabeled". Reply with JSON only, no other words:
        {"labels": [{"id": <number>, "name": "<name>", "role": "button" | "text field" | "checkbox" | "tab" | "menu" | "link"}]}
        \(request.map { "The person wants to: \($0.replacingOccurrences(of: "\n", with: " ").prefix(200))\n" } ?? "")Boxes:
        \(rows)
        """
    }

    static func make(model: String, text: String, png: Data, key: String, config: MetaConfig) throws -> MetaHTTPRequest {
        guard !key.isEmpty else { throw MetaError.noKey }
        let body: [String: Any] = [
            "model": model,
            "input": [[
                "type": "message", "role": "user",
                "content": [
                    ["type": "input_text", "text": text],
                    ["type": "input_image", "image_url": "data:image/png;base64," + png.base64EncodedString()],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return MetaHTTPRequest(url: config.responsesURL, method: "POST",
                               headers: ["Authorization": "Bearer " + key, "Content-Type": "application/json"],
                               body: data, timeout: config.timeout)
    }
}

/// Response parsers. Tolerant on purpose (the shapes are ASSUMED); anything unreadable is an empty result or `.malformed`,
/// never a crash and never a guessed control.
public enum MetaResponses {
    static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// All text the model wrote: `output_text`, or every `output[].content[].text`.
    public static func outputText(_ data: Data) -> String {
        guard let obj = json(data) as? [String: Any] else { return String(decoding: data, as: UTF8.self) }
        if let t = obj["output_text"] as? String { return t }
        var parts: [String] = []
        for item in obj["output"] as? [[String: Any]] ?? [] {
            if let t = item["text"] as? String { parts.append(t) }
            for c in item["content"] as? [[String: Any]] ?? [] { if let t = c["text"] as? String { parts.append(t) } }
        }
        return parts.joined(separator: "\n")
    }

    /// The whole message (callers scrub it, then shorten it: cutting first could leave half a key unmatched).
    public static func errorMessage(_ data: Data) -> String {
        if let obj = json(data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = obj["error"] as? String ?? obj["message"] as? String { return m }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// SAM regions from a response: structured detections in `output[]`, or a JSON object/array in the output text.
    /// Boxes are clamped to the image; empty, non-finite or off-image boxes are dropped.
    public static func regions(_ data: Data, concept: String, imageSize: CGSize) throws -> [SAMRegion] {
        guard let obj = json(data) else { throw MetaError.malformed("not JSON") }
        var raw: [[String: Any]] = []
        if let top = obj as? [String: Any] {
            raw += detections(in: top)
            for item in top["output"] as? [[String: Any]] ?? [] {
                raw += detections(in: item)
                for c in item["content"] as? [[String: Any]] ?? [] { raw += detections(in: c) }
            }
            if raw.isEmpty {
                let text = outputText(data)
                if let embedded = embeddedJSON(text) {
                    if let o = embedded as? [String: Any] { raw += detections(in: o) }
                    if let a = embedded as? [[String: Any]] { raw += a }
                }
            }
        } else if let a = obj as? [[String: Any]] { raw = a }
        return raw.compactMap { region($0, concept: concept, imageSize: imageSize) }
    }

    static func detections(in o: [String: Any]) -> [[String: Any]] {
        for key in ["detections", "masks", "regions", "objects", "results"] {
            if let a = o[key] as? [[String: Any]] { return a }
        }
        return []
    }

    /// A JSON number, strictly: a boolean (which bridging would turn into 0 or 1), a string and anything non-finite are
    /// not numbers, so malformed input cannot become a valid id or coordinate.
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBoolean(n) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func isBoolean(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        return String(describing: type(of: n)).contains("Bool")
        #endif
    }

    /// A JSON integer (3 or 3.0, not 3.5, not true, not "3").
    static func integer(_ v: Any?) -> Int? {
        guard let d = number(v) else { return nil }
        return Int(exactly: d)
    }

    /// A confidence score: absent means 1; a valid number is clamped to 0...1; a present but malformed one counts as 0.
    static func score(_ v: Any?) -> Double {
        guard let v, !(v is NSNull) else { return 1 }
        guard let d = number(v) else { return 0 }
        return min(max(d, 0), 1)
    }

    /// A box that is exactly four JSON numbers, every one valid. Nothing is dropped to make it fit.
    static func fourNumbers(_ v: Any?) -> [Double]? {
        guard let raw = v as? [Any], raw.count == 4 else { return nil }
        var out: [Double] = []
        for item in raw {
            guard let d = number(item) else { return nil }
            out.append(d)
        }
        return out
    }

    static func region(_ d: [String: Any], concept: String, imageSize: CGSize) -> SAMRegion? {
        var r: CGRect?
        let xywh = ((d["box"] ?? d["bbox"]) as? [String: Any]) ?? d
        if let arrayBox = d["box"] ?? d["bbox"] ?? d["xyxy"], arrayBox is [Any] {
            // An array box must be exactly four valid numbers; a malformed one is not read as anything else.
            guard let v = fourNumbers(arrayBox) else { return nil }
            r = CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
        } else if let x = number(xywh["x"]), let y = number(xywh["y"]),
                  let w = number(xywh["width"] ?? xywh["w"]), let h = number(xywh["height"] ?? xywh["h"]) {
            r = CGRect(x: x, y: y, width: w, height: h)
        }
        guard var box = r, box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite else { return nil }
        // Normalised (every edge within 0...1): scale to pixels.
        if box.maxX <= 1.0, box.maxY <= 1.0, box.minX >= 0, box.minY >= 0, imageSize.width > 1 {
            box = CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height,
                         width: box.width * imageSize.width, height: box.height * imageSize.height)
        }
        let image = CGRect(origin: .zero, size: imageSize)
        let clipped = box.standardized.intersection(image)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        let confidence = score(d["score"] ?? d["confidence"])
        let label = (d["label"] as? String) ?? (d["concept"] as? String) ?? concept
        return SAMRegion(box: clipped, score: confidence, concept: label)
    }

    /// The first JSON object or array in a reply (models wrap JSON in prose or ``` fences).
    static func embeddedJSON(_ text: String) -> Any? {
        // Whichever bracket opens first is the outer value ("[{...}]" is an array, not its first object).
        let objectFirst = (text.firstIndex(of: "{") ?? text.endIndex) <= (text.firstIndex(of: "[") ?? text.endIndex)
        for (open, close) in objectFirst ? [("{", "}"), ("[", "]")] : [("[", "]"), ("{", "}")] {
            guard let s = text.firstIndex(of: Character(open)), let e = text.lastIndex(of: Character(close)), s < e,
                  let data = String(text[s...e]).data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            return obj
        }
        return nil
    }

    /// Muse Spark's labels, only for the ids that were asked about. Names are cut to 60 characters; empty ones dropped.
    public static func labels(_ text: String, ids: Set<Int>) -> [Int: MuseLabel] {
        guard let obj = embeddedJSON(text) else { return [:] }
        let rows = (obj as? [String: Any])?["labels"] as? [[String: Any]] ?? (obj as? [[String: Any]]) ?? []
        var out: [Int: MuseLabel] = [:]
        for row in rows {
            guard let id = integer(row["id"]), ids.contains(id),
                  let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let clean = String(name.replacingOccurrences(of: "\n", with: " ").prefix(60))
            out[id] = MuseLabel(id: id, name: clean, role: (row["role"] as? String)?.lowercased())
        }
        return out
    }
}

/// Where the Meta key comes from: the environment only (MODEL_API_KEY, then META_API_KEY). Never written anywhere.
public enum MetaKeySource {
    public static func resolve(environment: [String: String]) -> String? {
        for name in ["MODEL_API_KEY", "META_API_KEY"] {
            if let v = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return nil
    }
}
