import AppKit
import WebKit
import chord_logic

// How web extensions see Chord. A Major Chord window is an extension window
// whose tabs are the live tabs of its current space. A tab session is an
// extension tab. A Minor Chord window is a window with one tab: itself.

extension TabSession: WKWebExtensionTab {
    private var hostWindow: BrowserWindowController? {
        (NSApp.delegate as? AppDelegate)?.majorWindow(showing: sessions?.windowState(showing: tabID))
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        hostWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        hostWindow?.extensionTabs().firstIndex { $0 === self } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        library?.allTabs.first { $0.id == tabID }?.section == .pinned
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window = hostWindow {
            window.state.activate(tabID)
            window.showWindow(nil)
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let state = sessions?.windowState(showing: tabID) {
            state.close(tabID)
        } else {
            library?.close(tabID)
        }
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.goForward()
        completionHandler(nil)
    }
}

extension BrowserWindowController: WKWebExtensionWindow {
    /// The live tabs of the window's current space, in sidebar order.
    func extensionTabs() -> [TabSession] {
        state.visibleTabs.compactMap { sessions.liveSession(for: $0.id) }
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        extensionTabs()
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        state.activeTabID.flatMap { sessions.liveSession(for: $0) }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}

extension MinorChordWindowController: WKWebExtensionWindow, WKWebExtensionTab {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [self] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { self }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        window?.isMiniaturized == true ? .minimized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    /// Closing the window or its only tab closes the window.
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.goForward()
        completionHandler(nil)
    }
}
