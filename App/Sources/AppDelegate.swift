import AppKit
import OSLog

/// The application shell. It builds the main menu and opens the first browser
/// window at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "app")

    /// Open browser windows. A window controller removes itself when its window closes.
    private var browserWindows: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.log.notice("Chord launched")
        // The main menu carries the standard key equivalents, such as Command-Q
        // and Command-V. With no main menu, those keys reach nothing.
        NSApp.mainMenu = AppDelegate.buildMainMenu()
        openBrowserWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openBrowserWindow(nil)
        }
        return true
    }

    @objc func openBrowserWindow(_ sender: Any?) {
        let controller = BrowserWindowController(startURL: BrowserWindowController.homeURL)
        controller.onClose = { [weak self, weak controller] in
            self?.browserWindows.removeAll { $0 === controller }
        }
        browserWindows.append(controller)
        controller.showWindow(nil)
    }

    private static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Chord",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Chord", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Chord", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        mainMenu.addItem(submenu(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(openBrowserWindow(_:)),
                         keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        mainMenu.addItem(submenu(fileMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        mainMenu.addItem(submenu(editMenu))

        return mainMenu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
