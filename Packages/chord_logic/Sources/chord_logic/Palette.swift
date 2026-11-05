import Foundation

/// An action the command palette offers by name, such as "Toggle Sidebar".
/// The app decides which commands exist at the moment and runs them by `id`.
public struct PaletteCommand: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// An SF Symbol name.
    public let symbol: String
    /// Extra words that also match, such as "default" for the search engine commands.
    public let keywords: [String]
    /// The key shortcut shown beside the command, such as "⌘S".
    public let shortcut: String?

    public init(id: String, title: String, symbol: String, keywords: [String] = [], shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
        self.shortcut = shortcut
    }
}

/// One row in the command palette.
public enum PaletteItem: Equatable, Sendable {
    /// Load an address the user typed.
    case navigate(URL)
    /// Send the typed text to the search engine.
    case search(query: String, engine: SearchEngine, url: URL)
    /// Show a tab that is already open.
    case tab(BrowserTab)
    /// Load a page from history.
    case history(HistoryEntry)
    /// Load a page from the bookmark service.
    case bookmark(ServiceBookmark)
    case command(PaletteCommand)
    /// Fill a saved login into the page. These rows appear only when the
    /// palette is choosing a login.
    case login(LoginItem)
}

/// Scores how well text matches what the user typed.
public enum FuzzyMatch {
    /// A score for `query` against `candidate`, higher is better, or nil when
    /// it does not match. Matching ignores case. The tiers, best first:
    /// 1. the candidate starts with the query,
    /// 2. a word in the candidate starts with the query,
    /// 3. the candidate contains the query,
    /// 4. the query's characters appear in the candidate in order.
    /// Within a tier, a shorter candidate scores higher.
    public static func score(_ query: String, in candidate: String) -> Double? {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        let candidate = candidate.lowercased()
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        let lengthBonus = 1 / Double(candidate.count + 1)

        if candidate.hasPrefix(query) {
            return 4 + lengthBonus
        }
        let words = candidate.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(query) }) {
            return 3 + lengthBonus
        }
        if candidate.contains(query) {
            return 2 + lengthBonus
        }
        var remaining = query[...]
        for character in candidate where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty {
                return 1 + lengthBonus
            }
        }
        return nil
    }

    /// The best score among several candidate texts.
    public static func bestScore(_ query: String, in candidates: [String]) -> Double? {
        candidates.compactMap { score(query, in: $0) }.max()
    }
}

/// Builds the palette's rows for what the user typed.
public enum PaletteResults {
    /// The rows when the palette is choosing a login: every login with nothing
    /// typed, in the order given, or the logins whose title, username, or vault
    /// match, best first.
    public static func logins(query: String, logins: [LoginItem]) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return logins.map(PaletteItem.login) }
        return logins
            .compactMap { login -> (LoginItem, Double)? in
                let texts = [login.title, login.username ?? "", login.vault ?? ""]
                return FuzzyMatch.bestScore(trimmed, in: texts).map { (login, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map { PaletteItem.login($0.0) }
    }

    public static let maximumTabs = 4
    public static let maximumCommands = 4
    public static let maximumHistory = 6
    public static let maximumBookmarks = 4

    /// The rows, in this order:
    /// 1. one primary row: the typed address, or a search,
    /// 2. open tabs that match,
    /// 3. commands that match,
    /// 4. history that matches, without pages already open in a tab,
    /// 5. bookmarks from the bookmark service, without pages already listed.
    ///
    /// With nothing typed, the rows are the most recent tabs, then the commands.
    /// When the query matches a command's title from its start, commands come
    /// before tabs, so typing "tog" puts "Toggle Sidebar" near the top.
    public static func build(query: String, tabs: [BrowserTab], commands: [PaletteCommand],
                             history: [HistoryEntry], bookmarks: [ServiceBookmark] = [],
                             engine: SearchEngine) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let recent = tabs.sorted { ($0.lastActivatedAt ?? .distantPast) > ($1.lastActivatedAt ?? .distantPast) }
            return recent.prefix(maximumTabs).map(PaletteItem.tab)
                + commands.prefix(maximumCommands).map(PaletteItem.command)
        }

        var items: [PaletteItem] = []
        switch AddressInput(searchEngine: engine).resolve(trimmed) {
        case .address(let url):
            items.append(.navigate(url))
        case .search(let url):
            items.append(.search(query: trimmed, engine: engine, url: url))
        case nil:
            break
        }

        let matchingTabs = tabs
            .compactMap { tab -> (BrowserTab, Double)? in
                let texts = [tab.title, tab.url.host() ?? "", tab.url.absoluteString]
                return FuzzyMatch.bestScore(trimmed, in: texts).map { (tab, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maximumTabs)
            .map { PaletteItem.tab($0.0) }

        let matchingCommands = commands
            .compactMap { command -> (PaletteCommand, Double)? in
                FuzzyMatch.bestScore(trimmed, in: [command.title] + command.keywords).map { (command, $0) }
            }
            .sorted { $0.1 > $1.1 }
        let commandRows = matchingCommands.prefix(maximumCommands).map { PaletteItem.command($0.0) }
        let commandsLead = matchingCommands.first.map { $0.0.title.lowercased().hasPrefix(trimmed.lowercased()) } ?? false

        let openURLs = Set(tabs.map(\.url))
        let historyRows = history
            .filter { !openURLs.contains($0.url) }
            .prefix(maximumHistory)
            .map(PaletteItem.history)

        if commandsLead {
            items += commandRows + matchingTabs
        } else {
            items += matchingTabs + commandRows
        }
        let listedURLs = openURLs.union(historyRows.compactMap { item in
            if case .history(let entry) = item { return entry.url } else { return nil }
        })
        let bookmarkRows = bookmarks
            .filter { !listedURLs.contains($0.url) }
            .prefix(maximumBookmarks)
            .map(PaletteItem.bookmark)
        return items + historyRows + bookmarkRows
    }
}
