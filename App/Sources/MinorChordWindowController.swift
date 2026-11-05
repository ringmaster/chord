import AppKit
import SwiftUI
import WebKit
import chord_logic

/// A Minor Chord window: one website, with almost no chrome.
///
/// The page fills the window. When the pointer nears the top edge, a thin bar
/// fades in with the window buttons, the site's address, and a button that
/// moves the page into a Major Chord window. The top edge always drags the
/// window. Minor Chord windows are not tabs, so they are not saved between
/// launches; their visits still go into history.
@MainActor
final class MinorChordWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let profileID: UUID
    /// Runs when the window closes, so the owner can release this controller.
    var onClose: (() -> Void)?

    private let library: Library
    private let bar = MinorChordBarModel()
    private let rootView = NSView()
    private let dragStrip = DragStripView()
    private var barHost: NSView!
    private var hoverZone: HoverZoneView!
    private var hideBarTask: Task<Void, Never>?
    private var observations: [NSKeyValueObservation] = []
    private var overtones: OvertoneBinding?

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// Opens a window for `url`. With `configuration`, the window adopts a web
    /// view configuration that WebKit gave for a new window, which keeps the
    /// link between a popup and the page that opened it.
    init(url: URL?, profileID: UUID, library: Library, configuration: WKWebViewConfiguration,
         overtoneManager: OvertoneManager) {
        self.profileID = profileID
        self.library = library
        // Each web view gets its own script list for its overtones.
        configuration.userContentController = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        window.contentView = rootView
        window.center()
        super.init(window: window)
        window.delegate = self

        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        overtones = OvertoneBinding(webView: webView, manager: overtoneManager, library: library)

        buildViews()
        setBarVisible(false, animated: false)
        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.pageChanged() } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.pageChanged() } },
        ]
        if let url {
            webView.load(URLRequest(url: url))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MinorChordWindowController is created in code only")
    }

    // MARK: Views

    private func buildViews() {
        webView.frame = rootView.bounds
        webView.autoresizingMask = [.width, .height]
        rootView.addSubview(webView)

        let strip = Design.Edge.dragStripHeight
        dragStrip.frame = NSRect(x: 0, y: rootView.bounds.height - strip, width: rootView.bounds.width, height: strip)
        dragStrip.autoresizingMask = [.width, .minYMargin]
        rootView.addSubview(dragStrip)

        let barHeight = Design.MinorChord.barHeight
        let host = NSHostingView(rootView: MinorChordBar(model: bar) { [weak self] in self?.moveToMajorWindow(nil) })
        host.frame = NSRect(x: 0, y: rootView.bounds.height - barHeight, width: rootView.bounds.width, height: barHeight)
        host.autoresizingMask = [.width, .minYMargin]
        rootView.addSubview(host)
        barHost = host

        // The zone covers the bar's area and reports the pointer without
        // taking clicks, so the page under it still works.
        let zone = HoverZoneView(frame: host.frame)
        zone.autoresizingMask = [.width, .minYMargin]
        zone.onChange = { [weak self] inside in self?.pointerInBar(inside) }
        rootView.addSubview(zone, positioned: .below, relativeTo: host)
        hoverZone = zone
    }

    private func pointerInBar(_ inside: Bool) {
        hideBarTask?.cancel()
        if inside {
            setBarVisible(true, animated: true)
        } else {
            hideBarTask = Task { [weak self] in
                try? await Task.sleep(for: Design.Sidebar.hideDelay)
                guard !Task.isCancelled else { return }
                self?.setBarVisible(false, animated: true)
            }
        }
    }

    /// Shows or hides the bar and the window buttons together. Hidden views
    /// are also marked hidden, because a view with zero alpha still takes clicks.
    private func setBarVisible(_ visible: Bool, animated: Bool) {
        let views: [NSView] = [barHost] + windowButtons
        if visible { views.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.15 : 0
            views.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.barHost.alphaValue == 0 else { return }
                views.forEach { $0.isHidden = true }
            }
        }
    }

    private var windowButtons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window?.standardWindowButton($0) }
    }

    private func pageChanged() {
        bar.host = webView.url?.host() ?? ""
        window?.title = webView.title?.isEmpty == false ? webView.title! : bar.host
    }

    // MARK: Actions

    /// Command-W closes the window, as it closes a tab elsewhere.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc func reloadPage(_ sender: Any?) { webView.reload() }
    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }

    @objc func copyAddress(_ sender: Any?) {
        guard let url = webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Command-T opens a new tab in the front Major Chord window.
    @objc func newTab(_ sender: Any?) {
        appDelegate?.showMainWindow(nil)
        appDelegate?.frontMajorWindow()?.newTab(nil)
    }

    /// Moves the page into a tab in the front Major Chord window and closes
    /// this window.
    @objc func moveToMajorWindow(_ sender: Any?) {
        guard let url = webView.url, let appDelegate else { return }
        appDelegate.openInMajorWindow(url)
        window?.performClose(nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        library.recordVisit(url: url, title: webView.title ?? "")
        Favicons.shared.load(for: webView)
    }

    /// A clicked link to another site goes where Air Traffic Control sends it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true,
           let source = webView.url, let target = navigationAction.request.url,
           appDelegate?.routeClickedLink(target, from: source, context: .init(spaceID: nil, groupID: nil),
                                         window: nil) == true {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url {
            overtones?.prepare(for: url)
        }
        decisionHandler(.allow)
    }

    // MARK: WKUIDelegate

    /// A clicked link that opens a new window goes where the rules send it.
    /// Otherwise, and for windows a script opens, the new page gets its own
    /// Minor Chord window with the same profile.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated,
           let source = webView.url, let target = navigationAction.request.url,
           appDelegate?.routeClickedLink(target, from: source, context: .init(spaceID: nil, groupID: nil),
                                         window: nil) == true {
            return nil
        }
        return appDelegate?.openMinorChord(url: nil, profileID: profileID, configuration: configuration)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window?.performClose(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        hideBarTask?.cancel()
        webView.stopLoading()
        onClose?()
    }
}

/// The text the Minor Chord bar shows.
@MainActor
@Observable
final class MinorChordBarModel {
    var host = ""
}

/// The bar that fades in at the top of a Minor Chord window: room for the
/// window buttons, the site's address, and a button that moves the page into
/// a Major Chord window.
private struct MinorChordBar: View {
    let model: MinorChordBarModel
    let onMoveToMajor: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64)
            Spacer(minLength: 0)
            Text(model.host)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onMoveToMajor) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .help("Open in a Chord window")
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    }
}

/// An invisible view that reports when the pointer enters or leaves it, and
/// passes clicks through to the views below.
final class HoverZoneView: NSView {
    var onChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
