import AppKit
import SwiftUI
import chord_logic

/// The Air Traffic Control window: the rules that decide where links open.
///
/// The top of the window is a test field. Type or paste a link, and the window
/// shows where it would open and highlights the rules that match. Below it,
/// each rule is a card that reads as a sentence, and each part of the sentence
/// is edited in place.
@MainActor
final class AirTrafficControlWindowController: NSWindowController, NSWindowDelegate {
    let model: AirTrafficControlModel

    init(library: Library, overtones: OvertoneManager) {
        model = AirTrafficControlModel(library: library, overtones: overtones)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Air Traffic Control"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AirTrafficControl")

        // The container gets its final size before the hosting view is sized
        // from it. Autoresizing from a zero-size container stretches wrongly.
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 780, height: 680))
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        let host = NSHostingView(rootView: AirTrafficControlView(model: model))
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        window.contentView = background
        if window.frame.origin == .zero {
            window.center()
        }
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AirTrafficControlWindowController is created in code only")
    }

    /// Shows the window. With a page URL, the test field holds it, and a new
    /// rule for that site is added when no rule routes it yet.
    func show(routing pageURL: URL?, spaceID: UUID) {
        model.newRuleSpaceID = spaceID
        if let pageURL {
            model.testText = pageURL.absoluteString
            model.addRuleForTestedSiteIfUnrouted()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The state behind the Air Traffic Control window.
@MainActor
@Observable
final class AirTrafficControlModel {
    let library: Library
    let overtones: OvertoneManager
    var testText = ""
    /// The rule that was just added, so its card can scroll into view and glow.
    var highlightedRuleID: UUID?
    /// The space a new rule routes to: the space of the window that opened
    /// Air Traffic Control.
    var newRuleSpaceID: UUID?

    init(library: Library, overtones: OvertoneManager) {
        self.library = library
        self.overtones = overtones
    }

    /// The URL in the test field, read the way the palette reads an address.
    var testURL: URL? {
        guard case .address(let url) = AddressInput().resolve(testText) else { return nil }
        return url
    }

    var testDecision: RoutingDecision? {
        testURL.map(library.decide)
    }

    /// The group the tested link would open in: a group in the space the
    /// link is routed to, or in the space a new rule would route to.
    var testGroup: BrowserTab? {
        guard let url = testURL else { return nil }
        let spaceID: UUID
        if case .space(let routed) = library.decide(url).route {
            spaceID = routed
        } else {
            spaceID = newRuleSpaceID ?? library.lastSpaceID
        }
        return library.contents(of: spaceID)?.group(for: url)
    }

    func addRule(_ matcher: URLMatcher) {
        let route = Route.space(newRuleSpaceID ?? library.lastSpaceID)
        if let rule = library.addRule(matcher: matcher, actions: RuleActions(route: route)) {
            highlightedRuleID = rule.id
        }
    }

    /// Adds a rule for the tested site when no rule routes it yet.
    func addRuleForTestedSiteIfUnrouted() {
        guard let url = testURL, library.decide(url).route == nil,
              let matcher = URLMatcher.suggested(for: url) else { return }
        addRule(matcher)
    }

    func addEmptyRule() {
        addRule(URLMatcher(scope: .domain, value: ""))
    }
}

// MARK: Window content

struct AirTrafficControlView: View {
    @Bindable var model: AirTrafficControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 20)

            TestField(model: model)
                .padding(.horizontal, 32)
                .padding(.bottom, 18)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        if model.library.rules.isEmpty {
                            EmptyRules(onAdd: model.addEmptyRule)
                        }
                        ForEach(Array(model.library.rules.enumerated()), id: \.element.id) { index, rule in
                            RuleCard(rule: rule, index: index, model: model)
                                .id(rule.id)
                        }
                        if !model.library.rules.isEmpty {
                            AddRuleButton(action: model.addEmptyRule)
                        }
                        GroupSection(model: model)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.highlightedRuleID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Air Traffic Control")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Rules decide where links open. Rules higher in the list are checked first.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Test field

private struct TestField: View {
    @Bindable var model: AirTrafficControlModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("", text: $model.testText, prompt: Text("Paste a link to see where it goes"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                if !model.testText.isEmpty {
                    Button {
                        model.testText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            if let url = model.testURL, let decision = model.testDecision {
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                TestResult(url: url, decision: decision, model: model)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.opacity(0.6))
                .shadow(color: .black.opacity(focused ? 0.12 : 0.05), radius: focused ? 10 : 4, y: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.6) : .primary.opacity(0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.18), value: model.testURL)
    }
}

private struct TestResult: View {
    let url: URL
    let decision: RoutingDecision
    let model: AirTrafficControlModel

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(url: url, size: 16)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            DestinationLabel(route: decision.route, library: model.library, fallback: true)
            if let group = model.testGroup {
                Text("· \(group.title.isEmpty ? "a" : group.title) group")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if decision.route == nil, let matcher = URLMatcher.suggested(for: url) {
                Button {
                    model.addRule(matcher)
                } label: {
                    Label("Make a rule for \(matcher.value)", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            } else if let index = decision.routeRuleID.flatMap({ id in model.library.rules.firstIndex { $0.id == id } }) {
                Text("Rule \(index + 1) decides")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Work space", "Minor Chord window · Personal", or the fallback wording.
private struct DestinationLabel: View {
    let route: Route?
    let library: Library
    /// When true and there is no route, says where the link opens anyway.
    var fallback = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(route == nil ? .secondary : .primary)
    }

    private var symbol: String {
        switch route {
        case .space: "square.stack"
        case .minorChord: "macwindow"
        case nil: "square.dashed"
        }
    }

    private var text: String {
        switch route {
        case .space(let id):
            let name = library.spaces.first { $0.id == id }?.name ?? "Missing space"
            return "\(name) space"
        case .minorChord(let profileID):
            let name = library.profiles.first { $0.id == profileID }?.name ?? "Missing profile"
            return "Minor Chord window · \(name)"
        case nil:
            return fallback ? "The current space (no rule matches)" : "Anywhere"
        }
    }
}

// MARK: Rule cards

private struct RuleCard: View {
    let rule: Rule
    let index: Int
    let model: AirTrafficControlModel
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var glow = false

    private var library: Library { model.library }
    private var decision: RoutingDecision? { model.testDecision }
    private var matchesTest: Bool { decision?.matchedRuleIDs.contains(rule.id) ?? false }
    private var decidesTest: Bool { decision?.routeRuleID == rule.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DragHandle(visible: hovering)
                .draggable(rule.id.uuidString)

            EnabledSwitch(isOn: rule.enabled) { enabled in
                var updated = rule
                updated.enabled = enabled
                library.updateRule(updated)
            }

            FlowSentence(rule: rule, model: model)
                .opacity(rule.enabled ? 1 : 0.45)
                .layoutPriority(-1)

            if decidesTest {
                Badge(text: "Decides", tint: .accentColor)
            } else if matchesTest {
                Badge(text: "Matches", tint: .secondary)
            }

            Button {
                withAnimation(.easeOut(duration: 0.2)) { library.deleteRule(rule.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Delete rule")
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.07 : 0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: decidesTest || glow || dropTargeted ? 1.5 : 1))
        .overlay(alignment: .top) {
            if dropTargeted {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -7)
            }
        }
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != rule.id else { return false }
            withAnimation(.spring(duration: 0.3)) { library.moveRule(id, to: index) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: matchesTest)
        .onAppear { flashIfNew() }
        .onChange(of: model.highlightedRuleID) { _, _ in flashIfNew() }
    }

    private var borderColor: Color {
        if dropTargeted || glow || decidesTest { return .accentColor.opacity(0.8) }
        if matchesTest { return .accentColor.opacity(0.35) }
        return .primary.opacity(0.07)
    }

    private func flashIfNew() {
        guard model.highlightedRuleID == rule.id else { return }
        withAnimation(.easeOut(duration: 0.2)) { glow = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.6)) { glow = false }
            if model.highlightedRuleID == rule.id { model.highlightedRuleID = nil }
        }
    }
}

/// The rule as a sentence: "Links to [github.com] [and its subdomains]
/// [on any path] open in [Work space]".
private struct FlowSentence: View {
    let rule: Rule
    let model: AirTrafficControlModel
    private var library: Library { model.library }

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Word("Links to")
            MatcherPills(matcher: rule.matcher) { matcher in
                var updated = rule
                updated.matcher = matcher
                library.updateRule(updated)
            }
            Word("open in")
            RoutePill(rule: rule, library: library)
            OvertonesPill(rule: rule, model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The value, scope, and path pills for one matcher. The path pill is left
/// out for a pattern, which already covers the whole link.
private struct MatcherPills: View {
    let matcher: URLMatcher
    let onChange: (URLMatcher) -> Void

    var body: some View {
        MatcherValuePill(matcher: matcher, onChange: onChange)
        ScopePill(matcher: matcher, onChange: onChange)
        if matcher.scope != .pattern {
            PathPill(matcher: matcher, onChange: onChange)
        }
    }
}

private struct Word: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// The host, domain, or pattern, edited in place. It turns red when invalid.
private struct MatcherValuePill: View {
    let matcher: URLMatcher
    let onChange: (URLMatcher) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(matcher.scope == .pattern ? "pattern" : "example.com"))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold, design: matcher.scope == .pattern ? .monospaced : .default))
            .focused($focused)
            .fixedSize()
            .frame(minWidth: 90, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(focused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
            .onAppear { text = matcher.value }
            .onChange(of: matcher.value) { _, value in if !focused { text = value } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
            .help(matcher.isValid ? "" : invalidHelp)
            .onAppear {
                // A new, empty matcher starts with its value ready for typing.
                if matcher.value.isEmpty { focused = true }
            }
    }

    private var draft: URLMatcher {
        var matcher = matcher
        matcher.value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if matcher.scope == .pattern { matcher.value = text.trimmingCharacters(in: .whitespaces) }
        return matcher
    }

    private var fill: Color {
        draft.isValid || text.isEmpty ? Color.accentColor.opacity(0.16) : Color.red.opacity(0.22)
    }

    private var invalidHelp: String {
        matcher.scope == .pattern ? "This is not a valid regular expression." : "Enter a host name with no spaces or slashes."
    }

    private func commit() {
        guard draft != matcher else { return }
        onChange(draft)
    }
}

/// "only", "and its subdomains", or "matching the pattern".
private struct ScopePill: View {
    let matcher: URLMatcher
    let onChange: (URLMatcher) -> Void
    @State private var open = false

    var body: some View {
        ChoicePill(title: title, open: $open) {
            ChoiceList {
                ChoiceRow(title: "and its subdomains", detail: "datadoghq.com also covers app.datadoghq.com",
                          symbol: "square.3.layers.3d", selected: matcher.scope == .domain) { set(.domain) }
                ChoiceRow(title: "only", detail: "Just this host. www. is ignored",
                          symbol: "square", selected: matcher.scope == .host) { set(.host) }
                ChoiceRow(title: "as a pattern", detail: "A regular expression tested against the whole link",
                          symbol: "chevron.left.forwardslash.chevron.right",
                          selected: matcher.scope == .pattern) { set(.pattern) }
            }
        }
    }

    private var title: String {
        switch matcher.scope {
        case .domain: "and its subdomains"
        case .host: "only"
        case .pattern: "as a pattern"
        }
    }

    private func set(_ scope: URLMatcher.Scope) {
        open = false
        var updated = matcher
        updated.scope = scope
        onChange(updated)
    }
}

/// "on any path", or "under /docs", edited in a popover.
private struct PathPill: View {
    let matcher: URLMatcher
    let onChange: (URLMatcher) -> Void
    @State private var open = false
    @State private var text = ""

    var body: some View {
        ChoicePill(title: title, open: $open) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Only links whose path starts with")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $text, prompt: Text("/any/path"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(width: 240, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06)))
                    .onSubmit(commit)
                HStack {
                    Button("Any path") { text = ""; commit() }
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("Done", action: commit)
                        .buttonStyle(QuietButtonStyle(prominent: true))
                }
            }
            .padding(14)
            .onAppear { text = matcher.pathPrefix ?? "" }
        }
    }

    private var title: String {
        guard let path = matcher.pathPrefix, !path.isEmpty, path != "/" else { return "on any path" }
        return "under \(path.hasPrefix("/") ? path : "/" + path)"
    }

    private func commit() {
        open = false
        var updated = matcher
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        updated.pathPrefix = trimmed.isEmpty ? nil : trimmed
        onChange(updated)
    }
}

/// Where matching links open: a space, a Minor Chord window, or nowhere special.
private struct RoutePill: View {
    let rule: Rule
    let library: Library
    @State private var open = false

    var body: some View {
        ChoicePill(open: $open, prominent: true) {
            DestinationLabel(route: rule.actions.route, library: library)
        } content: {
            ChoiceList {
                ChoiceHeading("Spaces")
                ForEach(library.spaces) { space in
                    ChoiceRow(title: space.name, detail: profileName(space.profileID), symbol: "square.stack",
                              selected: rule.actions.route == .space(space.id)) { set(.space(space.id)) }
                }
                ChoiceHeading("Minor Chord window")
                ForEach(library.profiles) { profile in
                    ChoiceRow(title: "Minor Chord window", detail: "Uses the \(profile.name) profile",
                              symbol: "macwindow",
                              selected: rule.actions.route == .minorChord(profileID: profile.id)) {
                        set(.minorChord(profileID: profile.id))
                    }
                }
                ChoiceHeading("Other")
                ChoiceRow(title: "Anywhere", detail: "Do not route; other actions still apply",
                          symbol: "square.dashed", selected: rule.actions.route == nil) { set(nil) }
            }
        }
    }

    private func profileName(_ id: UUID) -> String {
        "\(library.profiles.first { $0.id == id }?.name ?? "Unknown") profile"
    }

    private func set(_ route: Route?) {
        open = false
        var updated = rule
        updated.actions.route = route
        library.updateRule(updated)
    }
}

// MARK: Building blocks

/// A capsule that opens a popover of choices.
private struct ChoicePill<Label: View, Content: View>: View {
    @Binding var open: Bool
    var prominent = false
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                label
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.primary.opacity(prominent ? (hovering ? 0.12 : 0.09) : (hovering ? 0.09 : 0.05))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) { content }
    }
}

extension ChoicePill where Label == Text {
    init(title: String, open: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._open = open
        self.label = Text(title).font(.system(size: 13, weight: .medium))
        self.content = content()
    }
}

private struct ChoiceList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .padding(6)
        .frame(width: 300)
    }
}

private struct ChoiceHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

private struct ChoiceRow: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small round switch: filled when on. Used instead of the stock switch.
struct EnabledSwitch: View {
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { onChange(!isOn) }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentColor : .primary.opacity(0.15))
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .help(isOn ? "Turn this rule off" : "Turn this rule on")
    }
}

private struct DragHandle: View {
    let visible: Bool

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 26)
            .contentShape(Rectangle())
            .opacity(visible ? 1 : 0.25)
            .help("Drag to reorder")
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }
}

private struct AddRuleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("New rule")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(hovering ? 0.2 : 0.1), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct EmptyRules: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No rules yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Paste a link above to make a rule for its site, or start from a blank rule.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New rule", action: onAdd)
                .buttonStyle(QuietButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// A rounded button with a soft fill, used instead of the stock bordered style.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.3 : 0.2)
                                                 : .primary.opacity(configuration.isPressed ? 0.12 : 0.07)))
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
}

// MARK: Tab groups

/// The heading and cards for tab groups. A group is made from a sidebar tab
/// with "Group Tabs from…"; here its match rule is edited.
private struct GroupSection: View {
    let model: AirTrafficControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Tab groups")
                    .font(.system(size: 15, weight: .semibold))
                Text("New tabs that match a group open in its strip of header tabs, including windows the site opens.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            if model.library.groups.isEmpty {
                Text("Right-click a sidebar tab and choose Group Tabs to make a group.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            ForEach(model.library.groups) { group in
                GroupCard(group: group, model: model)
            }
        }
    }
}

private struct GroupCard: View {
    let group: BrowserTab
    let model: AirTrafficControlModel
    @State private var hovering = false

    private var library: Library { model.library }
    private var matchesTest: Bool {
        guard let url = model.testURL, let matcher = group.groupMatcher else { return false }
        return matcher.isValid && matcher.matches(url)
    }

    var body: some View {
        HStack(spacing: 12) {
            SiteIcon(url: group.url, size: 18)
                .padding(.leading, 6)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Word("Tabs for")
                if let matcher = group.groupMatcher {
                    MatcherPills(matcher: matcher) { library.setGroupMatcher(group.id, matcher: $0) }
                }
                Word("open in the")
                Text(groupName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Word("group in \(spaceName)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)

            if matchesTest {
                Badge(text: "Matches", tint: .accentColor)
            }
            Button {
                withAnimation(.easeOut(duration: 0.2)) { library.ungroup(group.id) }
            } label: {
                Image(systemName: "rectangle.stack.badge.minus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Ungroup: the tabs go back to the sidebar")
        }
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.primary.opacity(hovering ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(matchesTest ? Color.accentColor.opacity(0.6) : .primary.opacity(0.07), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var groupName: String {
        group.title.isEmpty ? (group.url.host() ?? "Untitled") : group.title
    }

    private var spaceName: String {
        library.spaces.first { $0.id == group.spaceID }?.name ?? "a missing space"
    }
}

// MARK: Overtones

/// "with no overtones", or the names of the overtones a rule adds, chosen in a
/// popover. Overtones named after a domain apply on their own, so the popover
/// lists them only when the rule already names one.
private struct OvertonesPill: View {
    let rule: Rule
    let model: AirTrafficControlModel
    @State private var open = false

    private var choices: [String] {
        let ruleOnly = model.overtones.overtones.filter { $0.domain == nil }.map(\.id)
        return ruleOnly + rule.actions.overtones.filter { !ruleOnly.contains($0) }
    }

    var body: some View {
        ChoicePill(title: title, open: $open) {
            ChoiceList {
                ChoiceHeading("Overtones")
                if choices.isEmpty {
                    Text("Add a folder to the overtones folder to make one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
                ForEach(choices, id: \.self) { id in
                    let known = model.overtones.overtones.contains { $0.id == id }
                    ChoiceRow(title: id, detail: known ? detail(for: id) : "Missing from the overtones folder",
                              symbol: "wand.and.sparkles", selected: rule.actions.overtones.contains(id)) {
                        toggle(id)
                    }
                }
                Divider().padding(.vertical, 4)
                ChoiceRow(title: "Open Overtones Folder", detail: "Each folder there is one overtone",
                          symbol: "folder", selected: false) {
                    open = false
                    model.overtones.revealFolder()
                }
            }
        }
    }

    private var title: String {
        switch rule.actions.overtones.count {
        case 0: "with no overtones"
        case 1: "with \(rule.actions.overtones[0])"
        default: "with \(rule.actions.overtones.count) overtones"
        }
    }

    private func detail(for id: String) -> String {
        guard let overtone = model.overtones.overtones.first(where: { $0.id == id }) else { return "" }
        let parts = [(overtone.styles.count, "CSS"), (overtone.scripts.count, "JS"), (overtone.html.count, "HTML")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "No files yet" : parts.joined(separator: " · ")
    }

    private func toggle(_ id: String) {
        var updated = rule
        if let index = updated.actions.overtones.firstIndex(of: id) {
            updated.actions.overtones.remove(at: index)
        } else {
            updated.actions.overtones.append(id)
        }
        model.library.updateRule(updated)
    }
}
