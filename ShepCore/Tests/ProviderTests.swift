import CoreGraphics
import XCTest
@testable import ShepCore

final class StubTransport: MetaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [MetaHTTPRequest] = []
    /// Answers in order; the last one repeats.
    private var replies: [Result<MetaHTTPResponse, Error>]
    init(_ reply: Result<MetaHTTPResponse, Error>) { replies = [reply] }
    init(sequence: [Result<MetaHTTPResponse, Error>]) { replies = sequence }
    func send(_ request: MetaHTTPRequest) async throws -> MetaHTTPResponse {
        lock.lock()
        requests.append(request)
        let r = replies.count > 1 ? replies.removeFirst() : replies[0]
        lock.unlock()
        return try r.get()
    }
    func bodies() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return requests.compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }
}

struct FakePreparer: ImagePreparing {
    var result: PreparedImage?
    func prepare(png: Data, longestSide: CGFloat, quality: CGFloat) -> PreparedImage? { result }
}

func chatReply(_ content: String) -> Result<MetaHTTPResponse, Error> {
    let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    return .success(MetaHTTPResponse(status: 200, body: body))
}

func assertRect(_ a: CGRect?, _ b: CGRect, accuracy: CGFloat = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("nil rect, expected \(b)", file: file, line: line) }
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
}

final class GlimmerNamerTests: XCTestCase {
    // A 3024x1964 Retina screenshot downscaled to 960x624.
    let prepared = PreparedImage(jpeg: Data([0xFF, 0xD8, 0xFF]), size: CGSize(width: 960, height: 624), originalSize: CGSize(width: 3024, height: 1964))
    var candidates: [VisionCandidate] {
        [VisionCandidate(id: 1, pixelBox: CGRect(x: 1512, y: 982, width: 151.2, height: 98.2), screenFrame: CGRect(x: 756, y: 491, width: 75.6, height: 49.1), concept: "icon", score: 0.9),
         VisionCandidate(id: 2, pixelBox: CGRect(x: 300, y: 100, width: 200, height: 100), screenFrame: CGRect(x: 150, y: 50, width: 100, height: 50), concept: "icon", score: 0.8)]
    }
    func job(request: String? = nil, hints: [Int: String] = [:]) -> NamingJob {
        NamingJob(image: prepared, candidates: candidates, hints: hints,
                  axControls: [Control(index: 1, role: "AXButton", title: "Send", frame: CGRect(x: 1, y: 2, width: 30, height: 20))],
                  request: request, windowTitle: "Inbox")
    }
    let good = #"{"summary":"A mail window.","controls":[{"id":1,"name":"Settings","role":"button"},{"id":2,"name":"Search","role":"text field"}],"target":{"id":null,"box":null,"name":null}}"#

    func testDefaultsAreTheLocalServerAndNotAnyOtherPort() {
        let c = GlimmerConfig()
        XCTAssertEqual(c.baseURL.absoluteString, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(c.chatURL.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertEqual(c.maxTokens, 1500)
        XCTAssertEqual(c.temperature, 0)
        XCTAssertEqual(c.longestSide, 960)
        XCTAssertNoThrow(try c.validate())
        XCTAssertEqual(GlimmerConfig.defaultModelPath(home: "/Users/me/"), "/Users/me/models/Muse-Glimmer-30B-4bit")
    }

    func testConfigRefusesOtherModelServersAndRemoteHosts() {
        XCTAssertThrowsError(try GlimmerConfig(baseURL: URL(string: "http://127.0.0.1:\(11230 + 4)/v1")!).validate())
        XCTAssertThrowsError(try GlimmerConfig(baseURL: URL(string: "http://example.com:8080/v1")!).validate())
        XCTAssertThrowsError(try GlimmerConfig(maxTokens: 5000).validate())
        XCTAssertNoThrow(try GlimmerConfig(baseURL: URL(string: "http://127.0.0.1:18089/v1")!).validate(), "an already-running llama-server is fine")
    }

    // MARK: 0-1000 boxes

    func testBoxesOnTheThousandScaleBecomeOriginalPixels() throws {
        let size = CGSize(width: 3024, height: 1964)
        let r = try XCTUnwrap(GlimmerBoxes.pixelRect(fromThousandths: [480, 312, 528, 360], imageSize: size))
        XCTAssertEqual(r.minX, 480.0 / 1000 * 3024, accuracy: 1e-6)
        XCTAssertEqual(r.minY, 312.0 / 1000 * 1964, accuracy: 1e-6)
        XCTAssertEqual(r.width, 48.0 / 1000 * 3024, accuracy: 1e-6)
        XCTAssertEqual(r.height, 48.0 / 1000 * 1964, accuracy: 1e-6)
        // The scale is relative to the image: the same numbers on a different image size give different pixels.
        let small = try XCTUnwrap(GlimmerBoxes.pixelRect(fromThousandths: [480, 312, 528, 360], imageSize: CGSize(width: 1000, height: 500)))
        assertRect(small, CGRect(x: 480, y: 156, width: 48, height: 24))
    }

    func testThousandthsRoundTrip() {
        let size = CGSize(width: 3024, height: 1964)
        let px = CGRect(x: 1512, y: 982, width: 302.4, height: 196.4)
        XCTAssertEqual(GlimmerBoxes.thousandths(forPixelRect: px, imageSize: size), [500, 500, 600, 600])
        let back = GlimmerBoxes.pixelRect(fromThousandths: GlimmerBoxes.thousandths(forPixelRect: px, imageSize: size).map(Double.init), imageSize: size)!
        XCTAssertEqual(back.minX, px.minX, accuracy: 3024.0 / 1000)
        XCTAssertEqual(GlimmerBoxes.thousandths(forPixelRect: CGRect(x: -50, y: 0, width: 4000, height: 10), imageSize: size), [0, 0, 1000, 5])
    }

    func testBadBoxesAreRejected() {
        let size = CGSize(width: 1000, height: 1000)
        XCTAssertNil(GlimmerBoxes.pixelRect(fromThousandths: [1, 2, 3], imageSize: size))
        XCTAssertNil(GlimmerBoxes.pixelRect(fromThousandths: [Double.nan, 0, 10, 10], imageSize: size))
        XCTAssertNil(GlimmerBoxes.pixelRect(fromThousandths: [1100, 1100, 1200, 1200], imageSize: size), "off the image")
        XCTAssertNil(GlimmerBoxes.pixelRect(fromThousandths: [10, 10, 11, 11], imageSize: size), "under 2 px")
        XCTAssertNil(GlimmerBoxes.pixelRect(fromThousandths: [0, 0, 10, 10], imageSize: .zero))
        // Corners given the wrong way round are fixed; a box poking past the edge is clipped.
        assertRect(GlimmerBoxes.pixelRect(fromThousandths: [200, 200, 100, 100], imageSize: size), CGRect(x: 100, y: 100, width: 100, height: 100))
        assertRect(GlimmerBoxes.pixelRect(fromThousandths: [900, 900, 1200, 1200], imageSize: size), CGRect(x: 900, y: 900, width: 100, height: 100))
    }

    // MARK: request

    func testRequestDisablesThinkingTheMeasuredWayAndAsksForSchemaJSON() throws {
        let r = try GlimmerNaming.body(job(request: "find the gear", hints: [1: "gear icon"]), config: GlimmerConfig(), useSchema: true, problem: nil)
        XCTAssertEqual(r.url.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertNil(r.headers["Authorization"], "no key goes to the local server")
        XCTAssertTrue(r.localOnly, "the transport sends a local request only to loopback")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertEqual(obj["reasoning_strength"] as? String, "none")
        XCTAssertNil(obj["chat_template_kwargs"])
        XCTAssertNil(obj["enable_thinking"])
        XCTAssertEqual(obj["max_tokens"] as? Int, 1500)
        XCTAssertEqual(obj["temperature"] as? Double, 0)
        XCTAssertEqual(obj["stream"] as? Bool, false)
        let format = try XCTUnwrap(obj["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let js = try XCTUnwrap(format["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(js["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["summary", "controls", "target"])
        let content = try XCTUnwrap(((obj["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("find the gear"))
        XCTAssertTrue(text.contains("1: box [500, 500, 550, 550]"), "candidate 1 is shown on the 0-1000 scale: \(text)")
        XCTAssertTrue(text.contains("detector caption \"gear icon\""))
        XCTAssertTrue(text.contains("\"label\":\"Send\""), "known AX controls are listed so the model skips them")
        let url = try XCTUnwrap((content.last?["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertEqual(url, "data:image/jpeg;base64," + prepared.jpeg.base64EncodedString())
    }

    func testPromptOnlyRequestHasNoResponseFormatAndCarriesTheProblem() throws {
        let r = try GlimmerNaming.body(job(), config: GlimmerConfig(), useSchema: false, problem: "the answer was not a JSON object")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertNil(obj["response_format"])
        let content = try XCTUnwrap(((obj["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String ?? "").contains("previous answer was rejected: the answer was not a JSON object"))
    }

    // MARK: parsing and validation

    func testGoodAnswerParses() {
        let p = GlimmerNaming.parse(text: "```json\n" + good + "\n```", job: job())
        let r = p.result
        XCTAssertEqual(r?.summary, "A mail window.")
        XCTAssertEqual(r?.labels[1]?.name, "Settings")
        XCTAssertEqual(r?.labels[2]?.role, "text field")
        XCTAssertNil(r?.target)
        XCTAssertTrue(p.problems.isEmpty)
    }

    func testBadRowsAreDroppedAndUnknownRolesBecomeNil() {
        let text = #"{"summary":"s","controls":[{"id":1,"name":"Gear","role":"Wobbly"},{"id":9,"name":"Ghost","role":"button"},{"id":2,"name":"  ","role":"button"},{"id":1,"name":"Dup","role":"button"}],"target":null}"#
        let r = GlimmerNaming.parse(text: text, job: job()).result
        XCTAssertEqual(r?.labels.count, 1)
        XCTAssertEqual(r?.labels[1]?.name, "Gear")
        XCTAssertNil(r?.labels[1]?.role)
        XCTAssertTrue((r?.notes ?? []).contains { $0.contains("dropped 3") })
        XCTAssertTrue((r?.notes ?? []).contains { $0.contains("1 box(es) got no name") })
    }

    func testUnusableAnswersAreRejectedWithAReason() {
        for text in ["I cannot help", "{}", #"{"controls":"none"}"#, #"{"summary":"s","controls":[{"id":7,"name":"X"}]}"#, ""] {
            let p = GlimmerNaming.parse(text: text, job: job())
            XCTAssertNil(p.result, text)
            XCTAssertFalse(p.problems.isEmpty, text)
        }
    }

    func testTargetByIdAndByConvertedBox() {
        let byId = GlimmerNaming.parse(text: #"{"summary":"s","controls":[{"id":1,"name":"Gear","role":"button"}],"target":{"id":1,"box":null,"name":null}}"#, job: job()).result
        XCTAssertEqual(byId?.target, .candidate(1))
        let byBox = GlimmerNaming.parse(text: #"{"summary":"s","controls":[{"id":1,"name":"Gear","role":"button"}],"target":{"id":null,"box":[100,200,150,250],"name":"Mute"}}"#, job: job()).result
        guard case .box(let name, let rect)? = byBox?.target else { return XCTFail("\(String(describing: byBox?.target))") }
        XCTAssertEqual(name, "Mute")
        XCTAssertEqual(rect.minX, 0.1 * 3024, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, 0.2 * 1964, accuracy: 1e-6)
        XCTAssertEqual(rect.width, 0.05 * 3024, accuracy: 1e-6)
        let unknownId = GlimmerNaming.parse(text: #"{"summary":"s","controls":[{"id":1,"name":"Gear"}],"target":{"id":42,"box":null,"name":null}}"#, job: job()).result
        XCTAssertNil(unknownId?.target)
    }

    // MARK: the namer end to end (stub transport)

    func testNamerRoundTrip() async throws {
        let t = StubTransport(chatReply(good))
        let namer = GlimmerNamer(transport: t)
        let r = try await namer.nameControls(job())
        XCTAssertEqual(r.labels.count, 2)
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertNotNil(t.bodies().first?["response_format"])
    }

    func testOneRetryOnBadJSONThenSuccess() async throws {
        let t = StubTransport(sequence: [chatReply("Sure! Here are the names"), chatReply(good)])
        let r = try await GlimmerNamer(transport: t).nameControls(job())
        XCTAssertEqual(r.labels[1]?.name, "Settings")
        XCTAssertEqual(t.requests.count, 2)
        let second = try XCTUnwrap(t.bodies().last)
        let text = (((second["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("previous answer was rejected"))
    }

    func testTwoBadAnswersFailAfterExactlyOneRetry() async {
        let t = StubTransport(chatReply("nope"))
        do { _ = try await GlimmerNamer(transport: t).nameControls(job()); XCTFail("must throw") }
        catch { guard case .malformed? = error as? ProviderError else { return XCTFail("\(error)") } }
        XCTAssertEqual(t.requests.count, 2)
    }

    func testServerWithoutResponseFormatFallsBackToThePromptAndRemembersIt() async throws {
        let reject = Result<MetaHTTPResponse, Error>.success(MetaHTTPResponse(status: 400, body: Data(#"{"error":"unknown field response_format"}"#.utf8)))
        let t = StubTransport(sequence: [reject, chatReply(good)])
        let namer = GlimmerNamer(transport: t)
        _ = try await namer.nameControls(job())
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertNotNil(t.bodies()[0]["response_format"])
        XCTAssertNil(t.bodies()[1]["response_format"])
        _ = try await namer.nameControls(job())
        XCTAssertEqual(t.requests.count, 3)
        XCTAssertNil(t.bodies()[2]["response_format"], "the next call does not try the schema again")
    }

    func testErrorsAreReported() async {
        let down = GlimmerNamer(transport: StubTransport(.failure(URLError(.cannotConnectToHost))))
        do { _ = try await down.nameControls(job()); XCTFail("must throw") }
        catch { guard case .unreachable? = error as? ProviderError else { return XCTFail("\(error)") } }

        let bad = GlimmerNamer(transport: StubTransport(.success(MetaHTTPResponse(status: 500, body: Data(#"{"error":"boom"}"#.utf8)))))
        do { _ = try await bad.nameControls(job()); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? ProviderError, .http(500, "boom")) }

        let empty = GlimmerNamer(transport: StubTransport(.success(MetaHTTPResponse(status: 200, body: Data(#"{"choices":[]}"#.utf8)))))
        do { _ = try await empty.nameControls(job()); XCTFail("must throw") }
        catch { guard case .malformed? = error as? ProviderError else { return XCTFail("\(error)") } }
    }

    func testNothingIsSentToARefusedServerOrWhenThereIsNothingToName() async throws {
        let t = StubTransport(chatReply(good))
        let refused = GlimmerNamer(config: GlimmerConfig(baseURL: URL(string: "http://127.0.0.1:\(11230 + 4)/v1")!), transport: t)
        do { _ = try await refused.nameControls(job()); XCTFail("must throw") } catch {}
        var none = job()
        none.candidates = []
        let r = try await GlimmerNamer(transport: t).nameControls(none)
        XCTAssertTrue(r.labels.isEmpty)
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testResponseContentParsing() {
        XCTAssertNil(GlimmerResponses.content(Data("nope".utf8)))
        XCTAssertNil(GlimmerResponses.content(Data(#"{"choices":[]}"#.utf8)))
        let parts = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#.utf8)
        XCTAssertEqual(GlimmerResponses.content(parts), "a\nb")
    }
}

final class ProviderFactoryTests: XCTestCase {
    func testDefaultIsGlimmerAndMetaNeedsAKey() {
        XCTAssertEqual(ProviderFactory.select(config: ProviderConfig(), environment: [:]).kind, .glimmer)
        let wantsMeta = ProviderConfig(preferred: .meta)
        let noKey = ProviderFactory.select(config: wantsMeta, environment: [:])
        XCTAssertEqual(noKey.kind, .glimmer)
        XCTAssertNotNil(noKey.note)
        XCTAssertEqual(ProviderFactory.select(config: wantsMeta, environment: ["MODEL_API_KEY": "  "]).kind, .glimmer)
        XCTAssertEqual(ProviderFactory.select(config: wantsMeta, environment: ["MODEL_API_KEY": "abc12345"]).kind, .meta)
    }

    func testAKeyAloneNeverSwitchesToMeta() {
        XCTAssertEqual(ProviderFactory.select(config: ProviderConfig(), environment: ["MODEL_API_KEY": "abc12345"]).kind, .glimmer)
    }

    func testConfigFromEnvironment() {
        let c = ProviderConfig.from(environment: ["SHEP_PROVIDER": "META", "SHEP_GLIMMER_URL": "http://127.0.0.1:9000/v1", "SHEP_GLIMMER_MODEL": "/m/x"], home: "/Users/me")
        XCTAssertEqual(c.preferred, .meta)
        XCTAssertEqual(c.glimmer.baseURL.port, 9000)
        XCTAssertEqual(c.glimmer.model, "/m/x")
        let d = ProviderConfig.from(environment: ["SHEP_PROVIDER": "bogus"], home: "/Users/me")
        XCTAssertEqual(d.preferred, .glimmer)
        XCTAssertEqual(d.glimmer.model, "/Users/me/models/Muse-Glimmer-30B-4bit")
        XCTAssertEqual(d.glimmer.baseURL.absoluteString, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(d.detector.baseURL.absoluteString, "http://127.0.0.1:8765")
        XCTAssertFalse(d.detector.useSAM3, "SAM 3 is off by default")
    }

    func testDetectorAndSAM3FlagsComeFromTheEnvironment() {
        let c = ProviderConfig.from(environment: ["SHEP_DETECTOR_URL": "http://127.0.0.1:9100", "SHEP_SAM3": "1"], home: "/Users/me")
        XCTAssertEqual(c.detector.baseURL.port, 9100)
        XCTAssertTrue(c.detector.useSAM3)
        for off in ["0", "", "no", "false"] {
            XCTAssertFalse(ProviderConfig.from(environment: ["SHEP_SAM3": off], home: "/h").detector.useSAM3, off)
        }
    }

    func testReusingARunningGlimmerServerIsJustAnEnvironmentVariable() {
        let c = ProviderConfig.from(environment: ["SHEP_GLIMMER_URL": "http://127.0.0.1:18089/v1"], home: "/Users/me")
        XCTAssertEqual(c.glimmer.baseURL.port, 18089)
        XCTAssertNoThrow(try c.glimmer.validate())
        XCTAssertEqual(c.glimmer.chatURL.absoluteString, "http://127.0.0.1:18089/v1/chat/completions")
    }

    func testMakeBuildsTheSelectedProvider() throws {
        let g = try ProviderFactory.make(config: ProviderConfig(), environment: [:])
        XCTAssertEqual(g.provider.name, "omniparser-v3+glimmer")
        XCTAssertFalse(g.provider.sendsOffDevice)
        var withSAM = ProviderConfig()
        withSAM.detector.useSAM3 = true
        XCTAssertEqual(try ProviderFactory.make(config: withSAM, environment: [:]).provider.name, "omniparser-v3+sam3+glimmer")
        let m = try ProviderFactory.make(config: ProviderConfig(preferred: .meta), environment: ["MODEL_API_KEY": "abc12345"])
        XCTAssertEqual(m.provider.name, "meta")
        XCTAssertTrue(m.provider.sendsOffDevice)
        let fake = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
        XCTAssertEqual(try ProviderFactory.make(config: ProviderConfig(preferred: .fake), environment: [:], fake: fake).provider.name, "fake")
        XCTAssertThrowsError(try ProviderFactory.make(config: ProviderConfig(preferred: .fake), environment: [:]))
    }

    func testMakeRefusesAForbiddenGlimmerOrDetectorConfig() {
        var c = ProviderConfig()
        c.glimmer.baseURL = URL(string: "http://127.0.0.1:\(11230 + 4)/v1")!
        XCTAssertThrowsError(try ProviderFactory.make(config: c, environment: [:]))
        var d = ProviderConfig()
        d.detector.baseURL = URL(string: "http://example.com:8765")!
        XCTAssertThrowsError(try ProviderFactory.make(config: d, environment: [:]))
    }
}

final class MetaProviderTests: XCTestCase {
    final class Vision: MetaVisioning, @unchecked Sendable {
        func segment(png: Data, imageSize: CGSize, concept: String) async throws -> [SAMRegion] {
            concept == "button" ? [SAMRegion(box: CGRect(x: 600, y: 100, width: 60, height: 60), score: 0.9, concept: "button")] : []
        }
        func name(png: Data, candidates: [VisionCandidate], request: String?) async throws -> [Int: MuseLabel] {
            [1: MuseLabel(id: 1, name: "Settings", role: "button")]
        }
    }
    func testMetaProviderNamesWhatSAMFound() async throws {
        let geo = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
        let a = try await MetaProvider(vision: Vision(), concepts: ["button", "icon"])
            .analyze(VisionInput(png: Data([1]), geometry: geo, axControls: [], bundleID: "com.example", windowTitle: "W"))
        XCTAssertEqual(a.controls.map(\.name), ["Settings"])
        XCTAssertEqual(a.controls[0].box, CGRect(x: 600, y: 100, width: 60, height: 60))
    }
}
