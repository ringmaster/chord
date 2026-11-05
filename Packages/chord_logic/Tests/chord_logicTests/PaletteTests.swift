import Foundation
import Testing
@testable import chord_logic

struct FuzzyMatchTests {
    @Test func noMatchGivesNil() {
        #expect(FuzzyMatch.score("xyz", in: "GitHub") == nil)
    }

    @Test(arguments: [("", "GitHub"), ("git", ""), ("   ", "GitHub")])
    func emptyTextGivesNil(query: String, candidate: String) {
        #expect(FuzzyMatch.score(query, in: candidate) == nil)
    }

    @Test func tiersAreOrdered() throws {
        let prefix = try #require(FuzzyMatch.score("hub", in: "hub page"))
        let wordPrefix = try #require(FuzzyMatch.score("hub", in: "my hub page"))
        let contains = try #require(FuzzyMatch.score("hub", in: "github"))
        let subsequence = try #require(FuzzyMatch.score("hub", in: "h-u-b"))
        #expect(prefix > wordPrefix)
        #expect(wordPrefix > contains)
        #expect(contains > subsequence)
    }

    @Test func matchingIgnoresCase() {
        #expect(FuzzyMatch.score("GIT", in: "github") != nil)
    }

    @Test func aShorterCandidateWinsWithinATier() throws {
        let short = try #require(FuzzyMatch.score("git", in: "git"))
        let long = try #require(FuzzyMatch.score("git", in: "git and more"))
        #expect(short > long)
    }

    @Test func bestScoreTakesTheHighest() throws {
        let best = try #require(FuzzyMatch.bestScore("hub", in: ["github", "hub"]))
        #expect(best == FuzzyMatch.score("hub", in: "hub"))
        #expect(FuzzyMatch.bestScore("zzz", in: ["github", "hub"]) == nil)
    }
}

struct AddressResolutionTests {
    let input = AddressInput()

    @Test func addressesResolveAsAddresses() {
        #expect(input.resolve("example.com") == .address(URL(string: "https://example.com")!))
    }

    @Test func wordsResolveAsSearches() throws {
        let resolution = try #require(input.resolve("swift testing"))
        guard case .search(let url) = resolution else {
            Issue.record("Expected a search, got \(resolution)")
            return
        }
        #expect(url.host() == "duckduckgo.com")
    }

    @Test func emptyTextResolvesToNil() {
        #expect(input.resolve("  ") == nil)
    }
}

struct PaletteResultsTests {
    let profile = UUID()
    let space = UUID()
    let engine = SearchEngine.duckDuckGo

    private func tab(_ url: String, _ title: String, activated: TimeInterval? = nil) -> BrowserTab {
        BrowserTab(profileID: profile, spaceID: space, section: .open, position: 0,
                   url: URL(string: url)!, title: title,
                   lastActivatedAt: activated.map(Date.init(timeIntervalSince1970:)))
    }

    private func entry(_ url: String, _ title: String) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: title, visitCount: 1,
                     lastVisitedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    private let toggle = PaletteCommand(id: "toggle-sidebar", title: "Toggle Sidebar", symbol: "layout-sidebar")
    private let reload = PaletteCommand(id: "reload", title: "Reload Page", symbol: "reload",
                                        keywords: ["refresh"])

    @Test func emptyQueryShowsRecentTabsThenCommands() {
        let old = tab("https://a.example", "A", activated: 1)
        let new = tab("https://b.example", "B", activated: 2)
        let items = PaletteResults.build(query: " ", tabs: [old, new], commands: [toggle],
                                         history: [], engine: engine)
        #expect(items == [.tab(new), .tab(old), .command(toggle)])
    }

    @Test func emptyQueryLimitsTabsAndCommands() {
        let tabs = (0..<10).map { tab("https://\($0).example", "\($0)", activated: Double($0)) }
        let commands = (0..<10).map { PaletteCommand(id: "\($0)", title: "Command \($0)", symbol: "circle") }
        let items = PaletteResults.build(query: "", tabs: tabs, commands: commands, history: [], engine: engine)
        #expect(items.count == PaletteResults.maximumTabs + PaletteResults.maximumCommands)
    }

    @Test func anAddressComesFirst() {
        let items = PaletteResults.build(query: "example.com", tabs: [], commands: [], history: [], engine: engine)
        #expect(items.first == .navigate(URL(string: "https://example.com")!))
    }

    @Test func wordsSearchFirst() {
        let items = PaletteResults.build(query: "swift", tabs: [], commands: [], history: [], engine: engine)
        guard case .search(let query, let usedEngine, let url) = items.first else {
            Issue.record("Expected a search row first")
            return
        }
        #expect(query == "swift")
        #expect(usedEngine == engine)
        #expect(url == engine.searchURL(for: "swift"))
    }

    @Test func matchingTabsComeBeforeCommandsAndHistory() {
        let github = tab("https://github.com", "GitHub")
        let items = PaletteResults.build(
            query: "git", tabs: [github, tab("https://news.example", "News")],
            commands: [PaletteCommand(id: "x", title: "Open digit tool", symbol: "circle")],
            history: [entry("https://gitlab.com", "GitLab")], engine: engine)
        #expect(items.count == 4)
        #expect(items[1] == .tab(github))
        #expect(items[2] == .command(PaletteCommand(id: "x", title: "Open digit tool", symbol: "circle")))
        #expect(items[3] == .history(entry("https://gitlab.com", "GitLab")))
    }

    @Test func aCommandTitlePrefixPutsCommandsBeforeTabs() {
        let toggleTab = tab("https://toggl.com", "Toggl Track")
        let items = PaletteResults.build(query: "tog", tabs: [toggleTab], commands: [toggle],
                                         history: [], engine: engine)
        #expect(items.dropFirst().first == .command(toggle))
        #expect(items.dropFirst(2).first == .tab(toggleTab))
    }

    @Test func commandKeywordsMatch() {
        let items = PaletteResults.build(query: "refresh", tabs: [], commands: [reload, toggle],
                                         history: [], engine: engine)
        #expect(items.contains(.command(reload)))
        #expect(!items.contains(.command(toggle)))
    }

    @Test func historyAlreadyOpenInATabIsLeftOut() {
        let open = tab("https://github.com", "GitHub")
        let items = PaletteResults.build(
            query: "github", tabs: [open], commands: [],
            history: [entry("https://github.com", "GitHub"), entry("https://github.com/x", "X")],
            engine: engine)
        #expect(!items.contains(.history(entry("https://github.com", "GitHub"))))
        #expect(items.contains(.history(entry("https://github.com/x", "X"))))
    }

    @Test func historyIsLimited() {
        let history = (0..<20).map { entry("https://h.example/\($0)", "Page \($0)") }
        let items = PaletteResults.build(query: "page", tabs: [], commands: [], history: history, engine: engine)
        let historyCount = items.filter { if case .history = $0 { true } else { false } }.count
        #expect(historyCount == PaletteResults.maximumHistory)
    }

    @Test func bookmarksComeLastWithoutPagesAlreadyListed() {
        let open = tab("https://github.com", "GitHub")
        let visited = entry("https://github.com/x", "X")
        let bookmarks = [
            ServiceBookmark(id: "1", url: URL(string: "https://github.com")!, title: "Open already"),
            ServiceBookmark(id: "2", url: URL(string: "https://github.com/x")!, title: "In history"),
            ServiceBookmark(id: "3", url: URL(string: "https://github.blog")!, title: "New"),
        ]
        let items = PaletteResults.build(query: "github", tabs: [open], commands: [], history: [visited],
                                         bookmarks: bookmarks, engine: engine)
        #expect(items.last == .bookmark(bookmarks[2]))
        #expect(items.filter { if case .bookmark = $0 { true } else { false } }.count == 1)
    }

    @Test func bookmarksAreLimited() {
        let bookmarks = (0..<10).map { ServiceBookmark(id: "\($0)", url: URL(string: "https://b\($0).example")!, title: "B") }
        let items = PaletteResults.build(query: "b", tabs: [], commands: [], history: [], bookmarks: bookmarks,
                                         engine: engine)
        #expect(items.filter { if case .bookmark = $0 { true } else { false } }.count == PaletteResults.maximumBookmarks)
    }
}
