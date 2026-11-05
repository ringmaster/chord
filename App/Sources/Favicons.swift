import AppKit
import Observation
import OSLog
import WebKit

/// Site icons, one per host, kept in memory and in `~/Library/Caches/Chord/Favicons`.
///
/// `image(for:)` returns the icon when it is known and starts a fetch of
/// `/favicon.ico` when it is not. When a page finishes loading, `load(for:)`
/// reads the icon the page declares, which replaces the guess.
/// Views that read `images` update when an icon arrives.
@MainActor
@Observable
final class Favicons {
    static let shared = Favicons()
    private static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "favicons")

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let directory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "Chord/Favicons")

    /// The icon for the host of `url`, or nil while none is known.
    func image(for url: URL) -> NSImage? {
        guard let host = url.host()?.lowercased() else { return nil }
        if let image = images[host] {
            return image
        }
        if !requested.contains(host) {
            requested.insert(host)
            Task { await self.fetchFallback(host: host, scheme: url.scheme ?? "https") }
        }
        return nil
    }

    /// Reads the icon that the loaded page declares and fetches it.
    func load(for webView: WKWebView) {
        guard let pageURL = webView.url, let host = pageURL.host()?.lowercased() else { return }
        let script = """
            (() => {
              const link = document.querySelector('link[rel="apple-touch-icon"]')
                || document.querySelector('link[rel~="icon"][sizes="32x32"]')
                || document.querySelector('link[rel~="icon"]');
              return link ? link.href : null;
            })()
            """
        webView.evaluateJavaScript(script) { result, _ in
            let href = result as? String
            MainActor.assumeIsolated {
                guard let href, let iconURL = URL(string: href) else { return }
                Task { await self.fetch(iconURL, host: host) }
            }
        }
    }

    private func fetchFallback(host: String, scheme: String) async {
        if let cached = readCache(host: host) {
            images[host] = cached
            return
        }
        guard let url = URL(string: "\(scheme)://\(host)/favicon.ico") else { return }
        await fetch(url, host: host)
    }

    private func fetch(_ url: URL, host: String) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data),
                  image.isValid else { return }
            images[host] = image
            writeCache(host: host, data: data)
        } catch {
            Favicons.log.debug("No icon for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cacheFile(host: String) -> URL? {
        directory?.appending(path: host)
    }

    private func readCache(host: String) -> NSImage? {
        guard let file = cacheFile(host: host), let data = try? Data(contentsOf: file) else { return nil }
        return NSImage(data: data)
    }

    private func writeCache(host: String, data: Data) {
        guard let directory, let file = cacheFile(host: host) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file)
    }
}
