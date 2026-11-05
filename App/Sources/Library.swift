import Foundation
import Observation
import OSLog
import chord_logic

/// The app's view of the database: the spaces, the active space's tabs, and the
/// active tab. Views read this and call its methods; it writes every change to
/// the database and then reloads what changed.
///
/// A failed database call is logged and leaves the in-memory state as it was.
@MainActor
@Observable
final class Library {
    static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "library")

    @ObservationIgnored let database: ChordDatabase

    private(set) var spaces: [Space] = []
    private(set) var contents: SpaceContents
    private(set) var activeTabID: UUID?
    private(set) var searchEngine: SearchEngine = .duckDuckGo
    /// Air Traffic Control rules, in the order the engine checks them.
    private(set) var rules: [Rule] = []
    private(set) var profiles: [Profile] = []
    var sidebarPinned: Bool {
        didSet { save(.sidebarPinned, sidebarPinned ? "1" : "0") }
    }

    var activeSpace: Space { contents.space }

    /// Every tab the sidebar shows for the active space, in sidebar order.
    var visibleTabs: [BrowserTab] { contents.favorites + contents.pinned + contents.open }

    var activeTab: BrowserTab? {
        guard let activeTabID else { return nil }
        return visibleTabs.first { $0.id == activeTabID }
    }

    init(database: ChordDatabase) throws {
        self.database = database
        let spaces = try database.spaces()
        let storedSpace = try database.setting(.activeSpaceID).flatMap(UUID.init(uuidString:))
        let space = spaces.first { $0.id == storedSpace } ?? spaces[0]
        self.spaces = spaces
        contents = try database.contents(ofSpace: space.id)
        searchEngine = try database.searchEngine()
        rules = try database.rules()
        profiles = try database.profiles()
        sidebarPinned = try database.setting(.sidebarPinned).map { $0 == "1" } ?? true
        activeTabID = mostRecentTab()?.id
    }

    // MARK: Spaces

    func selectSpace(_ id: UUID) {
        guard id != contents.space.id else { return }
        attempt("select space") {
            contents = try database.contents(ofSpace: id)
            try database.setSetting(.activeSpaceID, to: id.uuidString)
            activeTabID = mostRecentTab()?.id
        }
    }

    func createSpace(named name: String) {
        attempt("create space") {
            let space = try database.createSpace(name: name, profileID: contents.profile.id)
            spaces = try database.spaces()
            selectSpace(space.id)
        }
    }

    // MARK: Tabs

    /// Opens `url` in a new tab at the top of the active space and shows it.
    @discardableResult
    func openTab(_ url: URL, title: String = "") -> BrowserTab? {
        var opened: BrowserTab?
        attempt("open tab") {
            opened = try database.openTab(url: url, title: title, inSpace: contents.space.id)
            try reloadContents()
            activeTabID = opened?.id
        }
        return opened
    }

    func activate(_ tabID: UUID) {
        attempt("activate tab") {
            try database.activateTab(id: tabID)
            activeTabID = tabID
        }
    }

    /// Closes a tab. The next tab down becomes active, or the one above when
    /// the closed tab was last.
    func close(_ tabID: UUID) {
        attempt("close tab") {
            let order = visibleTabs.map(\.id)
            try database.closeTab(id: tabID)
            try reloadContents()
            if activeTabID == tabID {
                let index = order.firstIndex(of: tabID) ?? 0
                let remaining = visibleTabs.map(\.id)
                activeTabID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
            }
        }
    }

    func move(_ tabID: UUID, to section: TabSection) {
        attempt("move tab") {
            try database.move(tabID: tabID, to: section, inSpace: contents.space.id)
            try reloadContents()
        }
    }

    /// Records what a tab's page now shows. Called by the tab's web view.
    func pageChanged(tabID: UUID, url: URL, title: String) {
        attempt("update tab") {
            try database.updateTab(id: tabID, url: url, title: title)
            try reloadContents()
        }
    }

    // MARK: Routing

    /// What the rules decide for `url`.
    func decide(_ url: URL) -> RoutingDecision {
        RuleEngine.decide(url, rules: rules)
    }

    /// Where a URL from outside the current tab opens: a link from another
    /// app, or an address typed into the palette for a new tab.
    enum Destination: Equatable {
        case space(UUID)
        case minorChord(profileID: UUID)
    }

    /// The destination for `url`. A route to a space or profile that no
    /// longer exists falls back to the active space.
    func destination(for url: URL) -> Destination {
        switch decide(url).route {
        case .space(let id) where spaces.contains(where: { $0.id == id }):
            return .space(id)
        case .minorChord(let profileID) where profiles.contains(where: { $0.id == profileID }):
            return .minorChord(profileID: profileID)
        default:
            return .space(contents.space.id)
        }
    }

    /// Opens `url` in a new tab in `spaceID`, switching to that space first.
    @discardableResult
    func openTab(_ url: URL, inSpace spaceID: UUID) -> BrowserTab? {
        selectSpace(spaceID)
        return openTab(url)
    }

    // MARK: Rules

    @discardableResult
    func addRule(matcher: URLMatcher, actions: RuleActions) -> Rule? {
        var added: Rule?
        attempt("add rule") {
            added = try database.addRule(matcher: matcher, actions: actions)
            rules = try database.rules()
        }
        return added
    }

    func updateRule(_ rule: Rule) {
        attempt("update rule") {
            try database.updateRule(rule)
            rules = try database.rules()
        }
    }

    func deleteRule(_ id: UUID) {
        attempt("delete rule") {
            try database.deleteRule(id: id)
            rules = try database.rules()
        }
    }

    func moveRule(_ id: UUID, to index: Int) {
        attempt("move rule") {
            try database.moveRule(id: id, to: index)
            rules = try database.rules()
        }
    }

    // MARK: History

    func recordVisit(url: URL, title: String) {
        attempt("record visit") {
            try database.recordVisit(url: url, title: title)
        }
    }

    func updateHistoryTitle(url: URL, title: String) {
        attempt("update history title") {
            try database.updateHistoryTitle(url: url, title: title)
        }
    }

    func clearHistory() {
        attempt("clear history") {
            try database.clearHistory()
        }
    }

    // MARK: Settings

    func setSearchEngine(_ engine: SearchEngine) {
        attempt("set search engine") {
            try database.setSearchEngine(engine)
            searchEngine = engine
        }
    }

    // MARK: Helpers

    private func reloadContents() throws {
        contents = try database.contents(ofSpace: contents.space.id)
    }

    private func mostRecentTab() -> BrowserTab? {
        visibleTabs.max { ($0.lastActivatedAt ?? .distantPast) < ($1.lastActivatedAt ?? .distantPast) }
    }

    private func save(_ key: SettingKey, _ value: String) {
        attempt("save setting") { try database.setSetting(key, to: value) }
    }

    private func attempt(_ action: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Library.log.error("Could not \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
