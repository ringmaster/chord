import AppKit
import WebKit
import chord_logic

/// One browser window that shows one web view.
///
/// The page fills the whole window. There is no address bar; the command
/// palette will do that job. The window's own controls are:
/// - a transparent drag strip over the top edge of the page,
/// - a sidebar flyout that slides in from the left edge, and
/// - the window buttons, which show only at the top of the flyout.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let homeURL = SearchEngine.duckDuckGo.baseURL

    let webView: WKWebView
    /// Runs when the window closes, so the owner can release this controller.
    var onClose: (() -> Void)?

    private let rootView = NSView()
    private let dragStrip = DragStripView()
    private let edgeHotZone = EdgeHotZoneView()
    private let sidebar = SidebarView()

    private var flyout = SidebarFlyout()
    private var hideTask: Task<Void, Never>?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?

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
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.contentView = rootView
        window.setFrameAutosaveName("BrowserWindow")
        if window.frame.origin == .zero {
            window.center()
        }

        super.init(window: window)
        window.delegate = self

        buildViews()
        observePage()
        // `open Chord.app --args -ChordSidebarPinned YES` starts with the
        // sidebar pinned open, so screenshots can show it without key presses.
        if UserDefaults.standard.bool(forKey: "ChordSidebarPinned") {
            _ = flyout.handle(.togglePinned)
        }
        applyFlyoutState(animated: false)
        webView.load(URLRequest(url: startURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is created in code only")
    }

    // MARK: Views

    private func buildViews() {
        rootView.addSubview(webView)
        rootView.addSubview(dragStrip)
        rootView.addSubview(edgeHotZone)
        rootView.addSubview(sidebar)

        webView.autoresizingMask = [.width, .height]
        webView.frame = rootView.bounds

        dragStrip.autoresizingMask = [.width, .minYMargin]
        edgeHotZone.autoresizingMask = [.height]
        sidebar.autoresizingMask = [.height]

        edgeHotZone.onPointerEntered = { [weak self] in self?.send(.pointerReachedEdge) }
        sidebar.onPointerExited = { [weak self] in self?.send(.pointerLeftSidebar) }

        layoutChrome()
    }

    /// Places the strip, the hot zone, and the sidebar. The sidebar sits off
    /// the left edge when hidden and slides in when shown.
    private func layoutChrome() {
        let bounds = rootView.bounds
        let strip = Design.Edge.dragStripHeight
        dragStrip.frame = NSRect(x: 0, y: bounds.height - strip, width: bounds.width, height: strip)
        edgeHotZone.frame = NSRect(x: 0, y: 0, width: Design.Edge.hotZoneWidth, height: bounds.height)
        sidebar.frame = sidebarFrame(visible: flyout.isVisible)
    }

    private func sidebarFrame(visible: Bool) -> NSRect {
        let bounds = rootView.bounds
        let inset = Design.Sidebar.inset
        let width = Design.Sidebar.width
        let x = visible ? inset : -width - inset
        return NSRect(x: x, y: inset, width: width, height: bounds.height - inset * 2)
    }

    // MARK: Sidebar flyout

    @objc func toggleSidebar(_ sender: Any?) {
        send(.togglePinned)
    }

    private func send(_ event: SidebarFlyout.Event) {
        let wasVisible = flyout.isVisible
        let effect = flyout.handle(event)
        if effect == .scheduleHide {
            scheduleHide()
        }
        if flyout.isVisible != wasVisible {
            applyFlyoutState(animated: true)
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Design.Sidebar.hideDelay)
            guard !Task.isCancelled, let self else { return }
            self.send(.hideDelayElapsed(pointerInsideSidebar: self.pointerIsInsideSidebar()))
        }
    }

    private func pointerIsInsideSidebar() -> Bool {
        guard let window else { return false }
        let point = rootView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return sidebar.frame.contains(point)
    }

    private func applyFlyoutState(animated: Bool) {
        let visible = flyout.isVisible
        let target = sidebarFrame(visible: visible)
        // A view with zero alpha still takes clicks, so hidden controls are
        // also marked hidden. They are unhidden before they fade in, and hidden
        // after they fade out.
        if visible {
            sidebar.isHidden = false
            windowButtons.forEach { $0.isHidden = false }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Design.Sidebar.slideDuration : 0
            context.timingFunction = Design.Motion.easeOut
            context.allowsImplicitAnimation = true
            sidebar.animator().frame = target
            for button in windowButtons {
                button.animator().alphaValue = visible ? 1 : 0
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.flyout.isVisible else { return }
                self.sidebar.isHidden = true
                self.windowButtons.forEach { $0.isHidden = true }
            }
        }
        placeWindowButtons()
    }

    // MARK: Window buttons

    private var windowButtons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window?.standardWindowButton($0) }
    }

    /// Moves the window buttons so they sit inside the top of the flyout card.
    /// `applyFlyoutState` shows and hides them.
    private func placeWindowButtons() {
        let buttons = windowButtons
        guard let first = buttons.first, let titlebar = first.superview else { return }
        let spacing: CGFloat = buttons.count > 1 ? buttons[1].frame.minX - first.frame.minX : 20
        let leading = Design.Sidebar.inset + Design.Sidebar.contentPadding
        // Centered in the card's header area, measured from the window top.
        let headerCenterFromTop = Design.Sidebar.inset + Design.Sidebar.headerHeight / 2
        for (index, button) in buttons.enumerated() {
            var origin = NSPoint(x: leading + CGFloat(index) * spacing, y: 0)
            let centerY = titlebar.bounds.height - headerCenterFromTop
            origin.y = titlebar.isFlipped
                ? headerCenterFromTop - button.frame.height / 2
                : centerY - button.frame.height / 2
            button.setFrameOrigin(origin)
        }
    }

    // MARK: Page

    private func observePage() {
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateSidebarPage() }
        }
        urlObservation = webView.observe(\.url) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateSidebarPage() }
        }
    }

    private func updateSidebarPage() {
        let host = webView.url?.host() ?? ""
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? host
        sidebar.show(title: title, host: host)
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        layoutChrome()
        placeWindowButtons()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        placeWindowButtons()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        placeWindowButtons()
    }

    func windowWillClose(_ notification: Notification) {
        hideTask?.cancel()
        onClose?()
    }
}
