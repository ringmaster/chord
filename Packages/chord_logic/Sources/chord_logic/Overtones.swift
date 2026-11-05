import Foundation

/// A set of CSS, JavaScript, and HTML files that Chord adds to matching pages.
///
/// Each overtone is one folder in the overtones folder. The folder's name is
/// the overtone's id. A folder named like a domain ("github.com") applies to
/// that domain and its subdomains on its own. Any other folder applies only
/// where an Air Traffic Control rule names it.
///
/// Inside the folder, files are used in name order:
/// - `*.css` is added as a style sheet when the page starts loading,
/// - `*.html` is added at the end of the page body when the page has loaded,
/// - `*.js` runs when the page has loaded, after the HTML is in place.
/// Other files are ignored. Names that start with "." are skipped.
public struct Overtone: Equatable, Sendable, Identifiable {
    public var id: String
    /// The domain the overtone applies to on its own, or nil for a rule-only overtone.
    public var domain: String?
    public var styles: [String]
    public var scripts: [String]
    public var html: [String]

    public init(id: String, domain: String?, styles: [String] = [], scripts: [String] = [], html: [String] = []) {
        self.id = id
        self.domain = domain
        self.styles = styles
        self.scripts = scripts
        self.html = html
    }

    /// Whether the overtone applies to `url` on its own, by its domain.
    public func appliesByDomain(to url: URL) -> Bool {
        guard let domain else { return false }
        return URLMatcher(scope: .domain, value: domain).matches(url)
    }
}

public enum OvertoneLibrary {
    /// Reads every overtone in `folder`. A missing folder gives no overtones.
    /// A file that cannot be read as UTF-8 text is skipped.
    public static func load(from folder: URL) -> [Overtone] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { load(overtoneAt: $0) }
    }

    static func load(overtoneAt folder: URL) -> Overtone {
        let id = folder.lastPathComponent
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        func texts(_ fileExtension: String) -> [String] {
            files.filter { $0.pathExtension.lowercased() == fileExtension }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        let looksLikeDomain = id.contains(".") && !id.hasPrefix(".") && !id.hasSuffix(".")
            && URLMatcher(scope: .domain, value: id).isValid
        return Overtone(id: id, domain: looksLikeDomain ? id.lowercased() : nil,
                        styles: texts("css"), scripts: texts("js"), html: texts("html"))
    }

    /// The overtones for `url`: those that apply by domain, then those that
    /// matching rules name, without repeats. Unknown ids are ignored.
    public static func applicable(to url: URL, overtones: [Overtone], ruleOvertoneIDs: [String]) -> [Overtone] {
        var result = overtones.filter { $0.appliesByDomain(to: url) }
        for id in ruleOvertoneIDs where !result.contains(where: { $0.id == id }) {
            if let overtone = overtones.first(where: { $0.id == id }) {
                result.append(overtone)
            }
        }
        return result
    }
}

/// Builds the JavaScript that puts an overtone's files into a page. Text from
/// the files is embedded as JSON string literals, so quotes and line breaks in
/// it cannot end the script early.
public enum OvertoneScript {
    /// Adds the overtone's style sheets. Runs when the page starts loading.
    public static func styles(for overtone: Overtone) -> String? {
        guard !overtone.styles.isEmpty else { return nil }
        return """
            (() => {
              const style = document.createElement('style');
              style.dataset.chordOvertone = \(literal(overtone.id));
              style.textContent = \(literal(overtone.styles.joined(separator: "\n")));
              (document.head || document.documentElement).appendChild(style);
            })();
            """
    }

    /// Adds the overtone's HTML at the end of the body, then runs its scripts.
    /// Runs when the page has loaded.
    public static func body(for overtone: Overtone) -> String? {
        guard !overtone.html.isEmpty || !overtone.scripts.isEmpty else { return nil }
        var parts: [String] = []
        if !overtone.html.isEmpty {
            parts.append("""
                (() => {
                  const holder = document.createElement('div');
                  holder.dataset.chordOvertone = \(literal(overtone.id));
                  holder.innerHTML = \(literal(overtone.html.joined(separator: "\n")));
                  document.body.appendChild(holder);
                })();
                """)
        }
        // Each script runs in its own function, so one script's names do not
        // clash with another's.
        parts.append(contentsOf: overtone.scripts.map { "(() => {\n\($0)\n})();" })
        return parts.joined(separator: "\n")
    }

    /// A JavaScript string literal for `text`.
    static func literal(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
