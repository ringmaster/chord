import Foundation
import Testing
@testable import chord_logic

struct NativeMessagingHostTests {
    let folder: URL
    let origin = "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/"

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "chord-nm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func writeManifest(_ name: String, json: String) throws {
        try Data(json.utf8).write(to: folder.appending(path: "\(name).json"))
    }

    private func manifestJSON(name: String = "com.example.host", path: String = "/Applications/Host",
                              type: String = "stdio", origins: [String]) -> String {
        let list = origins.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"name":"\#(name)","description":"Host","path":"\#(path)","type":"\#(type)","allowed_origins":[\#(list)]}"#
    }

    // Security: names, origins, and manifest contents.

    @Test func namesThatCouldLeaveTheFolderAreRefused() {
        for name in ["../etc/passwd", "a/b", ".hidden", "trailing.", "two..dots", "Upper.Case", "", "space name"] {
            #expect(!NativeMessagingHosts.isValidName(name), "\(name)")
            #expect(throws: NativeMessagingHosts.LookupError.invalidName(name)) {
                try NativeMessagingHosts.manifest(named: name, for: origin, in: [folder])
            }
        }
        #expect(NativeMessagingHosts.isValidName("com.1password.1password"))
        #expect(NativeMessagingHosts.isValidName("host_name.v2"))
    }

    @Test func anOriginTheManifestDoesNotListIsRefused() throws {
        try writeManifest("com.example.host", json: manifestJSON(origins: ["chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/"]))
        #expect(throws: NativeMessagingHosts.LookupError.originNotAllowed(name: "com.example.host", origin: origin)) {
            try NativeMessagingHosts.manifest(named: "com.example.host", for: origin, in: [folder])
        }
    }

    @Test func aManifestWhoseNameDoesNotMatchItsFileIsRefused() throws {
        try writeManifest("com.example.host", json: manifestJSON(name: "com.other.host", origins: [origin]))
        #expect(throws: NativeMessagingHosts.LookupError.self) {
            try NativeMessagingHosts.manifest(named: "com.example.host", for: origin, in: [folder])
        }
    }

    @Test func aRelativePathOrAnotherTypeIsRefused() throws {
        try writeManifest("com.example.host", json: manifestJSON(path: "Host", origins: [origin]))
        #expect(throws: NativeMessagingHosts.LookupError.self) {
            try NativeMessagingHosts.manifest(named: "com.example.host", for: origin, in: [folder])
        }
        try writeManifest("com.example.host", json: manifestJSON(type: "socket", origins: [origin]))
        #expect(throws: NativeMessagingHosts.LookupError.self) {
            try NativeMessagingHosts.manifest(named: "com.example.host", for: origin, in: [folder])
        }
        try writeManifest("com.example.host", json: "not json")
        #expect(throws: NativeMessagingHosts.LookupError.self) {
            try NativeMessagingHosts.manifest(named: "com.example.host", for: origin, in: [folder])
        }
    }

    // Lookup.

    @Test func aListedOriginFindsTheManifest() throws {
        try writeManifest("com.example.host", json: manifestJSON(origins: [origin]))
        let manifest = try NativeMessagingHosts.manifest(named: "com.example.host", for: origin, in: [folder])
        #expect(manifest.path == "/Applications/Host")
        #expect(manifest.allowedOrigins == [origin])
    }

    @Test func theFirstFolderWithTheManifestWins() throws {
        let second = folder.appending(path: "second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(manifestJSON(path: "/second", origins: [origin]).utf8).write(to: second.appending(path: "com.example.host.json"))
        let missing = folder.appending(path: "missing")
        let manifest = try NativeMessagingHosts.manifest(named: "com.example.host", for: origin, in: [missing, second])
        #expect(manifest.path == "/second")
    }

    @Test func aMissingManifestIsNotFound() {
        #expect(throws: NativeMessagingHosts.LookupError.notFound("com.example.none")) {
            try NativeMessagingHosts.manifest(named: "com.example.none", for: origin, in: [folder])
        }
    }

    @Test func chordsFolderComesBeforeChromes() {
        let folders = NativeMessagingHosts.defaultFolders(home: URL(filePath: "/Users/x"))
        #expect(folders.first?.path == "/Users/x/Library/Application Support/Chord/NativeMessagingHosts")
        #expect(folders.contains { $0.path.contains("Google/Chrome/NativeMessagingHosts") })
    }
}

struct NativeMessageFramingTests {
    @Test func framingPutsALittleEndianLengthFirst() throws {
        let framed = try NativeMessageFraming.frame(Data(#"{"a":1}"#.utf8))
        #expect(Array(framed.prefix(4)) == [7, 0, 0, 0])
        #expect(framed.dropFirst(4) == Data(#"{"a":1}"#.utf8))
    }

    @Test func aMessageSplitAcrossReadsIsJoined() throws {
        var reader = NativeMessageFraming()
        let framed = try NativeMessageFraming.frame(Data(#"{"type":"hello"}"#.utf8))
        #expect(try reader.append(framed.prefix(2)).isEmpty)
        #expect(try reader.append(framed.dropFirst(2).prefix(5)).isEmpty)
        #expect(try reader.append(framed.dropFirst(7)) == [Data(#"{"type":"hello"}"#.utf8)])
    }

    @Test func oneReadCanHoldSeveralMessages() throws {
        var reader = NativeMessageFraming()
        var bytes = try NativeMessageFraming.frame(Data("1".utf8))
        bytes.append(try NativeMessageFraming.frame(Data("22".utf8)))
        bytes.append(try NativeMessageFraming.frame(Data("333".utf8)).prefix(5))
        #expect(try reader.append(bytes) == [Data("1".utf8), Data("22".utf8)])
        #expect(try reader.append(Data("33".utf8)) == [Data("333".utf8)])
    }

    @Test func anIncomingMessageOverOneMegabyteIsRefused() {
        var reader = NativeMessageFraming()
        let length = NativeMessageFraming.maximumIncomingLength + 1
        let header = Data([UInt8(length & 0xff), UInt8(length >> 8 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 24 & 0xff)])
        #expect(throws: NativeMessageFraming.FramingError.messageTooLong(length)) {
            try reader.append(header)
        }
    }
}

struct ChromeExtensionIDTests {
    @Test func theIDComesFromTheManifestKey() {
        // The expected ID was computed separately with Python's hashlib:
        // the first 16 bytes of sha256(b"chord"), each hex digit mapped to a to p.
        let key = Data("chord".utf8).base64EncodedString()
        #expect(ChromeExtensionID.id(forPublicKey: key) == "cfhdflkkkfleoemmcdipkaachpcbonie")
    }

    @Test func aFolderWithoutAKeyUsesTheStoreMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "chord-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "_metadata"), withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"X","version":"1"}"#.utf8).write(to: folder.appending(path: "manifest.json"))
        let payload = Data(#"{"item_id":"aeblfdkhhhdcdjpifhhbdiojplfjncoa","item_version":"1"}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let verified = #"[{"description":"treehash per file","signed_content":{"payload":"\#(payload)","signatures":[]}}]"#
        try Data(verified.utf8).write(to: folder.appending(path: "_metadata/verified_contents.json"))
        #expect(ChromeExtensionID.id(forExtensionFolder: folder) == "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
    }

    @Test func aFolderWithNoKeyAndNoMetadataHasNoID() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "chord-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"X","version":"1"}"#.utf8).write(to: folder.appending(path: "manifest.json"))
        #expect(ChromeExtensionID.id(forExtensionFolder: folder) == nil)
    }

    @Test func aMalformedStoreIDIsIgnored() {
        let payload = Data(#"{"item_id":"../../not-an-id"}"#.utf8).base64EncodedString()
        let verified = #"[{"signed_content":{"payload":"\#(payload)"}}]"#
        #expect(ChromeExtensionID.storeID(fromVerifiedContents: Data(verified.utf8)) == nil)
        #expect(ChromeExtensionID.isValid("aeblfdkhhhdcdjpifhhbdiojplfjncoa"))
        #expect(!ChromeExtensionID.isValid("zeblfdkhhhdcdjpifhhbdiojplfjncoa"))
    }

    @Test func theOriginHasChromesForm() {
        #expect(ChromeExtensionID.origin(for: "abc") == "chrome-extension://abc/")
    }
}
