import AppKit
import SwiftUI
import WebKit
import chord_logic

/// A Major Chord window: the sidebar and the active tab's page. Every Major
/// Chord window shows the same spaces and tabs; each has its own space and
/// active tab, kept in `state`.
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
    let state: WindowState
    /// Runs when the window closes, so the owner can release this controller.
    var onClose: (() -> Void)?

    private let rootView = NSView()
    /// Holds the active tab's web view. Rounded when the sidebar is pinned.
    private let pageContainer = NSView()
    private let dragStrip = DragStripView()
    private let edgeHotZone = EdgeHotZoneView()
    private var sidebar: SidebarView!
    /// The group's header tabs, above the page while a group is shown.
    private var headerStrip: NSView!
    private var showsHeaderStrip = false

    private var paletteHost: NSView?
    private var paletteModel: PaletteModel?
    /// Watches key presses while the palette is open. See `handlePaletteKey`.
    private var paletteKeyMonitor: Any?

    private var flyout: SidebarFlyout
    private var hideTask: Task<Void, Never>?
    private weak var shownWebView: WKWebView?
    /// Shown in place of the page while another window shows this tab.
    private var elsewhereView: NSView?

    init(library: Library, sessions: TabSessions, spaceID: UUID, showRecentTab: Bool) {
        self.library = library
        self.sessions = sessions
        self.state = WindowState(library: library, spaceID: spaceID, showRecentTab: showRecentTab)
        // `open Chord.app --args -ChordSidebarPinned YES` starts with the
        // sidebar pinned open, so screenshots can show it without key presses.
        let defaults = UserDefaults.standard
        let pinnedOverride = defaults.object(forKey: "ChordSidebarPinned") == nil
            ? nil : defaults.bool(forKey: "ChordSidebarPinned")
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
            state: state,
            onOpenPalette: { [weak self] in self?.openPalette(nil) },
            onNewTab: { [weak self] in self?.newTab(nil) }))
        headerStrip = NSHostingView(rootView: HeaderStrip(
            state: state,
            onNewTab: { [weak self] groupID in self?.showPalette(mode: .newTab, initialText: "", groupID: groupID) }))
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
        rootView.addSubview(headerStrip)
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
        // The header strip, when shown, takes the top of the page area.
        let stripHeight = showsHeaderStrip ? Design.Page.headerStripHeight : 0
        headerStrip.isHidden = !showsHeaderStrip
        headerStrip.frame = NSRect(x: pageFrame.minX, y: pageFrame.maxY - stripHeight,
                                   width: pageFrame.width, height: stripHeight)
        pageContainer.frame = NSRect(x: pageFrame.minX, y: pageFrame.minY,
                                     width: pageFrame.width, height: pageFrame.height - stripHeight)
        pageContainer.layer?.cornerRadius = pagePinned ? Design.Page.cornerRadius : 0
        // Below a header strip, only the page's bottom corners are rounded.
        pageContainer.layer?.maskedCorners = showsHeaderStrip
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        shownWebView?.frame = pageContainer.bounds
        elsewhereView?.frame = pageContainer.bounds

        let strip = Design.Edge.dragStripHeight
        dragStrip.frame = NSRect(x: pageFrame.minX, y: bounds.height - strip,
                                 width: pageFrame.width, height: strip)
        // The header strip drags the window itself, so the drag strip would
        // only block clicks on the header tabs.
        dragStrip.isHidden = showsHeaderStrip
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
    ///
    /// A web view can be in only one window. When another window shows this
    /// tab, the key window takes the web view, and a window in the background
    /// shows a card that offers to bring the page back.
    private func showActiveTab() {
        state.reconcile()
        sessions.prune(keeping: library.allTabs)
        let wantsStrip = state.activeGroup != nil
        if wantsStrip != showsHeaderStrip {
            showsHeaderStrip = wantsStrip
            layoutChrome()
        }
        guard let tab = state.activeTab else {
            removeShownWebView()
            showElsewhereCard(false)
            return
        }
        let webView = sessions.session(for: tab).webView
        let me = ObjectIdentifier(self)
        let host = sessions.hosts[tab.id]
        let mayClaim = host == nil || host == me || window?.isKeyWindow == true
        guard mayClaim else {
            if shownWebView?.superview === pageContainer { removeShownWebView() }
            showElsewhereCard(true)
            return
        }
        sessions.claim(tabID: tab.id, by: me, state: state)
        showElsewhereCard(false)
        guard webView.superview !== pageContainer else {
            shownWebView = webView
            return
        }
        removeShownWebView()
        webView.frame = pageContainer.bounds
        webView.autoresizingMask = [.width, .height]
        pageContainer.addSubview(webView)
        shownWebView = webView
        if paletteHost == nil {
            window?.makeFirstResponder(webView)
        }
    }

    /// Takes the page out of this window, unless another window already took it.
    private func removeShownWebView() {
        if shownWebView?.superview === pageContainer {
            shownWebView?.removeFromSuperview()
        }
        shownWebView = nil
    }

    private func showElsewhereCard(_ show: Bool) {
        if show, elsewhereView == nil {
            let card = NSHostingView(rootView: ElsewhereCard { [weak self] in self?.bringPageHere() })
            card.frame = pageContainer.bounds
            card.autoresizingMask = [.width, .height]
            pageContainer.addSubview(card)
            elsewhereView = card
        } else if !show, let card = elsewhereView {
            card.removeFromSuperview()
            elsewhereView = nil
        }
    }

    private func bringPageHere() {
        guard let tab = state.activeTab else { return }
        sessions.claim(tabID: tab.id, by: ObjectIdentifier(self), state: state)
        showActiveTab()
    }

    // MARK: Actions

    /// Command-T: the palette, to open a new tab.
    @objc func newTab(_ sender: Any?) {
        showPalette(mode: .newTab, initialText: "")
    }

    /// Command-L: the palette, filled with the active tab's address.
    @objc func openPalette(_ sender: Any?) {
        let address = state.activeTab?.url.absoluteString ?? ""
        showPalette(mode: state.activeTab == nil ? .newTab : .currentTab, initialText: address)
    }

    @objc func closeTab(_ sender: Any?) {
        guard let id = state.activeTabID else { return }
        state.close(id)
    }

    @objc func copyAddress(_ sender: Any?) {
        guard let url = state.activeTab?.url else { return }
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

    /// Opens the palette. With `groupID`, new tabs from it open in that group.
    func showPalette(mode: PaletteMode, initialText: String, groupID: UUID? = nil) {
        dismissPalette()
        let model = PaletteModel(
            mode: mode, initialText: initialText, library: library, tabs: state.visibleTabs,
            commands: paletteCommands(),
            onPerform: { [weak self] item, mode in self?.perform(item, mode: mode, groupID: groupID) },
            onDismiss: { [weak self] in self?.dismissPalette() })
        let host = NSHostingView(rootView: PaletteView(model: model))
        host.frame = rootView.bounds
        host.autoresizingMask = [.width, .height]
        rootView.addSubview(host)
        paletteHost = host
        paletteModel = model
        paletteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent is not Sendable, so only plain values cross into the main actor.
            let keyCode = event.keyCode
            let windowNumber = event.windowNumber
            let used = MainActor.assumeIsolated {
                guard let self, windowNumber == self.window?.windowNumber else { return false }
                return self.handlePaletteKey(keyCode: keyCode)
            }
            return used ? nil : event
        }
        // The web view keeps keyboard focus until another view takes it. The
        // hosting view must become first responder before SwiftUI can focus
        // the palette's text field.
        window?.makeFirstResponder(host)
    }

    /// Handles the palette's keys before the text field sees them. The text
    /// field's editor uses the up and down arrows to move the insertion
    /// point, so a SwiftUI key handler on the field never receives them.
    /// Returns true when the key was used.
    private func handlePaletteKey(keyCode: UInt16) -> Bool {
        guard let model = paletteModel else { return false }
        // While an input method is composing text, its keys go to the field.
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        switch keyCode {
        case 125: // Down arrow
            model.moveSelection(by: 1)
        case 126: // Up arrow
            model.moveSelection(by: -1)
        case 36, 76: // Return, Enter
            model.performSelected()
        case 53: // Escape
            dismissPalette()
        default:
            return false
        }
        return true
    }

    private func dismissPalette() {
        if let monitor = paletteKeyMonitor {
            NSEvent.removeMonitor(monitor)
            paletteKeyMonitor = nil
        }
        paletteModel = nil
        guard let host = paletteHost else { return }
        paletteHost = nil
        host.removeFromSuperview()
        if let shownWebView {
            window?.makeFirstResponder(shownWebView)
        }
    }

    private func perform(_ item: PaletteItem, mode: PaletteMode, groupID: UUID?) {
        switch item {
        case .navigate(let url), .search(_, _, let url):
            load(url, mode: mode, groupID: groupID)
        case .history(let entry):
            load(entry.url, mode: mode, groupID: groupID)
        case .tab(let tab):
            state.activate(tab.id)
        case .command(let command):
            run(command.id)
        }
    }

    private func load(_ url: URL, mode: PaletteMode, groupID: UUID?) {
        if mode == .currentTab, let shownWebView {
            shownWebView.load(URLRequest(url: url))
        } else if let groupID {
            state.openTab(url, inGroup: groupID)
        } else if let appDelegate {
            appDelegate.route(url, from: self)
        } else {
            state.openTab(url)
        }
    }

    /// The commands that make sense right now. Run them with `run(_:)`.
    private func paletteCommands() -> [PaletteCommand] {
        var commands = [
            PaletteCommand(id: "new-tab", title: "New Tab", symbol: "plus", shortcut: "⌘T"),
            PaletteCommand(id: "new-window", title: "New Window", symbol: "macwindow.badge.plus", shortcut: "⌘N"),
            PaletteCommand(id: "toggle-sidebar", title: "Toggle Sidebar", symbol: "sidebar.left", shortcut: "⌘S"),
            PaletteCommand(id: "reload", title: "Reload Page", symbol: "arrow.clockwise",
                           keywords: ["refresh"], shortcut: "⌘R"),
            PaletteCommand(id: "back", title: "Go Back", symbol: "chevron.left", shortcut: "⌘["),
            PaletteCommand(id: "forward", title: "Go Forward", symbol: "chevron.right", shortcut: "⌘]"),
            PaletteCommand(id: "copy-address", title: "Copy Address", symbol: "link",
                           keywords: ["url"], shortcut: "⇧⌘C"),
            PaletteCommand(id: "close-tab", title: "Close Tab", symbol: "xmark", shortcut: "⌘W"),
        ]
        if let group = state.activeGroup {
            commands.append(PaletteCommand(id: "ungroup", title: "Ungroup Tabs", symbol: "rectangle.stack.badge.minus",
                                           keywords: ["group"]))
            commands.append(PaletteCommand(id: "group-new-tab", title: "New Tab in \(group.title.isEmpty ? "Group" : group.title)",
                                           symbol: "plus.rectangle.on.rectangle", keywords: ["group"]))
        } else if let tab = state.activeTab, tab.section != .favorite, let matcher = URLMatcher.suggested(for: tab.url) {
            commands.append(PaletteCommand(id: "group", title: "Group Tabs from \(matcher.value)",
                                           symbol: "rectangle.stack.badge.plus", keywords: ["group", "strip"]))
        }
        if let tab = state.activeTab, !tab.isGroup, tab.parentTabID == nil {
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
        if state.activeTab != nil {
            commands.append(PaletteCommand(id: "route-site", title: "Route This Site…",
                                           symbol: "arrow.triangle.branch", keywords: ["rule"]))
        }
        commands.append(PaletteCommand(id: "overtones-folder", title: "Open Overtones Folder", symbol: "folder",
                                       keywords: ["overtone", "css", "javascript"]))
        commands.append(PaletteCommand(id: "overtones-reload", title: "Reload Overtones", symbol: "arrow.triangle.2.circlepath",
                                       keywords: ["overtone"]))
        commands.append(PaletteCommand(id: "new-space", title: "New Space", symbol: "square.stack"))
        for space in library.spaces where space.id != state.spaceID {
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
            state.selectSpace(id)
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
        case "new-window": appDelegate?.newWindow(nil)
        case "overtones-folder": appDelegate?.overtones?.revealFolder()
        case "overtones-reload": appDelegate?.overtones?.reload()
        case "group":
            if let tab = state.activeTab, let matcher = URLMatcher.suggested(for: tab.url) {
                library.makeGroup(tab.id, matcher: matcher)
            }
        case "ungroup": state.activeGroup.map { library.ungroup($0.id) }
        case "group-new-tab":
            if let group = state.activeGroup {
                showPalette(mode: .newTab, initialText: "", groupID: group.id)
            }
        case "toggle-sidebar": toggleSidebar(nil)
        case "reload": reloadPage(nil)
        case "back": goBack(nil)
        case "forward": goForward(nil)
        case "copy-address": copyAddress(nil)
        case "close-tab": closeTab(nil)
        case "pin-tab": state.activeTabID.map { state.move($0, to: .pinned) }
        case "unpin-tab": state.activeTabID.map { state.move($0, to: .open) }
        case "favorite-tab": state.activeTabID.map { state.move($0, to: .favorite) }
        case "unfavorite-tab": state.activeTabID.map { state.move($0, to: .pinned) }
        case "new-space": state.createSpace(named: "Space \(library.spaces.count + 1)")
        case "default-browser": DefaultBrowser.request()
        case "clear-history": library.clearHistory()
        case "air-traffic-control": appDelegate?.showAirTrafficControl(routing: nil, spaceID: state.spaceID)
        case "route-site": appDelegate?.showAirTrafficControl(routing: state.activeTab?.url, spaceID: state.spaceID)
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
        // Take back the active tab's page if another window showed it.
        showActiveTab()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        placeWindowButtons()
    }

    func windowWillClose(_ notification: Notification) {
        hideTask?.cancel()
        removeShownWebView()
        sessions.release(window: ObjectIdentifier(self))
        onClose?()
    }
}

/// The card a background window shows while another window shows its tab.
private struct ElsewhereCard: View {
    let onBringHere: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("This tab is showing in another window")
                .font(.system(size: 14, weight: .semibold))
            Button("Show It Here", action: onBringHere)
                .buttonStyle(QuietButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
