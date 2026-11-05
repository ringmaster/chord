import AppKit
import Observation
import Security
import SwiftUI
import chord_logic

/// Stores secrets, such as API keys, in the login Keychain under Chord's name.
enum Keychain {
    private static let service = "net.asymptomatic.Chord"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value`, or deletes the item when `value` is nil. Returns false on failure.
    @discardableResult
    static func write(_ account: String, _ value: String?) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard let value else { return true }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// The connection to Karakeep: the server address from settings and the API
/// key from the Keychain. `service` is nil until both are set.
@MainActor
@Observable
final class Bookmarking {
    private static let keyAccount = "karakeep-api-key"

    private(set) var service: (any BookmarkService)?
    private(set) var server: URL?
    @ObservationIgnored private let library: Library

    init(library: Library) {
        self.library = library
        // `--args -ChordKarakeepServer URL -ChordKarakeepKey KEY` uses that
        // server for this launch only, saving nothing, for testing.
        let defaults = UserDefaults.standard
        if let testServer = defaults.string(forKey: "ChordKarakeepServer").flatMap(URL.init(string:)),
           let testKey = defaults.string(forKey: "ChordKarakeepKey") {
            server = testServer
            rebuild(apiKey: testKey)
            return
        }
        server = (try? library.database.setting(.karakeepServer)).flatMap(URL.init(string:))
        rebuild(apiKey: Keychain.read(Self.keyAccount))
    }

    var isConnected: Bool { service != nil }

    /// Checks the address and key with the server, then saves them.
    func connect(server: URL, apiKey: String) async throws {
        let candidate = KarakeepService(server: server, apiKey: apiKey)
        try await candidate.verify()
        guard Keychain.write(Self.keyAccount, apiKey) else {
            throw BookmarkServiceError.network("The API key could not be saved in the Keychain.")
        }
        try? library.database.setSetting(.karakeepServer, to: server.absoluteString)
        self.server = server
        service = candidate
    }

    func disconnect() {
        Keychain.write(Self.keyAccount, nil)
        try? library.database.setSetting(.karakeepServer, to: nil)
        server = nil
        service = nil
    }

    private func rebuild(apiKey: String?) {
        guard let server, let apiKey, !apiKey.isEmpty else {
            service = nil
            return
        }
        service = KarakeepService(server: server, apiKey: apiKey)
    }
}

/// The sheet that connects Chord to a Karakeep server.
struct KarakeepConnectView: View {
    let bookmarking: Bookmarking
    let onDone: () -> Void
    @State private var address = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Icon("bookmark-filled", size: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Karakeep").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Save pages to Karakeep and find your bookmarks in the command palette.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            LabeledField(label: "Server", text: $address, prompt: "https://karakeep.example.com", secure: false)
            LabeledField(label: "API key", text: $apiKey, prompt: "From Settings > API Keys in Karakeep", secure: true)
            if let problem {
                Label { Text(problem) } icon: { Icon("alert-triangle-filled", size: 15) }
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            HStack {
                if bookmarking.isConnected {
                    Button("Disconnect") {
                        bookmarking.disconnect()
                        onDone()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(checking ? "Checking…" : "Connect", action: connect)
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || address.isEmpty || apiKey.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { address = bookmarking.server?.absoluteString ?? "" }
    }

    private func connect() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let server = URL(string: text), server.host() != nil else {
            problem = "Enter the server's address, such as https://karakeep.example.com."
            return
        }
        checking = true
        problem = nil
        Task {
            do {
                try await bookmarking.connect(server: server, apiKey: apiKey.trimmingCharacters(in: .whitespaces))
                onDone()
            } catch BookmarkServiceError.unauthorized {
                problem = "Karakeep refused this API key."
            } catch {
                problem = "Could not reach Karakeep: \(error.localizedDescription)"
            }
            checking = false
        }
    }
}

/// A label above a rounded text field, styled to match Chord.
private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    let secure: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(prompt))
                } else {
                    TextField("", text: $text, prompt: Text(prompt))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        }
    }
}

/// A short message that fades in at the bottom of a window, then away.
struct ToastView: View {
    let text: String
    let symbol: String
    @State private var shown = false

    var body: some View {
        Label { Text(text) } icon: { Icon(symbol, size: 16) }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .glassEffect(.regular, in: Capsule())
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 28)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.spring(duration: 0.3)) { shown = true } }
    }
}
