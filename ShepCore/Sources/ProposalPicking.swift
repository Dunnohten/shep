import CoreGraphics
import Foundation

/// Written for Shep.
/// The model's part of proposing: among the few best-ranked controls, each shown with a mark number (also drawn on the
/// screenshot), say which ones answer the request, or, with no request, the one most likely helpful next step. The model
/// answers with mark numbers only; it never invents a control.

public struct PickCandidate: Equatable, Sendable {
    public var mark: Int
    public var control: Control
    public init(mark: Int, control: Control) { self.mark = mark; self.control = control }
}

public struct PickJob: Sendable {
    /// The screenshot with the marks drawn on it, when it could be prepared.
    public var image: PreparedImage?
    public var candidates: [PickCandidate]
    public var request: String?
    public var windowTitle: String
    public init(image: PreparedImage?, candidates: [PickCandidate], request: String?, windowTitle: String) {
        self.image = image; self.candidates = candidates; self.request = request; self.windowTitle = windowTitle
    }
    /// With a request up to `ProposalRanker.maxProposals` picks; without one exactly the single best next step.
    public var maxPicks: Int { (request ?? "").isEmpty ? 1 : ProposalRanker.maxProposals }
}

public struct PickResult: Equatable, Sendable {
    /// Mark numbers, best first, each from the job, at most `maxPicks`. Empty: nothing fits.
    public var marks: [Int]
    /// One sentence, shown when nothing fits.
    public var explanation: String
    public init(marks: [Int], explanation: String = "") { self.marks = marks; self.explanation = explanation }
}

public protocol ProposalPicking: Sendable {
    var name: String { get }
    func pick(_ job: PickJob) async throws -> PickResult
}

public final class FakePicker: ProposalPicking, @unchecked Sendable {
    public let name = "fake-picker"
    private let lock = NSLock()
    private var result: Result<PickResult, ProviderError>
    private var seen: [PickJob] = []
    public init(result: PickResult) { self.result = .success(result) }
    public init(error: ProviderError) { self.result = .failure(error) }
    public var jobs: [PickJob] { lock.lock(); defer { lock.unlock() }; return seen }
    public func pick(_ job: PickJob) async throws -> PickResult {
        lock.lock(); seen.append(job); let r = result; lock.unlock()
        return try r.get()
    }
}

// MARK: Glimmer prompt, schema, validation

public enum GlimmerPicking {
    public static func schema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "picks": ["type": "array", "items": ["type": "integer"]],
                "reason": ["type": "string"],
            ],
            "required": ["picks", "reason"],
            "additionalProperties": false,
        ]
    }

    public static func prompt(_ job: PickJob, problem: String?) -> String {
        let rows = job.candidates.map { c -> String in
            let origin = c.control.fromVision ? "found on the screenshot" : "listed by the app"
            return "\(c.mark): \(c.control.kind) \"\(c.control.label)\" (\(origin))"
        }.joined(separator: "\n")
        let marked = job.image?.marked == true ? "Each candidate is drawn on the image in red with its mark number on a tag at its top-left corner.\n" : ""
        var s = "You help a person use the window \"\(job.windowTitle)\". These are the controls that could be pressed:\n\(rows)\n\(marked)"
        let ask = String((job.request ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if !ask.isEmpty {
            s += "The person asked: \(ask)\nPick up to \(ProposalRanker.maxProposals) mark numbers whose control does what they asked, best first. "
            s += "If none of them does, pick none and say why in one sentence. "
        } else {
            s += "The person gave no request. Pick exactly ONE mark number: the control that is the most likely helpful next step in this window. If none is clearly helpful, pick none and say why. "
        }
        s += "Never pick anything that closes, quits, deletes or pays unless it was asked for. "
        s += "Reply with one JSON object and nothing else: {\"picks\": [<mark numbers>], \"reason\": \"<one sentence>\"}"
        if let problem { s += "\nYour previous answer was rejected: \(problem). Reply again with valid JSON only." }
        return s
    }

    public static func body(_ job: PickJob, config: GlimmerConfig, useSchema: Bool, problem: String?) throws -> MetaHTTPRequest {
        var content: [[String: Any]] = [["type": "text", "text": prompt(job, problem: problem)]]
        if let image = job.image {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.jpeg.base64EncodedString()]])
        }
        var body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": content]],
            "max_tokens": min(config.maxTokens, 400),
            "temperature": config.temperature,
            "stream": false,
            GlimmerConfig.reasoningStrengthField: GlimmerConfig.reasoningOff,
        ]
        if useSchema {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "shep_picks", "strict": true, "schema": schema()]]
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return MetaHTTPRequest(url: config.chatURL, method: "POST", headers: ["Content-Type": "application/json"], body: data, timeout: config.timeout, localOnly: true)
    }

    public struct Parsed: Equatable, Sendable {
        public var result: PickResult?
        public var problems: [String]
    }

    /// A JSON object with a `picks` list of mark numbers. Strict: every entry must be an integer naming a listed mark, once.
    /// A boolean, text, fractional, unknown, out-of-range or repeated entry rejects the whole answer (the caller asks again
    /// once, then gives up), so a damaged answer is never read as a different pick. A list longer than `maxPicks` is cut.
    public static func parse(text: String, job: PickJob) -> Parsed {
        guard let obj = MetaResponses.embeddedJSON(text) as? [String: Any] else {
            return Parsed(result: nil, problems: ["the answer was not a JSON object"])
        }
        guard let raw = obj["picks"] as? [Any] else { return Parsed(result: nil, problems: ["\"picks\" is missing or not a list"]) }
        let valid = Set(job.candidates.map(\.mark))
        var marks: [Int] = []
        for (i, item) in raw.enumerated() {
            guard let mark = MetaResponses.integer(item), valid.contains(mark), !marks.contains(mark) else {
                return Parsed(result: nil, problems: ["pick \(i + 1) is not a distinct mark number from the list (\(valid.sorted().map(String.init).joined(separator: ", ")))"])
            }
            marks.append(mark)
        }
        marks = Array(marks.prefix(job.maxPicks))
        let reason = String(((obj["reason"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return Parsed(result: PickResult(marks: marks, explanation: reason), problems: [])
    }
}

// MARK: Glimmer picker

public final class GlimmerPicker: ProposalPicking, @unchecked Sendable {
    public let name = "glimmer-picker"
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
    public func pick(_ job: PickJob) async throws -> PickResult {
        try config.validate()
        if job.candidates.isEmpty { return PickResult(marks: []) }
        var problem: String?
        for _ in 0..<2 {
            let text = try await ask(job, problem: problem)
            let parsed = GlimmerPicking.parse(text: text, job: job)
            if let result = parsed.result { return result }
            problem = parsed.problems.joined(separator: "; ")
        }
        throw ProviderError.malformed("Glimmer's pick was not usable twice in a row (\(problem ?? "unknown"))")
    }

    private func ask(_ job: PickJob, problem: String?) async throws -> String {
        var schema = useSchema()
        var response = try await send(GlimmerPicking.body(job, config: config, useSchema: schema, problem: problem))
        if schema, response.status == 400 || response.status == 422 {
            setSchemaUnsupported()
            schema = false
            response = try await send(GlimmerPicking.body(job, config: config, useSchema: false, problem: problem))
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
