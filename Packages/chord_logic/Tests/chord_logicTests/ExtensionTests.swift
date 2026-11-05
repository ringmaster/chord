import Foundation
import Testing
@testable import chord_logic

struct InstalledExtensionTests {
    let database: ChordDatabase

    init() throws {
        database = try ChordDatabase.inMemory()
    }

    @Test func addListUpdateAndRemove() throws {
        var added = try database.addExtension(source: .folder, path: "/x/ext", name: "Ext")
        #expect(try database.installedExtensions().map(\.id) == [added.id])

        added.enabled = false
        added.grantedPermissions = ["tabs", "storage"]
        added.grantedMatchPatterns = ["<all_urls>"]
        try database.updateExtension(added)
        let stored = try #require(try database.installedExtensions().first)
        #expect(stored.enabled == false)
        #expect(stored.grantedPermissions == ["tabs", "storage"])
        #expect(stored.grantedMatchPatterns == ["<all_urls>"])

        try database.removeExtension(id: added.id)
        #expect(try database.installedExtensions().isEmpty)
    }

    @Test func aPathCanBeInstalledOnce() throws {
        try database.addExtension(source: .appExtension, path: "/A.app/Contents/PlugIns/E.appex", name: "E")
        #expect(throws: ExtensionError.alreadyInstalled("/A.app/Contents/PlugIns/E.appex")) {
            try database.addExtension(source: .appExtension, path: "/A.app/Contents/PlugIns/E.appex", name: "E")
        }
    }

    @Test func updatingAMissingExtensionFails() throws {
        let ghost = InstalledExtension(source: .folder, path: "/ghost", name: "Ghost")
        #expect(throws: ExtensionError.extensionNotFound(ghost.id)) {
            try database.updateExtension(ghost)
        }
    }
}

struct SafariExtensionScannerTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "chord-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func makeAppex(app: String, appex: String, point: String, displayName: String?) throws {
        let contents = folder.appending(path: "\(app).app/Contents/PlugIns/\(appex).appex/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["NSExtension": ["NSExtensionPointIdentifier": point], "CFBundleName": appex]
        if let displayName { info["CFBundleDisplayName"] = displayName }
        (info as NSDictionary).write(to: contents.appending(path: "Info.plist"), atomically: true)
    }

    @Test func findsOnlySafariWebExtensions() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeAppex(app: "Passwords", appex: "Safari", point: SafariExtensionScanner.extensionPoint,
                      displayName: "Passwords for Safari")
        try makeAppex(app: "Blocker", appex: "Filter", point: SafariExtensionScanner.extensionPoint, displayName: nil)
        try makeAppex(app: "Widgets", appex: "Widget", point: "com.apple.widgetkit-extension", displayName: "Widget")
        try FileManager.default.createDirectory(at: folder.appending(path: "Empty.app"), withIntermediateDirectories: true)

        let found = SafariExtensionScanner.scan(applicationFolders: [folder, folder.appending(path: "missing")])
        #expect(found.map(\.name) == ["Filter", "Passwords for Safari"])
        #expect(found.last?.appURL.lastPathComponent == "Passwords.app")
        #expect(found.last?.bundleURL.lastPathComponent == "Safari.appex")
    }
}
