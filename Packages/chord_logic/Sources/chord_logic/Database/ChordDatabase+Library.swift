import Foundation
import GRDB

/// What the sidebar shows for one space.
public struct SpaceContents: Equatable, Sendable {
    public var space: Space
    public var profile: Profile
    /// The profile's favorites, in order.
    public var favorites: [BrowserTab]
    /// Pinned tabs and groups, not counting group members.
    public var pinned: [BrowserTab]
    /// Open tabs and groups, not counting group members.
    public var open: [BrowserTab]
    /// Each group's member tabs, in strip order, by group id.
    public var members: [UUID: [BrowserTab]]

    public init(space: Space, profile: Profile, favorites: [BrowserTab], pinned: [BrowserTab],
                open: [BrowserTab], members: [UUID: [BrowserTab]] = [:]) {
        self.space = space
        self.profile = profile
        self.favorites = favorites
        self.pinned = pinned
        self.open = open
        self.members = members
    }

    /// The tabs a group's strip shows: the group tab, then its members.
    public func strip(ofGroup groupID: UUID) -> [BrowserTab] {
        guard let group = (pinned + open).first(where: { $0.id == groupID }) else { return [] }
        return [group] + (members[groupID] ?? [])
    }

    /// The group whose strip holds `tabID`: the group itself, or the group
    /// it is a member of. Nil for a tab that is not in a group.
    public func group(containing tabID: UUID) -> BrowserTab? {
        let tops = pinned + open
        if let tab = tops.first(where: { $0.id == tabID }) {
            return tab.isGroup ? tab : nil
        }
        for (groupID, list) in members where list.contains(where: { $0.id == tabID }) {
            return tops.first { $0.id == groupID }
        }
        return nil
    }

    /// The first group, in sidebar order, whose matcher matches `url`.
    public func group(for url: URL) -> BrowserTab? {
        (pinned + open).first { tab in
            guard let matcher = tab.groupMatcher else { return false }
            return matcher.isValid && matcher.matches(url)
        }
    }
}

public enum LibraryError: Error, Equatable {
    case spaceNotFound(UUID)
    case profileNotFound(UUID)
    case tabNotFound(UUID)
    /// A profile that a space uses cannot be deleted.
    case profileInUse(UUID)
    /// Favorites and group members cannot be groups, and groups cannot be favorites.
    case notGroupable(UUID)
    case notAGroup(UUID)
}

// MARK: Profiles and spaces

extension ChordDatabase {
    public func profiles() throws -> [Profile] {
        try writer.read { db in
            try Profile.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func spaces() throws -> [Space] {
        try writer.read { db in
            try Space.order(Column("position")).fetchAll(db)
        }
    }

    @discardableResult
    public func createProfile(name: String) throws -> Profile {
        try writer.write { db in
            let profile = Profile(name: name)
            try profile.insert(db)
            return profile
        }
    }

    /// Deletes a profile. A profile that a space still uses cannot be deleted.
    public func deleteProfile(id: UUID) throws {
        try writer.write { db in
            let users = try Space.filter(Column("profileID") == id).fetchCount(db)
            if users > 0 {
                throw LibraryError.profileInUse(id)
            }
            _ = try Profile.deleteOne(db, key: id)
        }
    }

    /// Adds a space at the end of the space switcher.
    @discardableResult
    public func createSpace(name: String, profileID: UUID) throws -> Space {
        try writer.write { db in
            guard try Profile.exists(db, key: profileID) else {
                throw LibraryError.profileNotFound(profileID)
            }
            let last = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM space") ?? -1
            let space = Space(name: name, profileID: profileID, position: last + 1)
            try space.insert(db)
            return space
        }
    }

    public func renameSpace(id: UUID, to name: String) throws {
        try writer.write { db in
            guard var space = try Space.fetchOne(db, key: id) else {
                throw LibraryError.spaceNotFound(id)
            }
            space.name = name
            try space.update(db)
        }
    }

    /// Moves a space to another profile. Its pinned and open tabs move with it.
    public func setProfile(ofSpace spaceID: UUID, to profileID: UUID) throws {
        try writer.write { db in
            guard var space = try Space.fetchOne(db, key: spaceID) else {
                throw LibraryError.spaceNotFound(spaceID)
            }
            guard try Profile.exists(db, key: profileID) else {
                throw LibraryError.profileNotFound(profileID)
            }
            space.profileID = profileID
            try space.update(db)
            _ = try BrowserTab.filter(Column("spaceID") == spaceID)
                .updateAll(db, Column("profileID").set(to: profileID))
        }
    }

    /// Everything the sidebar shows for one space.
    public func contents(ofSpace spaceID: UUID) throws -> SpaceContents {
        try writer.read { db in
            guard let space = try Space.fetchOne(db, key: spaceID) else {
                throw LibraryError.spaceNotFound(spaceID)
            }
            guard let profile = try Profile.fetchOne(db, key: space.profileID) else {
                throw LibraryError.profileNotFound(space.profileID)
            }
            let favorites = try BrowserTab
                .filter(Column("profileID") == profile.id && Column("section") == TabSection.favorite)
                .order(Column("position")).fetchAll(db)
            let inSpace = try BrowserTab.filter(Column("spaceID") == spaceID)
                .order(Column("position")).fetchAll(db)
            let tops = inSpace.filter { $0.parentTabID == nil }
            let members = Dictionary(grouping: inSpace.filter { $0.parentTabID != nil }) { $0.parentTabID! }
            return SpaceContents(
                space: space, profile: profile, favorites: favorites,
                pinned: tops.filter { $0.section == .pinned },
                open: tops.filter { $0.section == .open },
                members: members)
        }
    }
}

// MARK: Tabs

extension ChordDatabase {
    public func tab(id: UUID) throws -> BrowserTab? {
        try writer.read { db in try BrowserTab.fetchOne(db, key: id) }
    }

    /// Adds an open tab to a space. A new open tab goes to the top of the
    /// open section, as in Arc.
    @discardableResult
    public func openTab(url: URL, title: String = "", inSpace spaceID: UUID, at date: Date = Date()) throws -> BrowserTab {
        try writer.write { db in
            guard let space = try Space.fetchOne(db, key: spaceID) else {
                throw LibraryError.spaceNotFound(spaceID)
            }
            try db.execute(sql: "UPDATE tab SET position = position + 1 WHERE spaceID = ? AND section = 'open' AND parentTabID IS NULL",
                           arguments: [spaceID])
            let tab = BrowserTab(profileID: space.profileID, spaceID: spaceID, section: .open,
                                 position: 0, url: url, title: title, lastActivatedAt: date)
            try tab.insert(db)
            return tab
        }
    }

    /// Moves a tab to the end of another section. A tab that becomes a favorite
    /// leaves its space; a favorite that becomes pinned or open joins `spaceID`.
    public func move(tabID: UUID, to section: TabSection, inSpace spaceID: UUID?) throws {
        try writer.write { db in
            guard var tab = try BrowserTab.fetchOne(db, key: tabID) else {
                throw LibraryError.tabNotFound(tabID)
            }
            if section == .favorite && tab.isGroup {
                throw LibraryError.notGroupable(tabID)
            }
            // A member that moves leaves its group.
            tab.parentTabID = nil
            var targetSpace: UUID? = nil
            if section != .favorite {
                guard let id = spaceID ?? tab.spaceID, let space = try Space.fetchOne(db, key: id) else {
                    throw LibraryError.spaceNotFound(spaceID ?? tab.spaceID ?? UUID())
                }
                targetSpace = space.id
                tab.profileID = space.profileID
            }
            let last: Int
            if let targetSpace {
                last = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM tab WHERE spaceID = ? AND section = ? AND parentTabID IS NULL",
                                        arguments: [targetSpace, section]) ?? -1
            } else {
                last = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM tab WHERE profileID = ? AND section = 'favorite'",
                                        arguments: [tab.profileID]) ?? -1
            }
            tab.section = section
            tab.spaceID = targetSpace
            tab.position = last + 1
            try tab.update(db)
        }
    }

    /// Records the page a tab now shows.
    public func updateTab(id: UUID, url: URL, title: String) throws {
        try writer.write { db in
            guard var tab = try BrowserTab.fetchOne(db, key: id) else {
                throw LibraryError.tabNotFound(id)
            }
            tab.url = url
            tab.title = title
            try tab.update(db)
        }
    }

    public func activateTab(id: UUID, at date: Date = Date()) throws {
        try writer.write { db in
            guard var tab = try BrowserTab.fetchOne(db, key: id) else {
                throw LibraryError.tabNotFound(id)
            }
            tab.lastActivatedAt = date
            try tab.update(db)
        }
    }

    public func closeTab(id: UUID) throws {
        try writer.write { db in
            _ = try BrowserTab.deleteOne(db, key: id)
        }
    }
}

// MARK: Tab groups

extension ChordDatabase {
    /// Makes a pinned or open tab into a group for `matcher`. Open tabs in the
    /// same space that match, and are not groups themselves, move into it.
    public func makeGroup(tabID: UUID, matcher: URLMatcher) throws {
        try writer.write { db in
            guard var group = try BrowserTab.fetchOne(db, key: tabID) else {
                throw LibraryError.tabNotFound(tabID)
            }
            guard group.section != .favorite, group.parentTabID == nil, let spaceID = group.spaceID else {
                throw LibraryError.notGroupable(tabID)
            }
            group.groupMatcher = matcher
            try group.update(db)

            let candidates = try BrowserTab
                .filter(Column("spaceID") == spaceID && Column("section") == TabSection.open
                        && Column("parentTabID") == nil && Column("groupMatcher") == nil && Column("id") != tabID)
                .order(Column("position")).fetchAll(db)
            var position = try Self.nextMemberPosition(groupID: tabID, db)
            for var tab in candidates where matcher.isValid && matcher.matches(tab.url) {
                tab.parentTabID = tabID
                tab.position = position
                position += 1
                try tab.update(db)
            }
        }
    }

    /// Changes which URLs a group takes. Members already in it stay.
    public func setGroupMatcher(tabID: UUID, matcher: URLMatcher) throws {
        try writer.write { db in
            guard var group = try BrowserTab.fetchOne(db, key: tabID), group.isGroup else {
                throw LibraryError.notAGroup(tabID)
            }
            group.groupMatcher = matcher
            try group.update(db)
        }
    }

    /// Turns a group back into a plain tab. Its members become open tabs at
    /// the top of the space's open tabs.
    public func ungroup(tabID: UUID) throws {
        try writer.write { db in
            guard let group = try BrowserTab.fetchOne(db, key: tabID), group.isGroup,
                  let spaceID = group.spaceID else {
                throw LibraryError.notAGroup(tabID)
            }
            let members = try BrowserTab.filter(Column("parentTabID") == tabID)
                .order(Column("position")).fetchAll(db)
            try db.execute(sql: "UPDATE tab SET position = position + ? WHERE spaceID = ? AND section = 'open' AND parentTabID IS NULL",
                           arguments: [members.count, spaceID])
            for (index, var member) in members.enumerated() {
                member.parentTabID = nil
                member.section = .open
                member.position = index
                try member.update(db)
            }
            // Only the matcher column changes. The shift above already moved
            // the group's position, and the record read before it is stale.
            _ = try BrowserTab.filter(Column("id") == tabID).updateAll(db, Column("groupMatcher").set(to: nil))
        }
    }

    /// Adds a tab at the end of a group's strip.
    @discardableResult
    public func openTab(url: URL, title: String = "", inGroup groupID: UUID, at date: Date = Date()) throws -> BrowserTab {
        try writer.write { db in
            guard let group = try BrowserTab.fetchOne(db, key: groupID), group.isGroup else {
                throw LibraryError.notAGroup(groupID)
            }
            let tab = BrowserTab(profileID: group.profileID, spaceID: group.spaceID, section: .open,
                                 position: try Self.nextMemberPosition(groupID: groupID, db),
                                 url: url, title: title, lastActivatedAt: date, parentTabID: groupID)
            try tab.insert(db)
            return tab
        }
    }

    /// Every group in every space: by space, then pinned before open, then sidebar order.
    public func groups() throws -> [BrowserTab] {
        try writer.read { db in
            try BrowserTab.fetchAll(db, sql: """
                SELECT tab.* FROM tab JOIN space ON space.id = tab.spaceID
                WHERE tab.groupMatcher IS NOT NULL
                ORDER BY space.position, tab.section DESC, tab.position
                """)
        }
    }

    private static func nextMemberPosition(groupID: UUID, _ db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM tab WHERE parentTabID = ?", arguments: [groupID]) ?? -1) + 1
    }
}

// MARK: Settings

extension ChordDatabase {
    public func setting(_ key: SettingKey) throws -> String? {
        try writer.read { db in
            try SettingRow.fetchOne(db, key: key.rawValue)?.value
        }
    }

    /// Stores a setting. A nil value removes it.
    public func setSetting(_ key: SettingKey, to value: String?) throws {
        try writer.write { db in
            if let value {
                try SettingRow(key: key.rawValue, value: value).save(db)
            } else {
                _ = try SettingRow.deleteOne(db, key: key.rawValue)
            }
        }
    }

    /// The default search engine. DuckDuckGo when none is stored or the stored
    /// id is unknown.
    public func searchEngine() throws -> SearchEngine {
        let id = try setting(.searchEngine)
        return SearchEngine.presets.first { $0.id == id } ?? .duckDuckGo
    }

    public func setSearchEngine(_ engine: SearchEngine) throws {
        try setSetting(.searchEngine, to: engine.id)
    }
}

// MARK: Lookups for the web layer

extension ChordDatabase {
    /// The website data store id of a profile, or nil when the profile does
    /// not exist or the read fails.
    public func profileDataStoreID(_ profileID: UUID) -> UUID? {
        try? writer.read { db in try Profile.fetchOne(db, key: profileID)?.dataStoreID }
    }
}
