import Foundation
import GRDB

extension ChordDatabase {
    /// Records one visit to `url`. A URL visited before keeps one row; its
    /// visit count goes up and its title and time are replaced.
    public func recordVisit(url: URL, title: String, at date: Date = Date()) throws {
        guard HistoryRanking.isRecordable(url) else { return }
        try writer.write { db in
            if var entry = try HistoryEntry.filter(Column("url") == url).fetchOne(db) {
                entry.visitCount += 1
                entry.lastVisitedAt = date
                if !title.isEmpty {
                    entry.title = title
                }
                try entry.update(db)
            } else {
                var entry = HistoryEntry(url: url, title: title, visitCount: 1, lastVisitedAt: date)
                try entry.insert(db)
            }
        }
    }

    /// Sets the title of a URL already in history. A page often sets its title
    /// after the navigation that recorded the visit.
    public func updateHistoryTitle(url: URL, title: String) throws {
        guard !title.isEmpty else { return }
        try writer.write { db in
            _ = try HistoryEntry.filter(Column("url") == url)
                .updateAll(db, Column("title").set(to: title))
        }
    }

    /// History entries whose title or address contain words that start with
    /// each word of `query`, best first. See `HistoryRanking` for the order.
    public func searchHistory(_ query: String, limit: Int = 8, now: Date = Date()) throws -> [HistoryEntry] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let candidates = try writer.read { db in
            try HistoryEntry.fetchAll(db, sql: """
                SELECT historyEntry.*
                FROM historyEntry
                JOIN historySearch ON historySearch.rowid = historyEntry.id
                WHERE historySearch MATCH ?
                ORDER BY historySearch.rank
                LIMIT 200
                """, arguments: [pattern])
        }
        return HistoryRanking.ranked(candidates, query: query, now: now).prefix(limit).map { $0 }
    }

    /// Removes every history entry.
    public func clearHistory() throws {
        try writer.write { db in
            _ = try HistoryEntry.deleteAll(db)
        }
    }
}

/// How history results are ordered and which URLs are recorded.
public enum HistoryRanking {
    /// Only web pages go into history.
    public static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// A score that grows with the number of visits and shrinks with the time
    /// since the last visit. The recency weight halves every seven days.
    public static func frecency(visitCount: Int, lastVisitedAt: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(lastVisitedAt) / 86_400)
        let recency = pow(0.5, days / 7)
        return log2(Double(visitCount) + 1) * (0.25 + recency)
    }

    /// Orders matches in two tiers. Entries whose host starts with the first
    /// word of the query come first, so "git" puts github.com above a page that
    /// only mentions git. Within each tier, higher frecency comes first, then
    /// the more recent visit.
    public static func ranked(_ entries: [HistoryEntry], query: String, now: Date) -> [HistoryEntry] {
        let firstWord = query.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        func hostMatches(_ entry: HistoryEntry) -> Bool {
            let host = (entry.url.host() ?? "").lowercased()
            let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return !firstWord.isEmpty && bareHost.hasPrefix(firstWord)
        }
        let scored = entries.map { entry in
            (entry: entry,
             hostMatch: hostMatches(entry),
             frecency: frecency(visitCount: entry.visitCount, lastVisitedAt: entry.lastVisitedAt, now: now))
        }
        return scored.sorted { a, b in
            if a.hostMatch != b.hostMatch { return a.hostMatch }
            if a.frecency != b.frecency { return a.frecency > b.frecency }
            return a.entry.lastVisitedAt > b.entry.lastVisitedAt
        }.map(\.entry)
    }
}
