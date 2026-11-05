import AppKit
import WebKit
import chord_logic

/// The live web view for one tab, created the first time the tab is shown.
///
/// It reports page changes to the library: the address and title go to the
/// tab, and each finished navigation goes to history. Links that open a new
/// window open a new tab instead.
@MainActor
final class TabSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let tabID: UUID
    let webView: WKWebView
    private weak var library: Library?
    private weak var sessions: TabSessions?
    private var observations: [NSKeyValueObservation] = []

    init(tabID: UUID, configuration: WKWebViewConfiguration, library: Library, sessions: TabSessions) {
        self.tabID = tabID
        self.library = library
        self.sessions = sessions
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Web Inspector opens from Safari's Develop menu for now. A docked
        // inspector pane is a later task.
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.titleChanged() }
            },
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reportPage() }
            },
        ]
    }

    private func reportPage() {
        guard let url = webView.url, let library else { return }
        library.pageChanged(tabID: tabID, url: url, title: webView.title ?? "")
    }

    private func titleChanged() {
        reportPage()
        if let url = webView.url, let title = webView.title {
            library?.updateHistoryTitle(url: url, title: title)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        library?.recordVisit(url: url, title: webView.title ?? "")
        Favicons.shared.load(for: webView)
    }

    // MARK: WKUIDelegate

    /// A link with target="_blank", or window.open, opens a new tab. WebKit
    /// requires the new web view to use the configuration it passes here.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let library, let sessions,
              let tab = library.openTab(navigationAction.request.url ?? URL(string: "about:blank")!) else {
            return nil
        }
        return sessions.adopt(tabID: tab.id, configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        library?.close(tabID)
    }
}

/// Every live tab session, and the website data store of each profile.
@MainActor
final class TabSessions {
    private let library: Library
    private var sessions: [UUID: TabSession] = [:]
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    init(library: Library) {
        self.library = library
    }

    /// The session for `tab`. A new session loads the tab's address.
    func session(for tab: BrowserTab) -> TabSession {
        if let existing = sessions[tab.id] {
            return existing
        }
        let session = adopt(tabID: tab.id, configuration: configuration(forProfile: tab.profileID))
        session.webView.load(URLRequest(url: tab.url))
        return session
    }

    /// Makes a session from a configuration WebKit gave for a new window.
    func adopt(tabID: UUID, configuration: WKWebViewConfiguration) -> TabSession {
        let session = TabSession(tabID: tabID, configuration: configuration, library: library, sessions: self)
        sessions[tabID] = session
        return session
    }

    /// Ends sessions whose tabs were closed or moved to a different profile.
    func prune(keeping tabs: [BrowserTab]) {
        let kept = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.profileID) })
        for (id, session) in sessions {
            let profile = kept[id]
            let sessionStore = session.webView.configuration.websiteDataStore.identifier
            let expectedStore = profile.flatMap { profileID in
                library.database.profileDataStoreID(profileID)
            }
            if profile == nil || (expectedStore != nil && sessionStore != expectedStore) {
                session.webView.removeFromSuperview()
                sessions[id] = nil
            }
        }
    }

    /// Each profile gets its own persistent website data store, so cookies
    /// and logins in one profile are not visible to another.
    private func configuration(forProfile profileID: UUID) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(forProfile: profileID)
        return configuration
    }

    private func dataStore(forProfile profileID: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[profileID] {
            return store
        }
        guard let identifier = library.database.profileDataStoreID(profileID) else {
            return .default()
        }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        dataStores[profileID] = store
        return store
    }
}
