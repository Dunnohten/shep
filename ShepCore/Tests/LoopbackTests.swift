import XCTest
@testable import ShepCore

final class LoopbackURLTests: XCTestCase {
    func url(_ s: String) -> URL { URL(string: s)! }

    func testLoopbackHostsAreAccepted() {
        for s in ["http://127.0.0.1:8080/v1", "http://localhost:8765", "http://[::1]:8080/v1", "https://127.0.0.1/x", "http://LOCALHOST:9/"] {
            XCTAssertTrue(LoopbackURL.isLoopback(url(s)), s)
        }
    }

    func testOtherHostsSchemesAndDisguisedAddressesAreRefused() {
        for s in ["http://example.com:8080/v1", "http://127.0.0.1.example.com/v1", "http://localhost.example.com/", "http://192.168.1.5:8080",
                  "http://0.0.0.0:8080", "http://[::2]/", "ftp://127.0.0.1/", "file:///tmp/x", "http://user@127.0.0.1:8080/v1",
                  "http://127.0.0.1:pw@example.com/", "http://127.0.0.1@example.com/", "127.0.0.1:8080"] {
            if let u = URL(string: s) { XCTAssertFalse(LoopbackURL.isLoopback(u), s) }
        }
    }

    func testEveryLocalConfigPinsLoopback() {
        XCTAssertThrowsError(try GlimmerConfig(baseURL: url("http://example.com:8080/v1")).validate())
        XCTAssertThrowsError(try GlimmerConfig(baseURL: url("http://127.0.0.1@example.com:8080/v1")).validate())
        XCTAssertThrowsError(try DetectorConfig(baseURL: url("http://10.0.0.2:8765")).validate())
        XCTAssertThrowsError(try DetectorConfig(baseURL: url("ftp://127.0.0.1:8765")).validate())
        XCTAssertNoThrow(try GlimmerConfig(baseURL: url("http://[::1]:8080/v1")).validate())
        XCTAssertNoThrow(try DetectorConfig(baseURL: url("http://localhost:8765")).validate())
    }

    func testSettingsFieldRejectsARemoteAddress() {
        XCTAssertNotNil(ShepSettings.glimmerURLIssue("http://example.com:8080/v1"))
        XCTAssertNil(ShepSettings.glimmerURLIssue("http://127.0.0.1:8080/v1"))
    }

    func testLocalRequestBuildersAreMarkedLocalOnly() throws {
        let detect = try DetectorRequests.detect(png: Data([1, 2, 3]), config: DetectorConfig())
        XCTAssertTrue(detect.localOnly)
        XCTAssertTrue(GlimmerPing.request(baseURL: url("http://127.0.0.1:8080/v1")).localOnly)
    }

    func testTheCloudRequestIsNotMarkedLocal() throws {
        let r = try MetaRequests.segment(png: Data([1]), concept: "button", key: "k", config: MetaConfig())
        XCTAssertFalse(r.localOnly)
    }
}

final class TransportRedirectTests: XCTestCase {
    func testRedirectDelegateAnswersNilForEveryRedirect() {
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let from = URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
        for (status, target) in [(307, "http://example.com/steal"), (308, "https://evil.example/x"), (302, "http://127.0.0.1:9/ok"), (301, "http://localhost/x")] {
            let task = session.dataTask(with: from)
            let response = HTTPURLResponse(url: from, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            var answered = false
            var followed: URLRequest? = URLRequest(url: from)
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) { next in
                answered = true; followed = next
            }
            XCTAssertTrue(answered, "\(status)")
            XCTAssertNil(followed, "\(status) to \(target) must not be followed, not even to loopback")
        }
        session.invalidateAndCancel()
    }

    func testALocalOnlyRequestToARemoteHostFailsClosedBeforeAnythingIsSent() async {
        let request = MetaHTTPRequest(url: URL(string: "http://example.invalid/v1/chat/completions")!, method: "POST", headers: [:],
                                      body: Data([1]), timeout: 1, localOnly: true)
        do {
            _ = try await URLSessionMetaTransport().send(request)
            XCTFail("a local-only request to a remote host must throw")
        } catch let error as TransportError {
            XCTAssertEqual(error, .notLoopback("example.invalid"))
        } catch {
            XCTFail("expected TransportError.notLoopback, got \(error)")
        }
    }
}
