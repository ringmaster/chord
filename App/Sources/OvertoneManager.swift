import AppKit
import CoreServices
import Observation
import OSLog
import WebKit
import chord_logic

extension Notification.Name {
    /// Posted after the overtones folder changed and the overtones were read again.
    static let overtonesChanged = Notification.Name("ChordOvertonesChanged")
}

/// Loads overtones from `~/Library/Application Support/Chord/Overtones`,
/// watches that folder, and installs the right overtones into a web view
/// before each page loads.
///
/// Overtones run in their own content world, so the page's scripts cannot see
/// or change them. They share the page's DOM, which is how their styles and
/// HTML take effect.
@MainActor
@Observable
final class OvertoneManager {
    static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "overtones")
    static let contentWorld = WKContentWorld.world(name: "ChordOvertones")

    private(set) var overtones: [Overtone] = []
    @ObservationIgnored let folder: URL
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
        startWatching()
    }

    static func defaultFolder() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Chord/Overtones")
    }

    /// Reads the folder again and tells open pages when anything changed.
    /// A page action reloads at once after a write, and the folder watcher
    /// reloads again a moment later; the second one finds no change, so the
    /// page reloads only once.
    func reload() {
        let loaded = OvertoneLibrary.load(from: folder)
        guard loaded != overtones else { return }
        overtones = loaded
        OvertoneManager.log.notice("Loaded \(self.overtones.count) overtones")
        NotificationCenter.default.post(name: .overtonesChanged, object: self)
    }

    /// The overtones for `url`, given the ids that matching rules name.
    func applicable(to url: URL, ruleOvertoneIDs: [String]) -> [Overtone] {
        OvertoneLibrary.applicable(to: url, overtones: overtones, ruleOvertoneIDs: ruleOvertoneIDs)
    }

    /// Replaces the web view's overtone scripts with the ones for `url`.
    /// Call it before the page at `url` loads; scripts apply to the next page.
    /// Returns the ids installed.
    @discardableResult
    func install(on webView: WKWebView, for url: URL, ruleOvertoneIDs: [String]) -> [String] {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let chosen = applicable(to: url, ruleOvertoneIDs: ruleOvertoneIDs)
        for overtone in chosen {
            if let source = OvertoneScript.styles(for: overtone) {
                controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                      forMainFrameOnly: true, in: OvertoneManager.contentWorld))
            }
            if let source = OvertoneScript.body(for: overtone) {
                controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                      forMainFrameOnly: true, in: OvertoneManager.contentWorld))
            }
        }
        return chosen.map(\.id)
    }

    /// Opens the overtones folder in the Finder.
    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Watching the folder

    private func startWatching() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let manager = Unmanaged<OvertoneManager>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { manager.folderChanged() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               UInt32(kFSEventStreamCreateFlagFileEvents)) else {
            OvertoneManager.log.error("Could not watch the overtones folder")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Several file events arrive for one save, so the reload waits for them to settle.
    private func folderChanged() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }
}

/// Keeps one web view's overtones current: installs them before each page
/// loads, and reloads the page when its overtones' files change.
@MainActor
final class OvertoneBinding {
    private weak var webView: WKWebView?
    private let manager: OvertoneManager
    private let library: Library
    private var installedIDs: [String] = []
    private var observer: NSObjectProtocol?

    init(webView: WKWebView, manager: OvertoneManager, library: Library) {
        self.webView = webView
        self.manager = manager
        self.library = library
        observer = NotificationCenter.default.addObserver(forName: .overtonesChanged, object: manager,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overtonesChanged() }
        }
    }

    // The deinit runs on the main actor, where the observer was added.
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Call before a main-frame page at `url` loads.
    func prepare(for url: URL) {
        guard let webView else { return }
        installedIDs = manager.install(on: webView, for: url, ruleOvertoneIDs: library.decide(url).overtones)
    }

    /// A page that had overtones, or now has some, reloads with the new files.
    private func overtonesChanged() {
        guard let webView, let url = webView.url else { return }
        let ruleIDs = library.decide(url).overtones
        let now = manager.applicable(to: url, ruleOvertoneIDs: ruleIDs).map(\.id)
        guard !now.isEmpty || !installedIDs.isEmpty else { return }
        prepare(for: url)
        webView.reload()
    }
}

/// The overtone a page action writes: the folder for the page's domain when
/// the action started. A write reloads the overtones at once, which reloads
/// the page, and returns after the page has loaded with the change.
@MainActor
final class FolderOvertoneWorkspace: OvertoneWorkspace {
    let folder: URL
    private let manager: OvertoneManager
    private weak var webView: WKWebView?
    /// True after the first file was written or deleted.
    private(set) var hasWritten = false

    /// Nil when the page has no domain to write an overtone for.
    init?(manager: OvertoneManager, webView: WKWebView) {
        guard let url = webView.url,
              let name = OvertoneFiles.folderName(for: url, existing: manager.overtones) else { return nil }
        self.folder = manager.folder.appending(path: name)
        self.manager = manager
        self.webView = webView
    }

    func context() -> OvertoneContext {
        OvertoneContext(folderName: folder.lastPathComponent, files: OvertoneFiles.read(folder))
    }

    func write(file: String, content: String) async throws {
        try OvertoneFiles.write(file, content: content, in: folder)
        hasWritten = true
        OvertoneManager.log.notice("Page action wrote \(file, privacy: .public) in \(self.folder.lastPathComponent, privacy: .public)")
        manager.reload()
        // The page reload starts from a notification; give it a moment, then
        // wait for the load and for the overtone's scripts to run.
        try? await Task.sleep(for: .milliseconds(300))
        var waited = 0
        while webView?.isLoading == true && waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        try? await Task.sleep(for: .milliseconds(500))
    }
}
