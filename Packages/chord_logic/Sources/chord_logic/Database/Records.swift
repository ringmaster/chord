import Foundation
import GRDB

/// A profile is one set of website data: cookies, logins, and storage.
/// Each space uses one profile, and several spaces can share a profile.
public struct Profile: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var name: String
    /// The identifier passed to `WKWebsiteDataStore(forIdentifier:)`.
    public var dataStoreID: UUID
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, dataStoreID: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.dataStoreID = dataStoreID
        self.createdAt = createdAt
    }
}

/// A space is a named set of pinned and open tabs that uses one profile.
public struct Space: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var name: String
    public var profileID: UUID
    /// The order of the space in the sidebar's space switcher.
    public var position: Int

    public init(id: UUID = UUID(), name: String, profileID: UUID, position: Int) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.position = position
    }
}

/// Where a tab shows in the sidebar.
public enum TabSection: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Shared by all spaces that use the same profile. Shown as tiles at the top.
    case favorite
    /// Kept in one space until the user unpins it.
    case pinned
    /// An ordinary open tab in one space.
    case open
}

/// A tab the user has open, pinned, or added to favorites.
///
/// A favorite belongs to a profile and has no space. Pinned and open tabs
/// belong to a space, and their profile is the space's profile.
///
/// A pinned or open tab with a `groupMatcher` is a tab group. New tabs whose
/// address matches open inside it, as header tabs across the top of the page.
/// Those member tabs have `parentTabID` set to the group's id and do not show
/// in the sidebar themselves.
public struct BrowserTab: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var profileID: UUID
    public var spaceID: UUID?
    public var section: TabSection
    /// The order of the tab within its section.
    public var position: Int
    public var url: URL
    public var title: String
    public var lastActivatedAt: Date?
    /// The group this tab is a member of.
    public var parentTabID: UUID?
    /// Set when this tab is a group: the URLs that open inside it.
    public var groupMatcher: URLMatcher?

    public var isGroup: Bool { groupMatcher != nil }

    public init(id: UUID = UUID(), profileID: UUID, spaceID: UUID?, section: TabSection,
                position: Int, url: URL, title: String = "", lastActivatedAt: Date? = nil,
                parentTabID: UUID? = nil, groupMatcher: URLMatcher? = nil) {
        self.id = id
        self.profileID = profileID
        self.spaceID = spaceID
        self.section = section
        self.position = position
        self.url = url
        self.title = title
        self.lastActivatedAt = lastActivatedAt
        self.parentTabID = parentTabID
        self.groupMatcher = groupMatcher
    }

    public static let databaseTableName = "tab"
}

/// One visited address. Each visit to the same URL updates this row.
public struct HistoryEntry: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var url: URL
    public var title: String
    public var visitCount: Int
    public var lastVisitedAt: Date

    public init(id: Int64? = nil, url: URL, title: String, visitCount: Int, lastVisitedAt: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A page action task the user ran, offered again when they type "$" in the palette.
public struct AgentTaskEntry: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "agentTask"

    public var id: Int64?
    public var text: String
    public var useCount: Int
    public var lastUsedAt: Date

    public init(id: Int64? = nil, text: String, useCount: Int, lastUsedAt: Date) {
        self.id = id
        self.text = text
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One stored setting. `SettingKey` lists the keys.
struct SettingRow: Codable, FetchableRecord, PersistableRecord {
    var key: String
    var value: String

    static let databaseTableName = "setting"
}
