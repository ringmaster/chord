import Foundation

/// A bookmark from an external bookmark service.
public struct ServiceBookmark: Equatable, Sendable, Identifiable {
    public var id: String
    public var url: URL
    public var title: String

    public init(id: String, url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

public enum BookmarkServiceError: Error, Equatable {
    /// The server address or API key is missing.
    case notConfigured
    /// The server refused the API key (HTTP 401 or 403).
    case unauthorized
    /// The server answered with another error status.
    case server(status: Int, message: String)
    /// The request did not reach the server, or no answer came back.
    case network(String)
    /// The answer was not in the expected shape.
    case unreadableResponse
}

/// The contract Chord needs from a bookmark service. Only the module that
/// implements it changes when the service changes.
///
/// - Every method throws `BookmarkServiceError` and nothing else.
/// - No method retries. A caller that wants a retry calls again.
/// - Methods are safe to call from any task.
public protocol BookmarkService: Sendable {
    /// Checks that the server is reachable and accepts the key.
    func verify() async throws
    /// Saves a link and returns the saved bookmark. Saving a link that is
    /// already saved returns the existing bookmark.
    func save(url: URL, title: String?) async throws -> ServiceBookmark
    /// Bookmarks that match `query`, best first, at most `limit`.
    func search(_ query: String, limit: Int) async throws -> [ServiceBookmark]
    /// The id of the bookmark for `url`, or nil when it is not saved.
    func bookmarkID(for url: URL) async throws -> String?
}

/// Sends HTTP requests. URLSession in the app; a test double in tests.
///
/// Contract: returns the body and the HTTP response for any status code, and
/// throws only when no response arrived.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The Karakeep bookmark service, through its REST API at `{server}/api/v1`.
/// See https://docs.karakeep.com/api/karakeep-api.
public struct KarakeepService: BookmarkService {
    public let server: URL
    let apiKey: String
    let transport: any HTTPTransport

    public init(server: URL, apiKey: String, transport: any HTTPTransport = URLSession.shared) {
        self.server = server
        self.apiKey = apiKey
        self.transport = transport
    }

    public func verify() async throws {
        _ = try await get(path: "bookmarks", query: [URLQueryItem(name: "limit", value: "1")])
    }

    public func save(url: URL, title: String?) async throws -> ServiceBookmark {
        var body: [String: String] = ["type": "link", "url": url.absoluteString, "source": "api"]
        if let title, !title.isEmpty { body["title"] = title }
        var request = makeRequest(path: "bookmarks", query: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        let data = try await perform(request)
        guard let bookmark = try? JSONDecoder().decode(KarakeepBookmark.self, from: data).serviceBookmark else {
            throw BookmarkServiceError.unreadableResponse
        }
        return bookmark
    }

    public func search(_ query: String, limit: Int) async throws -> [ServiceBookmark] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = try await get(path: "bookmarks/search", query: [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        guard let page = try? JSONDecoder().decode(KarakeepPage.self, from: data) else {
            throw BookmarkServiceError.unreadableResponse
        }
        // Text notes and uploaded files have no link, so they are left out.
        return page.bookmarks.compactMap(\.serviceBookmark)
    }

    public func bookmarkID(for url: URL) async throws -> String? {
        let data = try await get(path: "bookmarks/check-url", query: [URLQueryItem(name: "url", value: url.absoluteString)])
        guard let answer = try? JSONDecoder().decode(KarakeepCheck.self, from: data) else {
            throw BookmarkServiceError.unreadableResponse
        }
        return answer.bookmarkId
    }

    // MARK: Requests

    func makeRequest(path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: server.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        try await perform(makeRequest(path: path, query: query))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        guard !apiKey.isEmpty else { throw BookmarkServiceError.notConfigured }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw BookmarkServiceError.network(error.localizedDescription)
        }
        switch response.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw BookmarkServiceError.unauthorized
        default:
            let message = String(decoding: data.prefix(300), as: UTF8.self)
            throw BookmarkServiceError.server(status: response.statusCode, message: message)
        }
    }
}

// MARK: Karakeep response shapes

private struct KarakeepPage: Decodable {
    var bookmarks: [KarakeepBookmark]
}

private struct KarakeepCheck: Decodable {
    var bookmarkId: String?
}

private struct KarakeepBookmark: Decodable {
    struct Content: Decodable {
        var type: String
        var url: String?
        var title: String?
    }

    var id: String
    var title: String?
    var content: Content

    /// The bookmark as Chord sees it, or nil when it is not a link.
    var serviceBookmark: ServiceBookmark? {
        guard content.type == "link", let string = content.url, let url = URL(string: string) else { return nil }
        let name = [title, content.title].compactMap { $0 }.first { !$0.isEmpty } ?? (url.host() ?? string)
        return ServiceBookmark(id: id, url: url, title: name)
    }
}
