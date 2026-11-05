import Foundation
import GRDB

/// What the sidebar shows for one space.
public struct SpaceContents: Equatable, Sendable {
    public var space: Space
    public var profile: Profile
    /// The profile's favorites, in order.
    public var favorites: [BrowserTab]
    public var pinned: [BrowserTab]
    public var open: [BrowserTab]
}

public enum LibraryError: Error, Equatable {
    case spaceNotFound(UUID)
    case profileNotFound(UUID)
    case tabNotFound(UUID)
    /// A profile that a space uses cannot be deleted.
    case profileInUse(UUID)
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
            return SpaceContents(
                space: space, profile: profile, favorites: favorites,
                pinned: inSpace.filter { $0.section == .pinned },
                open: inSpace.filter { $0.section == .open })
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
            try db.execute(sql: "UPDATE tab SET position = position + 1 WHERE spaceID = ? AND section = 'open'",
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
                last = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM tab WHERE spaceID = ? AND section = ?",
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
