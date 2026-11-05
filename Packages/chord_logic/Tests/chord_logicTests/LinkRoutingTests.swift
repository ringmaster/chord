import Foundation
import Testing
@testable import chord_logic

struct LinkRoutingTests {
    let home = UUID()
    let work = UUID()
    let profile = UUID()
    let group = UUID()

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func rule(_ value: String, _ route: Route) -> Rule {
        Rule(matcher: URLMatcher(scope: .domain, value: value), actions: RuleActions(route: route))
    }

    private func noGroups(_ url: URL, _ space: UUID) -> UUID? { nil }

    private var inHome: LinkRouting.Context { .init(spaceID: home, groupID: nil) }

    @Test func sameSiteLinksStay() {
        let action = LinkRouting.action(source: url("https://app.datadoghq.com/a"),
                                        target: url("https://docs.datadoghq.com/b"),
                                        context: inHome, rules: [rule("datadoghq.com", .space(work))],
                                        groupFor: noGroups)
        #expect(action == .stay)
    }

    @Test func linksWithoutAHostStay() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("about:blank"),
                                        context: inHome, rules: [], groupFor: noGroups)
        #expect(action == .stay)
    }

    @Test func crossSiteLinksWithNoRuleStay() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://example2.com"),
                                        context: inHome, rules: [], groupFor: noGroups)
        #expect(action == .stay)
    }

    @Test func aMinorChordRuleOpensAMinorChordWindow() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://example2.com"),
                                        context: inHome, rules: [rule("example2.com", .minorChord(profileID: profile))],
                                        groupFor: noGroups)
        #expect(action == .openMinorChord(profileID: profile))
    }

    @Test func insideAMinorChordWindowAMinorChordRuleStays() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://example2.com"),
                                        context: .init(spaceID: nil, groupID: nil),
                                        rules: [rule("example2.com", .minorChord(profileID: profile))],
                                        groupFor: noGroups)
        #expect(action == .stay)
    }

    @Test func aRuleForAnotherSpaceOpensThere() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://github.com/x"),
                                        context: inHome, rules: [rule("github.com", .space(work))],
                                        groupFor: noGroups)
        #expect(action == .openInSpace(work))
    }

    @Test func aRuleForTheSameSpaceStays() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://github.com/x"),
                                        context: inHome, rules: [rule("github.com", .space(home))],
                                        groupFor: noGroups)
        #expect(action == .stay)
    }

    @Test func aGroupInTheTabSpaceTakesPrecedenceOverRules() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://app.datadoghq.com"),
                                        context: inHome,
                                        rules: [rule("datadoghq.com", .minorChord(profileID: profile))],
                                        groupFor: { _, space in space == home ? group : nil })
        #expect(action == .openInGroup(group))
    }

    @Test func aLinkIntoTheGroupTheTabIsAlreadyInStays() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://app.datadoghq.com"),
                                        context: .init(spaceID: home, groupID: group), rules: [],
                                        groupFor: { _, _ in group })
        #expect(action == .stay)
    }

    @Test func aRuleForAnotherSpaceUsesThatSpacesGroup() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://app.datadoghq.com"),
                                        context: inHome, rules: [rule("datadoghq.com", .space(work))],
                                        groupFor: { _, space in space == work ? group : nil })
        #expect(action == .openInGroup(group))
    }

    @Test func minorChordWindowsIgnoreGroups() {
        let action = LinkRouting.action(source: url("https://example.com"), target: url("https://app.datadoghq.com"),
                                        context: .init(spaceID: nil, groupID: nil), rules: [],
                                        groupFor: { _, _ in group })
        #expect(action == .stay)
    }
}

struct ChordLinkTests {
    @Test func readsAMinorLink() {
        let link = ChordLink(URL(string: "chord://minor?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1")!)
        #expect(link == .minor(URL(string: "https://example.com/a?b=1")!))
    }

    @Test(arguments: [
        "chord://minor",
        "chord://minor?url=",
        "chord://minor?url=file%3A%2F%2F%2Fetc%2Fpasswd",
        "chord://other?url=https%3A%2F%2Fexample.com",
        "https://minor?url=https%3A%2F%2Fexample.com",
    ])
    func rejectsOtherLinks(address: String) {
        #expect(ChordLink(URL(string: address)!) == nil)
    }
}
