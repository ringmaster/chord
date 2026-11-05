import Foundation
import GRDB

/// A web extension the user added to Chord.
public struct InstalledExtension: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public enum Source: String, Codable, Sendable, DatabaseValueConvertible {
        /// A folder with a manifest.json, such as an unpacked Chrome or Firefox extension.
        case folder
        /// A Safari web extension: an .appex bundle inside an app.
        case appExtension
    }

    public var id: UUID
    public var source: Source
    /// The folder or .appex bundle the extension loads from.
    public var path: String
    public var name: String
    public var enabled: Bool
    /// Permission names the user granted, such as "tabs" or "storage".
    public var grantedPermissions: [String]
    /// Match patterns the user granted, such as "<all_urls>" or "*://*.example.com/*".
    public var grantedMatchPatterns: [String]
    public var addedAt: Date

    public init(id: UUID = UUID(), source: Source, path: String, name: String, enabled: Bool = true,
                grantedPermissions: [String] = [], grantedMatchPatterns: [String] = [], addedAt: Date = Date()) {
        self.id = id
        self.source = source
        self.path = path
        self.name = name
        self.enabled = enabled
        self.grantedPermissions = grantedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
        self.addedAt = addedAt
    }

    public static let databaseTableName = "webExtension"
}

public enum ExtensionError: Error, Equatable {
    case extensionNotFound(UUID)
    /// The folder or bundle is already installed.
    case alreadyInstalled(String)
}

extension ChordDatabase {
    public func installedExtensions() throws -> [InstalledExtension] {
        try writer.read { db in
            try InstalledExtension.order(Column("addedAt")).fetchAll(db)
        }
    }

    @discardableResult
    public func addExtension(source: InstalledExtension.Source, path: String, name: String) throws -> InstalledExtension {
        try writer.write { db in
            if try InstalledExtension.filter(Column("path") == path).fetchCount(db) > 0 {
                throw ExtensionError.alreadyInstalled(path)
            }
            let installed = InstalledExtension(source: source, path: path, name: name)
            try installed.insert(db)
            return installed
        }
    }

    /// Saves changes to an extension's name, enabled state, or grants.
    public func updateExtension(_ installed: InstalledExtension) throws {
        try writer.write { db in
            guard try InstalledExtension.exists(db, key: installed.id) else {
                throw ExtensionError.extensionNotFound(installed.id)
            }
            try installed.update(db)
        }
    }

    public func removeExtension(id: UUID) throws {
        try writer.write { db in
            _ = try InstalledExtension.deleteOne(db, key: id)
        }
    }
}

/// Finds the Safari web extensions that apps carry inside them.
///
/// A Safari web extension is an .appex bundle in an app's
/// `Contents/PlugIns` folder whose Info.plist names the extension point
/// `com.apple.Safari.web-extension`.
public enum SafariExtensionScanner {
    public static let extensionPoint = "com.apple.Safari.web-extension"

    public struct Found: Equatable, Sendable {
        /// The .appex bundle.
        public var bundleURL: URL
        /// The app that carries it.
        public var appURL: URL
        /// The extension's display name, or the app's name when it has none.
        public var name: String
    }

    /// The Safari web extensions in the apps directly inside `folders`, sorted by name.
    public static func scan(applicationFolders folders: [URL]) -> [Found] {
        let manager = FileManager.default
        var found: [Found] = []
        for folder in folders {
            let apps = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                found += scan(app: app)
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Safari web extensions inside one app.
    public static func scan(app: URL) -> [Found] {
        let plugIns = app.appending(path: "Contents/PlugIns")
        let bundles = (try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? []
        return bundles.filter { $0.pathExtension == "appex" }.compactMap { bundle in
            guard let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")),
                  let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                  point == extensionPoint else { return nil }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? app.deletingPathExtension().lastPathComponent
            return Found(bundleURL: bundle, appURL: app, name: name)
        }
    }
}
