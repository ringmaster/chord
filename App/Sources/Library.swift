import Foundation
import Observation
import OSLog
import chord_logic

/// The app's shared view of the database: spaces, every space's tabs, rules,
/// and settings. All Major Chord windows read the same library, so they show
/// the same tabs. Which space and tab a window shows is kept per window in
/// `WindowState`.
///
/// Views read this and call its methods; each method writes to the database
/// and then reloads. A failed database call is logged and leaves the
/// in-memory state as it was.
@MainActor
@Observable
final class Library {
    static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "library")

    @ObservationIgnored let database: ChordDatabase

    private(set) var spaces: [Space] = []
    /// What the sidebar shows for each space, by space id.
    private(set) var contentsBySpace: [UUID: SpaceContents] = [:]
    private(set) var searchEngine: SearchEngine = .duckDuckGo
    /// Air Traffic Control rules, in the order the engine checks them.
    private(set) var rules: [Rule] = []
    private(set) var profiles: [Profile] = []
    /// The space used most recently in any window. A new window starts here.
    private(set) var lastSpaceID: UUID
    var sidebarPinned: Bool {
        didSet { save(.sidebarPinned, sidebarPinned ? "1" : "0") }
    }

    /// Every tab in every space, group members included, without repeats.
    var allTabs: [BrowserTab] {
        var seen: Set<UUID> = []
        return contentsBySpace.values
            .flatMap { $0.favorites + $0.pinned + $0.open + $0.members.values.flatMap { $0 } }
            .filter { seen.insert($0.id).inserted }
    }

    /// Every tab group, in space order.
    var groups: [BrowserTab] {
        spaces.flatMap { space in
            (contentsBySpace[space.id].map { $0.pinned + $0.open } ?? []).filter(\.isGroup)
        }
    }

    init(database: ChordDatabase) throws {
        self.database = database
        let spaces = try database.spaces()
        let storedSpace = try database.setting(.activeSpaceID).flatMap(UUID.init(uuidString:))
        self.spaces = spaces
        lastSpaceID = spaces.first { $0.id == storedSpace }?.id ?? spaces[0].id
        searchEngine = try database.searchEngine()
        rules = try database.rules()
        profiles = try database.profiles()
        sidebarPinned = try database.setting(.sidebarPinned).map { $0 == "1" } ?? true
        try reloadAll()
    }

    /// The contents of a space, or nil when the space does not exist.
    func contents(of spaceID: UUID) -> SpaceContents? {
        contentsBySpace[spaceID]
    }

    // MARK: Spaces

    /// Records that a window now shows `spaceID`, so the next window starts there.
    func noteSpaceUsed(_ spaceID: UUID) {
        guard spaceID != lastSpaceID else { return }
        lastSpaceID = spaceID
        save(.activeSpaceID, spaceID.uuidString)
    }

    @discardableResult
    func createSpace(named name: String, profileID: UUID) -> Space? {
        var created: Space?
        attempt("create space") {
            created = try database.createSpace(name: name, profileID: profileID)
            try reloadAll()
        }
        return created
    }

    // MARK: Tabs

    /// Opens `url` in a new tab at the top of a space's open tabs.
    @discardableResult
    func openTab(_ url: URL, title: String = "", inSpace spaceID: UUID) -> BrowserTab? {
        var opened: BrowserTab?
        attempt("open tab") {
            opened = try database.openTab(url: url, title: title, inSpace: spaceID)
            try reloadAll()
        }
        return opened
    }

    /// Records when a tab was last shown, so a window that opens a space shows
    /// its most recent tab.
    func activate(_ tabID: UUID) {
        attempt("activate tab") {
            try database.activateTab(id: tabID)
            try reloadAll()
        }
    }

    func close(_ tabID: UUID) {
        attempt("close tab") {
            try database.closeTab(id: tabID)
            try reloadAll()
        }
    }

    func move(_ tabID: UUID, to section: TabSection, inSpace spaceID: UUID) {
        attempt("move tab") {
            try database.move(tabID: tabID, to: section, inSpace: spaceID)
            try reloadAll()
        }
    }

    @discardableResult
    func openTab(_ url: URL, inGroup groupID: UUID) -> BrowserTab? {
        var opened: BrowserTab?
        attempt("open tab in group") {
            opened = try database.openTab(url: url, inGroup: groupID)
            try reloadAll()
        }
        return opened
    }

    func makeGroup(_ tabID: UUID, matcher: URLMatcher) {
        attempt("make group") {
            try database.makeGroup(tabID: tabID, matcher: matcher)
            try reloadAll()
        }
    }

    func setGroupMatcher(_ tabID: UUID, matcher: URLMatcher) {
        attempt("change group matcher") {
            try database.setGroupMatcher(tabID: tabID, matcher: matcher)
            try reloadAll()
        }
    }

    func ungroup(_ tabID: UUID) {
        attempt("ungroup") {
            try database.ungroup(tabID: tabID)
            try reloadAll()
        }
    }

    /// Records what a tab's page now shows. Called by the tab's web view.
    func pageChanged(tabID: UUID, url: URL, title: String) {
        attempt("update tab") {
            try database.updateTab(id: tabID, url: url, title: title)
            try reloadAll()
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

    /// The destination for `url`. With no route, or a route to a space or
    /// profile that no longer exists, the link opens in `fallbackSpace`.
    func destination(for url: URL, fallbackSpace: UUID) -> Destination {
        switch decide(url).route {
        case .space(let id) where spaces.contains(where: { $0.id == id }):
            return .space(id)
        case .minorChord(let profileID) where profiles.contains(where: { $0.id == profileID }):
            return .minorChord(profileID: profileID)
        default:
            return .space(fallbackSpace)
        }
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

    private func reloadAll() throws {
        spaces = try database.spaces()
        profiles = try database.profiles()
        var contents: [UUID: SpaceContents] = [:]
        for space in spaces {
            contents[space.id] = try database.contents(ofSpace: space.id)
        }
        contentsBySpace = contents
        if !spaces.contains(where: { $0.id == lastSpaceID }), let first = spaces.first {
            lastSpaceID = first.id
        }
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

/// Which space and tab one Major Chord window shows. Every window has its own,
/// and all of them read the same `Library`.
@MainActor
@Observable
final class WindowState {
    let library: Library
    private(set) var spaceID: UUID
    private(set) var activeTabID: UUID?

    /// With `showRecentTab`, the window starts on the space's most recent tab.
    /// Without it, the window starts with no tab, ready for a new one.
    init(library: Library, spaceID: UUID, showRecentTab: Bool) {
        self.library = library
        self.spaceID = library.contents(of: spaceID) == nil ? library.lastSpaceID : spaceID
        activeTabID = showRecentTab ? mostRecentTab()?.id : nil
    }

    /// The window's space. When the space was deleted, the library's last space.
    var contents: SpaceContents {
        library.contents(of: spaceID) ?? library.contents(of: library.lastSpaceID)!
    }

    var space: Space { contents.space }

    /// Every tab in this window's space, in sidebar order, with each group's
    /// members after the group.
    var visibleTabs: [BrowserTab] {
        let contents = contents
        return contents.favorites + (contents.pinned + contents.open).flatMap { tab in
            [tab] + (contents.members[tab.id] ?? [])
        }
    }

    /// The group whose strip shows the active tab, if any.
    var activeGroup: BrowserTab? {
        activeTabID.flatMap { contents.group(containing: $0) }
    }

    var activeTab: BrowserTab? {
        guard let activeTabID else { return nil }
        return visibleTabs.first { $0.id == activeTabID }
    }

    func selectSpace(_ id: UUID) {
        guard id != spaceID, library.contents(of: id) != nil else { return }
        spaceID = id
        library.noteSpaceUsed(id)
        activeTabID = mostRecentTab()?.id
    }

    func createSpace(named name: String) {
        if let space = library.createSpace(named: name, profileID: contents.profile.id) {
            selectSpace(space.id)
        }
    }

    func activate(_ tabID: UUID) {
        activeTabID = tabID
        library.activate(tabID)
    }

    /// Opens `url` in a new tab in this window's space and shows it. When a
    /// group in the space matches `url`, the tab opens in that group's strip.
    @discardableResult
    func openTab(_ url: URL) -> BrowserTab? {
        if let group = contents.group(for: url) {
            return openTab(url, inGroup: group.id)
        }
        guard let tab = library.openTab(url, inSpace: spaceID) else { return nil }
        activeTabID = tab.id
        return tab
    }

    /// Opens `url` at the end of a group's strip and shows it.
    @discardableResult
    func openTab(_ url: URL, inGroup groupID: UUID) -> BrowserTab? {
        guard let tab = library.openTab(url, inGroup: groupID) else { return nil }
        activeTabID = tab.id
        return tab
    }

    /// Shows a group: the strip tab used most recently.
    func activateGroup(_ groupID: UUID) {
        let strip = contents.strip(ofGroup: groupID)
        let recent = strip.max { ($0.lastActivatedAt ?? .distantPast) < ($1.lastActivatedAt ?? .distantPast) }
        activate(recent?.id ?? groupID)
    }

    /// Closes a tab. When it was the active tab, a neighbor becomes active: in
    /// a group's strip, the tab to its left; elsewhere, the next tab down, or
    /// the one above when the closed tab was last.
    func close(_ tabID: UUID) {
        let group = contents.group(containing: tabID)
        let strip = group.map { contents.strip(ofGroup: $0.id).map(\.id) } ?? []
        let order = visibleTabs.map(\.id)
        library.close(tabID)
        guard activeTabID == tabID else { return }
        if let group, group.id != tabID, let index = strip.firstIndex(of: tabID) {
            activeTabID = strip[max(0, index - 1)]
        } else {
            activeTabID = neighbor(of: tabID, in: order)
        }
    }

    func move(_ tabID: UUID, to section: TabSection) {
        library.move(tabID, to: section, inSpace: spaceID)
    }

    /// Picks another tab when the active tab was closed in another window, and
    /// follows the space when it was deleted.
    func reconcile() {
        if library.contents(of: spaceID) == nil {
            spaceID = library.lastSpaceID
            activeTabID = mostRecentTab()?.id
        } else if let activeTabID, !visibleTabs.contains(where: { $0.id == activeTabID }) {
            self.activeTabID = mostRecentTab()?.id
        }
    }

    private func neighbor(of tabID: UUID, in order: [UUID]) -> UUID? {
        let remaining = visibleTabs.map(\.id)
        guard !remaining.isEmpty else { return nil }
        let index = order.firstIndex(of: tabID) ?? 0
        return remaining[min(index, remaining.count - 1)]
    }

    private func mostRecentTab() -> BrowserTab? {
        guard library.contents(of: spaceID) != nil || library.contents(of: library.lastSpaceID) != nil else {
            return nil
        }
        return visibleTabs.max { ($0.lastActivatedAt ?? .distantPast) < ($1.lastActivatedAt ?? .distantPast) }
    }
}
