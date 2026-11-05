import Foundation

/// Decides what happens when the user clicks a link inside a page.
///
/// Most clicks load in place. A click is handed to Air Traffic Control only
/// when the link goes to a different site and the rules want it somewhere
/// else. Redirects, form submissions, and navigation started by scripts never
/// reach this type, so sign-in flows keep working; the caller checks that.
public enum LinkRouting {
    /// Where the page that holds the link is.
    public struct Context: Equatable, Sendable {
        /// The space of the tab, or nil in a Minor Chord window.
        public var spaceID: UUID?
        /// The group whose strip holds the tab, if any.
        public var groupID: UUID?

        public init(spaceID: UUID?, groupID: UUID?) {
            self.spaceID = spaceID
            self.groupID = groupID
        }

        public var isMinorChord: Bool { spaceID == nil }
    }

    public enum Action: Equatable, Sendable {
        /// Load the link where it was clicked.
        case stay
        /// Open the link in this group's strip.
        case openInGroup(UUID)
        /// Open the link in a Minor Chord window with this profile.
        case openMinorChord(profileID: UUID)
        /// Open the link in a tab in this space.
        case openInSpace(UUID)
    }

    /// The action for a click on a link to `target` from a page at `source`.
    ///
    /// - `groupFor` returns the group in a space that takes a URL, if any.
    ///
    /// The order of checks:
    /// 1. A link to the same site stays.
    /// 2. In a Major Chord window, a group in the tab's space that takes the
    ///    link wins, unless the tab is already in that group.
    /// 3. A rule's route applies when it differs from where the tab is.
    /// 4. Otherwise the link stays.
    public static func action(source: URL, target: URL, context: Context, rules: [Rule],
                              groupFor: (URL, UUID) -> UUID?) -> Action {
        guard let sourceSite = site(of: source), let targetSite = site(of: target),
              sourceSite != targetSite else {
            return .stay
        }

        if let spaceID = context.spaceID, let groupID = groupFor(target, spaceID) {
            return groupID == context.groupID ? .stay : .openInGroup(groupID)
        }

        switch RuleEngine.decide(target, rules: rules).route {
        case .minorChord(let profileID):
            return context.isMinorChord ? .stay : .openMinorChord(profileID: profileID)
        case .space(let spaceID):
            guard spaceID != context.spaceID else { return .stay }
            if let groupID = groupFor(target, spaceID) {
                return .openInGroup(groupID)
            }
            return .openInSpace(spaceID)
        case nil:
            return .stay
        }
    }

    /// The site of a URL: its domain without subdomains, as `URLMatcher.suggested` reads it.
    public static func site(of url: URL) -> String? {
        URLMatcher.suggested(for: url)?.value
    }
}

/// The address a `chord://` link carries.
public enum ChordLink: Equatable, Sendable {
    /// `chord://minor?url=…`: open the URL in a new Minor Chord window.
    case minor(URL)

    /// Reads a `chord://` URL. Only http and https targets are accepted.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "chord",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "minor",
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: value),
              HistoryRanking.isRecordable(target) else {
            return nil
        }
        self = .minor(target)
    }
}
