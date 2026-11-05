import Foundation
import GRDB

extension Rule: FetchableRecord, PersistableRecord {}

extension ChordDatabase {
    /// Every rule, in the order the engine checks them.
    public func rules() throws -> [Rule] {
        try writer.read { db in
            try Rule.order(Column("position")).fetchAll(db)
        }
    }

    /// Adds a rule above the first broader rule. See `RuleEngine.insertionIndex`.
    @discardableResult
    public func addRule(matcher: URLMatcher, actions: RuleActions, enabled: Bool = true) throws -> Rule {
        try writer.write { db in
            var ordered = try Rule.order(Column("position")).fetchAll(db)
            let index = RuleEngine.insertionIndex(for: matcher, in: ordered)
            let rule = Rule(position: index, enabled: enabled, matcher: matcher, actions: actions)
            ordered.insert(rule, at: index)
            try Self.renumber(ordered, db)
            return rule
        }
    }

    /// Saves changes to a rule's matcher, actions, or enabled state. The
    /// position is kept; use `moveRule` to change it.
    public func updateRule(_ rule: Rule) throws {
        try writer.write { db in
            guard let stored = try Rule.fetchOne(db, key: rule.id) else {
                throw RuleError.ruleNotFound(rule.id)
            }
            var updated = rule
            updated.position = stored.position
            try updated.update(db)
        }
    }

    public func deleteRule(id: UUID) throws {
        try writer.write { db in
            _ = try Rule.deleteOne(db, key: id)
            try Self.renumber(try Rule.order(Column("position")).fetchAll(db), db)
        }
    }

    /// Moves a rule to `index` in the list. An index past the end moves it last.
    public func moveRule(id: UUID, to index: Int) throws {
        try writer.write { db in
            var ordered = try Rule.order(Column("position")).fetchAll(db)
            guard let from = ordered.firstIndex(where: { $0.id == id }) else {
                throw RuleError.ruleNotFound(id)
            }
            let rule = ordered.remove(at: from)
            ordered.insert(rule, at: max(0, min(index, ordered.count)))
            try Self.renumber(ordered, db)
        }
    }

    /// Writes positions 0, 1, 2… in the given order.
    private static func renumber(_ ordered: [Rule], _ db: Database) throws {
        for (index, var rule) in ordered.enumerated() {
            rule.position = index
            try rule.save(db)
        }
    }
}

public enum RuleError: Error, Equatable {
    case ruleNotFound(UUID)
}
