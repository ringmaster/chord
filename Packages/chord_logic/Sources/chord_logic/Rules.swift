import Foundation

/// Which URLs a rule applies to.
public struct URLMatcher: Codable, Equatable, Hashable, Sendable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// Only this host. "www." is ignored on both sides.
        case host
        /// This domain and every subdomain of it.
        case domain
        /// A regular expression tested against the whole URL.
        case pattern
    }

    public var scope: Scope
    /// A host or domain such as "datadoghq.com", or a regular expression when
    /// `scope` is `.pattern`.
    public var value: String
    /// Limits a host or domain match to paths that start with this path, at a
    /// "/" boundary. "/docs" matches "/docs" and "/docs/x", not "/docsearch".
    /// Ignored when `scope` is `.pattern`.
    public var pathPrefix: String?

    public init(scope: Scope, value: String, pathPrefix: String? = nil) {
        self.scope = scope
        self.value = value
        self.pathPrefix = pathPrefix
    }

    public func matches(_ url: URL) -> Bool {
        switch scope {
        case .pattern:
            guard let regex = try? Regex(value).ignoresCase() else { return false }
            return url.absoluteString.contains(regex)
        case .host, .domain:
            guard let host = url.host()?.lowercased() else { return false }
            let target = URLMatcher.bareHost(value.lowercased())
            let actual = URLMatcher.bareHost(host)
            let hostMatches = scope == .host
                ? actual == target
                : actual == target || actual.hasSuffix("." + target)
            return hostMatches && pathMatches(url.path())
        }
    }

    private func pathMatches(_ path: String) -> Bool {
        guard var prefix = pathPrefix, !prefix.isEmpty, prefix != "/" else { return true }
        if !prefix.hasPrefix("/") { prefix = "/" + prefix }
        if prefix.hasSuffix("/") { prefix.removeLast() }
        return path == prefix || path.hasPrefix(prefix + "/")
    }

    /// How narrow the matcher is. Higher is narrower. A new rule is placed
    /// above broader rules, so narrower rules win unless the user reorders them.
    public var specificity: Int {
        let pathBonus = (pathPrefix?.isEmpty == false && pathPrefix != "/") ? 100 : 0
        switch scope {
        case .pattern:
            return 0
        case .domain:
            return 10 + URLMatcher.bareHost(value).split(separator: ".").count + pathBonus
        case .host:
            return 50 + URLMatcher.bareHost(value).split(separator: ".").count + pathBonus
        }
    }

    /// Whether the matcher can match anything. An empty value or an invalid
    /// pattern cannot.
    public var isValid: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if scope == .pattern {
            return (try? Regex(trimmed)) != nil
        }
        return !trimmed.contains(where: { $0.isWhitespace || $0 == "/" })
    }

    /// A domain matcher for the site of `url`, for a rule made from a page.
    /// It keeps the last two labels of the host ("app.datadoghq.com" gives
    /// "datadoghq.com"), or three when the last two look like a country
    /// suffix such as "co.uk". It returns nil for a URL with no host.
    public static func suggested(for url: URL) -> URLMatcher? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let labels = bareHost(host).split(separator: ".")
        guard labels.count > 2 else {
            return URLMatcher(scope: .domain, value: bareHost(host))
        }
        let last = labels[labels.count - 1]
        let secondLast = labels[labels.count - 2]
        let keep = (last.count == 2 && secondLast.count <= 3) ? 3 : 2
        return URLMatcher(scope: .domain, value: labels.suffix(keep).joined(separator: "."))
    }

    static func bareHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Where a matching URL opens.
public enum Route: Codable, Equatable, Hashable, Sendable {
    /// A tab in this space of the main window. The space's profile applies.
    case space(UUID)
    /// A Minor Chord window that uses this profile.
    case minorChord(profileID: UUID)
}

/// What a rule does to the URLs it matches. Each part is optional; a rule
/// without a route can still, for example, apply overtones.
public struct RuleActions: Codable, Equatable, Hashable, Sendable {
    public var route: Route?
    /// The ids of overtones to inject into matching pages.
    public var overtones: [String]

    public init(route: Route? = nil, overtones: [String] = []) {
        self.route = route
        self.overtones = overtones
    }
}

/// One Air Traffic Control rule.
public struct Rule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The rule's place in the list. Lower positions are checked first.
    public var position: Int
    public var enabled: Bool
    public var matcher: URLMatcher
    public var actions: RuleActions

    public init(id: UUID = UUID(), position: Int = 0, enabled: Bool = true,
                matcher: URLMatcher, actions: RuleActions) {
        self.id = id
        self.position = position
        self.enabled = enabled
        self.matcher = matcher
        self.actions = actions
    }
}

/// What the rules decide for one URL, and which rule decided each part.
public struct RoutingDecision: Equatable, Sendable {
    public var route: Route?
    /// The rule that set `route`.
    public var routeRuleID: UUID?
    /// Overtones from every matching rule, in rule order, without repeats.
    public var overtones: [String]
    /// Every enabled rule that matched, in rule order.
    public var matchedRuleIDs: [UUID]

    public static let none = RoutingDecision(route: nil, routeRuleID: nil, overtones: [], matchedRuleIDs: [])
}

public enum RuleEngine {
    /// Checks the enabled rules in position order. The first matching rule
    /// that has a route sets the route. Overtones come from every matching rule.
    public static func decide(_ url: URL, rules: [Rule]) -> RoutingDecision {
        var decision = RoutingDecision.none
        for rule in rules.sorted(by: { $0.position < $1.position })
        where rule.enabled && rule.matcher.isValid && rule.matcher.matches(url) {
            decision.matchedRuleIDs.append(rule.id)
            if decision.route == nil, let route = rule.actions.route {
                decision.route = route
                decision.routeRuleID = rule.id
            }
            for overtone in rule.actions.overtones where !decision.overtones.contains(overtone) {
                decision.overtones.append(overtone)
            }
        }
        return decision
    }

    /// The position for a new rule: above the first existing rule that is
    /// broader, so narrower rules are checked first.
    public static func insertionIndex(for matcher: URLMatcher, in rules: [Rule]) -> Int {
        let ordered = rules.sorted { $0.position < $1.position }
        return ordered.firstIndex { $0.matcher.specificity < matcher.specificity } ?? ordered.count
    }
}
