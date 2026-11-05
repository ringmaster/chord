import Foundation
import GRDB
import Testing
@testable import chord_logic

struct ChordDatabaseTests {
    let database: ChordDatabase

    init() throws {
        database = try ChordDatabase.inMemory()
    }

    private func homeSpace() throws -> Space {
        try #require(try database.spaces().first)
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: Setup

    @Test func seedsOneProfileAndOneSpace() throws {
        let profiles = try database.profiles()
        let spaces = try database.spaces()
        #expect(profiles.count == 1)
        #expect(spaces.count == 1)
        #expect(spaces[0].profileID == profiles[0].id)
        #expect(spaces[0].name == "Home")
    }

    @Test func reopeningAFileKeepsDataAndDoesNotSeedAgain() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "chord-test-\(UUID().uuidString)/chord.sqlite")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let first = try ChordDatabase(url: file)
        let space = try #require(try first.spaces().first)
        try first.openTab(url: url("https://example.com"), inSpace: space.id)

        let second = try ChordDatabase(url: file)
        #expect(try second.profiles().count == 1)
        #expect(try second.contents(ofSpace: space.id).open.count == 1)
    }

    // MARK: Profiles and spaces

    @Test func newSpacesGoToTheEnd() throws {
        let profile = try #require(try database.profiles().first)
        let work = try database.createSpace(name: "Work", profileID: profile.id)
        let play = try database.createSpace(name: "Play", profileID: profile.id)
        #expect(work.position == 1)
        #expect(play.position == 2)
        #expect(try database.spaces().map(\.name) == ["Home", "Work", "Play"])
    }

    @Test func creatingASpaceForAMissingProfileFails() throws {
        let missing = UUID()
        #expect(throws: LibraryError.profileNotFound(missing)) {
            try database.createSpace(name: "X", profileID: missing)
        }
    }

    @Test func aProfileInUseCannotBeDeleted() throws {
        let profile = try #require(try database.profiles().first)
        #expect(throws: LibraryError.profileInUse(profile.id)) {
            try database.deleteProfile(id: profile.id)
        }
    }

    @Test func anUnusedProfileCanBeDeleted() throws {
        let spare = try database.createProfile(name: "Spare")
        try database.deleteProfile(id: spare.id)
        #expect(try database.profiles().count == 1)
    }

    @Test func eachProfileHasItsOwnDataStoreID() throws {
        let work = try database.createProfile(name: "Work")
        let personal = try #require(try database.profiles().first)
        #expect(work.dataStoreID != personal.dataStoreID)
    }

    @Test func renameSpace() throws {
        let space = try homeSpace()
        try database.renameSpace(id: space.id, to: "Desk")
        #expect(try database.spaces().first?.name == "Desk")
    }

    @Test func renamingAMissingSpaceFails() throws {
        let missing = UUID()
        #expect(throws: LibraryError.spaceNotFound(missing)) {
            try database.renameSpace(id: missing, to: "X")
        }
    }

    @Test func changingASpaceProfileMovesItsTabs() throws {
        let space = try homeSpace()
        let work = try database.createProfile(name: "Work")
        let tab = try database.openTab(url: url("https://example.com"), inSpace: space.id)
        try database.setProfile(ofSpace: space.id, to: work.id)
        #expect(try database.tab(id: tab.id)?.profileID == work.id)
        #expect(try database.contents(ofSpace: space.id).profile.id == work.id)
    }

    // MARK: Tabs

    @Test func newOpenTabsGoToTheTop() throws {
        let space = try homeSpace()
        try database.openTab(url: url("https://a.example"), inSpace: space.id)
        try database.openTab(url: url("https://b.example"), inSpace: space.id)
        let open = try database.contents(ofSpace: space.id).open
        #expect(open.map(\.url.host) == ["b.example", "a.example"])
        #expect(open.map(\.position) == [0, 1])
    }

    @Test func openingATabInAMissingSpaceFails() throws {
        let missing = UUID()
        #expect(throws: LibraryError.spaceNotFound(missing)) {
            try database.openTab(url: url("https://example.com"), inSpace: missing)
        }
    }

    @Test func pinningMovesATabToThePinnedSection() throws {
        let space = try homeSpace()
        let tab = try database.openTab(url: url("https://example.com"), inSpace: space.id)
        try database.move(tabID: tab.id, to: .pinned, inSpace: nil)
        let contents = try database.contents(ofSpace: space.id)
        #expect(contents.pinned.map(\.id) == [tab.id])
        #expect(contents.open.isEmpty)
    }

    @Test func favoritesLeaveTheSpaceAndShowInEverySpaceOfTheProfile() throws {
        let home = try homeSpace()
        let other = try database.createSpace(name: "Other", profileID: home.profileID)
        let tab = try database.openTab(url: url("https://example.com"), inSpace: home.id)
        try database.move(tabID: tab.id, to: .favorite, inSpace: nil)

        #expect(try database.tab(id: tab.id)?.spaceID == nil)
        #expect(try database.contents(ofSpace: home.id).favorites.map(\.id) == [tab.id])
        #expect(try database.contents(ofSpace: other.id).favorites.map(\.id) == [tab.id])
    }

    @Test func favoritesOfAnotherProfileDoNotShow() throws {
        let home = try homeSpace()
        let work = try database.createProfile(name: "Work")
        let workSpace = try database.createSpace(name: "Work", profileID: work.id)
        let tab = try database.openTab(url: url("https://example.com"), inSpace: home.id)
        try database.move(tabID: tab.id, to: .favorite, inSpace: nil)
        #expect(try database.contents(ofSpace: workSpace.id).favorites.isEmpty)
    }

    @Test func aFavoriteMovedToAnotherProfileSpaceTakesThatProfile() throws {
        let home = try homeSpace()
        let work = try database.createProfile(name: "Work")
        let workSpace = try database.createSpace(name: "Work", profileID: work.id)
        let tab = try database.openTab(url: url("https://example.com"), inSpace: home.id)
        try database.move(tabID: tab.id, to: .favorite, inSpace: nil)
        try database.move(tabID: tab.id, to: .pinned, inSpace: workSpace.id)

        let moved = try #require(try database.tab(id: tab.id))
        #expect(moved.spaceID == workSpace.id)
        #expect(moved.profileID == work.id)
    }

    @Test func movedTabsGoToTheEndOfTheSection() throws {
        let space = try homeSpace()
        let first = try database.openTab(url: url("https://a.example"), inSpace: space.id)
        let second = try database.openTab(url: url("https://b.example"), inSpace: space.id)
        try database.move(tabID: first.id, to: .pinned, inSpace: nil)
        try database.move(tabID: second.id, to: .pinned, inSpace: nil)
        #expect(try database.contents(ofSpace: space.id).pinned.map(\.id) == [first.id, second.id])
    }

    @Test func movingAMissingTabFails() throws {
        let missing = UUID()
        #expect(throws: LibraryError.tabNotFound(missing)) {
            try database.move(tabID: missing, to: .pinned, inSpace: nil)
        }
    }

    @Test func movingAFavoriteWithNoSpaceToPinnedFails() throws {
        let space = try homeSpace()
        let tab = try database.openTab(url: url("https://example.com"), inSpace: space.id)
        try database.move(tabID: tab.id, to: .favorite, inSpace: nil)
        #expect(throws: LibraryError.self) {
            try database.move(tabID: tab.id, to: .pinned, inSpace: nil)
        }
    }

    @Test func updateActivateAndCloseATab() throws {
        let space = try homeSpace()
        let tab = try database.openTab(url: url("https://a.example"), inSpace: space.id)
        try database.updateTab(id: tab.id, url: url("https://b.example/page"), title: "Page")
        let when = Date(timeIntervalSince1970: 1_000_000)
        try database.activateTab(id: tab.id, at: when)

        let updated = try #require(try database.tab(id: tab.id))
        #expect(updated.url == url("https://b.example/page"))
        #expect(updated.title == "Page")
        #expect(updated.lastActivatedAt == when)

        try database.closeTab(id: tab.id)
        #expect(try database.tab(id: tab.id) == nil)
    }

    @Test func updatingOrActivatingAMissingTabFails() throws {
        let missing = UUID()
        #expect(throws: LibraryError.tabNotFound(missing)) {
            try database.updateTab(id: missing, url: url("https://a.example"), title: "")
        }
        #expect(throws: LibraryError.tabNotFound(missing)) {
            try database.activateTab(id: missing)
        }
    }

    @Test func theSchemaRejectsAFavoriteWithASpace() throws {
        let space = try homeSpace()
        let bad = BrowserTab(profileID: space.profileID, spaceID: space.id, section: .favorite,
                             position: 0, url: url("https://example.com"))
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in try bad.insert(db) }
        }
    }

    // MARK: Settings

    @Test func settingsStoreAndRemoveValues() throws {
        #expect(try database.setting(.activeSpaceID) == nil)
        try database.setSetting(.activeSpaceID, to: "abc")
        #expect(try database.setting(.activeSpaceID) == "abc")
        try database.setSetting(.activeSpaceID, to: "def")
        #expect(try database.setting(.activeSpaceID) == "def")
        try database.setSetting(.activeSpaceID, to: nil)
        #expect(try database.setting(.activeSpaceID) == nil)
    }

    @Test func searchEngineDefaultsToDuckDuckGo() throws {
        #expect(try database.searchEngine() == .duckDuckGo)
    }

    @Test func searchEngineCanBeChanged() throws {
        let kagi = try #require(SearchEngine.presets.first { $0.id == "kagi" })
        try database.setSearchEngine(kagi)
        #expect(try database.searchEngine() == kagi)
    }

    @Test func anUnknownStoredSearchEngineFallsBackToDuckDuckGo() throws {
        try database.setSetting(.searchEngine, to: "gone")
        #expect(try database.searchEngine() == .duckDuckGo)
    }
}
