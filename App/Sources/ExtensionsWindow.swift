import AppKit
import SwiftUI
import WebKit
import chord_logic

/// The Extensions window: the installed web extensions, and the Safari web
/// extensions found inside installed apps, ready to add.
@MainActor
final class ExtensionsWindowController: NSWindowController {
    init(manager: ExtensionManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Extensions"
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Extensions")

        // The container gets its size before the hosting view is sized from it.
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 720, height: 640))
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        let host = NSHostingView(rootView: ExtensionsView(manager: manager))
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        window.contentView = background
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ExtensionsWindowController is created in code only")
    }
}

private struct ExtensionsView: View {
    let manager: ExtensionManager
    @State private var found: [SafariExtensionScanner.Found] = []

    private var available: [SafariExtensionScanner.Found] {
        let installedPaths = Set(manager.installed.map(\.path))
        return found.filter { !installedPaths.contains($0.bundleURL.path) }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                header
                    .padding(.bottom, 10)
                if manager.installed.isEmpty {
                    Text("No extensions yet. Add one from your apps below, or add an unpacked extension folder.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }
                ForEach(manager.installed) { item in
                    ExtensionCard(item: item, manager: manager)
                }

                if !available.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Found in your apps")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Safari web extensions that installed apps carry. Adding one loads it into Chord.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 18)
                    ForEach(available, id: \.bundleURL) { item in
                        FoundRow(item: item) {
                            Task { await manager.add(source: .appExtension, url: item.bundleURL) }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 32)
        }
        .task {
            let folders = [URL(filePath: "/Applications"),
                           FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
            found = await Task.detached { SafariExtensionScanner.scan(applicationFolders: folders) }.value
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Extensions")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Extensions work in every tab. Sites stay closed to an extension until you allow them.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Folder…") { chooseFolder() }
                .buttonStyle(QuietButtonStyle())
                .help("Add an unpacked extension: a folder with a manifest.json")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Extension"
        panel.message = "Choose a folder that holds an extension's manifest.json."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await manager.add(source: .folder, url: url) }
    }
}

private struct ExtensionCard: View {
    let item: InstalledExtension
    let manager: ExtensionManager
    @State private var hovering = false

    private var loaded: ExtensionManager.Loaded? { manager.loaded[item.id] }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(loaded?.webExtension.displayName ?? item.name)
                        .font(.system(size: 14, weight: .semibold))
                    if let version = loaded?.webExtension.displayVersion {
                        Text(version).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Text(item.source == .appExtension ? "Safari" : "Folder")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
                if let description = loaded?.webExtension.displayDescription {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let error = manager.loadErrors[item.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                if loaded != nil {
                    siteAccess
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                EnabledSwitch(isOn: item.enabled) { value in
                    Task { await manager.setEnabled(item.id, value) }
                }
                Button {
                    manager.remove(item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChromeButtonStyle(shape: .roundedRectangle(cornerRadius: 7)))
                .opacity(hovering ? 1 : 0)
                .help("Remove extension")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.primary.opacity(hovering ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.primary.opacity(0.07), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private var icon: some View {
        if let image = loaded?.webExtension.icon(for: NSSize(width: 40, height: 40)) {
            Image(nsImage: image).resizable().frame(width: 40, height: 40)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.08))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary))
        }
    }

    /// What sites the extension may read, with buttons to change it.
    @ViewBuilder private var siteAccess: some View {
        let requested = loaded?.webExtension.allRequestedMatchPatterns.map(\.string).sorted() ?? []
        let granted = item.grantedMatchPatterns
        HStack(spacing: 8) {
            Image(systemName: granted.isEmpty ? "lock" : "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(granted.isEmpty ? .secondary : Color.accentColor)
            Text(siteSummary(granted: granted, requested: requested))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !requested.isEmpty && Set(requested).isSubset(of: Set(granted)) == false {
                Button("Allow Requested Sites") { manager.grantAllRequestedSites(item.id) }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .help(requested.joined(separator: "\n"))
            }
            if !granted.isEmpty {
                Button("Remove Site Access") { manager.revokeSites(item.id) }
                    .buttonStyle(QuietButtonStyle())
            }
            if loaded?.webExtension.hasOptionsPage == true, let context = loaded?.context {
                Button("Options") { manager.showOptionsPage(for: context) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.top, 2)
    }

    private func siteSummary(granted: [String], requested: [String]) -> String {
        if granted.contains("<all_urls>") || granted.contains("*://*/*") { return "Allowed on all sites" }
        if !granted.isEmpty { return "Allowed on \(granted.count) site\(granted.count == 1 ? "" : "s")" }
        if requested.isEmpty { return "Asks for site access when it needs it" }
        return "No site access yet"
    }
}

private struct FoundRow: View {
    let item: SafariExtensionScanner.Found
    let onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.appURL.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13, weight: .medium))
                Text(item.appURL.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add", action: onAdd)
                .buttonStyle(QuietButtonStyle(prominent: true))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.primary.opacity(hovering ? 0.06 : 0.03)))
        .onHover { hovering = $0 }
    }
}
