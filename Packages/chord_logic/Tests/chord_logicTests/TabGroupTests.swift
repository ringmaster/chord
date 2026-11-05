import Foundation
import Testing
@testable import chord_logic

struct TabGroupTests {
    let database: ChordDatabase
    let space: Space
    let datadog = URLMatcher(scope: .domain, value: "datadoghq.com")

    init() throws {
        database = try ChordDatabase.inMemory()
        space = try #require(try database.spaces().first)
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func contents() throws -> SpaceContents {
        try database.contents(ofSpace: space.id)
    }

    @Test func makingAGroupPullsInMatchingOpenTabs() throws {
        let other = try database.openTab(url: url("https://example.com"), inSpace: space.id)
        let logs = try database.openTab(url: url("https://app.datadoghq.com/logs"), inSpace: space.id)
        let group = try database.openTab(url: url("https://app.datadoghq.com/dash"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)

        let after = try contents()
        #expect(after.open.map(\.id) == [group.id, other.id])
        #expect(after.members[group.id]?.map(\.id) == [logs.id])
        #expect(after.strip(ofGroup: group.id).map(\.id) == [group.id, logs.id])
    }

    @Test func pinnedTabsAndOtherGroupsAreNotPulledIn() throws {
        let pinned = try database.openTab(url: url("https://app.datadoghq.com/a"), inSpace: space.id)
        try database.move(tabID: pinned.id, to: .pinned, inSpace: nil)
        let otherGroup = try database.openTab(url: url("https://app.datadoghq.com/b"), inSpace: space.id)
        try database.makeGroup(tabID: otherGroup.id, matcher: datadog)
        let group = try database.openTab(url: url("https://app.datadoghq.com/c"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        #expect(try contents().members[group.id] == nil)
    }

    @Test func favoritesAndMembersCannotBecomeGroups() throws {
        let favorite = try database.openTab(url: url("https://a.example"), inSpace: space.id)
        try database.move(tabID: favorite.id, to: .favorite, inSpace: nil)
        #expect(throws: LibraryError.notGroupable(favorite.id)) {
            try database.makeGroup(tabID: favorite.id, matcher: datadog)
        }
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        let member = try database.openTab(url: url("https://app.datadoghq.com/x"), inGroup: group.id)
        #expect(throws: LibraryError.notGroupable(member.id)) {
            try database.makeGroup(tabID: member.id, matcher: datadog)
        }
    }

    @Test func aGroupCannotBecomeAFavorite() throws {
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        #expect(throws: LibraryError.notGroupable(group.id)) {
            try database.move(tabID: group.id, to: .favorite, inSpace: nil)
        }
    }

    @Test func newMembersGoToTheEndOfTheStripAndNewOpenTabsSkipMembers() throws {
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        let first = try database.openTab(url: url("https://app.datadoghq.com/1"), inGroup: group.id)
        let second = try database.openTab(url: url("https://app.datadoghq.com/2"), inGroup: group.id)
        try database.openTab(url: url("https://example.com"), inSpace: space.id)

        let after = try contents()
        #expect(after.members[group.id]?.map(\.id) == [first.id, second.id])
        #expect(after.members[group.id]?.map(\.position) == [0, 1])
        #expect(after.open.count == 2)
    }

    @Test func openingInSomethingThatIsNotAGroupFails() throws {
        let plain = try database.openTab(url: url("https://example.com"), inSpace: space.id)
        #expect(throws: LibraryError.notAGroup(plain.id)) {
            try database.openTab(url: url("https://x.example"), inGroup: plain.id)
        }
        #expect(throws: LibraryError.notAGroup(plain.id)) {
            try database.ungroup(tabID: plain.id)
        }
        #expect(throws: LibraryError.notAGroup(plain.id)) {
            try database.setGroupMatcher(tabID: plain.id, matcher: datadog)
        }
    }

    @Test func groupLookups() throws {
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        let member = try database.openTab(url: url("https://app.datadoghq.com/x"), inGroup: group.id)
        let plain = try database.openTab(url: url("https://example.com"), inSpace: space.id)

        let now = try contents()
        #expect(now.group(containing: group.id)?.id == group.id)
        #expect(now.group(containing: member.id)?.id == group.id)
        #expect(now.group(containing: plain.id) == nil)
        #expect(now.group(for: url("https://eu.datadoghq.com/y"))?.id == group.id)
        #expect(now.group(for: url("https://example.com")) == nil)
    }

    @Test func anInvalidMatcherTakesNothing() throws {
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: URLMatcher(scope: .pattern, value: "(["))
        #expect(try contents().group(for: url("https://app.datadoghq.com")) == nil)
    }

    @Test func changingTheMatcher() throws {
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        try database.setGroupMatcher(tabID: group.id, matcher: URLMatcher(scope: .domain, value: "grafana.net"))
        #expect(try contents().group(for: url("https://x.grafana.net"))?.id == group.id)
    }

    @Test func ungroupingReturnsMembersToTheTopOfOpenTabs() throws {
        let plain = try database.openTab(url: url("https://example.com"), inSpace: space.id)
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        let member = try database.openTab(url: url("https://app.datadoghq.com/x"), inGroup: group.id)
        try database.ungroup(tabID: group.id)

        let after = try contents()
        #expect(after.members.isEmpty)
        #expect(after.open.map(\.id) == [member.id, group.id, plain.id])
        #expect(after.open.map(\.position) == [0, 1, 2])
        #expect(try database.tab(id: group.id)?.isGroup == false)
    }

    @Test func movingAMemberTakesItOutOfTheGroup() throws {
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        let member = try database.openTab(url: url("https://app.datadoghq.com/x"), inGroup: group.id)
        try database.move(tabID: member.id, to: .pinned, inSpace: nil)
        let after = try contents()
        #expect(after.members[group.id] == nil)
        #expect(after.pinned.map(\.id) == [member.id])
    }

    @Test func closingAGroupClosesItsMembers() throws {
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        let member = try database.openTab(url: url("https://app.datadoghq.com/x"), inGroup: group.id)
        try database.closeTab(id: group.id)
        #expect(try database.tab(id: member.id) == nil)
    }

    @Test func groupsListsEveryGroupWithItsMatcher() throws {
        let group = try database.openTab(url: url("https://app.datadoghq.com"), inSpace: space.id)
        try database.makeGroup(tabID: group.id, matcher: datadog)
        let groups = try database.groups()
        #expect(groups.map(\.id) == [group.id])
        #expect(groups.first?.groupMatcher == datadog)
    }
}
