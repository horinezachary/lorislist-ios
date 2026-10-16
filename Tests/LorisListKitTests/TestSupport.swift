import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LorisListKit

/// A canned HTTP response.
struct MockResponse {
    var status: Int
    var body: Data = Data()
    var headers: [String: String] = [:]

    /// One of the responses captured from the real API code (Tests/.../Fixtures/<name>.json).
    static func fixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> MockResponse {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = object["status"] as? Int else {
            XCTFail("Missing or unreadable fixture \(name)", file: file, line: line)
            return MockResponse(status: 599)
        }
        var response = MockResponse(status: status)
        if let body = object["body"], let bodyData = try? JSONSerialization.data(withJSONObject: body) {
            response.body = bodyData
        }
        response.headers = (object["headers"] as? [String: String]) ?? [:]
        return response
    }

    static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> MockResponse {
        MockResponse(status: status, body: Data(text.utf8), headers: headers)
    }
}

/// Answers requests with whatever the handler says and remembers what was asked.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> MockResponse

    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { log } }

    func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path.hasSuffix(path) == true }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { log.append(request) }
        let response = try await handler(request)
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            throw APIError.unexpected
        }
        return (response.body, http)
    }
}

/// A counter that can be bumped from concurrent requests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Collects a value reported from a @Sendable callback.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = 0

    func raise() { lock.withLock { raised += 1 } }
    var times: Int { lock.withLock { raised } }
}

/// Lets a MockTransport handler reach the client it belongs to.
final class ClientBox: @unchecked Sendable {
    var client: APIClient?
}

extension URLRequest {
    /// The JSON body as a dictionary, for checking what the client sent.
    var jsonBody: [String: Any]? {
        guard let data = httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var bearer: String? {
        value(forHTTPHeaderField: "Authorization")
    }
}

enum Fixtures {
    static let base = URL(string: "https://lorislist.example/api/v1")!

    /// A client that is already signed in with the given tokens.
    static func client(
        access: String = "access-1",
        refresh: String = "refresh-1",
        signedIn: Bool = true,
        store: TokenStore? = nil,
        transport: MockTransport
    ) -> (APIClient, TokenStore) {
        let tokenStore = store ?? InMemoryTokenStore(signedIn ? StoredTokens(accessToken: access, refreshToken: refresh) : nil)
        let client = APIClient(baseURL: base, deviceName: "Test iPhone", tokenStore: tokenStore, transport: transport)
        return (client, tokenStore)
    }
}
