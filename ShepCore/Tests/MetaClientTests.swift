import CoreGraphics
import XCTest
// Provenance: written on 2026-10-26 at about 11:44 AM CT (after the 11:00 AM CT start of the hackathon) on the author's earlier
// working branch for this same hackathon, reviewed at 11:52 AM CT, and carried into this repository.
@testable import ShepCore

/// Meta hackathon: request builders and parsers for SAM 3.1 and Muse Spark. No network: every response is a stub whose
/// shape is ASSUMED (see MetaClient.swift); these tests pin our reading of it, not Meta's real API.
final class MetaClientTests: XCTestCase {
    /// Records every request; answers from a queue.
    final class StubTransport: MetaTransport, @unchecked Sendable {
        var requests: [MetaHTTPRequest] = []
        var replies: [MetaHTTPResponse]
        init(_ replies: [MetaHTTPResponse]) { self.replies = replies }
        func send(_ request: MetaHTTPRequest) async throws -> MetaHTTPResponse {
            requests.append(request)
            return replies.isEmpty ? MetaHTTPResponse(status: 500, body: Data()) : replies.removeFirst()
        }
    }

    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let size = CGSize(width: 800, height: 600)
    func body(_ s: String) -> MetaHTTPResponse { MetaHTTPResponse(status: 200, body: Data(s.utf8)) }
    func json(_ r: MetaHTTPRequest) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any]) }

    func testSegmentRequestIsAResponsesCallWithTheConceptAndTheImage() throws {
        let r = try MetaRequests.segment(png: png, concept: "button", key: "test-key-123456", config: MetaConfig())
        XCTAssertEqual(r.url.absoluteString, "https://api.meta.ai/v1/responses")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["Authorization"], "Bearer test-key-123456")
        let obj = try json(r)
        XCTAssertEqual(obj["model"] as? String, "sam-3.1")
        let input = try XCTUnwrap((obj["input"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap(input["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "button")
        XCTAssertEqual(content.last?["type"] as? String, "input_image")
        XCTAssertEqual(content.last?["image_url"] as? String, "data:image/png;base64," + png.base64EncodedString())
    }

    func testNameRequestUsesMuseAndListsEveryNumberedBox() throws {
        let c = [VisionCandidate(id: 1, pixelBox: CGRect(x: 10, y: 20, width: 30, height: 40), screenFrame: .zero, concept: "icon", score: 0.9),
                 VisionCandidate(id: 2, pixelBox: CGRect(x: 100, y: 20, width: 30, height: 40), screenFrame: .zero, concept: "button", score: 0.8)]
        let r = try MetaRequests.name(png: png, candidates: c, request: "send the message", key: "k-12345678", config: MetaConfig())
        let obj = try json(r)
        XCTAssertEqual(obj["model"] as? String, "muse-spark-1.3")
        let text = try XCTUnwrap((((obj["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("1: icon at x=10 y=20 w=30 h=40"))
        XCTAssertTrue(text.contains("2: button at x=100"))
        XCTAssertTrue(text.contains("JSON only"))
        XCTAssertTrue(text.contains("send the message"))
    }

    func testNoKeyFailsBeforeAnythingIsSent() async {
        let t = StubTransport([])
        let client = MetaClient(apiKey: "  ", transport: t)
        do { _ = try await client.segment(png: png, imageSize: size, concept: "button"); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? MetaError, .noKey) }
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testStructuredDetectionsInPixels() throws {
        let data = Data(#"{"output":[{"type":"segmentation","detections":[{"box":[100,50,180,90],"score":0.92,"label":"button"},{"box":[10,10,11,11],"score":0.5}]}]}"#.utf8)
        let r = try MetaResponses.regions(data, concept: "button", imageSize: size)
        XCTAssertEqual(r.count, 1, "a 1x1 box is noise and is dropped")
        XCTAssertEqual(r[0].box, CGRect(x: 100, y: 50, width: 80, height: 40))
        XCTAssertEqual(r[0].score, 0.92, accuracy: 1e-9)
    }

    func testJSONInOutputTextWithNormalisedXYWH() throws {
        let text = "Here you go:\n```json\n{\"masks\": [{\"bbox\": {\"x\": 0.5, \"y\": 0.5, \"width\": 0.25, \"height\": 0.1}, \"score\": 0.7}]}\n```"
        let payload = try JSONSerialization.data(withJSONObject: ["output": [["type": "message", "content": [["type": "output_text", "text": text]]]]])
        let r = try MetaResponses.regions(payload, concept: "text field", imageSize: size)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].box, CGRect(x: 400, y: 300, width: 200, height: 60))
        XCTAssertEqual(r[0].concept, "text field")
    }

    func testBoxesAreClampedToTheImageAndOffImageOnesDropped() throws {
        let data = Data(#"{"detections":[{"box":[780,580,900,700]},{"box":[900,900,950,950]},{"box":["a",1,2,3]}]}"#.utf8)
        let r = try MetaResponses.regions(data, concept: "button", imageSize: size)
        XCTAssertEqual(r.map(\.box), [CGRect(x: 780, y: 580, width: 20, height: 20)])
    }

    func testMalformedSAMAnswers() {
        XCTAssertThrowsError(try MetaResponses.regions(Data("not json".utf8), concept: "button", imageSize: size))
        XCTAssertEqual(try MetaResponses.regions(Data(#"{"output":[]}"#.utf8), concept: "button", imageSize: size), [])
        XCTAssertEqual(try MetaResponses.regions(Data(#"{"output_text":"I see two buttons."}"#.utf8), concept: "button", imageSize: size), [])
    }

    func testMuseLabelsOnlyForAskedIdsAndCleaned() {
        let text = #"Sure! {"labels":[{"id":1,"name":"Send","role":"Button"},{"id":"2","name":"  "},{"id":9,"name":"Ghost"},{"id":3,"name":"Search\nfield"}]}"#
        let l = MetaResponses.labels(text, ids: [1, 2, 3])
        XCTAssertEqual(l[1], MuseLabel(id: 1, name: "Send", role: "button"))
        XCTAssertNil(l[2], "empty names are dropped")
        XCTAssertNil(l[9], "ids that weren't asked about are ignored")
        XCTAssertEqual(l[3]?.name, "Search field")
        XCTAssertEqual(MetaResponses.labels("no json here", ids: [1]), [:])
        XCTAssertEqual(MetaResponses.labels(#"[{"id":1,"name":"Bold"}]"#, ids: [1])[1]?.name, "Bold")
        // Hostile or sloppy ids never crash and never round onto a real candidate.
        XCTAssertEqual(MetaResponses.labels(#"[{"id":1e100,"name":"A"},{"id":"NaN","name":"B"},{"id":1.7,"name":"C"},{"id":"inf","name":"D"}]"#, ids: [1, 2]), [:])
    }

    func testHTTPErrorIsReportedWithTheKeyScrubbed() async {
        let key = "meta-secret-key-0123456789"
        let t = StubTransport([MetaHTTPResponse(status: 401, body: Data(#"{"error":{"message":"bad key meta-secret-key-0123456789"}}"#.utf8))])
        let client = MetaClient(apiKey: key, transport: t)
        do { _ = try await client.segment(png: png, imageSize: size, concept: "button"); XCTFail("must throw") }
        catch {
            guard case let .http(code, message)? = error as? MetaError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 401)
            XCTAssertFalse(message.contains(key))
            XCTAssertFalse(error.localizedDescription.contains(key))
        }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testAKeyCrossingTheCutIsScrubbedWhole() async {
        let key = "meta-boundary-key-ABCDEFGHIJKLMNOP"
        let message = String(repeating: "x", count: 190) + " " + key
        let t = StubTransport([MetaHTTPResponse(status: 400, body: try! JSONSerialization.data(withJSONObject: ["error": ["message": message]]))])
        let client = MetaClient(apiKey: key, transport: t)
        do { _ = try await client.segment(png: png, imageSize: size, concept: "button"); XCTFail("must throw") }
        catch {
            guard case let .http(_, m)? = error as? MetaError else { return XCTFail("\(error)") }
            XCTAssertFalse(m.contains("meta-boundary"), m)
            XCTAssertLessThanOrEqual(m.count, 200)
        }
    }

    func testClientRoundTripThroughTheStub() async throws {
        let t = StubTransport([body(#"{"output":[{"type":"segmentation","detections":[{"box":[0,0,40,40],"score":0.9}]}]}"#),
                               body(#"{"output_text":"{\"labels\":[{\"id\":1,\"name\":\"Settings\"}]}"}"#)])
        let client = MetaClient(apiKey: "k-abcdefgh", transport: t)
        let regions = try await client.segment(png: png, imageSize: size, concept: "icon")
        XCTAssertEqual(regions.count, 1)
        let c = VisionCandidate(id: 1, pixelBox: regions[0].box, screenFrame: regions[0].box, concept: "icon", score: 0.9)
        let names = try await client.name(png: png, candidates: [c], request: nil)
        XCTAssertEqual(names[1]?.name, "Settings")
        XCTAssertEqual(t.requests.count, 2)
    }

    func testKeyComesFromTheEnvironmentOnly() {
        XCTAssertEqual(MetaKeySource.resolve(environment: ["MODEL_API_KEY": "env-key-123456"]), "env-key-123456")
        XCTAssertEqual(MetaKeySource.resolve(environment: ["META_API_KEY": "meta-env-1234"]), "meta-env-1234")
        XCTAssertNil(MetaKeySource.resolve(environment: ["MODEL_API_KEY": "  "]))
        XCTAssertNil(MetaKeySource.resolve(environment: [:]))
    }
}
