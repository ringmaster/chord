import Foundation
import GRDB

/// The keys of stored settings.
public enum SettingKey: String, Sendable {
    /// The `SearchEngine.id` of the default search engine.
    case searchEngine
    /// The id of the space the main window shows.
    case activeSpaceID
}

/// Chord's database: profiles, spaces, tabs, settings, and history.
///
/// All reads and writes go through this type. The app keeps one instance for
/// its whole run. Tests use `ChordDatabase.inMemory()`.
public final class ChordDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens the database file at `url`, creates it when it does not exist,
    /// and applies any migrations the file does not have yet.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        try self.init(writer: DatabasePool(path: url.path, configuration: configuration))
    }

    /// A database that lives only in memory, for tests.
    public static func inMemory() throws -> ChordDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try ChordDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
        try writer.write { db in try Self.seedDefaults(db) }
    }

    /// The default file location: `~/Library/Application Support/Chord/chord.sqlite`.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: "Chord/chord.sqlite")
    }

    // MARK: Schema

    /// Each migration runs once per database file, in order. Never change a
    /// migration that has shipped; add a new one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "profile") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("dataStoreID", .blob).notNull().unique()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "space") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("profileID", .blob).notNull().indexed().references("profile", onDelete: .restrict)
                t.column("position", .integer).notNull()
            }

            try db.create(table: "tab") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull().indexed().references("profile", onDelete: .cascade)
                t.column("spaceID", .blob).indexed().references("space", onDelete: .cascade)
                t.column("section", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("lastActivatedAt", .datetime)
                t.check(sql: "(section = 'favorite') = (spaceID IS NULL)")
            }

            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            try db.create(table: "historyEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("visitCount", .integer).notNull()
                t.column("lastVisitedAt", .datetime).notNull().indexed()
            }

            // Full-text search over history titles and addresses. GRDB keeps
            // it in step with historyEntry through triggers.
            try db.create(virtualTable: "historySearch", using: FTS5()) { t in
                t.synchronize(withTable: "historyEntry")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("url")
            }
        }

        return migrator
    }

    /// Creates one profile and one space when the database has none.
    static func seedDefaults(_ db: Database) throws {
        if try Profile.fetchCount(db) == 0 {
            let profile = Profile(name: "Personal")
            try profile.insert(db)
            try Space(name: "Home", profileID: profile.id, position: 0).insert(db)
        }
    }
}
