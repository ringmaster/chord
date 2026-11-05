import Foundation
import Testing
@testable import chord_logic

struct HistoryTests {
    let database: ChordDatabase
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    init() throws {
        database = try ChordDatabase.inMemory()
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    @Test func aFirstVisitAddsAnEntry() throws {
        try database.recordVisit(url: url("https://github.com/"), title: "GitHub", at: now)
        let results = try database.searchHistory("github", now: now)
        #expect(results.count == 1)
        #expect(results[0].visitCount == 1)
        #expect(results[0].title == "GitHub")
    }

    @Test func aRepeatVisitCountsUpAndKeepsOneRow() throws {
        try database.recordVisit(url: url("https://github.com/"), title: "GitHub", at: daysAgo(1))
        try database.recordVisit(url: url("https://github.com/"), title: "", at: now)
        let results = try database.searchHistory("github", now: now)
        #expect(results.count == 1)
        #expect(results[0].visitCount == 2)
        #expect(results[0].lastVisitedAt == now)
        // An empty title on a later visit keeps the earlier one.
        #expect(results[0].title == "GitHub")
    }

    @Test(arguments: ["about:blank", "file:///tmp/x.html", "chord://minor?url=x"])
    func nonWebAddressesAreNotRecorded(address: String) throws {
        try database.recordVisit(url: url(address), title: "x", at: now)
        #expect(try database.searchHistory("x", now: now).isEmpty)
    }

    @Test func aLaterTitleUpdatesTheEntry() throws {
        try database.recordVisit(url: url("https://example.com/"), title: "", at: now)
        try database.updateHistoryTitle(url: url("https://example.com/"), title: "Example Domain")
        #expect(try database.searchHistory("domain", now: now).first?.title == "Example Domain")
    }

    @Test func anEmptyTitleUpdateIsIgnored() throws {
        try database.recordVisit(url: url("https://example.com/"), title: "Example", at: now)
        try database.updateHistoryTitle(url: url("https://example.com/"), title: "")
        #expect(try database.searchHistory("example", now: now).first?.title == "Example")
    }

    @Test func searchMatchesWordPrefixesInTitleAndAddress() throws {
        try database.recordVisit(url: url("https://app.datadoghq.com/dashboard/abc"), title: "Service health", at: now)
        #expect(try database.searchHistory("datad", now: now).count == 1)
        #expect(try database.searchHistory("dash", now: now).count == 1)
        #expect(try database.searchHistory("serv heal", now: now).count == 1)
        #expect(try database.searchHistory("health datadog", now: now).count == 1)
        #expect(try database.searchHistory("ealth", now: now).isEmpty)
    }

    @Test func everyQueryWordMustMatch() throws {
        try database.recordVisit(url: url("https://example.com/"), title: "Example", at: now)
        #expect(try database.searchHistory("example missing", now: now).isEmpty)
    }

    @Test(arguments: ["", "   ", "\"", "*"])
    func emptyOrPunctuationQueriesGiveNothing(query: String) throws {
        try database.recordVisit(url: url("https://example.com/"), title: "Example", at: now)
        #expect(try database.searchHistory(query, now: now).isEmpty)
    }

    @Test func resultsAreLimited() throws {
        for index in 0..<20 {
            try database.recordVisit(url: url("https://example.com/\(index)"), title: "Page \(index)", at: now)
        }
        #expect(try database.searchHistory("page", limit: 5, now: now).count == 5)
    }

    @Test func clearHistoryRemovesEverything() throws {
        try database.recordVisit(url: url("https://example.com/"), title: "Example", at: now)
        try database.clearHistory()
        #expect(try database.searchHistory("example", now: now).isEmpty)
    }

    // MARK: Ranking

    @Test func frecencyGrowsWithVisits() {
        let few = HistoryRanking.frecency(visitCount: 1, lastVisitedAt: now, now: now)
        let many = HistoryRanking.frecency(visitCount: 50, lastVisitedAt: now, now: now)
        #expect(many > few)
    }

    @Test func frecencyShrinksWithAge() {
        let fresh = HistoryRanking.frecency(visitCount: 5, lastVisitedAt: now, now: now)
        let stale = HistoryRanking.frecency(visitCount: 5, lastVisitedAt: daysAgo(30), now: now)
        #expect(fresh > stale)
        #expect(stale > 0)
    }

    @Test func aFutureVisitTimeCountsAsNow() {
        let future = HistoryRanking.frecency(visitCount: 5, lastVisitedAt: now.addingTimeInterval(3600), now: now)
        let present = HistoryRanking.frecency(visitCount: 5, lastVisitedAt: now, now: now)
        #expect(future == present)
    }

    @Test func aHostThatStartsWithTheQueryRanksFirst() throws {
        try database.recordVisit(url: url("https://news.example/git-tips"), title: "Git tips", at: now)
        for _ in 0..<5 {
            try database.recordVisit(url: url("https://news.example/git-tips"), title: "Git tips", at: now)
        }
        try database.recordVisit(url: url("https://www.github.com/"), title: "GitHub", at: daysAgo(3))
        let results = try database.searchHistory("git", now: now)
        #expect(results.map { $0.url.host() } == ["www.github.com", "news.example"])
    }

    @Test func moreFrequentRecentPagesRankHigher() throws {
        try database.recordVisit(url: url("https://a.example/swift"), title: "Swift A", at: daysAgo(60))
        for _ in 0..<10 {
            try database.recordVisit(url: url("https://b.example/swift"), title: "Swift B", at: now)
        }
        #expect(try database.searchHistory("swift", now: now).first?.title == "Swift B")
    }
}
