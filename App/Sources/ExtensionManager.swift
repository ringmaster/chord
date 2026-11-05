import AppKit
import Observation
import OSLog
import SwiftUI
import WebKit
import chord_logic

/// Loads the installed web extensions into one `WKWebExtensionController`,
/// which every web view shares, and answers WebKit's questions about Chord's
/// windows and tabs.
///
/// An extension's API permissions are granted when it is added. Access to
/// websites is not: the extension asks, and Chord shows a prompt, or the user
/// grants it in the Extensions window. Every grant is saved in the database
/// and applied again at each launch.
@MainActor
@Observable
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "extensions")

    /// A loaded extension and its saved record.
    struct Loaded: Identifiable {
        var installed: InstalledExtension
        var context: WKWebExtensionContext
        var id: UUID { installed.id }
        var webExtension: WKWebExtension { context.webExtension }
    }

    private(set) var installed: [InstalledExtension] = []
    private(set) var loaded: [UUID: Loaded] = [:]
    /// Why an extension failed to load, by extension id.
    private(set) var loadErrors: [UUID: String] = [:]

    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored private let database: ChordDatabase
    /// Where an action's popup appears: the view and the rect in it.
    @ObservationIgnored var popupAnchor: (view: NSView, rect: NSRect)?

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    init(database: ChordDatabase) {
        self.database = database
        // A fixed identifier keeps extension storage between launches.
        let identifier = UUID(uuidString: "6A1F3C2E-8B4D-4E7A-9C1B-2D3E4F5A6B7C")!
        controller = WKWebExtensionController(configuration: WKWebExtensionController.Configuration(identifier: identifier))
        super.init()
        controller.delegate = self
        // WebKit records an extension's errors, such as a background script
        // that fails to start, on its context. They go to the log in full.
        NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification,
                                               object: nil, queue: .main) { notification in
            guard let context = notification.object as? WKWebExtensionContext else { return }
            MainActor.assumeIsolated {
                let name = context.webExtension.displayName ?? "Extension"
                for error in context.errors {
                    let nsError = error as NSError
                    ExtensionManager.log.error("\(name, privacy: .public): \(nsError.localizedDescription, privacy: .public) \(String(describing: nsError.userInfo), privacy: .public)")
                }
            }
        }
        reloadInstalled()
        Task { await loadAllEnabled() }
    }

    // MARK: Installed extensions

    private func reloadInstalled() {
        do {
            installed = try database.installedExtensions()
        } catch {
            ExtensionManager.log.error("Could not read extensions: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadAllEnabled() async {
        for item in installed where item.enabled {
            await load(item)
        }
    }

    /// Adds an unpacked extension folder or a Safari web extension bundle and loads it.
    func add(source: InstalledExtension.Source, url: URL) async {
        do {
            let webExtension = try await Self.makeExtension(source: source, url: url)
            let name = webExtension.displayName ?? url.deletingPathExtension().lastPathComponent
            var item = try database.addExtension(source: source, path: url.path, name: name)
            item.grantedPermissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
            try database.updateExtension(item)
            reloadInstalled()
            await load(item)
        } catch {
            ExtensionManager.log.error("Could not add extension: \(error.localizedDescription, privacy: .public)")
            loadErrors[UUID()] = error.localizedDescription
        }
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard var item = installed.first(where: { $0.id == id }) else { return }
        item.enabled = enabled
        save(item)
        if enabled {
            await load(item)
        } else {
            unload(id)
        }
    }

    func remove(_ id: UUID) {
        unload(id)
        do {
            try database.removeExtension(id: id)
        } catch {
            ExtensionManager.log.error("Could not remove extension: \(error.localizedDescription, privacy: .public)")
        }
        loadErrors[id] = nil
        reloadInstalled()
    }

    /// Grants every website the extension asked for, including all sites when it asked for that.
    func grantAllRequestedSites(_ id: UUID) {
        guard let entry = loaded[id] else { return }
        let patterns = entry.webExtension.allRequestedMatchPatterns
        for pattern in patterns {
            entry.context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        var item = entry.installed
        item.grantedMatchPatterns = Array(Set(item.grantedMatchPatterns + patterns.map(\.string))).sorted()
        save(item)
    }

    /// Removes every website grant.
    func revokeSites(_ id: UUID) {
        guard let entry = loaded[id] else { return }
        for pattern in entry.context.grantedPermissionMatchPatterns.keys {
            entry.context.setPermissionStatus(.requestedExplicitly, for: pattern)
        }
        var item = entry.installed
        item.grantedMatchPatterns = []
        save(item)
    }

    private func save(_ item: InstalledExtension) {
        do {
            try database.updateExtension(item)
        } catch {
            ExtensionManager.log.error("Could not save extension: \(error.localizedDescription, privacy: .public)")
        }
        reloadInstalled()
        if var entry = loaded[item.id] {
            entry.installed = item
            loaded[item.id] = entry
        }
    }

    private static func makeExtension(source: InstalledExtension.Source, url: URL) async throws -> WKWebExtension {
        switch source {
        case .folder:
            return try await WKWebExtension(resourceBaseURL: url)
        case .appExtension:
            guard let bundle = Bundle(url: url) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            return try await WKWebExtension(appExtensionBundle: bundle)
        }
    }

    private func load(_ item: InstalledExtension) async {
        guard loaded[item.id] == nil else { return }
        do {
            let webExtension = try await Self.makeExtension(source: item.source, url: URL(filePath: item.path))
            let context = WKWebExtensionContext(for: webExtension)
            // A stable identifier keeps the extension's storage and its
            // extension-page origin the same between launches.
            context.uniqueIdentifier = item.id.uuidString
            context.isInspectable = true
            for permission in item.grantedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
            }
            for string in item.grantedMatchPatterns {
                if let pattern = try? WKWebExtension.MatchPattern(string: string) {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
            }
            try controller.load(context)
            loaded[item.id] = Loaded(installed: item, context: context)
            loadErrors[item.id] = nil
            announceOpenWindowsAndTabs(to: context)
        } catch {
            ExtensionManager.log.error("Could not load \(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            loadErrors[item.id] = error.localizedDescription
        }
    }

    private func unload(_ id: UUID) {
        guard let entry = loaded[id] else { return }
        try? controller.unload(entry.context)
        loaded[id] = nil
    }

    /// Tells a newly loaded extension about the windows and tabs already open.
    private func announceOpenWindowsAndTabs(to context: WKWebExtensionContext) {
        for window in appDelegate?.extensionWindows() ?? [] {
            context.didOpenWindow(window)
            for tab in window.tabs?(for: context) ?? [] {
                context.didOpenTab(tab)
            }
        }
    }

    // MARK: Toolbar actions

    /// Clicks an extension's toolbar button for `tab`.
    func performAction(_ id: UUID, for tab: (any WKWebExtensionTab)?, anchor: (view: NSView, rect: NSRect)) {
        guard let entry = loaded[id] else { return }
        popupAnchor = anchor
        entry.context.performAction(for: tab)
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        appDelegate?.extensionWindows() ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        NSApp.keyWindow?.windowController as? any WKWebExtensionWindow
            ?? appDelegate?.extensionWindows().first
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let url = configuration.url ?? URL(string: "about:blank")!
        completionHandler(appDelegate?.openTabForExtension(url, activate: configuration.shouldBeActive), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        completionHandler(appDelegate?.openWindowForExtension(urls: configuration.tabURLs), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        showOptionsPage(for: extensionContext)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let names = permissions.map(\.rawValue).sorted()
        askPermission(for: extensionContext, asking: "use these features", items: names) { [weak self] allowed in
            guard allowed else { return completionHandler([], nil) }
            self?.recordGrant(extensionContext) { $0.grantedPermissions = Array(Set($0.grantedPermissions + names)).sorted() }
            completionHandler(permissions, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap { $0.host() }).sorted()
        askPermission(for: extensionContext, asking: "read and change these sites", items: hosts) { [weak self] allowed in
            guard allowed else { return completionHandler([], nil) }
            let patterns = hosts.map { "*://\($0)/*" }
            self?.recordGrant(extensionContext) {
                $0.grantedMatchPatterns = Array(Set($0.grantedMatchPatterns + patterns)).sorted()
            }
            completionHandler(urls, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let strings = matchPatterns.map(\.string).sorted()
        askPermission(for: extensionContext, asking: "read and change these sites", items: strings) { [weak self] allowed in
            guard allowed else { return completionHandler([], nil) }
            self?.recordGrant(extensionContext) {
                $0.grantedMatchPatterns = Array(Set($0.grantedMatchPatterns + strings)).sorted()
            }
            completionHandler(matchPatterns, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else {
            return completionHandler(nil)
        }
        if let anchor = popupAnchor, anchor.view.window != nil {
            popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxX)
        } else if let view = NSApp.keyWindow?.contentView {
            popover.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1),
                         of: view, preferredEdge: .minY)
        }
        completionHandler(nil)
    }

    // MARK: Native messaging

    /// Open `connectNative` ports and their hosts. Releasing a port disconnects it.
    @ObservationIgnored private var nativePorts: [ObjectIdentifier: (port: WKWebExtension.MessagePort, host: NativeHostConnection)] = [:]
    /// Hosts started for one `sendNativeMessage`, kept until they reply or quit.
    @ObservationIgnored private var oneShotHosts: [ObjectIdentifier: NativeHostConnection] = [:]

    /// The host manifest that lets this extension reach `name`.
    private func nativeHostManifest(named name: String?, for context: WKWebExtensionContext) throws
        -> (manifest: NativeMessagingHostManifest, origin: String) {
        guard let name, !name.isEmpty else { throw NativeMessagingError.noApplicationName }
        guard let item = loaded.values.first(where: { $0.context === context })?.installed else {
            throw NativeMessagingError.noExtensionID
        }
        guard item.source == .folder else { throw NativeMessagingError.safariAppExtension }
        guard let id = ChromeExtensionID.id(forExtensionFolder: URL(filePath: item.path)) else {
            throw NativeMessagingError.noExtensionID
        }
        let origin = ChromeExtensionID.origin(for: id)
        do {
            let folders = NativeMessagingHosts.defaultFolders(home: FileManager.default.homeDirectoryForCurrentUser)
            return (try NativeMessagingHosts.manifest(named: name, for: origin, in: folders), origin)
        } catch let error as NativeMessagingHosts.LookupError {
            throw NativeMessagingError.lookup(error)
        }
    }

    /// `runtime.sendNativeMessage`: starts the host, sends one message, and
    /// replies with the host's first message. The host is then closed.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        do {
            let (manifest, origin) = try nativeHostManifest(named: applicationIdentifier, for: extensionContext)
            let host = try NativeHostConnection.start(manifest: manifest, origin: origin)
            let key = ObjectIdentifier(host)
            oneShotHosts[key] = host
            var replied = false
            host.onMessage = { [weak host] reply in
                guard !replied else { return }
                replied = true
                replyHandler(reply, nil)
                host?.close()
            }
            host.onClose = { [weak self] error in
                self?.oneShotHosts[key] = nil
                guard !replied else { return }
                replied = true
                replyHandler(nil, error ?? NativeMessagingError.closedWithoutReply)
            }
            try host.send(message)
        } catch {
            ExtensionManager.log.error("Native message failed: \(error.localizedDescription, privacy: .public)")
            replyHandler(nil, error)
        }
    }

    /// `runtime.connectNative`: starts the host and joins it to the port until
    /// either side disconnects.
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        do {
            let (manifest, origin) = try nativeHostManifest(named: port.applicationIdentifier, for: extensionContext)
            let host = try NativeHostConnection.start(manifest: manifest, origin: origin)
            let key = ObjectIdentifier(port)
            nativePorts[key] = (port, host)
            port.messageHandler = { [weak host] message, error in
                guard error == nil, let message else { return }
                MainActor.assumeIsolated {
                    do {
                        try host?.send(message)
                    } catch {
                        ExtensionManager.log.error("Could not send to host: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            port.disconnectHandler = { [weak self, weak host] _ in
                MainActor.assumeIsolated {
                    host?.close()
                    self?.nativePorts[key] = nil
                }
            }
            host.onMessage = { [weak port] message in
                port?.sendMessage(message, completionHandler: nil)
            }
            host.onClose = { [weak self, weak port] error in
                if let port, !port.isDisconnected {
                    port.disconnect(throwing: error)
                }
                self?.nativePorts[key] = nil
            }
            completionHandler(nil)
        } catch {
            ExtensionManager.log.error("Native connection failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    // MARK: Prompts and pages

    private func recordGrant(_ context: WKWebExtensionContext, _ change: (inout InstalledExtension) -> Void) {
        guard var item = loaded.values.first(where: { $0.context === context })?.installed else { return }
        change(&item)
        save(item)
    }

    /// Shows a permission prompt as a sheet on the key window.
    private func askPermission(for context: WKWebExtensionContext, asking: String, items: [String],
                               completion: @escaping (Bool) -> Void) {
        guard let window = NSApp.keyWindow ?? appDelegate?.extensionWindows().first.flatMap({ ($0 as? NSWindowController)?.window }) else {
            return completion(false)
        }
        let name = context.webExtension.displayName ?? "An extension"
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        let icon = context.webExtension.icon(for: NSSize(width: 48, height: 48))
        let prompt = PermissionPrompt(name: name, asking: asking, items: items, icon: icon) { [weak window, weak panel] allowed in
            if let panel { window?.endSheet(panel) }
            completion(allowed)
        }
        let host = NSHostingView(rootView: prompt)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        window.beginSheet(panel)
    }

    @ObservationIgnored private var optionsWindows: [NSWindow] = []

    /// Shows an extension's options page in its own small window. The page
    /// needs the extension's own web view configuration to work.
    func showOptionsPage(for context: WKWebExtensionContext) {
        guard let url = context.optionsPageURL, let configuration = context.webViewConfiguration else { return }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 560), configuration: configuration)
        webView.load(URLRequest(url: url))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(context.webExtension.displayName ?? "Extension") Options"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        optionsWindows.append(window)
    }
}

/// The sheet that asks whether an extension may have a permission.
private struct PermissionPrompt: View {
    let name: String
    let asking: String
    let items: [String]
    let icon: NSImage?
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 28)).frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 15, weight: .semibold))
                    Text("wants to \(asking):").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(.primary.opacity(0.07)))
                }
            }
            HStack {
                Spacer()
                Button("Don't Allow") { onAnswer(false) }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { onAnswer(true) }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
