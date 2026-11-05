import Foundation

/// The search engine that receives text that is not an address.
public struct SearchEngine: Equatable, Sendable, Identifiable {
    /// A stable id that the settings store.
    public let id: String
    public let name: String
    /// The query is appended to this URL as the value of `queryItemName`.
    public let baseURL: URL
    public let queryItemName: String

    public init(id: String, name: String, baseURL: URL, queryItemName: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.queryItemName = queryItemName
    }

    public static let duckDuckGo = SearchEngine(
        id: "duckduckgo", name: "DuckDuckGo",
        baseURL: URL(string: "https://duckduckgo.com/")!, queryItemName: "q")

    /// The engines the user can choose from. The first one is the default.
    public static let presets: [SearchEngine] = [
        .duckDuckGo,
        SearchEngine(id: "kagi", name: "Kagi",
                     baseURL: URL(string: "https://kagi.com/search")!, queryItemName: "q"),
        SearchEngine(id: "startpage", name: "Startpage",
                     baseURL: URL(string: "https://www.startpage.com/do/search")!, queryItemName: "q"),
        SearchEngine(id: "google", name: "Google",
                     baseURL: URL(string: "https://www.google.com/search")!, queryItemName: "q"),
        SearchEngine(id: "bing", name: "Bing",
                     baseURL: URL(string: "https://www.bing.com/search")!, queryItemName: "q"),
    ]

    /// The search results page for `query`.
    public func searchURL(for query: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: queryItemName, value: query)]
        return components.url!
    }
}

/// Turns what the user typed into the URL to load.
///
/// The rules, in order:
/// 1. Empty or whitespace-only text gives nil.
/// 2. Text with a known scheme loads as typed.
/// 3. `localhost`, with or without a port or path, loads over http.
/// 4. Text with no spaces and a dot in the host part loads over https.
/// 5. Anything else goes to the search engine.
public struct AddressInput: Sendable {
    public static let knownSchemes: Set<String> = ["http", "https", "file", "about"]

    public let searchEngine: SearchEngine

    public init(searchEngine: SearchEngine = .duckDuckGo) {
        self.searchEngine = searchEngine
    }

    public func url(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           AddressInput.knownSchemes.contains(scheme) {
            return url
        }

        if !trimmed.contains(where: \.isWhitespace) {
            let host = AddressInput.hostPart(of: trimmed)
            if host.lowercased() == "localhost" {
                return URL(string: "http://" + trimmed)
            }
            if host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
               let url = URL(string: "https://" + trimmed), url.host != nil {
                return url
            }
        }

        return searchEngine.searchURL(for: trimmed)
    }

    /// The text before the first `/`, `?`, or `#`, without a port.
    static func hostPart(of text: String) -> String {
        let end = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        let hostAndPort = text[..<end]
        let host = hostAndPort.split(separator: ":", maxSplits: 1).first ?? ""
        return String(host)
    }
}
