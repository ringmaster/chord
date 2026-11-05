import SwiftUI
import chord_logic

/// The contents of the sidebar card, from top to bottom:
/// - room for the window buttons,
/// - the address pill, which opens the command palette,
/// - favorites as tiles,
/// - pinned tabs, a New Tab row, and open tabs,
/// - the space switcher.
///
/// Empty areas of the card drag the window.
struct SidebarContent: View {
    let library: Library
    var onOpenPalette: () -> Void
    var onNewTab: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Design.Sidebar.headerHeight)

                AddressPill(tab: library.activeTab, action: onOpenPalette)
                    .padding(.horizontal, Design.Sidebar.contentPadding - 4)
                    .padding(.bottom, 12)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !library.contents.favorites.isEmpty {
                            FavoritesGrid(library: library)
                                .padding(.bottom, 10)
                        }
                        ForEach(library.contents.pinned) { tab in
                            TabRow(tab: tab, library: library)
                        }
                        SectionDivider()
                        NewTabRow(action: onNewTab)
                        ForEach(library.contents.open) { tab in
                            TabRow(tab: tab, library: library)
                        }
                    }
                    .padding(.horizontal, Design.Sidebar.contentPadding - 4)
                }
                .scrollIndicators(.never)

                Spacer(minLength: 0)

                SpaceSwitcher(library: library)
                    .padding(.horizontal, Design.Sidebar.contentPadding - 4)
                    .padding(.vertical, 10)
            }
        }
    }
}

// MARK: Address pill

private struct AddressPill: View {
    let tab: BrowserTab?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tab == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.10 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Search or enter an address (⌘L)")
    }

    private var label: String {
        guard let tab else { return "Search or enter address" }
        return tab.url.host() ?? tab.url.absoluteString
    }
}

// MARK: Favorites

private struct FavoritesGrid: View {
    let library: Library
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(library.contents.favorites) { tab in
                FavoriteTile(tab: tab, active: tab.id == library.activeTabID) {
                    library.activate(tab.id)
                }
                .contextMenu { TabMenu(tab: tab, library: library) }
            }
        }
    }
}

private struct FavoriteTile: View {
    let tab: BrowserTab
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SiteIcon(url: tab.url, size: 18)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(active ? 0.16 : hovering ? 0.10 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(tab.title.isEmpty ? (tab.url.host() ?? "") : tab.title)
    }
}

// MARK: Tab rows

private struct TabRow: View {
    let tab: BrowserTab
    let library: Library
    @State private var hovering = false

    private var active: Bool { tab.id == library.activeTabID }

    var body: some View {
        HStack(spacing: 9) {
            SiteIcon(url: tab.url, size: 16)
            Text(title)
                .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                .foregroundStyle(.primary.opacity(active ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering {
                Button {
                    library.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .help(tab.section == .pinned ? "Close pinned tab" : "Close tab")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(active ? 0.13 : hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { library.activate(tab.id) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: active)
        .contextMenu { TabMenu(tab: tab, library: library) }
    }

    private var title: String {
        if !tab.title.isEmpty { return tab.title }
        return tab.url.host() ?? tab.url.absoluteString
    }
}

private struct NewTabRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
            Text("New Tab")
                .font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
    }
}

/// The actions every tab offers on right-click.
private struct TabMenu: View {
    let tab: BrowserTab
    let library: Library

    var body: some View {
        if tab.section != .favorite {
            Button("Add to Favorites") { library.move(tab.id, to: .favorite) }
        } else {
            Button("Remove from Favorites") { library.move(tab.id, to: .pinned) }
        }
        if tab.section == .open {
            Button("Pin Tab") { library.move(tab.id, to: .pinned) }
        } else if tab.section == .pinned {
            Button("Unpin Tab") { library.move(tab.id, to: .open) }
        }
        Divider()
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
        }
        Divider()
        Button("Close Tab") { library.close(tab.id) }
    }
}

// MARK: Site icon

/// A site's icon, or a rounded monogram of its host while no icon is known.
struct SiteIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        if let image = Favicons.shared.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(.primary.opacity(0.12))
                .frame(width: size, height: size)
                .overlay(
                    Text(monogram)
                        .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary))
        }
    }

    private var monogram: String {
        var host = url.host() ?? "?"
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: Spaces

private struct SpaceSwitcher: View {
    let library: Library

    var body: some View {
        HStack(spacing: 6) {
            Text(library.activeSpace.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            ForEach(library.spaces) { space in
                SpaceDot(space: space, active: space.id == library.activeSpace.id) {
                    library.selectSpace(space.id)
                }
            }
            Button {
                library.createSpace(named: "Space \(library.spaces.count + 1)")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("New space")
        }
    }
}

private struct SpaceDot: View {
    let space: Space
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(space.name.first.map { String($0).uppercased() } ?? "•")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(active ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.primary.opacity(active ? 0.16 : hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(space.name)
    }
}
