import CryptoKit
import Foundation

// Chrome-style native messaging: an extension calls
// `runtime.connectNative(name)` or `runtime.sendNativeMessage(name, message)`,
// and the browser starts the app named by a host manifest. The browser and the
// app exchange JSON messages over the app's standard input and output.
//
// The protocol, from Chrome's documentation
// (https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging):
// - Each message is UTF-8 JSON, preceded by its length as a 32-bit unsigned
//   integer in native byte order (little-endian on every Mac Chord runs on).
// - A message from the app is at most 1 MB. A message to the app is at most 64 MiB.
// - The browser passes the caller's origin, such as
//   `chrome-extension://abcdefghijklmnopabcdefghijklmnop/`, as the first argument.

/// Reads and writes length-prefixed native messages.
public struct NativeMessageFraming: Sendable {
    /// The largest message an app may send to the browser.
    public static let maximumIncomingLength = 1024 * 1024
    /// The largest message the browser may send to an app.
    public static let maximumOutgoingLength = 64 * 1024 * 1024

    public enum FramingError: Error, Equatable {
        /// A message is longer than the protocol allows.
        case messageTooLong(Int)
    }

    private var buffer = Data()

    public init() {}

    /// Adds `message`'s length before it.
    public static func frame(_ message: Data) throws -> Data {
        guard message.count <= maximumOutgoingLength else {
            throw FramingError.messageTooLong(message.count)
        }
        var length = UInt32(message.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(message)
        return framed
    }

    /// Adds bytes read from the app, and returns each message that is now complete.
    /// A message can arrive across several reads, and one read can hold several messages.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var messages: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8
                | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 24
            guard length <= Self.maximumIncomingLength else {
                throw FramingError.messageTooLong(length)
            }
            guard buffer.count >= 4 + length else { break }
            messages.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return messages
    }
}

/// A host manifest: a JSON file that names a native messaging app and the
/// extensions that may start it.
public struct NativeMessagingHostManifest: Decodable, Equatable, Sendable {
    public var name: String
    public var description: String?
    /// The app to start. It must be an absolute path.
    public var path: String
    /// Always "stdio".
    public var type: String
    /// The extension origins that may start the app, such as
    /// `chrome-extension://abcdefghijklmnopabcdefghijklmnop/`.
    public var allowedOrigins: [String]

    enum CodingKeys: String, CodingKey {
        case name, description, path, type
        case allowedOrigins = "allowed_origins"
    }

    /// True when the extension at `origin` may start this app.
    public func allows(origin: String) -> Bool {
        allowedOrigins.contains(origin)
    }
}

/// Finds host manifests in the folders browsers keep them in.
public enum NativeMessagingHosts {
    public enum LookupError: Error, Equatable {
        /// The name has characters a host name cannot have.
        case invalidName(String)
        /// No folder has a manifest with this name.
        case notFound(String)
        /// The manifest is not valid: it is not JSON, its name does not match its
        /// file name, its path is not absolute, or its type is not "stdio".
        case invalidManifest(String)
        /// The manifest does not list the extension's origin.
        case originNotAllowed(name: String, origin: String)
    }

    /// The folders searched, in order. Chord's own folder comes first. Chrome's
    /// folders follow, because apps such as 1Password install their manifests
    /// only for browsers they know.
    public static func defaultFolders(home: URL) -> [URL] {
        [
            home.appending(path: "Library/Application Support/Chord/NativeMessagingHosts"),
            home.appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts"),
            URL(filePath: "/Library/Google/Chrome/NativeMessagingHosts"),
        ]
    }

    /// True when `name` is a valid host name: lowercase letters, digits,
    /// underscores, and dots, with no dot at either end and no two dots together.
    /// This also keeps the name from naming a file outside the folders.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasSuffix("."), !name.contains("..") else { return false }
        return name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "." }
    }

    /// The manifest for `name` that lets `origin` start its app.
    public static func manifest(named name: String, for origin: String, in folders: [URL]) throws -> NativeMessagingHostManifest {
        guard isValidName(name) else { throw LookupError.invalidName(name) }
        for folder in folders {
            let file = folder.appending(path: "\(name).json")
            guard let data = try? Data(contentsOf: file) else { continue }
            guard let manifest = try? JSONDecoder().decode(NativeMessagingHostManifest.self, from: data),
                  manifest.name == name, manifest.type == "stdio", manifest.path.hasPrefix("/") else {
                throw LookupError.invalidManifest(file.path)
            }
            guard manifest.allows(origin: origin) else {
                throw LookupError.originNotAllowed(name: name, origin: origin)
            }
            return manifest
        }
        throw LookupError.notFound(name)
    }
}

/// The ID Chrome gives an extension, which names it in host manifests.
public enum ChromeExtensionID {
    /// The origin Chrome uses for the extension with this ID.
    public static func origin(for id: String) -> String {
        "chrome-extension://\(id)/"
    }

    /// The ID of the unpacked extension in `folder`, or nil when it has none.
    ///
    /// The ID comes from the manifest's `key`, as Chrome computes it for an
    /// unpacked extension. A folder unpacked from the Chrome Web Store has no
    /// `key`, so the ID then comes from the store's `_metadata/verified_contents.json`.
    /// Neither source proves where the folder came from; as in Chrome, an
    /// unpacked extension is trusted because the user chose to add it.
    public static func id(forExtensionFolder folder: URL) -> String? {
        if let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = manifest["key"] as? String,
           let id = id(forPublicKey: key) {
            return id
        }
        if let data = try? Data(contentsOf: folder.appending(path: "_metadata/verified_contents.json")) {
            return storeID(fromVerifiedContents: data)
        }
        return nil
    }

    /// Chrome's ID for a base64 public key: the first 16 bytes of its SHA-256
    /// hash, with each hex digit 0 to f written as a letter a to p.
    public static func id(forPublicKey base64Key: String) -> String? {
        guard let key = Data(base64Encoded: base64Key, options: .ignoreUnknownCharacters), !key.isEmpty else { return nil }
        let digest = SHA256.hash(data: key)
        let letters = Array("abcdefghijklmnop")
        var id = ""
        for byte in digest.prefix(16) {
            id.append(letters[Int(byte >> 4)])
            id.append(letters[Int(byte & 0x0f)])
        }
        return id
    }

    /// The `item_id` in a Chrome Web Store `verified_contents.json`.
    static func storeID(fromVerifiedContents data: Data) -> String? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let signed = entries.first?["signed_content"] as? [String: Any],
              var payload = signed["payload"] as? String else { return nil }
        // The payload is base64url without padding.
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let contents = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let id = contents["item_id"] as? String, isValid(id) else { return nil }
        return id
    }

    /// True when `id` has the form of a Chrome extension ID: 32 letters from a to p.
    public static func isValid(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }
}
