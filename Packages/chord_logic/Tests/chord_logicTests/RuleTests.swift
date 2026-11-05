import Foundation
import GRDB
import Testing
@testable import chord_logic

struct URLMatcherTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test(arguments: [
        ("https://github.com/x", true),
        ("https://www.github.com/x", true),
        ("https://GitHub.com", true),
        ("https://gist.github.com", false),
        ("https://github.company.com", false),
    ])
    func hostScopeMatchesOnlyThatHost(address: String, expected: Bool) {
        let matcher = URLMatcher(scope: .host, value: "github.com")
        #expect(matcher.matches(url(address)) == expected)
    }

    @Test(arguments: [
        ("https://datadoghq.com", true),
        ("https://app.datadoghq.com/dashboard", true),
        ("https://a.b.datadoghq.com", true),
        ("https://notdatadoghq.com", false),
        ("https://datadoghq.com.evil.example", false),
    ])
    func domainScopeMatchesTheDomainAndSubdomains(address: String, expected: Bool) {
        let matcher = URLMatcher(scope: .domain, value: "datadoghq.com")
        #expect(matcher.matches(url(address)) == expected)
    }

    @Test(arguments: [
        ("https://example.com/docs", true),
        ("https://example.com/docs/", true),
        ("https://example.com/docs/a/b", true),
        ("https://example.com/docsearch", false),
        ("https://example.com/", false),
    ])
    func pathPrefixStopsAtSlashBoundaries(address: String, expected: Bool) {
        let matcher = URLMatcher(scope: .host, value: "example.com", pathPrefix: "/docs")
        #expect(matcher.matches(url(address)) == expected)
    }

    @Test(arguments: ["docs", "/docs/", "/docs"])
    func pathPrefixAcceptsLooseSpelling(prefix: String) {
        let matcher = URLMatcher(scope: .host, value: "example.com", pathPrefix: prefix)
        #expect(matcher.matches(url("https://example.com/docs/x")))
    }

    @Test(arguments: ["", "/"])
    func anEmptyPathPrefixMatchesEveryPath(prefix: String) {
        let matcher = URLMatcher(scope: .host, value: "example.com", pathPrefix: prefix)
        #expect(matcher.matches(url("https://example.com/anything")))
    }

    @Test func patternScopeTestsTheWholeURLIgnoringCase() {
        let matcher = URLMatcher(scope: .pattern, value: "jira.*/browse/[A-Z]+-\\d+")
        #expect(matcher.matches(url("https://acme.atlassian.net/jira/browse/ABC-123")))
        #expect(matcher.matches(url("https://JIRA.acme.com/browse/abc-1")))
        #expect(!matcher.matches(url("https://acme.atlassian.net/wiki")))
    }

    @Test func anInvalidPatternMatchesNothing() {
        let matcher = URLMatcher(scope: .pattern, value: "([")
        #expect(!matcher.isValid)
        #expect(!matcher.matches(url("https://example.com/([")))
    }

    @Test func aURLWithNoHostDoesNotMatchAHostRule() {
        #expect(!URLMatcher(scope: .domain, value: "example.com").matches(url("about:blank")))
    }

    @Test(arguments: [
        (URLMatcher(scope: .host, value: "example.com"), true),
        (URLMatcher(scope: .host, value: "  "), false),
        (URLMatcher(scope: .domain, value: "exa mple.com"), false),
        (URLMatcher(scope: .domain, value: "example.com/x"), false),
        (URLMatcher(scope: .pattern, value: "a+"), true),
    ])
    func validity(matcher: URLMatcher, expected: Bool) {
        #expect(matcher.isValid == expected)
    }

    @Test func specificityOrdersHostAboveDomainAbovePattern() {
        let host = URLMatcher(scope: .host, value: "app.datadoghq.com").specificity
        let domain = URLMatcher(scope: .domain, value: "datadoghq.com").specificity
        let deeperDomain = URLMatcher(scope: .domain, value: "eu.datadoghq.com").specificity
        let pattern = URLMatcher(scope: .pattern, value: ".*").specificity
        let withPath = URLMatcher(scope: .domain, value: "datadoghq.com", pathPrefix: "/logs").specificity
        #expect(host > deeperDomain)
        #expect(deeperDomain > domain)
        #expect(domain > pattern)
        #expect(withPath > host)
    }
}

struct SuggestedMatcherTests {
    @Test(arguments: [
        ("https://app.datadoghq.com/x", "datadoghq.com"),
        ("https://datadoghq.com", "datadoghq.com"),
        ("https://www.github.com", "github.com"),
        ("https://news.bbc.co.uk/a", "bbc.co.uk"),
        ("https://a.b.example.io", "example.io"),
        ("http://localhost:3000", "localhost"),
    ])
    func suggestsTheSiteDomain(address: String, expected: String) {
        let matcher = URLMatcher.suggested(for: URL(string: address)!)
        #expect(matcher == URLMatcher(scope: .domain, value: expected))
    }

    @Test func noHostGivesNil() {
        #expect(URLMatcher.suggested(for: URL(string: "about:blank")!) == nil)
    }
}

struct RuleEngineTests {
    let work = UUID()
    let personal = UUID()
    let workProfile = UUID()

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func rule(_ position: Int, _ matcher: URLMatcher, route: Route? = nil,
                      overtones: [String] = [], enabled: Bool = true) -> Rule {
        Rule(position: position, enabled: enabled, matcher: matcher,
             actions: RuleActions(route: route, overtones: overtones))
    }

    @Test func noRulesDecideNothing() {
        #expect(RuleEngine.decide(url("https://example.com"), rules: []) == .none)
    }

    @Test func theFirstMatchingRuleWithARouteWins() {
        let first = rule(0, URLMatcher(scope: .host, value: "app.datadoghq.com"), route: .minorChord(profileID: workProfile))
        let second = rule(1, URLMatcher(scope: .domain, value: "datadoghq.com"), route: .space(work))
        let decision = RuleEngine.decide(url("https://app.datadoghq.com/x"), rules: [second, first])
        #expect(decision.route == .minorChord(profileID: workProfile))
        #expect(decision.routeRuleID == first.id)
        #expect(decision.matchedRuleIDs == [first.id, second.id])
    }

    @Test func aMatchingRuleWithoutARouteLetsALaterRuleRoute() {
        let overtoneOnly = rule(0, URLMatcher(scope: .domain, value: "github.com"), overtones: ["wide"])
        let router = rule(1, URLMatcher(scope: .domain, value: "github.com"), route: .space(personal))
        let decision = RuleEngine.decide(url("https://github.com"), rules: [overtoneOnly, router])
        #expect(decision.route == .space(personal))
        #expect(decision.routeRuleID == router.id)
    }

    @Test func overtonesCollectFromEveryMatchWithoutRepeats() {
        let a = rule(0, URLMatcher(scope: .host, value: "github.com"), overtones: ["wide", "dark"])
        let b = rule(1, URLMatcher(scope: .domain, value: "github.com"), overtones: ["dark", "quiet"])
        let decision = RuleEngine.decide(url("https://github.com"), rules: [a, b])
        #expect(decision.overtones == ["wide", "dark", "quiet"])
    }

    @Test func disabledRulesAreSkipped() {
        let off = rule(0, URLMatcher(scope: .domain, value: "github.com"), route: .space(work), enabled: false)
        let decision = RuleEngine.decide(url("https://github.com"), rules: [off])
        #expect(decision == .none)
    }

    @Test func invalidRulesAreSkipped() {
        let broken = rule(0, URLMatcher(scope: .pattern, value: "(["), route: .space(work))
        #expect(RuleEngine.decide(url("https://github.com"), rules: [broken]) == .none)
    }

    @Test func insertionPutsNarrowerRulesAboveBroader() {
        let domain = rule(0, URLMatcher(scope: .domain, value: "github.com"))
        let pattern = rule(1, URLMatcher(scope: .pattern, value: ".*"))
        let rules = [pattern, domain]
        #expect(RuleEngine.insertionIndex(for: URLMatcher(scope: .host, value: "gist.github.com"), in: rules) == 0)
        #expect(RuleEngine.insertionIndex(for: URLMatcher(scope: .domain, value: "gitlab.com"), in: rules) == 1)
        #expect(RuleEngine.insertionIndex(for: URLMatcher(scope: .pattern, value: "x"), in: rules) == 2)
        #expect(RuleEngine.insertionIndex(for: URLMatcher(scope: .host, value: "a.com"), in: []) == 0)
    }
}

struct RuleStorageTests {
    let database: ChordDatabase

    init() throws {
        database = try ChordDatabase.inMemory()
    }

    @Test func addedRulesAreOrderedBySpecificity() throws {
        let broad = try database.addRule(matcher: URLMatcher(scope: .domain, value: "github.com"), actions: RuleActions())
        let narrow = try database.addRule(matcher: URLMatcher(scope: .host, value: "gist.github.com"), actions: RuleActions())
        let pattern = try database.addRule(matcher: URLMatcher(scope: .pattern, value: "x"), actions: RuleActions())
        #expect(try database.rules().map(\.id) == [narrow.id, broad.id, pattern.id])
        #expect(try database.rules().map(\.position) == [0, 1, 2])
    }

    @Test func actionsRoundTripThroughJSON() throws {
        let space = UUID()
        let actions = RuleActions(route: .space(space), overtones: ["a", "b"])
        let rule = try database.addRule(matcher: URLMatcher(scope: .domain, value: "x.com", pathPrefix: "/p"),
                                        actions: actions)
        let stored = try #require(try database.rules().first)
        #expect(stored == rule)
        #expect(stored.actions.route == .space(space))
    }

    @Test func updateKeepsThePosition() throws {
        _ = try database.addRule(matcher: URLMatcher(scope: .host, value: "a.com"), actions: RuleActions())
        var second = try database.addRule(matcher: URLMatcher(scope: .domain, value: "b.com"), actions: RuleActions())
        second.position = 0
        second.enabled = false
        try database.updateRule(second)
        let stored = try database.rules()
        #expect(stored[1].id == second.id)
        #expect(stored[1].enabled == false)
    }

    @Test func updatingAMissingRuleFails() throws {
        let ghost = Rule(matcher: URLMatcher(scope: .host, value: "a.com"), actions: RuleActions())
        #expect(throws: RuleError.ruleNotFound(ghost.id)) {
            try database.updateRule(ghost)
        }
    }

    @Test func moveAndDeleteRenumber() throws {
        let a = try database.addRule(matcher: URLMatcher(scope: .host, value: "a.com"), actions: RuleActions())
        let b = try database.addRule(matcher: URLMatcher(scope: .host, value: "b.com"), actions: RuleActions())
        let c = try database.addRule(matcher: URLMatcher(scope: .host, value: "c.com"), actions: RuleActions())
        let start = try database.rules().map(\.id)

        try database.moveRule(id: start[2], to: 0)
        #expect(try database.rules().map(\.id) == [start[2], start[0], start[1]])

        try database.moveRule(id: start[2], to: 99)
        #expect(try database.rules().map(\.id) == [start[0], start[1], start[2]])

        try database.deleteRule(id: start[1])
        #expect(try database.rules().map(\.position) == [0, 1])
        #expect(Set(try database.rules().map(\.id)).isSubset(of: [a.id, b.id, c.id]))
    }

    @Test func movingAMissingRuleFails() throws {
        let missing = UUID()
        #expect(throws: RuleError.ruleNotFound(missing)) {
            try database.moveRule(id: missing, to: 0)
        }
    }
}

struct OvertoneMigrationTests {
    @Test func savedRulesKeepTheirListUnderTheNewKey() throws {
        let queue = try DatabaseQueue()
        try ChordDatabase.migrator.migrate(queue, upTo: "v3-tab-groups")
        let id = UUID()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO rule (id, position, enabled, matcher, actions)
                VALUES (?, 0, 1, '{"scope":"domain","value":"github.com"}', '{"augments":["wide","dark"]}')
                """, arguments: [id])
        }
        let database = try ChordDatabase(writer: queue)
        let rule = try #require(try database.rules().first)
        #expect(rule.id == id)
        #expect(rule.actions.overtones == ["wide", "dark"])
    }
}
