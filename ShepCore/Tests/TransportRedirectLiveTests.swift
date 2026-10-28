import Darwin
import Foundation
import XCTest
@testable import ShepCore

/// A tiny HTTP/1.1 server bound to 127.0.0.1 on an ephemeral port (BSD sockets). It reads one request per connection
/// (headers and Content-Length body, with timeouts everywhere), answers `redirectStatus` with a Location header, or 200
/// when no redirect is configured, and closes. It records what arrived. Nothing here can reach a non-loopback address.
final class TinyLoopbackServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let redirectStatus: Int?
    private let location: String
    private let lock = NSLock()
    private var stopRequested = false
    private var started = false
    private var accepted = 0
    private var bytes = 0
    private var lastRequest = Data()
    private let finished = DispatchSemaphore(value: 0)

    init(redirectStatus: Int? = nil, location: String = "") {
        self.redirectStatus = redirectStatus; self.location = location
    }

    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return accepted }
    var bytesReceived: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var requestText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: lastRequest, as: UTF8.self) }

    /// Binds and starts listening; returns false if any step failed.
    func start() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return false }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); return false }
        port = UInt16(bigEndian: actual.sin_port)
        started = true
        DispatchQueue.global().async { self.acceptLoop(fd) }
        return true
    }

    /// Stops the accept loop (it closes the listening socket itself) and waits at most 2 s for it.
    func stop() {
        lock.lock(); stopRequested = true; lock.unlock()
        if started { _ = finished.wait(timeout: .now() + 2) }
    }

    private func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }

    private func acceptLoop(_ fd: Int32) {
        while !shouldStop() {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)   // wakes every 100 ms to look at the stop flag
            if ready <= 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            lock.lock(); accepted += 1; lock.unlock()
            serve(client)
            close(client)
        }
        close(fd)
        finished.signal()
    }

    private func serve(_ client: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(2)
        let marker = Data("\r\n\r\n".utf8)
        while Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, 4096, 0) }
            if n <= 0 { break }
            request.append(contentsOf: buffer[0..<n])
            if let end = request.range(of: marker) {
                let head = String(decoding: request[request.startIndex..<end.lowerBound], as: UTF8.self).lowercased()
                var wanted = 0
                for line in head.components(separatedBy: "\r\n") where line.hasPrefix("content-length:") {
                    wanted = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
                if request.endIndex - end.upperBound >= wanted { break }
            }
        }
        lock.lock(); bytes += request.count; lastRequest = request; lock.unlock()

        let reply: String
        if let status = redirectStatus {
            reply = "HTTP/1.1 \(status) Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        } else {
            reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        }
        let out = Array(reply.utf8)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { send(client, $0.baseAddress! + sent, out.count - sent, 0) }
            if n <= 0 { break }
            sent += n
        }
    }
}

/// The real URLSessionMetaTransport against two loopback servers: A redirects to B; B must never be contacted.
final class TransportRedirectLiveTests: XCTestCase {
    private var servers: [TinyLoopbackServer] = []

    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        super.tearDown()
    }

    private func makeServer(redirectStatus: Int? = nil, location: String = "") throws -> TinyLoopbackServer {
        let server = TinyLoopbackServer(redirectStatus: redirectStatus, location: location)
        servers.append(server)
        guard server.start() else { throw XCTSkip("could not bind a loopback socket") }
        return server
    }

    private func assertRedirectRefused(status: Int, headers: [String: String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let b = try makeServer()
        let a = try makeServer(redirectStatus: status, location: "http://127.0.0.1:\(b.port)/steal")
        let body = Data("screenshot-bytes-0123456789".utf8)
        let request = MetaHTTPRequest(url: URL(string: "http://127.0.0.1:\(a.port)/v1/chat/completions")!, method: "POST",
                                      headers: headers, body: body, timeout: 5, localOnly: true)
        let response = try await URLSessionMetaTransport().send(request)
        XCTAssertEqual(response.status, status, "the \(status) is returned as it is, not followed", file: file, line: line)
        XCTAssertEqual(a.connectionCount, 1, "the request did reach server A", file: file, line: line)
        XCTAssertTrue(a.requestText.contains("screenshot-bytes-0123456789"), "server A received the body", file: file, line: line)
        if headers["Authorization"] != nil {
            XCTAssertTrue(a.requestText.contains("Bearer test-key"), "server A received the header", file: file, line: line)
        }
        try await Task.sleep(nanoseconds: 500_000_000)   // grace period for a redirect that would follow late
        XCTAssertEqual(b.connectionCount, 0, "server B must not receive a connection", file: file, line: line)
        XCTAssertEqual(b.bytesReceived, 0, "server B must not receive a body or a header", file: file, line: line)
    }

    func testA307WithABodyIsReturnedAndNotFollowed() async throws {
        try await assertRedirectRefused(status: 307, headers: ["Content-Type": "application/json"])
    }

    func testA308WithABodyIsReturnedAndNotFollowed() async throws {
        try await assertRedirectRefused(status: 308, headers: ["Content-Type": "application/json"])
    }

    func testAnAuthorizationHeaderIsNotForwardedByARedirect() async throws {
        try await assertRedirectRefused(status: 307, headers: ["Authorization": "Bearer test-key"])
        try await assertRedirectRefused(status: 308, headers: ["Authorization": "Bearer test-key"])
    }

    func testTheTinyServerAnswersAPlainRequest() async throws {
        let server = try makeServer()
        let request = MetaHTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/ping")!, method: "POST", headers: [:],
                                      body: Data([1, 2, 3]), timeout: 5, localOnly: true)
        let response = try await URLSessionMetaTransport().send(request)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(server.connectionCount, 1)
    }
}
