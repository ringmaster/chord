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
    private(set) weak var library: Library?
    private(set) weak var sessions: TabSessions?
    private var observations: [NSKeyValueObservation] = []
    private var overtones: OvertoneBinding?

    init(tabID: UUID, configuration: WKWebViewConfiguration, library: Library, sessions: TabSessions,
         overtoneManager: OvertoneManager) {
        self.tabID = tabID
        self.library = library
        self.sessions = sessions
        // Each web view gets its own script list, so one page's overtones
        // never reach another page. A popup's configuration can share its
        // opener's list otherwise.
        configuration.userContentController = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        overtones = OvertoneBinding(webView: webView, manager: overtoneManager, library: library)
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
        sessions?.extensionController.didChangeTabProperties([.title, .URL], for: self)
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
    /// Where this tab is, for routing the links clicked in it.
    private var linkContext: LinkRouting.Context? {
        guard let state = sessions?.windowState(showing: tabID) else { return nil }
        return LinkRouting.Context(spaceID: state.spaceID, groupID: state.contents.group(containing: tabID)?.id)
    }

    /// Hands a clicked link to Air Traffic Control. True when it went elsewhere.
    private func routeClickedLink(_ navigationAction: WKNavigationAction) -> Bool {
        guard navigationAction.navigationType == .linkActivated,
              let source = webView.url, let target = navigationAction.request.url,
              let context = linkContext, let appDelegate = NSApp.delegate as? AppDelegate else { return false }
        let window = appDelegate.majorWindow(showing: sessions?.windowState(showing: tabID))
        return appDelegate.routeClickedLink(target, from: source, context: context, window: window)
    }

    /// A clicked link to another site goes where Air Traffic Control sends it.
    /// Redirects, form submissions, and script navigation always load in place.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true {
            if routeClickedLink(navigationAction) {
                decisionHandler(.cancel)
                return
            }
            if let url = navigationAction.request.url {
                overtones?.prepare(for: url)
            }
        }
        decisionHandler(.allow)
    }

    /// A clicked link that opens a new window goes where the rules send it.
    /// Otherwise the new tab opens in the window that shows this tab, in a
    /// matching group when there is one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if routeClickedLink(navigationAction) {
            return nil
        }
        guard let sessions, let state = sessions.windowState(showing: tabID),
              let tab = state.openTab(navigationAction.request.url ?? URL(string: "about:blank")!) else {
            return nil
        }
        return sessions.adopt(tabID: tab.id, configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let state = sessions?.windowState(showing: tabID) {
            state.close(tabID)
        } else {
            library?.close(tabID)
        }
    }
}

/// Every live tab session, and the website data store of each profile.
///
/// All Major Chord windows share these sessions. A web view can be in only one
/// window at a time, so each session records the window that shows it. A
/// window that claims a tab takes its web view from the window that had it.
@MainActor
@Observable
final class TabSessions {
    @ObservationIgnored private let library: Library
    @ObservationIgnored let overtoneManager: OvertoneManager
    /// Every web view shares this controller, so extensions reach every page.
    @ObservationIgnored let extensionController: WKWebExtensionController
    @ObservationIgnored private var sessions: [UUID: TabSession] = [:]
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    /// The window that shows each tab's web view, by tab id.
    private(set) var hosts: [UUID: ObjectIdentifier] = [:]
    @ObservationIgnored private var hostStates: [ObjectIdentifier: WeakWindowState] = [:]

    private struct WeakWindowState {
        weak var state: WindowState?
    }

    init(library: Library, overtoneManager: OvertoneManager, extensionController: WKWebExtensionController) {
        self.library = library
        self.overtoneManager = overtoneManager
        self.extensionController = extensionController
    }

    /// The session for a tab, if its web view exists.
    func liveSession(for tabID: UUID) -> TabSession? {
        sessions[tabID]
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
        let session = TabSession(tabID: tabID, configuration: configuration, library: library, sessions: self,
                                 overtoneManager: overtoneManager)
        sessions[tabID] = session
        extensionController.didOpenTab(session)
        return session
    }

    /// Records that `window` now shows the tab's web view.
    func claim(tabID: UUID, by window: ObjectIdentifier, state: WindowState) {
        hostStates[window] = WeakWindowState(state: state)
        if hosts[tabID] != window {
            hosts[tabID] = window
        }
    }

    /// Forgets a window that closed.
    func release(window: ObjectIdentifier) {
        hostStates[window] = nil
        hosts = hosts.filter { $0.value != window }
    }

    /// The state of the window that shows a tab, if any.
    func windowState(showing tabID: UUID) -> WindowState? {
        hosts[tabID].flatMap { hostStates[$0]?.state }
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
                hosts[id] = nil
                extensionController.didCloseTab(session, windowIsClosing: false)
            }
        }
    }

    /// Each profile gets its own persistent website data store, so cookies
    /// and logins in one profile are not visible to another.
    func configuration(forProfile profileID: UUID) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(forProfile: profileID)
        configuration.webExtensionController = extensionController
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
