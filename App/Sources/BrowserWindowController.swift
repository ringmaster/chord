import AppKit
import WebKit
import chord_logic

/// One browser window that shows one web view.
///
/// The window has a transparent title bar and its content fills the full window,
/// so the page runs to the edges. The command palette and the sidebar will
/// replace an address bar, so this window has none.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let homeURL = SearchEngine.duckDuckGo.baseURL

    let webView: WKWebView
    /// Runs when the window closes, so the owner can release this controller.
    var onClose: (() -> Void)?

    init(startURL: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        // Web Inspector opens from Safari's Develop menu for now. A docked
        // inspector pane is a later task.
        webView.isInspectable = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.contentView = webView
        window.setFrameAutosaveName("BrowserWindow")
        if window.frame.origin == .zero {
            window.center()
        }

        super.init(window: window)
        window.delegate = self

        webView.load(URLRequest(url: startURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is created in code only")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
