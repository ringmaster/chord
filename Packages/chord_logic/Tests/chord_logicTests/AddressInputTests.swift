import Foundation
import Testing
@testable import chord_logic

struct AddressInputTests {
    let input = AddressInput()

    @Test(arguments: ["", "   ", "\n\t"])
    func emptyTextGivesNil(text: String) {
        #expect(input.url(for: text) == nil)
    }

    @Test(arguments: [
        "https://example.com/path?q=1",
        "http://example.com",
        "HTTPS://Example.com",
        "file:///Users/someone/page.html",
        "about:blank",
    ])
    func knownSchemeLoadsAsTyped(text: String) {
        #expect(input.url(for: text)?.absoluteString == text)
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(input.url(for: "  https://example.com  ")?.absoluteString == "https://example.com")
    }

    @Test(arguments: [
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost:3000/admin", "http://localhost:3000/admin"),
        ("LocalHost/x", "http://LocalHost/x"),
    ])
    func localhostLoadsOverHTTP(text: String, expected: String) {
        #expect(input.url(for: text)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("news.ycombinator.com/item?id=1", "https://news.ycombinator.com/item?id=1"),
        ("example.com:8443/x", "https://example.com:8443/x"),
    ])
    func dottedHostLoadsOverHTTPS(text: String, expected: String) {
        #expect(input.url(for: text)?.absoluteString == expected)
    }

    @Test(arguments: [
        "swift concurrency",
        "kagi",
        ".com",
        "example.",
        "what is example.com",
        "mailto:someone@example.com",
    ])
    func otherTextGoesToSearch(text: String) throws {
        let url = try #require(input.url(for: text))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "duckduckgo.com")
        #expect(components.queryItems == [URLQueryItem(name: "q", value: text)])
    }

    @Test func searchUsesTheGivenEngine() throws {
        let engine = SearchEngine(
            id: "test", name: "Test", baseURL: URL(string: "https://search.test/find")!, queryItemName: "term")
        let url = try #require(AddressInput(searchEngine: engine).url(for: "a & b"))
        #expect(url.absoluteString == "https://search.test/find?term=a%20%26%20b")
    }

    @Test(arguments: [
        ("example.com", "example.com"),
        ("example.com:80/path", "example.com"),
        ("host?q=1", "host"),
        ("host#frag", "host"),
        ("", ""),
    ])
    func hostPartStopsAtPathQueryFragmentAndPort(text: String, expected: String) {
        #expect(AddressInput.hostPart(of: text) == expected)
    }
}
