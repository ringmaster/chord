import Foundation
import Testing
@testable import chord_logic

/// A stand-in for the network. It records each request and answers with a
/// fixed status and body, or throws `failure` to act as a lost connection.
///
/// Contract, matching `HTTPTransport`: it returns a response for any status
/// and throws only when no response "arrived".
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let status: Int
    let body: String
    let failure: URLError?

    init(status: Int = 200, body: String = "{}", failure: URLError? = nil) {
        self.status = status
        self.body = body
        self.failure = failure
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        if let failure { throw failure }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

struct KarakeepServiceTests {
    let server = URL(string: "https://keep.example.com")!

    private func service(_ transport: StubTransport, key: String = "secret") -> KarakeepService {
        KarakeepService(server: server, apiKey: key, transport: transport)
    }

    private let linkBookmark = """
        {"id":"b1","title":null,"content":{"type":"link","url":"https://swift.org/","title":"Swift.org"}}
        """

    // Security and authorization first.

    @Test func everyRequestCarriesTheBearerKey() async throws {
        let transport = StubTransport(body: #"{"bookmarks":[],"nextCursor":null}"#)
        _ = try await service(transport).search("swift", limit: 5)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test(arguments: [401, 403])
    func refusedKeysAreUnauthorized(status: Int) async {
        let transport = StubTransport(status: status, body: #"{"error":"no"}"#)
        await #expect(throws: BookmarkServiceError.unauthorized) {
            try await service(transport).verify()
        }
    }

    @Test func anEmptyKeyIsNotConfiguredAndSendsNothing() async {
        let transport = StubTransport()
        await #expect(throws: BookmarkServiceError.notConfigured) {
            try await service(transport, key: "").verify()
        }
        #expect(transport.requests.isEmpty)
    }

    // Requests and answers.

    @Test func verifyListsOneBookmark() async throws {
        let transport = StubTransport(body: #"{"bookmarks":[],"nextCursor":null}"#)
        try await service(transport).verify()
        #expect(transport.requests.first?.url?.absoluteString == "https://keep.example.com/api/v1/bookmarks?limit=1")
    }

    @Test func saveSendsALinkBookmark() async throws {
        let transport = StubTransport(status: 201, body: linkBookmark)
        let saved = try await service(transport).save(url: URL(string: "https://swift.org/")!, title: "Swift")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://keep.example.com/api/v1/bookmarks")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body == ["type": "link", "url": "https://swift.org/", "title": "Swift", "source": "api"])
        #expect(saved == ServiceBookmark(id: "b1", url: URL(string: "https://swift.org/")!, title: "Swift.org"))
    }

    @Test func saveLeavesOutAnEmptyTitle() async throws {
        let transport = StubTransport(body: linkBookmark)
        _ = try await service(transport).save(url: URL(string: "https://swift.org/")!, title: "")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(transport.requests.first?.httpBody))
        #expect(body["title"] == nil)
    }

    @Test func searchKeepsOnlyLinksAndPrefersTheBookmarkTitle() async throws {
        let transport = StubTransport(body: """
            {"bookmarks":[
              {"id":"a","title":"My title","content":{"type":"link","url":"https://a.example/","title":"Page"}},
              {"id":"b","title":null,"content":{"type":"text","text":"a note"}},
              {"id":"c","title":"","content":{"type":"link","url":"https://c.example/","title":null}}
            ],"nextCursor":null}
            """)
        let results = try await service(transport).search(" swift testing ", limit: 7)
        #expect(results.map(\.id) == ["a", "c"])
        #expect(results.map(\.title) == ["My title", "c.example"])
        let url = try #require(transport.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(url.path() == "/api/v1/bookmarks/search")
        #expect(items == [URLQueryItem(name: "q", value: "swift testing"), URLQueryItem(name: "limit", value: "7")])
    }

    @Test func anEmptySearchSendsNothing() async throws {
        let transport = StubTransport()
        #expect(try await service(transport).search("  ", limit: 5).isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func bookmarkIDChecksTheURL() async throws {
        let found = StubTransport(body: #"{"bookmarkId":"b9"}"#)
        #expect(try await service(found).bookmarkID(for: URL(string: "https://swift.org/?a=1&b=2")!) == "b9")
        let items = URLComponents(url: try #require(found.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "url", value: "https://swift.org/?a=1&b=2")])

        let missing = StubTransport(body: #"{"bookmarkId":null}"#)
        #expect(try await service(missing).bookmarkID(for: URL(string: "https://x.example")!) == nil)
    }

    // Error paths.

    @Test func otherStatusesCarryTheMessage() async {
        let transport = StubTransport(status: 500, body: "boom")
        await #expect(throws: BookmarkServiceError.server(status: 500, message: "boom")) {
            try await service(transport).verify()
        }
    }

    @Test func aLostConnectionIsANetworkError() async {
        let transport = StubTransport(failure: URLError(.notConnectedToInternet))
        await #expect {
            try await service(transport).verify()
        } throws: { error in
            if case BookmarkServiceError.network = error { return true }
            return false
        }
    }

    @Test func unexpectedShapesAreUnreadable() async {
        await #expect(throws: BookmarkServiceError.unreadableResponse) {
            try await service(StubTransport(body: "[]")).search("x", limit: 1)
        }
        await #expect(throws: BookmarkServiceError.unreadableResponse) {
            try await service(StubTransport(body: #"{"id":"t","content":{"type":"text"}}"#))
                .save(url: URL(string: "https://x.example")!, title: nil)
        }
        await #expect(throws: BookmarkServiceError.unreadableResponse) {
            try await service(StubTransport(body: "nope")).bookmarkID(for: URL(string: "https://x.example")!)
        }
    }

    @Test func aServerAddressWithAPathKeepsIt() {
        let nested = KarakeepService(server: URL(string: "https://example.com/keep")!, apiKey: "k",
                                     transport: StubTransport())
        let request = nested.makeRequest(path: "bookmarks", query: [])
        #expect(request.url?.absoluteString == "https://example.com/keep/api/v1/bookmarks")
    }
}
