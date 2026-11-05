import AppKit
import OSLog
import chord_logic

/// The application shell. It opens the database, builds the main menu, and
/// owns the Major Chord windows, which all share one set of tabs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "app")

    private var library: Library?
    private var sessions: TabSessions?
    private var windows: [BrowserWindowController] = []
    private var airTrafficControl: AirTrafficControlWindowController?
    /// Links that arrived before the database was open.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.log.notice("Chord launched")
        // The main menu carries the standard key equivalents, such as Command-Q
        // and Command-V. With no main menu, those keys reach nothing.
        NSApp.mainMenu = AppDelegate.buildMainMenu()

        do {
            // `--args -ChordDatabasePath /some/file.sqlite` uses another
            // database file, so tests and screenshots leave real data alone.
            let override = UserDefaults.standard.string(forKey: "ChordDatabasePath")
            let databaseURL = try override.map { URL(filePath: $0) } ?? ChordDatabase.defaultURL()
            let database = try ChordDatabase(url: databaseURL)
            let library = try Library(database: database)
            self.library = library
            sessions = TabSessions(library: library)
        } catch {
            AppDelegate.log.fault("Could not open the database: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert(error: error)
            alert.messageText = "Chord could not open its database."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let first = frontWindow()
        if !pendingURLs.isEmpty {
            application(NSApp, open: pendingURLs)
            pendingURLs = []
        } else if first?.state.activeTab == nil {
            first?.newTab(nil)
        }
        // `--args -ChordExtraWindows 1` opens more Major Chord windows at
        // launch, so screenshots can show shared tabs without key presses.
        for _ in 0..<UserDefaults.standard.integer(forKey: "ChordExtraWindows") {
            newWindow(nil)
        }
        // `--args -ChordPaletteQuery text` opens the palette with that text,
        // so screenshots can show it without key presses.
        if let query = UserDefaults.standard.string(forKey: "ChordPaletteQuery") {
            first?.showPalette(mode: .newTab, initialText: query)
        }
        // `--args -ChordShowAirTrafficControl https://example.com` opens Air
        // Traffic Control testing that link, for screenshots.
        if let test = UserDefaults.standard.string(forKey: "ChordShowAirTrafficControl") {
            showAirTrafficControl(routing: URL(string: test), spaceID: first?.state.spaceID)
        }
        NSApp.activate()
    }

    /// Opens http and https links that other apps send. Air Traffic Control
    /// rules decide where each one goes.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard library != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls where HistoryRanking.isRecordable(url) {
            route(url, from: nil)
        }
    }

    /// Opens `url` where the rules send it. A link routed to a space opens
    /// in `window`, or in the frontmost Major Chord window, which switches to
    /// that space. With no route, it opens in that window's current space.
    func route(_ url: URL, from window: BrowserWindowController?) {
        guard let library, let target = window ?? frontWindow() else { return }
        switch library.destination(for: url, fallbackSpace: target.state.spaceID) {
        case .space(let spaceID):
            target.state.selectSpace(spaceID)
            target.state.openTab(url)
            target.showWindow(nil)
        case .minorChord:
            // Minor Chord windows arrive in Phase 4. Until then, open a tab.
            target.state.openTab(url)
            target.showWindow(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            frontWindow()?.showWindow(nil)
        }
        return true
    }

    /// The frontmost Major Chord window, creating one when none is open.
    @discardableResult
    private func frontWindow() -> BrowserWindowController? {
        let ordered = NSApp.orderedWindows.compactMap { window in
            windows.first { $0.window === window }
        }
        if let front = ordered.first ?? windows.last {
            return front
        }
        return makeWindow()
    }

    /// Opens a new Major Chord window. It shows the same tabs as the others,
    /// starting in the space used most recently.
    @objc func newWindow(_ sender: Any?) {
        guard let controller = makeWindow() else { return }
        if controller.state.activeTab == nil {
            controller.newTab(nil)
        }
    }

    @discardableResult
    private func makeWindow() -> BrowserWindowController? {
        guard let library, let sessions else { return nil }
        // The first window reopens the last tab. Later windows start on a new tab.
        let controller = BrowserWindowController(library: library, sessions: sessions,
                                                 spaceID: library.lastSpaceID, showRecentTab: windows.isEmpty)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        if let previous = windows.last?.window, let window = controller.window {
            // Each new window steps down and right from the last one.
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX,
                                                                            y: previous.frame.maxY)))
        }
        windows.append(controller)
        controller.showWindow(nil)
        return controller
    }

    /// Brings the front Major Chord window forward, opening one when none is open.
    @objc func showMainWindow(_ sender: Any?) {
        frontWindow()?.showWindow(nil)
    }

    /// Shows the Air Traffic Control window. With a page URL, the window tests
    /// it and adds a rule for its site, routed to `spaceID`, when none routes it.
    func showAirTrafficControl(routing pageURL: URL?, spaceID: UUID?) {
        guard let library else { return }
        if airTrafficControl == nil {
            airTrafficControl = AirTrafficControlWindowController(library: library)
        }
        airTrafficControl?.show(routing: pageURL, spaceID: spaceID ?? library.lastSpaceID)
    }

    @objc func showAirTrafficControl(_ sender: Any?) {
        showAirTrafficControl(routing: nil, spaceID: nil)
    }

    // MARK: Menu

    private static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Chord",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Air Traffic Control…", action: #selector(showAirTrafficControl(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Chord", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Chord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)),
                         keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open Location…", action: #selector(BrowserWindowController.openPalette(_:)),
                         keyEquivalent: "l")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(BrowserWindowController.closeTab(_:)),
                         keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "W")
        mainMenu.addItem(submenu(fileMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Copy Address", action: #selector(BrowserWindowController.copyAddress(_:)),
                         keyEquivalent: "C")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu(editMenu))

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(BrowserWindowController.toggleSidebar(_:)),
                         keyEquivalent: "s")
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reloadPage(_:)),
                         keyEquivalent: "r")
        mainMenu.addItem(submenu(viewMenu))

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)),
                            keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)),
                            keyEquivalent: "]")
        mainMenu.addItem(submenu(historyMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Chord", action: #selector(showMainWindow(_:)), keyEquivalent: "0")
        mainMenu.addItem(submenu(windowMenu))
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
