import AppKit
import SwiftUI
import WebKit
import chord_logic

/// The main Chord window: the sidebar and the active tab's page.
///
/// There is no address bar; the command palette does that job. The window's
/// own controls are:
/// - a transparent drag strip over the top edge of the page,
/// - the sidebar, which is either pinned beside the page or a flyout that
///   slides in from the left edge, and
/// - the window buttons, which show only at the top of the sidebar.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let library: Library
    let sessions: TabSessions
    /// Runs when the window closes, so the owner can release this controller.
    var onClose: (() -> Void)?

    private let rootView = NSView()
    /// Holds the active tab's web view. Rounded when the sidebar is pinned.
    private let pageContainer = NSView()
    private let dragStrip = DragStripView()
    private let edgeHotZone = EdgeHotZoneView()
    private var sidebar: SidebarView!

    private var paletteHost: NSView?

    private var flyout: SidebarFlyout
    private var hideTask: Task<Void, Never>?
    private weak var shownWebView: WKWebView?

    init(library: Library, sessions: TabSessions) {
        self.library = library
        self.sessions = sessions
        // `open Chord.app --args -ChordSidebarPinned YES` starts with the
        // sidebar pinned open, so screenshots can show it without key presses.
        let pinnedOverride = UserDefaults.standard.object(forKey: "ChordSidebarPinned") as? Bool
        flyout = SidebarFlyout(isPinned: pinnedOverride ?? library.sidebarPinned)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)
        window.contentView = rootView
        window.setFrameAutosaveName("BrowserWindow")
        if window.frame.origin == .zero {
            window.center()
        }

        super.init(window: window)
        window.delegate = self

        sidebar = SidebarView(content: SidebarContent(
            library: library,
            onOpenPalette: { [weak self] in self?.openPalette(nil) },
            onNewTab: { [weak self] in self?.newTab(nil) }))
        buildViews()
        applyFlyoutState(animated: false)

        keepUpdated { [weak self] in self?.showActiveTab() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is created in code only")
    }

    // MARK: Views

    private func buildViews() {
        rootView.wantsLayer = true
        pageContainer.wantsLayer = true
        pageContainer.layer?.masksToBounds = true

        rootView.addSubview(pageContainer)
        rootView.addSubview(dragStrip)
        rootView.addSubview(edgeHotZone)
        rootView.addSubview(sidebar)

        edgeHotZone.onPointerEntered = { [weak self] in self?.send(.pointerReachedEdge) }
        sidebar.onPointerExited = { [weak self] in self?.send(.pointerLeftSidebar) }

        layoutChrome()
    }

    /// Places every part of the window for the current size and sidebar state.
    /// When the sidebar is pinned, the page sits beside it in a rounded card.
    /// Otherwise the page fills the window and the sidebar floats over it.
    private func layoutChrome() {
        let bounds = rootView.bounds
        let inset = Design.Sidebar.inset
        let pagePinned = flyout.isPinned

        let pageFrame = pagePinned
            ? NSRect(x: inset + Design.Sidebar.width + inset, y: inset,
                     width: bounds.width - Design.Sidebar.width - inset * 3,
                     height: bounds.height - inset * 2)
            : bounds
        pageContainer.frame = pageFrame
        pageContainer.layer?.cornerRadius = pagePinned ? Design.Page.cornerRadius : 0
        shownWebView?.frame = pageContainer.bounds

        let strip = Design.Edge.dragStripHeight
        dragStrip.frame = NSRect(x: pageFrame.minX, y: bounds.height - strip,
                                 width: pageFrame.width, height: strip)
        edgeHotZone.frame = NSRect(x: 0, y: 0, width: Design.Edge.hotZoneWidth, height: bounds.height)
        edgeHotZone.isHidden = pagePinned
        sidebar.frame = sidebarFrame(visible: flyout.isVisible)
    }

    private func sidebarFrame(visible: Bool) -> NSRect {
        let bounds = rootView.bounds
        let inset = Design.Sidebar.inset
        let width = Design.Sidebar.width
        let x = visible ? inset : -width - inset
        return NSRect(x: x, y: inset, width: width, height: bounds.height - inset * 2)
    }

    // MARK: Active tab

    /// Shows the active tab's web view, creating it the first time.
    private func showActiveTab() {
        let tab = library.activeTab
        sessions.prune(keeping: library.visibleTabs)
        guard let tab else {
            shownWebView?.removeFromSuperview()
            shownWebView = nil
            return
        }
        let webView = sessions.session(for: tab).webView
        guard webView !== shownWebView else { return }
        shownWebView?.removeFromSuperview()
        webView.frame = pageContainer.bounds
        webView.autoresizingMask = [.width, .height]
        pageContainer.addSubview(webView)
        shownWebView = webView
        window?.makeFirstResponder(webView)
    }

    // MARK: Actions

    /// Command-T: the palette, to open a new tab.
    @objc func newTab(_ sender: Any?) {
        showPalette(mode: .newTab, initialText: "")
    }

    /// Command-L: the palette, filled with the active tab's address.
    @objc func openPalette(_ sender: Any?) {
        let address = library.activeTab?.url.absoluteString ?? ""
        showPalette(mode: library.activeTab == nil ? .newTab : .currentTab, initialText: address)
    }

    @objc func closeTab(_ sender: Any?) {
        guard let id = library.activeTabID else { return }
        library.close(id)
    }

    @objc func copyAddress(_ sender: Any?) {
        guard let url = library.activeTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func reloadPage(_ sender: Any?) {
        shownWebView?.reload()
    }

    @objc func goBack(_ sender: Any?) {
        shownWebView?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        shownWebView?.goForward()
    }

    // MARK: Command palette

    func showPalette(mode: PaletteMode, initialText: String) {
        dismissPalette()
        let model = PaletteModel(
            mode: mode, initialText: initialText, library: library, commands: paletteCommands(),
            onPerform: { [weak self] item, mode in self?.perform(item, mode: mode) },
            onDismiss: { [weak self] in self?.dismissPalette() })
        let host = NSHostingView(rootView: PaletteView(model: model))
        host.frame = rootView.bounds
        host.autoresizingMask = [.width, .height]
        rootView.addSubview(host)
        paletteHost = host
        // The web view keeps keyboard focus until another view takes it. The
        // hosting view must become first responder before SwiftUI can focus
        // the palette's text field.
        window?.makeFirstResponder(host)
    }

    private func dismissPalette() {
        guard let host = paletteHost else { return }
        paletteHost = nil
        host.removeFromSuperview()
        if let shownWebView {
            window?.makeFirstResponder(shownWebView)
        }
    }

    private func perform(_ item: PaletteItem, mode: PaletteMode) {
        switch item {
        case .navigate(let url), .search(_, _, let url):
            load(url, mode: mode)
        case .history(let entry):
            load(entry.url, mode: mode)
        case .tab(let tab):
            library.activate(tab.id)
        case .command(let command):
            run(command.id)
        }
    }

    private func load(_ url: URL, mode: PaletteMode) {
        if mode == .currentTab, let shownWebView {
            shownWebView.load(URLRequest(url: url))
        } else if let appDelegate {
            appDelegate.route(url)
        } else {
            library.openTab(url)
        }
    }

    /// The commands that make sense right now. Run them with `run(_:)`.
    private func paletteCommands() -> [PaletteCommand] {
        var commands = [
            PaletteCommand(id: "new-tab", title: "New Tab", symbol: "plus", shortcut: "⌘T"),
            PaletteCommand(id: "toggle-sidebar", title: "Toggle Sidebar", symbol: "sidebar.left", shortcut: "⌘S"),
            PaletteCommand(id: "reload", title: "Reload Page", symbol: "arrow.clockwise",
                           keywords: ["refresh"], shortcut: "⌘R"),
            PaletteCommand(id: "back", title: "Go Back", symbol: "chevron.left", shortcut: "⌘["),
            PaletteCommand(id: "forward", title: "Go Forward", symbol: "chevron.right", shortcut: "⌘]"),
            PaletteCommand(id: "copy-address", title: "Copy Address", symbol: "link",
                           keywords: ["url"], shortcut: "⇧⌘C"),
            PaletteCommand(id: "close-tab", title: "Close Tab", symbol: "xmark", shortcut: "⌘W"),
        ]
        if let tab = library.activeTab {
            switch tab.section {
            case .open:
                commands.append(PaletteCommand(id: "pin-tab", title: "Pin Tab", symbol: "pin"))
                commands.append(PaletteCommand(id: "favorite-tab", title: "Add to Favorites", symbol: "star"))
            case .pinned:
                commands.append(PaletteCommand(id: "unpin-tab", title: "Unpin Tab", symbol: "pin.slash"))
                commands.append(PaletteCommand(id: "favorite-tab", title: "Add to Favorites", symbol: "star"))
            case .favorite:
                commands.append(PaletteCommand(id: "unfavorite-tab", title: "Remove from Favorites",
                                               symbol: "star.slash"))
            }
        }
        commands.append(PaletteCommand(id: "air-traffic-control", title: "Air Traffic Control",
                                       symbol: "point.3.filled.connected.trianglepath.dotted",
                                       keywords: ["rules", "routing", "route"], shortcut: "⌘,"))
        if library.activeTab != nil {
            commands.append(PaletteCommand(id: "route-site", title: "Route This Site…",
                                           symbol: "arrow.triangle.branch", keywords: ["rule"]))
        }
        commands.append(PaletteCommand(id: "new-space", title: "New Space", symbol: "square.stack"))
        for space in library.spaces where space.id != library.activeSpace.id {
            commands.append(PaletteCommand(id: "space:\(space.id.uuidString)", title: "Switch to \(space.name)",
                                           symbol: "square.stack", keywords: ["space"]))
        }
        for engine in SearchEngine.presets where engine != library.searchEngine {
            commands.append(PaletteCommand(id: "engine:\(engine.id)", title: "Search with \(engine.name)",
                                           symbol: "magnifyingglass", keywords: ["search engine", "default"]))
        }
        if !DefaultBrowser.isDefault {
            commands.append(PaletteCommand(id: "default-browser", title: "Make Chord the Default Browser",
                                           symbol: "globe", keywords: ["default"]))
        }
        commands.append(PaletteCommand(id: "clear-history", title: "Clear History", symbol: "trash"))
        return commands
    }

    private func run(_ commandID: String) {
        if commandID.hasPrefix("space:"), let id = UUID(uuidString: String(commandID.dropFirst(6))) {
            library.selectSpace(id)
            return
        }
        if commandID.hasPrefix("engine:") {
            let id = String(commandID.dropFirst(7))
            if let engine = SearchEngine.presets.first(where: { $0.id == id }) {
                library.setSearchEngine(engine)
            }
            return
        }
        switch commandID {
        case "new-tab": newTab(nil)
        case "toggle-sidebar": toggleSidebar(nil)
        case "reload": reloadPage(nil)
        case "back": goBack(nil)
        case "forward": goForward(nil)
        case "copy-address": copyAddress(nil)
        case "close-tab": closeTab(nil)
        case "pin-tab": library.activeTabID.map { library.move($0, to: .pinned) }
        case "unpin-tab": library.activeTabID.map { library.move($0, to: .open) }
        case "favorite-tab": library.activeTabID.map { library.move($0, to: .favorite) }
        case "unfavorite-tab": library.activeTabID.map { library.move($0, to: .pinned) }
        case "new-space": library.createSpace(named: "Space \(library.spaces.count + 1)")
        case "default-browser": DefaultBrowser.request()
        case "clear-history": library.clearHistory()
        case "air-traffic-control": appDelegate?.showAirTrafficControl(routing: nil)
        case "route-site": appDelegate?.showAirTrafficControl(routing: library.activeTab?.url)
        default: AppDelegate.log.error("Unknown palette command \(commandID, privacy: .public)")
        }
    }

    private var appDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    // MARK: Sidebar flyout

    @objc func toggleSidebar(_ sender: Any?) {
        send(.togglePinned)
        library.sidebarPinned = flyout.isPinned
    }

    private func send(_ event: SidebarFlyout.Event) {
        let wasVisible = flyout.isVisible
        let wasPinned = flyout.isPinned
        let effect = flyout.handle(event)
        if effect == .scheduleHide {
            scheduleHide()
        }
        if flyout.isVisible != wasVisible || flyout.isPinned != wasPinned {
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
            layoutChrome()
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

    /// Moves the window buttons so they sit inside the top of the sidebar card.
    /// `applyFlyoutState` shows and hides them.
    private func placeWindowButtons() {
        let buttons = windowButtons
        guard let first = buttons.first, let titlebar = first.superview else { return }
        let spacing: CGFloat = buttons.count > 1 ? buttons[1].frame.minX - first.frame.minX : 20
        let leading = Design.Sidebar.inset + Design.Sidebar.contentPadding
        // Centered in the card's header area, measured from the window top.
        let headerCenterFromTop = Design.Sidebar.inset + Design.Sidebar.headerHeight / 2
        for (index, button) in buttons.enumerated() {
            let y = titlebar.isFlipped
                ? headerCenterFromTop - button.frame.height / 2
                : titlebar.bounds.height - headerCenterFromTop - button.frame.height / 2
            button.setFrameOrigin(NSPoint(x: leading + CGFloat(index) * spacing, y: y))
        }
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
