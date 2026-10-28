import CoreGraphics
import Foundation

/// Everything a namer needs: the screenshot (downscaled), the numbered boxes the detector found, and what is known.
public struct NamingJob: Sendable {
    public var image: PreparedImage
    public var candidates: [VisionCandidate]
    /// Detector captions by candidate id (hints only).
    public var hints: [Int: String]
    /// Controls already readable through Accessibility, so the namer does not repeat them.
    public var axControls: [Control]
    public var request: String?
    public var windowTitle: String
    public init(image: PreparedImage, candidates: [VisionCandidate], hints: [Int: String] = [:], axControls: [Control] = [],
                request: String? = nil, windowTitle: String = "") {
        self.image = image; self.candidates = candidates; self.hints = hints; self.axControls = axControls
        self.request = request; self.windowTitle = windowTitle
    }
}

/// The control the person's request points at.
public enum NamedTarget: Equatable, Sendable {
    /// One of the numbered candidates.
    case candidate(Int)
    /// Visible but missed by the detector: a box in pixels of the original screenshot, with the model's name for it.
    case box(name: String, rect: CGRect)
}

public struct NamingResult: Equatable, Sendable {
    public var summary: String
    public var labels: [Int: MuseLabel]
    public var target: NamedTarget?
    public var notes: [String]
    public init(summary: String = "", labels: [Int: MuseLabel] = [:], target: NamedTarget? = nil, notes: [String] = []) {
        self.summary = summary; self.labels = labels; self.target = target; self.notes = notes
    }
}

/// Names the detector's boxes (and picks the one a request is about). It never finds controls itself.
public protocol ControlNaming: Sendable {
    var name: String { get }
    func nameControls(_ job: NamingJob) async throws -> NamingResult
}

public final class FakeNamer: ControlNaming, @unchecked Sendable {
    public let name = "fake-namer"
    private let lock = NSLock()
    private var result: Result<NamingResult, ProviderError>
    private var seen: [NamingJob] = []
    public init(result: NamingResult) { self.result = .success(result) }
    public init(error: ProviderError) { self.result = .failure(error) }
    public var jobs: [NamingJob] { lock.lock(); defer { lock.unlock() }; return seen }
    public func nameControls(_ job: NamingJob) async throws -> NamingResult {
        lock.lock(); seen.append(job); let r = result; lock.unlock()
        return try r.get()
    }
}

// MARK: Glimmer prompt, schema, validation

public enum GlimmerNaming {
    /// The enum the model must pick a role from (ControlRole decides what each means for proposing).
    public static let roles = ControlRole.schemaNames
    public static let maxNameLength = 60

    /// JSON Schema for the answer, sent as `response_format` when the server supports it.
    public static func schema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "controls": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "integer"],
                            "name": ["type": "string"],
                            "role": ["type": "string", "enum": roles],
                        ],
                        "required": ["id", "name", "role"],
                        "additionalProperties": false,
                    ],
                ],
                "target": [
                    "type": "object",
                    "properties": [
                        "id": ["type": ["integer", "null"]],
                        "box": ["type": ["array", "null"], "items": ["type": "integer"]],
                        "name": ["type": ["string", "null"]],
                    ],
                    "required": ["id", "box", "name"],
                    "additionalProperties": false,
                ],
            ],
            "required": ["summary", "controls", "target"],
            "additionalProperties": false,
        ]
    }

    public static func prompt(_ job: NamingJob, problem: String?) -> String {
        let size = job.image.originalSize
        let known = ControlFilter.serialize(Array(job.axControls.prefix(30)))
        let rows = job.candidates.map { c -> String in
            let b = GlimmerBoxes.thousandths(forPixelRect: c.pixelBox, imageSize: size)
            let hint = job.hints[c.id].map { ", detector caption \"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? ""
            return "\(c.id): box \(b)\(hint)"
        }.joined(separator: "\n")
        let ask = job.request.map { $0.replacingOccurrences(of: "\n", with: " ") }.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        let markNote = job.image.marked
            ? "Each box is also drawn on the image in red with its id number on a tag at its top-left corner: name what is inside THAT box, not what you would expect at that position.\n"
            : ""
        var s = """
        You name controls in a screenshot of an app window. A detector found the boxes below; each box is [x0, y0, x1, y1] on a \
        0 to 1000 scale (0,0 is the top-left of the image, 1000,1000 the bottom-right). Controls the app already names \
        (skip these): \(known)
        \(markNote)Boxes:
        \(rows)

        """
        if let ask { s += "The person asked: \(ask)\n" }
        s += """
        Name every listed id once, like a screen reader would: 1 to 4 words, what it does. role is one of: \(roles.joined(separator: ", ")). \
        Use "static text" for plain text, a paragraph or a label on the page; "image" for pictures and logos; "other" when unsure. \
        "text field" is only an input box you can type in, never a line of text. "icon" is a small clickable symbol. \
        "target": when the person asked for one specific control, give its id in "id" and null in "box"; if it is visible but not \
        listed, give "id" null and its box on the same 0-1000 scale; with no request, or none that fits, all three fields are null. \
        Reply with one JSON object and nothing else: \
        {"summary": "<one sentence about this window>", "controls": [{"id": 1, "name": "<name>", "role": "button"}], \
        "target": {"id": null, "box": null, "name": null}}
        """
        if let problem { s += "\nYour previous answer was rejected: \(problem). Reply again with valid JSON only." }
        return s
    }

    public static func body(_ job: NamingJob, config: GlimmerConfig, useSchema: Bool, problem: String?) throws -> MetaHTTPRequest {
        var body: [String: Any] = [
            "model": config.model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt(job, problem: problem)],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + job.image.jpeg.base64EncodedString()]],
                ],
            ]],
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "stream": false,
            GlimmerConfig.reasoningStrengthField: GlimmerConfig.reasoningOff,
        ]
        if useSchema {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "shep_control_names", "strict": true, "schema": schema()]]
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return MetaHTTPRequest(url: config.chatURL, method: "POST", headers: ["Content-Type": "application/json"],
                               body: data, timeout: config.timeout, localOnly: true)
    }

    public struct Parsed: Equatable, Sendable {
        /// Nil when the answer is unusable (the caller retries once).
        public var result: NamingResult?
        public var problems: [String]
    }

    /// Validates the model's text against the job: JSON object, a `controls` list, ids from the candidate list, names present.
    /// Bad rows are dropped and noted; an answer with no usable row at all is rejected.
    public static func parse(text: String, job: NamingJob) -> Parsed {
        guard let obj = MetaResponses.embeddedJSON(text) as? [String: Any] else {
            return Parsed(result: nil, problems: ["the answer was not a JSON object"])
        }
        guard let rows = obj["controls"] as? [[String: Any]] else {
            return Parsed(result: nil, problems: ["\"controls\" is missing or not a list"])
        }
        let ids = Set(job.candidates.map(\.id))
        var labels: [Int: MuseLabel] = [:]
        var dropped = 0
        for row in rows {
            guard let id = MetaResponses.integer(row["id"]), ids.contains(id), labels[id] == nil else {
                dropped += 1; continue
            }
            let name = ((row["name"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { dropped += 1; continue }
            let role = ControlRole.recognized(row["role"] as? String)
            labels[id] = MuseLabel(id: id, name: String(name.prefix(maxNameLength)), role: role?.rawValue)
        }
        if labels.isEmpty, !ids.isEmpty {
            return Parsed(result: nil, problems: ["no row had an id from the list (\(ids.sorted().map(String.init).joined(separator: ", "))) with a name"])
        }
        var notes: [String] = []
        if dropped > 0 { notes.append("dropped \(dropped) unusable label(s) from the model") }
        let missing = ids.subtracting(labels.keys).count
        if missing > 0 { notes.append("\(missing) box(es) got no name and are listed as unlabeled") }
        let summary = String(((obj["summary"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(240))
        let result = NamingResult(summary: summary, labels: labels, target: target(in: obj, ids: ids, size: job.image.originalSize), notes: notes)
        return Parsed(result: result, problems: [])
    }

    /// The model's pick of one control. A pick that names an id must name a listed one: an unknown, out-of-range,
    /// fractional, boolean or text id is no target (it never falls back to the box, and never to the first candidate).
    /// Without an id, the box must be exactly four valid numbers on the 0...1000 scale.
    static func target(in obj: [String: Any], ids: Set<Int>, size: CGSize) -> NamedTarget? {
        guard let t = obj["target"] as? [String: Any] else { return nil }
        if let idValue = t["id"], !(idValue is NSNull) {
            guard let id = MetaResponses.integer(idValue), ids.contains(id) else { return nil }
            return .candidate(id)
        }
        if let boxValue = t["box"], !(boxValue is NSNull) {
            guard let v = MetaResponses.fourNumbers(boxValue), let rect = GlimmerBoxes.pixelRect(fromThousandths: v, imageSize: size) else { return nil }
            let name = ((t["name"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return .box(name: name.isEmpty ? "unlabeled control" : String(name.prefix(maxNameLength)), rect: rect)
        }
        return nil
    }
}

// MARK: Glimmer namer

public final class GlimmerNamer: ControlNaming, @unchecked Sendable {
    public let name = "glimmer"
    public let config: GlimmerConfig
    private let transport: any MetaTransport
    private let lock = NSLock()
    private var schemaSupported = true

    public init(config: GlimmerConfig = GlimmerConfig(), transport: any MetaTransport = URLSessionMetaTransport()) {
        self.config = config; self.transport = transport
    }

    private func useSchema() -> Bool { lock.lock(); defer { lock.unlock() }; return schemaSupported }
    private func setSchemaUnsupported() { lock.lock(); schemaSupported = false; lock.unlock() }

    /// One question, then at most one retry when the answer is not valid JSON for this job.
    public func nameControls(_ job: NamingJob) async throws -> NamingResult {
        try config.validate()
        if job.candidates.isEmpty { return NamingResult() }
        var problem: String?
        for _ in 0..<2 {
            let text = try await ask(job, problem: problem)
            let parsed = GlimmerNaming.parse(text: text, job: job)
            if let result = parsed.result { return result }
            problem = parsed.problems.joined(separator: "; ")
        }
        throw ProviderError.malformed("Glimmer's answer was not usable twice in a row (\(problem ?? "unknown"))")
    }

    private func ask(_ job: NamingJob, problem: String?) async throws -> String {
        var schema = useSchema()
        var response = try await send(GlimmerNaming.body(job, config: config, useSchema: schema, problem: problem))
        // A server that does not know response_format says so with a client error: ask again with the prompt alone.
        if schema, response.status == 400 || response.status == 422 {
            setSchemaUnsupported()
            schema = false
            response = try await send(GlimmerNaming.body(job, config: config, useSchema: false, problem: problem))
        }
        guard (200..<300).contains(response.status) else {
            throw ProviderError.http(response.status, String(Redact.scrub(MetaResponses.errorMessage(response.body)).prefix(200)))
        }
        guard let text = GlimmerResponses.content(response.body) else { throw ProviderError.malformed("no choices[0].message.content") }
        return text
    }

    private func send(_ request: MetaHTTPRequest) async throws -> MetaHTTPResponse {
        do { return try await transport.send(request) }
        catch { throw ProviderError.unreachable(Redact.scrub(error.localizedDescription)) }
    }
}
