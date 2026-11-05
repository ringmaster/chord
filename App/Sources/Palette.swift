import SwiftUI
import chord_logic

/// What pressing Return on an address or a search does.
enum PaletteMode {
    /// Opens a new tab. Command-T opens the palette this way.
    case newTab
    /// Loads the page in the active tab. Command-L opens the palette this way,
    /// with the active tab's address filled in.
    case currentTab
}

/// The state of an open command palette: the typed text, the rows, and the
/// selected row. `PaletteResults` decides the rows.
@MainActor
@Observable
final class PaletteModel {
    let mode: PaletteMode
    var query: String {
        didSet { refresh() }
    }
    var selection: TextSelection?
    private(set) var items: [PaletteItem] = []
    var selectedIndex = 0

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let tabs: [BrowserTab]
    @ObservationIgnored private let commands: [PaletteCommand]
    @ObservationIgnored let onPerform: (PaletteItem, PaletteMode) -> Void
    @ObservationIgnored let onDismiss: () -> Void

    init(mode: PaletteMode, initialText: String, library: Library, tabs: [BrowserTab], commands: [PaletteCommand],
         onPerform: @escaping (PaletteItem, PaletteMode) -> Void, onDismiss: @escaping () -> Void) {
        self.mode = mode
        self.query = initialText
        self.library = library
        self.tabs = tabs
        self.commands = commands
        self.onPerform = onPerform
        self.onDismiss = onDismiss
        if !initialText.isEmpty {
            selection = TextSelection(range: initialText.startIndex..<initialText.endIndex)
        }
        refresh()
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + items.count) % items.count
    }

    func performSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        perform(items[selectedIndex])
    }

    func perform(_ item: PaletteItem) {
        onDismiss()
        onPerform(item, mode)
    }

    private func refresh() {
        let history = (try? library.database.searchHistory(query, limit: PaletteResults.maximumHistory * 2)) ?? []
        items = PaletteResults.build(query: query, tabs: tabs, commands: commands,
                                     history: history, engine: library.searchEngine)
        selectedIndex = 0
    }
}

/// The command palette: a glass card near the top of the window with a text
/// field and the rows below it. A click outside the card closes it.
struct PaletteView: View {
    @Bindable var model: PaletteModel
    @FocusState private var fieldFocused: Bool
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(appeared ? 0.12 : 0)
                .contentShape(Rectangle())
                .onTapGesture { model.onDismiss() }

            VStack(spacing: 0) {
                field
                if !model.items.isEmpty {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 1)
                    results
                }
            }
            .frame(width: Design.Palette.width)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Design.Palette.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, Design.Palette.topOffset)
            .scaleEffect(appeared ? 1 : 0.97, anchor: .top)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            fieldFocused = true
            // The hosting view becomes first responder after this view
            // appears, so focus is set again on the next turn of the run loop.
            Task { @MainActor in fieldFocused = true }
            withAnimation(.spring(duration: 0.22, bounce: 0.15)) { appeared = true }
        }
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: model.mode == .newTab ? "plus.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: $model.query, selection: $model.selection,
                      prompt: Text(model.mode == .newTab ? "Search or enter address" : "Go to address, search, or run a command"))
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($fieldFocused)
                // The window controller handles Return, Escape, and the arrow
                // keys before the field sees them.
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        PaletteRow(item: item, selected: index == model.selectedIndex)
                            .id(index)
                            .onTapGesture { model.perform(item) }
                            .onHover { if $0 { model.selectedIndex = index } }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: Design.Palette.maximumResultsHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.selectedIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
    }
}

/// One row: an icon, a title, a detail line, and a hint for what Return does.
private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(hint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .navigate(let url):
            SiteIcon(url: url, size: 18)
        case .search:
            symbol("magnifyingglass")
        case .tab(let tab):
            SiteIcon(url: tab.url, size: 18)
        case .history(let entry):
            SiteIcon(url: entry.url, size: 18)
        case .command(let command):
            symbol(command.symbol)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.08)))
    }

    private var title: String {
        switch item {
        case .navigate(let url): url.absoluteString
        case .search(let query, _, _): query
        case .tab(let tab): tab.title.isEmpty ? (tab.url.host() ?? tab.url.absoluteString) : tab.title
        case .history(let entry): entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title
        case .command(let command): command.title
        }
    }

    private var detail: String? {
        switch item {
        case .navigate: nil
        case .search(_, let engine, _): "Search \(engine.name)"
        case .tab(let tab): tab.url.absoluteString
        case .history(let entry): entry.url.absoluteString
        case .command(let command): command.shortcut
        }
    }

    private var hint: String {
        switch item {
        case .navigate: "Open ↩"
        case .search: "Search ↩"
        case .tab: "Switch to Tab ↩"
        case .history: "Open ↩"
        case .command: "Run ↩"
        }
    }
}
