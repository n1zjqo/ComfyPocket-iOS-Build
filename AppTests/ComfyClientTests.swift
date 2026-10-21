import XCTest
import Security
import ComfyCore
@testable import ComfyPocket

final class ComfyClientTests: XCTestCase {
    private func client() throws -> ComfyClient {
        var server = ServerProfile()
        server.address = "https://comfy.example.test/proxy"
        server.username = "ray"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try ComfyClient(server: server, configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testKeychainRoundTrip() throws {
        let identity = UUID()
        defer {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.ray.comfypocket.server", kSecAttrAccount as String: identity.uuidString]
            SecItemDelete(query as CFDictionary)
        }
        XCTAssertEqual(try PasswordStore.read(id: identity), "")
        try PasswordStore.save("test-only-secret", id: identity)
        XCTAssertEqual(try PasswordStore.read(id: identity), "test-only-secret")
    }

    func testEmptyQueueCommandSucceeds() async throws {
        let api = try client()
        defer { api.close() }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/proxy/queue")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200, Data())
        }
        try await api.command("queue", body: .object(["delete": .array([.string("prompt")])]))
    }

    func testEmptyInterruptCommandSucceeds() async throws {
        let api = try client()
        defer { api.close() }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/proxy/interrupt")
            return (200, Data())
        }
        try await api.command("interrupt", body: .object(["prompt_id": .string("prompt")]))
    }

    func testEmptyJSONResponseIsStillRejected() async throws {
        let api = try client()
        defer { api.close() }
        StubURLProtocol.handler = { _ in (200, Data()) }
        do {
            _ = try await api.json("queue")
            XCTFail("A JSON endpoint must not silently accept an empty body")
        } catch is DecodingError {
        }
    }

    func testHTTPErrorIsStillRejectedForCommand() async throws {
        let api = try client()
        defer { api.close() }
        StubURLProtocol.handler = { _ in (500, Data(#"{"error":"queue unavailable"}"#.utf8)) }
        do {
            try await api.command("queue", body: .object([:]))
            XCTFail("A failed command must not report success")
        } catch ComfyError.server(let status, let message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "queue unavailable")
        }
    }

    func testProxyPrefixQueryAndAuthentication() async throws {
        let api = try client()
        defer { api.close() }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/proxy/history")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "猫 & sky#")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("ray:".utf8).base64EncodedString())
            return (200, Data(#"{"queue_pending":[]}"#.utf8))
        }
        let value = try await api.json("history", query: [URLQueryItem(name: "filename", value: "猫 & sky#")])
        XCTAssertEqual(value["queue_pending"], .array([]))
    }

    func testCrossOriginRedirectIsRejected() throws {
        let api = try client()
        defer { api.close() }
        let destination = URLRequest(url: URL(string: "https://untrusted.example.test/file")!)
        let response = HTTPURLResponse(url: api.base, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = URLSession.shared.dataTask(with: api.base)
        defer { task.cancel() }
        var called = false
        api.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: destination) { redirect in
            called = true
            XCTAssertNil(redirect)
        }
        XCTAssertTrue(called)
    }

    func testSameOriginRedirectRetainsAuthentication() throws {
        let api = try client()
        defer { api.close() }
        let destination = URLRequest(url: URL(string: "https://comfy.example.test/proxy/file")!)
        let response = HTTPURLResponse(url: api.base, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = URLSession.shared.dataTask(with: api.base)
        defer { task.cancel() }
        var called = false
        api.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: destination) { redirect in
            called = true
            XCTAssertEqual(redirect?.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("ray:".utf8).base64EncodedString())
        }
        XCTAssertTrue(called)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
