import AppKit

/// Asks macOS to make Chord the default web browser. macOS shows its own
/// confirmation dialog, and the user can decline it.
@MainActor
enum DefaultBrowser {
    static func request() {
        let app = Bundle.main.bundleURL
        Task {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
            } catch {
                AppDelegate.log.notice("Default browser not changed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Whether Chord is the default handler for https.
    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            return false
        }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
}
