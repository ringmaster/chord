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
    let state: WindowState
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

                AddressPill(tab: state.activeTab, action: onOpenPalette)
                    .padding(.horizontal, Design.Sidebar.contentPadding - 4)
                    .padding(.bottom, 12)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !state.contents.favorites.isEmpty {
                            FavoritesGrid(state: state)
                                .padding(.bottom, 10)
                        }
                        ForEach(state.contents.pinned) { tab in
                            TabRow(tab: tab, state: state)
                        }
                        SectionDivider()
                        NewTabRow(action: onNewTab)
                        ForEach(state.contents.open) { tab in
                            TabRow(tab: tab, state: state)
                        }
                    }
                    .padding(.horizontal, Design.Sidebar.contentPadding - 4)
                }
                .scrollIndicators(.never)

                Spacer(minLength: 0)

                SpaceSwitcher(state: state)
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
    let state: WindowState
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(state.contents.favorites) { tab in
                FavoriteTile(tab: tab, active: tab.id == state.activeTabID) {
                    state.activate(tab.id)
                }
                .contextMenu { TabMenu(tab: tab, state: state) }
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
    let state: WindowState
    @State private var hovering = false

    /// A group row is active while any tab in its strip is shown.
    private var active: Bool {
        tab.isGroup ? state.activeGroup?.id == tab.id : tab.id == state.activeTabID
    }

    private var memberCount: Int { state.contents.members[tab.id]?.count ?? 0 }

    var body: some View {
        HStack(spacing: 9) {
            SiteIcon(url: tab.url, size: 16)
                .overlay(alignment: .bottomTrailing) {
                    if tab.isGroup {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tint)
                            .padding(1.5)
                            .background(Circle().fill(.background))
                            .offset(x: 4, y: 4)
                    }
                }
            Text(title)
                .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                .foregroundStyle(.primary.opacity(active ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if tab.isGroup && !hovering && memberCount > 0 {
                Text("\(memberCount + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(.primary.opacity(0.08)))
                    .help("\(memberCount + 1) tabs in this group")
            }
            if hovering {
                Button {
                    state.close(tab.id)
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
        .onTapGesture {
            if tab.isGroup { state.activateGroup(tab.id) } else { state.activate(tab.id) }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: active)
        .contextMenu { TabMenu(tab: tab, state: state) }
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
    let state: WindowState

    var body: some View {
        if tab.isGroup {
            Button("Ungroup Tabs") { state.library.ungroup(tab.id) }
        } else if tab.section != .favorite, let matcher = URLMatcher.suggested(for: tab.url) {
            Button("Group Tabs from \(matcher.value)") { state.library.makeGroup(tab.id, matcher: matcher) }
        }
        if tab.isGroup {
            // A group cannot be a favorite.
        } else if tab.section != .favorite {
            Button("Add to Favorites") { state.move(tab.id, to: .favorite) }
        } else {
            Button("Remove from Favorites") { state.move(tab.id, to: .pinned) }
        }
        if tab.section == .open {
            Button("Pin Tab") { state.move(tab.id, to: .pinned) }
        } else if tab.section == .pinned {
            Button("Unpin Tab") { state.move(tab.id, to: .open) }
        }
        Divider()
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
        }
        Divider()
        Button(tab.isGroup ? "Close Group" : "Close Tab") { state.close(tab.id) }
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
    let state: WindowState

    var body: some View {
        HStack(spacing: 6) {
            Text(state.space.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            ForEach(state.library.spaces) { space in
                SpaceDot(space: space, active: space.id == state.spaceID) {
                    state.selectSpace(space.id)
                }
            }
            Button {
                state.createSpace(named: "Space \(state.library.spaces.count + 1)")
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
