import Foundation
import GRDB

extension ChordDatabase {
    /// The most page action tasks kept. Older ones are removed.
    public static let maximumAgentTasks = 200

    /// Records that the user ran `text` as a page action. The same text keeps
    /// one row; its count goes up and its time is replaced.
    public func recordAgentTask(_ text: String, at date: Date = Date()) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try writer.write { db in
            if var entry = try AgentTaskEntry.filter(Column("text") == text).fetchOne(db) {
                entry.useCount += 1
                entry.lastUsedAt = date
                try entry.update(db)
            } else {
                var entry = AgentTaskEntry(text: text, useCount: 1, lastUsedAt: date)
                try entry.insert(db)
            }
            let old = try AgentTaskEntry.order(Column("lastUsedAt").desc)
                .limit(-1, offset: Self.maximumAgentTasks).fetchAll(db)
            for entry in old {
                _ = try entry.delete(db)
            }
        }
    }

    /// Page action tasks, the most recently used first.
    public func recentAgentTasks(limit: Int = 50) throws -> [String] {
        try writer.read { db in
            try AgentTaskEntry.order(Column("lastUsedAt").desc).limit(limit).fetchAll(db).map(\.text)
        }
    }
}
