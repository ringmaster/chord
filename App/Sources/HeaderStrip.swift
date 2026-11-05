import SwiftUI
import chord_logic

/// The row of header tabs above the page while a tab group is shown. The
/// group's own tab comes first, then its members. Empty space in the strip
/// drags the window.
struct HeaderStrip: View {
    let state: WindowState
    var onNewTab: (UUID) -> Void

    /// True when the page sits in a rounded card beside the pinned sidebar.
    private var rounded: Bool { state.library.sidebarPinned }

    var body: some View {
        if let group = state.activeGroup {
            HStack(spacing: 4) {
                ForEach(state.contents.strip(ofGroup: group.id)) { tab in
                    HeaderTab(tab: tab, isGroupTab: tab.id == group.id, state: state)
                }
                NewHeaderTabButton { onNewTab(group.id) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: rounded ? Design.Page.cornerRadius : 0,
                                       topTrailingRadius: rounded ? Design.Page.cornerRadius : 0,
                                       style: .continuous)
                    .fill(.bar)
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true))
            .overlay(alignment: .bottom) {
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            }
        }
    }
}

private struct HeaderTab: View {
    let tab: BrowserTab
    let isGroupTab: Bool
    let state: WindowState
    @State private var hovering = false

    private var active: Bool { tab.id == state.activeTabID }

    var body: some View {
        HStack(spacing: 7) {
            SiteIcon(url: tab.url, size: 14)
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering && !isGroupTab {
                Button {
                    state.close(tab.id)
                } label: {
                    Icon("x", size: 10)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(.primary.opacity(0.08)))
                }
                .buttonStyle(ChromeButtonStyle(shape: .circle))
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 110, idealWidth: 200, maxWidth: 220)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(active ? 0.13 : hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { state.activate(tab.id) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            if !isGroupTab {
                Button("Move Out of Group") { state.move(tab.id, to: .open) }
                Divider()
                Button("Close Tab") { state.close(tab.id) }
            }
        }
        .help(tab.url.absoluteString)
    }

    private var title: String {
        if !tab.title.isEmpty { return tab.title }
        return tab.url.host() ?? tab.url.absoluteString
    }
}

private struct NewHeaderTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon("plus", size: 14)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle(shape: .roundedRectangle(cornerRadius: 7)))
        .onHover { hovering = $0 }
        .help("New tab in this group")
    }
}
